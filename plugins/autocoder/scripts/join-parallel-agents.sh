#!/bin/bash
# Join an existing parallel agent tmux session
# Usage: join-parallel-agents.sh [session_name]

# Check for required dependencies
if ! command -v tmux &> /dev/null; then
  echo "❌ Error: tmux is not installed" >&2
  echo "" >&2
  echo "tmux is required for parallel agent sessions." >&2
  echo "" >&2
  echo "Install tmux:" >&2
  echo "  Ubuntu/Debian:  sudo apt-get install tmux" >&2
  echo "  Fedora/RHEL:    sudo dnf install tmux" >&2
  echo "  macOS:          brew install tmux" >&2
  echo "  Arch Linux:     sudo pacman -S tmux" >&2
  echo "" >&2
  exit 1
fi

# Get session name from argument or auto-detect from current directory
if [ -n "$1" ]; then
  SESSION_NAME="$1"
else
  PROJECT_NAME=$(basename "$(pwd)")
  SESSION_NAME="claude-${PROJECT_NAME}"
fi

# Check if the session exists
if ! tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
  echo "❌ Session '$SESSION_NAME' not found"
  echo ""

  # List available Claude Code sessions
  CLAUDE_SESSIONS=$(tmux list-sessions 2>/dev/null | grep "^claude-" || true)

  if [ -n "$CLAUDE_SESSIONS" ]; then
    echo "📋 Available Claude Code sessions:"
    echo "$CLAUDE_SESSIONS" | sed 's/^/   /'
    echo ""
    echo "💡 To join a specific session:"
    echo "   join-parallel-agents.sh <session_name>"
  else
    echo "No Claude Code parallel agent sessions found."
    echo ""
    echo "💡 To start a new session:"
    echo "   start-parallel-agents.sh [num_agents]"
  fi

  exit 1
fi

# Attach to the session
echo "🔗 Joining session: $SESSION_NAME"
tmux attach-session -t "$SESSION_NAME"
