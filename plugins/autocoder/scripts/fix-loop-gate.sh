#!/usr/bin/env bash
#
# fix-loop-gate.sh — pure-script pre-LLM gate for the fix-loop cron tick.
#
# Decides whether there is autonomous work to do, and if so, atomically
# claims a single issue by adding the `working` label. Exits 0 + writes a
# work plan to ${AUTOCODER_WORK_JSON:-/tmp/autocoder-work.json} when work
# was claimed. Exits 1 (silently) when the queue is empty — caller skips
# the LLM invocation entirely.
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
#   File backend: atomic claim via `issue_update --add-label working
#                 --if-unset` which exits 9 if another gate beat us;
#                 we then try the next candidate.
#   GitHub backend: same `--add-label working` (idempotent) plus the
#                 existing comment-scan race detector in /autocoder:fix.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_JSON="${AUTOCODER_WORK_JSON:-/tmp/autocoder-work.json}"

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
#   TRIAGE <n> <n> <n>...
#   FIX <issue_num> <priority>  (already sorted highest-priority first)
#   ENHANCE <issue_num>
#   REGRESSION
#   IDLE
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
    "too-complex", "future", "decomposed",
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
if priority:
    p_idx, num = priority[0]
    print(f"FIX {num} {PRIORITY_LABELS[p_idx]}")
    sys.exit(0)

enhancements.sort()
if enhancements:
    _, num = enhancements[0]
    print(f"ENHANCE {num}")
    sys.exit(0)

# Nothing to do. Caller can decide whether to escalate to regression-test
# proposal, or just idle.
print("IDLE")
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

  FIX|ENHANCE)
    # Try to atomically claim the chosen issue. For file backend we get
    # CAS via --if-unset; for github backend the label-add is idempotent
    # so we fall back to the existing comment-scan race detector in
    # /autocoder:fix.
    set -- $REST
    ISSUE_NUM="$1"
    PRIORITY="${2:-}"

    if [ "$ISSUE_SOURCE" = "file" ]; then
      # Atomic claim: exit 9 if already claimed (lost race).
      if ! issue_update "$ISSUE_NUM" --add-label working --if-unset 2>/dev/null; then
        # Lost race — another gate beat us. Re-run on next tick.
        exit 1
      fi
    else
      # GitHub backend: idempotent add + downstream comment-scan handles
      # cross-host racers.
      issue_update "$ISSUE_NUM" --add-label working 2>/dev/null || true
    fi

    if [ "$PHASE" = "FIX" ]; then
      printf '{"phase":"fix","issue":%s,"priority":"%s"}\n' \
        "$ISSUE_NUM" "$PRIORITY" > "$WORK_JSON"
    else
      printf '{"phase":"enhance","issue":%s}\n' "$ISSUE_NUM" > "$WORK_JSON"
    fi
    exit 0
    ;;

  *)
    echo "fix-loop-gate: unexpected classification '$PHASE'" >&2
    exit 2
    ;;
esac
