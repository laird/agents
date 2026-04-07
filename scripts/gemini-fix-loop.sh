#!/bin/bash
# Run the Gemini (Antigravity) autocoder workflow repeatedly using shell control.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

usage() {
  echo "Usage: $0 [--issue N] [--sleep MINUTES] [--max-iterations N]"
}

ISSUE_NUMBER=""
SLEEP_MINUTES=15
MAX_ITERATIONS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --issue)
      ISSUE_NUMBER="$2"
      shift 2
      ;;
    --sleep)
      SLEEP_MINUTES="$2"
      shift 2
      ;;
    --max-iterations)
      MAX_ITERATIONS="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "❌ Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
  echo "❌ Must be run inside a git repository" >&2
  exit 1
fi

REPO_ROOT=$(git rev-parse --show-toplevel)
STATE_DIR="$REPO_ROOT/.codex/loops"
STOP_FILE="$STATE_DIR/fix-loop.stop"
STATUS_FILE="$STATE_DIR/fix-loop.status"
DISPATCH_FILE="$STATE_DIR/fix-loop.dispatch"
mkdir -p "$STATE_DIR"
rm -f "$STOP_FILE"

ITERATION=0

set_status() {
  printf '%s\t%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" > "$STATUS_FILE"
}

sleep_until_next_cycle() {
  local remaining_seconds=$((SLEEP_MINUTES * 60))
  while [ "$remaining_seconds" -gt 0 ]; do
    if [ -f "$STOP_FILE" ] || [ -s "$DISPATCH_FILE" ]; then
      return
    fi
    sleep 5
    remaining_seconds=$((remaining_seconds - 5))
  done
}

echo "🔄 Starting Gemini fix loop"
echo "FIX_LOOP_STARTED"
echo "   Repo: $REPO_ROOT"
echo "   Sleep: ${SLEEP_MINUTES}m"
if [ -n "$ISSUE_NUMBER" ]; then
  echo "   Target issue: #$ISSUE_NUMBER"
fi
if [ "$MAX_ITERATIONS" -gt 0 ]; then
  echo "   Max iterations: $MAX_ITERATIONS"
fi
echo "   Stop file: $STOP_FILE"
echo ""
set_status "starting"

while true; do
  if [ -f "$STOP_FILE" ]; then
    echo "🛑 Stop file detected, ending Gemini fix loop"
    break
  fi

  RUN_ISSUE_NUMBER="$ISSUE_NUMBER"
  DISPATCHED_ISSUE=false
  if [ -z "$RUN_ISSUE_NUMBER" ] && [ -s "$DISPATCH_FILE" ]; then
    RUN_ISSUE_NUMBER=$(tr -d '[:space:]' < "$DISPATCH_FILE")
    rm -f "$DISPATCH_FILE"
    DISPATCHED_ISSUE=true
    echo "🎯 Received dispatched issue #$RUN_ISSUE_NUMBER"
  fi

  ITERATION=$((ITERATION + 1))
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Iteration $ITERATION"
  if [ -n "$RUN_ISSUE_NUMBER" ]; then
    set_status "working issue #$RUN_ISSUE_NUMBER"
  else
    set_status "working next available issue"
  fi

  OUTPUT_FILE=$(mktemp)
  if [ -n "$RUN_ISSUE_NUMBER" ]; then
    bash "$SCRIPT_DIR/gemini-autocoder.sh" fix "$RUN_ISSUE_NUMBER" | tee "$OUTPUT_FILE"
  else
    bash "$SCRIPT_DIR/gemini-autocoder.sh" fix | tee "$OUTPUT_FILE"
  fi

  if grep -q '^IDLE_NO_WORK_AVAILABLE$' "$OUTPUT_FILE"; then
    set_status "idle"
    echo "GEMINI_FIX_LOOP_IDLE"
    if [ "$MAX_ITERATIONS" -gt 0 ] && [ "$ITERATION" -ge "$MAX_ITERATIONS" ]; then
      rm -f "$OUTPUT_FILE"
      break
    fi
    rm -f "$OUTPUT_FILE"
    sleep_until_next_cycle
    continue
  fi

  rm -f "$OUTPUT_FILE"

  if [ -n "$ISSUE_NUMBER" ]; then
    set_status "completed targeted issue #$ISSUE_NUMBER"
    echo "✅ Targeted issue pass complete"
    break
  fi

  if [ "$DISPATCHED_ISSUE" = true ]; then
    set_status "completed dispatched issue #$RUN_ISSUE_NUMBER"
  else
    set_status "completed pass"
  fi

  if [ "$MAX_ITERATIONS" -gt 0 ] && [ "$ITERATION" -ge "$MAX_ITERATIONS" ]; then
    break
  fi

  sleep 5
done

set_status "stopped"
echo "✅ Gemini fix loop stopped"
