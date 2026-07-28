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
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/issue-fns.sh"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

extract_first_number() {
    local file="$1"
    local pattern="$2"

    sed -nE "s/${pattern}/\\1/p" "$file" | head -1
}

extract_last_number() {
    local file="$1"
    local pattern="$2"

    sed -nE "s/${pattern}/\\1/p" "$file" | tail -1
}

extract_stat_or_zero() {
    local value="$1"

    if [ -n "$value" ]; then
        echo "$value"
    else
        echo "0"
    fi
}

append_command_failure_report() {
    local report_file="$1"
    local section_title="$2"
    local command="$3"
    local workdir="$4"
    local results_file="$5"

    {
        echo "### ${section_title} Command Failure"
        echo "- **Command**: \`${command}\`"
        echo "- **Working Directory**: \`${workdir}\`"
        echo ""
        echo '```text'
        sed -n '1,20p' "$results_file"
        echo '```'
        echo ""
    } >> "$report_file"
}

create_issue_with_existing_labels() {
    local title="$1"
    local body="$2"
    local candidate_csv="$3"
    local label
    local existing
    local args=()
    local issue_output
    local issue_status

    IFS=',' read -r -a requested_labels <<< "$candidate_csv"

    for label in "${requested_labels[@]}"; do
        # Only the github backend rejects unknown labels, and only then do we
        # have a label roster to check against. Without the roster (file
        # backend, or the listing failed) pass every label through unfiltered.
        if [ -s /tmp/gh-labels.json ]; then
            existing=$(jq -r --arg label "$label" '.[] | select(.name == $label) | .name' /tmp/gh-labels.json 2>/dev/null | head -1)
            if [ -z "$existing" ]; then
                echo -e "${YELLOW}Skipping missing label: ${label}${NC}"
                continue
            fi
        fi
        args+=(--label "$label")
    done

    set +e
    issue_output=$(issue_create --title "$title" --body "$body" "${args[@]}" 2>&1)
    issue_status=$?
    set -e

    if [ "$issue_status" -ne 0 ]; then
        echo -e "${YELLOW}Issue creation failed: ${issue_output}${NC}"
        return 1
    fi

    echo "$issue_output"
    return 0
}

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
    if grep -q "### Unit Tests Only" CLAUDE.md; then
        UNIT_TEST_CMD=$(grep -A5 "### Unit Tests Only" CLAUDE.md | sed -n '/```bash/,/```/p' | grep -v '```' | head -1)
    else
        UNIT_TEST_CMD="npm test"
    fi

    if grep -q "Working directory: " CLAUDE.md && grep -A5 "### Unit Tests Only" CLAUDE.md | grep -q "Working directory:"; then
        UNIT_TEST_DIR=$(grep -A5 "### Unit Tests Only" CLAUDE.md | grep "Working directory:" | sed 's/.*Working directory: *`\([^`]*\)`.*/\1/' | head -1)
    else
        UNIT_TEST_DIR="."
    fi

    # Extract E2E test configuration
    if grep -q "### E2E Tests Only" CLAUDE.md; then
        E2E_TEST_CMD=$(grep -A5 "### E2E Tests Only" CLAUDE.md | sed -n '/```bash/,/```/p' | grep -v '```' | head -1)
    else
        E2E_TEST_CMD="npx playwright test --reporter=json"
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

print_suite_summary() {
    local suite_name="$1"
    local status="$2"
    local passed="$3"
    local total="$4"

    if [ "$status" = "✅ PASSED" ]; then
        echo -e "${GREEN}${suite_name} Complete: ${status} (${passed}/${total} passed)${NC}"
    elif [ "$status" = "⏭️ SKIPPED" ]; then
        echo -e "${YELLOW}${suite_name} Complete: ${status} (${passed}/${total} passed)${NC}"
    else
        echo -e "${RED}${suite_name} Complete: ${status} (${passed}/${total} passed)${NC}"
    fi
}

print_final_suite_summary() {
    local suite_name="$1"
    local status="$2"
    local passed="$3"
    local total="$4"

    if [ "$status" = "✅ PASSED" ]; then
        echo -e "  ${GREEN}${suite_name}:${NC} ${status} (${passed}/${total} passed)"
    elif [ "$status" = "⏭️ SKIPPED" ]; then
        echo -e "  ${YELLOW}${suite_name}:${NC} ${status} (${passed}/${total} passed)"
    else
        echo -e "  ${RED}${suite_name}:${NC} ${status} (${passed}/${total} passed)"
    fi
}

is_node_based_command() {
    case "$1" in
        npm*|npx*|pnpm*|yarn*|bun*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

detect_skip_reason() {
    local command="$1"
    local workdir="$2"
    local suite_name="$3"
    local resolved_dir="$workdir"
    local suite_name_lower

    if [ -z "$resolved_dir" ] || [ "$resolved_dir" = "." ]; then
        resolved_dir="$(pwd)"
    fi

    if [ ! -d "$resolved_dir" ]; then
        echo "${suite_name} working directory does not exist: ${workdir}"
        return 0
    fi

    if is_node_based_command "$command" && [ ! -f "${resolved_dir}/package.json" ]; then
        suite_name_lower=$(printf '%s' "$suite_name" | tr '[:upper:]' '[:lower:]')
        echo "No package.json found in ${workdir}; skipping ${suite_name_lower} command '${command}'"
        return 0
    fi

    return 1
}

# ==========================================
# STEP 1: Run Unit Tests
# ==========================================
echo -e "${YELLOW}[1/2] Running Unit Tests...${NC}"
UNIT_RESULTS="/tmp/unit-test-results-${TIMESTAMP}.log"
UNIT_SKIP_REASON=""

if UNIT_SKIP_REASON=$(detect_skip_reason "$UNIT_TEST_CMD" "$UNIT_TEST_DIR" "Unit Tests"); then
    UNIT_STATUS="⏭️ SKIPPED"
    UNIT_EXIT=0
    UNIT_PASSED=0
    UNIT_FAILED=0
    UNIT_TOTAL=0
    printf '%s\n' "$UNIT_SKIP_REASON" | tee "$UNIT_RESULTS" >/dev/null
else
    # Run unit tests from configured directory
    if [ "$UNIT_TEST_DIR" != "." ]; then
        cd "$UNIT_TEST_DIR"
    fi

    set +e
    bash -lc "$UNIT_TEST_CMD" 2>&1 | tee "$UNIT_RESULTS"
    UNIT_CMD_EXIT=${PIPESTATUS[0]}
    set -e

    if [ "$UNIT_CMD_EXIT" -eq 0 ]; then
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
    UNIT_PASSED=$(extract_stat_or_zero "$(extract_last_number "$UNIT_RESULTS" '.*Tests:.*([0-9]+)[[:space:]]+passed.*')")
    UNIT_FAILED=$(extract_stat_or_zero "$(extract_first_number "$UNIT_RESULTS" '.*Tests:.*([0-9]+)[[:space:]]+failed.*')")
    UNIT_TOTAL=$(extract_stat_or_zero "$(extract_last_number "$UNIT_RESULTS" '.*Tests:.*([0-9]+)[[:space:]]+total.*')")
fi

print_suite_summary "Unit Tests" "$UNIT_STATUS" "$UNIT_PASSED" "$UNIT_TOTAL"
echo ""

# Add to report
cat >> "$REPORT_FILE" << EOF
### Unit Tests
- **Status**: $UNIT_STATUS
- **Command**: \`$UNIT_TEST_CMD\`
- **Working Directory**: \`$UNIT_TEST_DIR\`
- **Total**: $UNIT_TOTAL
- **Passed**: $UNIT_PASSED
- **Failed**: $UNIT_FAILED
- **Skip Reason**: ${UNIT_SKIP_REASON:-N/A}

EOF

# ==========================================
# STEP 2: Run E2E Tests
# ==========================================
echo -e "${YELLOW}[2/2] Running E2E Tests...${NC}"
E2E_RESULTS="/tmp/e2e-test-results-${TIMESTAMP}.log"
E2E_JSON="/tmp/e2e-results-${TIMESTAMP}.json"
E2E_SKIP_REASON=""

if E2E_SKIP_REASON=$(detect_skip_reason "$E2E_TEST_CMD" "." "E2E Tests"); then
    E2E_STATUS="⏭️ SKIPPED"
    E2E_EXIT=0
    E2E_PASSED=0
    E2E_FAILED=0
    E2E_SKIPPED=0
    E2E_TOTAL=0
    printf '%s\n' "$E2E_SKIP_REASON" | tee "$E2E_RESULTS" >/dev/null
else
    # Run E2E tests with configured command
    set +e
    bash -lc "$E2E_TEST_CMD" 2>&1 | tee "$E2E_RESULTS"
    E2E_CMD_EXIT=${PIPESTATUS[0]}
    set -e

    if [ "$E2E_CMD_EXIT" -eq 0 ]; then
        E2E_STATUS="✅ PASSED"
        E2E_EXIT=0
    else
        E2E_STATUS="❌ FAILED"
        E2E_EXIT=1
    fi

    # Parse E2E results from Playwright JSON output
    # Extract from the JSON stats section if available, otherwise try text output
    if grep -q '"stats"' "$E2E_RESULTS"; then
        E2E_PASSED=$(extract_stat_or_zero "$(extract_last_number "$E2E_RESULTS" '.*"expected":[[:space:]]*([0-9]+).*')")
        E2E_FAILED=$(extract_stat_or_zero "$(extract_last_number "$E2E_RESULTS" '.*"unexpected":[[:space:]]*([0-9]+).*')")
        E2E_SKIPPED=$(extract_stat_or_zero "$(extract_last_number "$E2E_RESULTS" '.*"skipped":[[:space:]]*([0-9]+).*')")
        E2E_TOTAL=$((E2E_PASSED + E2E_FAILED + E2E_SKIPPED))
    else
        # Fallback to text parsing
        E2E_PASSED=$(extract_stat_or_zero "$(extract_last_number "$E2E_RESULTS" '.*([0-9]+)[[:space:]]+passed.*')")
        E2E_FAILED=$(extract_stat_or_zero "$(extract_last_number "$E2E_RESULTS" '.*([0-9]+)[[:space:]]+failed.*')")
        E2E_SKIPPED=$(extract_stat_or_zero "$(extract_last_number "$E2E_RESULTS" '.*([0-9]+)[[:space:]]+skipped.*')")
        E2E_TOTAL=$((E2E_PASSED + E2E_FAILED + E2E_SKIPPED))
    fi
fi

print_suite_summary "E2E Tests" "$E2E_STATUS" "$E2E_PASSED" "$E2E_TOTAL"
echo ""

# Add to report
cat >> "$REPORT_FILE" << EOF
### E2E Tests
- **Status**: $E2E_STATUS
- **Command**: \`$E2E_TEST_CMD\`
- **Total**: $E2E_TOTAL
- **Passed**: $E2E_PASSED
- **Failed**: $E2E_FAILED
- **Skipped**: $E2E_SKIPPED
- **Skip Reason**: ${E2E_SKIP_REASON:-N/A}

---

EOF

# ==========================================
# STEP 3: Process Test Failures
# ==========================================
echo -e "${YELLOW}Processing test failures and GitHub issues...${NC}"

UNIT_COMMAND_FAILURE=0
if [ "$UNIT_EXIT" -ne 0 ] && [ "$UNIT_TOTAL" -eq 0 ] && [ "$UNIT_FAILED" -eq 0 ]; then
    UNIT_COMMAND_FAILURE=1
    append_command_failure_report "$REPORT_FILE" "Unit Test" "$UNIT_TEST_CMD" "$UNIT_TEST_DIR" "$UNIT_RESULTS"
fi

E2E_COMMAND_FAILURE=0
if [ "$E2E_EXIT" -ne 0 ] && [ "$E2E_TOTAL" -eq 0 ] && [ "$E2E_FAILED" -eq 0 ]; then
    E2E_COMMAND_FAILURE=1
    append_command_failure_report "$REPORT_FILE" "E2E Test" "$E2E_TEST_CMD" "." "$E2E_RESULTS"
fi

# Check for E2E syntax errors first
if [ "$E2E_STATUS" != "⏭️ SKIPPED" ] && grep -q "SyntaxError" "$E2E_RESULTS"; then
    echo "## E2E Syntax Errors" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"

    # Extract syntax error details
    SYNTAX_FILE=$(extract_stat_or_zero "$(extract_first_number "$E2E_RESULTS" '.*"file":[[:space:]]*"([^"]+)".*')")
    SYNTAX_LINE=$(extract_stat_or_zero "$(extract_first_number "$E2E_RESULTS" '.*"line":[[:space:]]*([0-9]+).*')")
    SYNTAX_MSG=$(sed -nE 's/.*(SyntaxError:.*Unexpected token.*)/\1/p' "$E2E_RESULTS" | head -1)
    if [ "$SYNTAX_FILE" = "0" ]; then SYNTAX_FILE="unknown"; fi
    if [ "$SYNTAX_LINE" = "0" ]; then SYNTAX_LINE="unknown"; fi
    if [ -z "$SYNTAX_MSG" ]; then SYNTAX_MSG="Syntax error"; fi

    echo "### Syntax Error" >> "$REPORT_FILE"
    echo "- **File**: \`$SYNTAX_FILE\`" >> "$REPORT_FILE"
    echo "- **Line**: $SYNTAX_LINE" >> "$REPORT_FILE"
    echo "- **Error**: $SYNTAX_MSG" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
fi

# Extract E2E test failures
if [ "$E2E_STATUS" != "⏭️ SKIPPED" ] && [ "$E2E_FAILED" -gt 0 ]; then
    echo "## E2E Test Failures" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"

    # Extract failed test names from log
    while IFS= read -r line; do
        # Extract test file and description
        TEST_FILE=$(echo "$line" | sed -nE 's/.*(tests\/e2e\/[^ ]+\.spec\.ts).*/\1/p')
        if [ -z "$TEST_FILE" ]; then TEST_FILE="unknown"; fi
        TEST_DESC=$(echo "$line" | sed -E 's/.*›\s+(.+)\s+\([0-9.]+s\)/\1/' || echo "Unknown test")

        echo "### Failed Test" >> "$REPORT_FILE"
        echo "- **File**: \`$TEST_FILE\`" >> "$REPORT_FILE"
        echo "- **Test**: $TEST_DESC" >> "$REPORT_FILE"
        echo "" >> "$REPORT_FILE"
    done < <(grep "✘" "$E2E_RESULTS" || true)
fi

# Extract unit test failures
if [ "$UNIT_FAILED" -gt 0 ]; then
    echo "## Unit Test Failures" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"

    while IFS= read -r line; do
        if echo "$line" | grep -q "^[[:space:]]*[0-9])" ; then
            echo "- $line" >> "$REPORT_FILE"
        fi
    done < <(grep "failing" "$UNIT_RESULTS" -A 50 || true)
    echo "" >> "$REPORT_FILE"
fi

# ==========================================
# STEP 4: GitHub Issue Management
# ==========================================
echo -e "${YELLOW}Checking for existing GitHub issues...${NC}"

# Fetch all open issues
issue_list --state open --limit 100 > /tmp/gh-issues.json

# Label roster for create_issue_with_existing_labels. Only the github backend
# rejects labels that don't exist yet; other backends leave the file absent and
# the helper then passes labels through unfiltered.
rm -f /tmp/gh-labels.json
if [ "${ISSUE_SOURCE:-}" = "github" ]; then
    gh label list --json name --limit 200 > /tmp/gh-labels.json 2>/dev/null || true
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
    while IFS= read -r line; do
        TEST_FILE=$(echo "$line" | sed -nE 's/.*(tests\/e2e\/[^ ]+\.spec\.ts).*/\1/p')
        if [ -z "$TEST_FILE" ]; then TEST_FILE="unknown"; fi
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

            create_issue_with_existing_labels "$ISSUE_TITLE" "$ISSUE_BODY" "bug,automated-test-failure,$PRIORITY" || true
        fi
    done < <(grep "✘" "$E2E_RESULTS" || true)
fi

create_command_failure_issue() {
    local suite_name="$1"
    local command="$2"
    local workdir="$3"
    local results_file="$4"
    local priority="$5"
    local title="${priority}-${suite_name} command failed before tests executed"
    local existing_issue
    local suite_name_lower

    existing_issue=$(jq -r --arg title "$title" '.[] | select(.title == $title) | .number' /tmp/gh-issues.json 2>/dev/null | head -1)
    suite_name_lower=$(printf '%s' "$suite_name" | tr '[:upper:]' '[:lower:]')

    local issue_body="## ${suite_name} Command Failure
**Command**: \`${command}\`
**Working Directory**: \`${workdir}\`
**Detected**: $(date)
**Test Report**: See \`${REPORT_FILE}\`

The configured ${suite_name_lower} command failed before any test cases were reported.

\`\`\`text
$(sed -n '1,20p' "$results_file")
\`\`\`

**Next Steps**:
1. Fix the configured command or working directory
2. Re-run \`bash plugins/autocoder/scripts/regression-test.sh\`
3. Verify that real test counts are reported"

    if [ -n "$existing_issue" ]; then
        echo -e "${BLUE}Updating issue #${existing_issue}...${NC}"
        gh issue comment "$existing_issue" --body "$issue_body"
    else
        echo -e "${BLUE}Creating new issue for ${suite_name} command failure...${NC}"
        create_issue_with_existing_labels "$title" "$issue_body" "bug,automated-test-failure,$priority" || true
    fi
}

if [ "$UNIT_COMMAND_FAILURE" -eq 1 ]; then
    create_command_failure_issue "Unit Tests" "$UNIT_TEST_CMD" "$UNIT_TEST_DIR" "$UNIT_RESULTS" "P1"
fi

if [ "$E2E_COMMAND_FAILURE" -eq 1 ]; then
    create_command_failure_issue "E2E Tests" "$E2E_TEST_CMD" "." "$E2E_RESULTS" "P1"
fi

# ==========================================
# STEP 5: Final Report
# ==========================================
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Regression Test Complete${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
print_final_suite_summary "Unit Tests" "$UNIT_STATUS" "$UNIT_PASSED" "$UNIT_TOTAL"
print_final_suite_summary "E2E Tests" "$E2E_STATUS" "$E2E_PASSED" "$E2E_TOTAL"
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
