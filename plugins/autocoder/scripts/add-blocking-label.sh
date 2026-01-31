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

for label in "needs-approval:Architectural decisions, major changes, security implications:e99695" "needs-design:Requirements unclear, multiple approaches, needs design:fbca04" "needs-clarification:Incomplete information, missing context, questions needed:d4c5f9" "too-complex:Beyond autonomous capability, requires deep expertise:b60205"; do
  IFS=':' read -r name desc color <<< "$label"
  if ! echo "$EXISTING_LABELS" | grep -qFx "$name"; then
    gh label create "$name" --description "$desc" --color "$color" 2>/dev/null || true
  fi
done

# Add blocking label
gh issue edit "$ISSUE_NUM" --add-label "$BLOCKING_LABEL"

# Add comment explaining why it's blocked
gh issue comment "$ISSUE_NUM" --body "🚫 **Blocked - Requires Human Input**

**Blocking Reason**: ${BLOCKING_LABEL}

**Details**: ${BLOCKING_REASON}

**Next Steps**:
- Use \`/review-blocked\` in a separate session to review and approve this issue
- Once approved (blocking label removed), fix-loop will automatically work on this issue

**Why This Was Blocked**: ${BLOCKING_REASON}

Moving to next priority issue.

🤖 Autonomous fix workflow"

# Remove 'working' label to release the issue
gh issue edit "$ISSUE_NUM" --remove-label "working" 2>/dev/null || true

echo "🚫 Issue #${ISSUE_NUM} blocked with label: ${BLOCKING_LABEL}"
