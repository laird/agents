#!/bin/bash
# End a parallel Antigravity agent session and optionally clean up worktrees
# Usage: end-parallel-agents.sh [--keep-worktrees]

set -e

# Parse arguments
KEEP_WORKTREES=false

for arg in "$@"; do
  case $arg in
    --keep-worktrees)
      KEEP_WORKTREES=true
      shift
      ;;
  esac
done

PROJECT_ROOT=$(pwd)
PROJECT_NAME=$(basename "$PROJECT_ROOT")

echo "🛑 Ending parallel agent session for: $PROJECT_NAME"
echo ""

# Check for session configuration file
CONFIG_FILE=".agent/parallel-workspaces.json"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "⚠️  No parallel session configuration found"
  echo "   (Expected: $CONFIG_FILE)"
  echo ""
  echo "💡 Session may have already been cleaned up or never started"
  exit 1
fi

# Get session info
SESSION_ID=$(jq -r '.session_id' "$CONFIG_FILE" 2>/dev/null || echo "unknown")
echo "📋 Session ID: $SESSION_ID"
echo ""

# Note about manual Antigravity cleanup
echo "ℹ️  Antigravity workspace cleanup:"
echo "   Close workspace windows manually in Antigravity GUI"
echo ""

# Remove configuration file
rm -f "$CONFIG_FILE"
echo "✅ Removed session configuration"

# Find and offer to clean up worktrees
if [ "$KEEP_WORKTREES" = false ]; then
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
      read -p "Delete worktree branches (*-wt-*)? [y/N] " -n 1 -r
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
echo "✅ Session ended: $PROJECT_NAME"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
