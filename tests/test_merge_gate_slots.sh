#!/bin/bash
# tests/test_merge_gate_slots.sh — gates on one host share AUTOCODER_MAX_GATES slots.
#
# Every gate in merge-to-integration.sh runs inside a flock-held slot file
# ${AUTOCODER_TMP:-/tmp}/autocoder-gate-slot-<k>.lock. With AUTOCODER_MAX_GATES=1 and two
# merges started together (two repos, so neither the gate cache nor the push race can
# serialise them by accident), the second gate must start only after the first has
# ended, and the job that waited must say so in its log. With the cap at 2 the same two
# gates overlap, which proves the first assertion measured the semaphore and not the
# machine. The fake gate records its start and end as epoch seconds with nanoseconds.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$ROOT/plugins/autocoder/scripts"
MTI="$SCRIPT_DIR/merge-to-integration.sh"

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export ISSUE_SOURCE=file
export AUTOCODER_TMP="$TMP/tmp"; mkdir -p "$AUTOCODER_TMP"
export AUTOCODER_GATE_CACHE_DIR="$TMP/gate-cache"

# make_repo <name>: bare origin + worker on feature/code with content unique to <name>.
make_repo() {
  local d="$TMP/$1"
  git init --bare -q "$d-origin.git"
  git init -q "$d"
  git -C "$d" config user.email t@example.com; git -C "$d" config user.name T
  git -C "$d" remote add origin "$d-origin.git"
  echo "base $1" > "$d/README.md"
  git -C "$d" add -A; git -C "$d" commit -q -m init; git -C "$d" branch -M master; git -C "$d" push -q origin master
  git -C "$d" fetch -q origin; git -C "$d" checkout -q -b feature/code master
  echo "change $1" > "$d/app.txt"; git -C "$d" add -A; git -C "$d" commit -q -m fix
}
# The gate: log start, sleep, log end. $1 names the log.
gate() { printf 'date +%%s.%%N > %q; sleep 2; date +%%s.%%N > %q' "$TMP/$1.start" "$TMP/$1.end"; }
run_pair() {  # $1 = AUTOCODER_MAX_GATES
  rm -rf "$TMP"/r1* "$TMP"/r2* "$TMP"/*.start "$TMP"/*.end "$TMP/gate-cache"
  make_repo r1; make_repo r2
  (cd "$TMP/r1" && AUTOCODER_MAX_GATES="$1" bash "$MTI" --feature feature/code --issue 101 --integration master --test-cmd "$(gate r1)" > "$TMP/r1.log" 2>&1) &
  (cd "$TMP/r2" && AUTOCODER_MAX_GATES="$1" bash "$MTI" --feature feature/code --issue 102 --integration master --test-cmd "$(gate r2)" > "$TMP/r2.log" 2>&1) &
  wait
}
# Prints "first.end second.start" ordered by start time.
order() {
  if [ "$(cat "$TMP/r1.start")" \< "$(cat "$TMP/r2.start")" ]; then echo "$(cat "$TMP/r1.end") $(cat "$TMP/r2.start")"; else echo "$(cat "$TMP/r2.end") $(cat "$TMP/r1.start")"; fi
}

# ── one slot: strictly one after the other ──────────────────────────────────
run_pair 1
for r in r1 r2; do grep -q "merged into 'master'" "$TMP/$r.log" && ok "$r merged" || bad "$r did not merge: $(cat "$TMP/$r.log")"; done
[ -f "$TMP/r1.start" ] && [ -f "$TMP/r2.start" ] && ok "both gates ran" || bad "a gate never ran"
read -r FIRST_END SECOND_START <<< "$(order)"
python3 -c "import sys; sys.exit(0 if float('$SECOND_START') >= float('$FIRST_END') else 1)" \
  && ok "with 1 slot the second gate started ($SECOND_START) after the first ended ($FIRST_END)" \
  || bad "with 1 slot the gates overlapped: second started $SECOND_START, first ended $FIRST_END"
grep -q "All 1 gate slot(s) on this host are busy; waiting for slot 1" "$TMP/r1.log" "$TMP/r2.log" && ok "the waiting job logged that it waited" || bad "no waiting line in either log"
grep -q "Gate slot 1 acquired" "$TMP/r1.log" "$TMP/r2.log" && ok "the waiting job logged the acquisition" || bad "no acquisition line"
[ -f "$AUTOCODER_TMP/autocoder-gate-slot-1.lock" ] && ok "slot lock file lives under AUTOCODER_TMP" || bad "slot lock not under AUTOCODER_TMP: $(ls "$AUTOCODER_TMP")"

# ── two slots: the same pair overlaps, so the serialisation above was the cap ──
run_pair 2
read -r FIRST_END SECOND_START <<< "$(order)"
python3 -c "import sys; sys.exit(0 if float('$SECOND_START') < float('$FIRST_END') else 1)" \
  && ok "with 2 slots the gates overlapped (second started $SECOND_START before the first ended $FIRST_END)" \
  || bad "with 2 slots the gates still serialised: second started $SECOND_START, first ended $FIRST_END"
grep -q "waiting for slot" "$TMP/r1.log" "$TMP/r2.log" && bad "a job waited with 2 slots free" || ok "nobody waited with 2 slots"

# ── a bad or missing value falls back to max(1, nproc/4) and still gates ─────
rm -rf "$TMP"/r1* "$TMP"/*.start "$TMP"/*.end "$TMP/gate-cache"; make_repo r1
(cd "$TMP/r1" && AUTOCODER_MAX_GATES=0 bash "$MTI" --feature feature/code --issue 101 --integration master --test-cmd "$(gate r1)" > "$TMP/r1.log" 2>&1)
grep -q "merged into 'master'" "$TMP/r1.log" && [ -f "$TMP/r1.end" ] && ok "AUTOCODER_MAX_GATES=0 falls back to a sane cap and the gate runs" || bad "cap of 0 broke the gate: $(cat "$TMP/r1.log")"

TOTAL=$((PASS + FAIL))
echo "$PASS passed / $FAIL failed / $TOTAL total"
[ "$FAIL" -eq 0 ]
