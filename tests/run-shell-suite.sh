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
# Arguments, optional: test file names (test_x.sh or tests/test_x.sh) to run instead of
# all of them. The merge gate's flaky re-run uses this (AUTOCODER_GATE_RERUN_CMD, #191).
#
# Exit status: 0 when every test passed, 1 otherwise.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
cd "$ROOT" || exit 1

# Tests build throwaway repos and expect git to find them from the current
# directory. An inherited GIT_DIR or GIT_WORK_TREE (from a git hook or a wrapper)
# overrides that, and issue-config.sh would then read the real repo's
# .autocoder.json and send a test's issue calls to the real tracker (#257).
# Drop every variable git itself clears when it changes repository.
unset $(git rev-parse --local-env-vars 2>/dev/null) GIT_DIR GIT_WORK_TREE

# Tests drive merge jobs, which append merge-attempt events (#184). Keep those out
# of the real ~/.local/state/autocoder/merge-events.jsonl.
SUITE_EVENTS=$(mktemp "${TMPDIR:-/tmp}/suite-merge-events.XXXXXX")
export AUTOCODER_MERGE_EVENTS="$SUITE_EVENTS"
# Likewise the issue lifecycle events (#190), which the issue verbs append.
SUITE_ISSUE_EVENTS=$(mktemp "${TMPDIR:-/tmp}/suite-issue-events.XXXXXX")
export AUTOCODER_ISSUE_EVENTS="$SUITE_ISSUE_EVENTS"
# Each test's output, shown on failure. mktemp, and removed by the trap, so an
# interrupted run does not leave it behind (#259).
SUITE_LOG=$(mktemp "${TMPDIR:-/tmp}/shell-suite.XXXXXX")
trap 'rm -f "$SUITE_EVENTS" "$SUITE_ISSUE_EVENTS" "$SUITE_LOG"' EXIT
# #197's random spot-check sampling makes exact-label assertions flaky (#225). Off by
# default for the suite; tests that exercise spot checks set or unset it themselves.
export AUTOCODER_SPOT_CHECK_RATE="${AUTOCODER_SPOT_CHECK_RATE:-0}"

passed=0
failed=0
failed_names=""

if [ "$#" -gt 0 ]; then
    tests=()
    for a in "$@"; do
        t="tests/$(basename "$a")"
        case "$(basename "$a")" in
            test_*.sh) [ -f "$t" ] && tests+=("$t") || { echo "FAIL  $(basename "$a") (no such test)"; failed=$((failed + 1)); failed_names="$failed_names $(basename "$a")"; } ;;
            *) echo "run-shell-suite: not a test file: $a" >&2; exit 2 ;;
        esac
    done
else
    tests=(tests/test_*.sh)
fi

for t in "${tests[@]}"; do
    [ -f "$t" ] || continue
    name="$(basename "$t")"
    if bash "$t" >"$SUITE_LOG" 2>&1; then
        echo "PASS  $name"
        passed=$((passed + 1))
    else
        echo "FAIL  $name"
        sed 's/^/      | /' "$SUITE_LOG" | tail -20
        failed=$((failed + 1))
        failed_names="$failed_names $name"
    fi
done

total=$((passed + failed))

echo ""
if [ "$failed" -gt 0 ]; then
    echo "Failing suites:$failed_names"
fi
# Single machine-parseable summary. Keep this format — regression-test.sh's
# count_before() greps "<N> passed", "<N> failed", "<N> total".
echo "Tests: $failed failed, $passed passed, $total total"

[ "$failed" -eq 0 ]
