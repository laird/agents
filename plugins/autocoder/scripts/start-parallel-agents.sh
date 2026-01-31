#!/bin/bash
# Start parallel Claude Code agents using tmux and git worktrees
# Usage: start-parallel-agents.sh [num_agents] [--no-worktrees]

set -e

# Check for required dependencies
if ! command -v tmux &> /dev/null; then
  echo "❌ Error: tmux is not installed" >&2
  echo "" >&2
  echo "tmux is required for running parallel agents." >&2
  echo "" >&2
  echo "Install tmux:" >&2
  echo "  Ubuntu/Debian:  sudo apt-get install tmux" >&2
  echo "  Fedora/RHEL:    sudo dnf install tmux" >&2
  echo "  macOS:          brew install tmux" >&2
  echo "  Arch Linux:     sudo pacman -S tmux" >&2
  echo "" >&2
  exit 1
fi

if ! command -v claude &> /dev/null; then
  echo "❌ Error: claude command is not installed" >&2
  echo "" >&2
  echo "Claude Code CLI is required." >&2
  echo "" >&2
  echo "Install Claude Code:" >&2
  echo "  Visit: https://claude.ai/download" >&2
  echo "" >&2
  exit 1
fi

# Parse arguments
NUM_AGENTS="${1:-3}"
USE_WORKTREES=true

for arg in "$@"; do
  case $arg in
    --no-worktrees)
      USE_WORKTREES=false
      shift
      ;;
    [0-9]*)
      NUM_AGENTS="$arg"
      shift
      ;;
  esac
done

# Validate we're in a git repo (if using worktrees)
if [ "$USE_WORKTREES" = true ]; then
  if ! git rev-parse --git-dir > /dev/null 2>&1; then
    echo "❌ Error: Not in a git repository" >&2
    echo "   Use --no-worktrees flag to run without git worktrees" >&2
    exit 1
  fi
fi

# Get project info
PROJECT_ROOT=$(pwd)
PROJECT_NAME=$(basename "$PROJECT_ROOT")
SESSION_NAME="claude-${PROJECT_NAME}"
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")

# Generate shared task list ID for coordination
TASK_LIST_ID="parallel-$(date +%Y%m%d-%H%M%S)"

echo "🚀 Starting parallel agent system"
echo "   Project: $PROJECT_NAME"
echo "   Main path: $PROJECT_ROOT"
echo "   Num agents: $NUM_AGENTS"
echo "   Task list ID: $TASK_LIST_ID"
echo "   Branch: $CURRENT_BRANCH"
echo ""

# Check if session already exists
if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
  echo "⚠️  Session '$SESSION_NAME' already exists"
  echo "   Attaching to existing session..."
  tmux attach-session -t "$SESSION_NAME"
  exit 0
fi

# Create worktrees if needed
WORKTREE_PATHS=()

if [ "$USE_WORKTREES" = true ]; then
  echo "📁 Setting up git worktrees..."

  for i in $(seq 1 $((NUM_AGENTS - 1))); do
    WORKTREE_PATH="${PROJECT_ROOT}-wt-${i}"
    WORKTREE_BRANCH="${CURRENT_BRANCH}-wt-${i}"

    if [ -d "$WORKTREE_PATH" ]; then
      echo "   ✓ Worktree already exists: $WORKTREE_PATH"
    else
      echo "   Creating worktree: $WORKTREE_PATH"

      # Create branch if it doesn't exist
      if ! git show-ref --verify --quiet "refs/heads/$WORKTREE_BRANCH"; then
        git branch "$WORKTREE_BRANCH" "$CURRENT_BRANCH"
      fi

      git worktree add "$WORKTREE_PATH" "$WORKTREE_BRANCH"
    fi

    WORKTREE_PATHS+=("$WORKTREE_PATH")
  done
  echo ""
else
  echo "⚠️  Running without worktrees (all agents in same directory)"
  echo ""
fi

# Create tmux session with first window (parallel agents)
echo "🖥️  Creating tmux session: $SESSION_NAME"
tmux new-session -d -s "$SESSION_NAME" -n "agents"

# Main pane (leftmost) - coordinator in main repo
echo "   Setting up main agent (coordinator)..."
tmux send-keys -t "$SESSION_NAME:0.0" "cd '$PROJECT_ROOT'" C-m
tmux send-keys -t "$SESSION_NAME:0.0" "export CLAUDE_CODE_TASK_LIST_ID='$TASK_LIST_ID'" C-m
tmux send-keys -t "$SESSION_NAME:0.0" "export CLAUDE_CODE_INTEGRATION_BRANCH='$CURRENT_BRANCH'" C-m

# Create panes for workers
for i in $(seq 1 $((NUM_AGENTS - 1))); do
  echo "   Setting up worker agent $i..."
  tmux split-window -h -t "$SESSION_NAME:0"

  if [ "$USE_WORKTREES" = true ]; then
    WORKTREE_PATH="${WORKTREE_PATHS[$((i-1))]}"
    tmux send-keys -t "$SESSION_NAME:0.$i" "cd '$WORKTREE_PATH'" C-m
  else
    tmux send-keys -t "$SESSION_NAME:0.$i" "cd '$PROJECT_ROOT'" C-m
  fi

  tmux send-keys -t "$SESSION_NAME:0.$i" "export CLAUDE_CODE_TASK_LIST_ID='$TASK_LIST_ID'" C-m
done

# Balance the panes to make them equal width
tmux select-layout -t "$SESSION_NAME:0" even-horizontal

# Launch Claude Code in each pane
echo ""
echo "🤖 Starting Claude Code sessions..."

for i in $(seq 0 $((NUM_AGENTS - 1))); do
  tmux send-keys -t "$SESSION_NAME:0.$i" "claude code --dangerously-skip-permissions ." C-m
done

# Wait for Claude Code to initialize
echo "   Waiting for Claude Code to initialize (5 seconds)..."
sleep 5

# Send /fix-loop command to all agents
echo "   Starting /fix-loop in all agents..."
for i in $(seq 0 $((NUM_AGENTS - 1))); do
  tmux send-keys -t "$SESSION_NAME:0.$i" "/fix-loop" C-m
done

# Create second window for review/planning (single pane)
echo ""
echo "📋 Setting up review/planning window..."
tmux new-window -t "$SESSION_NAME:1" -n "review"

# Set up review window
tmux send-keys -t "$SESSION_NAME:1.0" "cd '$PROJECT_ROOT'" C-m
tmux send-keys -t "$SESSION_NAME:1.0" "export CLAUDE_CODE_TASK_LIST_ID='$TASK_LIST_ID'" C-m
tmux send-keys -t "$SESSION_NAME:1.0" "claude code --dangerously-skip-permissions ." C-m

# Wait for Claude Code to initialize in review window
sleep 3
tmux send-keys -t "$SESSION_NAME:1.0" "/review-blocked" C-m

# Select the first window (agents) by default
tmux select-window -t "$SESSION_NAME:0"

echo ""
echo "✅ Parallel agent system started!"
echo ""
echo "📊 Session Info:"
echo "   Session name: $SESSION_NAME"
echo "   Task list ID: $TASK_LIST_ID"
echo "   Window 0: $NUM_AGENTS parallel agents running /fix-loop"
echo "   Window 1: Review/planning agent running /review-blocked"
echo ""
echo "🔧 Useful tmux commands:"
echo "   Switch windows: Ctrl+b then 0 or 1"
echo "   Detach: Ctrl+b then d"
echo "   Reattach: tmux attach -t $SESSION_NAME"
echo "   Kill session: tmux kill-session -t $SESSION_NAME"
echo ""
echo "📌 To join this session later, use:"
echo "   tmux attach -t $SESSION_NAME"
echo ""

# Attach to the session
tmux attach-session -t "$SESSION_NAME"
