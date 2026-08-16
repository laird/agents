#!/bin/bash
# tests/test_mux_send_enter.sh — pin that prompt submission uses a SEPARATE Enter.
#
# `tmux send-keys -t <pane> "$text" Enter` in one call reliably leaves the text
# sitting unsubmitted in an agent TUI's input box: the TUI takes the burst as a
# single paste and treats the trailing newline as pasted content rather than as
# submit. The failure is invisible from the outside — the pane shows the text,
# so a capture-pane marker grep reports success while the agent never saw it.
# The dispatch silently does nothing and the worker is later misread as idle.
#
# This test exists because that regression is a one-line "simplification" away:
# collapsing the two calls back into one looks tidier and passes every check
# that does not look for exactly this.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

ok()   { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad()  { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
check() { [ "$2" = "$3" ] && ok "$1" || bad "$1 — want '$3', got '$2'"; }

for lib in plugins/autocoder/scripts/mux-send-lib.sh .agent/scripts/mux-send-lib.sh; do
  f="$ROOT/$lib"
  [ -f "$f" ] || { bad "$lib exists"; continue; }
  ok "$lib exists"

  body=$(awk '/^send_tmux_text_enter\(\)/,/^}/' "$f")

  # Two send-keys calls, not one.
  check "$lib: send_tmux_text_enter issues two send-keys calls" \
    "$(printf '%s' "$body" | grep -c 'send-keys')" "2"

  # The text call must NOT carry a trailing Enter/C-m.
  if printf '%s' "$body" | grep -q 'send-keys -t "\$target" "\$text" *\(Enter\|C-m\)'; then
    bad "$lib: text call must not carry a trailing Enter/C-m"
  else
    ok "$lib: text call carries no trailing Enter/C-m"
  fi

  # A bare Enter must be sent on its own.
  printf '%s' "$body" | grep -q 'send-keys -t "\$target" Enter' \
    && ok "$lib: submits with a standalone Enter" \
    || bad "$lib: no standalone Enter send"

  # The settle delay is what makes it reliable; zero works sometimes, which is
  # worse than never working.
  printf '%s' "$body" | grep -q 'sleep' \
    && ok "$lib: sleeps between text and Enter" \
    || bad "$lib: no settle delay between text and Enter"
done

# The docs must not teach the broken one-call form for agent prompts.
for doc in plugins/autocoder/commands/monitor-workers.md .agent/workflows/monitor-workers.md plugins/autocoder/README.md; do
  f="$ROOT/$doc"
  [ -f "$f" ] || { bad "$doc exists"; continue; }
  # grep -c already prints 0 on no match; a `|| echo 0` fallback would append a
  # SECOND zero (grep exits 1 on no match) and the comparison would never pass.
  n=$(grep -c 'tmux send-keys -t [^ ]* "[^"]*" Enter' "$f" 2>/dev/null)
  check "$doc teaches no one-call send-keys+Enter" "$n" "0"
done

TOTAL=$((PASS + FAIL))
echo "$PASS passed / $FAIL failed / $TOTAL total"
[ "$FAIL" -eq 0 ]
