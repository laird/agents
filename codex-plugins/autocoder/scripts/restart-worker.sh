#!/bin/bash
# restart-worker.sh — restart a single unhealthy worker IN PLACE.
#
# Kills the worker's running agent process (the one wedged / bloated) and
# relaunches a fresh agent in the SAME worktree on the SAME branch. The worker
# resumes its assigned issue via the existing "working" label — committed
# progress is preserved; only uncommitted in-memory state (already lost on a
# hung process) is discarded.
#
# This is the recovery action the manager (/monitor-workers) takes when
# worker-health.sh flags a worker as UNHEALTHY (stalled AND high memory).
#
# Usage:
#   restart-worker.sh --worktree <path> [--mux tmux|cmux] [--agent claude|gemini|codex|droid]
#
# Examples:
#   restart-worker.sh --worktree /Users/me/src/agents-wt-2
#   restart-worker.sh --worktree /Users/me/src/agents-wt-2 --mux cmux --agent codex

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
WORKTREE=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --mux)      MUX="$2";      shift 2 ;;
    --agent)    AGENT="$2";    shift 2 ;;
    --worktree) WORKTREE="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: restart-worker.sh --worktree <path> [--mux tmux|cmux] [--agent claude|gemini|codex|droid]"
      exit 0
      ;;
    *)
      echo "❌ Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [ -z "$WORKTREE" ]; then
  echo "❌ --worktree <path> is required" >&2
  exit 1
fi
# Normalize to an absolute path with no trailing slash.
WORKTREE="$(cd "$WORKTREE" 2>/dev/null && pwd)" || { echo "❌ Worktree not found: $WORKTREE" >&2; exit 1; }

# ── Auto-detect multiplexer ──────────────────────────────────────────────────
if [ -z "$MUX" ]; then
  if command -v cmux &>/dev/null; then MUX="cmux"
  elif command -v tmux &>/dev/null; then MUX="tmux"
  else echo "❌ No terminal multiplexer found (tmux or cmux)" >&2; exit 1
  fi
fi

# ── Auto-detect agent framework ──────────────────────────────────────────────
if [ -z "$AGENT" ]; then
  for a in claude gemini codex droid; do
    command -v "$a" &>/dev/null && { AGENT="$a"; break; }
  done
  [ -z "$AGENT" ] && { echo "❌ No agent framework found" >&2; exit 1; }
fi

# ── Agent launch config (shared with add-worker.sh) ──────────────────────────
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
WORKER_STATE=""
WORKER_NUM=""
if [ -f "$MANIFEST_PATH" ]; then
  ISSUE_SOURCE=$(manifest_get "$MANIFEST_PATH" 'm.get("issueSource")')
  ISSUE_DIR_PATH=$(manifest_get "$MANIFEST_PATH" 'm.get("issueDir")')
  ISSUE_BACKEND=$(manifest_get "$MANIFEST_PATH" 'm.get("issueBackend")')
  export ISSUE_SOURCE ISSUE_DIR_PATH ISSUE_BACKEND
  WORKER_INFO=$(python3 - "$MANIFEST_PATH" "$WORKTREE" <<'PY'
import json, sys
path, worktree = sys.argv[1:]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
for worker in data.get("workers", []):
    if worker.get("worktree") == worktree:
        print(f"{worker.get('number')}|{worker.get('state')}")
        break
PY
)
  WORKER_NUM="${WORKER_INFO%%|*}"
  WORKER_STATE="${WORKER_INFO#*|}"
fi

echo "♻️  Restarting worker in worktree: $WORKTREE"

# ── tmux: respawn the pane whose cwd is the worktree ─────────────────────────
if [ "$MUX" = "tmux" ]; then

  if ! tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    echo "❌ No tmux session '$SESSION_NAME' found." >&2
    exit 1
  fi

  # Find the pane whose current path matches the worktree.
  PANE=$(tmux list-panes -a \
      -F '#{pane_current_path}|#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null \
    | awk -F'|' -v w="$WORKTREE" '$1==w {print $2; exit}')

  if [ -z "$PANE" ]; then
    echo "❌ No tmux pane found with cwd '$WORKTREE'. Is the worker still in this worktree?" >&2
    exit 1
  fi

  echo "   Killing hung process and respawning pane $PANE ..."
  # -k kills the pane's running process and starts a fresh login shell in the
  # same pane, preserving its cwd.
  tmux respawn-pane -k -t "$PANE"
  sleep 1

  tmux send-keys -t "$PANE" "cd '$WORKTREE'" C-m
  if [ -n "${ISSUE_SOURCE:-}" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] && tmux send-keys -t "$PANE" "$line" C-m
    done < <(issue_env_exports)
  fi

  if [ "$AGENT" = "claude" ]; then
    TASK_LIST_ID=$(tmux show-environment -t "$SESSION_NAME" CLAUDE_CODE_TASK_LIST_ID 2>/dev/null | cut -d= -f2 || true)
    [ -n "$TASK_LIST_ID" ] && tmux send-keys -t "$PANE" \
      "export CLAUDE_CODE_TASK_LIST_ID='$TASK_LIST_ID'" C-m
    tmux send-keys -t "$PANE" \
      "export CLAUDE_CODE_INTEGRATION_BRANCH='$CURRENT_BRANCH'" C-m
  fi

  if [ -n "$AGENT_LAUNCH_CMD" ]; then
    tmux send-keys -t "$PANE" "$AGENT_LAUNCH_CMD" C-m
    sleep 5
  fi

  if [ "$WORKER_STATE" = "paused" ]; then
    [ -n "$WORKER_NUM" ] && manifest_update_worker_state "$MANIFEST_PATH" "$WORKER_NUM" paused || true
    echo "   Paused worker relaunched; WORKER_CMD was not sent."
  else
    tmux send-keys -t "$PANE" "$WORKER_CMD" C-m

    # Confirm the relaunch actually took. A respawned pane that failed to start
    # the loop sits at a bare shell, and reporting success there hides a dead
    # worker from the manager's recovery loop (issue #94).
    sleep 2
    PANE_TAIL=$(tmux capture-pane -p -t "$PANE" 2>/dev/null | tail -5 || true)
    case "$PANE_TAIL" in
      *"No such file or directory"*|*"command not found"*)
        echo "❌ Relaunch failed — the pane reported:" >&2
        echo "$PANE_TAIL" >&2
        echo "   Worker was killed but did NOT restart. Fix the launch command before retrying." >&2
        exit 1
        ;;
    esac
  fi

  echo "✅ Worker restarted in tmux pane $PANE (worktree: $WORKTREE)"

# ── cmux: close the wedged workspace and reopen one at the same cwd ───────────
elif [ "$MUX" = "cmux" ]; then

  if ! cmux ping &>/dev/null; then
    echo "❌ cmux is not running. Launch cmux.app first." >&2
    exit 1
  fi

  # Derive the workspace name from the worktree index (matches add-worker.sh:
  # `${PROJECT_ROOT}-wt-N` -> workspace `wtN-<project>`).
  WT_NUM=$(echo "$WORKTREE" | sed -n 's/.*-wt-\([0-9]\{1,\}\)$/\1/p')
  OLD_REF=""
  if [ -n "$WT_NUM" ]; then
    OLD_REF=$(cmux tree --all 2>/dev/null \
      | grep -o "workspace:[0-9]*[^\n]*wt${WT_NUM}-${PROJECT_NAME}" \
      | grep -o 'workspace:[0-9]*' | head -1)
  fi

  if [ -n "$OLD_REF" ]; then
    echo "   Closing wedged workspace $OLD_REF ..."
    cmux close-workspace --workspace "$OLD_REF" >/dev/null 2>&1 || true
    sleep 1
  else
    echo "   ⚠️  Could not locate the old cmux workspace by name; opening a fresh one." >&2
  fi

  WS_OUTPUT=$(cmux new-workspace --cwd "$WORKTREE")
  WS_REF=$(echo "$WS_OUTPUT" | grep -o 'workspace:[0-9]*')
  [ -z "$WS_REF" ] && { echo "❌ Could not create cmux workspace" >&2; exit 1; }

  [ -n "$WT_NUM" ] && cmux rename-workspace --workspace "$WS_REF" "wt${WT_NUM}-${PROJECT_NAME}" >/dev/null || true

  if [ -n "${ISSUE_SOURCE:-}" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] && cmux send --workspace "$WS_REF" "$line" >/dev/null && cmux send-key --workspace "$WS_REF" enter >/dev/null
    done < <(issue_env_exports)
  fi

  if [ "$AGENT" = "claude" ]; then
    cmux send --workspace "$WS_REF" "export CLAUDE_CODE_INTEGRATION_BRANCH='$CURRENT_BRANCH'" >/dev/null
    cmux send-key --workspace "$WS_REF" enter >/dev/null
  fi

  if [ -n "$AGENT_LAUNCH_CMD" ]; then
    cmux send --workspace "$WS_REF" "$AGENT_LAUNCH_CMD" >/dev/null
    cmux send-key --workspace "$WS_REF" enter >/dev/null
    sleep 5
  fi

  if [ "$WORKER_STATE" = "paused" ]; then
    [ -n "$WORKER_NUM" ] && manifest_update_worker_state "$MANIFEST_PATH" "$WORKER_NUM" paused || true
    echo "   Paused worker relaunched; WORKER_CMD was not sent."
  else
    cmux send --workspace "$WS_REF" "$WORKER_CMD" >/dev/null
    cmux send-key --workspace "$WS_REF" enter >/dev/null
  fi

  echo "✅ Worker restarted in cmux workspace $WS_REF (worktree: $WORKTREE)"

else
  echo "❌ Unknown multiplexer '$MUX'. Use 'tmux' or 'cmux'" >&2
  exit 1
fi
