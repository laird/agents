#!/bin/bash
# merge-poll.sh — check on a merge started with merge-launch.sh (#1693).
#
# Designed to be called repeatedly, ONE call per turn, as separate Bash-tool
# invocations. It sleeps a bounded slice of wall clock (default 60s, always
# well under the ~2-minute foreground Bash-tool ceiling) and then reports
# back. It never loops internally waiting for completion — a `while` loop
# with a long sleep packed into a single call just relocates the exact
# problem #1693 fixes into the loop itself.
#
# USAGE:
#   merge-poll.sh --issue <num> [--wait <seconds, default 60>]
#
# Exit codes:
#   0    merge finished successfully — same meaning as merge-to-integration.sh's own 0
#   1    merge finished with a push failure (or died with no exit code recorded)
#   2    merge finished with the combined-tree tests failing
#   3    merge conflict — left unresolved in the shared worktree; the caller resolves it
#        directly (same meaning as merge-to-integration.sh's own 3) and only escalates to
#        needs-clarification if ITS OWN resolution attempt also fails (#1766)
#   75   still running — call this again next turn (EX_TEMPFAIL)
#   64   no merge job recorded for this issue (never launched, or already reaped) (EX_USAGE)
set -uo pipefail

ISSUE_NUM=""
WAIT_SECS=60
while [ $# -gt 0 ]; do
  case "$1" in
    --issue) ISSUE_NUM="$2"; shift 2 ;;
    --wait)  WAIT_SECS="$2"; shift 2 ;;
    *) echo "merge-poll.sh: unknown arg '$1'" >&2; exit 1 ;;
  esac
done

if [ -z "$ISSUE_NUM" ]; then
  echo "merge-poll.sh: --issue is required" >&2
  exit 1
fi

LOG="/tmp/autocoder-merge-${ISSUE_NUM}.log"
PIDFILE="/tmp/autocoder-merge-${ISSUE_NUM}.pid"
EXITFILE="/tmp/autocoder-merge-${ISSUE_NUM}.exit"
RUNSCRIPT="/tmp/autocoder-merge-${ISSUE_NUM}.run.sh"

if [ ! -f "$PIDFILE" ]; then
  echo "❌ No merge job recorded for issue #${ISSUE_NUM} (${PIDFILE} missing)." >&2
  exit 64
fi

PID=$(cat "$PIDFILE" 2>/dev/null || echo "")

sleep "$WAIT_SECS"

if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
  echo "⏳ Still running (pid ${PID}). Last log lines:"
  tail -n 15 "$LOG" 2>/dev/null
  exit 75
fi

# Process is gone. Give the exit-file write a brief grace window in case this
# call landed exactly as the wrapper's last two lines were executing.
for _ in 1 2 3; do
  [ -f "$EXITFILE" ] && break
  sleep 1
done

if [ ! -f "$EXITFILE" ]; then
  echo "❌ Merge process ended but no exit code was recorded — treat as failed."
  echo "Last log lines:"
  tail -n 40 "$LOG" 2>/dev/null
  rm -f "$PIDFILE" "$RUNSCRIPT"
  exit 1
fi

CODE=$(cat "$EXITFILE" 2>/dev/null || echo 1)
echo "Merge finished with exit code ${CODE}. Last log lines:"
tail -n 40 "$LOG" 2>/dev/null

rm -f "$PIDFILE" "$EXITFILE" "$RUNSCRIPT"
exit "$CODE"
