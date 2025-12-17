# Regression Testing Workflow

**Purpose**: Execute comprehensive test suite and analyze failures

## Process

### 1. Test Configuration Loading
Read `CLAUDE.md` for project-specific settings:
- Unit test commands and directories
- E2E test commands and patterns
- Build verification commands
- Coverage report locations

### 2. Test Execution Sequence

#### A. Build Verification
```bash
# Run build command from CLAUDE.md or default
npm run build  # or configured command
```

#### B. Unit Tests
```bash
# Run from configured directory
cd {unit-test-dir}
npm test  # or configured command
```

#### C. E2E Tests
```bash
# Run with configured reporter
npx playwright test --reporter=json
```

### 3. Result Analysis

#### A. Parse Test Results
- Extract pass/fail counts from unit tests
- Parse JSON output from E2E tests
- Identify syntax errors and runtime failures

#### B. Failure Categorization
For each failure:
- Extract test file and description
- Determine failure type (syntax, logic, integration)
- Assign priority based on impact

### 4. GitHub Issue Creation

#### A. Priority Assignment
```python
def determine_priority(test_file, test_desc):
    if "auth|security|crash|data loss" in test_desc.lower():
        return "P0"
    elif "create|delete|update|crud|save" in test_desc.lower():
        return "P1"
    elif "filter|sort|search|display|show" in test_desc.lower():
        return "P2"
    else:
        return "P3"
```

#### B. Issue Creation
```bash
gh issue create \
  --title "{PRIORITY}-{test_desc:0:80}" \
  --body "## Test Failure
**Test File**: `{test_file}`
**Test Description**: {test_desc}
**Priority**: {PRIORITY}
**Detected**: {timestamp}

This test failure was detected during automated regression testing.

**Test Report**: See `{report_file}`
**Next Steps**:
1. Reproduce the failure locally
2. Identify root cause
3. Implement fix
4. Verify with test command" \
  --label "bug,automated-test-failure,{PRIORITY}"
```

### 5. Report Generation

Create detailed markdown report:
```markdown
# Regression Test Report
**Date**: {timestamp}
**Timestamp**: {run_id}

## Test Summary
### Unit Tests
- **Status**: {PASSED/FAILED}
- **Total**: {total}
- **Passed**: {passed}
- **Failed**: {failed}

### E2E Tests
- **Status**: {PASSED/FAILED}
- **Total**: {total}
- **Passed**: {passed}
- **Failed**: {failed}
- **Skipped**: {skipped}

## Test Failures
{detailed_failure_analysis}
```

### 6. Status Determination
- **Success**: All tests pass → proceed to enhancement phase
- **Failure**: Any test fails → return to bug fixing phase

## Configuration Defaults

If `CLAUDE.md` not found or incomplete:
- Unit tests: `npm test` in current directory
- E2E tests: `npx playwright test --reporter=json`
- Build: `npm run build`
- Test pattern: `*.spec.ts`
- Report directory: `docs/test/regression-reports`