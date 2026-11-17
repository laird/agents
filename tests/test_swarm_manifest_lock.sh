#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255: never write the real event logs
# tests/test_swarm_manifest_lock.sh — manifest_add_worker_json (add-worker.sh) and
# manifest_update_worker_state (restart-worker.sh) take the manifest lock (#238).
# Unlocked, either one racing a locked writer (swarm-register.sh, manifest_set_manager)
# dropped that writer's change. A script that already holds the lock for its whole run
# (start-workers.sh, remove-worker.sh) must not deadlock calling them.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../plugins/autocoder/scripts/swarm-manifest-lib.sh
source "$ROOT/plugins/autocoder/scripts/swarm-manifest-lib.sh"
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fixture() {
  local w1 workers manager
  w1=$(manifest_worker_json 1 "/tmp/w1" interactive agent-input true "s:%1" "" paused)
  workers=$(printf '%s\n' "$w1" | json_array_from_lines)
  manager=$(manifest_manager_json shell false shell "" "s:%0" "")
  MANIFEST="$TMP/$1/$SWARM_STATE_DIR/s.json"
  write_paused_manifest "$MANIFEST" s "$TMP/$1" project claude tmux file configured "" "" t main "$workers" "$manager"
  LOCK="${MANIFEST%.json}.lock"
}

# A locked writer, as swarm-register.sh does it: take the lock, read, (slowly) change
# the manager, write. Touches ready.flag once it has read, so the racing call starts
# inside its read-modify-write window.
slow_locked_writer() {
  (
    flock -x 9
    python3 - "$MANIFEST" "$TMP/ready.flag" <<'PY'
import json, os, sys, time
path, flag = sys.argv[1:]
data = json.load(open(path))
open(flag, "w").close()
time.sleep(1.5)
data["manager"] = {"registered": "by-locked-writer"}
tmp = path + ".tmp"
json.dump(data, open(tmp, "w"))
os.replace(tmp, path)
PY
  ) 9>"$LOCK"
}
wait_ready() { local i; for i in $(seq 50); do [ -f "$TMP/ready.flag" ] && return; sleep 0.1; done; }
mgr()    { python3 -c 'import json,sys; print((json.load(open(sys.argv[1])).get("manager") or {}).get("registered",""))' "$MANIFEST"; }
nums()   { python3 -c 'import json,sys; print(" ".join(str(w["number"]) for w in json.load(open(sys.argv[1]))["workers"]))' "$MANIFEST"; }
wstate() { manifest_get "$MANIFEST" "next(w['state'] for w in m['workers'] if w['number'] == $1)"; }

# ── 1. add-worker racing a locked writer: both changes survive ─────────────
fixture add; rm -f "$TMP/ready.flag"
slow_locked_writer & P=$!
wait_ready
manifest_add_worker_json "$MANIFEST" "$(manifest_worker_json 2 /tmp/w2 interactive agent-input true "s:%2" "" paused)"
wait "$P"
[ "$(mgr)" = by-locked-writer ] && ok "add-worker: the locked writer's manager change survives" || bad "manager change lost: '$(mgr)'"
[ "$(nums)" = "1 2" ] && ok "add-worker: the new worker survives" || bad "workers: '$(nums)'"

# ── 2. restart-worker racing a locked writer ────────────────────────────────
fixture restart; rm -f "$TMP/ready.flag"
manifest_update_worker_state "$MANIFEST" 1 started
slow_locked_writer & P=$!
wait_ready
manifest_update_worker_state "$MANIFEST" 1 paused
wait "$P"
[ "$(mgr)" = by-locked-writer ] && ok "restart-worker: the locked writer's manager change survives" || bad "manager change lost: '$(mgr)'"
[ "$(wstate 1)" = paused ] && ok "restart-worker: the worker state change survives" || bad "worker 1 state: '$(wstate 1)'"

# ── 3. a caller already holding the lock (start-workers.sh, remove-worker.sh) ─
fixture held
OUT=$(timeout 10 bash -c '
  source "$1/plugins/autocoder/scripts/swarm-manifest-lib.sh"
  exec 9>"$3"; flock -x 9; SWARM_MANIFEST_LOCK_HELD="$3"
  manifest_update_worker_state "$2" 1 started &&
  manifest_add_worker_json "$2" "$(manifest_worker_json 3 /tmp/w3 interactive agent-input true "s:%3" "" paused)" &&
  manifest_remove_workers "$2" 3 && echo done' _ "$ROOT" "$MANIFEST" "$LOCK" 2>&1); RC=$?
[ "$RC" -eq 0 ] && [ "$OUT" = done ] && ok "a lock holder calls the helpers without deadlocking" || bad "lock holder: rc=$RC out=$OUT"
[ "$(wstate 1)" = started ] && [ "$(nums)" = 1 ] && ok "the lock holder's writes landed" || bad "after lock holder: workers '$(nums)', state '$(wstate 1)'"

# A holder of a DIFFERENT session's lock still locks this one.
fixture other; OTHER_LOCK="$TMP/elsewhere.lock"
exec 8>"$LOCK"; flock -x 8   # this session's lock is busy
timeout 2 bash -c '
  source "$1/plugins/autocoder/scripts/swarm-manifest-lib.sh"
  SWARM_MANIFEST_LOCK_HELD="$3"; manifest_update_worker_state "$2" 1 started' _ "$ROOT" "$MANIFEST" "$OTHER_LOCK"
[ $? -eq 124 ] && ok "holding another session's lock does not skip this one's" || bad "wrote without this session's lock"
exec 8>&-

echo ""
echo "Tests: $FAIL failed, $PASS passed, $((PASS + FAIL)) total"
[ "$FAIL" -eq 0 ]
