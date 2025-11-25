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

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Timestamp for this test run
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")

# Load configuration from CLAUDE-AUTOFIX-CONFIG.md if it exists
if [ -f "CLAUDE-AUTOFIX-CONFIG.md" ]; then
    echo -e "${BLUE}Loading configuration from CLAUDE-AUTOFIX-CONFIG.md${NC}"

    # Extract report directory
    if grep -q "Location: " CLAUDE-AUTOFIX-CONFIG.md; then
        REPORT_DIR=$(grep "Location: " CLAUDE-AUTOFIX-CONFIG.md | sed 's/.*Location: *`\([^`]*\)`.*/\1/' | head -1)
    else
        REPORT_DIR="docs/test/regression-reports"
    fi

    # Extract unit test configuration
    if grep -q "Working directory: " CLAUDE-AUTOFIX-CONFIG.md && grep -B5 "Working directory:" CLAUDE-AUTOFIX-CONFIG.md | grep -q "Unit Tests"; then
        UNIT_TEST_DIR=$(grep -A5 "Unit Tests" CLAUDE-AUTOFIX-CONFIG.md | grep "Working directory:" | sed 's/.*Working directory: *`\([^`]*\)`.*/\1/' | head -1)
        UNIT_TEST_CMD=$(grep -A5 "### Unit Tests Only" CLAUDE-AUTOFIX-CONFIG.md | sed -n '/```bash/,/```/p' | grep -v '```' | head -1)
    else
        UNIT_TEST_DIR="."
        UNIT_TEST_CMD="npm test"
    fi

    # Extract E2E test configuration
    if grep -q "### E2E Tests Only" CLAUDE-AUTOFIX-CONFIG.md; then
        E2E_TEST_CMD=$(grep -A5 "### E2E Tests Only" CLAUDE-AUTOFIX-CONFIG.md | sed -n '/```bash/,/```/p' | grep -v '```' | head -1)
    else
        E2E_TEST_CMD="npx playwright test --reporter=json"
    fi

    # Extract test file patterns
    if grep -q "Test file pattern:" CLAUDE-AUTOFIX-CONFIG.md; then
        E2E_TEST_PATTERN=$(grep "Test file pattern:" CLAUDE-AUTOFIX-CONFIG.md | sed 's/.*Test file pattern: *`\([^`]*\)`.*/\1/' | head -1)
    else
        E2E_TEST_PATTERN="*.spec.ts"
    fi
else
    echo -e "${YELLOW}No CLAUDE-AUTOFIX-CONFIG.md found, using defaults${NC}"
    REPORT_DIR="docs/test/regression-reports"
    UNIT_TEST_DIR="."
    UNIT_TEST_CMD="npm test"
    E2E_TEST_CMD="npx playwright test --reporter=json"
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

# ==========================================
# STEP 1: Run Unit Tests
# ==========================================
echo -e "${YELLOW}[1/2] Running Unit Tests...${NC}"
UNIT_RESULTS="/tmp/unit-test-results-${TIMESTAMP}.log"

# Run unit tests from configured directory
if [ "$UNIT_TEST_DIR" != "." ]; then
    cd "$UNIT_TEST_DIR"
fi

if $UNIT_TEST_CMD 2>&1 | tee "$UNIT_RESULTS"; then
    UNIT_STATUS="✅ PASSED"
    UNIT_EXIT=0
else
    UNIT_STATUS="❌ FAILED"
    UNIT_EXIT=1
fi

if [ "$UNIT_TEST_DIR" != "." ]; then
    cd - > /dev/null
fi

# Extract unit test stats (Jest format: "Tests: X failed, Y skipped, Z passed")
UNIT_PASSED=$(grep -oP 'Tests:.*?(\d+)\s+passed' "$UNIT_RESULTS" | grep -oP '\d+' | tail -1 || echo "0")
UNIT_FAILED=$(grep -oP 'Tests:.*?(\d+)\s+failed' "$UNIT_RESULTS" | grep -oP '\d+' | head -1 || echo "0")
UNIT_TOTAL=$(grep -oP 'Tests:.*?(\d+)\s+total' "$UNIT_RESULTS" | grep -oP '\d+' | tail -1 || echo "0")

echo -e "${GREEN}Unit Tests Complete: ${UNIT_PASSED}/${UNIT_TOTAL} passed${NC}"
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
if $E2E_TEST_CMD 2>&1 | tee "$E2E_RESULTS"; then
    E2E_STATUS="✅ PASSED"
    E2E_EXIT=0
else
    E2E_STATUS="❌ FAILED"
    E2E_EXIT=1
fi

# Parse E2E results from Playwright JSON output
# Extract from the JSON stats section if available, otherwise try text output
if grep -q '"stats"' "$E2E_RESULTS"; then
    E2E_PASSED=$(grep -oP '"expected":\s*(\d+)' "$E2E_RESULTS" | grep -oP '\d+' || echo "0")
    E2E_FAILED=$(grep -oP '"unexpected":\s*(\d+)' "$E2E_RESULTS" | grep -oP '\d+' || echo "0")
    E2E_SKIPPED=$(grep -oP '"skipped":\s*(\d+)' "$E2E_RESULTS" | grep -oP '\d+' || echo "0")
    E2E_TOTAL=$((E2E_PASSED + E2E_FAILED + E2E_SKIPPED))
else
    # Fallback to text parsing
    E2E_PASSED=$(grep -oP '\d+\s+passed' "$E2E_RESULTS" | grep -oP '^\d+' || echo "0")
    E2E_FAILED=$(grep -oP '\d+\s+failed' "$E2E_RESULTS" | grep -oP '^\d+' || echo "0")
    E2E_SKIPPED=$(grep -oP '\d+\s+skipped' "$E2E_RESULTS" | grep -oP '^\d+' || echo "0")
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
    SYNTAX_FILE=$(grep -oP '"file":\s*"[^"]+"' "$E2E_RESULTS" | grep -oP '/[^"]+\.spec\.ts' | head -1 || echo "unknown")
    SYNTAX_LINE=$(grep -oP '"line":\s*(\d+)' "$E2E_RESULTS" | grep -oP '\d+' | head -1 || echo "unknown")
    SYNTAX_MSG=$(grep -oP 'SyntaxError:.*?Unexpected token' "$E2E_RESULTS" | head -1 || echo "Syntax error")

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
        TEST_FILE=$(echo "$line" | grep -oP 'tests/e2e/[^ ]+\.spec\.ts' || echo "unknown")
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
gh issue list --state open --json number,title,labels,body --limit 100 > /tmp/gh-issues.json

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
        TEST_FILE=$(echo "$line" | grep -oP 'tests/e2e/[^ ]+\.spec\.ts' || echo "unknown")
        TEST_DESC=$(echo "$line" | sed -E 's/.*›\s+(.+)\s+\([0-9.]+s\)/\1/' || echo "Unknown test")

        # Determine priority
        PRIORITY=$(determine_priority "$TEST_FILE" "$TEST_DESC")

        # Check for existing issue
        EXISTING_ISSUE=$(find_matching_issue "$TEST_FILE" "$TEST_DESC")

        if [ -n "$EXISTING_ISSUE" ]; then
            # Update existing issue with new failure
            echo -e "${BLUE}Updating issue #${EXISTING_ISSUE}...${NC}"
            gh issue comment "$EXISTING_ISSUE" --body "## Test Failure (Regression Test)
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

            gh issue create \
                --title "$ISSUE_TITLE" \
                --body "$ISSUE_BODY" \
                --label "bug,automated-test-failure,$PRIORITY"
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
echo -e "  ${GREEN}Unit Tests:${NC}  $UNIT_PASSED/$UNIT_TOTAL passed"
echo -e "  ${GREEN}E2E Tests:${NC}   $E2E_PASSED/$E2E_TOTAL passed"
echo ""
echo -e "  ${YELLOW}Report saved to:${NC} $REPORT_FILE"
echo ""

# Exit with failure if any tests failed
if [ "$UNIT_EXIT" -ne 0 ] || [ "$E2E_EXIT" -ne 0 ]; then
    echo -e "${RED}⚠️  Some tests failed. Check GitHub issues for details.${NC}"
    exit 1
else
    echo -e "${GREEN}✅ All tests passed!${NC}"
    exit 0
fi
