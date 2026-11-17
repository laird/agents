#!/bin/bash
# tests/test_merge_queue_orphan.sh — a merge job stopped while still WAITING in the host
# landing queue leaves no `flock -w` waiter behind (#226).
#
# The holder subshell used to wait in a foreground `flock -w <wait> 8`. Stopping the job
# did not stop it: merge_queue_release returned early (nothing held yet), and even killing
# the subshell orphaned the flock child, which kept waiting up to 7200 s and then took the
# lock from the next real job. Asserted here on the real property: no flock process on the
# lock file survives, and the lock is free the moment the outside holder lets go.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$ROOT/plugins/autocoder/scripts"
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
command -v flock >/dev/null || { echo "SKIP: no flock"; echo "Tests: 0 failed, 0 passed, 0 total"; exit 0; }

TMP=$(mktemp -d)
cleanup() { [ -n "${EXT:-}" ] && kill "$EXT" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT
export AUTOCODER_TMP="$TMP/tmp"; mkdir -p "$AUTOCODER_TMP"
export AUTOCODER_MERGE_QUEUE_WAIT=600

git init -q "$TMP/repo"
KEY=$(bash -c "source '$S/repo-id-fns.sh'; source '$S/merge-queue-fns.sh'; merge_queue_key '$TMP/repo' master")
LOCK="$AUTOCODER_TMP/autocoder-land-${KEY}.lock"

# waiters: pids of flock processes that have our lock file open.
waiters() {
  local p
  for p in $(pgrep -x flock 2>/dev/null); do
    ls -l "/proc/$p/fd" 2>/dev/null | grep -qF "$LOCK" && echo "$p"
  done
}
hold_externally() {   # another job holds the lock
  ( exec 9>>"$LOCK"; flock 9; : > "$TMP/ext.held"; sleep 300 ) & EXT=$!
  for _ in $(seq 1 50); do [ -e "$TMP/ext.held" ] && break; sleep 0.1; done
  rm -f "$TMP/ext.held"
}
release_externally() { kill "$EXT" 2>/dev/null; wait "$EXT" 2>/dev/null; EXT=""; sleep 0.3; }
lock_free() { ( exec 9>>"$LOCK"; flock -n 9 ); }
# job <mode>: a "merge job" that queues and is then stopped. Its pid goes to $TMP/job.pid.
start_job() {
  bash -c "
    source '$S/repo-id-fns.sh'; source '$S/merge-queue-fns.sh'
    trap 'merge_queue_release; exit 143' TERM
    echo \$\$ > '$TMP/job.pid'
    merge_queue_acquire '$TMP/repo' master 999 > '$TMP/job.log' 2>&1
    sleep 300
  " & JOB=$!
  for _ in $(seq 1 50); do [ -n "$(waiters)" ] && break; sleep 0.2; done
}

# ── 1. job stopped (TERM, trap runs) while waiting ──────────────────────────
hold_externally
start_job
[ -n "$(waiters)" ] && ok "the job is waiting in the queue (a flock waiter exists)" || bad "job never queued"
kill -TERM "$JOB"; wait "$JOB" 2>/dev/null
sleep 1
[ -z "$(waiters)" ] && ok "TERM: no flock waiter left behind" || bad "TERM: orphaned flock waiter(s): $(waiters)"
release_externally
lock_free && ok "TERM: the lock is free as soon as the outside holder lets go" || bad "TERM: lock still taken"

# ── 2. job SIGKILLed while waiting (no trap at all) ─────────────────────────
hold_externally
start_job
[ -n "$(waiters)" ] && ok "second job is waiting" || bad "second job never queued"
kill -KILL "$JOB"; wait "$JOB" 2>/dev/null
for _ in $(seq 1 20); do [ -z "$(waiters)" ] && break; sleep 0.25; done
[ -z "$(waiters)" ] && ok "KILL: the waiter notices its owner died and stops" || bad "KILL: orphaned flock waiter(s): $(waiters)"
release_externally
lock_free && ok "KILL: the lock is free as soon as the outside holder lets go" || bad "KILL: lock still taken"

# ── 3. the queue still works: a waiter gets the lock when the holder leaves ─
hold_externally
bash -c "
  source '$S/repo-id-fns.sh'; source '$S/merge-queue-fns.sh'
  merge_queue_acquire '$TMP/repo' master 998 > '$TMP/job3.log' 2>&1
  echo \"held=\$MERGE_QUEUE_HELD\" > '$TMP/job3.out'
  merge_queue_release
" & J3=$!
sleep 3
release_externally
wait "$J3"
grep -q 'held=1' "$TMP/job3.out" 2>/dev/null && ok "a waiting job takes the lock when the holder leaves" || bad "job3: $(cat "$TMP/job3.out" "$TMP/job3.log" 2>/dev/null)"
grep -q "Our turn to land" "$TMP/job3.log" && ok "and says it was its turn" || bad "job3 log: $(cat "$TMP/job3.log")"
sleep 0.5
lock_free && ok "after release the lock is free" || bad "lock still held after release"

echo ""
echo "Tests: $FAIL failed, $PASS passed, $((PASS + FAIL)) total"
[ "$FAIL" -eq 0 ]
