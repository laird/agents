# Full Regression Test

Run the complete regression test suite, analyze all results (successes and failures), and manage GitHub issues accordingly.

## Usage

```bash
# Run full regression test suite
/full-regression-test
```

## What This Does

1. **Load Configuration** from CLAUDE.md (test commands, report locations)
2. **Run Build Verification** with configured build command
3. **Run Unit Tests** with configured test command
4. **Run E2E Tests** with configured E2E command (if available)
5. **Analyze All Results** - both successes and failures
6. **Manage GitHub Issues**:
   - Create new issues for new failures
   - Update existing issues with regression data
   - **Close resolved issues** when previously-failing tests now pass
   - Add analysis comments to relevant issues
7. **Generate Report** saved to configured report directory

## Configuration

This command reads configuration from `CLAUDE.md`:

```markdown
## Automated Testing & Issue Management

### Regression Test Suite
```bash
npm test
```

### Build Verification
```bash
npm run build
```

### Test Framework Details

**Unit Tests**:
- Framework: Jest/Vitest/etc
- Location: tests/unit/

**E2E Tests**:
- Framework: Playwright/Cypress
- Location: tests/e2e/

**Test Reports**:
- Location: `docs/test/regression-reports/`
```

If no configuration is found, defaults are used.

## Instructions

```bash
# Timestamp for this test run
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")

# Load configuration from CLAUDE.md
if [ -f "CLAUDE.md" ]; then
  echo "📋 Loading configuration from CLAUDE.md"

  # Check if autocoder configuration exists
  if ! grep -q "## Automated Testing & Issue Management" CLAUDE.md; then
    echo "⚠️  No autocoder configuration found in CLAUDE.md"
    echo "📝 Adding autocoder configuration section to CLAUDE.md..."

    # Append autocoder configuration to CLAUDE.md
    cat >> CLAUDE.md << 'AUTOCODER_CONFIG'

## Automated Testing & Issue Management

This section configures the `/full-regression-test` command.

### Regression Test Suite
```bash
npm test
```

### Build Verification
```bash
npm run build
```

### Test Framework Details

**Unit Tests**:
- Framework: (Configure your test framework)
- Location: (Configure test file locations)

**E2E Tests**:
- Framework: (Configure E2E test framework)
- Location: (Configure E2E test locations)

**Test Reports**:
- Location: `docs/test/regression-reports/`

AUTOCODER_CONFIG

    echo "✅ Added autocoder configuration to CLAUDE.md - please update with project-specific details"
  fi

  # Extract test command
  if grep -q "### Regression Test Suite" CLAUDE.md; then
    TEST_COMMAND=$(sed -n "/### Regression Test Suite/,/^###/{/^\`\`\`bash$/n;p;}" CLAUDE.md | grep -v "^#" | grep -v "^\`\`\`" | grep -v "^$" | head -1)
    echo "✅ Regression test command: $TEST_COMMAND"
  else
    TEST_COMMAND="npm test"
    echo "⚠️  No regression test command found, using default: $TEST_COMMAND"
  fi

  # Extract build command
  if grep -q "### Build Verification" CLAUDE.md; then
    BUILD_COMMAND=$(sed -n "/### Build Verification/,/^###/{/^\`\`\`bash$/n;p;}" CLAUDE.md | grep -v "^#" | grep -v "^\`\`\`" | grep -v "^$" | head -1)
    echo "✅ Build command: $BUILD_COMMAND"
  else
    BUILD_COMMAND="npm run build"
    echo "⚠️  No build command found, using default: $BUILD_COMMAND"
  fi

  # Extract report directory
  if grep -q "Location:" CLAUDE.md && grep "Location:" CLAUDE.md | grep -q "regression-reports"; then
    REPORT_DIR=$(grep "Location:" CLAUDE.md | sed 's/.*`\([^`]*regression-reports[^`]*\)`.*/\1/' | head -1)
    echo "✅ Report directory: $REPORT_DIR"
  else
    REPORT_DIR="docs/test/regression-reports"
    echo "⚠️  No report directory found, using default: $REPORT_DIR"
  fi
else
  echo "⚠️  No CLAUDE.md found in project, using defaults"
  TEST_COMMAND="npm test"
  BUILD_COMMAND="npm run build"
  REPORT_DIR="docs/test/regression-reports"
fi

# Create report directory
mkdir -p "$REPORT_DIR"

REPORT_FILE="$REPORT_DIR/regression-${TIMESTAMP}.md"

echo ""
echo "════════════════════════════════════════"
echo "  Full Regression Test Suite"
echo "  Started: $(date)"
echo "════════════════════════════════════════"
echo ""

# Initialize report
cat > "$REPORT_FILE" << EOF
# Regression Test Report
**Date**: $(date)
**Timestamp**: ${TIMESTAMP}

## Test Summary

EOF
```

## Step 1: Run Build Verification

```bash
echo "🔧 [1/3] Running Build Verification..."
BUILD_RESULTS="/tmp/build-results-${TIMESTAMP}.log"

if $BUILD_COMMAND 2>&1 | tee "$BUILD_RESULTS"; then
  BUILD_STATUS="✅ PASSED"
  BUILD_EXIT=0
  echo "✅ Build successful"
else
  BUILD_STATUS="❌ FAILED"
  BUILD_EXIT=1
  echo "❌ Build failed"
fi

cat >> "$REPORT_FILE" << EOF
### Build Verification
- **Status**: $BUILD_STATUS
- **Command**: \`$BUILD_COMMAND\`

EOF
```

## Step 2: Run Unit Tests

```bash
echo ""
echo "🧪 [2/3] Running Unit Tests..."
UNIT_RESULTS="/tmp/unit-test-results-${TIMESTAMP}.log"

if $TEST_COMMAND 2>&1 | tee "$UNIT_RESULTS"; then
  UNIT_STATUS="✅ PASSED"
  UNIT_EXIT=0
else
  UNIT_STATUS="❌ FAILED"
  UNIT_EXIT=1
fi

# Extract unit test stats (Jest format)
UNIT_PASSED=$(grep -oP 'Tests:.*?(\d+)\s+passed' "$UNIT_RESULTS" | grep -oP '\d+' | tail -1 || echo "0")
UNIT_FAILED=$(grep -oP 'Tests:.*?(\d+)\s+failed' "$UNIT_RESULTS" | grep -oP '\d+' | head -1 || echo "0")
UNIT_TOTAL=$(grep -oP 'Tests:.*?(\d+)\s+total' "$UNIT_RESULTS" | grep -oP '\d+' | tail -1 || echo "0")

echo "Unit Tests: ${UNIT_PASSED}/${UNIT_TOTAL} passed"

cat >> "$REPORT_FILE" << EOF
### Unit Tests
- **Status**: $UNIT_STATUS
- **Total**: $UNIT_TOTAL
- **Passed**: $UNIT_PASSED
- **Failed**: $UNIT_FAILED

EOF
```

## Step 3: Run E2E Tests (if configured)

```bash
echo ""
echo "🌐 [3/3] Running E2E Tests..."
E2E_RESULTS="/tmp/e2e-test-results-${TIMESTAMP}.log"

# Check if E2E tests are configured
if grep -q "### E2E Tests Only" CLAUDE.md 2>/dev/null; then
  E2E_COMMAND=$(sed -n "/### E2E Tests Only/,/^###/{/^\`\`\`bash$/n;p;}" CLAUDE.md | grep -v "^#" | grep -v "^\`\`\`" | grep -v "^$" | head -1)
  echo "✅ E2E test command: $E2E_COMMAND"

  if $E2E_COMMAND 2>&1 | tee "$E2E_RESULTS"; then
    E2E_STATUS="✅ PASSED"
    E2E_EXIT=0
  else
    E2E_STATUS="❌ FAILED"
    E2E_EXIT=1
  fi

  # Parse E2E results
  E2E_PASSED=$(grep -oP '\d+\s+passed' "$E2E_RESULTS" | grep -oP '^\d+' || echo "0")
  E2E_FAILED=$(grep -oP '\d+\s+failed' "$E2E_RESULTS" | grep -oP '^\d+' || echo "0")
  E2E_TOTAL=$((E2E_PASSED + E2E_FAILED))

  echo "E2E Tests: ${E2E_PASSED}/${E2E_TOTAL} passed"

  cat >> "$REPORT_FILE" << EOF
### E2E Tests
- **Status**: $E2E_STATUS
- **Total**: $E2E_TOTAL
- **Passed**: $E2E_PASSED
- **Failed**: $E2E_FAILED

EOF
else
  echo "⏭️  E2E tests not configured, skipping"
  E2E_EXIT=0
  E2E_FAILED=0
fi
```

## Step 4: Analyze Results and Manage GitHub Issues

After running tests, analyze ALL results (successes and failures) and manage GitHub issues accordingly.

### Priority Assignment

Failures are assigned priority based on impact:
- **P0 - Critical**: Auth, security, crashes, data loss
- **P1 - High**: Major features broken, CRUD operations failing
- **P2 - Medium**: Filtering, sorting, search, display issues
- **P3 - Low**: UI issues, validation, edge cases

### Issue Management Strategy

1. **For failures**: Create new issues or update existing ones with regression data
2. **For successes**: Check if there are open issues for now-passing tests and close them
3. **Add analysis comments**: Document test results on relevant issues

```bash
echo ""
echo "📋 Analyzing test results and managing GitHub issues..."

# Fetch ALL test-failure issues (open and closed for analysis)
gh issue list --state open --label "test-failure" --json number,title,labels,body --limit 200 > /tmp/gh-open-issues.json 2>/dev/null || echo "[]" > /tmp/gh-open-issues.json
gh issue list --state all --json number,title,labels,body --limit 200 > /tmp/gh-all-issues.json 2>/dev/null || echo "[]" > /tmp/gh-all-issues.json

# Count results
TOTAL_FAILURES=$((UNIT_FAILED + E2E_FAILED))
TOTAL_PASSED=$((UNIT_PASSED + E2E_PASSED))
ISSUES_CREATED=0
ISSUES_UPDATED=0
ISSUES_CLOSED=0

cat >> "$REPORT_FILE" << EOF
---

## Test Analysis

- **Total Passed**: $TOTAL_PASSED
- **Total Failed**: $TOTAL_FAILURES

EOF
```

### Step 4A: Process Test Successes - Close Resolved Issues

Check if any previously-failing tests now pass and close their issues:

```bash
echo ""
echo "🔍 Checking for resolved issues (tests that now pass)..."

# Extract passing test names
grep -E "(PASS|✓|✔)" "$UNIT_RESULTS" 2>/dev/null | head -50 > /tmp/passing-tests.txt || true
if [ -f "$E2E_RESULTS" ]; then
  grep -E "(passed|✓|✔)" "$E2E_RESULTS" 2>/dev/null >> /tmp/passing-tests.txt || true
fi

# Check each open test-failure issue to see if its test now passes
cat /tmp/gh-open-issues.json | python3 -c "
import json, sys, subprocess

issues = json.load(sys.stdin)
passing_tests = open('/tmp/passing-tests.txt', 'r').read().lower() if open('/tmp/passing-tests.txt', 'r') else ''

for issue in issues:
    title = issue.get('title', '').lower()
    number = issue.get('number')

    # Check if this issue's test name appears in passing tests
    # Extract test name from title (remove 'Test failure:' or 'E2E failure:' prefix)
    test_name = title.replace('test failure:', '').replace('e2e failure:', '').strip()[:40]

    if test_name and test_name in passing_tests:
        print(f'{number}|{title}')
" 2>/dev/null > /tmp/resolved-issues.txt || true

# Close resolved issues
if [ -s /tmp/resolved-issues.txt ]; then
  echo "Found issues to close:"
  while IFS='|' read -r issue_num issue_title; do
    if [ -n "$issue_num" ]; then
      echo "  ✅ Closing #$issue_num: $issue_title"

      gh issue comment "$issue_num" --body "## ✅ Test Now Passing

**Date**: $(date)
**Report**: \`$REPORT_FILE\`

This test is now passing in the regression test suite.

### Test Results Summary
- Unit Tests: ${UNIT_PASSED}/${UNIT_TOTAL} passed
- E2E Tests: ${E2E_PASSED:-0}/${E2E_TOTAL:-0} passed

Closing this issue as resolved.

🤖 Auto-closed by /full-regression-test" 2>/dev/null || true

      gh issue close "$issue_num" --comment "Verified fixed - test now passes" 2>/dev/null || true
      ISSUES_CLOSED=$((ISSUES_CLOSED + 1))
    fi
  done < /tmp/resolved-issues.txt

  cat >> "$REPORT_FILE" << EOF
### Resolved Issues (Closed)

EOF
  while IFS='|' read -r issue_num issue_title; do
    echo "- #$issue_num: $issue_title" >> "$REPORT_FILE"
  done < /tmp/resolved-issues.txt
  echo "" >> "$REPORT_FILE"
else
  echo "  No resolved issues found"
fi
```

### Step 4B: Process Test Failures - Create/Update Issues

```bash
echo ""
echo "🔍 Processing test failures..."

if [ "$TOTAL_FAILURES" -gt 0 ]; then
  echo "Found $TOTAL_FAILURES test failure(s)"

  cat >> "$REPORT_FILE" << EOF
### Test Failures

Total failures: $TOTAL_FAILURES

EOF

  # Process unit test failures
  if [ "$UNIT_FAILED" -gt 0 ]; then
    echo "Processing $UNIT_FAILED unit test failure(s)..."

    # Extract failing test names and create/update issues
    grep -E "(FAIL|✘|✗)" "$UNIT_RESULTS" 2>/dev/null | head -20 | while IFS= read -r line; do
      TEST_NAME=$(echo "$line" | sed -E 's/.*?(FAIL|✘|✗)\s+//' | head -c 80)

      if [ -n "$TEST_NAME" ]; then
        # Determine priority
        if echo "$TEST_NAME" | grep -qiE "auth|login|security|crash"; then
          PRIORITY="P0"
        elif echo "$TEST_NAME" | grep -qiE "create|delete|update|save"; then
          PRIORITY="P1"
        elif echo "$TEST_NAME" | grep -qiE "filter|sort|search|display"; then
          PRIORITY="P2"
        else
          PRIORITY="P3"
        fi

        # Check if issue exists (search in all issues, not just open)
        EXISTING=$(cat /tmp/gh-all-issues.json | python3 -c "
import json, sys
issues = json.load(sys.stdin)
test = '$TEST_NAME'.lower()[:30]
for i in issues:
    if test in i.get('title','').lower():
        print(i['number'])
        break
" 2>/dev/null || echo "")

        if [ -n "$EXISTING" ]; then
          echo "  📝 Updating issue #$EXISTING: $TEST_NAME"
          gh issue comment "$EXISTING" --body "## 🔴 Regression Test Failure

**Date**: $(date)
**Test**: \`$TEST_NAME\`
**Priority**: $PRIORITY
**Report**: \`$REPORT_FILE\`

### Test Results Context
- Unit Tests: ${UNIT_PASSED}/${UNIT_TOTAL} passed (${UNIT_FAILED} failed)
- Build Status: $BUILD_STATUS

This test failed during automated regression testing.

🤖 Updated by /full-regression-test" 2>/dev/null || true

          # Reopen if closed
          gh issue reopen "$EXISTING" 2>/dev/null || true
          ISSUES_UPDATED=$((ISSUES_UPDATED + 1))
        else
          echo "  ➕ Creating issue: $TEST_NAME"
          gh issue create \
            --title "Test failure: ${TEST_NAME:0:80}" \
            --body "## Test Failure

**Test**: \`$TEST_NAME\`
**Priority**: $PRIORITY
**Detected**: $(date)
**Report**: \`$REPORT_FILE\`

### Test Results Context
- Unit Tests: ${UNIT_PASSED}/${UNIT_TOTAL} passed (${UNIT_FAILED} failed)
- Build Status: $BUILD_STATUS

This failure was detected during automated regression testing.

**Next Steps**:
1. Reproduce the failure locally
2. Identify root cause
3. Implement fix
4. Verify with \`/full-regression-test\`

🤖 Created by /full-regression-test" \
            --label "bug,test-failure,$PRIORITY" 2>/dev/null || true
          ISSUES_CREATED=$((ISSUES_CREATED + 1))
        fi
      fi
    done
  fi

  # Process E2E test failures
  if [ "$E2E_FAILED" -gt 0 ]; then
    echo "Processing $E2E_FAILED E2E test failure(s)..."

    grep -E "(✘|✗|FAILED)" "$E2E_RESULTS" 2>/dev/null | head -20 | while IFS= read -r line; do
      TEST_NAME=$(echo "$line" | sed -E 's/.*?(✘|✗|FAILED)\s*//' | head -c 80)

      if [ -n "$TEST_NAME" ]; then
        # Determine priority based on test content
        if echo "$TEST_NAME" | grep -qiE "auth|login|security|checkout"; then
          PRIORITY="P0"
        elif echo "$TEST_NAME" | grep -qiE "create|delete|submit|save"; then
          PRIORITY="P1"
        else
          PRIORITY="P2"
        fi

        # Check if issue exists
        EXISTING=$(cat /tmp/gh-all-issues.json | python3 -c "
import json, sys
issues = json.load(sys.stdin)
test = '$TEST_NAME'.lower()[:30]
for i in issues:
    if test in i.get('title','').lower():
        print(i['number'])
        break
" 2>/dev/null || echo "")

        if [ -n "$EXISTING" ]; then
          echo "  📝 Updating issue #$EXISTING: $TEST_NAME"
          gh issue comment "$EXISTING" --body "## 🔴 E2E Regression Test Failure

**Date**: $(date)
**Test**: \`$TEST_NAME\`
**Priority**: $PRIORITY
**Report**: \`$REPORT_FILE\`

### Test Results Context
- E2E Tests: ${E2E_PASSED}/${E2E_TOTAL} passed (${E2E_FAILED} failed)
- Build Status: $BUILD_STATUS

This E2E test failed during automated regression testing.

🤖 Updated by /full-regression-test" 2>/dev/null || true

          # Reopen if closed
          gh issue reopen "$EXISTING" 2>/dev/null || true
          ISSUES_UPDATED=$((ISSUES_UPDATED + 1))
        else
          echo "  ➕ Creating issue: $TEST_NAME"
          gh issue create \
            --title "E2E failure: ${TEST_NAME:0:80}" \
            --body "## E2E Test Failure

**Test**: \`$TEST_NAME\`
**Priority**: $PRIORITY
**Detected**: $(date)
**Report**: \`$REPORT_FILE\`

### Test Results Context
- E2E Tests: ${E2E_PASSED}/${E2E_TOTAL} passed (${E2E_FAILED} failed)
- Build Status: $BUILD_STATUS

This E2E test failure was detected during automated regression testing.

**Next Steps**:
1. Reproduce the failure locally
2. Check for environment/timing issues
3. Implement fix
4. Verify with \`/full-regression-test\`

🤖 Created by /full-regression-test" \
            --label "bug,test-failure,e2e,$PRIORITY" 2>/dev/null || true
          ISSUES_CREATED=$((ISSUES_CREATED + 1))
        fi
      fi
    done
  fi
else
  echo "✅ All tests passed!"

  cat >> "$REPORT_FILE" << EOF
### Result

✅ **All tests passed!**

No test failures detected during this regression test run.

EOF
fi

echo ""
echo "📊 Issue Management Summary:"
echo "  - Issues created: $ISSUES_CREATED"
echo "  - Issues updated: $ISSUES_UPDATED"
echo "  - Issues closed:  $ISSUES_CLOSED"
```

## Step 5: Final Report

```bash
echo ""
echo "════════════════════════════════════════"
echo "  Regression Test Complete"
echo "════════════════════════════════════════"
echo ""
echo "  Build:       $BUILD_STATUS"
echo "  Unit Tests:  ${UNIT_PASSED}/${UNIT_TOTAL} passed"
if [ -n "$E2E_TOTAL" ] && [ "$E2E_TOTAL" -gt 0 ]; then
  echo "  E2E Tests:   ${E2E_PASSED}/${E2E_TOTAL} passed"
fi
echo ""
echo "  Report: $REPORT_FILE"
echo ""

# Finalize report
cat >> "$REPORT_FILE" << EOF
---

## Summary

| Category | Status |
|----------|--------|
| Build | $BUILD_STATUS |
| Unit Tests | ${UNIT_PASSED}/${UNIT_TOTAL} passed |
| E2E Tests | ${E2E_PASSED:-N/A}/${E2E_TOTAL:-N/A} passed |

### GitHub Issue Management

| Action | Count |
|--------|-------|
| Issues Created | $ISSUES_CREATED |
| Issues Updated | $ISSUES_UPDATED |
| Issues Closed (Resolved) | $ISSUES_CLOSED |

---
🤖 Generated by /full-regression-test at $(date)
EOF

# Set exit code
if [ "$BUILD_EXIT" -ne 0 ] || [ "$UNIT_EXIT" -ne 0 ] || [ "$E2E_EXIT" -ne 0 ]; then
  echo "⚠️  Some tests failed. Check GitHub issues for details."
  exit 1
else
  echo "✅ All tests passed!"
  exit 0
fi
```

## Output

After running, this command produces:

1. **Console output** with test results summary and issue management stats
2. **Markdown report** saved to configured report directory
3. **GitHub issue management**:
   - New issues created for new failures
   - Existing issues updated with regression data
   - Resolved issues closed automatically when tests pass
   - Analysis comments added to relevant issues

## Integration with /fix

This command is automatically invoked by `/fix` when no priority bug issues exist. After running:

- If failures are found → Issues are created → `/fix` picks them up
- If all pass → `/fix` moves to enhancement phase

You can also run this command standalone to check project health.

---

🤖 **Ready to run full regression test suite.**
