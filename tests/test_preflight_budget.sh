#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"
# tests/test_preflight_budget.sh — preflight-budget.sh, the host-wide preflight budget and the host-exclusive
# lock: the slot arithmetic, a slot taken and released around a command, the waiting line in arrival order
# with a hotfix overtaking, admission refused under a seeded load average and granted when it clears (a hotfix
# obeying it and first after), dead tickets and stale holders reaped, two racers never both admitted to one
# slot, the exclusive lock with the gate admitted ahead of a waiting preflight, the wait bound and the
# waited-file, and status. Every wait here is seconds; every bound is seeded, never the real host's.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/plugins/autocoder/scripts/preflight-budget.sh"
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want '$2', got '$3'"; fi; }
has() { if grep -qE -- "$2" <<<"$3"; then ok "$1"; else bad "$1 — '$2' not in: $(printf '%s' "$3" | tail -20)"; fi; }
hasnt() { if grep -qE -- "$2" <<<"$3"; then bad "$1 — '$2' unexpectedly in: $(printf '%s' "$3" | tail -20)"; else ok "$1"; fi; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export AUTOCODER_PREFLIGHT_DIR="$TMP/budget" AUTOCODER_PREFLIGHT_POLL_S=0.1 AUTOCODER_PREFLIGHT_LOAD_FACTOR=off \
       AUTOCODER_PREFLIGHT_WAIT_MAX_S=30 AUTOCODER_HOST_EXCLUSIVE_POLL_S=0.1 AUTOCODER_HOST_EXCLUSIVE_WAIT_MAX_S=30 \
       AUTOCODER_PREFLIGHT_ADMISSION_GAP_S=0
unset AUTOCODER_PREFLIGHT_SLOTS AUTOCODER_PREFLIGHT_PRIORITY AUTOCODER_PREFLIGHT_GATES_CMD AUTOCODER_LOADAVG_FILE AUTOCODER_HOST_CORES
run() { bash "$LIB" "$@"; }
reset() { rm -rf "$AUTOCODER_PREFLIGHT_DIR"; }
# Sequencing is by condition, never by a fixed sleep (the suite runs under load): a holder holds until its
# go-file appears (`hold FILE`), and `wait_for EXPR` polls up to 20 s for the next waiter's ticket or marker.
hold() { printf 'until [ -e "%s" ]; do sleep 0.05; done' "$1"; }
wait_for() { local i=0; until eval "$1"; do sleep 0.05; i=$((i + 1)); [ "$i" -lt 400 ] || { bad "wait_for timed out: $1"; return 1; }; done; }
tickets() { find "$AUTOCODER_PREFLIGHT_DIR/queue" -name '*.ticket' 2>/dev/null | wc -l; }

# ── 1. the arithmetic (pure, sourced) ────────────────────────────────────────────────────────
# the subshell's counters are its own: re-count from its output
_sub() { "$@" > "$TMP/sub.out" 2>&1; cat "$TMP/sub.out"; PASS=$((PASS + $(grep -c '^PASS:' "$TMP/sub.out"))); FAIL=$((FAIL + $(grep -c '^FAIL:' "$TMP/sub.out"))); }
_sub bash -c 'source "$1"; set -u
  eq()  { if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 — want '"'"'$2'"'"', got '"'"'$3'"'"'"; fi; }
  has() { if grep -qE -- "$2" <<<"$3"; then echo "PASS: $1"; else echo "FAIL: $1 — $2 not in: $3"; fi; }
  eq "gate cap: (total - reserve) / ceiling" 20480 "$(pfb_gate_cap_mib $((64*1024*1024)) 4 3 4096)"
  eq "gate cap: never under the floor" 4096 "$(pfb_gate_cap_mib $((8*1024*1024)) 4 3 4096)"
  eq "gate cap: unreadable memory reads the floor" 4096 "$(pfb_gate_cap_mib "" 4 3 4096)"
  eq "slots: floor((total - reserve - gates x cap) / slot)" 3 "$(pfb_slot_count $((64*1024*1024)) 4 0 20480 20480)"
  eq "slots: one running gate takes its cap away" 2 "$(pfb_slot_count $((64*1024*1024)) 4 1 20480 20480)"
  eq "slots: never under one" 1 "$(pfb_slot_count $((16*1024*1024)) 4 3 20480 20480)"
  eq "slots: unreadable memory is one slot" 1 "$(pfb_slot_count "" 4 0 20480 20480)"
  eq "slots: a smaller per-preflight memory gives more" 6 "$(pfb_slot_count $((64*1024*1024)) 4 0 20480 10240)"
  eq "rank: a hotfix branch is 0" 0 "$(pfb_priority_rank hotfix/12)"
  eq "rank: an ordinary branch is 1" 1 "$(pfb_priority_rank feature/issue-12)"
  eq "rank: --priority hotfix wins" 0 "$(pfb_priority_rank feature/x hotfix)"
  eq "rank: --priority ordinary demotes a hotfix branch" 1 "$(pfb_priority_rank hotfix/12 ordinary)"
  eq "rank: AUTOCODER_PREFLIGHT_PRIORITY counts" 0 "$(AUTOCODER_PREFLIGHT_PRIORITY=HOTFIX pfb_priority_rank feature/x)"
  eq "cpu: over" 0 "$(pfb_cpu_over 41.2 16.00; echo $?)"
  eq "cpu: not over at the limit" 1 "$(pfb_cpu_over 16.00 16.00; echo $?)"
  eq "cpu: an unknown load never refuses" 1 "$(pfb_cpu_over "" 16.00; echo $?)"
  eq "cpu: the limit is cores x factor" 24.00 "$(pfb_cpu_limit 16 1.5)"
  printf "MemTotal:       67108864 kB\n" > "$2/meminfo"
  eq "meminfo seam is read" 67108864 "$(AUTOCODER_PREFLIGHT_MEMINFO_FILE=$2/meminfo pfb_host_memory_kib)"
  AUTOCODER_PREFLIGHT_MEMINFO_FILE=$2/meminfo pfb_compute_slots
  eq "compute: slots from the host" 3 "$PFB_SLOTS"
  AUTOCODER_PREFLIGHT_MEMINFO_FILE=$2/meminfo AUTOCODER_PREFLIGHT_GATES_CMD="echo 2" pfb_compute_slots
  eq "compute: running gates (the command count) narrow it" 1 "$PFB_SLOTS"
  AUTOCODER_PREFLIGHT_MEMINFO_FILE=$2/meminfo AUTOCODER_PREFLIGHT_SLOTS=5 pfb_compute_slots
  eq "compute: AUTOCODER_PREFLIGHT_SLOTS overrides" 5 "$PFB_SLOTS"
  AUTOCODER_PREFLIGHT_MEMINFO_FILE=$2/meminfo AUTOCODER_PREFLIGHT_SLOT_MIB=10240 pfb_compute_slots
  eq "compute: per-preflight memory sizes the slot" 6 "$PFB_SLOTS"
  has "budget line names the inputs" "MemTotal 64 GiB, reserve 4 GiB, 0 running gate\(s\) x 20480 MiB cap, 10240 MiB per slot" "$(pfb_budget_line)"
' _ "$LIB" "$TMP"

# ── 2. run: a slot around a command, the command's exit, the slot free after ─────────────────
reset; export AUTOCODER_PREFLIGHT_SLOTS=1
out=$(run run --what smoke -- sh -c 'echo ran; exit 3' 2>&1); RC=$?
eq "run: the command's exit status" 3 "$RC"
has "run: the command ran" '^ran$' "$out"
has "run: the line names the slot and the sizing" 'preflight budget: slot 1/1 after [0-9]+s in line; 1 slot\(s\) \(AUTOCODER_PREFLIGHT_SLOTS' "$out"
st=$(run status 2>&1)
has "run: the slot is free after" '^held: 0$' "$st"
has "run: nobody waits after" '^waiting: 0$' "$st"
eq "run: no ticket left behind" 0 "$(find "$AUTOCODER_PREFLIGHT_DIR/queue" -name '*.ticket' 2>/dev/null | wc -l)"
out=$(run run -- 2>&1); RC=$?
eq "run: no command is usage (2)" 2 "$RC"
out=$(run bogus 2>&1); RC=$?
eq "an unknown command is usage (2)" 2 "$RC"

# ── 3. the line: arrival order, and a hotfix overtakes every ordinary waiter ─────────────────
reset
ORDER="$TMP/order"; : > "$ORDER"
run run --what A -- sh -c "echo A-start >> '$ORDER'; $(hold "$TMP/go3"); echo A-end >> '$ORDER'" 2>"$TMP/A.err" &
wait_for '[ -e "$AUTOCODER_PREFLIGHT_DIR/slots/slot-0.holder" ]'
run run --what B --branch feature/b -- sh -c "echo B >> '$ORDER'" 2>"$TMP/B.err" &
wait_for '[ "$(tickets)" -ge 1 ]'
run run --what C --branch feature/c -- sh -c "echo C >> '$ORDER'" 2>"$TMP/C.err" &
wait_for '[ "$(tickets)" -ge 2 ]'
run run --what D --branch hotfix/9 -- sh -c "echo D >> '$ORDER'" 2>"$TMP/D.err" &
wait_for '[ "$(tickets)" -ge 3 ]'; wait_for 'grep -q "1 hotfix ahead" "$TMP/B.err"'
touch "$TMP/go3"; wait
eq "line: the holder ends, the hotfix goes next, then arrival order" "A-start A-end D B C" "$(tr '\n' ' ' <"$ORDER" | sed 's/ $//')"
B=$(cat "$TMP/B.err"); D=$(cat "$TMP/D.err")
has "line: the wait names the holder (pid, started, what)" 'holders: slot 0: pid=[0-9]+ token=[^ ]+ started=20[0-9-]+T[0-9:]+Z priority=ordinary what=A' "$B"
has "line: the ordinary waiter's position once the hotfix arrived" 'behind 1 waiter\(s\), 1 hotfix ahead; this one is ordinary' "$B"
has "line: a hotfix says so" 'hotfix preflight: it takes the next free slot ahead of every ordinary waiter' "$D"
has "line: the hotfix waits behind nobody" 'behind 0 waiter\(s\), 0 hotfix ahead; this one is hotfix' "$D"
out=$(run run --branch hotfix/9 --what D2 -- bash "$LIB" status 2>&1)
has "line: a hotfix branch and the what are in the holder's detail" 'slot 0: pid=[0-9]+ token=[^ ]+ started=.* priority=hotfix branch=hotfix/9 what=D2' "$out"

# ── 4. CPU admission: refused under a seeded load, admitted when it clears; a hotfix obeys it ──
reset
LA="$TMP/loadavg"; printf '41.20 30.00 20.00 2/900 1\n' > "$LA"
export AUTOCODER_LOADAVG_FILE="$LA" AUTOCODER_HOST_CORES=16 AUTOCODER_PREFLIGHT_LOAD_FACTOR=1.0
out=$(AUTOCODER_PREFLIGHT_WAIT_MAX_S=1 run run -- sh -c 'echo MUST-NOT-RUN' 2>&1); RC=$?
eq "cpu: past the bound the run fails (1)" 1 "$RC"
hasnt "cpu: nothing ran" 'MUST-NOT-RUN' "$out"
has "cpu: the wait line says why" 'waiting: host 1-minute load 41.20 over 16 cores x 1.0 = 16.00; no new preflight starts until it falls \(position 1 in line' "$out"
has "cpu: the refusal names the reason and the remedy" 'no slot after [0-9]+s \(AUTOCODER_PREFLIGHT_WAIT_MAX_S=1\): host 1-minute load 41.20 over 16 cores x 1.0 = 16.00.*raise AUTOCODER_PREFLIGHT_LOAD_FACTOR' "$out"
out=$(AUTOCODER_PREFLIGHT_WAIT_MAX_S=1 run run --priority hotfix -- sh -c 'echo MUST-NOT-RUN' 2>&1); RC=$?
eq "cpu: a hotfix obeys the rule too" 1 "$RC"
has "cpu: the hotfix's line says it is a hotfix" 'this one is hotfix\)' "$out"
run run -- sh -c 'echo RAN-WHEN-CLEAR' > "$TMP/clear.out" 2>&1 &
wait_for 'grep -q "waiting: host 1-minute load 41.20" "$TMP/clear.out"'   # it is held by the load before it clears
printf '3.00 10.00 20.00 1/900 1\n' > "$LA"
wait $!; RC=$?; out=$(cat "$TMP/clear.out")
eq "cpu: admitted once the load clears" 0 "$RC"
has "cpu: it waited first" 'waiting: host 1-minute load 41.20' "$out"
has "cpu: then ran" '^RAN-WHEN-CLEAR$' "$out"
# a hotfix and an ordinary waiter both held by load: the hotfix is first when it clears
printf '41.20 30.00 20.00 2/900 1\n' > "$LA"; : > "$ORDER"
run run --what O -- sh -c "echo O >> '$ORDER'" 2>/dev/null &
wait_for '[ "$(tickets)" -ge 1 ]'
run run --priority hotfix --what H -- sh -c "echo H >> '$ORDER'" 2>/dev/null &
wait_for '[ "$(tickets)" -ge 2 ]'
printf '2.00 10.00 20.00 1/900 1\n' > "$LA"
wait
eq "cpu: when the load clears the hotfix is first" "H O" "$(tr '\n' ' ' <"$ORDER" | sed 's/ $//')"
out=$(AUTOCODER_PREFLIGHT_LOAD_FACTOR=3.0 bash -c 'printf "41.20 1 1 1/1 1\n" > "$1"; bash "$2" run -- echo factor-raised' _ "$LA" "$LIB" 2>&1)
has "cpu: a raised factor admits the same load" '^factor-raised$' "$out"
printf '41.20 30.00 20.00 2/900 1\n' > "$LA"
out=$(AUTOCODER_PREFLIGHT_LOAD_FACTOR=off run run -- echo rule-off 2>&1)
has "cpu: off disables the rule" '^rule-off$' "$out"
# the admission gap: a second admission within the gap waits for the load to catch up
printf '1.00 1 1 1/1 1\n' > "$LA"
out=$(AUTOCODER_PREFLIGHT_ADMISSION_GAP_S=60 AUTOCODER_PREFLIGHT_WAIT_MAX_S=0 bash -c 'bash "$1" run -- true 2>/dev/null; bash "$1" run -- echo second' _ "$LIB" 2>&1); RC=$?
has "cpu: one admission per gap; the second says so" 'a preflight was admitted [0-9]+s ago and the 1-minute load \(1.00\) has not caught up yet; one admission per 60s' "$out"
unset AUTOCODER_LOADAVG_FILE AUTOCODER_HOST_CORES; export AUTOCODER_PREFLIGHT_LOAD_FACTOR=off

# ── 5. dead tickets and stale holders are reaped; a dead holder never blocks the line ────────
reset; mkdir -p "$AUTOCODER_PREFLIGHT_DIR/queue" "$AUTOCODER_PREFLIGHT_DIR/slots"
sh -c 'exit 0' & DEAD=$!; wait "$DEAD"
printf 'pid=%s token=%s priority=ordinary what=ghost\n' "$DEAD" "$DEAD" > "$AUTOCODER_PREFLIGHT_DIR/queue/+1-00000000000000000001-$DEAD.ticket"
: > "$AUTOCODER_PREFLIGHT_DIR/slots/slot-0.lock"   # no flock held: the holder died
printf 'pid=%s token=%s started=2026-01-01T00:00:00Z what=ghost-holder\n' "$DEAD" "$DEAD" > "$AUTOCODER_PREFLIGHT_DIR/slots/slot-0.holder"
out=$(AUTOCODER_PREFLIGHT_WAIT_MAX_S=0 run run -- echo past-the-ghosts 2>&1); RC=$?
eq "reap: a dead ticket ahead and a dead holder do not block (admitted at once)" 0 "$RC"
has "reap: ran" '^past-the-ghosts$' "$out"
eq "reap: the dead ticket is gone" 0 "$(find "$AUTOCODER_PREFLIGHT_DIR/queue" -name "*-$DEAD.ticket" | wc -l)"
[ -e "$AUTOCODER_PREFLIGHT_DIR/slots/slot-0.holder" ] && bad "reap: the stale holder file is gone" || ok "reap: the stale holder file is gone"
# a recycled pid is not the same process: a token with a start time that differs reads as dead
printf 'pid=%s token=%s@1 priority=ordinary what=recycled\n' "$$" "$$" > "$AUTOCODER_PREFLIGHT_DIR/queue/+1-00000000000000000002-$$.ticket"
out=$(AUTOCODER_PREFLIGHT_WAIT_MAX_S=0 run run -- echo past-recycled 2>&1); RC=$?
eq "reap: a ticket whose pid was recycled (start time differs) is swept" 0 "$RC"

# ── 6. two racers never both hold one slot (flock, never a mkdir claim) ──────────────────────
reset; TRACE="$TMP/trace"; : > "$TRACE"
for i in 1 2 3 4 5 6; do
  run run --what "racer$i" -- sh -c "echo enter >> '$TRACE'; sleep 0.25; echo exit >> '$TRACE'" 2>/dev/null &
done
wait
python3 - "$TRACE" <<'PY' && ok "race: at most one holder at any moment over six racers" || bad "race: two racers held the one slot at once"
import sys
depth = peak = 0
for line in open(sys.argv[1]):
    depth += 1 if line.strip() == "enter" else -1
    peak = max(peak, depth)
sys.exit(0 if peak == 1 else 1)
PY
eq "race: every racer ran once" 6 "$(grep -c '^enter$' "$TRACE")"
export AUTOCODER_PREFLIGHT_SLOTS=2; : > "$TRACE"; reset
# four racers that hold until a go-file: two are admitted and two wait, whatever the host's speed
for i in 1 2 3 4; do run run -- sh -c "echo enter >> '$TRACE'; $(hold "$TMP/go6"); echo exit >> '$TRACE'" 2>/dev/null & done
wait_for '[ "$(grep -c "^enter$" "$TRACE")" -eq 2 ] && [ "$(tickets)" -eq 2 ]'
st=$(run status 2>&1)
has "race: two slots admit two at once" '^held: 2$' "$st"
has "race: and the other two wait" '^waiting: 2$' "$st"
eq "race: never a third while two hold" 2 "$(grep -c '^enter$' "$TRACE")"
touch "$TMP/go6"; wait
eq "race: every racer ran once the slots freed" 4 "$(grep -c '^enter$' "$TRACE")"
export AUTOCODER_PREFLIGHT_SLOTS=1
n_mkdir=$(grep -cE '(^|[^A-Za-z_-])mkdir( |$)' "$LIB"); n_mkdir_p=$(grep -cE '(^|[^A-Za-z_-])mkdir -p( |$)' "$LIB")
eq "claims: every mkdir in the library is mkdir -p (never an exit-status claim)" "$n_mkdir" "$n_mkdir_p"
has "claims: a ticket is a noclobber redirection" 'set -o noclobber' "$(cat "$LIB")"

# ── 7. the wait bound names the holder; the slot count widens while waiting ──────────────────
reset
run run --what long -- sh -c "$(hold "$TMP/go7")" 2>/dev/null &
wait_for '[ -e "$AUTOCODER_PREFLIGHT_DIR/slots/slot-0.holder" ]'
out=$(AUTOCODER_PREFLIGHT_WAIT_MAX_S=1 run run -- echo MUST-NOT-RUN 2>&1); RC=$?
touch "$TMP/go7"
eq "bound: past it the run fails (1)" 1 "$RC"
hasnt "bound: nothing ran" 'MUST-NOT-RUN' "$out"
has "bound: the failure names the holder" 'no slot after [0-9]+s \(AUTOCODER_PREFLIGHT_WAIT_MAX_S=1\): all 1 slot\(s\) held, 0 waiting ahead \(0 hotfix\); holders: slot 0: pid=[0-9]+ .*what=long' "$out"
wait
reset; printf 'MemTotal:       67108864 kB\n' > "$TMP/meminfo"
GATES="$TMP/gates"; echo 2 > "$GATES"
# two gates leave one slot, held; when the gates end the count widens to three and the waiter takes slot 2
( unset AUTOCODER_PREFLIGHT_SLOTS; export AUTOCODER_PREFLIGHT_MEMINFO_FILE="$TMP/meminfo" AUTOCODER_PREFLIGHT_GATES_CMD="cat '$GATES'"
  bash "$LIB" run --what first -- sh -c "$(hold "$TMP/go7b")" 2>/dev/null &
  wait_for '[ -e "$AUTOCODER_PREFLIGHT_DIR/slots/slot-0.holder" ]'
  bash "$LIB" run --what widened -- echo widened > "$TMP/widen.waiter" 2>&1 &
  wait_for 'grep -q "all 1 slot(s) held" "$TMP/widen.waiter"'
  echo 0 > "$GATES"
  wait_for 'grep -q "^widened$" "$TMP/widen.waiter"'
  touch "$TMP/go7b"; wait; cat "$TMP/widen.waiter" ) > "$TMP/widen.out"
has "widen: the waiter saw the budget move when the gates ended" 'the host budget moved while waiting \(1 -> 3 slot\(s\): 0 running gate\(s\) now\)' "$(cat "$TMP/widen.out")"
has "widen: and took a slot the host now had" 'preflight budget: slot [23]/3 after [0-9]+s in line' "$(cat "$TMP/widen.out")"
has "widen: ran" '^widened$' "$(cat "$TMP/widen.out")"

# ── 8. the host-exclusive lock: one at a time; the gate ahead of a waiting preflight ─────────
reset; : > "$ORDER"; EXD="$AUTOCODER_PREFLIGHT_DIR/exclusive"
run exclusive --name types --role preflight --what P1 -- sh -c "echo P1-start >> '$ORDER'; $(hold "$TMP/go8"); echo P1-end >> '$ORDER'" 2>"$TMP/P1.err" &
wait_for '[ -e "$EXD/types.lock.holder" ]'
run exclusive --name types --role preflight --what W -- sh -c "echo W >> '$ORDER'" 2>"$TMP/W.err" &
wait_for 'grep -q "waiting for the host-exclusive lock" "$TMP/W.err"'
run exclusive --name types --role gate --what G --waited-file "$TMP/G.waited" -- sh -c "echo G >> '$ORDER'" 2>"$TMP/G.err" &
wait_for 'ls "$EXD"/types.lock.wants.* >/dev/null 2>&1'; wait_for 'grep -q "the gate wants it next" "$TMP/W.err"'
run exclusive --name other --role preflight --what X -- sh -c "echo X >> '$ORDER'" 2>/dev/null &
wait_for 'grep -q "^X$" "$ORDER"'
sleep 1   # the gate's reported wait is whole seconds; give it one
touch "$TMP/go8"; wait
has "exclusive: another name is not held up (X ran while P1 held types)" '^X$' "$(head -2 "$ORDER")"
seq_types=$(grep -v '^X$' "$ORDER" | tr '\n' ' ' | sed 's/ $//')
eq "exclusive: the types lock's order is holder, gate, preflight" "P1-start P1-end G W" "$seq_types"
W=$(cat "$TMP/W.err"); G=$(cat "$TMP/G.err")
has "exclusive: the preflight waiter names the holder" 'types: waiting for the host-exclusive lock \([0-9]+s so far; one at a time host-wide\): pid=[0-9]+ token=[^ ]+ role=preflight since=20.* what=P1' "$W"
has "exclusive: and says the gate wants it next" 'the gate wants it next \(pid=[0-9]+ token=[^ ]+ role=gate since=.* what=G\)' "$W"
has "exclusive: the gate says who holds it" 'types: waiting for the host-exclusive lock .*what=P1' "$G"
has "exclusive: the gate reports its wait" 'types: the host-exclusive lock is ours after [0-9]+s' "$G"
waited=$(cat "$TMP/G.waited"); [[ "$waited" =~ ^[0-9]+$ ]] && [ "$waited" -ge 1 ] && ok "exclusive: the waited file holds the seconds ($waited)" || bad "exclusive: waited file '$waited'"
eq "exclusive: no wants marker or holder left" 0 "$(find "$AUTOCODER_PREFLIGHT_DIR/exclusive" -name '*.wants.*' -o -name '*.holder' | wc -l)"
run exclusive --name types --role preflight --what held -- sh -c "$(hold "$TMP/go8b")" 2>/dev/null &
wait_for '[ -e "$EXD/types.lock.holder" ]'
out=$(AUTOCODER_HOST_EXCLUSIVE_WAIT_MAX_S=1 run exclusive --name types --role gate -- echo MUST-NOT-RUN 2>&1); RC=$?
eq "exclusive: past the bound 125, a host condition" 125 "$RC"
hasnt "exclusive: nothing ran" 'MUST-NOT-RUN' "$out"
has "exclusive: the refusal names the holder" 'types: the host-exclusive lock did not come in [0-9]+s \(AUTOCODER_HOST_EXCLUSIVE_WAIT_MAX_S=1\): pid=[0-9]+ .*what=held' "$out"
st=$(run status 2>&1)
has "status: the exclusive lock and its holder" '^exclusive types: pid=[0-9]+ token=[^ ]+ role=preflight since=.* what=held$' "$st"
touch "$TMP/go8b"; wait
out=$(run exclusive --name 'bad name' --role gate -- true 2>&1); RC=$?
eq "exclusive: a bad name is usage (2)" 2 "$RC"
out=$(run exclusive --name ok --role owner -- true 2>&1); RC=$?
eq "exclusive: a bad role is usage (2)" 2 "$RC"
out=$(run exclusive --role gate -- true 2>&1); RC=$?
eq "exclusive: --name is required (2)" 2 "$RC"
out=$(AUTOCODER_HOST_EXCLUSIVE_ROLE=preflight run exclusive --name r -- sh -c "cat '$AUTOCODER_PREFLIGHT_DIR/exclusive/r.lock.holder'" 2>&1)
has "exclusive: the role defaults to AUTOCODER_HOST_EXCLUSIVE_ROLE" 'role=preflight' "$out"
out=$(run exclusive --name r -- sh -c "cat '$AUTOCODER_PREFLIGHT_DIR/exclusive/r.lock.holder'" 2>&1)
has "exclusive: and to gate without it" 'role=gate' "$out"

# ── 9. status: the slots, the holders, the waiters in order ──────────────────────────────────
reset
run run --what holder -- sh -c "$(hold "$TMP/go9")" 2>/dev/null &
wait_for '[ -e "$AUTOCODER_PREFLIGHT_DIR/slots/slot-0.holder" ]'
run run --what waiter1 -- true 2>/dev/null &
wait_for '[ "$(tickets)" -ge 1 ]'
run run --priority hotfix --what waiter2 -- true 2>/dev/null &
wait_for '[ "$(tickets)" -ge 2 ]'
st=$(run status 2>&1)
touch "$TMP/go9"
has "status: the budget line" '^preflight budget: 1 slot\(s\) \(AUTOCODER_PREFLIGHT_SLOTS' "$st"
has "status: held count" '^held: 1$' "$st"
has "status: the holder" '^  slot 0: pid=[0-9]+ token=[^ ]+ started=.* priority=ordinary what=holder$' "$st"
has "status: the hotfix waiter is first in line" '^  waiting 1: pid=[0-9]+ priority=hotfix what=waiter2$' "$st"
has "status: the ordinary waiter second" '^  waiting 2: pid=[0-9]+ priority=ordinary what=waiter1$' "$st"
has "status: waiting count" '^waiting: 2$' "$st"
wait

# ── 10. sourced use: pfb_acquire/pfb_release in the caller's shell keep the slot across commands ──
out=$(bash -c 'source "$1"; pfb_acquire --what sourced 2>/dev/null || exit 9; held_by_me="$PFB_SLOT_INDEX"; bash "$1" status 2>&1 | grep -c "what=sourced"; pfb_release; bash "$1" status 2>&1 | grep "^held:"' _ "$LIB" 2>&1)
eq "sourced: the slot is held between commands and free after release" "1
held: 0" "$out"

echo; echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
