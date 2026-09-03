#!/bin/bash
# Add a single worker to an already-running parallel agent fleet.
#
# Usage: add-worker.sh [count] [options]
#
# Options:
#   --mux tmux|cmux        Terminal multiplexer to use (default: auto-detect)
#   --agent claude|gemini|codex|droid  Agent framework (default: auto-detect)
#   --no-worktrees         Run in the same directory as the main repo
#
# Examples:
#   add-worker.sh
#   add-worker.sh 2
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

# shellcheck source=mux-send-lib.sh
source "$SCRIPT_DIR/mux-send-lib.sh"

MUX=""
AGENT=""
USE_WORKTREES=true
NUM_WORKERS=1
NO_ATTACH=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --mux)   MUX="$2";   shift 2 ;;
    --agent) AGENT="$2"; shift 2 ;;
    --no-worktrees) USE_WORKTREES=false; shift ;;
    --no-attach) NO_ATTACH=true; shift ;;
    -h|--help)
      echo "Usage: add-worker.sh [count] [--mux tmux|cmux] [--agent claude|gemini|codex|droid] [--no-worktrees]"
      echo ""
      echo "Adds and starts one or more workers in an existing swarm."
      exit 0
      ;;
    [0-9]*)
      NUM_WORKERS="$1"
      shift
      ;;
    *)
      echo "❌ Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

# ── Auto-detect multiplexer ──────────────────────────────────────────────────
# Prefer cmux only when it is actually running — see cmux_is_running().
if [ -z "$MUX" ]; then
  if cmux_is_running; then MUX="cmux"
  elif command -v tmux &>/dev/null; then
    MUX="tmux"
    if command -v cmux &>/dev/null; then
      echo "ℹ️  cmux installed but not running — falling back to tmux"
    fi
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

if ! [[ "$NUM_WORKERS" =~ ^[1-9][0-9]*$ ]]; then
  echo "❌ Worker count must be a positive integer: $NUM_WORKERS" >&2
  exit 2
fi

# ── Agent launch config ───────────────────────────────────────────────────────
# shellcheck source=worker-launch-lib.sh
source "$SCRIPT_DIR/worker-launch-lib.sh"

# Every pane reports ctx/mem/model/worktree/branch. Advisory: never blocks launch.
ensure_statusline --quiet
# shellcheck source=issue-source-lib.sh
source "$SCRIPT_DIR/issue-source-lib.sh"
# shellcheck source=swarm-manifest-lib.sh
source "$SCRIPT_DIR/swarm-manifest-lib.sh"
resolve_worker_launch "$AGENT" "$AGENTS_REPO_ROOT" || exit 1

PROJECT_ROOT=$(resolve_main_worktree)
PROJECT_NAME=$(basename "$PROJECT_ROOT")
SESSION_NAME="${AGENT}-${PROJECT_NAME}"
CURRENT_BRANCH=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
MANIFEST_PATH=$(manifest_path_for_session "$PROJECT_ROOT" "$SESSION_NAME")
SWARM_STATE=""
HAS_MANIFEST=false
if [ -f "$MANIFEST_PATH" ]; then
  HAS_MANIFEST=true
  SWARM_STATE=$(manifest_get "$MANIFEST_PATH" 'm.get("state")')
  ISSUE_SOURCE=$(manifest_get "$MANIFEST_PATH" 'm.get("issueSource")')
  ISSUE_DIR_PATH=$(manifest_get "$MANIFEST_PATH" 'm.get("issueDir")')
  ISSUE_BACKEND=$(manifest_get "$MANIFEST_PATH" 'm.get("issueBackend")')
  export ISSUE_SOURCE ISSUE_DIR_PATH ISSUE_BACKEND
fi

if [ "$HAS_MANIFEST" = true ]; then
  STARTED_EXISTING=0
  while IFS= read -r IDLE_WORKER_NUM; do
    [ -z "$IDLE_WORKER_NUM" ] && continue
    [ "$STARTED_EXISTING" -ge "$NUM_WORKERS" ] && break
    echo "▶️  Starting idle worker $IDLE_WORKER_NUM in $SESSION_NAME..."
    bash "$SCRIPT_DIR/start-workers.sh" "$IDLE_WORKER_NUM" --session "$SESSION_NAME" --agent "$AGENT" --mux "$MUX"
    STARTED_EXISTING=$((STARTED_EXISTING + 1))
  done < <(python3 - "$MANIFEST_PATH" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)
for worker in data.get("workers", []):
    if worker.get("state") == "paused":
        print(worker.get("number"))
PY
)
  if [ "$STARTED_EXISTING" -gt 0 ]; then
    NUM_WORKERS=$((NUM_WORKERS - STARTED_EXISTING))
    if [ "$NUM_WORKERS" -eq 0 ]; then
      echo "✅ Started $STARTED_EXISTING idle worker(s)."
      exit 0
    fi
    echo "   Started $STARTED_EXISTING idle worker(s); adding $NUM_WORKERS more worker(s)."
  fi
fi

if [ "$NUM_WORKERS" -gt 1 ]; then
  echo "🤖 Adding and starting $NUM_WORKERS workers..."
  COMMON_ARGS=(--mux "$MUX" --agent "$AGENT" --no-attach)
  [ "$USE_WORKTREES" = false ] && COMMON_ARGS+=(--no-worktrees)
  for _ in $(seq 1 "$NUM_WORKERS"); do
    bash "$SCRIPT_DIR/add-worker.sh" "${COMMON_ARGS[@]}"
  done
  if [ "$MUX" = "tmux" ] && [ "$NO_ATTACH" = false ] && [ -z "${TMUX:-}" ]; then
    echo ""
    echo "   Attaching to session."
    tmux attach-session -t "$SESSION_NAME"
  fi
  exit 0
fi

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

  # Resolve the agents window by name (falling back to the first window) rather
  # than assuming index 0: tmux honours the user's `base-index` setting, so a
  # hardcoded ":0" fails with "can't find window: 0" under `base-index 1`.
  AGENTS_WINDOW=$(tmux list-windows -t "$SESSION_NAME" -F '#{window_id} #{window_name}' \
    | awk '$2 == "agents" { print $1; exit }')
  if [ -z "$AGENTS_WINDOW" ]; then
    AGENTS_WINDOW=$(tmux list-windows -t "$SESSION_NAME" -F '#{window_id}' | head -1)
  fi

  # Add a pane to the agents window; address it by pane id, not by index
  PANE_ID=$(tmux split-window -v -t "$AGENTS_WINDOW" -P -F '#{pane_id}')
  PANE_INDEX=$(tmux display-message -p -t "$PANE_ID" '#{pane_index}')

  tmux send-keys -t "$PANE_ID" "cd '$WORKER_DIR'" C-m
  if [ -n "${ISSUE_SOURCE:-}" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] && tmux send-keys -t "$PANE_ID" "$line" C-m
    done < <(issue_env_exports)
  fi

  if [ "$AGENT" = "claude" ]; then
    TASK_LIST_ID=$(tmux show-environment -t "$SESSION_NAME" CLAUDE_CODE_TASK_LIST_ID 2>/dev/null | cut -d= -f2 || true)
    [ -n "$TASK_LIST_ID" ] && tmux send-keys -t "$PANE_ID" \
      "export CLAUDE_CODE_TASK_LIST_ID='$TASK_LIST_ID'" C-m
    tmux send-keys -t "$PANE_ID" \
      "export CLAUDE_CODE_INTEGRATION_BRANCH='$CURRENT_BRANCH'" C-m
  fi

  tmux select-layout -t "$AGENTS_WINDOW" even-vertical

  if [ -n "$AGENT_LAUNCH_CMD" ]; then
    tmux send-keys -t "$PANE_ID" "$AGENT_LAUNCH_CMD" C-m
    sleep 5
  fi

  if [ "$HAS_MANIFEST" = true ]; then
    WORKER_JSON=$(manifest_worker_json "$WORKER_NUM" "$WORKER_DIR" "$WORKER_LAUNCH_MODE" "$WORKER_COMMAND_MODE" "$([ -n "$AGENT_LAUNCH_CMD" ] && echo true || echo false)" "$PANE_ID" "" paused)
    manifest_add_worker_json "$MANIFEST_PATH" "$WORKER_JSON"
    echo "   Manifest-backed swarm detected: starting newly added worker $WORKER_NUM."
    bash "$SCRIPT_DIR/start-workers.sh" "$WORKER_NUM" --session "$SESSION_NAME" --agent "$AGENT" --mux "$MUX"
  elif [ "$WORKER_COMMAND_MODE" = "agent-input" ]; then
    # Into an agent TUI: the Enter must be a separate send-keys call or the text
    # sits unsubmitted in the input box. See send_tmux_text_enter's note.
    send_tmux_text_enter "$PANE_ID" "$WORKER_CMD"
  else
    tmux send-keys -t "$PANE_ID" "$WORKER_CMD" C-m
  fi

  # Focus the new pane so the user can see the worker starting
  tmux select-window -t "$AGENTS_WINDOW"
  tmux select-pane -t "$PANE_ID"

  echo "✅ Worker $WORKER_NUM added to tmux session '$SESSION_NAME' (pane $PANE_INDEX)"
  echo "   Worktree: $WORKER_DIR"

  # Only attach if not already inside a tmux session (e.g. called by the manager agent)
  if [ "$NO_ATTACH" = false ] && [ -z "${TMUX:-}" ]; then
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
    if [ -n "${ISSUE_SOURCE:-}" ]; then
      while IFS= read -r line; do
        [ -n "$line" ] && cmux send --workspace "$WS_REF" "$line" >/dev/null && cmux send-key --workspace "$WS_REF" enter >/dev/null
      done < <(issue_env_exports)
    fi
    cmux send --workspace "$WS_REF" "export CLAUDE_CODE_INTEGRATION_BRANCH='$CURRENT_BRANCH'" >/dev/null
    cmux send-key --workspace "$WS_REF" enter >/dev/null
  elif [ -n "${ISSUE_SOURCE:-}" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] && cmux send --workspace "$WS_REF" "$line" >/dev/null && cmux send-key --workspace "$WS_REF" enter >/dev/null
    done < <(issue_env_exports)
  fi

  if [ -n "$AGENT_LAUNCH_CMD" ]; then
    cmux send --workspace "$WS_REF" "$AGENT_LAUNCH_CMD" >/dev/null
    cmux send-key --workspace "$WS_REF" enter >/dev/null
    sleep 5
  fi

  if [ "$HAS_MANIFEST" = true ]; then
    WORKER_JSON=$(manifest_worker_json "$WORKER_NUM" "$WORKER_DIR" "$WORKER_LAUNCH_MODE" "$WORKER_COMMAND_MODE" "$([ -n "$AGENT_LAUNCH_CMD" ] && echo true || echo false)" "" "$WS_REF" paused)
    manifest_add_worker_json "$MANIFEST_PATH" "$WORKER_JSON"
    echo "   Manifest-backed swarm detected: starting newly added worker $WORKER_NUM."
    bash "$SCRIPT_DIR/start-workers.sh" "$WORKER_NUM" --session "$SESSION_NAME" --agent "$AGENT" --mux "$MUX"
  else
    cmux send --workspace "$WS_REF" "$WORKER_CMD" >/dev/null
    cmux send-key --workspace "$WS_REF" enter >/dev/null
  fi

  # Focus the new workspace so the user can see the worker starting
  cmux select-workspace --workspace "$WS_REF" >/dev/null || true

  echo "✅ Worker $WORKER_NUM added to cmux fleet ($WS_REF: wt${WORKER_NUM}-${PROJECT_NAME})"
  echo "   Worktree: $WORKER_DIR"

fi
