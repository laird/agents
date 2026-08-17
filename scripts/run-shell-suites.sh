#!/usr/bin/env bash
# Run every shell test suite in tests/ and fail if any of them fail.
#
# WHY THIS EXISTS:
#   Issue #32 — CI collected only `pytest tests/`, so every tests/*.sh suite
#   went unexecuted — was fixed by inlining a loop into the `shell` job in
#   .github/workflows/test.yml. That worked, but left the logic reachable only
#   by pushing: there was no way to run locally what CI runs, and no test could
#   assert that CI still ran the suites at all.
#
#   This script is that logic, extracted. CI now calls it, so `bash
#   scripts/run-shell-suites.sh` and the CI job execute the same code, and
#   tests/test_ci_runs_shell_suites.py can guard both.
#
# DESIGN NOTES:
#
#   1. Only `tests/test_*.sh` — NOT `tests/fixtures/*.sh` and NOT
#      `tests/run-shell-suite.sh`. The fixtures are setup/teardown helpers with
#      a `$1 = setup|teardown` contract; running them as suites would mutate
#      .issues/ and prove nothing. `tests/run-shell-suite.sh` is itself a
#      meta-runner that loops over every `test_*.sh` and prints one aggregate
#      summary (for regression-test.sh's parser) — matching it as "a suite"
#      here would run the whole set a second time nested inside it on every
#      invocation. The `test_` prefix excludes both without an explicit
#      denylist. Note that a bash glob does not cross `/`, but
#      `git ls-files 'tests/test_*.sh'` DOES (git pathspec `*` matches
#      slashes) — so do not "simplify" this to git ls-files or
#      `find tests -name 'test_*.sh'` without re-excluding fixtures.
#
#   2. This script lives in scripts/, not tests/, so it cannot match its own
#      glob and recurse.
#
#   3. Every suite runs even if an earlier one fails, and the failures are
#      summarised at the end. `set -e`-ing out on the first failure would hide
#      the rest, which is how one broken suite masks five others.
#
#   4. Issue-source env vars are scrubbed per suite. Each suite builds its own
#      .issues/ fixture; an exported ISSUE_SOURCE / ISSUE_BACKEND from the
#      developer's shell is exactly the input that used to override that
#      resolution and point a suite at the wrong backend (#19).
#
#      This is now defensive, not load-bearing: #19 made .autocoder.json win
#      over a stale exported ISSUE_SOURCE, and as of this commit all 18 suites
#      pass with ISSUE_SOURCE / ISSUE_BACKEND / ISSUE_DIR_PATH set to junk. It
#      is kept because the scrub costs nothing and a future suite that resolves
#      config itself would silently reacquire the bug. Do not cite it as the
#      reason the suites pass.
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
SUITES=(tests/test_*.sh)
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
