# Start Autonomous Fix of GitHub Issues

Analyze all open GitHub issues, prioritize them, and begin systematically fixing or implementing them starting with the highest priority.

## Usage

```bash
# Automatic priority-based selection (processes all issues in priority order)
/fix

# Target a specific issue directly (skips priority selection)
/fix 223
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
9. Analyze regression test results and create GitHub issues for failures
10. Loop back to bug fixing if new issues are created

### Enhancement Phase (when no bugs)
11. Check for existing enhancement issues
12. **If enhancements exist**: Use superpowers to design, plan, and implement each one
13. Run tests after implementation
14. **If tests pass**: Commit, merge, and close enhancement
15. **If tests fail**: Create bug issues for failures, pause enhancement, fix bugs first
16. Repeat until all existing enhancements are implemented

### Propose New Enhancements (lowest priority)
17. **Only when no bugs AND no existing enhancements**: Propose new improvements
18. Use superpowers:brainstorming to identify valuable enhancements
19. Create enhancement issue with detailed implementation plan
20. Loop back to Enhancement Phase to implement

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

4. **Add a triage comment** explaining the priority decision:

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

**Complex Issues** (use superpowers if available):
- Multiple failing tests (>10 failures)
- Feature implementations
- Architecture changes
- Multi-file refactoring
- New functionality requiring design
- System integration issues

**Ultra-Complex Issues** (use quint if available):
- Major architecture decisions with significant trade-offs
- Issues requiring human judgment on business/product direction
- Problems too large for autonomous resolution (>100 test failures)
- Cross-cutting concerns affecting multiple systems
- Decisions with irreversible consequences
- When superpowers approaches have failed twice

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

This section configures the `/fix` command for autonomous issue resolution.

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

# Detect available plugins for enhanced capabilities
echo "🔌 Detecting available plugins..."

# Check for superpowers plugin (structured problem-solving skills)
SUPERPOWERS_AVAILABLE=false
if claude plugins list 2>/dev/null | grep -q "superpowers"; then
  SUPERPOWERS_AVAILABLE=true
  echo "✅ superpowers plugin detected - will use for complex issues"
else
  echo "ℹ️  superpowers plugin not installed - will use direct problem-solving"
fi

# Check for quint plugin (structured reasoning for ultra-complex decisions)
QUINT_AVAILABLE=false
if claude plugins list 2>/dev/null | grep -q "quint"; then
  QUINT_AVAILABLE=true
  echo "✅ quint plugin detected - will use for ultra-complex decisions requiring human guidance"
else
  echo "ℹ️  quint plugin not installed - will escalate ultra-complex issues for manual review"
fi

# Ensure priority labels exist (one-time setup per project)
if [ ! -f ".github/.priority-labels-configured" ]; then
  echo "🏷️  Checking priority labels (one-time setup)..."
  EXISTING_LABELS=$(gh label list --json name --jq '.[].name' 2>/dev/null || echo "")

  for label in "P0:Critical priority issue:d73a4a" "P1:High priority issue:ff9800" "P2:Medium priority issue:ffeb3b" "P3:Low priority issue:4caf50" "proposal:AI-generated proposal awaiting human approval:c5def5" "working:Issue currently being worked on by an agent:1d76db" "needs-approval:Architectural decisions, major changes, security implications:e99695" "needs-design:Requirements unclear, multiple approaches, needs design:fbca04" "needs-clarification:Incomplete information, missing context, questions needed:d4c5f9" "too-complex:Beyond autonomous capability, requires deep expertise:b60205" "decomposed:Complex issue broken into sub-tasks:9c27b0" "subtask:Part of a larger decomposed issue:ba68c8"; do
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

# Find issues without any priority label (P0-P3), excluding issues already being worked on
UNPRIORITIZED=$(cat /tmp/all-open-issues.json | python3 -c "
import json, sys
issues = json.load(sys.stdin)
unprioritized = [i for i in issues
                 if not any(l['name'] in ['P0','P1','P2','P3'] for l in i.get('labels',[]))
                 and not any(l['name'] == 'working' for l in i.get('labels',[]))]
for issue in unprioritized:
    print(f\"{issue['number']}|{issue['title']}|{issue.get('body', '')[:500]}\")
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
# Usage: /fix [issue_number]
SPECIFIED_ISSUE="${1:-}"

if [ -n "$SPECIFIED_ISSUE" ]; then
  # Specific issue provided - fetch it directly
  echo "🎯 Targeting specific issue #$SPECIFIED_ISSUE"
  gh issue view "$SPECIFIED_ISSUE" --json number,title,body,labels > /tmp/top-issue.json 2>/dev/null

  if [ $? -ne 0 ] || [ ! -s /tmp/top-issue.json ]; then
    echo "❌ Error: Issue #$SPECIFIED_ISSUE not found or not accessible"
    exit 1
  fi

  # Check if issue already has 'working' label (being worked on by another agent)
  IS_WORKING=$(cat /tmp/top-issue.json | jq -r '.labels | map(.name) | any(. == "working")')
  if [ "$IS_WORKING" = "true" ]; then
    echo "⚠️  Issue #$SPECIFIED_ISSUE has 'working' label - another agent is working on it"
    echo "Use 'gh issue edit $SPECIFIED_ISSUE --remove-label working' to force release"
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

  # Filter out issues with 'working' label (being worked on by another agent)
  # Also filter out issues with blocking labels (needs human review)
  # Also filter out decomposed parent issues (work on their sub-tasks instead)
  cat /tmp/all-issues.json | jq -r '
    .[] |
    select(
      (.labels | map(.name) | any(. == "P0" or . == "P1" or . == "P2" or . == "P3"))
      and (.labels | map(.name) | any(. == "working") | not)
      and (.labels | map(.name) | any(. == "needs-approval" or . == "needs-design" or . == "needs-clarification" or . == "too-complex" or . == "decomposed") | not)
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

  # Check if any issue was found (after filtering out 'working' and blocked issues)
  if [ "$ISSUE_NUM" = "null" ] || [ -z "$ISSUE_NUM" ]; then
    echo "ℹ️  No available priority issues found"
    echo "   All issues may be: claimed by other agents, or blocked (needs human review)"
    echo "   Use '/review-blocked' to review and approve blocked issues"
    echo "IDLE_NO_WORK_AVAILABLE"
    exit 0
  fi
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

# Save parent branch before creating feature branch
PARENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)

# Create fix branch
git checkout -b "fix/issue-${ISSUE_NUM}-auto" 2>/dev/null || git checkout "fix/issue-${ISSUE_NUM}-auto"

# Add 'working' label to claim the issue (prevents other agents from picking it up)
gh issue edit "$ISSUE_NUM" --add-label "working" 2>/dev/null || true

# Post comment that work started
gh issue comment "$ISSUE_NUM" --body "🤖 **Automated Fix Started**

Starting automated fix for this issue.

**Branch**: \`fix/issue-${ISSUE_NUM}-auto\`
**Started**: $(date)

Fix in progress..." 2>/dev/null || true

echo "✅ Created branch: fix/issue-${ISSUE_NUM}-auto"
echo "✅ Added 'working' label (concurrency lock)"
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

# Push feature branch
git push -u origin "fix/issue-${ISSUE_NUM}-auto"

# Switch back to parent branch and merge
git checkout "$PARENT_BRANCH"
git merge --no-ff "fix/issue-${ISSUE_NUM}-auto"

# Push parent branch
git push

# Clean up feature branch
git branch -d "fix/issue-${ISSUE_NUM}-auto"

# Remove 'working' label and close issue
gh issue edit "$ISSUE_NUM" --remove-label "working" 2>/dev/null || true
gh issue close "$ISSUE_NUM" --comment "✅ **Issue Resolved**

[Detailed explanation of fix]

**Branch**: \`fix/issue-${ISSUE_NUM}-auto\` (merged and deleted)

🤖 Auto-resolved by autonomous fix workflow"
```

### Step 2B: Complex Issue - Use Superpowers (if available)

For complex issues requiring design and planning. If `SUPERPOWERS_AVAILABLE=true`, use superpowers skills. Otherwise, use direct problem-solving approaches.

**1. Systematic Debugging (if bugs)**

If the issue involves bugs or test failures:

```
# If superpowers available:
Use Skill tool: superpowers:systematic-debugging

# If superpowers NOT available:
# - Reproduce the issue and capture error output
# - Trace through code to identify root cause
# - Form and test hypotheses
# - Document findings before implementing fix
```

This will:
- Investigate root cause thoroughly
- Analyze patterns across failures
- Test hypotheses before implementing
- Ensure understanding before solutions

**2. Brainstorming (if new features)**

If the issue requires new feature design:

```
# If superpowers available:
Use Skill tool: superpowers:brainstorming

# If superpowers NOT available:
# - Explore 2-3 design alternatives
# - List pros/cons for each approach
# - Identify open questions and assumptions
# - Select approach with clear rationale
```

This will:
- Explore design alternatives
- Clarify requirements through questions
- Validate assumptions
- Refine rough ideas into concrete designs

**3. Writing Plans (for implementation)**

After design is complete, create implementation plan:

```
# If superpowers available:
Use Skill tool: superpowers:writing-plans

# If superpowers NOT available:
# - Break work into numbered tasks (5-15 tasks)
# - Specify exact file paths and changes for each
# - Include verification command for each task
# - Order tasks by dependency
```

This will:
- Break down into bite-sized tasks
- Specify exact file paths and changes
- Include verification steps
- Assume zero prior codebase knowledge

**4. Executing Plans**

Execute the plan in controlled batches:

```
# If superpowers available:
Use Skill tool: superpowers:executing-plans

# If superpowers NOT available:
# - Execute 3-5 tasks at a time
# - Run verification after each batch
# - Stop and reassess if verification fails
# - Track completed vs remaining tasks
```

This will:
- Load and review the plan critically
- Execute tasks in batches
- Report progress for review between batches
- Track completion systematically

**5. Verification**

Before claiming complete, verify the fix:

```
# If superpowers available:
Use Skill tool: superpowers:verification-before-completion

# If superpowers NOT available:
# - Run all verification commands
# - Capture and review output
# - Confirm success criteria are met
# - Run full test suite before committing
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

# Push feature branch
git push -u origin "fix/issue-${ISSUE_NUM}-auto"

# Switch back to parent branch and merge
git checkout "$PARENT_BRANCH"
git merge --no-ff "fix/issue-${ISSUE_NUM}-auto"

# Push parent branch
git push

# Clean up feature branch
git branch -d "fix/issue-${ISSUE_NUM}-auto"

# Remove 'working' label and close issue with detailed explanation
gh issue edit "$ISSUE_NUM" --remove-label "working" 2>/dev/null || true
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

## Blocking Detection & Label Assignment

Before attempting to work on an issue, assess whether it can be handled autonomously. If not, add the appropriate blocking label and skip to the next issue.

### Blocking Labels

| Label | When to Apply | Example Indicators |
|-------|---------------|-------------------|
| `needs-clarification` | Incomplete information, missing context, unclear requirements | "Fix the bug" (which bug?), "Improve performance" (of what?), vague descriptions |
| `needs-design` | Multiple valid approaches without clear winner, requires design phase | "Add user dashboard", "Implement notifications", architectural uncertainty |
| `needs-approval` | Architectural decisions, major changes, security implications, breaking changes | "Migrate to microservices", "Change auth system", "Remove deprecated API" |
| `too-complex` | Beyond autonomous capability (when decomposition fails or superpowers unavailable) | Manual decomposition needed, requires deep expertise |
| `decomposed` | Complex issue broken into sub-tasks (automatically applied, not blocking) | Parent issue tracking sub-task completion |
| `subtask` | Part of a larger decomposed issue (informational, not blocking) | Individual actionable task from decomposition |

### Detection Process

**Step 1: Read the issue carefully**

Look for these red flags:
- **Vague or incomplete**: No specific steps, missing context, unclear acceptance criteria → `needs-clarification`
- **Multiple solutions**: Several valid approaches, trade-offs unclear, design needed → `needs-design`
- **Major decision**: Architectural change, breaking change, security impact → `needs-approval`
- **Too large**: >100 test failures, affects multiple systems, irreversible → `too-complex`

**Step 2: If blocked, add label and skip**

```bash
BLOCKING_LABEL=""  # Will be set to one of: needs-clarification, needs-design, needs-approval, too-complex
BLOCKING_REASON=""  # Human-readable explanation

# Example: Issue has unclear requirements
if [issue description is vague or missing critical information]; then
  BLOCKING_LABEL="needs-clarification"
  BLOCKING_REASON="Issue description is unclear. Need specific details about: [what's missing]"
fi

# Example: Issue requires design decisions
if [multiple approaches possible, no clear winner]; then
  BLOCKING_LABEL="needs-design"
  BLOCKING_REASON="Multiple valid approaches exist. Need design phase to evaluate: [list options]"
fi

# Example: Issue requires architectural approval
if [breaking change or major architectural decision]; then
  BLOCKING_LABEL="needs-approval"
  BLOCKING_REASON="This requires architectural decision: [describe the decision]"
fi

# Example: Issue is too complex for autonomous resolution
if [>100 test failures or cross-cutting concerns]; then
  BLOCKING_LABEL="too-complex"
  BLOCKING_REASON="Too large for autonomous resolution: [describe complexity]"
fi

# If a blocking label was identified, use the script to add it and skip
if [ -n "$BLOCKING_LABEL" ]; then
  # Determine script location (portable across different plugin install locations)
  SCRIPT_DIR="$HOME/.claude/plugins/autocoder/scripts"

  bash "$SCRIPT_DIR/add-blocking-label.sh" "$ISSUE_NUM" "$BLOCKING_LABEL" "$BLOCKING_REASON"

  echo "⏭️  Skipping to next issue..."
  echo ""
  # Continue to next issue in the workflow
fi
```

**Step 3: If not blocked, proceed with fix**

If no blocking conditions detected, continue with the normal fix workflow (simple vs complex vs ultra-complex determination).

### Ultra-Complex Issues - Decompose into Sub-Tasks

For issues too large for autonomous resolution (>100 test failures, major architecture changes, significant trade-off decisions):

**First, attempt to decompose the issue into manageable sub-tasks:**

```bash
echo "⚠️  Ultra-complex issue detected: attempting decomposition"

# Use brainstorming skill to analyze and decompose the complex issue
if [ "$SUPERPOWERS_AVAILABLE" = "true" ]; then
  echo "📋 Using superpowers:brainstorming to decompose issue #$ISSUE_NUM..."
  # Prompt: "Analyze issue #$ISSUE_NUM and decompose it into 3-8 manageable sub-tasks.
  # Each sub-task should be independently fixable and testable.
  # For each sub-task, provide: title, description, acceptance criteria, and priority."

  # After decomposition analysis is complete, create GitHub issues for each sub-task
  # Store sub-task numbers for linking
  SUBTASK_NUMBERS=()

  # Example sub-task creation (repeat for each decomposed task):
  # for SUBTASK in "${SUBTASKS[@]}"; do
  SUBTASK_NUM=$(gh issue create \
    --label "bug,P2,subtask" \
    --title "Subtask: [Brief description]" \
    --body "$(cat <<SUBTASK_BODY
## Sub-task of #${ISSUE_NUM}

This is a decomposed sub-task from the larger issue #${ISSUE_NUM}.

## Description
[What needs to be done in this specific sub-task]

## Acceptance Criteria
- [ ] Criterion 1
- [ ] Criterion 2
- [ ] Criterion 3

## Dependencies
- Must be completed as part of #${ISSUE_NUM}
- [Any dependencies on other sub-tasks]

## Testing
[How to verify this sub-task is complete]

---

🤖 Auto-decomposed from #${ISSUE_NUM} by autonomous fix workflow
SUBTASK_BODY
)" | grep -oP '#\K[0-9]+')

  SUBTASK_NUMBERS+=("$SUBTASK_NUM")
  echo "✅ Created sub-task #$SUBTASK_NUM"
  # done

  # Update original issue to reference all sub-tasks
  gh issue comment "$ISSUE_NUM" --body "🔍 **Issue Decomposed into Sub-Tasks**

This complex issue has been broken down into manageable sub-tasks:

$(for num in "${SUBTASK_NUMBERS[@]}"; do echo "- [ ] #$num"; done)

**Status**: This issue will be automatically closed once all sub-tasks are completed and verified.

**To track progress**: Check the sub-tasks listed above.

🤖 Auto-decomposed by autonomous fix workflow"

  # Add label to indicate decomposition
  gh issue edit "$ISSUE_NUM" --add-label "decomposed" 2>/dev/null || true

  echo "✅ Decomposed issue #$ISSUE_NUM into ${#SUBTASK_NUMBERS[@]} sub-tasks"
  echo "📋 Sub-tasks: ${SUBTASK_NUMBERS[*]}"
  echo ""
  echo "⏭️  Moving to next issue. Sub-tasks will be processed in priority order."

else
  # Fallback: If superpowers not available, add too-complex label
  echo "ℹ️  Superpowers not available for decomposition"

  # Prepare detailed reason for blocking
  COMPLEXITY_REASON="Ultra-complex issue requiring decomposition or human guidance.

**Complexity Indicators**:
- [List specific indicators: >100 test failures, major architectural change, etc.]

**Recommended Approach**:
- Manually decompose into smaller sub-tasks
- Use /review-blocked to interactively review this issue
- Consider using superpowers plugin for assisted decomposition

**Available Tools**:
$(if [ "$QUINT_AVAILABLE" = "true" ]; then
  echo "- ✅ Quint plugin available for structured reasoning"
else
  echo "- ℹ️  Quint plugin not installed - manual review recommended"
fi)"

  # Determine script location (portable across different plugin install locations)
  SCRIPT_DIR="$HOME/.claude/plugins/autocoder/scripts"

  # Use the script to add blocking label
  bash "$SCRIPT_DIR/add-blocking-label.sh" "$ISSUE_NUM" "too-complex" "$COMPLEXITY_REASON"

  echo "⏭️  Issue labeled as too-complex. Use /review-blocked to review."
fi

echo ""
# Continue to next issue
```

**Monitoring Decomposed Issues**:

When processing issues in the main loop, check for decomposed issues where all sub-tasks are complete:

```bash
# After fixing each issue, check if it was a sub-task that completes a decomposed issue
# Get parent issue if this was a subtask
PARENT_ISSUE=$(gh issue view "$ISSUE_NUM" --json body --jq '.body' | grep -oP 'Sub-task of #\K[0-9]+' || echo "")

if [ -n "$PARENT_ISSUE" ]; then
  echo "🔍 Checking if parent issue #$PARENT_ISSUE is now complete..."

  # Check if all sub-tasks of parent are closed
  PARENT_SUBTASKS=$(gh issue view "$PARENT_ISSUE" --json body --jq '.body' | grep -oP '#\K[0-9]+' || echo "")
  ALL_CLOSED=true

  for SUBTASK_NUM in $PARENT_SUBTASKS; do
    SUBTASK_STATE=$(gh issue view "$SUBTASK_NUM" --json state --jq '.state')
    if [ "$SUBTASK_STATE" != "CLOSED" ]; then
      ALL_CLOSED=false
      break
    fi
  done

  if [ "$ALL_CLOSED" = "true" ]; then
    echo "✅ All sub-tasks complete! Closing parent issue #$PARENT_ISSUE"
    gh issue close "$PARENT_ISSUE" --comment "✅ **Complex Issue Resolved**

All sub-tasks have been completed and verified:

$(for num in $PARENT_SUBTASKS; do echo "- ✅ #$num"; done)

The decomposed approach successfully resolved this complex issue.

🤖 Auto-closed by autonomous fix workflow"
  fi
fi
```

### Skip Criteria (Legacy)

Skip to next issue if:
- Issue requires external dependencies (API keys, services) → add `needs-clarification` label
- Issue is blocked by another issue → add comment, don't add blocking label
- Issue requires user input/decision → add appropriate blocking label (`needs-approval`, `needs-design`, or `needs-clarification`)

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

# Filter out proposals, blocked issues, and issues being worked on - only get available approved enhancements
APPROVED_ENHANCEMENTS=$(cat /tmp/all-enhancements.json | python3 -c "
import json, sys
issues = json.load(sys.stdin)
blocking_labels = ['needs-approval', 'needs-design', 'needs-clarification', 'too-complex']
approved = [i for i in issues
            if not any(l['name'] == 'proposal' for l in i.get('labels', []))
            and not any(l['name'] == 'working' for l in i.get('labels', []))
            and not any(l['name'] in blocking_labels for l in i.get('labels', []))]
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

  # Check if there are blocked issues
  BLOCKED_COUNT=$(cat /tmp/all-enhancements.json | python3 -c "
import json, sys
issues = json.load(sys.stdin)
blocking_labels = ['needs-approval', 'needs-design', 'needs-clarification', 'too-complex']
blocked = [i for i in issues if any(l['name'] in blocking_labels for l in i.get('labels', []))]
print(len(blocked))
")

  if [ "$PROPOSAL_COUNT" -gt 0 ]; then
    echo "📋 Found $PROPOSAL_COUNT proposal(s) awaiting human approval"
    echo "💡 Use '/list-proposals' to review pending proposals"
    echo "✨ No approved enhancements to implement. Creating new proposals..."
  elif [ "$BLOCKED_COUNT" -gt 0 ]; then
    echo "🚫 Found $BLOCKED_COUNT blocked issue(s) (requires human review)"
    echo "💡 Use '/review-blocked' to review and approve blocked issues"
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
echo ""
echo "IDLE_NO_WORK_AVAILABLE"
```

**IMPORTANT**: After creating a proposal, output `IDLE_NO_WORK_AVAILABLE` to trigger the sleep cycle. This gives humans time to review the proposal before the next iteration. Do NOT immediately create more proposals or loop without sleeping.

#### 5C: Implement Approved Enhancement Using Superpowers

**IMPORTANT**: Only implement enhancements that do NOT have the `proposal` label. If an enhancement has the `proposal` label, it is awaiting human approval and must NOT be implemented.

For each **approved** enhancement issue (no `proposal` label), follow this workflow:

**Step 1: Create Feature Branch**

```bash
# Save parent branch before creating feature branch
PARENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)

git checkout -b "enhancement/issue-${ENHANCE_NUM}-auto" 2>/dev/null || git checkout "enhancement/issue-${ENHANCE_NUM}-auto"

# Add 'working' label to claim the enhancement (prevents other agents from picking it up)
gh issue edit "$ENHANCE_NUM" --add-label "working" 2>/dev/null || true

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

  # Push feature branch
  git push -u origin "enhancement/issue-${ENHANCE_NUM}-auto"

  # Switch back to parent branch and merge
  git checkout "$PARENT_BRANCH"
  git merge --no-ff "enhancement/issue-${ENHANCE_NUM}-auto"

  # Push parent branch
  git push

  # Clean up feature branch
  git branch -d "enhancement/issue-${ENHANCE_NUM}-auto"

  # Remove 'working' label and close enhancement with details
  gh issue edit "$ENHANCE_NUM" --remove-label "working" 2>/dev/null || true
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
# Remove 'working' label to release the enhancement for others
gh issue edit "$ENHANCE_NUM" --remove-label "working" 2>/dev/null || true

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

# Count priority bug issues (P0-P3, excluding proposals, blocked, decomposed, and issues being worked on)
PRIORITY_ISSUES=$(cat /tmp/all-issues.json | python3 -c "
import json, sys
issues = json.load(sys.stdin)
blocking_labels = ['needs-approval', 'needs-design', 'needs-clarification', 'too-complex', 'decomposed']
priority = [i for i in issues
            if any(l['name'] in ['P0','P1','P2','P3'] for l in i.get('labels',[]))
            and not any(l['name'] == 'proposal' for l in i.get('labels',[]))
            and not any(l['name'] == 'working' for l in i.get('labels',[]))
            and not any(l['name'] in blocking_labels for l in i.get('labels',[]))]
print(len(priority))
")

# Count APPROVED enhancement issues (enhancement label but NOT proposal, blocked, or working label)
APPROVED_ENHANCEMENTS=$(cat /tmp/all-issues.json | python3 -c "
import json, sys
issues = json.load(sys.stdin)
blocking_labels = ['needs-approval', 'needs-design', 'needs-clarification', 'too-complex']
approved = [i for i in issues
            if any(l['name'] == 'enhancement' for l in i.get('labels',[]))
            and not any(l['name'] == 'proposal' for l in i.get('labels',[]))
            and not any(l['name'] == 'working' for l in i.get('labels',[]))
            and not any(l['name'] in blocking_labels for l in i.get('labels',[]))]
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
  echo "✨ No bugs or approved enhancements."

  # Count blocked issues
  BLOCKED_ISSUES_COUNT=$(cat /tmp/all-issues.json | python3 -c "
import json, sys
issues = json.load(sys.stdin)
blocking_labels = ['needs-approval', 'needs-design', 'needs-clarification', 'too-complex']
blocked = [i for i in issues if any(l['name'] in blocking_labels for l in i.get('labels', []))]
print(len(blocked))
")

  if [ "$PENDING_PROPOSALS" -gt 0 ] || [ "$BLOCKED_ISSUES_COUNT" -gt 0 ]; then
    if [ "$PENDING_PROPOSALS" -gt 0 ]; then
      echo "📋 $PENDING_PROPOSALS proposal(s) awaiting human approval."
      echo "💡 Use '/list-proposals' to review pending proposals"
    fi
    if [ "$BLOCKED_ISSUES_COUNT" -gt 0 ]; then
      echo "🚫 $BLOCKED_ISSUES_COUNT issue(s) blocked (requires human review)."
      echo "💡 Use '/review-blocked' to review and approve blocked issues"
    fi
    echo "💤 Nothing to do until proposals/blocked issues are approved or new issues arrive."
    echo ""
    echo "IDLE_NO_WORK_AVAILABLE"
  else
    echo "No pending proposals or blocked issues. Will brainstorm new proposals..."
    # Run /full-regression-test first if not recently run
    # Then brainstorm proposals using superpowers:brainstorming
    # After creating proposals, output IDLE_NO_WORK_AVAILABLE
  fi
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
- **DO** output `IDLE_NO_WORK_AVAILABLE` after creating a proposal (to allow human review)
- **DO** output `IDLE_NO_WORK_AVAILABLE` when no bugs and proposals already exist
- **DO** create bug issues for any test failures during enhancement work
- **DO** loop back to bug fixing if enhancement work creates failures

### Idle State

**CRITICAL: You MUST output the idle signal when there's nothing to do.**

Output this EXACT text (on its own line) when ANY of these conditions are true:
- No priority bugs (P0-P3) AND no approved enhancements AND (proposals already exist OR blocked issues exist)
- After creating a new proposal (to allow human review time)
- After completing all available work

```
IDLE_NO_WORK_AVAILABLE
```

**Without this signal, the loop will spin forever without sleeping.**

This signals the stop hook to sleep (default 15 minutes) before checking again for:
- New human-created issues
- Comments on existing issues
- Approved proposals ready for implementation
- Blocked issues reviewed and approved (blocking label removed)

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

Once the `proposal` label is removed, the `/fix` workflow will automatically implement the enhancement on its next iteration.

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
