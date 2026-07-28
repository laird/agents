#!/bin/bash
# claude-worker-loop.sh — runs gate + fix in separate Claude processes so each issue
# starts with a clean context window (new process = no accumulated conversation history).
#
# The gate writes the claimed issue number to AUTOCODER_NEXT_FIX_FILE; this loop reads
# it and starts a fresh 'claude' process for the fix. Workers are visible as the tmux
# pane that runs this script, so the user can inspect, interrupt, or unstick them.
#
# Usage:
#   WORKER_MODEL=claude-sonnet-5 bash claude-worker-loop.sh [--sleep MINUTES] [--model MODEL]
#
# Environment:
#   WORKER_MODEL          Claude model for this worker (default: claude-sonnet-5)
#   IDLE_SLEEP_MINUTES    Minutes to sleep when no work is found (default: 4)
#   ISSUE_SOURCE          Issue backend (file|github|jira), passed through to Claude
#   ISSUE_DIR_PATH        Path to .issues/ directory, passed through to Claude

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER_MODEL="${WORKER_MODEL:-claude-sonnet-5}"
IDLE_SLEEP_MINUTES="${IDLE_SLEEP_MINUTES:-4}"
# Unique handoff file per worker process to avoid collisions in parallel swarms
HANDOFF_FILE="/tmp/autocoder-next-fix-$$.txt"

while [[ $# -gt 0 ]]; do
  case $1 in
    --sleep)   IDLE_SLEEP_MINUTES="$2"; shift 2 ;;
    --model)   WORKER_MODEL="$2"; shift 2 ;;
    *)         shift ;;
  esac
done

CLAUDE_CMD="claude --dangerously-skip-permissions --model $WORKER_MODEL"

echo "🔄 Worker loop starting"
echo "   Model:      $WORKER_MODEL"
echo "   Idle sleep: ${IDLE_SLEEP_MINUTES}m"
echo "   PID:        $$"
echo "   Handoff:    $HANDOFF_FILE"
echo ""

cleanup() {
  rm -f "$HANDOFF_FILE"
}
trap cleanup EXIT

while true; do
  rm -f "$HANDOFF_FILE"

  # Gate: fresh Claude process per tick. If work is found, gate writes issue# to
  # AUTOCODER_NEXT_FIX_FILE and exits 0. If idle, exits 0 without writing the file.
  AUTOCODER_NEXT_FIX_FILE="$HANDOFF_FILE" \
    $CLAUDE_CMD /autocoder:gate || true

  if [ -f "$HANDOFF_FILE" ]; then
    ISSUE_NUM=$(cat "$HANDOFF_FILE")
    rm -f "$HANDOFF_FILE"

    if [ -n "$ISSUE_NUM" ]; then
      echo ""
      echo "🔨 Issue #$ISSUE_NUM — starting fix in fresh Claude session..."
      echo ""
      # Fix: completely separate Claude process = clean context window
      $CLAUDE_CMD "/autocoder:fix $ISSUE_NUM" || true
      echo ""
      echo "✅ Fix session for issue #$ISSUE_NUM completed"
      echo ""
    fi
    # Loop immediately back to gate — no idle sleep after completing work
  else
    # No work found — sleep before next gate tick
    echo "💤 No work — sleeping ${IDLE_SLEEP_MINUTES}m before next check..."
    sleep $((IDLE_SLEEP_MINUTES * 60))
  fi
done
