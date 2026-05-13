#!/bin/bash
# Add a blocking label to an issue with explanation comment
# Usage: add-blocking-label.sh <issue_number> <blocking_label> <reason>

set -e

if [ $# -lt 3 ]; then
  echo "Usage: add-blocking-label.sh <issue_number> <blocking_label> <reason>" >&2
  exit 1
fi

ISSUE_NUM="$1"
BLOCKING_LABEL="$2"
BLOCKING_REASON="$3"

# Ensure blocking labels exist
EXISTING_LABELS=$(gh label list --json name --jq '.[].name' 2>/dev/null || echo "")

for label in "needs-approval:Architectural decisions, major changes, security implications:e99695" "needs-design:Requirements unclear, multiple approaches, needs design:fbca04" "needs-clarification:Incomplete information, missing context, questions needed:d4c5f9" "too-complex:Beyond autonomous capability, requires deep expertise:b60205" "future:Idea for future consideration, not ready for implementation:bfd4f2"; do
  IFS=':' read -r name desc color <<< "$label"
  if ! echo "$EXISTING_LABELS" | grep -qFx "$name"; then
    gh label create "$name" --description "$desc" --color "$color" 2>/dev/null || true
  fi
done

# Reject placeholder-laden reasons (especially important for needs-design).
# A reason like "Need design phase to evaluate: [list options]" means the worker
# left the template unfilled. Refuse it so the worker has to write real content.
if echo "$BLOCKING_REASON" | grep -qE '\[[a-z][^]]*\]'; then
  echo "ERROR: BLOCKING_REASON contains unfilled placeholder text: $BLOCKING_REASON" >&2
  echo "  Fill in concrete details before adding the blocking label." >&2
  exit 2
fi

# Add blocking label
gh issue edit "$ISSUE_NUM" --add-label "$BLOCKING_LABEL"

# Build the comment body. needs-design gets a specialized template that
# explicitly captures *what* needs designing.
if [ "$BLOCKING_LABEL" = "needs-design" ]; then
  COMMENT_BODY="🎨 **Blocked — Needs Design**

This issue cannot be implemented autonomously because the design space is not yet resolved. A human designer/architect needs to make decisions before a worker can proceed.

### What needs design

${BLOCKING_REASON}

### Next steps

- Resolve the design questions above (in this comment thread, an ADR, or a spec doc).
- Link the design artifact in a follow-up comment.
- Remove the \`needs-design\` label once decisions are recorded — autocoder will then pick the issue up.

🤖 Autonomous fix workflow"
else
  COMMENT_BODY="🚫 **Blocked - Requires Human Input**

**Blocking Reason**: ${BLOCKING_LABEL}

**Details**: ${BLOCKING_REASON}

**Next Steps**:
- Use \`/review-blocked\` in a separate session to review and approve this issue
- Once approved (blocking label removed), fix-loop will automatically work on this issue

Moving to next priority issue.

🤖 Autonomous fix workflow"
fi

gh issue comment "$ISSUE_NUM" --body "$COMMENT_BODY"

# Remove 'working' label to release the issue
gh issue edit "$ISSUE_NUM" --remove-label "working" 2>/dev/null || true

echo "🚫 Issue #${ISSUE_NUM} blocked with label: ${BLOCKING_LABEL}"
