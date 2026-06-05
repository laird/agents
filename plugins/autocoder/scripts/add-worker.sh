#!/bin/bash
# Add a single worker to an already-running parallel agent fleet.
#
# Usage: add-worker.sh [options]
#
# Options:
#   --mux tmux|cmux        Terminal multiplexer to use (default: auto-detect)
#   --agent claude|gemini|codex|droid  Agent framework (default: auto-detect)
#   --no-worktrees         Run in the same directory as the main repo
#
# Examples:
#   add-worker.sh
#   add-worker.sh --mux tmux --agent claude
#   add-worker.sh --mux cmux --agent codex

set -e

SOURCE_PATH="${BASH_SOURCE[0]}"
while [ -L "$SOURCE_PATH" ]; do
  SOURCE_DIR="$(cd "$(dirname "$SOURCE_PATH")" && pwd)"
  SOURCE_PATH="$(readlink "$SOURCE_PATH")"
  [[ "$SOURCE_PATH" != /* ]] && SOURCE_PATH="$SOURCE_DIR/$SOURCE_PATH"
done
SCRIPT_DIR="$(cd "$(dirname "$SOURCE_PATH")" && pwd)"
AGENTS_REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

MUX=""
AGENT=""
USE_WORKTREES=true

while [[ $# -gt 0 ]]; do
  case $1 in
    --mux)   MUX="$2";   shift 2 ;;
    --agent) AGENT="$2"; shift 2 ;;
    --no-worktrees) USE_WORKTREES=false; shift ;;
    -h|--help)
      echo "Usage: add-worker.sh [--mux tmux|cmux] [--agent claude|gemini|codex|droid] [--no-worktrees]"
      exit 0
      ;;
    *)
      echo "❌ Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

# ── Auto-detect multiplexer ──────────────────────────────────────────────────
if [ -z "$MUX" ]; then
  if command -v cmux &>/dev/null; then MUX="cmux"
  elif command -v tmux &>/dev/null; then MUX="tmux"
  else
    echo "❌ No terminal multiplexer found (tmux or cmux)" >&2
    exit 1
  fi
fi

# ── Auto-detect agent framework ──────────────────────────────────────────────
if [ -z "$AGENT" ]; then
  for a in claude gemini codex droid; do
    command -v "$a" &>/dev/null && { AGENT="$a"; break; }
  done
  [ -z "$AGENT" ] && { echo "❌ No agent framework found" >&2; exit 1; }
fi

# ── Agent launch config ───────────────────────────────────────────────────────
# shellcheck source=worker-launch-lib.sh
source "$SCRIPT_DIR/worker-launch-lib.sh"
resolve_worker_launch "$AGENT" "$AGENTS_REPO_ROOT" || exit 1

PROJECT_ROOT=$(pwd)
PROJECT_NAME=$(basename "$PROJECT_ROOT")
SESSION_NAME="${AGENT}-${PROJECT_NAME}"
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")

# ── Find next available worktree index ───────────────────────────────────────
WORKER_NUM=1
if [ "$USE_WORKTREES" = true ]; then
  while [ -d "${PROJECT_ROOT}-wt-${WORKER_NUM}" ]; do
    WORKER_NUM=$((WORKER_NUM + 1))
  done
  WORKTREE_PATH="${PROJECT_ROOT}-wt-${WORKER_NUM}"
  WORKTREE_BRANCH="${CURRENT_BRANCH}-wt-${WORKER_NUM}"

  echo "📁 Creating worktree: $WORKTREE_PATH"
  if ! git show-ref --verify --quiet "refs/heads/$WORKTREE_BRANCH"; then
    git branch "$WORKTREE_BRANCH" "$CURRENT_BRANCH"
  fi
  git worktree add "$WORKTREE_PATH" "$WORKTREE_BRANCH"

  # Replicate .agent symlink if present
  if [ -L "$PROJECT_ROOT/.agent" ]; then
    AGENT_TARGET=$(readlink "$PROJECT_ROOT/.agent")
    ln -s "$AGENT_TARGET" "$WORKTREE_PATH/.agent" 2>/dev/null || true
    echo "   ✓ Replicated .agent symlink"
  fi

  WORKER_DIR="$WORKTREE_PATH"
else
  WORKER_DIR="$PROJECT_ROOT"
fi

echo "🤖 Adding worker $WORKER_NUM to fleet ($SESSION_NAME)..."
echo ""

# ── Inject into existing session ─────────────────────────────────────────────
if [ "$MUX" = "tmux" ]; then

  if ! tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    echo "❌ No tmux session '$SESSION_NAME' found." >&2
    echo "   Start the fleet first with: start-parallel" >&2
    exit 1
  fi

  # Add a pane to window 0 (agents window)
  tmux split-window -h -t "$SESSION_NAME:0"
  PANE_INDEX=$(tmux list-panes -t "$SESSION_NAME:0" -F '#{pane_index}' | tail -1)

  tmux send-keys -t "$SESSION_NAME:0.${PANE_INDEX}" "cd '$WORKER_DIR'" C-m

  if [ "$AGENT" = "claude" ]; then
    TASK_LIST_ID=$(tmux show-environment -t "$SESSION_NAME" CLAUDE_CODE_TASK_LIST_ID 2>/dev/null | cut -d= -f2 || true)
    [ -n "$TASK_LIST_ID" ] && tmux send-keys -t "$SESSION_NAME:0.${PANE_INDEX}" \
      "export CLAUDE_CODE_TASK_LIST_ID='$TASK_LIST_ID'" C-m
    tmux send-keys -t "$SESSION_NAME:0.${PANE_INDEX}" \
      "export CLAUDE_CODE_INTEGRATION_BRANCH='$CURRENT_BRANCH'" C-m
  fi

  tmux select-layout -t "$SESSION_NAME:0" even-horizontal

  if [ -n "$AGENT_LAUNCH_CMD" ]; then
    tmux send-keys -t "$SESSION_NAME:0.${PANE_INDEX}" "$AGENT_LAUNCH_CMD" C-m
    sleep 5
  fi

  tmux send-keys -t "$SESSION_NAME:0.${PANE_INDEX}" "$WORKER_CMD" C-m

  # Focus the new pane so the user can see the worker starting
  tmux select-window -t "$SESSION_NAME:0"
  tmux select-pane -t "$SESSION_NAME:0.${PANE_INDEX}"

  echo "✅ Worker $WORKER_NUM added to tmux session '$SESSION_NAME' (pane $PANE_INDEX)"
  echo "   Worktree: $WORKER_DIR"

  # Only attach if not already inside a tmux session (e.g. called by the manager agent)
  if [ -z "${TMUX:-}" ]; then
    echo ""
    echo "   Attaching to session — new worker is focused."
    tmux attach-session -t "$SESSION_NAME"
  fi

elif [ "$MUX" = "cmux" ]; then

  if ! cmux ping &>/dev/null; then
    echo "❌ cmux is not running. Launch cmux.app first." >&2
    exit 1
  fi

  WS_OUTPUT=$(cmux new-workspace --cwd "$WORKER_DIR")
  WS_REF=$(echo "$WS_OUTPUT" | grep -o 'workspace:[0-9]*')

  if [ -z "$WS_REF" ]; then
    echo "❌ Could not create cmux workspace" >&2
    exit 1
  fi

  cmux rename-workspace --workspace "$WS_REF" "wt${WORKER_NUM}-${PROJECT_NAME}" >/dev/null || true

  if [ "$AGENT" = "claude" ]; then
    cmux send --workspace "$WS_REF" "export CLAUDE_CODE_INTEGRATION_BRANCH='$CURRENT_BRANCH'" >/dev/null
    cmux send-key --workspace "$WS_REF" enter >/dev/null
  fi

  if [ -n "$AGENT_LAUNCH_CMD" ]; then
    cmux send --workspace "$WS_REF" "$AGENT_LAUNCH_CMD" >/dev/null
    cmux send-key --workspace "$WS_REF" enter >/dev/null
    sleep 5
  fi

  cmux send --workspace "$WS_REF" "$WORKER_CMD" >/dev/null
  cmux send-key --workspace "$WS_REF" enter >/dev/null

  # Focus the new workspace so the user can see the worker starting
  cmux select-workspace --workspace "$WS_REF" >/dev/null || true

  echo "✅ Worker $WORKER_NUM added to cmux fleet ($WS_REF: wt${WORKER_NUM}-${PROJECT_NAME})"
  echo "   Worktree: $WORKER_DIR"

fi
