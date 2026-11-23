#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255: never write the real event logs
# tests/test_merge_launch_train_carries.sh — merge-launch.sh refuses a branch the live merge train carries.
#
# A branch the train has planned, assembled or is gating (current.tsv under the train's state dir) is
# being landed by the train's gate; a second gate over the same commits makes whichever publishes second
# pay a full re-gate. So the launcher asks `merge-train.py carried --branch B` and refuses with exit 4,
# naming the member and its tip. A branch the train does not carry launches as before, and so does a
# launcher whose directory has no merge-train.py (the check cannot run, and says so only when it ran and
# failed).
#
# The detached merge-to-integration.sh is replaced with a stub that records its arguments.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$ROOT/plugins/autocoder/scripts"

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export AUTOCODER_TMP="$TMP/tmp"; mkdir -p "$AUTOCODER_TMP"
export AUTOCODER_TRAIN_STATE="$TMP/train-state"; mkdir -p "$AUTOCODER_TRAIN_STATE"

# A live train is a runner holding the state dir's lease (train_run.Lease, an flock): hold it from a
# sleeper for the carried cases, and release it for the "no live train" case.
# The holder blocks for the lock rather than failing fast (#356): the poll below takes LOCK_SH for an
# instant to see whether the lease is held, and on a loaded machine that instant can overlap the
# holder's first attempt. LOCK_NB turned that overlap into a BlockingIOError and a failed fixture.
# The poll allows 10s (was 5s) because the holder is a fresh python3 that may start slowly under the
# same load.
hold_lease() {
  python3 - "$AUTOCODER_TRAIN_STATE/lease.lock" <<'HOLD' &
import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o644)
fcntl.flock(fd, fcntl.LOCK_EX)
print("held", flush=True)
time.sleep(120)
HOLD
  LEASE_PID=$!
  for _ in $(seq 1 100); do python3 -c '
import fcntl, os, sys
fd = os.open(sys.argv[1], os.O_RDONLY)
try:
    fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
except OSError:
    sys.exit(0)
sys.exit(1)' "$AUTOCODER_TRAIN_STATE/lease.lock" 2>/dev/null && return 0; sleep 0.1; done
  echo "fixture: could not take the lease" >&2; return 1
}
release_lease() { [ -n "${LEASE_PID:-}" ] && kill "$LEASE_PID" 2>/dev/null; wait "$LEASE_PID" 2>/dev/null; LEASE_PID=""; }
trap 'release_lease; rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin"
cp "$SCRIPT_DIR/merge-launch.sh" "$SCRIPT_DIR/test-cmd-fns.sh" "$SCRIPT_DIR/repo-id-fns.sh" \
   "$SCRIPT_DIR/feature-ref-fns.sh" "$SCRIPT_DIR/git-net-fns.sh" "$SCRIPT_DIR/merge-archive-fns.sh" \
   "$SCRIPT_DIR/merge-train.py" "$SCRIPT_DIR/train_lib.py" "$TMP/bin/"
cat > "$TMP/bin/merge-to-integration.sh" <<STUB
#!/bin/bash
printf '%s\n' "\$@" > "$TMP/mti-args"
STUB
chmod +x "$TMP/bin/merge-to-integration.sh"

g() { git -c user.email=t@example.com -c user.name=T "$@"; }

git init -q --bare -b master "$TMP/origin.git"
g clone -q "$TMP/origin.git" "$TMP/worker" 2>/dev/null
cd "$TMP/worker" || exit 1
echo base > f; g add f; g commit -qm base; g push -q origin HEAD:master
g checkout -q -b feature/issue-41
echo change >> f; g commit -qam change; g push -q origin feature/issue-41
TIP=$(git rev-parse --short=10 HEAD)

wait_args() { for _ in $(seq 1 50); do [ -s "$TMP/mti-args" ] && return 0; sleep 0.1; done; return 1; }
settle() { for _ in $(seq 1 50); do pgrep -f "merge-to-integration.sh" >/dev/null 2>&1 || return 0; sleep 0.1; done; }

# ── the train carries the branch: refused, nothing launched ─────────────────────────────
printf '41\tfeature/issue-41\t%s\n' "$TIP" > "$AUTOCODER_TRAIN_STATE/current.tsv"
hold_lease && ok "fixture: a runner holds the train's lease" || bad "fixture: lease"
rm -f "$TMP/mti-args"
OUT=$(bash "$TMP/bin/merge-launch.sh" --feature feature/issue-41 --issue 41 \
  --integration master --test-cmd "true" 2>&1); RC=$?
[ "$RC" -eq 4 ] && ok "a branch the train carries is refused with exit 4" || { bad "carried branch: exit $RC"; echo "$OUT"; }
grep -q "A merge train already carries feature/issue-41 (#41 @ $TIP)" <<<"$OUT" \
  && ok "the refusal names the member and its tip" || { bad "refusal text"; echo "$OUT"; }
sleep 0.5
[ ! -e "$TMP/mti-args" ] && ok "no merge job was started" || bad "a merge job started for a carried branch"
[ ! -e "$AUTOCODER_TMP"/autocoder-merge-*-41.pid ] && ok "no pidfile was written" || bad "a pidfile was written for a refused launch"

# ── another branch in the train: this one launches ──────────────────────────────────────
printf '42\tfeature/issue-42\tabc1234567\n' > "$AUTOCODER_TRAIN_STATE/current.tsv"
rm -f "$TMP/mti-args"
OUT=$(bash "$TMP/bin/merge-launch.sh" --feature feature/issue-41 --issue 41 \
  --integration master --test-cmd "true" 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok "a branch the train does not carry launches" || { bad "uncarried branch: exit $RC"; echo "$OUT"; }
wait_args && grep -qx "feature/issue-41" "$TMP/mti-args" && ok "the job was given the branch" || bad "no job for the uncarried branch"
grep -q "Could not ask the merge train" <<<"$OUT" && bad "a clean check printed the cannot-ask warning" || ok "no warning when the check ran"
settle

# ── the runner died and left current.tsv behind: no live train, launches ────────────────
printf '41\tfeature/issue-41\t%s\n' "$TIP" > "$AUTOCODER_TRAIN_STATE/current.tsv"
release_lease
rm -f "$TMP/mti-args"
OUT=$(bash "$TMP/bin/merge-launch.sh" --feature feature/issue-41 --issue 41 \
  --integration master --test-cmd "true" 2>&1); RC=$?
[ "$RC" -eq 0 ] && wait_args && ok "a killed train's leftover current.tsv refuses nothing" || { bad "stale train state: exit $RC"; echo "$OUT"; }
settle

# ── no train state at all: launches ─────────────────────────────────────────────────────
rm -f "$AUTOCODER_TRAIN_STATE/current.tsv" "$TMP/mti-args"
OUT=$(bash "$TMP/bin/merge-launch.sh" --feature feature/issue-41 --issue 41 \
  --integration master --test-cmd "true" 2>&1); RC=$?
[ "$RC" -eq 0 ] && wait_args && ok "no live train: launches" || { bad "no train state: exit $RC"; echo "$OUT"; }
settle

# ── the check itself cannot run: said, and the launch goes ahead ────────────────────────
printf '41\tfeature/issue-41\t%s\n' "$TIP" > "$AUTOCODER_TRAIN_STATE/current.tsv"
hold_lease || bad "fixture: lease (again)"
rm -f "$TMP/bin/train_lib.py" "$TMP/mti-args"
OUT=$(bash "$TMP/bin/merge-launch.sh" --feature feature/issue-41 --issue 41 \
  --integration master --test-cmd "true" 2>&1); RC=$?
[ "$RC" -eq 0 ] && wait_args && ok "a check that cannot run does not block the launch" || { bad "broken check: exit $RC"; echo "$OUT"; }
grep -q "Could not ask the merge train whether it carries feature/issue-41" <<<"$OUT" \
  && ok "the broken check is said" || { bad "broken check not reported"; echo "$OUT"; }
settle

# ── no merge-train.py beside the launcher: said, and the launch goes ahead ──────────────
rm -f "$TMP/bin/merge-train.py" "$TMP/mti-args"
OUT=$(bash "$TMP/bin/merge-launch.sh" --feature feature/issue-41 --issue 41 \
  --integration master --test-cmd "true" 2>&1); RC=$?
[ "$RC" -eq 0 ] && wait_args && ok "a launcher without merge-train.py launches" || { bad "no merge-train.py: exit $RC"; echo "$OUT"; }
grep -q "Could not ask the merge train whether it carries feature/issue-41 (no merge-train.py beside" <<<"$OUT" \
  && ok "the missing check is said" || { bad "missing check not reported"; echo "$OUT"; }
settle

echo ""
echo "Tests: $FAIL failed, $PASS passed, $((PASS + FAIL)) total"
[ "$FAIL" -eq 0 ]
