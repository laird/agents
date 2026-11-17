# /fix reference: the loop and proposals

Moved out of the `/fix` command file (#240) because a worker rarely needs it.
The command keeps a pointer at each place this text used to be.

### Loop Implementation

After every issue is resolved, skipped, or when checking for work:

```bash
# Fetch all open issues
issue_list --state open --limit 100 > /tmp/all-issues.json

# Count priority bug issues (P0-P3, excluding proposals, blocked, decomposed, and issues being worked on)
PRIORITY_ISSUES=$(cat /tmp/all-issues.json | python3 -c "
import json, sys
issues = json.load(sys.stdin)
blocking_labels = ['needs-approval', 'needs-design', 'needs-clarification', 'too-complex', 'future', 'decomposed', 'awaiting-integration']
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
blocking_labels = ['needs-approval', 'needs-design', 'needs-clarification', 'too-complex', 'future', 'awaiting-integration']
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
blocking_labels = ['needs-approval', 'needs-design', 'needs-clarification', 'too-complex', 'future', 'awaiting-integration']
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
    # Then brainstorm proposals using thorough-brainstorming (preferred) or superpowers:brainstorming
    # After creating proposals, output IDLE_NO_WORK_AVAILABLE
  fi
fi
```

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
/update-issue <issue_number> --remove-label "proposal"
```

Once the `proposal` label is removed, the `/fix` workflow will automatically implement the enhancement on its next iteration.

### How to Provide Feedback on a Proposal

1. **Comment on the issue** with your feedback, questions, or requested changes
2. Run `/refine-proposal <issue_number>` to have the AI incorporate your feedback
3. Review the updated proposal
4. Approve or provide additional feedback

### How to Reject a Proposal

```bash
/close-issue <issue_number> "Rejected: [reason for rejection]"
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

**REMINDER**: The `working` label is released only on a **terminal outcome** —
the issue is closed, or you explicitly release it (blocked / skipped / abandoned)
with a release comment in the same step:

```bash
# Terminal outcome only. Never after a partial commit, a batch boundary, or a pause.
issue_update "$ISSUE_NUM" --remove-label "working" 2>/dev/null || true
```

Dropping it while the issue is still open and still yours re-exposes it to the
claimable pool and causes a peer to duplicate your work. Leaving it held while
you are genuinely still working is correct — `/monitor-workers` reclaims locks
that go stale.
