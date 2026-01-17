---
description: Autonomous GitHub issue resolution
---

# Start Autonomous Fix of GitHub Issues

Analyze all open GitHub issues, prioritize them, and begin systematically fixing or implementing them starting with the highest priority.

## Usage

```bash
# Automatic priority-based selection (processes all issues in priority order)
/fix-github

# Target a specific issue directly (skips priority selection)
/fix-github 223
```

**With issue number**: Skips the priority selection process and immediately starts working on the specified issue, regardless of its priority label.

**Without issue number**: Fetches all open issues with priority labels (P0-P3) and processes them in priority order.

## What This Does

### Bug Fixing Phase (Priority)

1. Creates priority labels (P0, P1, P2, P3) if they don't exist
2. Fetches all open GitHub issues with priority labels
3. Identifies the highest priority issue (P0 > P1 > P2 > P3)
4. **For simple issues**: Directly troubleshoot and fix
5. **For complex issues**: Use superpowers skills to plan and execute
6. After fixing, moves to the next issue
7. Continues until all bug issues are resolved

### Regression Testing Phase

8. **When no priority bugs exist**: Run full regression test suite
2. Analyze regression test results and create GitHub issues for failures
3. Loop back to bug fixing if new issues are created

### Enhancement Phase (when no bugs)

11. Check for existing enhancement issues
2. **If enhancements exist**: Use superpowers to design, plan, and implement each one
3. Run tests after implementation
4. **If tests pass**: Commit, merge, and close enhancement
5. **If tests fail**: Create bug issues for failures, pause enhancement, fix bugs first
6. Repeat until all existing enhancements are implemented

### Propose New Enhancements (lowest priority)

17. **Only when no bugs AND no existing enhancements**: Propose new improvements
2. Use superpowers:brainstorming to identify valuable enhancements
3. Create enhancement issue with detailed implementation plan
4. Loop back to Enhancement Phase to implement

Never stop, just keep looking for issues to address. Priority: Triage Unprioritized > Bugs > Existing Enhancements > Proposing New Enhancements.

**Note**: This command automatically reviews and prioritizes any open issues that lack priority labels (P0-P3) before processing the issue queue.

## Unprioritized Issue Triage

When unprioritized issues are detected, review each one and assign an appropriate priority label before continuing with the fix workflow.

### Triage Process

For each unprioritized issue:

1. **Read the issue** - Understand the title, description, and any labels
2. **Assess severity and impact**:
   - **P0 (Critical)**: System down, data loss, security vulnerability, blocks all users
   - **P1 (High)**: Major feature broken, significant user impact, no workaround
   - **P2 (Medium)**: Feature partially broken, workaround exists, moderate impact
   - **P3 (Low)**: Minor issue, cosmetic, nice-to-have, minimal user impact
3. **Assign the priority label**:

```bash
# Assign priority to an issue
gh issue edit <ISSUE_NUMBER> --add-label "P2"  # Use appropriate priority
```

1. **Add a triage comment** explaining the priority decision:

```bash
gh issue comment <ISSUE_NUMBER> --body "🏷️ **Triage Complete**

**Priority Assigned**: P2 (Medium)

**Rationale**: [Brief explanation of why this priority was chosen]

🤖 Triaged by autonomous fix workflow"
```

### Triage Decision Matrix

| Indicator | P0 | P1 | P2 | P3 |
|-----------|----|----|----|----|
| Production impact | Critical/Down | Major degradation | Partial impact | Minimal |
| User scope | All users | Many users | Some users | Few users |
| Workaround | None | Difficult | Available | Easy |
| Data risk | Loss/corruption | Possible | Unlikely | None |
| Security | Active exploit | Vulnerability | Potential | None |
| Keywords | "crash", "down", "urgent", "security" | "broken", "fails", "blocking" | "issue", "bug", "incorrect" | "minor", "cosmetic", "enhancement" |

### Triage Instructions

When `UNPRIORITIZED_ISSUES_FOUND=true` is detected:

1. Parse the `UNPRIORITIZED_DATA` to get issue numbers, titles, and descriptions
2. For each issue, use the decision matrix to determine priority
3. Assign the label and post a triage comment
4. Continue to the main fix workflow after all issues are triaged

**Model Selection for Triage**: Use **Haiku** for straightforward triage decisions, escalate to **Sonnet** if the issue description is ambiguous or requires deeper analysis.

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

## Model Selection (Opus 4.5)

When spawning agents or using the Task tool during issue resolution, select the model based on task complexity:

### Issue Complexity → Model Mapping

| Issue Type | Model | Rationale |
|------------|-------|-----------|
| Simple (P2/P3, clear fix) | Sonnet | Known patterns, documented solutions |
| Complex (P0/P1, architectural) | Opus | Deep analysis, trade-off decisions |
| Regression test analysis | Sonnet | Standard test interpretation |
| Root cause investigation | Opus | Multi-factor analysis |
| Improvement proposals | Opus | Creative problem-solving |
| Labeling & formatting | Haiku | Mechanical operations |

### Escalation Triggers

**Start with Sonnet, escalate to Opus when:**

- Fix attempt fails after 2 tries with same approach
- Issue involves 5+ files requiring coordinated changes
- Root cause is unclear after initial investigation
- Multiple test failures share non-obvious common cause
- Issue requires architectural decision (new patterns, dependencies)

**Stay with Sonnet when:**

- Error messages clearly indicate the fix
- Issue matches known patterns from previous fixes
- Single file change with isolated impact
- Test failures have obvious cause (typo, missing import)

**Drop to Haiku for:**

- Adding/updating priority labels
- Posting status comments to GitHub
- Formatting commit messages
- Simple file cleanup (delete, rename)

### Model Usage by Workflow Phase

| Phase | Recommended Model |
|-------|-------------------|
| Initial complexity assessment | Sonnet |
| Simple issue: direct fix | Sonnet |
| Complex issue: systematic-debugging skill | Opus |
| Complex issue: brainstorming skill | Opus |
| Complex issue: writing-plans skill | Opus |
| Complex issue: executing-plans skill | Sonnet |
| Verification before completion | Sonnet |
| Regression test execution | Sonnet |
| Regression test analysis | Sonnet → Opus if patterns unclear |
| Improvement proposals | Opus |
| Issue creation from failures | Haiku |

### Example Task Tool Usage

```javascript
// Initial assessment - start with Sonnet
Task("analyst", "Assess complexity of issue #${ISSUE_NUM}...", model="sonnet")

// Complex root cause - use Opus
Task("debugger", "Investigate why 15 tests fail with timeout...", model="opus")

// Standard fix - use Sonnet
Task("coder", "Update package.json to fix dependency conflict...", model="sonnet")

// Label management - use Haiku
Task("labeler", "Add P2 label to issue #${ISSUE_NUM}...", model="haiku")
```

## Context Management (CRITICAL)

**Before starting work on ANY new issue, run `/compact` to compress conversation history.** This prevents context overflow when working through multiple issues in a loop.

Each issue should start with a fresh, compacted context. Never carry over detailed investigation notes from a previous issue - the compact summary is sufficient.

## Instructions

Start working on GitHub issues now:

```bash
# Load project-specific configuration from CLAUDE.md
if [ -f "CLAUDE.md" ]; then
  echo "📋 Reading project configuration from CLAUDE.md"

  # Check if autocoder configuration exists
  if ! grep -q "## Automated Testing & Issue Management" CLAUDE.md; then
    echo "⚠️  No autocoder configuration found in CLAUDE.md"
    echo "📝 Adding autocoder configuration section to CLAUDE.md..."

    # Append autocoder configuration to CLAUDE.md
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
else
  echo "⚠️  No CLAUDE.md found in project, using defaults"
  TEST_COMMAND="npm test"
  BUILD_COMMAND="npm run build"
fi

# Ensure priority labels exist (one-time setup per project)

if [ ! -f ".github/.priority-labels-configured" ]; then
  echo "🏷️  Checking priority labels (one-time setup)..."
  EXISTING_LABELS=$(gh label list --json name --jq '.[].name' 2>/dev/null || echo "")

  for label in "P0:Critical priority issue:d73a4a" "P1:High priority issue:ff9800" "P2:Medium priority issue:ffeb3b" "P3:Low priority issue:4caf50" "proposal:AI-generated proposal awaiting human approval:c5def5"; do
    IFS=':' read -r name desc color <<< "$label"
    if ! echo "$EXISTING_LABELS" | grep -qFx "$name"; then
      echo "Creating label: $name"
      gh label create "$name" --description "$desc" --color "$color" 2>/dev/null || true
    fi
  done

# Mark labels as configured

  mkdir -p .github
  echo "# Priority labels configured on $(date -I)" > .github/.priority-labels-configured
  echo "✅ Priority labels configured"
fi

# Step 0: Review and prioritize any unprioritized issues

echo "🔍 Checking for unprioritized issues..."
gh issue list --state open --json number,title,body,labels --limit 100 > /tmp/all-open-issues.json

# Find issues without any priority label (P0-P3)

UNPRIORITIZED=$(cat /tmp/all-open-issues.json | python3 -c "
import json, sys
issues = json.load(sys.stdin)
unprioritized = [i for i in issues if not any(l['name'] in ['P0','P1','P2','P3'] for l in i.get('labels',[]))]
for issue in unprioritized:
    print(f\"{issue['number']}|{issue['title']}|{issue.get['body', ''](:500)}\")
")

if [ -n "$UNPRIORITIZED" ]; then
  UNPRIORITIZED_COUNT=$(echo "$UNPRIORITIZED" | grep -c "^" || echo "0")
  echo "⚠️  Found $UNPRIORITIZED_COUNT unprioritized issue(s). Reviewing and assigning priorities..."
  echo ""
  echo "UNPRIORITIZED_ISSUES_FOUND=true"
  echo "UNPRIORITIZED_DATA<<EOF"
  echo "$UNPRIORITIZED"
  echo "EOF"
else
  echo "✅ All open issues have priority labels assigned"
fi

# Check if a specific issue number was provided as argument

# Usage: /fix-github [issue_number]

SPECIFIED_ISSUE="${1:-}"

if [ -n "$SPECIFIED_ISSUE" ]; then

# Specific issue provided - fetch it directly

  echo "🎯 Targeting specific issue #$SPECIFIED_ISSUE"
  gh issue view "$SPECIFIED_ISSUE" --json number,title,body,labels > /tmp/top-issue.json 2>/dev/null

  if [ $? -ne 0 ] || [ ! -s /tmp/top-issue.json ]; then
    echo "❌ Error: Issue #$SPECIFIED_ISSUE not found or not accessible"
    exit 1
  fi

# Extract priority from labels (default to P2 if no priority label)

  ISSUE_PRIORITY=$(cat /tmp/top-issue.json | jq -r '
    if (.labels | map(.name) | any(. == "P0")) then 0
    elif (.labels | map(.name) | any(. == "P1")) then 1
    elif (.labels | map(.name) | any(. == "P2")) then 2
    elif (.labels | map(.name) | any(. == "P3")) then 3
    else 2
    end
  ')

  ISSUE_NUM=$(cat /tmp/top-issue.json | jq -r '.number')
  ISSUE_TITLE=$(cat /tmp/top-issue.json | jq -r '.title')
  ISSUE_BODY=$(cat /tmp/top-issue.json | jq -r '.body // ""')

  echo "✅ Found issue #$ISSUE_NUM: $ISSUE_TITLE"
else

# No specific issue - get highest priority issue (using labels only)

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
fi

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

### Simple Issue Example

```
Issue #240: TypeScript compilation errors in disabled-features
→ Direct fix: Delete broken test files
→ Verify: $BUILD_COMMAND (from CLAUDE-AUTOFIX-CONFIG.md)
→ Commit and close
```

### Complex Issue Example

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

### Step 1: Run Full Regression Test

Use the `/full-regression-test` command to run the complete test suite:

```
/full-regression-test
```

This command will:

- Load test configuration from CLAUDE.md
- Run build verification
- Run unit tests
- Run E2E tests (if configured)
- Analyze failures and assign priorities
- Create/update GitHub issues for each failure
- Generate a detailed report

### Step 2: Review Results

After `/full-regression-test` completes:

- **If failures found**: Issues are created with priority labels (P0-P3)
- **If all pass**: No new issues created

Check newly created issues:

```bash
# View issues created by regression test
gh issue list --label "test-failure" --state open --json number,title,labels --limit 20
```

### Step 3: Continue Workflow

After regression testing:

- **If issues were created** → Continue fixing (workflow picks them up automatically)
- **If all tests passed** → Move to Enhancement Phase (Step 5)

### Step 4: If All Tests Pass - Work on Enhancements

If regression tests pass completely (no new bug issues created), shift focus to **enhancements**.

#### 5A: Check for Approved Enhancement Issues

**IMPORTANT**: Only implement enhancements that have been **approved by a human** (i.e., do NOT have the `proposal` label). AI-generated proposals require human review before implementation.

```bash
# Check for open enhancement issues that are NOT proposals (approved for implementation)
gh issue list --state open --label "enhancement" --json number,title,body,labels --limit 50 > /tmp/all-enhancements.json

# Filter out proposals - only get approved enhancements
APPROVED_ENHANCEMENTS=$(cat /tmp/all-enhancements.json | python3 -c "
import json, sys
issues = json.load(sys.stdin)
approved = [i for i in issues if not any(l['name'] == 'proposal' for l in i.get('labels', []))]
print(json.dumps(approved))
")

ENHANCEMENT_COUNT=$(echo "$APPROVED_ENHANCEMENTS" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")

if [ "$ENHANCEMENT_COUNT" -gt 0 ]; then
  echo "🚀 Found $ENHANCEMENT_COUNT approved enhancement(s) to implement"
  # Get first approved enhancement
  ENHANCE_NUM=$(echo "$APPROVED_ENHANCEMENTS" | python3 -c "import json,sys; print(json.load(sys.stdin)[0]['number'])")
  ENHANCE_TITLE=$(echo "$APPROVED_ENHANCEMENTS" | python3 -c "import json,sys; print(json.load(sys.stdin)[0]['title'])")
  ENHANCE_BODY=$(echo "$APPROVED_ENHANCEMENTS" | python3 -c "import json,sys; print(json.load(sys.stdin)[0].get('body',''))")
  echo "📋 Working on approved enhancement #$ENHANCE_NUM: $ENHANCE_TITLE"
else
  # Check if there are pending proposals
  PROPOSAL_COUNT=$(cat /tmp/all-enhancements.json | python3 -c "
import json, sys
issues = json.load(sys.stdin)
proposals = [i for i in issues if any(l['name'] == 'proposal' for l in i.get('labels', []))]
print(len(proposals))
")

  if [ "$PROPOSAL_COUNT" -gt 0 ]; then
    echo "📋 Found $PROPOSAL_COUNT proposal(s) awaiting human approval"
    echo "💡 Use '/list-proposals' to review pending proposals"
    echo "✨ No approved enhancements to implement. Creating new proposals..."
  else
    echo "✨ No enhancements or proposals. Creating new proposals..."
  fi
  # Continue to Step 5B
fi
```

#### 5B: Propose New Enhancements (if none exist)

If no enhancement issues exist, analyze the codebase and propose improvements:

**First, check test coverage** using the persistent coverage report:

```bash
# Fast path: Read existing report if available
if [ -f "test-coverage.md" ]; then
  echo "📊 Reading test-coverage.md (fast path)"
  # Parse coverage from report header
  OVERALL_COV=$(grep "Overall Coverage" test-coverage.md | grep -oE '[0-9]+' | head -1)
  echo "Current coverage: ${OVERALL_COV}%"

  # Show lowest coverage areas from report
  echo ""
  echo "Areas needing coverage:"
  grep -E "<!-- COVERAGE: [0-9]+%" test-coverage.md | head -5
else
  # No report exists - run full analysis to create it
  echo "📊 No test-coverage.md found, running full analysis..."
  /improve-test-coverage --analyze
fi
```

If coverage is below 80%, use `/improve-test-coverage` to improve it (this uses the fast path when test-coverage.md exists).

**Then use superpowers:brainstorming** to identify other valuable enhancements:

```
Use Skill tool: superpowers:brainstorming
```

Focus areas for enhancement proposals:

1. **Test Coverage** - Use `/improve-test-coverage` to improve gaps (reads from test-coverage.md)
2. **Code Quality** - Complex functions to refactor, duplication to reduce
3. **Performance** - Slow queries, caching opportunities, bundle optimization
4. **Documentation** - API docs, code examples, best practices

**Create Enhancement Proposal** (tagged with `proposal` label for human review):

```bash
gh issue create \
  --label "enhancement,proposal,P3" \
  --title "Proposal: [Brief description]" \
  --body "$(cat <<'ENHANCEMENT_BODY'
## Proposed Enhancement

[Detailed description of what this enhancement accomplishes]

## Rationale

[Why this improvement is valuable - metrics, user impact, maintainability]

## Implementation Plan

### Phase 1: [First phase]
- [ ] Task 1.1
- [ ] Task 1.2

### Phase 2: [Second phase]
- [ ] Task 2.1
- [ ] Task 2.2

### Phase 3: Verification
- [ ] Run full test suite
- [ ] Manual verification of feature
- [ ] Update documentation

## Success Criteria

- [ ] All existing tests pass
- [ ] New tests added for enhancement
- [ ] Documentation updated
- [ ] No performance regression

## Estimated Complexity

[Simple | Medium | Complex]

---

## 📋 Proposal Status

**Status**: ⏳ Awaiting Human Approval

### How to Approve This Proposal

To approve and allow automated implementation:
```bash
gh issue edit <issue_number> --remove-label "proposal"
```

### How to Provide Feedback

Comment on this issue with your feedback. The AI will incorporate your suggestions when you run `/refine-proposal <issue_number>`.

### How to Reject This Proposal

```bash
gh issue close <issue_number> --comment "Rejected: [reason]"
```

---

🤖 Proposed by autonomous improvement workflow
ENHANCEMENT_BODY
)"

echo "✅ Created proposal issue. Awaiting human approval before implementation."
echo "💡 Use '/list-proposals' to view all pending proposals"

```

**IMPORTANT**: After creating a proposal, do NOT automatically implement it. The workflow should continue looking for other work (bugs, approved enhancements) or create additional proposals. Proposals require explicit human approval (removal of the `proposal` label) before implementation.

#### 5C: Implement Approved Enhancement Using Superpowers

**IMPORTANT**: Only implement enhancements that do NOT have the `proposal` label. If an enhancement has the `proposal` label, it is awaiting human approval and must NOT be implemented.

For each **approved** enhancement issue (no `proposal` label), follow this workflow:

**Step 1: Create Feature Branch**

```bash
git checkout -b "enhancement/issue-${ENHANCE_NUM}-auto" 2>/dev/null || git checkout "enhancement/issue-${ENHANCE_NUM}-auto"

gh issue comment "$ENHANCE_NUM" --body "🚀 **Enhancement Implementation Started**

Starting automated implementation of this enhancement.

**Branch**: \`enhancement/issue-${ENHANCE_NUM}-auto\`
**Started**: $(date)

Implementation in progress..."
```

**Step 2: Design Solution with Brainstorming**

```
Use Skill tool: superpowers:brainstorming
```

This will:

- Explore design alternatives
- Clarify requirements
- Validate assumptions
- Refine into concrete design

**Step 3: Create Detailed Implementation Plan**

```
Use Skill tool: superpowers:writing-plans
```

This will:

- Break down into bite-sized tasks
- Specify exact file paths and changes
- Include verification steps
- Assume zero prior codebase knowledge

**Update the GitHub issue** with the implementation plan:

```bash
gh issue comment "$ENHANCE_NUM" --body "📋 **Implementation Plan Created**

## Detailed Implementation Plan

[Paste the implementation plan created by superpowers:writing-plans]

Beginning execution..."
```

**Step 4: Execute the Plan**

```
Use Skill tool: superpowers:executing-plans
```

This will:

- Load and review the plan critically
- Execute tasks in batches
- Report progress for review between batches
- Track completion systematically

**Step 5: Run Tests and Verify**

```bash
# Run full test suite
$TEST_COMMAND

# Capture test results
TEST_EXIT_CODE=$?
TEST_OUTPUT=$(cat /tmp/test-output.txt 2>/dev/null || echo "Test output not captured")
```

#### 5D: Handle Test Results

**If Tests Pass**:

```bash
if [ $TEST_EXIT_CODE -eq 0 ]; then
  echo "✅ All tests pass!"

  # Use verification skill before claiming complete
  # Use Skill tool: superpowers:verification-before-completion

  # Commit changes
  git add -A
  git commit -m "Implement enhancement #${ENHANCE_NUM}: ${ENHANCE_TITLE}

Detailed explanation of:
- What was implemented
- Design decisions made
- Tests added/modified

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>"

  # Merge to main
  git checkout main
  git merge "enhancement/issue-${ENHANCE_NUM}-auto" --no-edit
  git branch -d "enhancement/issue-${ENHANCE_NUM}-auto"

  # Close enhancement with details
  gh issue close "$ENHANCE_NUM" --comment "✅ **Enhancement Implemented**

## Summary
[What was implemented]

## Changes Made
[List of changes]

## Tests
- All existing tests pass
- New tests added: [list new tests]

## Verification
[Evidence that enhancement works correctly]

**Branch**: \`enhancement/issue-${ENHANCE_NUM}-auto\` (merged and deleted)

🤖 Auto-implemented by autonomous enhancement workflow"
fi
```

**If Tests Fail - Create Bug Issues**:

```bash
if [ $TEST_EXIT_CODE -ne 0 ]; then
  echo "❌ Tests failed during enhancement implementation"

  # Parse test failures and create issues for each
  # Extract failing test names and create individual issues

  gh issue create \
    --label "bug,test-failure,P1" \
    --title "Test failure during enhancement #${ENHANCE_NUM}: [Test name]" \
    --body "$(cat <<FAILURE_BODY
## Test Failure

**Related Enhancement**: #${ENHANCE_NUM}
**Branch**: \`enhancement/issue-${ENHANCE_NUM}-auto\`

## Failing Test
\`\`\`
[Test name and location]
\`\`\`

## Error Output
\`\`\`
${TEST_OUTPUT}
\`\`\`

## Context
This test failure occurred while implementing enhancement #${ENHANCE_NUM}.

## Suggested Investigation
1. Check if enhancement changes broke existing functionality
2. Verify test expectations are still valid
3. Check for missing dependencies or setup

🤖 Created by autonomous enhancement workflow
FAILURE_BODY
)"

  # Comment on enhancement issue about the failure
  gh issue comment "$ENHANCE_NUM" --body "⚠️ **Implementation Blocked by Test Failures**

Test failures occurred during implementation. Bug issues have been created:
- [List created bug issue numbers]

Enhancement implementation paused. Will resume after bugs are fixed.

🤖 Autonomous enhancement workflow"

  # Do NOT merge - leave branch for investigation
  echo "⚠️ Enhancement branch preserved for investigation: enhancement/issue-${ENHANCE_NUM}-auto"

  # Switch back to main
  git checkout main
fi
```

#### 5E: Enhancement Skip Criteria

Skip an enhancement and move to the next if:

- Enhancement requires external services not available
- Enhancement scope is too large (>50 files affected)
- Enhancement has unresolved dependencies on other issues
- Enhancement requires user decisions not documented

```bash
gh issue comment "$ENHANCE_NUM" --body "⏭️ **Enhancement Skipped**

This enhancement cannot be automatically implemented because:
[Reason]

**Recommendation**: [What manual steps are needed]

Moving to next enhancement or proposing new improvements.

🤖 Autonomous enhancement workflow"

# Add 'needs-review' label
gh issue edit "$ENHANCE_NUM" --add-label "needs-review"
```

---

## MANDATORY: Continuous Loop

**THIS WORKFLOW RUNS FOREVER UNTIL MANUALLY STOPPED.**

### Context Compaction (CRITICAL)

**Run `/compact` BEFORE starting each new issue.** This compresses conversation history and prevents context overflow when working through multiple issues.

After completing ANY of these actions, you MUST immediately continue:

1. **After triaging unprioritized issues** → Fetch next priority issue
2. **After fixing and closing a bug issue** → Fetch next priority issue
3. **After skipping an issue** → Fetch next priority issue
4. **After running regression tests** → Check for new issues created
5. **After implementing an approved enhancement** → Check for more approved enhancements or bugs
6. **After test failures during enhancement** → Process created bug issues first
7. **After creating a proposal** → Continue generating more proposals if useful ideas remain
8. **If truly idle** → Output `IDLE_NO_WORK_AVAILABLE` to trigger sleep cycle

### Priority Order

The workflow follows this strict priority order:

1. **Triage Unprioritized Issues** (assign P0-P3 labels first)
2. **P0-P3 Bug Issues** (fix bugs first)
3. **Regression Test Failures** (creates new bug issues)
4. **Approved Enhancement Issues** (only enhancements WITHOUT the `proposal` label)
5. **Create New Proposals** (lowest priority - only when no bugs AND no approved enhancements)

**⚠️ NEVER automatically implement proposals.** Proposals (issues with `proposal` label) require human approval before implementation.

### Loop Implementation

After every issue is resolved, skipped, or when checking for work:

```bash
# Fetch all open issues
gh issue list --state open --json number,title,body,labels --limit 100 > /tmp/all-issues.json

# Count priority bug issues (P0-P3, excluding proposals)
PRIORITY_ISSUES=$(cat /tmp/all-issues.json | python3 -c "
import json, sys
issues = json.load(sys.stdin)
priority = [i for i in issues
            if any(l['name'] in ['P0','P1','P2','P3'] for l in i.get('labels',[]))
            and not any(l['name'] == 'proposal' for l in i.get('labels',[]))]
print(len(priority))
")

# Count APPROVED enhancement issues (enhancement label but NOT proposal label)
APPROVED_ENHANCEMENTS=$(cat /tmp/all-issues.json | python3 -c "
import json, sys
issues = json.load(sys.stdin)
approved = [i for i in issues
            if any(l['name'] == 'enhancement' for l in i.get('labels',[]))
            and not any(l['name'] == 'proposal' for l in i.get('labels',[]))]
print(len(approved))
")

# Count pending proposals
PENDING_PROPOSALS=$(cat /tmp/all-issues.json | python3 -c "
import json, sys
issues = json.load(sys.stdin)
proposals = [i for i in issues if any(l['name'] == 'proposal' for l in i.get('labels',[]))]
print(len(proposals))
")

if [ "$PRIORITY_ISSUES" -gt 0 ]; then
  echo "🐛 Found $PRIORITY_ISSUES priority bug(s). Fixing bugs first..."
  # Process next bug issue (repeat from "Get highest priority issue" section)
elif [ "$APPROVED_ENHANCEMENTS" -gt 0 ]; then
  echo "🚀 No bugs! Found $APPROVED_ENHANCEMENTS approved enhancement(s). Implementing..."
  # Process next approved enhancement (Step 5C)
else
  echo "✨ No bugs or approved enhancements. Checking for useful proposals to create..."
  # Run /full-regression-test first if not recently run
  # Then brainstorm proposals using superpowers:brainstorming
  # Create proposals for genuinely useful improvements
  # If nothing useful to propose → Output IDLE signal for sleep cycle
fi
```

### Never Stop

- **DO NOT** wait for user input between issues
- **DO NOT** stop after fixing one issue
- **DO NOT** ask "should I continue?"
- **DO NOT** implement issues with the `proposal` label (they require human approval)
- **DO** triage unprioritized issues first
- **DO** keep processing bug issues until the queue is empty
- **DO** run `/full-regression-test` when bug queue is empty
- **DO** process any new bug issues created by `/full-regression-test`
- **DO** work on **approved** enhancements only when no bugs exist
- **DO** keep generating proposals until you genuinely have no useful ideas
- **DO** create bug issues for any test failures during enhancement work
- **DO** loop back to bug fixing if enhancement work creates failures

### Idle State

When truly idle (no bugs, no approved enhancements, no useful proposals to create, tests passing), output:

```
IDLE_NO_WORK_AVAILABLE
```

This signals the stop hook to sleep (default 60 minutes) before checking again for:

- New human-created issues
- Comments on existing issues
- Approved proposals ready for implementation

**The only way this workflow stops is if the user manually interrupts it.**

---

## Proposal Management

### What is a Proposal?

A **proposal** is an AI-generated enhancement suggestion that requires human review before implementation. Proposals are tagged with the `proposal` label and will NOT be automatically implemented.

### How to Review Proposals

Use the `/list-proposals` command to see all pending proposals:

```bash
/list-proposals
```

### How to Approve a Proposal

To approve a proposal for automated implementation, remove the `proposal` label:

```bash
gh issue edit <issue_number> --remove-label "proposal"
```

Once the `proposal` label is removed, the `/fix-github` workflow will automatically implement the enhancement on its next iteration.

### How to Provide Feedback on a Proposal

1. **Comment on the issue** with your feedback, questions, or requested changes
2. Run `/refine-proposal <issue_number>` to have the AI incorporate your feedback
3. Review the updated proposal
4. Approve or provide additional feedback

### How to Reject a Proposal

```bash
gh issue close <issue_number> --comment "Rejected: [reason for rejection]"
```

### Proposal Labels

| Label | Meaning |
|-------|---------|
| `proposal` | AI-generated, awaiting human approval |
| `enhancement` | Describes a feature improvement |
| `P0`-`P3` | Priority level (assigned during triage) |

**Note**: An issue can have both `proposal` and `enhancement` labels. The `proposal` label is what prevents automatic implementation.

---

🤖 **Ready to fix issue #$ISSUE_NUM! Start working on it now, then IMMEDIATELY continue to the next issue.**
