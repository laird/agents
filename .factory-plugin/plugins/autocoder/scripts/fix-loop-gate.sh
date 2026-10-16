#!/usr/bin/env bash
#
# fix-loop-gate.sh — pure-script pre-LLM gate for the fix-loop cron tick.
#
# Decides whether there is autonomous work to do, and if so, atomically
# claims one issue via `issue_claim`. Candidates are tried in priority order
# (priority bugs, then enhancements); the first successful claim wins. Exits
# 0 + writes a work plan to ${AUTOCODER_WORK_JSON:-/tmp/autocoder-work.json}
# when work was claimed. Exits 1 (silently) when the queue is empty or every
# candidate's claim failed — caller skips the LLM invocation entirely.
#
# Work-plan JSON shape:
#   {"phase":"triage", "issues":[1,2,3]}        # unprioritized exist
#   {"phase":"fix",    "issue":42, "priority":"P0"}  # ready priority bug
#   {"phase":"enhance","issue":17}              # approved enhancement
#   {"phase":"regression"}                      # queue empty, run tests
#
# Exit codes:
#   0   work claimed (work-plan written)
#   1   no work available (idle tick — caller should not invoke Claude)
#   2   configuration error (e.g. missing issue source)
#
# Race safety:
#   File backend: atomic claim via `issue_claim` (rename open/NNN.md →
#                 working/NNN.md). Loser of the rename race gets exit 1;
#                 we then try the next candidate, so N workers ticking
#                 together claim N different issues instead of N-1 idling.
#   GitHub, Jira, ADO: `issue_claim` is a label-add that always succeeds,
#                 so every racer "wins" it. The gate settles the race itself,
#                 before any Claude session starts: after the label-add it
#                 posts `🔒 claim <worker-id> <epoch-ms>`, reads the comments
#                 back, and keeps the issue only when the earliest live claim
#                 (smallest epoch-ms, worker-id breaking ties) is its own.
#                 Every reader sorts the same comments the same way, so one
#                 racer keeps the issue. Claims older than
#                 AUTOCODER_CLAIM_WINDOW_S are settled races and are ignored.
#                 A loser moves to the next candidate WITHOUT `issue_release`:
#                 the label is shared, and removing it would strip the
#                 winner's lock. The marker deliberately differs from
#                 /autocoder:fix's `[autocoder-claim]`, which aborts when it
#                 counts more than one; that detector still runs downstream.
#                 If the comment or the read-back fails, the gate keeps the
#                 claim, as it did before the read-back existed.
#
# Environment:
#   AUTOCODER_WORK_JSON        work-plan path (default /tmp/autocoder-work.json)
#   AUTOCODER_CLAIM_MAX_TRIES  claim attempts per tick before giving up
#                              (default 10), so a backend whose claims all fail
#                              does not scan hundreds of issues per tick.
#   AUTOCODER_WORKER_ID        worker id in claim comments
#                              (default <hostname>-<gate pid>)
#   AUTOCODER_CLAIM_WINDOW_S   age in seconds past which a claim comment no
#                              longer competes (default 120)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_JSON="${AUTOCODER_WORK_JSON:-/tmp/autocoder-work.json}"
MAX_TRIES="${AUTOCODER_CLAIM_MAX_TRIES:-10}"
WORKER_ID="${AUTOCODER_WORKER_ID:-$(hostname)-$$}"
WORKER_ID="${WORKER_ID//[[:space:]]/_}"
CLAIM_WINDOW_S="${AUTOCODER_CLAIM_WINDOW_S:-120}"

# Source backend dispatch (defines issue_list, issue_update, ...)
# shellcheck source=issue-fns.sh
source "${SCRIPT_DIR}/issue-fns.sh"

if [ -z "${ISSUE_SOURCE:-}" ]; then
  echo "fix-loop-gate: ISSUE_SOURCE not set" >&2
  exit 2
fi

# ── 1. Snapshot all open issues ──────────────────────────────────────────
ALL_JSON="$(mktemp)"
trap 'rm -f "$ALL_JSON"' EXIT
issue_list --state open --limit 500 > "$ALL_JSON"

# ── 2. Classify in pure python (no LLM) ──────────────────────────────────
# Outputs one of:
#   TRIAGE <n> <n> <n>...       (single line)
#   IDLE                        (single line)
#   an ordered candidate list, one per line, best first:
#     FIX <issue_num> <priority>   (priority bugs, highest priority first)
#     ENHANCE <issue_num>          (then enhancements, highest priority first)
classify() {
  # Note: heredoc IS python stdin; the issues JSON must come via env var
  # (heredoc overrides any `< file` redirect, so we use ALL_JSON_PATH).
  ALL_JSON_PATH="$ALL_JSON" python3 - <<'PY'
import json, os, sys

with open(os.environ["ALL_JSON_PATH"]) as f:
    issues = json.load(f)

PRIORITY_LABELS = ("P0", "P1", "P2", "P3")
BLOCKING = {
    "needs-approval", "needs-design", "needs-clarification",
    "too-complex", "future", "decomposed", "blocked", "awaiting-integration",
}
WORKING = "working"
PROPOSAL = "proposal"
ENHANCEMENT = "enhancement"

def labels(issue):
    return {l["name"] for l in issue.get("labels", [])}

unprioritized = []
priority = []     # list of (priority_index, number)
enhancements = []

for issue in issues:
    ls = labels(issue)
    if WORKING in ls:
        continue
    if ls & BLOCKING:
        continue

    has_priority = bool(ls & set(PRIORITY_LABELS))

    if not has_priority:
        # Anything without a priority label is unprioritized work to triage,
        # *unless* it's a proposal (those wait for human approval).
        if PROPOSAL not in ls:
            unprioritized.append(issue["number"])
        continue

    # Priority issue: pick its priority index
    p_idx = next(i for i, p in enumerate(PRIORITY_LABELS) if p in ls)

    if PROPOSAL in ls:
        continue  # awaiting human approval

    if ENHANCEMENT in ls:
        enhancements.append((p_idx, issue["number"]))
    else:
        priority.append((p_idx, issue["number"]))

# Triage takes precedence over fix work
if unprioritized:
    print("TRIAGE " + " ".join(str(n) for n in unprioritized))
    sys.exit(0)

priority.sort()
enhancements.sort()
if not priority and not enhancements:
    print("IDLE")
    sys.exit(0)

for p_idx, num in priority:
    print(f"FIX {num} {PRIORITY_LABELS[p_idx]}")
for _, num in enhancements:
    print(f"ENHANCE {num}")
PY
}

CLASSIFICATION="$(classify)"
read -r PHASE REST <<< "$CLASSIFICATION"

case "$PHASE" in
  IDLE)
    # Truly nothing actionable. Do not spawn Claude.
    exit 1
    ;;

  TRIAGE)
    # Unprioritized issues exist. Write the list; dispatcher will use
    # Haiku to assign P0–P3. (No atomic claim needed: triage is pure
    # metadata, not work execution.)
    issues_json="[$(echo "$REST" | tr ' ' ',')]"
    printf '{"phase":"triage","issues":%s}\n' "$issues_json" > "$WORK_JSON"
    exit 0
    ;;
esac

# Exit 0 when this worker holds the earliest live claim comment on issue $1.
claim_comment_wins() {
  local n="$1" now_ms issue_json
  now_ms="$(python3 -c 'import time; print(int(time.time() * 1000))')"
  issue_comment "$n" --body "🔒 claim $WORKER_ID $now_ms" 2>/dev/null || return 0
  issue_json="$(issue_get "$n" 2>/dev/null)" || return 0
  ISSUE_JSON="$issue_json" ME="$WORKER_ID" NOW_MS="$now_ms" \
    WINDOW_MS="$((CLAIM_WINDOW_S * 1000))" python3 - <<'PY'
import json, os, re, sys

try:
    comments = json.loads(os.environ["ISSUE_JSON"]).get("comments") or []
except ValueError:
    sys.exit(0)
now = int(os.environ["NOW_MS"])
oldest = now - int(os.environ["WINDOW_MS"])
claims = []
for c in comments:
    m = re.match(r"\s*🔒 claim (\S+) (\d+)\s*$", c.get("body") or "")
    if m and int(m.group(2)) >= oldest:
        claims.append((int(m.group(2)), m.group(1)))
sys.exit(0 if not claims or min(claims) == (now, os.environ["ME"]) else 1)
PY
}

# Walk the candidates in order; a lost race means "try the next one".
tries=0
while read -r PHASE ISSUE_NUM PRIORITY <&3; do
  case "$PHASE" in
    FIX|ENHANCE) ;;
    *)
      echo "fix-loop-gate: unexpected classification '$PHASE'" >&2
      exit 2
      ;;
  esac
  [ "$tries" -lt "$MAX_TRIES" ] || break
  tries=$((tries + 1))

  issue_claim "$ISSUE_NUM" 2>/dev/null || continue
  if [ "$ISSUE_SOURCE" != file ]; then
    claim_comment_wins "$ISSUE_NUM" || continue
  fi

  if [ "$PHASE" = "FIX" ]; then
    printf '{"phase":"fix","issue":%s,"priority":"%s"}\n' \
      "$ISSUE_NUM" "$PRIORITY" > "$WORK_JSON"
  else
    printf '{"phase":"enhance","issue":%s}\n' "$ISSUE_NUM" > "$WORK_JSON"
  fi
  exit 0
done 3<<< "$CLASSIFICATION"

# Every candidate tried lost its claim (or the backend errored). Re-run on
# the next tick.
exit 1
