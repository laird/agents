# Full Regression Test

Run the complete regression test suite, analyze results, and create GitHub issues for any failures.

## Usage

```bash
# Run full regression test suite
/full-regression-test
```

## What This Does

1. **Load Configuration** from CLAUDE.md (test commands, report locations)
2. **Run Unit Tests** with configured test command
3. **Run E2E Tests** with configured E2E command
4. **Analyze Results** and categorize failures by priority
5. **Create/Update GitHub Issues** for test failures with priority labels
6. **Generate Report** saved to configured report directory

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

  # Check if autofix configuration exists
  if ! grep -q "## Automated Testing & Issue Management" CLAUDE.md; then
    echo "⚠️  No autofix configuration found in CLAUDE.md"
    echo "📝 Adding autofix configuration section to CLAUDE.md..."

    # Append autofix configuration to CLAUDE.md
    cat >> CLAUDE.md << 'AUTOFIX_CONFIG'

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

AUTOFIX_CONFIG

    echo "✅ Added autofix configuration to CLAUDE.md - please update with project-specific details"
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

## Step 4: Analyze Failures and Create GitHub Issues

After running the tests, analyze any failures and create GitHub issues:

### Priority Assignment

Failures are assigned priority based on impact:
- **P0 - Critical**: Auth, security, crashes, data loss
- **P1 - High**: Major features broken, CRUD operations failing
- **P2 - Medium**: Filtering, sorting, search, display issues
- **P3 - Low**: UI issues, validation, edge cases

### Issue Creation

For each test failure:

1. **Check for existing issue** - Search by test name/file
2. **If exists**: Add comment with regression data
3. **If new**: Create issue with priority label and details

```bash
echo ""
echo "📋 Processing test failures..."

# Fetch existing issues
gh issue list --state open --json number,title,labels,body --limit 100 > /tmp/gh-issues.json 2>/dev/null || echo "[]" > /tmp/gh-issues.json

# Count failures
TOTAL_FAILURES=$((UNIT_FAILED + E2E_FAILED))

if [ "$TOTAL_FAILURES" -gt 0 ]; then
  echo "Found $TOTAL_FAILURES test failure(s)"

  cat >> "$REPORT_FILE" << EOF
---

## Test Failures

Total failures: $TOTAL_FAILURES

EOF

  # Process unit test failures
  if [ "$UNIT_FAILED" -gt 0 ]; then
    echo "Creating issues for $UNIT_FAILED unit test failure(s)..."

    # Extract failing test names and create issues
    grep -E "(FAIL|✘|✗)" "$UNIT_RESULTS" | head -20 | while IFS= read -r line; do
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

        # Check if issue exists
        EXISTING=$(cat /tmp/gh-issues.json | python3 -c "
import json, sys
issues = json.load(sys.stdin)
test = '$TEST_NAME'.lower()[:30]
for i in issues:
    if test in i.get('title','').lower():
        print(i['number'])
        break
" 2>/dev/null || echo "")

        if [ -n "$EXISTING" ]; then
          echo "  Updating issue #$EXISTING: $TEST_NAME"
          gh issue comment "$EXISTING" --body "## Regression Test Failure
**Date**: $(date)
**Test**: $TEST_NAME
**Priority**: $PRIORITY

This test failed during automated regression testing." 2>/dev/null || true
        else
          echo "  Creating issue: $TEST_NAME"
          gh issue create \
            --title "Test failure: ${TEST_NAME:0:80}" \
            --body "## Test Failure

**Test**: $TEST_NAME
**Priority**: $PRIORITY
**Detected**: $(date)
**Report**: \`$REPORT_FILE\`

This failure was detected during automated regression testing.

**Next Steps**:
1. Reproduce the failure locally
2. Identify root cause
3. Implement fix
4. Verify with regression test

🤖 Created by /full-regression-test" \
            --label "bug,test-failure,$PRIORITY" 2>/dev/null || true
        fi
      fi
    done
  fi

  # Process E2E test failures
  if [ "$E2E_FAILED" -gt 0 ]; then
    echo "Creating issues for $E2E_FAILED E2E test failure(s)..."

    grep -E "(✘|✗|FAILED)" "$E2E_RESULTS" 2>/dev/null | head -20 | while IFS= read -r line; do
      TEST_NAME=$(echo "$line" | sed -E 's/.*?(✘|✗|FAILED)\s*//' | head -c 80)

      if [ -n "$TEST_NAME" ]; then
        PRIORITY="P2"  # Default E2E to medium priority

        echo "  Creating issue: $TEST_NAME"
        gh issue create \
          --title "E2E failure: ${TEST_NAME:0:80}" \
          --body "## E2E Test Failure

**Test**: $TEST_NAME
**Priority**: $PRIORITY
**Detected**: $(date)
**Report**: \`$REPORT_FILE\`

This E2E test failure was detected during automated regression testing.

🤖 Created by /full-regression-test" \
          --label "bug,test-failure,e2e,$PRIORITY" 2>/dev/null || true
      fi
    done
  fi
else
  echo "✅ All tests passed - no issues to create"

  cat >> "$REPORT_FILE" << EOF
---

## Result

✅ **All tests passed!**

No test failures detected during this regression test run.

EOF
fi
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
| Unit Tests | ${UNIT_PASSED}/${UNIT_TOTAL} |
| E2E Tests | ${E2E_PASSED:-N/A}/${E2E_TOTAL:-N/A} |

**Issues Created/Updated**: $TOTAL_FAILURES

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

1. **Console output** with test results summary
2. **Markdown report** saved to configured report directory
3. **GitHub issues** created/updated for each test failure

## Integration with /fix-github

This command is automatically invoked by `/fix-github` when no priority bug issues exist. After running:

- If failures are found → Issues are created → `/fix-github` picks them up
- If all pass → `/fix-github` moves to enhancement phase

You can also run this command standalone to check project health.

---

🤖 **Ready to run full regression test suite.**
