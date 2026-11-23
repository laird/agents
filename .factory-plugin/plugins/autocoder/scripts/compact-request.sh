#!/bin/bash
# compact-request.sh — a worker asks to be compacted, and the gate stops claiming until it is (#373).
#
# WHY THIS EXISTS:
#   A fix-loop worker running as an inline /loop cron must compact before it starts a new issue,
#   but a session cannot type /compact into itself. Before this, it asked a person to and gave the
#   gate's claim back (#248); every 4-minute tick then claimed the same issue and released it again,
#   for hours, until someone typed /compact. Now the worker records the request here. The gate
#   (fix-loop-gate.sh) claims nothing new while the request is pending, and the worker ends its turn
#   with a line starting COMPACT_REQUESTED, which worker-auth-watchdog.sh (cron, every 2 minutes)
#   answers by sending /compact to the pane. The request is cleared by the compacted session on its
#   next tick, or expires after AUTOCODER_COMPACT_REQUEST_TTL seconds (default 3600) so a host with no
#   watchdog falls back to one claim-and-release an hour instead of a stall.
#
# Usage:
#   compact-request.sh request ["<reason>"]   record a request for this worktree
#   compact-request.sh pending                exit 0 (and print its age and reason) while one is
#                                             pending; exit 1 when none is, or it expired (removed)
#   compact-request.sh clear                  remove the request (no-op when there is none)
#
# The request lives in this worktree's git dir (not the common dir), so each worktree has its own.
#
# Exit status: 0 done / pending; 1 nothing pending; 2 bad usage or not in a git worktree.
set -u

TTL="${AUTOCODER_COMPACT_REQUEST_TTL:-3600}"
GIT_DIR="$(git rev-parse --absolute-git-dir 2>/dev/null)" || { echo "compact-request: not in a git worktree" >&2; exit 2; }
FILE="$GIT_DIR/autocoder-compact-request"

case "${1:-}" in
  request)
    printf '%s\t%s\n' "$(date +%s)" "${2:-context compaction before the next issue}" > "$FILE" \
      || { echo "compact-request: cannot write $FILE" >&2; exit 2; }
    echo "compact-request: recorded; the gate claims nothing new until this worker is compacted"
    ;;
  pending)
    [ -f "$FILE" ] || exit 1
    IFS=$'\t' read -r AT REASON < "$FILE" || AT=""
    [[ "$AT" =~ ^[0-9]+$ ]] || AT=0
    AGE=$(( $(date +%s) - AT ))
    if [ "$AGE" -ge "$TTL" ]; then
      rm -f "$FILE"
      echo "compact-request: the request expired after ${AGE}s with no compaction; dropping it" >&2
      exit 1
    fi
    echo "compact-request: pending for ${AGE}s (${REASON:-no reason given})"
    ;;
  clear)
    rm -f "$FILE"
    ;;
  *)
    sed -n '/^# Usage:/,/^# Exit status/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
    exit 2
    ;;
esac
