#!/bin/bash
# Remove one or more workers from a manifest-backed swarm.

set -e

SOURCE_PATH="${BASH_SOURCE[0]}"
while [ -L "$SOURCE_PATH" ]; do
  SOURCE_DIR="$(cd "$(dirname "$SOURCE_PATH")" && pwd)"
  SOURCE_PATH="$(readlink "$SOURCE_PATH")"
  [[ "$SOURCE_PATH" != /* ]] && SOURCE_PATH="$SOURCE_DIR/$SOURCE_PATH"
done
SCRIPT_DIR="$(cd "$(dirname "$SOURCE_PATH")" && pwd)"

# shellcheck source=issue-source-lib.sh
source "$SCRIPT_DIR/issue-source-lib.sh"
# shellcheck source=swarm-manifest-lib.sh
source "$SCRIPT_DIR/swarm-manifest-lib.sh"
# shellcheck source=mux-send-lib.sh
source "$SCRIPT_DIR/mux-send-lib.sh"

MUX=""
AGENT=""
SESSION=""
REMOVE_WORKTREE=false
WORKERS=()

usage() {
  echo "Usage: remove-worker WORKER_NUMBER [WORKER_NUMBER ...] [--mux tmux|cmux] [--agent claude|gemini|codex|droid] [--session SESSION] [--remove-worktree]"
  echo ""
  echo "Stops the selected worker panes/workspaces and removes them from the swarm manifest."
  echo "Worktrees are preserved unless --remove-worktree is passed."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mux) MUX="$2"; shift 2 ;;
    --agent) AGENT="$2"; shift 2 ;;
    --session) SESSION="$2"; shift 2 ;;
    --remove-worktree) REMOVE_WORKTREE=true; shift ;;
    --keep-worktree) REMOVE_WORKTREE=false; shift ;;
    -h|--help)
      usage
      exit 0
      ;;
    [0-9]*)
      WORKERS+=("$1")
      shift
      ;;
    *)
      echo "❌ Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ "${#WORKERS[@]}" -eq 0 ]; then
  echo "❌ At least one worker number is required." >&2
  usage >&2
  exit 2
fi

MAIN_WORKTREE=$(resolve_main_worktree)
PROJECT_NAME=$(basename "$MAIN_WORKTREE")

if [ -z "$SESSION" ] && [ -z "$AGENT" ]; then
  shopt -s nullglob
  manifests=("$MAIN_WORKTREE/$SWARM_STATE_DIR"/*.json)
  shopt -u nullglob
  if [ "${#manifests[@]}" -eq 1 ]; then
    SESSION=$(basename "${manifests[0]}" .json)
  fi
fi

if [ -z "$AGENT" ] && [ -z "$SESSION" ]; then
  for a in claude gemini codex droid; do
    command -v "$a" >/dev/null 2>&1 && { AGENT="$a"; break; }
  done
  AGENT="${AGENT:-claude}"
fi

SESSION="${SESSION:-${AGENT}-${PROJECT_NAME}}"
MANIFEST_PATH=$(manifest_path_for_session "$MAIN_WORKTREE" "$SESSION")
LOCK_PATH=$(manifest_lock_path_for_session "$MAIN_WORKTREE" "$SESSION")

if [ ! -f "$MANIFEST_PATH" ]; then
  echo "❌ No swarm manifest found: $MANIFEST_PATH" >&2
  echo "   remove-worker requires a manifest-backed swarm." >&2
  exit 1
fi

MANIFEST_AGENT=$(manifest_get "$MANIFEST_PATH" 'm.get("agent")')
MANIFEST_MUX=$(manifest_get "$MANIFEST_PATH" 'm.get("mux")')
if [ -n "$AGENT" ] && [ "$AGENT" != "$MANIFEST_AGENT" ]; then
  echo "❌ --agent $AGENT does not match manifest agent $MANIFEST_AGENT" >&2
  exit 2
fi
if [ -n "$MUX" ] && [ "$MUX" != "$MANIFEST_MUX" ]; then
  echo "❌ --mux $MUX does not match manifest mux $MANIFEST_MUX" >&2
  exit 2
fi
AGENT="${AGENT:-$MANIFEST_AGENT}"
MUX="${MUX:-$MANIFEST_MUX}"

mkdir -p "$(dirname "$LOCK_PATH")"
exec 9>"$LOCK_PATH"
flock -x 9

SELECTED_FILE=$(mktemp)
REMOVED_FILE=$(mktemp)
trap 'rm -f "$SELECTED_FILE" "$REMOVED_FILE"' EXIT

python3 - "$MANIFEST_PATH" "${WORKERS[@]}" > "$SELECTED_FILE" <<'PY'
import json
import sys

path = sys.argv[1]
wanted = [int(n) for n in sys.argv[2:]]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
workers = {int(worker.get("number", -1)): worker for worker in data.get("workers", [])}
missing = [str(number) for number in wanted if number not in workers]
if missing:
    print(f"Worker(s) not found in manifest: {', '.join(missing)}", file=sys.stderr)
    sys.exit(1)
for number in wanted:
    print(json.dumps(workers[number]))
PY

remove_failed=0
while IFS= read -r worker_json; do
  [ -z "$worker_json" ] && continue
  number=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["number"])' "$worker_json")
  worktree=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("worktree") or "")' "$worker_json")
  tmux_target=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("tmuxTarget") or "")' "$worker_json")
  cmux_workspace=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("cmuxWorkspace") or "")' "$worker_json")

  echo "Removing worker $number..."
  if [ "$MUX" = "tmux" ]; then
    if [ -n "$tmux_target" ] && validate_tmux_target "$tmux_target"; then
      if run_with_timeout "$AUTOCODER_MUX_TIMEOUT_SECONDS" tmux kill-pane -t "$tmux_target"; then
        echo "   Closed tmux pane $tmux_target"
      else
        echo "❌ Failed to close tmux pane $tmux_target" >&2
        remove_failed=1
        continue
      fi
    else
      echo "   tmux pane already gone or missing: $tmux_target"
    fi
  elif [ "$MUX" = "cmux" ]; then
    if [ -n "$cmux_workspace" ] && validate_cmux_target "$cmux_workspace"; then
      if run_with_timeout "$AUTOCODER_MUX_TIMEOUT_SECONDS" cmux close-workspace --workspace "$cmux_workspace" >/dev/null; then
        echo "   Closed cmux workspace $cmux_workspace"
      else
        echo "❌ Failed to close cmux workspace $cmux_workspace" >&2
        remove_failed=1
        continue
      fi
    else
      echo "   cmux workspace already gone or missing: $cmux_workspace"
    fi
  else
    echo "❌ Unknown mux in manifest: $MUX" >&2
    exit 1
  fi

  if [ "$REMOVE_WORKTREE" = true ] && [ -n "$worktree" ] && [ "$worktree" != "$MAIN_WORKTREE" ]; then
    if git -C "$MAIN_WORKTREE" worktree remove "$worktree"; then
      echo "   Removed worktree $worktree"
    else
      echo "❌ Failed to remove worktree $worktree; leaving manifest entry for review." >&2
      remove_failed=1
      continue
    fi
  elif [ -n "$worktree" ]; then
    echo "   Preserved worktree $worktree"
  fi

  echo "$number" >> "$REMOVED_FILE"
done < "$SELECTED_FILE"

if [ -s "$REMOVED_FILE" ]; then
  REMOVED_WORKERS=()
  while IFS= read -r removed_number; do
    [ -n "$removed_number" ] && REMOVED_WORKERS+=("$removed_number")
  done < "$REMOVED_FILE"
  manifest_remove_workers "$MANIFEST_PATH" "${REMOVED_WORKERS[@]}"
  echo "✅ Removed worker(s): ${REMOVED_WORKERS[*]}"
fi

exit "$remove_failed"
