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
#   {"phase":"fix","issue":42,"priority":"P1","resume":true,"in_flight":false}
#                                               # this worktree's own claim (#182);
#                                               # in_flight: this very session is
#                                               # still working it (#130)
#
# Exit codes:
#   0   work claimed (work-plan written)
#   1   no work available (idle tick — caller should not invoke Claude)
#   2   configuration error (e.g. missing issue source)
#
# Abandoned claims (#203): a `working` issue is also a candidate, ranked after
# fresh issues of the same priority. It is taken over only when every claim on
# it is abandoned (see claim-takeover-fns.sh); live claims are always respected.
#
# Race safety:
#   File backend: atomic claim via `issue_claim` (rename open/NNN.md →
#                 working/NNN.md). Loser of the rename race gets exit 1;
#                 we then try the next candidate, so N workers ticking
#                 together claim N different issues instead of N-1 idling.
#   GitHub, Jira, ADO: `issue_claim` is a label-add that always succeeds,
#                 so every racer "wins" it. The gate settles the race itself,
#                 before any Claude session starts: after the label-add it
#                 posts `🔒 claim <worker-id> <epoch-ms> [start=<s>] wt=<path>`
#                 (claim-owner.sh, #202), reads the comments
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
#   AUTOCODER_WORKER_ID        worker id in claim comments (default
#                              <hostname>-<owner pid>; see claim-owner.sh)
#   AUTOCODER_OWNER_PID        the long-lived process that owns this worker's
#                              claims, exported by claude-worker-loop.sh
#   AUTOCODER_CLAIM_WINDOW_S   age in seconds past which a claim comment no
#                              longer competes (default 120)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_JSON="${AUTOCODER_WORK_JSON:-/tmp/autocoder-work.json}"
MAX_TRIES="${AUTOCODER_CLAIM_MAX_TRIES:-10}"
CLAIM_WINDOW_S="${AUTOCODER_CLAIM_WINDOW_S:-120}"

# Source backend dispatch (defines issue_list, issue_update, ...)
# shellcheck source=issue-fns.sh
source "${SCRIPT_DIR}/issue-fns.sh"

# The claim names the process that outlives it (the worker loop or the agent
# session), never this gate's own pid: the gate exits seconds after claiming,
# and a claim signed by a dead pid cannot be told apart from an orphan (#202).
# shellcheck source=claim-owner.sh
source "${SCRIPT_DIR}/claim-owner.sh"
OWNER_PID="$(claim_owner_pid "$$")"
WORKER_ID="$(claim_owner_id "$OWNER_PID")"
OWNER_EXTRA="$(claim_owner_extra "$OWNER_PID")"

if [ -z "${ISSUE_SOURCE:-}" ]; then
  echo "fix-loop-gate: ISSUE_SOURCE not set" >&2
  exit 2
fi

# ── 0. Resume this worktree's own claim before claiming anything new (#182) ──
# A worker compacted, cleared or restarted mid-issue would otherwise claim fresh
# work and strand its own `working` issue. AUTOCODER_RESUME_OWN_CLAIM=0 disables.
# Sourced only when present: a partial script tree (#142) then loses resume rather
# than the whole gate dying under `set -e`.
worker_state_set() { :; }
if [ -f "${SCRIPT_DIR}/worker-state-fns.sh" ]; then
  # shellcheck source=worker-state-fns.sh
  source "${SCRIPT_DIR}/worker-state-fns.sh"
  if [ "${AUTOCODER_RESUME_OWN_CLAIM:-1}" = 1 ]; then
    RESUME_RC=0
    RESUME_PLAN="$(worker_resume_plan)" || RESUME_RC=$?
    case "$RESUME_RC" in
      0) printf '%s\n' "$RESUME_PLAN" > "$WORK_JSON"; exit 0 ;;
      2) exit 1 ;;   # holding an issue that cannot resume this tick: never claim over it
    esac
  fi
fi

# ── 1. Snapshot all open issues ──────────────────────────────────────────
ALL_JSON="$(mktemp)"
trap 'rm -f "$ALL_JSON"' EXIT
issue_list --state open --limit 500 > "$ALL_JSON"

# ── 1b. Issues with a live remote branch are someone's work in flight ────
# /fix treats a pushed feature/issue-N branch as the strongest lock, because it
# survives a dropped or not-yet-propagated `working` label. This gate used to
# filter on labels alone, so an issue its owner was actively resuming (#140) or
# working (#153) was claimed by a second worker (#210). One ls-remote per tick;
# fails open to [] when origin is unreachable, as /fix does.
CLAIMED_BY_BRANCH="$(bash "${SCRIPT_DIR}/claimed-issue-numbers.sh" origin 2>/dev/null || true)"
[ -n "$CLAIMED_BY_BRANCH" ] || CLAIMED_BY_BRANCH="[]"

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
  ALL_JSON_PATH="$ALL_JSON" CLAIMED_BY_BRANCH="$CLAIMED_BY_BRANCH" python3 - <<'PY'
import json, os, random, sys

with open(os.environ["ALL_JSON_PATH"]) as f:
    issues = json.load(f)
try:
    claimed_by_branch = set(json.loads(os.environ.get("CLAIMED_BY_BRANCH") or "[]"))
except ValueError:
    claimed_by_branch = set()

PRIORITY_LABELS = ("P0", "P1", "P2", "P3")
BLOCKING = {
    "needs-approval", "needs-design", "needs-clarification",
    "too-complex", "future", "decomposed", "blocked", "awaiting-integration",
    "merging",
}
WORKING = "working"
PROPOSAL = "proposal"
ENHANCEMENT = "enhancement"

def labels(issue):
    return {l["name"] for l in issue.get("labels", [])}

unprioritized = []
priority = []     # (priority_index, rank, tiebreak, kind, number); rank 0 = fresh
enhancements = []

for issue in issues:
    ls = labels(issue)
    if ls & BLOCKING:
        continue
    if WORKING in ls:
        # Someone holds it. A candidate only for taking over an abandoned
        # claim (#203); the shell checks its claims before touching it.
        if (ls & set(PRIORITY_LABELS)) and PROPOSAL not in ls \
                and issue["number"] not in claimed_by_branch:
            p_idx = next(i for i, p in enumerate(PRIORITY_LABELS) if p in ls)
            kind = "enhance" if ENHANCEMENT in ls else "fix"
            # Shuffled within a priority (random tiebreak), so the per-tick
            # check cap cannot starve the same abandoned issue forever.
            (enhancements if kind == "enhance" else priority).append(
                (p_idx, 1, random.random(), "TAKEOVER", issue["number"]))
        continue

    has_priority = bool(ls & set(PRIORITY_LABELS))

    if not has_priority:
        # Anything without a priority label is unprioritized work to triage,
        # *unless* it's a proposal (those wait for human approval).
        if PROPOSAL not in ls:
            unprioritized.append(issue["number"])
        continue

    # A live feature/issue-N branch means another worker owns it; triage
    # above is metadata only, but fix/enhance work must not be claimed twice.
    if issue["number"] in claimed_by_branch:
        continue

    # Priority issue: pick its priority index
    p_idx = next(i for i, p in enumerate(PRIORITY_LABELS) if p in ls)

    if PROPOSAL in ls:
        continue  # awaiting human approval

    if ENHANCEMENT in ls:
        enhancements.append((p_idx, 0, 0.0, "ENHANCE", issue["number"]))
    else:
        priority.append((p_idx, 0, float(issue["number"]), "FIX", issue["number"]))

# Triage takes precedence over fix work
if unprioritized:
    print("TRIAGE " + " ".join(str(n) for n in unprioritized))
    sys.exit(0)

priority.sort()
enhancements.sort()
if not priority and not enhancements:
    print("IDLE")
    sys.exit(0)

# A fresh issue goes before a takeover at the same priority.
for p_idx, _, _, kind, num in priority:
    if kind == "TAKEOVER":
        print(f"TAKEOVER {num} {PRIORITY_LABELS[p_idx]} fix")
    else:
        print(f"FIX {num} {PRIORITY_LABELS[p_idx]}")
for p_idx, _, _, kind, num in enhancements:
    if kind == "TAKEOVER":
        print(f"TAKEOVER {num} {PRIORITY_LABELS[p_idx]} enhance")
    else:
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
  issue_comment "$n" --body "🔒 claim $WORKER_ID $now_ms $OWNER_EXTRA" 2>/dev/null || return 0
  CLAIM_MS="$now_ms"   # recorded with the claim, so a resume can prove it is still ours (#182)
  issue_json="$(issue_get "$n" 2>/dev/null)" || return 0
  ISSUE_JSON="$issue_json" ME="$WORKER_ID" NOW_MS="$now_ms" \
    WINDOW_MS="$((CLAIM_WINDOW_S * 1000))" EXCLUDE="${CLAIM_EXCLUDE:-}" python3 - <<'PY'
import json, os, re, sys

# Claims being taken over (#203): "<ms> <id> ..." lines. They are abandoned, so
# they cannot win the race against the takers.
excluded = set()
for line in os.environ.get("EXCLUDE", "").splitlines():
    f = line.split()
    if len(f) >= 2 and f[0].isdigit():
        excluded.add((int(f[0]), f[1]))

try:
    comments = json.loads(os.environ["ISSUE_JSON"]).get("comments") or []
except ValueError:
    sys.exit(0)
now = int(os.environ["NOW_MS"])
oldest = now - int(os.environ["WINDOW_MS"])
claims = []
for c in comments:
    # Old markers end after the epoch-ms; new ones add owner fields (#202).
    m = re.match(r"\s*🔒 claim (\S+) (\d+)(?: start=\d+)?(?: wt=[^\n]*)?\s*$", c.get("body") or "")
    if m and int(m.group(2)) >= oldest and (int(m.group(2)), m.group(1)) not in excluded:
        claims.append((int(m.group(2)), m.group(1)))
sys.exit(0 if not claims or min(claims) == (now, os.environ["ME"]) else 1)
PY
}

# ── Take over an abandoned claim (#203) ──────────────────────────────────
# A `working` issue whose every claim is abandoned (claim-takeover-fns.sh: owner
# dead on this host, or no branch after the grace period) is taken over instead
# of being backed off from forever. The race between takers is settled exactly as
# on a fresh claim, with the abandoned claims excluded so they cannot win it.
# Only comment-based backends carry claim markers; the file backend is skipped.
TAKEOVER_MAX="${AUTOCODER_TAKEOVER_MAX_CHECKS:-5}"
takeover_checks=0
if [ -f "${SCRIPT_DIR}/claim-takeover-fns.sh" ]; then
  # shellcheck source=claim-takeover-fns.sh
  source "${SCRIPT_DIR}/claim-takeover-fns.sh"
fi

# take_over_abandoned <issue> → exit 0 when this worker now holds the issue.
take_over_abandoned() {
  local n="$1" json abandoned list
  [ "$ISSUE_SOURCE" != file ] || return 1
  declare -F claims_abandoned >/dev/null || return 1
  [ "$takeover_checks" -lt "$TAKEOVER_MAX" ] || return 1
  takeover_checks=$((takeover_checks + 1))
  json="$(issue_get "$n" 2>/dev/null)" || return 1
  abandoned="$(claims_abandoned "$json" "$n")" || return 1
  CLAIM_EXCLUDE="$abandoned" claim_comment_wins "$n" || return 1
  list="$(printf '%s\n' "$abandoned" | sed -E 's/^[0-9]+ ([^ ]+) (.*)$/- `\1`: \2/')"
  issue_comment "$n" --body "♻️ **Taking over an abandoned claim**

This issue was \`working\`, but every claim on it was abandoned:
${list}

\`${WORKER_ID}\` has claimed it and will carry the work on." 2>/dev/null || true
  return 0
}

# Walk the candidates in order; a lost race means "try the next one".
tries=0
while read -r PHASE ISSUE_NUM PRIORITY KIND <&3; do
  case "$PHASE" in
    FIX|ENHANCE|TAKEOVER) ;;
    *)
      echo "fix-loop-gate: unexpected classification '$PHASE'" >&2
      exit 2
      ;;
  esac

  CLAIM_MS=""
  if [ "$PHASE" = TAKEOVER ]; then
    take_over_abandoned "$ISSUE_NUM" || continue
    if [ "$KIND" = enhance ]; then PHASE=ENHANCE; else PHASE=FIX; fi
  else
    [ "$tries" -lt "$MAX_TRIES" ] || break
    tries=$((tries + 1))
    issue_claim "$ISSUE_NUM" 2>/dev/null || continue
    if [ "$ISSUE_SOURCE" != file ]; then
      claim_comment_wins "$ISSUE_NUM" || continue
    fi
  fi

  SESSION_ID=""
  [ -z "${AUTOCODER_NEXT_FIX_FILE:-}" ] && SESSION_ID="${CLAUDE_CODE_SESSION_ID:-}"
  worker_state_set "$ISSUE_NUM" "$CLAIM_MS" "$SESSION_ID"
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
