# Proposal Management Workflow

**Purpose**: Create AI-generated enhancement proposals for human approval

## Overview

AI-generated enhancements are NOT auto-implemented. They're created as **proposals** with a `proposal` label, requiring human review before implementation.

## When to Create Proposals

- All P0-P3 bugs resolved
- All approved enhancements implemented
- Regression tests pass

## Create Proposal

```bash
gh issue create \
  --label "enhancement,proposal,P3" \
  --title "Proposal: {description}" \
  --body "$(cat <<'EOF'
## Proposed Enhancement
{what this accomplishes}

## Rationale
{why valuable - metrics, user impact, maintainability}

## Implementation Plan
- [ ] Phase 1: {tasks}
- [ ] Phase 2: {tasks}
- [ ] Verification: tests, docs

## Success Criteria
- [ ] Existing tests pass
- [ ] New tests added
- [ ] No performance regression

## Complexity
{Simple | Medium | Complex}

---
**Status**: Awaiting Human Approval

**Approve**: `gh issue edit {number} --remove-label "proposal"`
**Reject**: `gh issue close {number} --comment "Rejected: {reason}"`

Proposed by autocoder agent
EOF
)"
```

## Lifecycle

```
AI Creates Proposal (with proposal tag)
         ↓
Human Reviews → Approve (remove label) → Enhancement Workflow
             → Feedback → AI Revises
             → Reject → Close Issue
```

## Commands

```bash
# List pending proposals
gh issue list --state open --label "proposal"

# Approve
gh issue edit {number} --remove-label "proposal"

# Reject
gh issue close {number} --comment "Rejected: {reason}"
```

## Rules

1. NEVER auto-implement proposals
2. Check for `proposal` label before implementing any enhancement
3. Continue working on bugs while proposals await approval
