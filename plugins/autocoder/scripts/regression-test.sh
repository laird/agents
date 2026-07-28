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

# ── Portable stat parsing ────────────────────────────────────────────────────
# BSD/macOS grep has no PCRE flag (a GNU extension), so the previous
# PCRE-based idiom failed on every parse here and its `|| echo 0` fallback
# reported a hard 0 — making a red run indistinguishable from a green one on
# this project's default platform.
#
# parse_stat echoes the first capture group of an ERE, or NOTHING when the
# pattern does not match. Callers MUST distinguish empty (could not parse) from
# "0" (genuinely zero); an unparseable log is an error, never a pass.
parse_stat() {
    local file="$1" ere="$2"
    [ -f "$file" ] || return 1
    sed -E -n "s/.*${ere}.*/\1/p" "$file" | head -1
}

# Allow tests to source these helpers without executing the suite.
if [ "${1:-}" = "--source-only" ]; then
    return 0 2>/dev/null || exit 0
fi

# Timestamp for this test run
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")

# Load configuration from CLAUDE.md if it exists
if [ -f "CLAUDE.md" ]; then
    echo -e "${BLUE}Loading configuration from CLAUDE.md${NC}"

    # Extract report directory
    if grep -q "Location: " CLAUDE.md; then
        REPORT_DIR=$(grep "Location: " CLAUDE.md | sed 's/.*Location: *`\([^`]*\)`.*/\1/' | head -1)
    else
        REPORT_DIR="docs/test/regression-reports"
    fi

    # Extract unit test configuration
    if grep -q "Working directory: " CLAUDE.md && grep -B5 "Working directory:" CLAUDE.md | grep -q "Unit Tests"; then
        UNIT_TEST_DIR=$(grep -A5 "Unit Tests" CLAUDE.md | grep "Working directory:" | sed 's/.*Working directory: *`\([^`]*\)`.*/\1/' | head -1)
        UNIT_TEST_CMD=$(grep -A5 "### Unit Tests Only" CLAUDE.md | sed -n '/```bash/,/```/p' | grep -v '```' | head -1)
    else
        UNIT_TEST_DIR="."
        UNIT_TEST_CMD=""
    fi

    # Extract E2E test configuration
    if grep -q "### E2E Tests Only" CLAUDE.md; then
        E2E_TEST_CMD=$(grep -A5 "### E2E Tests Only" CLAUDE.md | sed -n '/```bash/,/```/p' | grep -v '```' | head -1)
    else
        E2E_TEST_CMD=""
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

# Suite status is tracked separately from counts, so "not configured" and
# "failed to execute" can never be reported as "ran and passed".
UNIT_SUITE_STATUS="ran"
E2E_SUITE_STATUS="ran"
[ -z "$UNIT_TEST_CMD" ] && UNIT_SUITE_STATUS="not_configured"
[ -z "$E2E_TEST_CMD" ] && E2E_SUITE_STATUS="not_configured"

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

# ==========================================
# STEP 1: Run Unit Tests
# ==========================================
echo -e "${YELLOW}[1/2] Running Unit Tests...${NC}"
UNIT_RESULTS="/tmp/unit-test-results-${TIMESTAMP}.log"

# Run unit tests from configured directory
if [ "$UNIT_TEST_DIR" != "." ]; then
    cd "$UNIT_TEST_DIR"
fi

if [ "$UNIT_SUITE_STATUS" = "not_configured" ]; then
    UNIT_STATUS="⏭️  SKIPPED (no unit suite configured)"
    UNIT_EXIT=0
    : > "$UNIT_RESULTS"
else
    # `cmd | tee` yields TEE's exit status, which masked every runner failure —
    # a second false-green source. Take the runner's own status via PIPESTATUS.
    $UNIT_TEST_CMD 2>&1 | tee "$UNIT_RESULTS"
    UNIT_EXIT=${PIPESTATUS[0]}
    if [ "$UNIT_EXIT" -eq 0 ]; then
        UNIT_STATUS="✅ PASSED"
    else
        UNIT_STATUS="❌ FAILED"
    fi
fi

if [ "$UNIT_TEST_DIR" != "." ]; then
    cd - > /dev/null
fi

# Extract unit test stats (Jest format: "Tests: X failed, Y skipped, Z passed")
UNIT_PASSED=$(parse_stat "$UNIT_RESULTS" 'Tests:.*[^0-9]([0-9]+) passed')
UNIT_FAILED=$(parse_stat "$UNIT_RESULTS" 'Tests:[^0-9]*([0-9]+) failed')
UNIT_TOTAL=$(parse_stat "$UNIT_RESULTS" 'Tests:.*[^0-9]([0-9]+) total')

# An empty parse means the runner produced no recognizable summary. That is an
# error condition, NOT zero failures — never let it read as green.
if [ "$UNIT_SUITE_STATUS" = "ran" ] && [ -z "$UNIT_TOTAL" ]; then
    UNIT_SUITE_STATUS="unparseable"
    UNIT_STATUS="❌ FAILED (test output could not be parsed — treating as failure)"
    UNIT_EXIT=1
fi
UNIT_PASSED="${UNIT_PASSED:-0}"
UNIT_FAILED="${UNIT_FAILED:-0}"
UNIT_TOTAL="${UNIT_TOTAL:-0}"

if [ "$UNIT_SUITE_STATUS" = "ran" ]; then
    echo -e "${GREEN}Unit Tests Complete: ${UNIT_PASSED}/${UNIT_TOTAL} passed${NC}"
else
    echo -e "${YELLOW}Unit Tests: ${UNIT_STATUS}${NC}"
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
if [ "$E2E_SUITE_STATUS" = "not_configured" ]; then
    E2E_STATUS="⏭️  SKIPPED (no E2E suite configured)"
    E2E_EXIT=0
    : > "$E2E_RESULTS"
else
    # Runner's status, not tee's — see note above.
    $E2E_TEST_CMD 2>&1 | tee "$E2E_RESULTS"
    E2E_EXIT=${PIPESTATUS[0]}
    if [ "$E2E_EXIT" -eq 0 ]; then
        E2E_STATUS="✅ PASSED"
    else
        E2E_STATUS="❌ FAILED"
    fi
fi

# Parse E2E results from Playwright JSON output
# Extract from the JSON stats section if available, otherwise try text output
if grep -q '"stats"' "$E2E_RESULTS"; then
    E2E_PASSED=$(parse_stat "$E2E_RESULTS" '"expected":[[:space:]]*([0-9]+)')
    E2E_FAILED=$(parse_stat "$E2E_RESULTS" '"unexpected":[[:space:]]*([0-9]+)')
    E2E_SKIPPED=$(parse_stat "$E2E_RESULTS" '"skipped":[[:space:]]*([0-9]+)')
else
    # Fallback to text parsing
    E2E_PASSED=$(parse_stat "$E2E_RESULTS" '([0-9]+) passed')
    E2E_FAILED=$(parse_stat "$E2E_RESULTS" '([0-9]+) failed')
    E2E_SKIPPED=$(parse_stat "$E2E_RESULTS" '([0-9]+) skipped')
fi

# As with unit tests: no parseable summary from a suite that actually ran is a
# failure, not zero failures.
if [ "$E2E_SUITE_STATUS" = "ran" ] && [ -z "$E2E_PASSED$E2E_FAILED$E2E_SKIPPED" ]; then
    E2E_SUITE_STATUS="unparseable"
    E2E_STATUS="❌ FAILED (test output could not be parsed — treating as failure)"
    E2E_EXIT=1
fi
E2E_PASSED="${E2E_PASSED:-0}"
E2E_FAILED="${E2E_FAILED:-0}"
E2E_SKIPPED="${E2E_SKIPPED:-0}"
E2E_TOTAL=$((E2E_PASSED + E2E_FAILED + E2E_SKIPPED))

if [ "$E2E_SUITE_STATUS" = "ran" ]; then
    echo -e "${GREEN}E2E Tests Complete: ${E2E_PASSED}/${E2E_TOTAL} passed${NC}"
else
    echo -e "${YELLOW}E2E Tests: ${E2E_STATUS}${NC}"
fi
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
    SYNTAX_FILE=$(parse_stat "$E2E_RESULTS" '"file":[[:space:]]*"([^"]+\.spec\.ts)"')
    SYNTAX_FILE="${SYNTAX_FILE:-unknown}"
    SYNTAX_LINE=$(parse_stat "$E2E_RESULTS" '"line":[[:space:]]*([0-9]+)')
    SYNTAX_LINE="${SYNTAX_LINE:-unknown}"
    SYNTAX_MSG=$(parse_stat "$E2E_RESULTS" '(SyntaxError:.*Unexpected token)')
    SYNTAX_MSG="${SYNTAX_MSG:-Syntax error}"

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
        TEST_FILE=$(echo "$line" | sed -E -n 's|.*(tests/e2e/[^ ]+\.spec\.ts).*|\1|p' | head -1)
        TEST_FILE="${TEST_FILE:-unknown}"
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
issue_list --state open --limit 100 > /tmp/gh-issues.json

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
        TEST_FILE=$(echo "$line" | sed -E -n 's|.*(tests/e2e/[^ ]+\.spec\.ts).*|\1|p' | head -1)
        TEST_FILE="${TEST_FILE:-unknown}"
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

            # Never manufacture issues from a suite that did not actually run.
            if [ "$E2E_SUITE_STATUS" != "ran" ]; then
                echo "   ⏭️  Skipping issue creation (E2E suite status: $E2E_SUITE_STATUS)"
                continue
            fi

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
summarize_suite() { # label status passed total
    if [ "$2" = "ran" ]; then
        echo -e "  ${GREEN}$1${NC}  $3/$4 passed"
    else
        echo -e "  ${YELLOW}$1${NC}  not run ($2)"
    fi
}
summarize_suite "Unit Tests:" "$UNIT_SUITE_STATUS" "$UNIT_PASSED" "$UNIT_TOTAL"
summarize_suite "E2E Tests: " "$E2E_SUITE_STATUS" "$E2E_PASSED" "$E2E_TOTAL"
echo ""
echo -e "  ${YELLOW}Report saved to:${NC} $REPORT_FILE"
echo ""

# Exit with failure if any tests failed
if [ "$UNIT_EXIT" -ne 0 ] || [ "$E2E_EXIT" -ne 0 ]; then
    echo -e "${RED}⚠️  Some tests failed. Check GitHub issues for details.${NC}"
    exit 1
elif [ "$UNIT_SUITE_STATUS" != "ran" ] && [ "$E2E_SUITE_STATUS" != "ran" ]; then
    # Nothing actually executed — that is not a pass.
    echo -e "${YELLOW}⚠️  No test suite was configured or executed — nothing was verified.${NC}"
    exit 0
else
    echo -e "${GREEN}✅ All tests passed!${NC}"
    exit 0
fi
