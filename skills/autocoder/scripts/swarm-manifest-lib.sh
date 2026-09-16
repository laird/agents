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

# Stable process-start token for the manager entry's pid_start_time field.
# A PID alone is not identity — PIDs recycle — so liveness is "PID exists AND
# its start token matches the manifest" (idle-sentinel spec, R2-F4).
# Representation (one per platform, compared only for equality against tokens
# from this same helper on the same host, so the two never mix):
#   Linux:  field 22 of /proc/<pid>/stat — start time in clock ticks since
#           boot. Parsed AFTER the closing ')' of the comm field, so binary
#           names containing spaces or parentheses cannot shift the count.
#   other:  the full `ps -o lstart=` timestamp string (darwin has no /proc).
# Prints the token; exits 1 when the PID does not exist.
process_start_time() {
  local pid="$1"
  local token=""
  if [ -r "/proc/$pid/stat" ]; then
    token=$(awk '{ sub(/.*\) /, ""); print $20 }' "/proc/$pid/stat" 2>/dev/null)
  else
    token=$(ps -o lstart= -p "$pid" 2>/dev/null | sed 's/^ *//; s/ *$//')
  fi
  [ -n "$token" ] || return 1
  printf '%s\n' "$token"
}

# Locate a live process whose ENVIRONMENT carries the manager identity marker
# (AUTOCODER_MANAGER=<session>). The marker lives in the environment, not
# argv, so agent TUIs rewriting their titles/command lines cannot shed it and
# a command line merely mentioning the string cannot fake it.
#   Linux:  scan /proc/<pid>/environ (null-delimited — probed with tr '\0').
#   darwin: snapshot `ps -axwwE` FIRST and filter the captured text second,
#           so the filter process can never self-match through ps.
# Best-effort: prints one PID, exits 1 when none. Callers must corroborate
# with process_start_time — a leftover process from an earlier swarm of the
# same session name also carries this marker.
#
# Tree-root preference (idle-sentinel #3): the manager pane exports the
# marker BEFORE the agent launches, so every subprocess the manager spawns
# inherits it. The MANAGER is the topmost marker holder — on Linux, prefer a
# candidate whose PARENT does not carry the marker, oldest start time as the
# tiebreak, so a scan mid-build never records a transient child pid as the
# manager identity. (darwin keeps first-match: ps -E only shows our own
# processes and the ordering caveat is documented best-effort there.)
manager_pid_by_marker() {
  local session="$1"
  local marker="AUTOCODER_MANAGER=$session"
  if [ -d /proc/self ]; then
    local dir pid candidates=""
    for dir in /proc/[0-9]*; do
      pid="${dir#/proc/}"
      [ "$pid" = "$$" ] && continue
      # Only our own processes' environ is readable — enough, since the
      # manager was spawned by us. stderr is redirected BEFORE the input
      # redirection so a process vanishing mid-scan stays silent.
      [ -r "$dir/environ" ] || continue
      if tr '\0' '\n' 2>/dev/null < "$dir/environ" | grep -Fxq "$marker"; then
        candidates="$candidates $pid"
      fi
    done
    candidates="${candidates# }"
    [ -n "$candidates" ] || return 1
    local best="" best_start="" ppid start
    for pid in $candidates; do
      ppid=$(awk '/^PPid:/ { print $2 }' "/proc/$pid/status" 2>/dev/null)
      if [ -n "$ppid" ] && [ -r "/proc/$ppid/environ" ] &&
         tr '\0' '\n' 2>/dev/null < "/proc/$ppid/environ" | grep -Fxq "$marker"; then
        continue  # parent carries the marker too: a child, never the manager
      fi
      start=$(process_start_time "$pid") || continue
      if [ -z "$best" ] || [ "$start" -lt "$best_start" ] 2>/dev/null; then
        best="$pid"
        best_start="$start"
      fi
    done
    # Every candidate had a marker-bearing parent (root unreadable or gone
    # mid-scan): degrade to the first candidate rather than reporting none.
    [ -n "$best" ] || best="${candidates%% *}"
    printf '%s\n' "$best"
    return 0
  fi
  local snapshot pid
  snapshot=$(ps -axwwE -o pid= -o command= 2>/dev/null) || return 1
  pid=$(printf '%s\n' "$snapshot" | awk -v marker="$marker" '
    {
      i = index($0, marker)
      if (i) {
        c = substr($0, i + length(marker), 1)
        if (c == "" || c == " ") { print $1; exit }
      }
    }')
  [ -n "$pid" ] || return 1
  printf '%s\n' "$pid"
}

# Poll manager_pid_by_marker for up to $2 seconds (default 15). Launch paths
# dispatch the agent REPL asynchronously through the mux, so the
# marker-bearing process appears some seconds after dispatch. Prints the PID
# on success; exits 1 on timeout (callers record pid null and move on — a
# null pid is refreshed by the sentinel's own probes, never guessed).
wait_for_manager_pid() {
  local session="$1"
  local timeout="${2:-15}"
  local deadline=$((SECONDS + timeout))
  local pid
  while :; do
    if pid=$(manager_pid_by_marker "$session"); then
      printf '%s\n' "$pid"
      return 0
    fi
    [ "$SECONDS" -ge "$deadline" ] && return 1
    sleep 1
  done
}

# Full-manifest writer. Same arguments as write_paused_manifest plus a
# trailing swarm state ("paused", "running", ...). Runs under the manifest
# lock: since R2-F1 every launch path writes the manifest, so launches now
# contend with add-worker/remove-worker/start-workers for the same file.
write_swarm_manifest() {
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
  local state="${15}"
  local lock_path="${manifest_path%.json}.lock"

  mkdir -p "$(dirname "$manifest_path")"
  (
    flock -x 9
    python3 - "$manifest_path" "$session" "$project_root" "$project_name" "$agent" "$mux" \
      "$issue_source" "$issue_source_origin" "$issue_backend" "$issue_dir" "$task_list_id" \
      "$integration_branch" "$workers_json" "$manager_json" "$state" <<'PY'
import json
import os
import sys
import tempfile

(
    path, session, project_root, project_name, agent, mux, issue_source,
    issue_source_origin, issue_backend, issue_dir, task_list_id,
    integration_branch, workers_json, manager_json, state
) = sys.argv[1:]

data = {
    "version": 1,
    "session": session,
    "projectRoot": project_root,
    "projectName": project_name,
    "agent": agent,
    "mux": mux,
    "state": state,
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
  ) 9>"$lock_path"
}

# Backward-compatible wrapper: the original paused-launch writer.
write_paused_manifest() {
  write_swarm_manifest "$@" paused
}

# Write/refresh ONLY the manager entry of an EXISTING manifest, atomically and
# under the manifest lock (the same .lock file remove-worker/start-workers
# take). Exits 2 when no manifest exists — a caller that can describe the
# whole swarm should use write_swarm_manifest instead of inventing one here.
manifest_set_manager() {
  local manifest_path="$1"
  local manager_json="$2"
  local lock_path="${manifest_path%.json}.lock"

  mkdir -p "$(dirname "$manifest_path")"
  (
    flock -x 9
    [ -f "$manifest_path" ] || exit 2
    python3 - "$manifest_path" "$manager_json" <<'PY'
import json
import os
import sys
import tempfile

path, manager_json = sys.argv[1:]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
data["manager"] = json.loads(manager_json)

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
  ) 9>"$lock_path"
}

# Read one field of the manifest's manager entry. Backward compatible with
# manifests written before the identity fields existed (and with
# "manager": null): a missing field prints nothing and exits 0, so callers
# treat empty output as "unknown", never as an error.
manifest_manager_field() {
  local manifest_path="$1"
  local field="$2"
  python3 - "$manifest_path" "$field" <<'PY'
import json
import sys

path, field = sys.argv[1:]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
manager = data.get("manager") or {}
value = manager.get(field)
if value is None:
    sys.exit(0)
print(value)
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
  local herdr_pane="${9:-}"
  python3 - "$number" "$worktree" "$launch_mode" "$command_mode" "$agent_launched" \
    "$tmux_target" "$cmux_workspace" "$state" "$herdr_pane" "$(now_utc_iso)" <<'PY'
import json
import sys
number, worktree, launch_mode, command_mode, agent_launched, tmux_target, cmux_workspace, state, herdr_pane, ts = sys.argv[1:]
print(json.dumps({
    "number": int(number),
    "worktree": worktree,
    "launchMode": launch_mode,
    "commandMode": command_mode,
    "agentLaunched": agent_launched == "true",
    "tmuxTarget": tmux_target or None,
    "cmuxWorkspace": cmux_workspace or None,
    "herdrPane": herdr_pane or None,
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
  local herdr_pane="${7:-}"
  # Identity fields (idle-sentinel spec, R2-F1/R2-F4). All optional so
  # pre-existing 7-argument callers keep working. The JSON keys follow the
  # spec verbatim (pid, pid_start_time, marker, spawned_at) — deliberately
  # snake_case, unlike the rest of the manifest, because every sentinel-side
  # consumer is written against the spec's names.
  #   pid            manager process id, or empty when not (yet) known
  #   pid_start_time token from process_start_time (see its comment)
  #   marker         the env assignment probed in the process environment,
  #                  e.g. "AUTOCODER_MANAGER=claude-myproject"
  #   spawned_at     defaults to now; when this entry was written
  local pid="${8:-}"
  local pid_start_time="${9:-}"
  local marker="${10:-}"
  local spawned_at="${11:-}"
  if [ -z "$spawned_at" ]; then
    spawned_at="$(now_utc_iso)"
  fi
  python3 - "$launch_mode" "$agent_launched" "$readiness_mode" "$ready_file" "$tmux_target" "$cmux_workspace" "$herdr_pane" \
    "$pid" "$pid_start_time" "$marker" "$spawned_at" <<'PY'
import json
import sys
(
    launch_mode, agent_launched, readiness_mode, ready_file, tmux_target,
    cmux_workspace, herdr_pane, pid, pid_start_time, marker, spawned_at
) = sys.argv[1:]
print(json.dumps({
    "launchMode": launch_mode,
    "agentLaunched": agent_launched == "true",
    "readinessMode": readiness_mode,
    "readyFile": ready_file,
    "tmuxTarget": tmux_target or None,
    "cmuxWorkspace": cmux_workspace or None,
    "herdrPane": herdr_pane or None,
    "pid": int(pid) if pid else None,
    "pid_start_time": pid_start_time or None,
    "marker": marker or None,
    "spawned_at": spawned_at,
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
