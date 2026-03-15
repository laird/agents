#!/bin/bash
# Stop parallel AI agent sessions
# Supports both tmux and cmux multiplexers
#
# Usage: stop-parallel-agents.sh [options]
#
# Options:
#   --mux tmux|cmux  Terminal multiplexer to use (default: auto-detect)

set -e

MUX=""

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --mux)
      MUX="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: stop-parallel-agents.sh [options]"
      echo ""
      echo "Options:"
      echo "  --mux tmux|cmux  Terminal multiplexer (default: auto-detect)"
      echo ""
      echo "Stops all parallel agent sessions for the current project."
      exit 0
      ;;
    *)
      echo "❌ Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

# Auto-detect multiplexer if not specified
if [ -z "$MUX" ]; then
  if command -v cmux &> /dev/null; then
    MUX="cmux"
  elif command -v tmux &> /dev/null; then
    MUX="tmux"
  else
    echo "❌ Error: No terminal multiplexer found" >&2
    exit 1
  fi
fi

PROJECT_NAME=$(basename "$(pwd)")

# ============================================================================
# TMUX MODE
# ============================================================================
if [ "$MUX" = "tmux" ]; then

  # Try both claude- and gemini- prefixed sessions
  KILLED=false
  for PREFIX in claude gemini; do
    SESSION_NAME="${PREFIX}-${PROJECT_NAME}"
    if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
      echo "🛑 Killing tmux session: $SESSION_NAME"
      tmux kill-session -t "$SESSION_NAME"
      KILLED=true
    fi
  done

  if [ "$KILLED" = false ]; then
    echo "No parallel agent sessions found for $PROJECT_NAME"
    echo ""
    # Show any agent sessions that do exist
    AGENT_SESSIONS=$(tmux list-sessions 2>/dev/null | grep -E "^(claude|gemini)-" || true)
    if [ -n "$AGENT_SESSIONS" ]; then
      echo "📋 Other agent sessions:"
      echo "$AGENT_SESSIONS" | sed 's/^/   /'
    fi
  else
    echo "✅ Done"
  fi

# ============================================================================
# CMUX MODE
# ============================================================================
elif [ "$MUX" = "cmux" ]; then

  if ! cmux ping &>/dev/null; then
    echo "❌ cmux is not running"
    exit 1
  fi

  # Get all workspaces as JSON and find ones matching our project
  # Worker workspaces are named "wt<N>-<project>", manager is "<project>"
  WORKSPACES_TO_CLOSE=$(cmux --json list-workspaces 2>/dev/null | python3 -c "
import sys, json

project = '$PROJECT_NAME'
data = json.load(sys.stdin)

# Handle both list-of-dicts and other formats
workspaces = data if isinstance(data, list) else data.get('workspaces', [])

for ws in workspaces:
    title = ws.get('title', ws.get('name', ''))
    ref = ws.get('ref', '')
    ws_id = ws.get('id', '')

    # Match: wt<N>-<project> (workers) or exact <project> (manager)
    if title == project or (title.startswith('wt') and title.endswith('-' + project)):
        # Prefer ref, fall back to id
        identifier = ref if ref else ws_id
        if identifier:
            print(f'{identifier}\t{title}')
" 2>/dev/null || true)

  if [ -z "$WORKSPACES_TO_CLOSE" ]; then
    echo "No parallel agent workspaces found for $PROJECT_NAME"
    echo ""
    echo "📋 Current workspaces:"
    cmux list-workspaces 2>/dev/null || true
    exit 0
  fi

  echo "🛑 Closing agent workspaces for $PROJECT_NAME..."
  echo ""

  CLOSED=0
  while IFS=$'\t' read -r ws_ref ws_title; do
    echo "   Closing: $ws_title ($ws_ref)"
    cmux close-workspace --workspace "$ws_ref" >/dev/null 2>&1 || echo "   ⚠️  Failed to close $ws_ref"
    CLOSED=$((CLOSED + 1))
    sleep 0.5
  done <<< "$WORKSPACES_TO_CLOSE"

  echo ""
  echo "✅ Closed $CLOSED workspace(s)"

fi
