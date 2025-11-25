# Start Autonomous Fix of GitHub Issues

Analyze all open GitHub issues, prioritize them, and begin systematically fixing or implementing them starting with the highest priority.

## What This Does

1. Creates priority labels (P0, P1, P2, P3) if they don't exist
2. Fetches all open GitHub issues with priority labels
3. Identifies the highest priority issue (P0 > P1 > P2 > P3)
4. Displays the issue details and prompt for you to fix
5. **For simple issues**: Directly troubleshoot and fix
6. **For complex issues**: Use superpowers skills to plan and execute
7. After fixing, moves to the next issue
8. Continues until all issues are resolved
9. **If there are no priority issues**: Run full regression test suite
10. Analyze regression test results and create GitHub issues for failures
11. Propose improvements (test coverage, robustness, simplicity)

Never stop, just keep looking for issues to address.

**Note**: This command uses GitHub labels (P0, P1, P2, P3) exclusively for priority detection. Issues without priority labels will not be processed by this workflow.

## Issue Complexity Detection

**Simple Issues** (direct fix):
- Single file changes
- Configuration tweaks
- Small bug fixes
- UI visibility issues
- Test timeout adjustments
- Removing deprecated code

**Complex Issues** (use superpowers):
- Multiple failing tests (>10 failures)
- Feature implementations
- Architecture changes
- Multi-file refactoring
- New functionality requiring design
- System integration issues

## Instructions

Start working on GitHub issues now:

```bash
# Load project-specific configuration from CLAUDE.md
if [ -f "CLAUDE.md" ]; then
  echo "📋 Reading project configuration from CLAUDE.md"

  # Check if autofix configuration exists
  if ! grep -q "## Automated Testing & Issue Management" CLAUDE.md; then
    echo "⚠️  No autofix configuration found in CLAUDE.md"
    echo "📝 Adding autofix configuration section to CLAUDE.md..."

    # Append autofix configuration to CLAUDE.md
    cat >> CLAUDE.md << 'AUTOFIX_CONFIG'

## Automated Testing & Issue Management

This section configures the `/fix-github` command for autonomous issue resolution.

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
else
  echo "⚠️  No CLAUDE.md found in project, using defaults"
  TEST_COMMAND="npm test"
  BUILD_COMMAND="npm run build"
fi

# Ensure priority labels exist (create only if missing)
for label in "P0:Critical priority issue:d73a4a" "P1:High priority issue:ff9800" "P2:Medium priority issue:ffeb3b" "P3:Low priority issue:4caf50"; do
  IFS=':' read -r name desc color <<< "$label"
  if ! gh label list --json name --jq '.[].name' | grep -qx "$name"; then
    echo "Creating label: $name"
    gh label create "$name" --description "$desc" --color "$color"
  fi
done

# Get highest priority issue (using labels only)
gh issue list --state open --json number,title,body,labels --limit 100 > /tmp/all-issues.json

cat /tmp/all-issues.json | jq -r '
  .[] |
  select(
    (.labels | map(.name) | any(. == "P0" or . == "P1" or . == "P2" or . == "P3"))
  ) |
  {
    number: .number,
    title: .title,
    body: (.body // ""),
    priority: (
      if (.labels | map(.name) | any(. == "P0")) then 0
      elif (.labels | map(.name) | any(. == "P1")) then 1
      elif (.labels | map(.name) | any(. == "P2")) then 2
      elif (.labels | map(.name) | any(. == "P3")) then 3
      else 4
      end
    )
  }
' | jq -s 'sort_by(.priority) | .[0]' > /tmp/top-issue.json

# Display the top issue
ISSUE_NUM=$(cat /tmp/top-issue.json | jq -r '.number')
ISSUE_TITLE=$(cat /tmp/top-issue.json | jq -r '.title')
ISSUE_BODY=$(cat /tmp/top-issue.json | jq -r '.body')
ISSUE_PRIORITY=$(cat /tmp/top-issue.json | jq -r '.priority')

echo ""
echo "🎯 Highest Priority Issue to Fix"
echo "════════════════════════════════════════"
echo "Issue: #$ISSUE_NUM"
echo "Priority: P$ISSUE_PRIORITY"
echo "Title: $ISSUE_TITLE"
echo ""
echo "Description:"
echo "$ISSUE_BODY" | head -20
echo ""
echo "════════════════════════════════════════"
echo ""
echo "📋 Starting work on issue #$ISSUE_NUM..."
echo ""

# Create fix branch
git checkout -b "fix/issue-${ISSUE_NUM}-auto" 2>/dev/null || git checkout "fix/issue-${ISSUE_NUM}-auto"

# Post comment that work started
gh issue comment "$ISSUE_NUM" --body "🤖 **Automated Fix Started**

Starting automated fix for this issue.

**Branch**: \`fix/issue-${ISSUE_NUM}-auto\`
**Started**: $(date)

Fix in progress..." 2>/dev/null || true

echo "✅ Created branch: fix/issue-${ISSUE_NUM}-auto"
echo "✅ Posted GitHub comment"
echo ""
```

## Fixing Strategy

### Step 1: Assess Complexity

Analyze the issue and determine if it's simple or complex:

**Simple Issue Indicators**:
- Description < 500 chars
- Single component/file mentioned
- Clear, specific fix described
- No test failures OR < 5 test failures
- Keywords: "hide", "timeout", "remove", "add field", "typo"

**Complex Issue Indicators**:
- Description > 1000 chars
- Multiple failing tests (>10)
- Multiple components involved
- Requires design/architecture
- Keywords: "implement", "system", "management", "integration", "~30 failures"

### Step 2A: Simple Issue - Direct Fix

For simple issues, proceed directly:

1. Read relevant code files to understand the root cause
2. Implement a complete fix (not partial)
3. Run targeted tests to verify the fix works
4. Create a git commit with the changes
5. Mark as complete

```bash
# After fixing simple issue:
git add -A
git commit -m "Fix #${ISSUE_NUM}: Brief description

Detailed explanation of what was fixed and how.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>"

# Merge to main
git checkout main
git merge "fix/issue-${ISSUE_NUM}-auto" --no-edit
git branch -d "fix/issue-${ISSUE_NUM}-auto"

# Close issue
gh issue close "$ISSUE_NUM" --comment "✅ **Issue Resolved**

[Detailed explanation of fix]

**Branch**: \`fix/issue-${ISSUE_NUM}-auto\` (merged and deleted)

🤖 Auto-resolved by autonomous fix workflow"
```

### Step 2B: Complex Issue - Use Superpowers

For complex issues requiring design and planning:

**1. Systematic Debugging (if bugs)**

If the issue involves bugs or test failures, use the systematic-debugging skill:

```
Use Skill tool: superpowers:systematic-debugging
```

This will:
- Investigate root cause thoroughly
- Analyze patterns across failures
- Test hypotheses before implementing
- Ensure understanding before solutions

**2. Brainstorming (if new features)**

If the issue requires new feature design:

```
Use Skill tool: superpowers:brainstorming
```

This will:
- Explore design alternatives
- Clarify requirements through questions
- Validate assumptions
- Refine rough ideas into concrete designs

**3. Writing Plans (for implementation)**

After design is complete, create implementation plan:

```
Use Skill tool: superpowers:writing-plans
```

This will:
- Break down into bite-sized tasks
- Specify exact file paths and changes
- Include verification steps
- Assume zero prior codebase knowledge

**4. Executing Plans**

Execute the plan in controlled batches:

```
Use Skill tool: superpowers:executing-plans
```

This will:
- Load and review the plan critically
- Execute tasks in batches
- Report progress for review between batches
- Track completion systematically

**5. Verification**

Before claiming complete, verify the fix:

```
Use Skill tool: superpowers:verification-before-completion
```

This will:
- Run verification commands
- Confirm output shows success
- Provide evidence before assertions
- Ensure tests pass before committing

### Step 3: Commit and Close

After verification passes:

```bash
# Commit changes
git add -A
git commit -m "Fix #${ISSUE_NUM}: Brief description

Detailed multi-line explanation of:
- Root cause analysis
- Solution approach
- Changes made
- Verification results

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>"

# Merge to main
git checkout main
git merge "fix/issue-${ISSUE_NUM}-auto" --no-edit
git branch -d "fix/issue-${ISSUE_NUM}-auto"

# Close issue with detailed explanation
gh issue close "$ISSUE_NUM" --comment "✅ **Issue Resolved**

## Root Cause
[Detailed analysis]

## Solution
[Approach taken]

## Changes Made
[List of changes]

## Verification
[Test results and evidence]

**Branch**: \`fix/issue-${ISSUE_NUM}-auto\` (merged and deleted)
**Commit**: [commit hash]

🤖 Auto-resolved by autonomous fix workflow with superpowers"
```

## Example Workflow

### Simple Issue Example:
```
Issue #240: TypeScript compilation errors in disabled-features
→ Direct fix: Delete broken test files
→ Verify: $BUILD_COMMAND (from CLAUDE-AUTOFIX-CONFIG.md)
→ Commit and close
```

### Complex Issue Example:
```
Issue #222: Review Management system broken (~30 test failures)
→ Complexity detected: >30 failures, multiple components
→ Use superpowers:systematic-debugging
  - Investigate root cause
  - Analyze test failure patterns
  - Identify common issues
→ Use superpowers:brainstorming
  - Design fix approach
  - Validate assumptions
→ Use superpowers:writing-plans
  - Create implementation plan
  - Break into tasks
→ Use superpowers:executing-plans
  - Execute in batches
  - Review between batches
→ Use superpowers:verification-before-completion
  - Run all tests
  - Confirm passing
→ Commit and close with evidence
```

## Skip Criteria

Skip to next issue if:
- Issue requires external dependencies (API keys, services)
- Issue is blocked by another issue
- Issue requires user input/decision
- Issue is too large even for superpowers (>100 test failures, major architecture change)

Post a comment explaining why skipped:

```bash
gh issue comment "$ISSUE_NUM" --body "⏭️ **Skipped for Manual Review**

This issue requires [reason] and cannot be automatically resolved.

**Recommendation**: [Suggested approach]

Moving to next priority issue.

🤖 Autonomous fix workflow"
```

## No Priority Issues Found

If no issues with P0-P3 labels exist, run full regression testing:

### Step 1: Run Regression Test Suite

```bash
# Run complete regression test suite (uses command from CLAUDE-AUTOFIX-CONFIG.md)
$TEST_COMMAND

# This command is configured in the project's CLAUDE-AUTOFIX-CONFIG.md
# It should run all tests and generate a report with GitHub issue integration
```

### Step 2: Analyze Regression Results

The regression test suite automatically:
- Creates GitHub issues for new test failures
- Updates existing issues with regression data
- Applies priority labels (P0-P3) based on severity

**Priority Assignment**:
- **P0 - Critical**: Auth, security, crashes, data loss
- **P1 - High**: Major features broken, CRUD operations failing
- **P2 - Medium**: Filtering, sorting, search, display issues
- **P3 - Low**: UI issues, validation, edge cases

### Step 3: Review Generated Issues

Check newly created issues:

```bash
# View issues created by regression test
gh issue list --label "test-failure" --state open --json number,title,labels --limit 20
```

### Step 4: Restart /fix-github Workflow

After regression testing creates new issues, restart the workflow:

```bash
# Refresh issue list and continue
/fix-github
```

The workflow will now pick up the newly created issues and begin fixing them.

### Step 5: If All Tests Pass

If regression tests pass completely (no issues created):

**Propose Improvements**:

1. **Test Coverage Analysis**
   - Identify untested code paths
   - Add missing E2E scenarios
   - Improve edge case coverage

2. **Code Quality Improvements**
   - Refactor complex functions
   - Reduce code duplication
   - Improve type safety

3. **Performance Optimizations**
   - Identify slow queries
   - Add caching where needed
   - Optimize bundle size

4. **Documentation Updates**
   - Update API docs
   - Add code examples
   - Document best practices

**Create Improvement Issues**:

```bash
# Create issues for proposed improvements
gh issue create \
  --label "enhancement,proposed" \
  --title "P3-Improvement: [Brief description]" \
  --body "## Proposed Improvement

[Detailed description]

## Rationale
[Why this improvement is valuable]

## Implementation
[How to implement]

## Impact
[Expected benefits]

🤖 Proposed by autonomous improvement workflow"
```

---

🤖 **Ready to fix issue #$ISSUE_NUM! Start working on it now.**

**Remember**:
- Simple issues: Fix directly
- Complex issues: Use superpowers skills
- No issues: Run regression tests
- All passing: Propose improvements
- Always verify before claiming complete
- Provide evidence in GitHub comments
- Never stop improving the codebase!
