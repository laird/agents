#!/usr/bin/env bash
# Run every shell test suite in tests/ and fail if any of them fail.
#
# WHY THIS EXISTS (issue #32):
#   CI ran only `pytest tests/`, which collects Python tests. Every tests/*.sh
#   suite was therefore never executed by CI — including the ones guarding the
#   claim lock, the issue backend, and the multiplexer probe. CI was green and
#   said nothing about any of them.
#
# DESIGN NOTES:
#
#   1. Only `tests/*.sh` — NOT `tests/fixtures/*.sh`. The fixtures are
#      setup/teardown helpers with a `$1 = setup|teardown` contract; running
#      them as suites would mutate .issues/ and prove nothing. Note that a bash
#      glob does not cross `/`, but `git ls-files 'tests/*.sh'` DOES (git
#      pathspec `*` matches slashes) — so do not "simplify" this to git ls-files
#      or `find tests -name '*.sh'` without re-excluding fixtures.
#
#   2. This script lives in scripts/, not tests/, so it cannot match its own
#      glob and recurse.
#
#   3. Every suite runs even if an earlier one fails, and the failures are
#      summarised at the end. `set -e`-ing out on the first failure would hide
#      the rest, which is how one broken suite masks five others.
#
#   4. Issue-source env vars are scrubbed per suite. Each suite builds its own
#      .issues/ fixture, but an exported ISSUE_SOURCE / ISSUE_BACKEND from the
#      developer's shell overrides that resolution and makes the suite read the
#      wrong backend — the same class of bug as #19. Without this, three suites
#      fail locally and pass in CI, which trains people to ignore local reds.
#
# Usage: bash scripts/run-shell-suites.sh
# Exit:  0 = all suites passed, 1 = at least one failed

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

# Suites that genuinely cannot run in this environment go here, each with a
# stated reason. An empty list is the correct state — silently omitting a suite
# is how issue #32 happened in the first place.
# Format: "tests/<name>.sh:<reason>"
SKIP=()

shopt -s nullglob
SUITES=(tests/*.sh)
shopt -u nullglob

if [ ${#SUITES[@]} -eq 0 ]; then
    echo "ERROR: no shell suites found in tests/ — expected at least one." >&2
    echo "       If they moved, update scripts/run-shell-suites.sh." >&2
    exit 1
fi

passed=0
failed=0
skipped=0
FAILED_SUITES=()

for suite in "${SUITES[@]}"; do
    skip_reason=""
    for entry in ${SKIP[@]+"${SKIP[@]}"}; do
        if [ "${entry%%:*}" = "$suite" ]; then
            skip_reason="${entry#*:}"
            break
        fi
    done

    if [ -n "$skip_reason" ]; then
        echo "── SKIP $suite — $skip_reason"
        skipped=$((skipped + 1))
        continue
    fi

    echo "── $suite"
    # Scrub inherited issue-source config so each suite's own fixture wins.
    if env -u ISSUE_SOURCE -u ISSUE_BACKEND -u ISSUE_DIR_PATH bash "$suite"; then
        passed=$((passed + 1))
    else
        echo "   ^^ FAILED: $suite"
        failed=$((failed + 1))
        FAILED_SUITES+=("$suite")
    fi
done

echo
echo "════════════════════════════════════════"
echo "Shell suites: ${passed} passed, ${failed} failed, ${skipped} skipped"
if [ ${#FAILED_SUITES[@]} -gt 0 ]; then
    echo "Failed:"
    for s in "${FAILED_SUITES[@]}"; do echo "  - $s"; done
fi
echo "════════════════════════════════════════"

[ "$failed" -eq 0 ]
