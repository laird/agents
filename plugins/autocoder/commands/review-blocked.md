# Review Blocked Issues

Interactive planning session to review and unblock issues that fix-loop has labeled with blocking tags. This command is designed to run in parallel with `/fix-loop` in a separate terminal session.

## Usage

```bash
# Review all blocked issues (priority-first)
/review-blocked

# Filter to specific blocking label
/review-blocked --label needs-design
/review-blocked --label needs-approval
/review-blocked --label needs-clarification
/review-blocked --label too-complex
/review-blocked --label future
/review-blocked --label proposal

# Filter to specific priority
/review-blocked --priority P0
/review-blocked --priority P1

# Jump directly to a specific issue
/review-blocked 123
```

## What This Does

1. **Fetches blocked issues** - Finds all open issues with blocking labels (`needs-approval`, `needs-design`, `needs-clarification`, `too-complex`, `future`, `proposal`)
2. **Shows overview** - Groups by blocking type and priority, shows counts
3. **Proposes highest priority** - Starts with P0, then P1, then P2, then P3
4. **Analyzes the issue** - Reads full context, explains why it's blocked
5. **Presents recommendations** - Shows 2-3 approaches with pros/cons
6. **Gets your decision** - Approve, explore further, reject, or skip
7. **Updates labels** - Removes blocking label when approved, closes if rejected
8. **Continues** - Moves to next blocked issue or exits

## Blocking Labels

These labels indicate why fix-loop cannot autonomously work on an issue:

| Label | When Applied | Example Scenario |
|-------|--------------|------------------|
| `needs-approval` | Architectural decisions, major changes, security implications | "Should we migrate from REST to GraphQL?" |
| `needs-design` | Requirements unclear, multiple valid approaches, needs design phase | "Add user dashboard" (what features? layout?) |
| `needs-clarification` | Incomplete information, missing context, questions needed | "Fix the bug in checkout" (which bug? what's failing?) |
| `too-complex` | Beyond autonomous capability, requires deep expertise/judgment | "Refactor entire auth system for multi-tenancy" |
| `future` | Idea for future consideration, not ready for implementation | "Expose data via MCP server", research spikes |
| `proposal` | Proposed feature or change awaiting review | "Add dark mode support" (needs design review and approval) |

**Note**: Blocking labels are independent from priority labels. An issue can have both `P0` + `needs-design`.

## Interactive Review Flow

For each blocked issue, the command:

1. **Shows Context**
   - Issue title, number, priority, blocking label
   - Quote from fix-loop's comment explaining why it's blocked
   - Brief summary of what the issue is asking for

2. **Presents Analysis**
   - Why it's blocked (specific reason)
   - 2-3 recommended approaches with:
     - Description of what it involves
     - Pros (2-3 benefits)
     - Cons (1-2 drawbacks)
     - Effort estimation (Small/Medium/Large)
   - Recommendation with reasoning

3. **Asks for Decision**
   - **Approve Option [X]** - Remove blocking label, add comment with decision
   - **Explore further** - Use other skills like `/brainstorm`, `/q1-hypothesize`
   - **Reject** - Close issue with reason
   - **Skip** - Leave blocked, move to next

4. **Updates Issue**
   - If approved: Remove blocking label, add approval comment
   - If rejected: Close issue with rejection comment
   - If skipped: No changes, move to next

## Instructions

Start the interactive review session now:

```bash
# Determine script location (portable across different plugin install locations)
PLUGIN_DIR="${BASH_SOURCE[0]%/*}"
SCRIPT_DIR="$PLUGIN_DIR/../scripts"

# If running via Claude Code plugin system, use the plugin path
if [ -d "$HOME/.claude/plugins/autocoder/scripts" ]; then
  SCRIPT_DIR="$HOME/.claude/plugins/autocoder/scripts"
fi

echo "🏷️  Checking blocking labels..."
echo "🔍 Scanning for blocked issues..."
echo ""

# Fetch blocked issues using the script
BLOCKED_ISSUES=$(bash "$SCRIPT_DIR/fetch-blocked-issues.sh" "$@")

# Check if we found any issues
TOTAL_BLOCKED=$(echo "$BLOCKED_ISSUES" | python3 -c "import json,sys; print(json.load(sys.stdin)['total'])")

if [ "$TOTAL_BLOCKED" -eq 0 ]; then
  echo "✅ No blocked issues found!"
  echo ""
  echo "All issues are either:"
  echo "  - Ready for autonomous fix-loop to work on, or"
  echo "  - Already being worked on (have 'working' label)"
  echo ""
  exit 0
fi

# Show summary
echo "📊 Blocked Issues Overview"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

SUMMARY=$(echo "$BLOCKED_ISSUES" | python3 -c "
import json, sys
data = json.load(sys.stdin)
summary = data['summary']

for label, priorities in summary.items():
    if priorities:
        counts = [f'{count} {priority}' for priority, count in priorities.items()]
        print(f'{label}: {len(priorities)} priorities ({', '.join(counts)})')

print(f'\nTotal: {data[\"total\"]} blocked issues')
")

echo "$SUMMARY"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Save for use in review loop
echo "$BLOCKED_ISSUES" > /tmp/blocked-issues.json
```

Now begin the interactive review loop. For each blocked issue (starting with highest priority):

### Step 1: Present the Issue

Extract the highest priority blocked issue:

```bash
CURRENT_ISSUE=$(cat /tmp/blocked-issues.json | python3 -c "
import json, sys
data = json.load(sys.stdin)
if data['issues']:
    issue = data['issues'][0]
    print(json.dumps(issue))
")

if [ -z "$CURRENT_ISSUE" ]; then
  echo "✅ All blocked issues have been reviewed!"
  exit 0
fi

ISSUE_NUM=$(echo "$CURRENT_ISSUE" | python3 -c "import json,sys; print(json.load(sys.stdin)['number'])")
ISSUE_TITLE=$(echo "$CURRENT_ISSUE" | python3 -c "import json,sys; print(json.load(sys.stdin)['title'])")
ISSUE_BODY=$(echo "$CURRENT_ISSUE" | python3 -c "import json,sys; print(json.load(sys.stdin).get('body',''))")

BLOCKING_LABEL=$(echo "$CURRENT_ISSUE" | python3 -c "
import json, sys
issue = json.load(sys.stdin)
blocking_labels = ['needs-approval', 'needs-design', 'needs-clarification', 'too-complex', 'future', 'proposal']
labels = [l['name'] for l in issue.get('labels', [])]
for bl in blocking_labels:
    if bl in labels:
        print(bl)
        break
")

PRIORITY_LABEL=$(echo "$CURRENT_ISSUE" | python3 -c "
import json, sys
issue = json.load(sys.stdin)
priorities = ['P0', 'P1', 'P2', 'P3']
labels = [l['name'] for l in issue.get('labels', [])]
for p in priorities:
    if p in labels:
        print(p)
        break
")

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📋 Issue #${ISSUE_NUM}: ${ISSUE_TITLE}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Priority: ${PRIORITY_LABEL}"
echo "Blocking: ${BLOCKING_LABEL}"
echo ""
```

### Step 2: Analyze the Issue

Read the issue context and look for fix-loop's explanation:

```bash
# Check if fix-loop left a comment explaining why it's blocked
FIXLOOP_COMMENT=$(echo "$CURRENT_ISSUE" | python3 -c "
import json, sys
issue = json.load(sys.stdin)
comments = issue.get('comments', [])
for comment in comments:
    body = comment.get('body', '')
    # Look for comments from automated systems or containing blocking keywords
    if any(keyword in body.lower() for keyword in ['blocked', 'cannot', 'requires human', 'needs approval', 'unclear']):
        print(body[:300])  # First 300 chars
        break
")

if [ -n "$FIXLOOP_COMMENT" ]; then
  echo "🤖 Fix-loop's Note:"
  echo "$FIXLOOP_COMMENT"
  echo ""
fi
```

Now use your capabilities to analyze the issue and present recommendations. You should:

1. **Read the full issue** - Understand title, body, any comments
2. **Determine why it's blocked** - Explain the specific reason based on the blocking label
3. **Research context** - If the issue mentions files/components, read relevant code
4. **Generate 2-3 approaches** - Consider different ways to solve this
5. **Make a recommendation** - Pick the best approach and explain why

Present your analysis in this format:

```markdown
## Issue #${ISSUE_NUM}: ${ISSUE_TITLE}

**Priority**: ${PRIORITY_LABEL}
**Blocking Reason**: ${BLOCKING_LABEL}

### Context
[2-3 sentence summary of what the issue is asking for]

### Why It's Blocked
[Specific reason: architectural choice needed, unclear requirements, too complex, etc.]

### Recommended Approaches

**Option A: [Approach Name]** (Recommended)
- Description: [What this approach involves]
- Pros: [2-3 benefits]
- Cons: [1-2 drawbacks]
- Effort: [Small/Medium/Large]

**Option B: [Alternative Approach]**
- Description: [What this approach involves]
- Pros: [2-3 benefits]
- Cons: [1-2 drawbacks]
- Effort: [Small/Medium/Large]

**Option C: [Another Alternative]** (if applicable)
- [Same structure]

### Recommendation
I recommend Option A because [specific reasoning based on project context, existing patterns, trade-offs].
```

### Step 3: Get User Decision

After presenting your analysis, use the AskUserQuestion tool to get the user's decision:

```
AskUserQuestion with:
- Question: "How would you like to proceed with issue #${ISSUE_NUM}?"
- Options:
  A) "Approve Option A (Recommended)" - "Remove blocking label and add approval comment. Fix-loop will implement this approach."
  B) "Approve Option B" - "Remove blocking label with this alternative approach."
  C) "Approve Option C" - (if 3 options presented)
  D) "Explore further" - "Ask more questions or use other skills (/brainstorm, /q1-hypothesize) before deciding."
  E) "Reject this issue" - "Close the issue as it shouldn't be worked on."
  F) "Skip for now" - "Leave blocked and move to next issue."
```

### Step 4: Process Decision

Based on user's choice:

**If Approved (Option A/B/C):**
```bash
APPROVED_OPTION="[User's choice: A/B/C]"
APPROVED_APPROACH="[Name of the approach they chose]"

# Use the approve script
bash "$SCRIPT_DIR/approve-blocked-issue.sh" "$ISSUE_NUM" "$BLOCKING_LABEL" "$APPROVED_APPROACH"

echo ""
echo "   Fix-loop will work on this issue on its next iteration."
echo ""
```

**If Explore Further:**
```bash
echo ""
echo "💡 You can now use other skills to explore this issue:"
echo "   - /brainstorm for design discussion"
echo "   - /q1-hypothesize for systematic hypothesis generation"
echo "   - Ask follow-up questions about the issue"
echo ""
echo "When ready to make a decision, we can continue the review process."
echo ""

# Don't remove from queue yet - let user explore
exit 0
```

**If Rejected:**
```bash
REJECT_REASON="[Ask user for rejection reason]"

# Use the reject script
bash "$SCRIPT_DIR/reject-blocked-issue.sh" "$ISSUE_NUM" "$REJECT_REASON"

echo ""
```

**If Skipped:**
```bash
echo ""
echo "⏭️  Skipped issue #${ISSUE_NUM}. Blocking label remains."
echo "   This issue will appear in the next /review-blocked session."
echo ""
```

### Step 5: Continue to Next Issue

After processing the current issue (unless user chose "Explore further"), remove it from the queue and continue:

```bash
# Remove processed issue from queue
cat /tmp/blocked-issues.json | python3 -c "
import json, sys
data = json.load(sys.stdin)
if len(data['issues']) > 1:
    data['issues'] = data['issues'][1:]
    data['total'] = len(data['issues'])
    print(json.dumps(data))
" > /tmp/blocked-issues-remaining.json

mv /tmp/blocked-issues-remaining.json /tmp/blocked-issues.json

REMAINING=$(cat /tmp/blocked-issues.json | python3 -c "import json,sys; print(json.load(sys.stdin)['total'])")

if [ "$REMAINING" -eq 0 ]; then
  echo "✅ All blocked issues have been reviewed!"
  echo ""
  exit 0
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📊 ${REMAINING} blocked issue(s) remaining"
echo ""
```

Now repeat from Step 1 for the next blocked issue. Use the AskUserQuestion tool to ask:

```
"Continue to next blocked issue?"
Options:
- "Yes, continue" - Proceed to review the next issue
- "Stop for now" - Exit the review session
```

If user chooses "Yes, continue", repeat the process from Step 1. If "Stop for now", exit gracefully.

## Key Behaviors

- **Non-blocking**: This command runs independently from `/fix-loop`
- **Priority-first**: Always surfaces P0 before P1, P1 before P2, etc.
- **Lightweight analysis**: Quick recommendations, user can dive deeper with other skills
- **Clear state transitions**: Issues move from blocked → approved with proper label updates
- **Interactive**: Uses AskUserQuestion for all decisions
- **Contextual**: Reads code, past comments, related issues to inform recommendations
- **Flexible**: User can explore further before deciding

## Notes

- This command is designed to run in parallel with `/fix-loop` in a separate terminal
- Fix-loop will automatically pick up approved issues (blocking label removed) on its next iteration
- Use filtering options (`--label`, `--priority`) to focus on specific types of blocked issues
- The "Explore further" option allows you to use other skills like `/brainstorm` or `/q1-hypothesize` before making a decision
