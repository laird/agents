#!/bin/bash
# swarm-register.sh — record this worktree's worker (or, with --manager, the
# manager) in the swarm manifest, under the manifest lock (#215, part of #178).
#
# Workers added by hand (create the workspace, run the agent, send
# /autocoder:fix-loop) never appeared in .autocoder/swarm/<session>.json, so
# the manifest said "workers": [] while workers ran. Calling this at start
# fixes that: it adds the entry, or updates the existing one in place.
#
# Usage:
#   swarm-register.sh [--manager] [--session NAME] [--pid PID] [--state STATE]
#
#   --manager   set the manager entry's pane fields and pid instead of a worker
#   --session   the swarm session; otherwise taken from AUTOCODER_WORKER
#               (<session>:<N>) or AUTOCODER_MANAGER (<session>), else the
#               manifest that already lists this worktree, else the only one
#   --pid       the agent's pid; default: the nearest ancestor that is an
#               agent CLI (claude, codex, gemini, droid, pi, node), else $PPID
#   --state     worker state to record (default: started for a new entry;
#               an existing entry keeps its state unless this is given)
#
# Worker entry fields written: number, worktree, branch, tmuxTarget
# ($TMUX_PANE), herdrPane ($HERDR_PANE_ID), cmuxWorkspace ($CMUX_WORKSPACE_ID),
# pid, pid_start_time, state, stateUpdatedAt, registeredAt. A mux field is only
# overwritten when its variable is set, so registering from a plain shell does
# not erase a pane recorded at launch.
#
# The main checkout is the manager's, so it is only registered as a worker when
# the manifest already lists it, or --session / AUTOCODER_WORKER says so.
#
# No manifest (not a swarm), or no way to tell which manifest: prints a note
# on stderr and exits 0. Exits 1 only on bad arguments or a failed write.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=swarm-manifest-lib.sh
source "$SCRIPT_DIR/swarm-manifest-lib.sh"

ROLE=worker
SESSION=""
PID=""
STATE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --manager) ROLE=manager; shift ;;
    --session) SESSION="${2:?--session needs a value}"; shift 2 ;;
    --pid)     PID="${2:?--pid needs a value}"; shift 2 ;;
    --state)   STATE="${2:?--state needs a value}"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "swarm-register: unknown argument '$1'" >&2; exit 1 ;;
  esac
done
case "$PID" in ''|*[!0-9]*) [ -z "$PID" ] || { echo "swarm-register: --pid must be a number" >&2; exit 1; } ;; esac

note() { echo "swarm-register: $*" >&2; }

WORKTREE=$(git rev-parse --show-toplevel 2>/dev/null) || { note "not in a git checkout; nothing to register"; exit 0; }
COMMON=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
  || COMMON=$(cd "$WORKTREE" && cd "$(git rev-parse --git-common-dir)" && pwd)
PROJECT_ROOT=$(dirname "$COMMON")
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

MARKER_NUMBER=""
if [ -z "$SESSION" ]; then
  if [ "$ROLE" = worker ] && [ -n "${AUTOCODER_WORKER:-}" ]; then
    SESSION="${AUTOCODER_WORKER%:*}"
    MARKER_NUMBER="${AUTOCODER_WORKER##*:}"
  elif [ "$ROLE" = manager ] && [ -n "${AUTOCODER_MANAGER:-}" ]; then
    SESSION="$AUTOCODER_MANAGER"
  fi
elif [ "$ROLE" = worker ] && [ -n "${AUTOCODER_WORKER:-}" ] && [ "${AUTOCODER_WORKER%:*}" = "$SESSION" ]; then
  MARKER_NUMBER="${AUTOCODER_WORKER##*:}"
fi
case "$MARKER_NUMBER" in *[!0-9]*) MARKER_NUMBER="" ;; esac
case "$SESSION" in
  */*|.*) echo "swarm-register: invalid session name '$SESSION'" >&2; exit 1 ;;
esac

# A worker in the main checkout needs an explicit session (see above).
ALLOW_NEW=1
GIT_DIR_ABS=$(cd "$(git rev-parse --git-dir)" && pwd -P)
if [ "$ROLE" = worker ] && [ "$GIT_DIR_ABS" = "$(cd "$COMMON" && pwd -P)" ] && [ -z "$SESSION" ]; then
  ALLOW_NEW=0
fi

SWARM_DIR="$PROJECT_ROOT/$SWARM_STATE_DIR"
if [ -n "$SESSION" ]; then
  MANIFEST=$(manifest_path_for_session "$PROJECT_ROOT" "$SESSION")
  [ -f "$MANIFEST" ] || { note "no manifest for session '$SESSION'; nothing to register"; exit 0; }
else
  # The manifest that already lists this worktree wins; otherwise the only one.
  MANIFEST=$(python3 - "$SWARM_DIR" "$WORKTREE" <<'PY'
import glob, json, os, sys
d, wt = sys.argv[1], os.path.realpath(sys.argv[2])
paths = sorted(glob.glob(os.path.join(d, "*.json")))
owning = []
for p in paths:
    try:
        with open(p, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        continue
    for w in data.get("workers") or []:
        if w.get("worktree") and os.path.realpath(w["worktree"]) == wt:
            owning.append(p)
            break
pick = owning if owning else paths
print(pick[0] if len(pick) == 1 else ("AMBIGUOUS" if pick else ""))
PY
)
  case "$MANIFEST" in
    "") note "no swarm manifest under $SWARM_DIR; nothing to register"; exit 0 ;;
    AMBIGUOUS) note "several manifests under $SWARM_DIR and none lists $WORKTREE; pass --session"; exit 0 ;;
  esac
fi

# The agent's own pid: the shell running this script is a short-lived child of
# the agent's tool runner, so walk up to the first agent CLI.
agent_ancestor_pid() {
  local pid=$PPID comm i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null || break
    comm=$(ps -o comm= -p "$pid" 2>/dev/null | sed 's/^ *//; s/ *$//')
    case "${comm##*/}" in
      claude|codex|gemini|droid|pi|node|claude-*) echo "$pid"; return 0 ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  done
  echo "$PPID"
}
if [ -z "$PID" ] && [ "$ROLE" = manager ] && [ -n "$SESSION" ]; then
  PID=$(manager_pid_by_marker "$SESSION" 2>/dev/null || true)
fi
[ -n "$PID" ] || PID=$(agent_ancestor_pid)
PID_START=$(process_start_time "$PID" 2>/dev/null || true)
NOW=$(now_utc_iso)

LOCK="${MANIFEST%.json}.lock"
(
  flock -x 9
  [ -f "$MANIFEST" ] || exit 3
  python3 - "$MANIFEST" "$ROLE" "$WORKTREE" "$PROJECT_ROOT" "$BRANCH" "$MARKER_NUMBER" \
    "$PID" "$PID_START" "$STATE" "$NOW" "${TMUX_PANE:-}" "${HERDR_PANE_ID:-}" "${CMUX_WORKSPACE_ID:-}" \
    "${AUTOCODER_MANAGER:+AUTOCODER_MANAGER=${AUTOCODER_MANAGER}}" "$ALLOW_NEW" <<'PY'
import json, os, re, sys, tempfile

(path, role, worktree, root, branch, marker_number, pid, pid_start, state, now,
 tmux, herdr, cmux, manager_marker, allow_new) = sys.argv[1:]

def num(w):
    try:
        return int(w.get("number", -1))
    except (TypeError, ValueError):
        return -1
with open(path, encoding="utf-8") as f:
    data = json.load(f)

def mux_fields(entry):
    for key, value in (("tmuxTarget", tmux), ("herdrPane", herdr), ("cmuxWorkspace", cmux)):
        if value:
            entry[key] = value
        else:
            entry.setdefault(key, None)

if role == "manager":
    mgr = data.get("manager") or {
        "launchMode": "manual", "agentLaunched": True, "readinessMode": None,
        "readyFile": None, "marker": manager_marker or None, "spawned_at": now,
    }
    mux_fields(mgr)
    mgr["pid"] = int(pid) if pid else None
    mgr["pid_start_time"] = pid_start or None
    mgr["registeredAt"] = now
    data["manager"] = mgr
    print(f"manager pid {mgr['pid']}")
else:
    real = os.path.realpath(worktree)
    workers = data.setdefault("workers", [])
    entry = next((w for w in workers
                  if w.get("worktree") and os.path.realpath(w["worktree"]) == real), None)
    if entry is None and allow_new != "1":
        print("main checkout is not a listed worker; pass --session to register it", file=sys.stderr)
        sys.exit(4)
    if entry is None:
        taken = {num(w) for w in workers}
        number = None
        if marker_number:
            number = int(marker_number)
        else:
            m = re.fullmatch(re.escape(os.path.realpath(root)) + r"-wt-(\d+)", real)
            if m:
                number = int(m.group(1))
        if number is None or number in taken:
            number = max(taken | {0}) + 1
        entry = {"number": number, "launchMode": "manual", "commandMode": "fix-loop",
                 "agentLaunched": True}
        workers.append(entry)
        workers.sort(key=num)
        verb = "registered"
    else:
        verb = "updated"
    entry["worktree"] = worktree
    entry["branch"] = branch or None
    mux_fields(entry)
    entry["pid"] = int(pid) if pid else None
    entry["pid_start_time"] = pid_start or None
    if state or verb == "registered":
        entry["state"] = state or "started"
        entry["stateUpdatedAt"] = now
    entry["registeredAt"] = now
    print(f"worker {entry['number']} {verb}")

fd, tmp = tempfile.mkstemp(prefix=".manifest.", suffix=".json", dir=os.path.dirname(path))
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    os.replace(tmp, path)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)
PY
) 9>"$LOCK"
RC=$?
case $RC in
  0) exit 0 ;;
  3) note "manifest $MANIFEST disappeared; nothing to register"; exit 0 ;;
  4) note "not registering $WORKTREE"; exit 0 ;;
  *) note "could not update $MANIFEST (rc=$RC)"; exit 1 ;;
esac
