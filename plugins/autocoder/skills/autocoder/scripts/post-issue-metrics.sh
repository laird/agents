#!/usr/bin/env bash
# post-issue-metrics.sh — comment an issue's token/time/cost metrics onto the issue.
#
# WHY THIS EXISTS:
#   The cost of a fix was only ever visible as an unattributed line on a monthly
#   bill. Every headless worker session already records what it spent in its
#   stream-json transcript (see issue-metrics.py); this puts that number where
#   the work is, so "what did this change cost, and how long did it take" is
#   answerable from the issue itself long after /tmp has been cleared.
#
#   Posting goes through issue-fns.sh rather than `gh` directly, so it works on
#   whichever backend the project uses (github/jira/ado/file) instead of
#   silently doing nothing on three of the four.
#
# IDEMPOTENCY: each comment carries an HTML marker naming its scope —
#   <!-- autocoder-metrics session=worker-123-fix-456-090000.jsonl -->
#   <!-- autocoder-metrics aggregate -->
# and the issue's existing comments are checked for that exact marker before
# posting. Per-session markers are unique, so a worker that fixes an issue twice
# posts two comments (one per attempt) rather than overwriting the first — the
# retry cost is data, not noise. `--force` posts regardless.
#
# FAIL-SOFT: this is called from claude-worker-loop.sh immediately after a fix
# session. A metrics comment failing must never take down a worker, so every
# failure path prints a reason and returns non-zero for a caller that cares,
# and the loop invokes it with `|| true`.
#
# Usage:
#   post-issue-metrics.sh <issue> [--session PATH] [--dry-run] [--force]
#
# Environment:
#   AUTOCODER_METRICS   0 to disable posting entirely (default: 1)
#   AUTOCODER_LOG_DIR   transcript directory (default: /tmp/autocoder-logs)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
METRICS_PY="$SCRIPT_DIR/issue-metrics.py"

ISSUE=""
SESSION=""
DRY_RUN=0
FORCE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --session) SESSION="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --force)   FORCE=1; shift ;;
    -h|--help) sed -n '2,34p' "$0"; exit 0 ;;
    -*) echo "post-issue-metrics.sh: unknown argument '$1'" >&2; exit 2 ;;
    *)  ISSUE="$1"; shift ;;
  esac
done

[ -n "$ISSUE" ] || { echo "Usage: $0 <issue> [--session PATH] [--dry-run] [--force]" >&2; exit 2; }

if [ "${AUTOCODER_METRICS:-1}" = "0" ]; then
  echo "metrics: disabled (AUTOCODER_METRICS=0)"
  exit 0
fi

[ -f "$METRICS_PY" ] || { echo "metrics: issue-metrics.py not found at $METRICS_PY" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "metrics: python3 not available" >&2; exit 1; }

# Render first. An issue with no finished transcript produces nothing, and that
# is the common case for a fix that crashed before its first result event —
# report it rather than posting an empty table.
if [ -n "$SESSION" ]; then
  BODY=$(python3 "$METRICS_PY" --session "$SESSION" --issue "$ISSUE" --markdown 2>&1)
else
  BODY=$(python3 "$METRICS_PY" "$ISSUE" --markdown 2>&1)
fi
rc=$?
if [ $rc -ne 0 ] || [ -z "$BODY" ]; then
  echo "metrics: nothing to report for #$ISSUE (${BODY:-no output})"
  exit 0
fi

MARKER=$(printf '%s\n' "$BODY" | head -1)
case "$MARKER" in
  '<!-- autocoder-metrics'*) ;;
  *) echo "metrics: rendered body has no marker line; refusing to post" >&2; exit 1 ;;
esac

if [ "$DRY_RUN" = "1" ]; then
  printf '%s\n' "$BODY"
  exit 0
fi

# shellcheck source=issue-fns.sh
source "${SCRIPT_DIR}/issue-fns.sh" || {
  echo "metrics: cannot source issue-fns.sh" >&2; exit 1; }

if [ "$FORCE" != "1" ]; then
  # A backend that cannot read comments back returns nothing here; treat that as
  # "unknown", post anyway, and let the marker dedupe on the next run rather
  # than silently never reporting.
  if issue_get "$ISSUE" 2>/dev/null \
       | jq -e --arg m "$MARKER" '((.comments // []) | any((.body // "") | contains($m)))' \
       >/dev/null 2>&1; then
    echo "metrics: #$ISSUE already has this metrics comment — skipping"
    exit 0
  fi
fi

if issue_comment "$ISSUE" --body "$BODY" >/dev/null 2>&1; then
  echo "metrics: posted to #$ISSUE"
  exit 0
fi

echo "metrics: failed to comment on #$ISSUE (backend error)" >&2
exit 1
