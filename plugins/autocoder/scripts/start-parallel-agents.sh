#!/bin/bash
# Start parallel AI agents using a terminal multiplexer and git worktrees
# Supports both tmux and cmux multiplexers, and Claude, Gemini, and Codex agent frameworks
#
# Usage: start-parallel-agents.sh [num_agents] [options]
#
# Options:
#   --mux tmux|cmux        Terminal multiplexer to use (default: auto-detect)
#   --agent claude|gemini|codex|droid  Agent framework to use (default: auto-detect)
#   --no-worktrees         Run all agents in the same directory
#
# Examples:
#   start-parallel-agents.sh 3 --mux tmux --agent claude
#   start-parallel-agents.sh 4 --mux cmux --agent gemini
#   start-parallel-agents.sh 3 --mux tmux --agent codex
#   start-parallel-agents.sh 3 --mux tmux --agent droid
#   start-parallel-agents.sh 2 --no-worktrees

set -e

SOURCE_PATH="${BASH_SOURCE[0]}"
while [ -L "$SOURCE_PATH" ]; do
  SOURCE_DIR="$(cd "$(dirname "$SOURCE_PATH")" && pwd)"
  SOURCE_PATH="$(readlink "$SOURCE_PATH")"
  [[ "$SOURCE_PATH" != /* ]] && SOURCE_PATH="$SOURCE_DIR/$SOURCE_PATH"
done

SCRIPT_DIR="$(cd "$(dirname "$SOURCE_PATH")" && pwd)"
AGENTS_REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Defaults
NUM_AGENTS=3
USE_WORKTREES=true
MUX=""
AGENT=""

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --mux)
      MUX="$2"
      shift 2
      ;;
    --agent)
      AGENT="$2"
      shift 2
      ;;
    --no-worktrees)
      USE_WORKTREES=false
      shift
      ;;
    [0-9]*)
      NUM_AGENTS="$1"
      shift
      ;;
    -h|--help)
      echo "Usage: start-parallel-agents.sh [num_agents] [options]"
      echo ""
      echo "Options:"
      echo "  --mux tmux|cmux        Terminal multiplexer (default: auto-detect)"
      echo "  --agent claude|gemini|codex|droid  Agent framework (default: auto-detect)"
      echo "  --no-worktrees         Run all agents in the same directory"
      echo ""
      echo "Examples:"
      echo "  start-parallel-agents.sh 3 --mux tmux --agent claude"
      echo "  start-parallel-agents.sh 4 --mux cmux --agent gemini"
      echo "  start-parallel-agents.sh 3 --mux tmux --agent codex"
      echo "  start-parallel-agents.sh 3 --mux tmux --agent droid"
      exit 0
      ;;
    *)
      echo "❌ Unknown argument: $1" >&2
      echo "   Use --help for usage information" >&2
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
    echo "" >&2
    echo "Install one of the following:" >&2
    echo "  tmux:  brew install tmux" >&2
    echo "  cmux:  brew tap manaflow-ai/cmux && brew install --cask cmux" >&2
    echo "" >&2
    exit 1
  fi
fi

# Validate multiplexer choice
case "$MUX" in
  tmux|cmux)
    if ! command -v "$MUX" &> /dev/null; then
      echo "❌ Error: $MUX is not installed" >&2
      exit 1
    fi
    ;;
  *)
    echo "❌ Error: Unknown multiplexer '$MUX'. Use 'tmux' or 'cmux'" >&2
    exit 1
    ;;
esac

# Auto-detect agent framework if not specified
if [ -z "$AGENT" ]; then
  if command -v claude &> /dev/null; then
    AGENT="claude"
  elif command -v gemini &> /dev/null; then
    AGENT="gemini"
  elif command -v codex &> /dev/null; then
    AGENT="codex"
  elif command -v droid &> /dev/null; then
    AGENT="droid"
  else
    echo "❌ Error: No agent framework found" >&2
    echo "" >&2
    echo "Install one of the following:" >&2
    echo "  Claude Code: https://claude.ai/download" >&2
    echo "  Gemini CLI:  https://github.com/google-gemini/gemini-cli" >&2
    echo "  Codex CLI:   codex" >&2
    echo "  Droid CLI:   https://docs.factory.ai/" >&2
    echo "" >&2
    exit 1
  fi
fi

# Validate agent choice and set launch command
case "$AGENT" in
  claude)
    if ! command -v claude &> /dev/null; then
      echo "❌ Error: claude command is not installed" >&2
      echo "   Install Claude Code: https://claude.ai/download" >&2
      exit 1
    fi
    AGENT_LAUNCH_CMD="claude code --dangerously-skip-permissions ."
    WORKER_CMD="/autocoder:fix-loop"
    MANAGER_CMD="/autocoder:monitor-loop"
    ;;
  gemini)
    if ! command -v gemini &> /dev/null; then
      echo "❌ Error: gemini command is not installed" >&2
      echo "   Install Gemini CLI: https://github.com/google-gemini/gemini-cli" >&2
      exit 1
    fi
    AGENT_LAUNCH_CMD="gemini --sandbox=false"
    WORKER_CMD="/fix-loop"
    MANAGER_CMD="/monitor-loop"
    ;;
  codex)
    if ! command -v codex &> /dev/null; then
      echo "❌ Error: codex command is not installed" >&2
      exit 1
    fi
    AGENT_LAUNCH_CMD=""
    WORKER_CMD="bash '$AGENTS_REPO_ROOT/scripts/codex-fix-loop.sh'"
    MANAGER_CMD="bash '$AGENTS_REPO_ROOT/scripts/codex-manage-workers-loop.sh'"
    ;;
  droid)
    if ! command -v droid &> /dev/null; then
      echo "❌ Error: droid command is not installed" >&2
      echo "   Install Droid: https://docs.factory.ai/" >&2
      exit 1
    fi
    AGENT_LAUNCH_CMD=""
    WORKER_CMD="bash '$AGENTS_REPO_ROOT/scripts/droid-fix-loop.sh'"
    MANAGER_CMD="bash '$AGENTS_REPO_ROOT/scripts/droid-manage-workers-loop.sh'"
    ;;
  *)
    echo "❌ Error: Unknown agent framework '$AGENT'. Use 'claude', 'gemini', 'codex', or 'droid'" >&2
    exit 1
    ;;
esac

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
SESSION_NAME="${AGENT}-${PROJECT_NAME}"
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")

# Generate shared task list ID for coordination
TASK_LIST_ID="parallel-$(date +%Y%m%d-%H%M%S)"

echo "🚀 Starting parallel agent system"
echo "   Project: $PROJECT_NAME"
echo "   Main path: $PROJECT_ROOT"
echo "   Num agents: $NUM_AGENTS"
echo "   Multiplexer: $MUX"
echo "   Agent framework: $AGENT"
echo "   Task list ID: $TASK_LIST_ID"
echo "   Branch: $CURRENT_BRANCH"
echo ""

# Create worktrees if needed
WORKTREE_PATHS=()

if [ "$USE_WORKTREES" = true ]; then
  echo "📁 Setting up git worktrees..."

  # Create N worktrees for N agents (all workers in worktrees)
  for i in $(seq 1 $NUM_AGENTS); do
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

  # Replicate .agent symlink to worktrees if it exists (for Gemini/Antigravity)
  if [ -L "$PROJECT_ROOT/.agent" ]; then
    AGENT_TARGET=$(readlink "$PROJECT_ROOT/.agent")
    echo ""
    echo "📁 Detected .agent/ symlink, replicating to worktrees..."

    for i in $(seq 1 $NUM_AGENTS); do
      WORKTREE_PATH="${WORKTREE_PATHS[$((i-1))]}"

      if [ ! -L "$WORKTREE_PATH/.agent" ]; then
        ln -s "$AGENT_TARGET" "$WORKTREE_PATH/.agent"
        echo "   ✓ Created symlink in worktree $i: .agent -> $AGENT_TARGET"
      else
        echo "   ✓ Symlink already exists in worktree $i"
      fi
    done
  fi

  echo ""
else
  echo "⚠️  Running without worktrees (all agents in same directory)"
  echo ""
fi

# ============================================================================
# TMUX MODE
# ============================================================================
if [ "$MUX" = "tmux" ]; then

  # Check if session already exists
  if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    echo "⚠️  Session '$SESSION_NAME' already exists"
    echo "   Attaching to existing session..."
    tmux attach-session -t "$SESSION_NAME"
    exit 0
  fi

  # Create tmux session with first window (parallel agents)
  echo "🖥️  Creating tmux session: $SESSION_NAME"
  tmux new-session -d -s "$SESSION_NAME" -n "agents"

  # First pane (leftmost) - worker 1 in wt-1
  echo "   Setting up worker agent 1..."
  if [ "$USE_WORKTREES" = true ]; then
    tmux send-keys -t "$SESSION_NAME:0.0" "cd '${WORKTREE_PATHS[0]}'" C-m
  else
    tmux send-keys -t "$SESSION_NAME:0.0" "cd '$PROJECT_ROOT'" C-m
  fi

  # Set environment variables for Claude Code coordination
  if [ "$AGENT" = "claude" ]; then
    tmux send-keys -t "$SESSION_NAME:0.0" "export CLAUDE_CODE_TASK_LIST_ID='$TASK_LIST_ID'" C-m
    tmux send-keys -t "$SESSION_NAME:0.0" "export CLAUDE_CODE_INTEGRATION_BRANCH='$CURRENT_BRANCH'" C-m
  fi

  # Create panes for remaining workers
  for i in $(seq 2 $NUM_AGENTS); do
    echo "   Setting up worker agent $i..."
    tmux split-window -h -t "$SESSION_NAME:0"

    if [ "$USE_WORKTREES" = true ]; then
      tmux send-keys -t "$SESSION_NAME:0.$((i-1))" "cd '${WORKTREE_PATHS[$((i-1))]}'" C-m
    else
      tmux send-keys -t "$SESSION_NAME:0.$((i-1))" "cd '$PROJECT_ROOT'" C-m
    fi

    if [ "$AGENT" = "claude" ]; then
      tmux send-keys -t "$SESSION_NAME:0.$((i-1))" "export CLAUDE_CODE_TASK_LIST_ID='$TASK_LIST_ID'" C-m
    fi
  done

  # Balance the panes to make them equal width
  tmux select-layout -t "$SESSION_NAME:0" even-horizontal

  # Launch agent in each pane sequentially with individual waits
  echo ""
  echo "🤖 Starting $AGENT sessions..."

  for i in $(seq 0 $((NUM_AGENTS - 1))); do
    echo "   Starting worker $((i+1))/$NUM_AGENTS..."
    if [ -n "$AGENT_LAUNCH_CMD" ]; then
      tmux send-keys -t "$SESSION_NAME:0.$i" "$AGENT_LAUNCH_CMD" C-m
      sleep 5
    fi
  done

  # Wait for all instances to be fully ready
  echo "   Waiting for all instances to stabilize..."
  sleep 3

  # Send $WORKER_CMD command to agents ONE AT A TIME with full initialization wait
  echo "   Starting $WORKER_CMD in all agents (sequential)..."
  for i in $(seq 0 $((NUM_AGENTS - 1))); do
    echo "   → Agent $((i+1)): sending $WORKER_CMD..."
    tmux send-keys -t "$SESSION_NAME:0.$i" "$WORKER_CMD"
    sleep 0.5
    tmux send-keys -t "$SESSION_NAME:0.$i" "Enter"

    # Wait for THIS agent to fully process $WORKER_CMD before starting next
    echo "   → Agent $((i+1)): waiting for initialization..."
    sleep 10
  done

  echo "   All agents initialized"

  # Create second window for review/planning (single pane)
  echo ""
  echo "📋 Setting up review/planning window..."
  tmux new-window -t "$SESSION_NAME:1" -n "review"

  # Set up review window
  echo "   Starting coordinator..."
  tmux send-keys -t "$SESSION_NAME:1.0" "cd '$PROJECT_ROOT'" C-m

  if [ "$AGENT" = "claude" ]; then
    tmux send-keys -t "$SESSION_NAME:1.0" "export CLAUDE_CODE_TASK_LIST_ID='$TASK_LIST_ID'" C-m
  fi

  if [ -n "$AGENT_LAUNCH_CMD" ]; then
    tmux send-keys -t "$SESSION_NAME:1.0" "$AGENT_LAUNCH_CMD" C-m
    sleep 5
  fi
  tmux send-keys -t "$SESSION_NAME:1.0" "$MANAGER_CMD"
  sleep 0.5
  tmux send-keys -t "$SESSION_NAME:1.0" "Enter"

  # Select the first window (agents) by default
  tmux select-window -t "$SESSION_NAME:0"

  echo ""
  echo "✅ Parallel agent system started!"
  echo ""
  echo "📊 Session Info:"
  echo "   Session name: $SESSION_NAME"
  echo "   Multiplexer: tmux"
  echo "   Agent framework: $AGENT"
  echo "   Task list ID: $TASK_LIST_ID"
  echo "   Window 0: $NUM_AGENTS worker agents in worktrees running $WORKER_CMD"
  echo "   Window 1: Manager in main repo running $MANAGER_CMD"
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

# ============================================================================
# CMUX MODE
# ============================================================================
elif [ "$MUX" = "cmux" ]; then

  # Verify cmux is running (it's a GUI app, must be open)
  if ! cmux ping &>/dev/null; then
    echo "❌ Error: cmux is not running" >&2
    echo "   Please launch cmux.app first, then re-run this script" >&2
    exit 1
  fi

  # Helper: send text to a workspace and press enter
  # Uses --workspace ref to target the right workspace
  cmux_send_cmd() {
    local ws_ref="$1"
    local text="$2"
    cmux send --workspace "$ws_ref" "$text" >/dev/null
    cmux send-key --workspace "$ws_ref" enter >/dev/null
  }

  # Extract workspace ref (e.g. "workspace:3") from "OK workspace:3" output
  parse_ws_ref() {
    echo "$1" | grep -o 'workspace:[0-9]*'
  }

  WORKER_WS_REFS=()

  # --- Create one workspace per worker agent ---
  echo "🤖 Starting $AGENT worker sessions..."
  echo ""

  for i in $(seq 1 $NUM_AGENTS); do
    echo "   Setting up worker agent $i/$NUM_AGENTS..."

    # Create a new workspace in the worktree directory
    if [ "$USE_WORKTREES" = true ]; then
      WS_OUTPUT=$(cmux new-workspace --cwd "${WORKTREE_PATHS[$((i-1))]}")
    else
      WS_OUTPUT=$(cmux new-workspace --cwd "$PROJECT_ROOT")
    fi
    WS_REF=$(parse_ws_ref "$WS_OUTPUT")
    echo "   Created $WS_REF"

    if [ -z "$WS_REF" ]; then
      echo "   ⚠️  Could not parse workspace ref from: $WS_OUTPUT"
      continue
    fi

    WORKER_WS_REFS+=("$WS_REF")
    sleep 1

    # Rename workspace: wt<N>-<project>
    cmux rename-workspace --workspace "$WS_REF" "wt${i}-${PROJECT_NAME}" >/dev/null || true

    # Set environment variables for Claude Code coordination
    if [ "$AGENT" = "claude" ]; then
      cmux_send_cmd "$WS_REF" "export CLAUDE_CODE_TASK_LIST_ID='$TASK_LIST_ID'"
      cmux_send_cmd "$WS_REF" "export CLAUDE_CODE_INTEGRATION_BRANCH='$CURRENT_BRANCH'"
      sleep 0.5
    fi

    # Launch agent
    if [ -n "$AGENT_LAUNCH_CMD" ]; then
      echo "   Starting $AGENT in worker $i..."
      cmux_send_cmd "$WS_REF" "$AGENT_LAUNCH_CMD"
      sleep 5
    fi

    # Send worker command
    echo "   → Worker $i: sending $WORKER_CMD..."
    cmux_send_cmd "$WS_REF" "$WORKER_CMD"

    echo "   → Worker $i: waiting for initialization..."
    sleep 10
  done

  echo "   All workers initialized"

  # --- Review Workspace ---
  echo ""
  echo "📋 Setting up review/planning workspace..."
  REVIEW_OUTPUT=$(cmux new-workspace --cwd "$PROJECT_ROOT")
  MANAGER_WS_REF=$(parse_ws_ref "$REVIEW_OUTPUT")
  echo "   Created $MANAGER_WS_REF"
  sleep 1

  if [ -n "$MANAGER_WS_REF" ]; then
    # Manager workspace: manager-<project> (same pattern as wt<N>-<project> workers)
    cmux rename-workspace --workspace "$MANAGER_WS_REF" "manager-${PROJECT_NAME}" >/dev/null || true

    if [ "$AGENT" = "claude" ]; then
      cmux_send_cmd "$MANAGER_WS_REF" "export CLAUDE_CODE_TASK_LIST_ID='$TASK_LIST_ID'"
      sleep 0.5
    fi

    if [ -n "$AGENT_LAUNCH_CMD" ]; then
      echo "   Starting coordinator..."
      cmux_send_cmd "$MANAGER_WS_REF" "$AGENT_LAUNCH_CMD"
      sleep 5
    fi
    echo "   → Manager: sending $MANAGER_CMD..."
    cmux_send_cmd "$MANAGER_WS_REF" "$MANAGER_CMD"
  else
    echo "   ⚠️  Could not parse workspace ref from: $REVIEW_OUTPUT"
  fi

  # Switch back to the first worker workspace
  if [ -n "${WORKER_WS_REFS[0]}" ]; then
    cmux select-workspace --workspace "${WORKER_WS_REFS[0]}" >/dev/null || true
  fi

  echo ""
  echo "✅ Parallel agent system started!"
  echo ""
  echo "📊 Session Info:"
  echo "   Multiplexer: cmux"
  echo "   Agent framework: $AGENT"
  echo "   Task list ID: $TASK_LIST_ID"
  echo "   $NUM_AGENTS worker workspaces running $WORKER_CMD"
  echo "   1 manager workspace running $MANAGER_CMD"
  echo ""
  echo "   Worker workspaces: ${WORKER_WS_REFS[*]}"
  if [ -n "$MANAGER_WS_REF" ]; then
    echo "   Review workspace: $MANAGER_WS_REF"
  fi
  echo ""
  echo "🔧 Useful cmux commands:"
  echo "   List workspaces:  cmux list-workspaces"
  echo "   List panes:       cmux list-panes --workspace <ref>"
  echo "   Read screen:      cmux read-screen --workspace <ref>"
  echo "   Send text:        cmux send --workspace <ref> \"text\""
  echo "   Send enter:       cmux send-key --workspace <ref> enter"
  echo "   Close workspace:  cmux close-workspace --workspace <ref>"
  echo ""

fi
