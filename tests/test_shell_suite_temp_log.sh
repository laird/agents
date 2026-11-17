#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255: never write the real event logs
# tests/test_shell_suite_temp_log.sh — run-shell-suite.sh keeps each test's output in a
# mktemp file under TMPDIR and removes it on every exit, interrupted or not (#259).
#
# It used to write a fixed /tmp/shell-suite-$$.log and remove it only after the loop,
# so a run stopped mid-test left the log behind. This runs a copy of the runner in a
# private root with its own tests/ directory, so it never runs the real suite.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
SANDBOX="$TMP/repo"; SCRATCH="$TMP/tmpdir"
mkdir -p "$SANDBOX/tests" "$SCRATCH"
cp "$ROOT/tests/run-shell-suite.sh" "$SANDBOX/tests/"
printf '#!/bin/bash\necho fine\n' > "$SANDBOX/tests/test_a_pass.sh"
printf '#!/bin/bash\necho "marker-from-failing-test"\nexit 1\n' > "$SANDBOX/tests/test_b_fail.sh"

echo "=== no fixed /tmp path for the per-test log ==="
if grep -q '/tmp/shell-suite' "$ROOT/tests/run-shell-suite.sh"; then
  bad "run-shell-suite.sh still writes /tmp/shell-suite-*"
else
  ok "no fixed /tmp/shell-suite path"
fi

echo "=== a completed run shows a failing test's output and removes the log ==="
out=$(TMPDIR="$SCRATCH" bash "$SANDBOX/tests/run-shell-suite.sh" 2>&1)
grep -q 'FAIL  test_b_fail.sh' <<<"$out" && ok "failing test reported" || bad "no FAIL line: $out"
grep -q 'marker-from-failing-test' <<<"$out" && ok "failing test's output shown" || bad "failure output missing: $out"
left=$(find "$SCRATCH" -name 'shell-suite.*')
[ -z "$left" ] && ok "no log left in TMPDIR" || bad "log left behind: $left"

echo "=== an interrupted run removes the log ==="
printf '#!/bin/bash\necho started > "%s/started"\nsleep 5\n' "$TMP" > "$SANDBOX/tests/test_c_slow.sh"
# Job control gives each run its own process group with SIGINT not ignored (a plain
# background job in a script starts with SIGINT ignored, so INT would interrupt
# nothing), and lets the kill reach the slow test's sleep too, so nothing outlives us.
set -m
for sig in INT TERM; do
  rm -f "$TMP/started"
  TMPDIR="$SCRATCH" bash "$SANDBOX/tests/run-shell-suite.sh" test_c_slow.sh >/dev/null 2>&1 &
  pid=$!
  for _ in $(seq 50); do [ -f "$TMP/started" ] && break; sleep 0.1; done
  during=$(find "$SCRATCH" -name 'shell-suite.*')
  kill -"$sig" -- -"$pid" 2>/dev/null; wait "$pid" 2>/dev/null; rc=$?
  left=$(find "$SCRATCH" -name 'shell-suite.*')
  if [ -n "$during" ] && [ -z "$left" ] && [ "$rc" -gt 128 ]; then
    ok "SIG$sig: interrupted (rc $rc); the log existed during the run and was removed"
  else
    bad "SIG$sig: rc=$rc during='$during' left='$left'"
  fi
done
set +m

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
