# Proposal Management Workflow

**Version**: 1.5.0
**Purpose**: Create and manage AI-generated enhancement proposals for human approval

## Overview

AI-generated enhancements are NOT automatically implemented. Instead, they are created as **proposals** with a `proposal` label, requiring human review and approval before implementation.

## Proposal Creation

### When to Create Proposals

Create proposals when:
- All priority bugs (P0-P3) are resolved
- All approved enhancements are implemented
- No existing proposals need work
- Regression tests pass

### Create Enhancement Proposal

```bash
gh issue create \
  --label "enhancement,proposal,P3" \
  --title "Proposal: [Brief description]" \
  --body "$(cat <<'EOF'
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

```bash
gh issue edit <issue_number> --remove-label "proposal"
```

### How to Provide Feedback

Comment on this issue with your feedback.

### How to Reject This Proposal

```bash
gh issue close <issue_number> --comment "Rejected: [reason]"
```

---

🤖 Proposed by autofix agent
EOF
)"
```

## Proposal Lifecycle

```
┌─────────────────┐
│  AI Creates     │
│  Proposal       │
│  (proposal tag) │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  Human Reviews  │◄──────────────────┐
└────────┬────────┘                   │
         │                            │
    ┌────┴────┐                       │
    │         │                       │
    ▼         ▼                       │
┌───────┐ ┌───────┐ ┌───────┐        │
│Approve│ │Feedback│ │Reject │        │
└───┬───┘ └───┬───┘ └───┬───┘        │
    │         │         │             │
    ▼         │         ▼             │
┌───────┐     │     ┌───────┐        │
│Remove │     │     │Close  │        │
│label  │     │     │Issue  │        │
└───┬───┘     │     └───────┘        │
    │         │                       │
    ▼         └───────────────────────┘
┌─────────────────┐
│  Enhancement    │
│  Workflow       │
│  Implements     │
└─────────────────┘
```

## Listing Proposals

```bash
# List all pending proposals
gh issue list --state open --label "proposal" --json number,title,createdAt

# View proposal details
gh issue view <number>
```

## Human Actions

### Approve a Proposal

To approve and allow automated implementation:

```bash
gh issue edit <issue_number> --remove-label "proposal"
```

Once the `proposal` label is removed, the enhancement workflow will pick it up.

### Provide Feedback

Comment on the issue with feedback:

```bash
gh issue comment <issue_number> --body "Please consider:
- [Feedback point 1]
- [Feedback point 2]"
```

### Reject a Proposal

```bash
gh issue close <issue_number> --comment "Rejected: [reason for rejection]"
```

## Important Rules

1. **NEVER auto-implement proposals** - They require human approval
2. **Check for proposal label** before implementing any enhancement
3. **Inform users** about pending proposals
4. **Continue working** on bugs while proposals await approval
5. **Create new proposals** only when no other work exists
