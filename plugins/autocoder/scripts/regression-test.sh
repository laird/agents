#!/bin/bash

# ==========================================
# Regression Test Suite
# ==========================================
# Runs all unit and E2E tests, documents failures,
# and automatically creates/updates GitHub issues.
#
# Usage: bash scripts/regression-test.sh
# ==========================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/issue-fns.sh"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Timestamp for this test run
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")

# Print the first command line inside the first fenced block following a
# markdown header. Uses awk rather than a nested sed range, because BSD sed
# (macOS) rejects `/a/,/b/{/c/,/d/p}` outright.
extract_fenced_command() {
    local header="$1" file="$2"
    [ -f "$file" ] || return 0
    awk -v hdr="$header" '
        index($0, hdr) == 1        { in_section = 1; next }
        in_section && /^### /      { exit }
        in_section && /^```/       { if (in_fence) exit; in_fence = 1; next }
        in_section && in_fence     { if ($0 ~ /^[[:space:]]*$/ || $0 ~ /^[[:space:]]*#/) next; print; exit }
    ' "$file"
}

# Load configuration from CLAUDE.md if it exists
if [ -f "CLAUDE.md" ]; then
    echo -e "${BLUE}Loading configuration from CLAUDE.md${NC}"

    # Extract report directory.
    #
    # Scoped to the "**Test Reports**:" block on purpose. A bare
    # `grep "Location: "` takes the FIRST match in the whole file, which is the
    # Unit Tests location (`tests/test_*.sh`) — a glob. mkdir -p then created a
    # directory whose literal name contained an asterisk, and that directory
    # subsequently matched `tests/test_*.sh` expansions elsewhere (issue #73).
    REPORT_DIR=$(awk '
        /^\*\*Test Reports\*\*:/ { in_block = 1; next }
        in_block && /^\*\*/      { exit }
        in_block && /Location: / { print; exit }
    ' CLAUDE.md | sed 's/.*Location: *`\([^`]*\)`.*/\1/')
    REPORT_DIR="${REPORT_DIR%/}"
    if [ -z "$REPORT_DIR" ]; then
        REPORT_DIR="docs/test/regression-reports"
    fi
    # Never let a glob or a path traversal reach mkdir.
    case "$REPORT_DIR" in
        *'*'*|*'?'*|*'['*|*'..'*)
            echo -e "${YELLOW}Ignoring unusable report directory '${REPORT_DIR}' from CLAUDE.md${NC}"
            REPORT_DIR="docs/test/regression-reports"
            ;;
    esac

    # Extract unit test working directory.
    if grep -q "Working directory: " CLAUDE.md && grep -B5 "Working directory:" CLAUDE.md | grep -q "Unit Tests"; then
        UNIT_TEST_DIR=$(grep -A5 "Unit Tests" CLAUDE.md | grep "Working directory:" | sed 's/.*Working directory: *`\([^`]*\)`.*/\1/' | head -1)
    else
        UNIT_TEST_DIR="."
    fi

    # Extract the unit test command. "### Unit Tests Only" is the header this
    # script has always documented, but it was gated behind a "Working
    # directory:" check that no CLAUDE.md satisfies, so extraction never ran and
    # the suite silently skipped — while the run still reported success (#73).
    # Read the header directly, and fall back to "### Regression Test Suite".
    UNIT_TEST_CMD=$(extract_fenced_command "### Unit Tests Only" CLAUDE.md)
    if [ -z "$UNIT_TEST_CMD" ]; then
        UNIT_TEST_CMD=$(extract_fenced_command "### Regression Test Suite" CLAUDE.md)
    fi
    # Guard against self-invocation: in this repo "### Regression Test Suite"
    # IS this script, and adopting it would recurse without bound.
    case "$UNIT_TEST_CMD" in
        *regression-test.sh*)
            echo -e "${YELLOW}Ignoring self-referential unit test command '${UNIT_TEST_CMD}'${NC}"
            UNIT_TEST_CMD=""
            ;;
    esac

    # Extract E2E test configuration
    if grep -q "### E2E Tests Only" CLAUDE.md; then
        E2E_TEST_CMD=$(grep -A5 "### E2E Tests Only" CLAUDE.md | sed -n '/```bash/,/```/p' | grep -v '```' | head -1)
    else
        E2E_TEST_CMD=""   # not configured — skip rather than assume playwright
    fi

    # Extract test file patterns
    if grep -q "Test file pattern:" CLAUDE.md; then
        E2E_TEST_PATTERN=$(grep "Test file pattern:" CLAUDE.md | sed 's/.*Test file pattern: *`\([^`]*\)`.*/\1/' | head -1)
    else
        E2E_TEST_PATTERN="*.spec.ts"
    fi
else
    echo -e "${YELLOW}No CLAUDE.md found, using defaults${NC}"
    REPORT_DIR="docs/test/regression-reports"
    UNIT_TEST_DIR="."
    UNIT_TEST_CMD=""
    E2E_TEST_CMD=""
    E2E_TEST_PATTERN="*.spec.ts"
fi

REPORT_FILE="$REPORT_DIR/regression-${TIMESTAMP}.md"

# Create report directory if it doesn't exist
mkdir -p "$REPORT_DIR"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Regression Test Suite${NC}"
echo -e "${BLUE}  Started: $(date)${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Initialize report
cat > "$REPORT_FILE" << EOF
# Regression Test Report
**Date**: $(date)
**Timestamp**: ${TIMESTAMP}

## Test Summary

EOF

# ── Portable parsing helpers ───────────────────────────────────────────────
# BSD/macOS grep has no -P (PCRE). Every stat parser used `grep -oP ... ||
# echo 0`, so on macOS the parse failed and the `|| echo 0` turned that
# failure into a zero — a red run became indistinguishable from a green one.
# These use -oE (ERE, portable) and return EMPTY when nothing matched, so the
# caller can tell "no data" apart from a genuine zero.

# count_before <file> <keyword>  — matches "<N> <keyword>" (Jest/Playwright text)
#
# SUMS every match rather than taking the last. Jest and Playwright emit one
# summary per run, so last-wins and sum agree there. But this repo's own unit
# command is `for t in tests/test_*.sh; do bash "$t" || exit 1; done` — a dozen
# independent scripts, each printing its own "Results: N passed, M failed". Under
# `tail -1` a green run of ~164 assertions reported the LAST suite's 7. Summing
# is correct for both shapes.
#
# Still returns EMPTY when nothing matched (awk's uninitialized `s` prints as
# the empty string), which the caller relies on to tell "runner produced no
# summary" apart from a genuine zero.
count_before() {
    grep -oE "[0-9]+[[:space:]]+$2" "$1" 2>/dev/null | grep -oE '^[0-9]+' \
        | awk '{ s += $1; n += 1 } END { if (n) print s }'
}

# json_int <file> <key>  — matches "<key>": <N> in JSON output
json_int() {
    grep -oE "\"$2\"[[:space:]]*:[[:space:]]*[0-9]+" "$1" 2>/dev/null \
        | grep -oE '[0-9]+$' | head -1
}

# ==========================================
# STEP 1: Run Unit Tests
# ==========================================
echo -e "${YELLOW}[1/2] Running Unit Tests...${NC}"
UNIT_RESULTS="/tmp/unit-test-results-${TIMESTAMP}.log"

# Run unit tests from configured directory
if [ "$UNIT_TEST_DIR" != "." ]; then
    cd "$UNIT_TEST_DIR"
fi

if [ -z "$UNIT_TEST_CMD" ]; then
    echo -e "${YELLOW}No unit test command configured — skipping.${NC}"
    UNIT_STATUS="⏭️  SKIPPED (not configured)"
    UNIT_EXIT=0
    UNIT_SUITE_SKIPPED=true
    : > "$UNIT_RESULTS"
else
    # Read the SUITE's status, not tee's. `cmd | tee f` reports tee's exit code,
    # which is essentially always 0, so `if cmd | tee f; then PASSED` marked
    # every failing suite as passing — the most severe form of #73, and it was
    # live on this branch. This script has no `set -o pipefail` (adding it
    # globally would change the behaviour of every other pipeline here under
    # `set -e`), so read PIPESTATUS at the one place correctness depends on it.
    env -u ISSUE_SOURCE -u ISSUE_DIR_PATH -u ISSUE_BACKEND \
        bash -lc "$UNIT_TEST_CMD" 2>&1 | tee "$UNIT_RESULTS"
    UNIT_EXIT=${PIPESTATUS[0]}
    if [ "$UNIT_EXIT" -eq 0 ]; then
        UNIT_STATUS="✅ PASSED"
    else
        UNIT_STATUS="❌ FAILED"
        UNIT_EXIT=1
    fi
fi

if [ "$UNIT_TEST_DIR" != "." ]; then
    cd - > /dev/null
fi

# Extract unit test stats (Jest format: "Tests: X failed, Y skipped, Z passed")
UNIT_PASSED=$(count_before "$UNIT_RESULTS" passed)
UNIT_FAILED=$(count_before "$UNIT_RESULTS" failed)
UNIT_TOTAL=$(count_before "$UNIT_RESULTS" total)

# No parseable summary at all means the runner never produced one — it failed
# to execute, was not installed, or is not the framework we assumed. That is an
# ERROR, not "0 tests, 0 failures". Reporting it as a green is how a broken
# suite hides a broken build.
if [ -z "${UNIT_PASSED}${UNIT_FAILED}${UNIT_TOTAL}" ] && [ "${UNIT_SUITE_SKIPPED:-false}" != "true" ]; then
    UNIT_STATUS="❌ FAILED (no parseable test summary — did '$UNIT_TEST_CMD' actually run?)"
    UNIT_EXIT=1
fi
UNIT_PASSED="${UNIT_PASSED:-0}"
UNIT_FAILED="${UNIT_FAILED:-0}"
# Derive the denominator when the runner never prints one. No bash suite in this
# repo emits the word "total", so UNIT_TOTAL was always 0 and every summary read
# "N/0 passed". Derive only — never overwrite a total the runner did report,
# since Jest's total legitimately includes skipped tests that are neither passed
# nor failed. Must stay AFTER the no-parseable-summary guard above, or an
# unparseable run would synthesise 0+0=0 and look like a valid green.
UNIT_TOTAL="${UNIT_TOTAL:-$((UNIT_PASSED + UNIT_FAILED))}"

# Print the STATUS, not just the counts. When the suite fails — especially with
# "no parseable test summary" — the reason previously went only into the report
# file, so an operator watching the run saw "0/0 passed" in green and no
# explanation. Colour by outcome so a red run is visibly red.
if [ "$UNIT_EXIT" -eq 0 ]; then
    echo -e "${GREEN}Unit Tests Complete: ${UNIT_STATUS} (${UNIT_PASSED}/${UNIT_TOTAL} passed)${NC}"
else
    echo -e "${RED}Unit Tests Complete: ${UNIT_STATUS} (${UNIT_PASSED}/${UNIT_TOTAL} passed)${NC}"
fi
echo ""

# Add to report
cat >> "$REPORT_FILE" << EOF
### Unit Tests
- **Status**: $UNIT_STATUS
- **Total**: $UNIT_TOTAL
- **Passed**: $UNIT_PASSED
- **Failed**: $UNIT_FAILED

EOF

# ==========================================
# STEP 2: Run E2E Tests
# ==========================================
echo -e "${YELLOW}[2/2] Running E2E Tests...${NC}"
E2E_RESULTS="/tmp/e2e-test-results-${TIMESTAMP}.log"
E2E_JSON="/tmp/e2e-results-${TIMESTAMP}.json"

# Run E2E tests with configured command
if [ -z "$E2E_TEST_CMD" ]; then
    echo -e "${YELLOW}No E2E test command configured — skipping.${NC}"
    E2E_STATUS="⏭️  SKIPPED (not configured)"
    E2E_EXIT=0
    E2E_SUITE_SKIPPED=true
    : > "$E2E_RESULTS"
else
    # Same PIPESTATUS reasoning as the unit suite above.
    env -u ISSUE_SOURCE -u ISSUE_DIR_PATH -u ISSUE_BACKEND \
        bash -lc "$E2E_TEST_CMD" 2>&1 | tee "$E2E_RESULTS"
    E2E_EXIT=${PIPESTATUS[0]}
    if [ "$E2E_EXIT" -eq 0 ]; then
        E2E_STATUS="✅ PASSED"
    else
        E2E_STATUS="❌ FAILED"
        E2E_EXIT=1
    fi
fi

# Parse E2E results from Playwright JSON output
# Extract from the JSON stats section if available, otherwise try text output
if grep -q '"stats"' "$E2E_RESULTS"; then
    E2E_PASSED=$(json_int "$E2E_RESULTS" expected)
    E2E_FAILED=$(json_int "$E2E_RESULTS" unexpected)
    E2E_SKIPPED=$(json_int "$E2E_RESULTS" skipped)
    E2E_PASSED="${E2E_PASSED:-0}"; E2E_FAILED="${E2E_FAILED:-0}"; E2E_SKIPPED="${E2E_SKIPPED:-0}"
    E2E_TOTAL=$((E2E_PASSED + E2E_FAILED + E2E_SKIPPED))
else
    # Fallback to text parsing
    E2E_PASSED=$(count_before "$E2E_RESULTS" passed)
    E2E_FAILED=$(count_before "$E2E_RESULTS" failed)
    E2E_SKIPPED=$(count_before "$E2E_RESULTS" skipped)
    E2E_PASSED="${E2E_PASSED:-0}"; E2E_FAILED="${E2E_FAILED:-0}"; E2E_SKIPPED="${E2E_SKIPPED:-0}"
    E2E_TOTAL=$((E2E_PASSED + E2E_FAILED + E2E_SKIPPED))
fi

echo -e "${GREEN}E2E Tests Complete: ${E2E_PASSED}/${E2E_TOTAL} passed${NC}"
echo ""

# Add to report
cat >> "$REPORT_FILE" << EOF
### E2E Tests
- **Status**: $E2E_STATUS
- **Total**: $E2E_TOTAL
- **Passed**: $E2E_PASSED
- **Failed**: $E2E_FAILED
- **Skipped**: $E2E_SKIPPED

---

EOF

# ==========================================
# STEP 3: Process Test Failures
# ==========================================
echo -e "${YELLOW}Processing test failures and GitHub issues...${NC}"

# Check for E2E syntax errors first
if grep -q "SyntaxError" "$E2E_RESULTS"; then
    echo "## E2E Syntax Errors" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"

    # Extract syntax error details
    SYNTAX_FILE=$(grep -oE '"file"[[:space:]]*:[[:space:]]*"[^"]+"' "$E2E_RESULTS" | grep -oE '/[^"]+\.spec\.ts' | head -1 || echo "unknown")
    SYNTAX_LINE=$(json_int "$E2E_RESULTS" line); SYNTAX_LINE="${SYNTAX_LINE:-unknown}"
    SYNTAX_MSG=$(grep -oE 'SyntaxError:.*Unexpected token' "$E2E_RESULTS" | head -1 || echo "Syntax error")

    echo "### Syntax Error" >> "$REPORT_FILE"
    echo "- **File**: \`$SYNTAX_FILE\`" >> "$REPORT_FILE"
    echo "- **Line**: $SYNTAX_LINE" >> "$REPORT_FILE"
    echo "- **Error**: $SYNTAX_MSG" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
fi

# Extract E2E test failures
if [ "$E2E_FAILED" -gt 0 ]; then
    echo "## E2E Test Failures" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"

    # Extract failed test names from log
    grep "✘" "$E2E_RESULTS" | while IFS= read -r line; do
        # Extract test file and description
        TEST_FILE=$(echo "$line" | grep -oE 'tests/e2e/[^ ]+\.spec\.ts' || echo "unknown")
        TEST_DESC=$(echo "$line" | sed -E 's/.*›\s+(.+)\s+\([0-9.]+s\)/\1/' || echo "Unknown test")

        echo "### Failed Test" >> "$REPORT_FILE"
        echo "- **File**: \`$TEST_FILE\`" >> "$REPORT_FILE"
        echo "- **Test**: $TEST_DESC" >> "$REPORT_FILE"
        echo "" >> "$REPORT_FILE"
    done
fi

# Extract unit test failures
if [ "$UNIT_FAILED" -gt 0 ]; then
    echo "## Unit Test Failures" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"

    grep "failing" "$UNIT_RESULTS" -A 50 | while IFS= read -r line; do
        if echo "$line" | grep -q "^[[:space:]]*[0-9])" ; then
            echo "- $line" >> "$REPORT_FILE"
        fi
    done
    echo "" >> "$REPORT_FILE"
fi

# ==========================================
# STEP 4: GitHub Issue Management
# ==========================================
echo -e "${YELLOW}Checking for existing GitHub issues...${NC}"

# Fetch all open issues
# Fetch open issues. Tolerate a backend that can't answer (no remote, no auth,
# transient API failure): a tracker lookup failing must not abort a run whose
# tests already passed, and `set -e` would otherwise do exactly that.
# REGRESSION_TEST_NO_ISSUES=1 puts the script in test mode: no tracker writes.
if [ "${REGRESSION_TEST_NO_ISSUES:-0}" = "1" ]; then
    echo "[]" > /tmp/gh-issues.json
elif ! issue_list --state open --limit 100 > /tmp/gh-issues.json 2>/dev/null; then
    echo -e "${YELLOW}⚠️  Could not query the issue tracker — continuing without issue management${NC}"
    echo "[]" > /tmp/gh-issues.json
fi

# Function to determine priority based on failure type
determine_priority() {
    local test_file="$1"
    local test_desc="$2"

    # P0 - Critical (affects auth, data integrity, crashes)
    if echo "$test_desc" | grep -qiE "login|auth|crash|data loss|security"; then
        echo "P0"
        return
    fi

    # P1 - High (major features broken)
    if echo "$test_desc" | grep -qiE "create|delete|update|crud|save"; then
        echo "P1"
        return
    fi

    # P2 - Medium (partial feature failures)
    if echo "$test_desc" | grep -qiE "filter|sort|search|display|show"; then
        echo "P2"
        return
    fi

    # P3 - Low (UI, validation, edge cases)
    echo "P3"
}

# Function to check if issue exists for this failure
find_matching_issue() {
    local test_file="$1"
    local test_desc="$2"

    # Search for existing issue with similar title
    local issue_num=$(jq -r --arg desc "$test_desc" \
        '.[] | select(.title | ascii_downcase | contains(($desc | ascii_downcase)[0:30])) | .number' \
        /tmp/gh-issues.json 2>/dev/null | head -1)

    echo "$issue_num"
}

# Process E2E failures and create/update issues
if [ "$E2E_FAILED" -gt 0 ]; then
    grep "✘" "$E2E_RESULTS" | while IFS= read -r line; do
        TEST_FILE=$(echo "$line" | grep -oE 'tests/e2e/[^ ]+\.spec\.ts' || echo "unknown")
        TEST_DESC=$(echo "$line" | sed -E 's/.*›\s+(.+)\s+\([0-9.]+s\)/\1/' || echo "Unknown test")

        # Determine priority
        PRIORITY=$(determine_priority "$TEST_FILE" "$TEST_DESC")

        # Check for existing issue
        EXISTING_ISSUE=$(find_matching_issue "$TEST_FILE" "$TEST_DESC")

        if [ -n "$EXISTING_ISSUE" ]; then
            # Update existing issue with new failure
            echo -e "${BLUE}Updating issue #${EXISTING_ISSUE}...${NC}"
            issue_comment "$EXISTING_ISSUE" --body "## Test Failure (Regression Test)
**Date**: $(date)
**Test File**: \`$TEST_FILE\`
**Test**: $TEST_DESC
**Priority**: $PRIORITY

This test failed during automated regression testing."
        else
            # Create new issue
            echo -e "${BLUE}Creating new issue for: $TEST_DESC${NC}"
            ISSUE_TITLE="${PRIORITY}-${TEST_DESC:0:80}"
            ISSUE_BODY="## Test Failure
**Test File**: \`$TEST_FILE\`
**Test Description**: $TEST_DESC
**Priority**: $PRIORITY
**Detected**: $(date)

This test failure was detected during automated regression testing.

**Test Report**: See \`$REPORT_FILE\`

**Next Steps**:
1. Reproduce the failure locally
2. Identify root cause
3. Implement fix
4. Verify with \`npm run test:e2e\`"

            RESULT=$(issue_create \
                --title "$ISSUE_TITLE" \
                --body "$ISSUE_BODY" \
                --label "bug" --label "automated-test-failure" --label "$PRIORITY")
        fi
    done
fi

# ==========================================
# STEP 5: Final Report
# ==========================================
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Regression Test Complete${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
# Same reasoning as the per-suite line above: show the status, and colour the
# label by outcome. A green "0/0 passed" on a failed run is how a broken suite
# reads as a healthy one.
if [ "$UNIT_EXIT" -eq 0 ]; then
    echo -e "  ${GREEN}Unit Tests:${NC}  ${UNIT_STATUS} ($UNIT_PASSED/$UNIT_TOTAL passed)"
else
    echo -e "  ${RED}Unit Tests:${NC}  ${UNIT_STATUS} ($UNIT_PASSED/$UNIT_TOTAL passed)"
fi
if [ "$E2E_EXIT" -eq 0 ]; then
    echo -e "  ${GREEN}E2E Tests:${NC}   ${E2E_STATUS} ($E2E_PASSED/$E2E_TOTAL passed)"
else
    echo -e "  ${RED}E2E Tests:${NC}   ${E2E_STATUS} ($E2E_PASSED/$E2E_TOTAL passed)"
fi
echo ""
echo -e "  ${YELLOW}Report saved to:${NC} $REPORT_FILE"
echo ""

# Exit with failure if any tests failed
if [ "$UNIT_EXIT" -ne 0 ] || [ "$E2E_EXIT" -ne 0 ]; then
    echo -e "${RED}⚠️  Some tests failed. Check GitHub issues for details.${NC}"
    exit 1
fi

# A run that executed nothing is not a pass. Previously every suite could be
# skipped and the script still printed success and exited 0, so a misconfigured
# runner looked identical to a green one — and the /fix and /dev protocols treat
# a green regression run as licence to move on (issue #73).
if [ "${UNIT_SUITE_SKIPPED:-false}" = "true" ] && [ "${E2E_SUITE_SKIPPED:-false}" = "true" ]; then
    echo -e "${RED}⚠️  No tests were executed — every suite was skipped.${NC}"
    echo -e "${YELLOW}   Configure '### Unit Tests Only' in CLAUDE.md so a real suite runs.${NC}"
    exit 1
fi

echo -e "${GREEN}✅ All tests passed!${NC}"
exit 0
