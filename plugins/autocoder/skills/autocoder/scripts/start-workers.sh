#!/bin/bash
# Start all paused workers or one selected paused worker from a swarm manifest.

set -e

SOURCE_PATH="${BASH_SOURCE[0]}"
while [ -L "$SOURCE_PATH" ]; do
  SOURCE_DIR="$(cd "$(dirname "$SOURCE_PATH")" && pwd)"
  SOURCE_PATH="$(readlink "$SOURCE_PATH")"
  [[ "$SOURCE_PATH" != /* ]] && SOURCE_PATH="$SOURCE_DIR/$SOURCE_PATH"
done
SCRIPT_DIR="$(cd "$(dirname "$SOURCE_PATH")" && pwd)"
AGENTS_REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# shellcheck source=worker-launch-lib.sh
source "$SCRIPT_DIR/worker-launch-lib.sh"
# shellcheck source=issue-source-lib.sh
source "$SCRIPT_DIR/issue-source-lib.sh"
# shellcheck source=swarm-manifest-lib.sh
source "$SCRIPT_DIR/swarm-manifest-lib.sh"
# shellcheck source=mux-send-lib.sh
source "$SCRIPT_DIR/mux-send-lib.sh"

CMD_NAME="$(basename "$0")"
WORKER_NUMBER=""
MUX=""
AGENT=""
SESSION=""
YES=false

if [ "$CMD_NAME" = "start-worker" ]; then
  if [ $# -lt 1 ] || [[ "$1" == --* ]]; then
    echo "Usage: start-worker WORKER_NUMBER [--mux tmux|cmux] [--agent claude|gemini|codex|droid] [--session SESSION] [--yes]" >&2
    exit 2
  fi
  WORKER_NUMBER="$1"
  shift
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mux) MUX="$2"; shift 2 ;;
    --agent) AGENT="$2"; shift 2 ;;
    --session) SESSION="$2"; shift 2 ;;
    --yes) YES=true; shift ;;
    -h|--help)
      if [ "$CMD_NAME" = "start-worker" ]; then
        echo "Usage: start-worker WORKER_NUMBER [--mux tmux|cmux] [--agent claude|gemini|codex|droid] [--session SESSION] [--yes]"
      else
        echo "Usage: start-workers [--mux tmux|cmux] [--agent claude|gemini|codex|droid] [--session SESSION] [--yes]"
      fi
      exit 0
      ;;
    *)
      if [ "$CMD_NAME" != "start-worker" ] && [ -z "$WORKER_NUMBER" ] && [[ "$1" =~ ^[0-9]+$ ]]; then
        WORKER_NUMBER="$1"
        shift
      else
        echo "❌ Unknown argument: $1" >&2
        exit 2
      fi
      ;;
  esac
done

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
  echo "❌ No paused swarm manifest found: $MANIFEST_PATH" >&2
  echo "   Start a paused swarm first: start-parallel --paused" >&2
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
resolve_worker_launch "$MANIFEST_AGENT" "$AGENTS_REPO_ROOT" || exit 1

mkdir -p "$(dirname "$LOCK_PATH")"
exec 9>"$LOCK_PATH"
flock -x 9

SELECTED_FILE=$(mktemp)
trap 'rm -f "$SELECTED_FILE"' EXIT

python3 - "$MANIFEST_PATH" "$CMD_NAME" "${WORKER_NUMBER:-}" "$YES" "${AUTOCODER_STARTING_STALE_SECONDS:-300}" > "$SELECTED_FILE" <<'PY'
from datetime import datetime, timezone
import json
import os
import sys
import tempfile

path, cmd_name, worker_number, yes, stale_seconds = sys.argv[1:]
yes = yes == "true"
stale_seconds = int(stale_seconds)
now = datetime.now(timezone.utc).replace(microsecond=0)
now_s = now.isoformat().replace("+00:00", "Z")

with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)

if data.get("state") not in ("paused", "partial", "running"):
    print(f"Unsupported swarm state: {data.get('state')}", file=sys.stderr)
    sys.exit(1)

workers = data.get("workers", [])
if worker_number:
    wanted = {int(worker_number)}
else:
    wanted = {
        int(w["number"])
        for w in workers
        if w.get("state") == "paused" or (yes and w.get("state") in ("starting", "failed"))
    }

selected = []
for worker in workers:
    number = int(worker.get("number", -1))
    if number not in wanted:
        continue
    state = worker.get("state")
    if state == "started" and not yes:
        print(f"Worker {number} is already started; use --yes to resend.", file=sys.stderr)
        sys.exit(1)
    if state == "starting":
        ts = worker.get("stateUpdatedAt", "")
        stale = False
        try:
            started = datetime.fromisoformat(ts.replace("Z", "+00:00"))
            stale = (now - started).total_seconds() > stale_seconds
        except Exception:
            stale = True
        if not yes or not stale:
            print(f"Worker {number} is already starting; use --yes after it is stale.", file=sys.stderr)
            sys.exit(1)
        worker["state"] = "failed"
        worker["stateUpdatedAt"] = now_s
    if state == "failed" and not yes:
        print(f"Worker {number} previously failed; use --yes to retry.", file=sys.stderr)
        sys.exit(1)
    if state not in ("paused", "failed", "started", "starting"):
        print(f"Worker {number} state is {state}; use --yes to override.", file=sys.stderr)
        if not yes:
            sys.exit(1)
    worker["state"] = "starting"
    worker["stateUpdatedAt"] = now_s
    selected.append(worker)

if worker_number and not selected:
    print(f"Worker {worker_number} not found in manifest.", file=sys.stderr)
    sys.exit(1)
if not selected:
    print("No paused workers to start.", file=sys.stderr)
    sys.exit(1)

directory = os.path.dirname(path)
fd, tmp = tempfile.mkstemp(prefix=".manifest.", suffix=".json", dir=directory)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    os.replace(tmp, path)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)

for worker in selected:
    print(json.dumps(worker))
PY

ISSUE_SOURCE=$(manifest_get "$MANIFEST_PATH" 'm.get("issueSource")')
ISSUE_DIR_PATH=$(manifest_get "$MANIFEST_PATH" 'm.get("issueDir")')
ISSUE_BACKEND=$(manifest_get "$MANIFEST_PATH" 'm.get("issueBackend")')
export ISSUE_SOURCE ISSUE_DIR_PATH ISSUE_BACKEND

delivery_failed=0
while IFS= read -r worker_json; do
  [ -z "$worker_json" ] && continue
  number=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["number"])' "$worker_json")
  command_mode=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["commandMode"])' "$worker_json")
  tmux_target=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("tmuxTarget") or "")' "$worker_json")
  cmux_workspace=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("cmuxWorkspace") or "")' "$worker_json")

  echo "Starting worker $number..."
  if [ "$MANIFEST_MUX" = "tmux" ]; then
    if ! validate_tmux_target "$tmux_target"; then
      echo "❌ Worker $number target missing: $tmux_target" >&2
      manifest_update_worker_state "$MANIFEST_PATH" "$number" failed || true
      delivery_failed=1
      continue
    fi
    if [ "$command_mode" = "shell" ]; then
      env_failed=0
      while IFS= read -r line; do
        if [ -n "$line" ] && ! send_tmux_command "$tmux_target" "$line"; then
          env_failed=1
          break
        fi
      done < <(issue_env_exports)
      if [ "$env_failed" -ne 0 ]; then
        manifest_update_worker_state "$MANIFEST_PATH" "$number" failed || true
        delivery_failed=1
        echo "❌ Worker $number issue-source export failed: $tmux_target" >&2
        continue
      fi
    fi
    if send_tmux_text_enter "$tmux_target" "$WORKER_CMD"; then
      manifest_update_worker_state "$MANIFEST_PATH" "$number" started
      echo "✅ Worker $number command sent to $tmux_target"
    else
      manifest_update_worker_state "$MANIFEST_PATH" "$number" failed || true
      delivery_failed=1
      echo "❌ Worker $number command delivery failed: $tmux_target" >&2
    fi
  elif [ "$MANIFEST_MUX" = "cmux" ]; then
    if ! validate_cmux_target "$cmux_workspace"; then
      echo "❌ Worker $number target missing: $cmux_workspace" >&2
      manifest_update_worker_state "$MANIFEST_PATH" "$number" failed || true
      delivery_failed=1
      continue
    fi
    if [ "$command_mode" = "shell" ]; then
      env_failed=0
      while IFS= read -r line; do
        if [ -n "$line" ] && ! send_cmux_command "$cmux_workspace" "$line"; then
          env_failed=1
          break
        fi
      done < <(issue_env_exports)
      if [ "$env_failed" -ne 0 ]; then
        manifest_update_worker_state "$MANIFEST_PATH" "$number" failed || true
        delivery_failed=1
        echo "❌ Worker $number issue-source export failed: $cmux_workspace" >&2
        continue
      fi
    fi
    if send_cmux_command "$cmux_workspace" "$WORKER_CMD"; then
      manifest_update_worker_state "$MANIFEST_PATH" "$number" started
      echo "✅ Worker $number command sent to $cmux_workspace"
    else
      manifest_update_worker_state "$MANIFEST_PATH" "$number" failed || true
      delivery_failed=1
      echo "❌ Worker $number command delivery failed: $cmux_workspace" >&2
    fi
  else
    echo "❌ Unknown mux in manifest: $MANIFEST_MUX" >&2
    exit 1
  fi
done < "$SELECTED_FILE"

exit "$delivery_failed"
