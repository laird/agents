#!/bin/bash
# tests/test_worker_idle.sh — pin the idle-detection rules that a manager got
# wrong in production: it read a bare `❯` prompt as idle and dispatched work
# over three workers that were 7, 19 and 23 minutes into live tasks, and it
# treated its own pane as a fourth worker so one dispatch typed itself into the
# manager's own input box.
#
# Runs against a real tmux server (its own throwaway socket), so the checks
# exercise capture-pane/display-message rather than a mock. Skips cleanly when
# tmux is unavailable.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IDLE="$ROOT/plugins/autocoder/scripts/worker-idle.sh"

assert_eq() {
  local label="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    echo "PASS: $label"; PASS=$((PASS + 1))
  else
    echo "FAIL: $label — want '$want', got '$got'"; FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local label="$1" needle="$2" hay="$3"
  case "$hay" in
    *"$needle"*) echo "PASS: $label"; PASS=$((PASS + 1)) ;;
    *) echo "FAIL: $label — '$needle' not in: $hay"; FAIL=$((FAIL + 1)) ;;
  esac
}

if ! command -v tmux >/dev/null 2>&1; then
  echo "SKIP: tmux not installed"
  echo "0 passed / 0 failed / 0 total"
  exit 0
fi

SOCK="worker-idle-test-$$"
TM="tmux -L $SOCK"
cleanup() { $TM kill-server >/dev/null 2>&1; }
trap cleanup EXIT

# ── Fixture 1: a pane that LOOKS idle the way the old heuristic looked at it —
#    a bare `❯` prompt on the last line — but is actively working: a status
#    line above it ticks an elapsed timer, exactly like the real TUI. The old
#    rule called this idle. It must read BUSY.
$TM new-session -d -s busy -x 100 -y 20 \
  "printf '● Bash(npm run build)\n'; i=0; while :; do i=\$((i+1)); printf '\r✽ Determining… (%dm %ds · ↓ 25.8k tokens)\n❯ \n' \$((i/60)) \$((i%60)); sleep 1; done" \
  >/dev/null 2>&1
BUSY_PANE=$($TM list-panes -t busy -F '#{pane_id}' | head -1)

# ── Fixture 2: a genuinely finished worker — emitted the idle sentinel and
#    stopped producing output.
$TM new-session -d -s idle -x 100 -y 20 \
  "printf 'IDLE_NO_WORK_AVAILABLE\n❯ \n'; sleep 600" >/dev/null 2>&1
IDLE_PANE=$($TM list-panes -t idle -F '#{pane_id}' | head -1)

sleep 2  # let both panes render

export AUTOCODER_IDLE_SETTLE_SECONDS=3
export AUTOCODER_TMUX_SOCKET="$SOCK"

# ── Test 1: the regression itself. Bare prompt + live work => BUSY, exit 1.
OUT=$(env -u TMUX -u TMUX_PANE "$IDLE" --pane "$BUSY_PANE" 2>&1); RC=$?
assert_eq "working pane with bare prompt is BUSY (exit 1)" "1" "$RC"
assert_contains "busy verdict is reported" "BUSY" "$OUT"

# ── Test 2: a truly finished pane reads IDLE, exit 0. Guards against
#    over-correcting into "always busy", which would stall every dispatch.
OUT=$(env -u TMUX -u TMUX_PANE "$IDLE" --pane "$IDLE_PANE" 2>&1); RC=$?
assert_eq "finished pane is IDLE (exit 0)" "0" "$RC"
assert_contains "idle verdict is reported" "IDLE" "$OUT"

# ── Test 3: the caller's own pane is refused as a dispatch target. This is the
#    bug where the manager typed a worker prompt into its own input box.
OUT=$(TMUX_PANE="$IDLE_PANE" "$IDLE" --pane "$IDLE_PANE" 2>&1); RC=$?
assert_eq "own pane is refused (exit 2)" "2" "$RC"
assert_contains "own-pane refusal explains itself" "own pane" "$OUT"

# ── Test 4: --all excludes the caller's pane rather than classifying it.
OUT=$(TMUX_PANE="$IDLE_PANE" "$IDLE" --all 2>&1)
assert_contains "--all marks own pane SELF" "SELF" "$OUT"
assert_contains "--all still classifies the other pane BUSY" "BUSY" "$OUT"

# ── Test 5: the removed heuristic must not come back into the docs. A bare
#    prompt listed as an idle indicator is what caused this.
for doc in "$ROOT/plugins/autocoder/commands/monitor-workers.md" \
           "$ROOT/.agent/workflows/monitor-workers.md" \
           "$ROOT/plugins/autocoder/commands/manager-handoff.md" \
           "$ROOT/plugins/autocoder/commands/manager-resume.md"; do
  if grep -qE '^- Bare prompt .❯. with no active tool calls' "$doc" 2>/dev/null; then
    echo "FAIL: $(basename "$doc") still lists a bare prompt as an idle indicator"
    FAIL=$((FAIL + 1))
  else
    echo "PASS: $(basename "$doc") does not list a bare prompt as an idle indicator"
    PASS=$((PASS + 1))
  fi
done

# ── Test 6: modernize's swarm dispatch is EXECUTABLE code, and it carried the
#    same bug in a worse form: it grepped the last 15 lines for `❯|╰|$` and
#    auto-dispatched on a hit. `╰` is part of the TUI's own border, so every
#    busy worker matched. It must not pattern-match a prompt again.
MOD="$ROOT/plugins/modernize/commands/modernize.md"
if grep -qE 'grep -qiE "\(no\.\*issues\|waiting\|idle\|╰\|❯' "$MOD" 2>/dev/null; then
  echo "FAIL: modernize.md still dispatches on a prompt-character grep"; FAIL=$((FAIL + 1))
else
  echo "PASS: modernize.md does not dispatch on a prompt-character grep"; PASS=$((PASS + 1))
fi
assert_eq "modernize.md double-samples before dispatching" "yes" \
  "$(grep -qE 'S1" != "\$S2' "$MOD" && echo yes || echo no)"
assert_eq "modernize.md skips the manager's own pane" "yes" \
  "$(grep -q 'TMUX_PANE' "$MOD" && echo yes || echo no)"

# ── Test 7: the README's "How Dispatching Works" examples are copy-pasted by
#    operators, so a stale `capture-pane | tail -15  # Check` there reintroduces
#    the rule regardless of what the commands say.
RM="$ROOT/plugins/autocoder/README.md"
assert_eq "README does not teach a tail-based idle check" "0" \
  "$(grep -cE 'read-screen .*# Check if idle|capture-pane .*tail -15 +# Check' "$RM")"
assert_eq "README points at worker-idle" "yes" \
  "$(grep -q 'worker-idle' "$RM" && echo yes || echo no)"

# ── Test 8: Claude and Antigravity copies of Step 3 stay in parity (CLAUDE.md
#    requires it; the wrong rule lived in both).
A=$(sed -n '/### Step 3: Decide Which Workers Are Idle/,/### Step 4:/p' "$ROOT/plugins/autocoder/commands/monitor-workers.md")
B=$(sed -n '/### Step 3: Decide Which Workers Are Idle/,/### Step 4:/p' "$ROOT/.agent/workflows/monitor-workers.md")
assert_eq "Step 3 is identical in plugins/ and .agent/" "same" "$([ "$A" = "$B" ] && echo same || echo differs)"
assert_eq "Step 3 is non-empty" "yes" "$([ -n "$A" ] && echo yes || echo no)"

TOTAL=$((PASS + FAIL))
echo "$PASS passed / $FAIL failed / $TOTAL total"
[ "$FAIL" -eq 0 ]
