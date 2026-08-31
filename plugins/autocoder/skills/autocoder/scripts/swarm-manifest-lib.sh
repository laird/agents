#!/bin/bash
# Swarm manifest helpers. JSON mutation is delegated to Python for safety.

SWARM_STATE_DIR=".autocoder/swarm"

manifest_path_for_session() {
  local project_root="$1"
  local session="$2"
  printf '%s/%s/%s.json\n' "$project_root" "$SWARM_STATE_DIR" "$session"
}

manifest_lock_path_for_session() {
  local project_root="$1"
  local session="$2"
  printf '%s/%s/%s.lock\n' "$project_root" "$SWARM_STATE_DIR" "$session"
}

now_utc_iso() {
  python3 - <<'PY'
from datetime import datetime, timezone
print(datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"))
PY
}

write_paused_manifest() {
  local manifest_path="$1"
  local session="$2"
  local project_root="$3"
  local project_name="$4"
  local agent="$5"
  local mux="$6"
  local issue_source="$7"
  local issue_source_origin="$8"
  local issue_backend="$9"
  local issue_dir="${10}"
  local task_list_id="${11}"
  local integration_branch="${12}"
  local workers_json="${13}"
  local manager_json="${14}"

  mkdir -p "$(dirname "$manifest_path")"
  python3 - "$manifest_path" "$session" "$project_root" "$project_name" "$agent" "$mux" \
    "$issue_source" "$issue_source_origin" "$issue_backend" "$issue_dir" "$task_list_id" \
    "$integration_branch" "$workers_json" "$manager_json" <<'PY'
import json
import os
import sys
import tempfile

(
    path, session, project_root, project_name, agent, mux, issue_source,
    issue_source_origin, issue_backend, issue_dir, task_list_id,
    integration_branch, workers_json, manager_json
) = sys.argv[1:]

data = {
    "version": 1,
    "session": session,
    "projectRoot": project_root,
    "projectName": project_name,
    "agent": agent,
    "mux": mux,
    "state": "paused",
    "issueSource": issue_source,
    "issueSourceOrigin": issue_source_origin,
    "issueBackend": issue_backend or None,
    "issueDir": issue_dir or None,
    "taskListId": task_list_id,
    "integrationBranch": integration_branch,
    "workers": json.loads(workers_json),
    "manager": json.loads(manager_json),
}

directory = os.path.dirname(path)
fd, tmp = tempfile.mkstemp(prefix=".manifest.", suffix=".json", dir=directory)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    with open(tmp, "r", encoding="utf-8") as f:
        json.load(f)
    os.replace(tmp, path)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)
PY
}

manifest_get() {
  local manifest_path="$1"
  local expr="$2"
  python3 - "$manifest_path" "$expr" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)
allowed = {
    "all": all,
    "any": any,
    "int": int,
    "len": len,
    "next": next,
    "str": str,
}
value = eval(sys.argv[2], {"__builtins__": allowed}, {"m": data})
if value is None:
    sys.exit(0)
print(value)
PY
}

manifest_update_worker_state() {
  local manifest_path="$1"
  local worker_number="$2"
  local state="$3"
  python3 - "$manifest_path" "$worker_number" "$state" "$(now_utc_iso)" <<'PY'
import json
import os
import sys
import tempfile

path, worker_number, state, timestamp = sys.argv[1:]
worker_number = int(worker_number)
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
found = False
for worker in data.get("workers", []):
    if int(worker.get("number", -1)) == worker_number:
        worker["state"] = state
        worker["stateUpdatedAt"] = timestamp
        found = True
        break
if not found:
    sys.exit(2)
states = [w.get("state") for w in data.get("workers", [])]
if states and all(s == "started" for s in states):
    data["state"] = "running"
elif any(s in ("started", "starting", "failed") for s in states):
    data["state"] = "partial"
else:
    data["state"] = "paused"

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
PY
}

manifest_add_worker_json() {
  local manifest_path="$1"
  local worker_json="$2"
  python3 - "$manifest_path" "$worker_json" <<'PY'
import json
import os
import sys
import tempfile

path, worker_json = sys.argv[1:]
worker = json.loads(worker_json)
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
workers = data.setdefault("workers", [])
workers = [w for w in workers if int(w.get("number", -1)) != int(worker["number"])]
workers.append(worker)
workers.sort(key=lambda w: int(w.get("number", 0)))
data["workers"] = workers
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
PY
}

manifest_remove_workers() {
  local manifest_path="$1"
  shift
  python3 - "$manifest_path" "$@" <<'PY'
import json
import os
import sys
import tempfile

path = sys.argv[1]
remove_numbers = {int(n) for n in sys.argv[2:]}
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
workers = [
    worker
    for worker in data.get("workers", [])
    if int(worker.get("number", -1)) not in remove_numbers
]
data["workers"] = workers
states = [worker.get("state") for worker in workers]
if not states:
    data["state"] = "paused"
elif all(state == "started" for state in states):
    data["state"] = "running"
elif any(state in ("started", "starting", "failed") for state in states):
    data["state"] = "partial"
else:
    data["state"] = "paused"

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
PY
}

manifest_starting_is_stale() {
  local timestamp="$1"
  local threshold="${AUTOCODER_STARTING_STALE_SECONDS:-300}"
  python3 - "$timestamp" "$threshold" <<'PY'
from datetime import datetime, timezone
import sys

timestamp, threshold = sys.argv[1], int(sys.argv[2])
if not timestamp:
    sys.exit(1)
try:
    started = datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
except ValueError:
    sys.exit(0)
now = datetime.now(timezone.utc)
sys.exit(0 if (now - started).total_seconds() > threshold else 1)
PY
}

manifest_worker_json() {
  local number="$1"
  local worktree="$2"
  local launch_mode="$3"
  local command_mode="$4"
  local agent_launched="$5"
  local tmux_target="$6"
  local cmux_workspace="$7"
  local state="${8:-paused}"
  python3 - "$number" "$worktree" "$launch_mode" "$command_mode" "$agent_launched" \
    "$tmux_target" "$cmux_workspace" "$state" "$(now_utc_iso)" <<'PY'
import json
import sys
number, worktree, launch_mode, command_mode, agent_launched, tmux_target, cmux_workspace, state, ts = sys.argv[1:]
print(json.dumps({
    "number": int(number),
    "worktree": worktree,
    "launchMode": launch_mode,
    "commandMode": command_mode,
    "agentLaunched": agent_launched == "true",
    "tmuxTarget": tmux_target or None,
    "cmuxWorkspace": cmux_workspace or None,
    "state": state,
    "stateUpdatedAt": ts,
}))
PY
}

manifest_manager_json() {
  local launch_mode="$1"
  local agent_launched="$2"
  local readiness_mode="$3"
  local ready_file="$4"
  local tmux_target="$5"
  local cmux_workspace="$6"
  python3 - "$launch_mode" "$agent_launched" "$readiness_mode" "$ready_file" "$tmux_target" "$cmux_workspace" <<'PY'
import json
import sys
launch_mode, agent_launched, readiness_mode, ready_file, tmux_target, cmux_workspace = sys.argv[1:]
print(json.dumps({
    "launchMode": launch_mode,
    "agentLaunched": agent_launched == "true",
    "readinessMode": readiness_mode,
    "readyFile": ready_file,
    "tmuxTarget": tmux_target or None,
    "cmuxWorkspace": cmux_workspace or None,
}))
PY
}

json_array_from_lines() {
  python3 -c '
import json
import sys
items = [json.loads(line) for line in sys.stdin if line.strip()]
print(json.dumps(items))
'
}
