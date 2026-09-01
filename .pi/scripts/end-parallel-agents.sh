#!/bin/bash
# End a parallel agent tmux session and optionally clean up worktrees
# Usage: end-parallel-agents.sh [session_name] [--keep-worktrees]

set -e

# Parse arguments
SESSION_NAME=""
KEEP_WORKTREES=false

for arg in "$@"; do
  case $arg in
    --keep-worktrees)
      KEEP_WORKTREES=true
      shift
      ;;
    *)
      if [ -z "$SESSION_NAME" ]; then
        SESSION_NAME="$arg"
      fi
      shift
      ;;
  esac
done

# Check for required dependencies
if ! command -v tmux &> /dev/null; then
  echo "❌ Error: tmux is not installed" >&2
  exit 1
fi

# Get session name from argument or auto-detect from current directory
if [ -z "$SESSION_NAME" ]; then
  PROJECT_NAME=$(basename "$(pwd)")
  SESSION_NAME="claude-${PROJECT_NAME}"
fi

# Check if the session exists
if ! tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
  echo "⚠️  Session '$SESSION_NAME' not found"
  echo ""

  # List available Claude Code sessions
  CLAUDE_SESSIONS=$(tmux list-sessions 2>/dev/null | grep "^claude-" || true)

  if [ -n "$CLAUDE_SESSIONS" ]; then
    echo "📋 Available Claude Code sessions:"
    echo "$CLAUDE_SESSIONS" | sed 's/^/   /'
    echo ""
    echo "💡 To end a specific session:"
    echo "   end-parallel-agents.sh <session_name>"
  else
    echo "No Claude Code parallel agent sessions running."
  fi

  exit 1
fi

echo "🛑 Ending parallel agent session: $SESSION_NAME"
echo ""

# Kill the tmux session
tmux kill-session -t "$SESSION_NAME"
echo "✅ Tmux session terminated"

# Find and offer to clean up worktrees
if [ "$KEEP_WORKTREES" = false ]; then
  PROJECT_ROOT=$(pwd)

  # Find worktrees matching the pattern
  WORKTREES=$(git worktree list 2>/dev/null | grep "${PROJECT_ROOT}-wt-" || true)

  if [ -n "$WORKTREES" ]; then
    echo ""
    echo "📁 Found worktrees associated with this session:"
    echo "$WORKTREES" | sed 's/^/   /'
    echo ""

    read -p "Remove these worktrees? [y/N] " -n 1 -r
    echo

    if [[ $REPLY =~ ^[Yy]$ ]]; then
      echo ""
      echo "🗑️  Removing worktrees..."

      # Extract worktree paths and remove them
      echo "$WORKTREES" | while read -r worktree_line; do
        WORKTREE_PATH=$(echo "$worktree_line" | awk '{print $1}')

        if [ -d "$WORKTREE_PATH" ]; then
          echo "   Removing: $WORKTREE_PATH"
          git worktree remove "$WORKTREE_PATH" --force 2>/dev/null || true
        fi
      done

      echo "✅ Worktrees removed"
      echo ""

      # Ask about cleaning up worktree branches
      read -p "Delete worktree branches (parallel-wt-*, *-wt-*)? [y/N] " -n 1 -r
      echo

      if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo ""
        echo "🗑️  Removing worktree branches..."

        # Delete branches matching worktree pattern
        git branch | grep -E "wt-[0-9]+$" | while read -r branch; do
          branch=$(echo "$branch" | xargs)  # trim whitespace
          echo "   Deleting: $branch"
          git branch -D "$branch" 2>/dev/null || true
        done

        echo "✅ Worktree branches removed"
      fi
    else
      echo ""
      echo "ℹ️  Worktrees preserved (can be manually removed later)"
      echo ""
      echo "💡 To remove worktrees manually:"
      echo "   git worktree list"
      echo "   git worktree remove <path>"
    fi
  fi
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Session ended: $SESSION_NAME"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
