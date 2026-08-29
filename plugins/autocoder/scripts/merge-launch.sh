#!/bin/bash
# merge-launch.sh — start merge-to-integration.sh fully DETACHED (#1693).
#
# WHY THIS EXISTS:
#   merge-to-integration.sh legitimately takes 25-30 minutes (it re-runs the
#   full regression gate on the combined tree). The /fix workflow used to
#   invoke it directly inside one foreground Bash-tool call, which agent
#   harnesses kill at a ~2-minute default timeout — a guaranteed failure, not
#   a flake. The kill sometimes tears down the merge script outright and
#   sometimes orphans its gate subtree (reparented to init, ppid=1), left
#   running with nothing to read its exit status and contending for host CPU
#   with live merges.
#
#   This script launches merge-to-integration.sh in a brand-new session via
#   `setsid`, with stdin/stdout/stderr fully detached from the caller, so a
#   killed caller (or a killed poller — see merge-poll.sh) can never take the
#   merge subtree down with it. It returns almost immediately; the caller
#   polls with merge-poll.sh.
#
# DUPLICATE DETECTION:
#   Refuses to start a second merge for the same issue while one is already
#   running — the caller should poll the existing job (merge-poll.sh) instead.
#   This makes re-entering this step after a restart/crash safe: launching
#   again is a no-op that just points back at the in-flight job.
#
# USAGE:
#   merge-launch.sh --feature <branch> --issue <num> \
#     [--integration <branch>] [--test-cmd "<cmd>"]
#
# State files (keyed by issue number, since only one worker holds an issue's
# `working` lock at a time so this is unique per in-flight merge):
#   /tmp/autocoder-merge-<issue>.pid   — PID of the detached run
#   /tmp/autocoder-merge-<issue>.log   — merge-to-integration.sh output
#   /tmp/autocoder-merge-<issue>.exit  — its exit code, written on completion
#   /tmp/autocoder-merge-<issue>.run.sh — generated wrapper (avoids nested-quote hell)
#
# Exit codes:
#   0  launched (or an equivalent job was already running) — poll with merge-poll.sh
#   1  bad arguments
set -uo pipefail

FEATURE=""
ISSUE_NUM=""
INTEGRATION_BRANCH="main"
TEST_CMD=""

while [ $# -gt 0 ]; do
  case "$1" in
    --feature)     FEATURE="$2"; shift 2 ;;
    --issue)       ISSUE_NUM="$2"; shift 2 ;;
    --integration) INTEGRATION_BRANCH="${2:-main}"; shift 2 ;;
    --test-cmd)    TEST_CMD="$2"; shift 2 ;;
    *) echo "merge-launch.sh: unknown arg '$1'" >&2; exit 1 ;;
  esac
done

if [ -z "$FEATURE" ] || [ -z "$ISSUE_NUM" ]; then
  echo "merge-launch.sh: --feature and --issue are required" >&2
  exit 1
fi
: "${INTEGRATION_BRANCH:=main}"

_MLI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="/tmp/autocoder-merge-${ISSUE_NUM}.log"
PIDFILE="/tmp/autocoder-merge-${ISSUE_NUM}.pid"
EXITFILE="/tmp/autocoder-merge-${ISSUE_NUM}.exit"
RUNSCRIPT="/tmp/autocoder-merge-${ISSUE_NUM}.run.sh"

if [ -f "$PIDFILE" ]; then
  OLD_PID=$(cat "$PIDFILE" 2>/dev/null || echo "")
  if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    echo "ℹ️  A merge for issue #${ISSUE_NUM} is already running (pid ${OLD_PID}) — not starting a duplicate."
    echo "   Poll it with: ${_MLI_DIR}/merge-poll.sh --issue ${ISSUE_NUM}"
    exit 0
  fi
  # Stale pidfile from a finished/dead run — clear state before relaunching.
  rm -f "$PIDFILE" "$EXITFILE" "$RUNSCRIPT"
fi

: > "$LOG"
rm -f "$EXITFILE"

# Generate a real wrapper script rather than nesting this into a `bash -c`
# string: --test-cmd carries its own quoting-heavy shell (&&, quoted env vars,
# pipes), and re-quoting that into another layer of quotes is exactly the kind
# of fragility this fix is trying to remove. printf %q escapes it once, safely.
{
  printf '#!/bin/bash\n'
  printf 'echo $$ > %q\n' "$PIDFILE"
  printf '%q --feature %q --issue %q --integration %q --test-cmd %q > %q 2>&1\n' \
    "${_MLI_DIR}/merge-to-integration.sh" "$FEATURE" "$ISSUE_NUM" "$INTEGRATION_BRANCH" "$TEST_CMD" "$LOG"
  printf 'echo $? > %q\n' "$EXITFILE"
} > "$RUNSCRIPT"
chmod +x "$RUNSCRIPT"

setsid "$RUNSCRIPT" < /dev/null > /dev/null 2>&1 &
disown 2>/dev/null || true

# The pidfile is written by the wrapper itself (via $$, immune to any
# uncertainty about what `$!` refers to across setsid's fork-or-exec cases);
# give it a moment to land before returning.
for _ in 1 2 3 4 5; do
  [ -f "$PIDFILE" ] && break
  sleep 0.2
done

echo "🚀 merge-to-integration.sh launched detached for issue #${ISSUE_NUM}."
echo "   Log:  ${LOG}"
echo "   Poll: ${_MLI_DIR}/merge-poll.sh --issue ${ISSUE_NUM}"
exit 0
