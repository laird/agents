#!/bin/bash
# claude-worker-loop.sh — runs gate + fix in separate Claude processes so each issue
# starts with a clean context window (new process = no accumulated conversation history).
#
# The gate writes the claimed issue number to AUTOCODER_NEXT_FIX_FILE; this loop reads
# it and starts a fresh 'claude' process for the fix. Workers are visible as the tmux
# pane that runs this script, so the user can inspect, interrupt, or unstick them.
#
# Both Claude invocations run HEADLESS (`-p`). That is load-bearing: without it,
# `claude <prompt>` opens an interactive REPL that never exits, so the loop blocks
# forever on the gate and never reaches the handoff check below. The gate keeps
# ticking inside that live session, claiming and re-claiming issues that no fix
# process ever picks up — three workers wedged this way for four hours while
# looking, from the outside, exactly like workers that were busy.
#
# Headless alone would trade that failure for a silent pane, so the stream is
# rendered event-by-event through stream-render.sh and tee'd raw to a per-session
# JSONL log. A watching human sees each tool call as it happens; a post-mortem
# gets the full transcript.
#
# Usage:
#   WORKER_MODEL=claude-sonnet-5 bash claude-worker-loop.sh [--sleep MINUTES] [--model MODEL]
#
# Environment:
#   WORKER_MODEL          Claude model for this worker (default: claude-sonnet-5)
#   IDLE_SLEEP_MINUTES    Minutes to sleep when no work is found (default: 4)
#   ISSUE_SOURCE          Issue backend (file|github|jira|ado), passed through to Claude
#   ISSUE_DIR_PATH        Path to .issues/ directory, passed through to Claude
#   AUTOCODER_LOG_DIR     Where raw stream-json transcripts land (default: /tmp/autocoder-logs)
#   AUTOCODER_STREAM      0 to disable streaming output entirely (plain -p text)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER_MODEL="${WORKER_MODEL:-claude-sonnet-5}"
IDLE_SLEEP_MINUTES="${IDLE_SLEEP_MINUTES:-4}"
# Unique handoff file per worker process to avoid collisions in parallel swarms
HANDOFF_FILE="/tmp/autocoder-next-fix-$$.txt"
LOG_DIR="${AUTOCODER_LOG_DIR:-/tmp/autocoder-logs}"
STREAM="${AUTOCODER_STREAM:-1}"

while [[ $# -gt 0 ]]; do
  case $1 in
    --sleep)   IDLE_SLEEP_MINUTES="$2"; shift 2 ;;
    --model)   WORKER_MODEL="$2"; shift 2 ;;
    *)         shift ;;
  esac
done

RENDER="$SCRIPT_DIR/stream-render.sh"
[ -x "$RENDER" ] || STREAM=0
mkdir -p "$LOG_DIR"

# Run one headless Claude session. $1 labels the log file; the rest is the prompt.
# stderr deliberately bypasses the renderer so a crash message reaches the pane raw.
run_claude() {
  local label="$1"; shift
  local log="$LOG_DIR/worker-$$-${label}-$(date +%H%M%S).jsonl"
  # `< /dev/null` on both: the prompt is an argument, so claude has no use for
  # stdin, and without it it stalls 3s per session waiting for piped input and
  # competes with the loop for the pane's keyboard. Ctrl-C still reaches it.
  if [ "$STREAM" = "1" ]; then
    echo "   ⤷ transcript: $log"
    claude -p --output-format stream-json --verbose \
      --dangerously-skip-permissions --model "$WORKER_MODEL" "$@" < /dev/null \
      | tee "$log" | "$RENDER" || true
  else
    claude -p --dangerously-skip-permissions --model "$WORKER_MODEL" "$@" < /dev/null || true
  fi
}

echo "🔄 Worker loop starting"
echo "   Model:      $WORKER_MODEL"
echo "   Idle sleep: ${IDLE_SLEEP_MINUTES}m"
echo "   PID:        $$"
echo "   Handoff:    $HANDOFF_FILE"
echo "   Logs:       $LOG_DIR (streaming: $STREAM)"
echo ""

cleanup() {
  rm -f "$HANDOFF_FILE"
}
trap cleanup EXIT

while true; do
  rm -f "$HANDOFF_FILE"

  # Gate: fresh Claude process per tick. If work is found, gate writes issue# to
  # AUTOCODER_NEXT_FIX_FILE and exits 0. If idle, exits 0 without writing the file.
  echo "🚪 $(date +%H:%M:%S) gate tick"
  AUTOCODER_NEXT_FIX_FILE="$HANDOFF_FILE" \
    run_claude gate /autocoder:gate

  if [ -f "$HANDOFF_FILE" ]; then
    ISSUE_NUM=$(cat "$HANDOFF_FILE")
    rm -f "$HANDOFF_FILE"

    if [ -n "$ISSUE_NUM" ]; then
      echo ""
      echo "🔨 $(date +%H:%M:%S) Issue #$ISSUE_NUM — starting fix in fresh Claude session..."
      echo ""
      # Fix: completely separate Claude process = clean context window
      run_claude "fix-$ISSUE_NUM" "/autocoder:fix $ISSUE_NUM"
      echo ""
      echo "✅ $(date +%H:%M:%S) Fix session for issue #$ISSUE_NUM completed"
      echo ""
    fi
    # Loop immediately back to gate — no idle sleep after completing work
  else
    # No work found — sleep before next gate tick
    echo "💤 $(date +%H:%M:%S) No work — sleeping ${IDLE_SLEEP_MINUTES}m before next check..."
    sleep $((IDLE_SLEEP_MINUTES * 60))
  fi
done
