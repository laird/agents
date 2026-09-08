#!/bin/bash
# Join an existing parallel agent session
# Supports the tmux, cmux, and herdr multiplexers
#
# Usage: join-parallel-agents.sh [options] [session_name]
#
# Options:
#   --mux tmux|cmux|herdr  Terminal multiplexer to use (default: auto-detect)

SOURCE_PATH="${BASH_SOURCE[0]}"
while [ -L "$SOURCE_PATH" ]; do
  SOURCE_DIR="$(cd "$(dirname "$SOURCE_PATH")" && pwd)"
  SOURCE_PATH="$(readlink "$SOURCE_PATH")"
  [[ "$SOURCE_PATH" != /* ]] && SOURCE_PATH="$SOURCE_DIR/$SOURCE_PATH"
done
SCRIPT_DIR="$(cd "$(dirname "$SOURCE_PATH")" && pwd)"

# shellcheck source=mux-send-lib.sh
source "$SCRIPT_DIR/mux-send-lib.sh"

# Parse arguments
MUX=""
SESSION_NAME=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --mux)
      MUX="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: join-parallel-agents.sh [options] [session_name]"
      echo ""
      echo "Options:"
      echo "  --mux tmux|cmux|herdr  Terminal multiplexer (default: auto-detect)"
      echo ""
      echo "If no session name is given, auto-detects from current directory."
      exit 0
      ;;
    *)
      SESSION_NAME="$1"
      shift
      ;;
  esac
done

# Auto-detect multiplexer if not specified.
# Prefer cmux/herdr only when actually running — see cmux_is_running() /
# herdr_is_running(). Inside a herdr pane (HERDR_ENV=1), prefer herdr.
if [ -z "$MUX" ]; then
  if [ "${HERDR_ENV:-}" = "1" ] && herdr_is_running; then
    MUX="herdr"
  elif cmux_is_running; then
    MUX="cmux"
  elif herdr_is_running; then
    MUX="herdr"
  elif command -v tmux &> /dev/null; then
    MUX="tmux"
    if command -v cmux &> /dev/null; then
      echo "ℹ️  cmux installed but not running — falling back to tmux"
    fi
    if command -v herdr &> /dev/null; then
      echo "ℹ️  herdr installed but not running — falling back to tmux"
    fi
  else
    echo "❌ Error: No terminal multiplexer found" >&2
    echo "" >&2
    echo "Install one of the following:" >&2
    echo "  tmux:  brew install tmux" >&2
    echo "  cmux:  brew tap manaflow-ai/cmux && brew install --cask cmux" >&2
    echo "  herdr: https://herdr.dev" >&2
    echo "" >&2
    exit 1
  fi
fi

# Validate multiplexer choice
case "$MUX" in
  tmux|cmux|herdr)
    if ! command -v "$MUX" &> /dev/null; then
      echo "❌ Error: $MUX is not installed" >&2
      exit 1
    fi
    ;;
  *)
    echo "❌ Error: Unknown multiplexer '$MUX'. Use 'tmux', 'cmux', or 'herdr'" >&2
    exit 1
    ;;
esac

# ============================================================================
# TMUX MODE
# ============================================================================
if [ "$MUX" = "tmux" ]; then

  # Get session name from argument or auto-detect from current directory
  if [ -z "$SESSION_NAME" ]; then
    PROJECT_NAME=$(basename "$(pwd)")

    # Try known agent-prefixed sessions
    if tmux has-session -t "claude-${PROJECT_NAME}" 2>/dev/null; then
      SESSION_NAME="claude-${PROJECT_NAME}"
    elif tmux has-session -t "gemini-${PROJECT_NAME}" 2>/dev/null; then
      SESSION_NAME="gemini-${PROJECT_NAME}"
    elif tmux has-session -t "codex-${PROJECT_NAME}" 2>/dev/null; then
      SESSION_NAME="codex-${PROJECT_NAME}"
    else
      SESSION_NAME="claude-${PROJECT_NAME}"
    fi
  fi

  # Check if the session exists
  if ! tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    echo "❌ Session '$SESSION_NAME' not found"
    echo ""

    # List available agent sessions
    AGENT_SESSIONS=$(tmux list-sessions 2>/dev/null | grep -E "^(claude|gemini|codex)-" || true)

    if [ -n "$AGENT_SESSIONS" ]; then
      echo "📋 Available agent sessions (tmux):"
      echo "$AGENT_SESSIONS" | sed 's/^/   /'
      echo ""
      echo "💡 To join a specific session:"
      echo "   join-parallel-agents.sh --mux tmux <session_name>"
    else
      echo "No parallel agent sessions found in tmux."
      echo ""
      echo "💡 To start a new session:"
      echo "   start-parallel-agents.sh --mux tmux [num_agents]"
    fi

    exit 1
  fi

  # Attach to the session
  echo "🔗 Joining session: $SESSION_NAME (tmux)"
  tmux attach-session -t "$SESSION_NAME"

# ============================================================================
# CMUX MODE
# ============================================================================
elif [ "$MUX" = "cmux" ]; then

  # Verify cmux is running
  if ! cmux ping &>/dev/null; then
    echo "❌ Error: cmux is not running" >&2
    echo "   Please launch cmux.app first" >&2
    exit 1
  fi

  echo "📋 cmux Workspaces:"
  echo ""

  # List all workspaces
  cmux list-workspaces

  # If a session name was provided, try to select that workspace
  if [ -n "$SESSION_NAME" ]; then
    echo ""
    echo "🔗 Selecting workspace matching: $SESSION_NAME"
    # Try using find-window to locate it
    cmux find-window --select "$SESSION_NAME" 2>/dev/null || \
      echo "⚠️  No workspace matching '$SESSION_NAME' found"
  fi

  echo ""
  echo "🔧 Useful cmux commands:"
  echo "   List workspaces:  cmux list-workspaces"
  echo "   Select workspace: cmux select-workspace --workspace <ref>"
  echo "   List panes:       cmux list-panes --workspace <ref>"
  echo "   Read screen:      cmux read-screen --workspace <ref>"
  echo "   Send text:        cmux send --workspace <ref> \"text\""
  echo "   Send enter:       cmux send-key --workspace <ref> enter"
  echo ""

# ============================================================================
# HERDR MODE
# ============================================================================
elif [ "$MUX" = "herdr" ]; then

  if ! herdr_is_running; then
    echo "❌ Error: no herdr server is running" >&2
    echo "   Launch herdr first (run \`herdr\` or \`herdr server\`)" >&2
    exit 1
  fi

  echo "📋 herdr Workspaces:"
  echo ""

  # Pretty-print the workspace list (label + workspace id)
  herdr workspace list 2>/dev/null | python3 -c '
import json, sys
data = json.load(sys.stdin)
for ws in data.get("result", {}).get("workspaces", []):
    print(f"   {ws.get(\"workspace_id\",\"?\"):6} {ws.get(\"label\",\"\")}")
' || herdr workspace list

  # If a session name was provided, focus the workspace whose label matches
  if [ -n "$SESSION_NAME" ]; then
    echo ""
    echo "🔗 Focusing workspace matching: $SESSION_NAME"
    WS_ID=$(herdr workspace list 2>/dev/null | python3 -c "
import json, sys
wanted = '$SESSION_NAME'
data = json.load(sys.stdin)
for ws in data.get('result', {}).get('workspaces', []):
    if wanted in ws.get('label', ''):
        print(ws.get('workspace_id', ''))
        break
" 2>/dev/null)
    if [ -n "$WS_ID" ]; then
      herdr workspace focus "$WS_ID" >/dev/null 2>&1 || true
    else
      echo "⚠️  No workspace matching '$SESSION_NAME' found"
    fi
  fi

  echo ""
  echo "🔧 Useful herdr commands:"
  echo "   List workspaces:  herdr workspace list"
  echo "   Focus workspace:  herdr workspace focus <workspace-id>"
  echo "   Read screen:      herdr pane read <pane-id>"
  echo "   Send text:        herdr pane send-text <pane-id> \"text\""
  echo "   Send enter:       herdr pane send-keys <pane-id> enter"
  echo "   Attach TUI:       herdr"
  echo ""

fi
