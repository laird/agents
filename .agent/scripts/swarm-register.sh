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
#               agent CLI (claude, codex, gemini, droid, pi, grok, node), else $PPID
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
# A live manager already recorded is not displaced by another process (a second
# /monitor-loop run by hand in another pane): --manager leaves the entry alone
# unless the recorded pid is dead, recycled, this process, or one of its
# ancestors (the pane shell that launched this agent), or no agent CLI runs at
# or under it any more (the pane shell outlived its agent) (#217). An entry
# with no pid_start_time cannot be proven live and is replaced.
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
# Remember this swarm root for reboot recovery (#275): on a tmux host nothing
# else names it after a reboot. Best effort.
# shellcheck source=reboot-lib.sh
source "$SCRIPT_DIR/reboot-lib.sh"
swarm_roots_register "$PROJECT_ROOT"
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
      claude|codex|gemini|droid|pi|grok|node|claude-*) echo "$pid"; return 0 ;;
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

# This process's ancestors, so a manager entry recorded as the pane shell
# (an ancestor of the agent) is recognised as the same manager.
ANCESTORS=""
_a=$$
for _i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  _a=$(ps -o ppid= -p "$_a" 2>/dev/null | tr -d ' ')
  [ -n "$_a" ] && [ "$_a" -gt 1 ] 2>/dev/null || break
  ANCESTORS="$ANCESTORS $_a"
done
# Is an agent CLI running at PID or anywhere under it? A pane shell recorded as
# the manager outlives the agent, so a live shell alone is not a live manager.
agent_at_or_under() {
  ps -e -o pid=,ppid=,comm= 2>/dev/null | awk -v root="$1" '
    { pid[NR]=$1; ppid[NR]=$2; c=$3; sub(/.*\//, "", c); comm[NR]=c; n=NR }
    END {
      want[root]=1
      do { grew=0
        for (i=1; i<=n; i++) if (!(pid[i] in want) && (ppid[i] in want)) { want[pid[i]]=1; grew=1 }
      } while (grew)
      for (i=1; i<=n; i++) if (pid[i] in want && comm[i] ~ /^(claude|codex|gemini|droid|pi|grok|node|claude-.*)$/) { found=1 }
      exit !found
    }'
}

LOCK="${MANIFEST%.json}.lock"
(
  flock -x 9
  [ -f "$MANIFEST" ] || exit 3
  # Read the recorded manager under the lock, so the pid checked is the one
  # the write below would replace.
  LIVE_MGR_START=""
  if [ "$ROLE" = manager ]; then
    _mpid=$(python3 -c 'import json,sys; m=json.load(open(sys.argv[1])).get("manager") or {}; print(m.get("pid") or "")' "$MANIFEST" 2>/dev/null)
    case "$_mpid" in
      ''|*[!0-9]*) ;;
      *) if agent_at_or_under "$_mpid"; then
           LIVE_MGR_START=$(process_start_time "$_mpid" 2>/dev/null || true)
         fi ;;
    esac
  fi
  python3 - "$MANIFEST" "$ROLE" "$WORKTREE" "$PROJECT_ROOT" "$BRANCH" "$MARKER_NUMBER" \
    "$PID" "$PID_START" "$STATE" "$NOW" "${TMUX_PANE:-}" "${HERDR_PANE_ID:-}" "${CMUX_WORKSPACE_ID:-}" \
    "${AUTOCODER_MANAGER:+AUTOCODER_MANAGER=${AUTOCODER_MANAGER}}" "$ALLOW_NEW" \
    "$ANCESTORS" "$LIVE_MGR_START" <<'PY'
import json, os, re, sys, tempfile

(path, role, worktree, root, branch, marker_number, pid, pid_start, state, now,
 tmux, herdr, cmux, manager_marker, allow_new, ancestors, live_mgr_start) = sys.argv[1:]

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
    old = data.get("manager") or {}
    old_pid = str(old.get("pid") or "")
    # live_mgr_start is the recorded pid's current start token, set only when an
    # agent CLI runs at or under it; it counts only when it matches the token
    # recorded with that pid (otherwise the pid was recycled).
    if (old_pid and old_pid != pid and old_pid not in ancestors.split()
            and live_mgr_start and str(old.get("pid_start_time") or "") == live_mgr_start):
        print(f"live manager pid {old_pid} already registered; not replacing it", file=sys.stderr)
        sys.exit(4)
    mgr = data.get("manager") or {
        "launchMode": "manual", "agentLaunched": True, "readinessMode": None,
        "readyFile": None, "marker": manager_marker or None, "spawned_at": now,
    }
    mux_fields(mgr)
    mgr["pid"] = int(pid) if pid else None
    mgr["pid_start_time"] = pid_start or None
    mgr["registeredAt"] = now
    data["manager"] = mgr
    data["state"] = "running"   # a live manager means the swarm runs (#218)
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
    data["state"] = "running"   # a live worker means the swarm runs (#218)
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
  4) note "not registering ${ROLE} for $WORKTREE"; exit 0 ;;
  *) note "could not update $MANIFEST (rc=$RC)"; exit 1 ;;
esac
