---
description: List pending AI-generated proposals
---

# List Pending Proposals

**Version**: 1.5.0
**Purpose**: Display all AI-generated enhancement proposals awaiting human review

---

## Usage

```bash
/list-proposals
```

## What This Does

Lists all open GitHub issues with the `proposal` label, showing:
- Issue number and title
- Priority level (P0-P3)
- Creation date
- Brief description
- Available actions (approve, feedback, reject)

---

## Proposal Workflow

```
AI Creates Proposal → Human Reviews → Approve/Feedback/Reject
                           ↓
                    If Approved:
                    Remove 'proposal' label
                           ↓
                    /fix-github implements
```

## Actions

| Action | Command |
|--------|---------|
| List proposals | `/list-proposals` |
| View details | `gh issue view <number>` |
| Approve | `gh issue edit <number> --remove-label "proposal"` |
| Feedback | `gh issue comment <number> --body "feedback"` |
| Refine | `/refine-proposal <number>` |
| Reject | `gh issue close <number> --comment "Rejected: reason"` |

---

## See Also

- `/fix-github` - Autonomous issue resolution (creates proposals)
- `/refine-proposal` - Incorporate feedback into a proposal
