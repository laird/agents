#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255: never write the real event logs
# tests/test_gate_cache_fns.sh — gate results are keyed by <tree, command>, a pass is
# reused, a fail is reused only on request, and the key changes with the command.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../plugins/autocoder/scripts/gate-cache-fns.sh
source "$ROOT/plugins/autocoder/scripts/gate-cache-fns.sh"

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export AUTOCODER_GATE_CACHE_DIR="$TMP/cache"

git init -q "$TMP/repo"
cd "$TMP/repo" || exit 1
git config user.email t@example.com; git config user.name T
echo a > a; git add a; git commit -q -m a
TREE=$(git rev-parse 'HEAD^{tree}')

COUNTER="$TMP/runs"
CMD="echo run >> $COUNTER"

gate_cache_get "$TREE" "$CMD" >/dev/null && bad "empty cache reports a record" || ok "empty cache is a miss"

gate_cache_run . "$CMD" >/dev/null || bad "first run of a passing gate fails"
gate_cache_run . "$CMD" >/dev/null || bad "second run of a passing gate fails"
[ "$(wc -l < "$COUNTER")" -eq 1 ] && ok "a recorded pass is not re-run" || bad "pass was re-run: $(wc -l < "$COUNTER") runs"
[ "$(gate_cache_get "$TREE" "$CMD")" = pass ] && ok "get reports pass" || bad "get did not report pass"

FAILCMD="echo run >> $COUNTER.fail; false"
gate_cache_run . "$FAILCMD" >/dev/null && bad "failing gate reported pass"
gate_cache_run . "$FAILCMD" >/dev/null && bad "failing gate reported pass on retry"
[ "$(wc -l < "$COUNTER.fail")" -eq 2 ] && ok "a recorded fail is re-run by default" || bad "fail reuse default wrong: $(wc -l < "$COUNTER.fail")"
GATE_CACHE_REUSE_FAIL=1 gate_cache_run . "$FAILCMD" >/dev/null && bad "reused fail reported pass"
[ "$(wc -l < "$COUNTER.fail")" -eq 2 ] && ok "GATE_CACHE_REUSE_FAIL=1 skips the run" || bad "fail was re-run under reuse"

gate_cache_get "$TREE" "some other command" >/dev/null && bad "different command shares a record" || ok "key includes the command"

echo b > b; git add b; git commit -q -m b
gate_cache_get "$(git rev-parse 'HEAD^{tree}')" "$CMD" >/dev/null && bad "new tree shares a record" || ok "key includes the tree"

gate_cache_put "$TREE" "$CMD" fail
[ "$(gate_cache_get "$TREE" "$CMD")" = fail ] && ok "put overwrites atomically" || bad "put did not overwrite"
[ -z "$(ls -A "$TMP/cache" | grep '^\.tmp')" ] && ok "no temp files left behind" || bad "temp files left in cache dir"

# #298: a run told to re-run named files is keyed apart from the plain command.
gate_cache_put "$TREE" "$CMD" pass
AUTOCODER_GATE_RETEST_FILES="t_a.test" gate_cache_get "$TREE" "$CMD" >/dev/null \
  && bad "a plain pass satisfies a retest run" || ok "a retest run misses the plain record"
AUTOCODER_GATE_RETEST_FILES="t_a.test" gate_cache_put "$TREE" "$CMD" pass
gate_cache_put "$TREE" "$CMD" fail
[ "$(AUTOCODER_GATE_RETEST_FILES="t_a.test" gate_cache_get "$TREE" "$CMD")" = pass ] \
  && [ "$(AUTOCODER_GATE_RETEST_FILES="t_b.test" gate_cache_get "$TREE" "$CMD" || echo miss)" = miss ] \
  && ok "the retest key carries the file list" || bad "retest key does not carry the file list"

# #298: vitest's indented FAIL lines and pytest's FAILED lines name their files.
printf ' FAIL  src/a.test.ts > suite > x\n ✓ src/b.test.ts\n' > "$TMP/vitest.log"
[ "$(gate_log_failed_tests "$TMP/vitest.log" files)" = src/a.test.ts ] && ok "vitest FAIL lines are named" || bad "vitest: $(gate_log_failed_tests "$TMP/vitest.log" files)"
printf 'FAILED tests/test_x.py::test_a - AssertionError\nFAILED tests/test_x.py::test_b\n' > "$TMP/pytest.log"
[ "$(gate_log_failed_tests "$TMP/pytest.log" files)" = tests/test_x.py ] && ok "pytest FAILED ids are cut to their file" || bad "pytest files: $(gate_log_failed_tests "$TMP/pytest.log" files)"
[ "$(gate_log_failed_tests "$TMP/pytest.log" | wc -l)" -eq 2 ] && ok "pytest ids are kept whole without files" || bad "pytest names: $(gate_log_failed_tests "$TMP/pytest.log")"
printf ' FAIL  |jsdom| src/x/Widget.test.tsx > W\n FAIL  |browser| src/x/Widget.layout.browser.test.tsx > L\n' > "$TMP/vitest-projects.log"
[ "$(gate_log_failed_tests "$TMP/vitest-projects.log" files | paste -sd' ' -)" = "src/x/Widget.layout.browser.test.tsx src/x/Widget.test.tsx" ] \
  && ok "a vitest project label before the file is skipped" || bad "project label: $(gate_log_failed_tests "$TMP/vitest-projects.log" files)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
