# Brainstorm Issue

Use AI-powered brainstorming to explore design options, clarify requirements, and develop implementation approaches for a GitHub issue.

## Usage

```bash
# Brainstorm a specific issue
/brainstorm-issue 123

# Brainstorm the next issue needing design
/brainstorm-issue
```

## What This Does

1. Fetches the specified GitHub issue (or first `needs-design` issue)
2. Checks for available brainstorming/design skills and uses them if present
3. Explores design alternatives, trade-offs, and implementation approaches
4. Posts brainstorming results as a comment on the issue
5. Optionally removes the `needs-design` label if design is complete

## Instructions

### Step 1: Fetch the Issue

```bash
ISSUE_NUM="${1:-}"

if [ -z "$ISSUE_NUM" ]; then
  echo "🔍 No issue number provided, finding first needs-design issue..."

  # Get first needs-design issue
  ISSUE_NUM=$(gh issue list --state open --label "needs-design" --json number --jq '.[0].number' 2>/dev/null)

  if [ -z "$ISSUE_NUM" ] || [ "$ISSUE_NUM" = "null" ]; then
    echo "✅ No issues need design work!"
    echo ""
    echo "Use '/list-needs-design' to see all issues needing design."
    echo "Use 'gh issue edit <number> --add-label needs-design' to flag an issue."
    exit 0
  fi
fi

echo "🧠 Brainstorming issue #$ISSUE_NUM..."
echo ""

# Fetch issue details
gh issue view "$ISSUE_NUM" --json number,title,body,labels,comments > /tmp/brainstorm-issue.json

if [ $? -ne 0 ]; then
  echo "❌ Error: Could not fetch issue #$ISSUE_NUM"
  exit 1
fi

ISSUE_TITLE=$(cat /tmp/brainstorm-issue.json | jq -r '.title')
ISSUE_BODY=$(cat /tmp/brainstorm-issue.json | jq -r '.body // ""')
ISSUE_COMMENTS=$(cat /tmp/brainstorm-issue.json | jq -r '.comments // []')

echo "═══════════════════════════════════════════════════════════════"
echo "Issue #$ISSUE_NUM: $ISSUE_TITLE"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "$ISSUE_BODY" | head -30
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo ""
```

### Step 2: Invoke Brainstorming

After fetching the issue, perform brainstorming. **Check for available skills first** - if a brainstorming or design-related skill is available (e.g., a brainstorming skill from any installed plugin), use it. Otherwise, perform manual brainstorming.

**Skill Discovery**: Check your available skills for any that mention:
- "brainstorm" or "brainstorming"
- "design" or "designing"
- "ideation" or "exploration"
- "creative" or "creativity"

If a relevant skill is found, invoke it with this context:

```
Context for brainstorming:
- Issue Number: #$ISSUE_NUM
- Issue Title: $ISSUE_TITLE
- Issue Description: $ISSUE_BODY
- Goal: Explore design options and implementation approaches
```

### Manual Brainstorming (if no skill available)

If no brainstorming skill is available, perform the following analysis:

1. **Explore User Intent**
   - What problem is this solving?
   - Who benefits from this?
   - What are the success criteria?

2. **Generate Design Alternatives**
   - At least 2-3 different approaches
   - Pros and cons of each
   - Complexity and effort estimates

3. **Identify Open Questions**
   - What assumptions are being made?
   - What decisions need human input?
   - What dependencies exist?

4. **Recommend an Approach**
   - Which option best balances trade-offs?
   - What's the implementation path?
   - What are the risks?

### Step 3: Post Results to GitHub

After brainstorming completes, post results as a comment:

```bash
# Post brainstorming results to the issue
gh issue comment "$ISSUE_NUM" --body "$(cat <<'BRAINSTORM_BODY'
## 🧠 Brainstorming Results

### Problem Understanding

[Summary of the problem and user intent]

### Design Alternatives

#### Option A: [Name]
**Approach**: [Description]
**Pros**: [Benefits]
**Cons**: [Drawbacks]
**Effort**: [Low/Medium/High]

#### Option B: [Name]
**Approach**: [Description]
**Pros**: [Benefits]
**Cons**: [Drawbacks]
**Effort**: [Low/Medium/High]

#### Option C: [Name] (if applicable)
**Approach**: [Description]
**Pros**: [Benefits]
**Cons**: [Drawbacks]
**Effort**: [Low/Medium/High]

### Open Questions

- [ ] [Question 1 requiring human input]
- [ ] [Question 2 requiring human input]

### Recommended Approach

**Recommendation**: Option [X]

**Rationale**: [Why this option is recommended]

### Next Steps

1. [First step]
2. [Second step]
3. [Third step]

---

🤖 Brainstormed by `/brainstorm-issue`

**Actions**:
- To approve this design: `gh issue edit ISSUE_NUM --remove-label "needs-design"`
- To request changes: Comment on this issue with feedback
- To brainstorm again: `/brainstorm-issue ISSUE_NUM`
BRAINSTORM_BODY
)"

echo "✅ Brainstorming results posted to issue #$ISSUE_NUM"
```

### Step 4: Update Labels (Optional)

If the design is complete and no open questions remain:

```bash
# Ask if design should be marked complete
echo ""
echo "📋 Design complete? Options:"
echo "  1. Remove 'needs-design' label (design is complete)"
echo "  2. Add 'needs-feedback' label (awaiting human input)"
echo "  3. Leave as-is (more brainstorming needed)"
```

## Brainstorming Focus Areas

Depending on the issue type, the brainstorming will focus on different aspects:

| Issue Type | Focus Areas |
|------------|-------------|
| **Bug Fix** | Root cause analysis, fix strategies, regression prevention |
| **New Feature** | User stories, architecture options, API design |
| **Refactoring** | Current pain points, target state, migration path |
| **Performance** | Bottleneck analysis, optimization strategies, trade-offs |
| **Security** | Threat model, mitigation options, implementation approach |

## Integration with Other Commands

```
┌─────────────────┐
│  Issue Created  │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│/list-needs-design
│  (find issues)  │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│/brainstorm-issue│◄───┐
│  (explore design)    │
└────────┬────────┘    │
         │             │
    ┌────┴────┐        │
    │         │        │
    ▼         ▼        │
┌───────┐ ┌───────┐    │
│Design │ │Needs  │────┘
│Complete│ │More Work│
└───┬───┘ └───────┘
    │
    ▼
┌─────────────────┐
│  Ready for      │
│  /fix    │
└─────────────────┘
```

## See Also

- `/list-needs-design` - List all issues needing design work
- `/list-needs-feedback` - List issues needing feedback
- `/fix` - Autonomous issue resolution
- `/approve-proposal` - Approve a proposal for implementation
