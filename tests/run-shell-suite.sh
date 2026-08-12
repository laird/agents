#!/bin/bash
# tests/run-shell-suite.sh — runs every tests/test_*.sh and prints ONE summary.
#
# WHY THIS EXISTS:
#   plugins/autocoder/scripts/regression-test.sh reads its unit-test command out
#   of CLAUDE.md and then parses the output for a "<N> passed / <N> failed /
#   <N> total" summary. A bare `for t in tests/test_*.sh; do bash "$t"; done`
#   emits one summary per test file, so the parser reads whichever line happens
#   to come last and reports a single test's numbers as the suite's. This
#   wrapper runs the same files and prints exactly one summary at the end.
#
#   Deliberately does NOT stop at the first failure: the regression report is
#   more useful when it names every failing suite, not just the earliest one.
#
# Exit status: 0 when every test passed, 1 otherwise.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
cd "$ROOT" || exit 1

passed=0
failed=0
failed_names=""

for t in tests/test_*.sh; do
    [ -f "$t" ] || continue
    name="$(basename "$t")"
    if bash "$t" >/tmp/shell-suite-$$.log 2>&1; then
        echo "PASS  $name"
        passed=$((passed + 1))
    else
        echo "FAIL  $name"
        sed 's/^/      | /' /tmp/shell-suite-$$.log | tail -20
        failed=$((failed + 1))
        failed_names="$failed_names $name"
    fi
done
rm -f /tmp/shell-suite-$$.log

total=$((passed + failed))

echo ""
if [ "$failed" -gt 0 ]; then
    echo "Failing suites:$failed_names"
fi
# Single machine-parseable summary. Keep this format — regression-test.sh's
# count_before() greps "<N> passed", "<N> failed", "<N> total".
echo "Tests: $failed failed, $passed passed, $total total"

[ "$failed" -eq 0 ]
