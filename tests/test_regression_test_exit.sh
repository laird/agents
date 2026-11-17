#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255: never write the real event logs
# tests/test_regression_test_exit.sh — regression-test.sh must fail when tests fail
# or when nothing ran (issues #195, #73).
#
# It used to run the suite as `$UNIT_TEST_CMD 2>&1 | tee log`, whose status is
# tee's (always 0), so a failing suite printed "All tests passed" and exited 0.
# Every gate on it passed anything. Each case below runs the real script in a
# throwaway repo whose configured unit-test command is a stub suite.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export ISSUE_SOURCE=file

# run_case <script> <name> <stub unit suite body> [<stub E2E suite body>]  → sets RC and OUT
run_case() {
  local script="$1" name="$2" body="$3" e2e="${4:-}" dir="$TMP/$2"
  rm -rf "$dir"; mkdir -p "$dir"/.issues/{open,working,blocked,closed}
  cd "$dir" || exit 1
  git init -q .   # issue-fns.sh resolves the repo; outside one it exits 128
  printf '{"issueSource": "file", "issueDir": "%s/.issues"}\n' "$dir" > .autocoder.json
  printf '#!/bin/bash\n%s\n' "$body" > suite.sh
  # Same config block for both platforms: CLAUDE.md (plugin) and GEMINI.md (.agent).
  local cfg='### Unit Tests Only
Working directory: `.`
```bash
bash ./suite.sh
```
'
  if [ -n "$e2e" ]; then
    printf '#!/bin/bash\n%s\n' "$e2e" > e2e.sh
    cfg="$cfg"'
### E2E Tests Only
```bash
bash ./e2e.sh
```
'
  fi
  printf '%s' "$cfg" > CLAUDE.md
  printf '%s' "$cfg" > GEMINI.md
  OUT=$(bash "$script" 2>&1 </dev/null); RC=$?
  # Exit 1 is the only failure the script means. Anything else (128 outside a
  # repo, 127 missing command) is a broken harness, not a verdict on the suite.
  [ "$RC" -eq 0 ] || [ "$RC" -eq 1 ] || { bad "$label/$name: harness error, exit $RC"; echo "$OUT" | tail -10; }
  cd "$ROOT" || exit 1
}

for script in "$ROOT/plugins/autocoder/scripts/regression-test.sh" \
              "$ROOT/.agent/scripts/regression-test.sh"; do
  label="${script#"$ROOT"/}"

  run_case "$script" failing 'echo "Tests: 1 failed, 2 passed, 3 total"; exit 1'
  [ "$RC" -ne 0 ] && ok "$label: failing suite exits non-zero" \
    || bad "$label: failing suite exited $RC"
  echo "$OUT" | grep -q "All tests passed" \
    && bad "$label: failing suite printed 'All tests passed'" \
    || ok "$label: failing suite does not claim success"
  echo "$OUT" | grep -q "1 failed (unit" && ok "$label: summary names '1 failed'" \
    || bad "$label: summary missing '1 failed'"

  run_case "$script" failing-exit0 'echo "Tests: 2 failed, 1 passed, 3 total"; exit 0'
  [ "$RC" -ne 0 ] && ok "$label: reported failures fail the run even when the runner exits 0" \
    || bad "$label: reported failures with runner exit 0 gave exit $RC"
  echo "$OUT" | grep -q "2 failed (unit" && ok "$label: runner-exit-0 failures reach the final summary" \
    || bad "$label: runner-exit-0 case never reached the final summary"

  run_case "$script" empty 'echo "Tests: 0 failed, 0 passed, 0 total"; exit 0'
  [ "$RC" -ne 0 ] && ok "$label: zero tests ran exits non-zero" \
    || bad "$label: zero tests ran exited $RC"
  echo "$OUT" | grep -q "0 tests ran" && ok "$label: empty suite says '0 tests ran'" \
    || bad "$label: empty suite missing '0 tests ran'"
  echo "$OUT" | grep -q "All tests passed" \
    && bad "$label: empty suite printed 'All tests passed'" \
    || ok "$label: empty suite does not claim success"

  run_case "$script" e2e-failing 'echo "Tests: 0 failed, 3 passed, 3 total"' 'echo "1 failed, 4 passed"; exit 1'
  [ "$RC" -ne 0 ] && ok "$label: failing E2E suite exits non-zero" \
    || bad "$label: failing E2E suite exited $RC"
  echo "$OUT" | grep -q "1 failed (unit: 0, E2E: 1)" && ok "$label: summary attributes the failure to E2E" \
    || bad "$label: summary missing E2E failure count"

  run_case "$script" e2e-empty 'echo "Tests: 0 failed, 3 passed, 3 total"' 'echo "0 passed"'
  [ "$RC" -ne 0 ] && ok "$label: E2E suite that ran nothing exits non-zero" \
    || bad "$label: empty E2E suite exited $RC"

  run_case "$script" passing 'echo "Tests: 0 failed, 3 passed, 3 total"; exit 0'
  [ "$RC" -eq 0 ] && ok "$label: passing suite exits 0" \
    || { bad "$label: passing suite exited $RC"; echo "$OUT" | tail -15; }
  echo "$OUT" | grep -q "All tests passed" && ok "$label: passing suite reports success" \
    || bad "$label: passing suite missing success line"
done

# ── Concurrent runs keep their own results (#214) ──────────────────────────
# Logs used to live at /tmp/*-<second>.log, so runs started in the same second
# (concurrent merge gates on one host) read each other's results. Start four at
# once, alternating failing and passing suites; each must get its own verdict.
script="$ROOT/plugins/autocoder/scripts/regression-test.sh"
for i in 1 2 3 4; do
  if [ $((i % 2)) -eq 1 ]; then body='echo "Tests: 1 failed, 2 passed, 3 total"; exit 1'
  else body='echo "Tests: 0 failed, 3 passed, 3 total"'; fi
  ( label=concurrent; run_case "$script" "conc$i" "$body"; echo "$RC" > "$TMP/conc$i.rc"; printf '%s' "$OUT" > "$TMP/conc$i.out" ) &
done
wait
for i in 1 2 3 4; do
  rc=$(cat "$TMP/conc$i.rc" 2>/dev/null)
  if [ $((i % 2)) -eq 1 ]; then
    [ "$rc" = 1 ] && grep -q "1 failed (unit: 1" "$TMP/conc$i.out" \
      && ok "concurrent run $i (failing) keeps its own verdict" || bad "concurrent run $i (failing): rc=$rc"
  else
    [ "$rc" = 0 ] && grep -q "All tests passed" "$TMP/conc$i.out" \
      && ok "concurrent run $i (passing) keeps its own verdict" || bad "concurrent run $i (passing): rc=$rc"
  fi
done

echo ""
echo "Tests: $FAIL failed, $PASS passed, $((PASS + FAIL)) total"
[ "$FAIL" -eq 0 ]
