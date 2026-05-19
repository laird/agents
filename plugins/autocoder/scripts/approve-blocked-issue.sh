#!/bin/bash
# Approve a blocked issue by removing blocking label and adding approval comment
# Usage: approve-blocked-issue.sh <issue_number> <blocking_label> <approach_description>

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/issue-fns.sh"

if [ $# -lt 3 ]; then
  echo "Usage: approve-blocked-issue.sh <issue_number> <blocking_label> <approach_description>" >&2
  exit 1
fi

ISSUE_NUM="$1"
BLOCKING_LABEL="$2"
APPROACH_DESCRIPTION="$3"

# Remove blocking label
issue_update "$ISSUE_NUM" --remove-label "$BLOCKING_LABEL"

# Add approval comment
issue_comment "$ISSUE_NUM" --body "✅ **Approved for Implementation**

**Decision**: ${APPROACH_DESCRIPTION}

**Approved By**: Human review via /review-blocked

**Next Steps**: Fix-loop will implement this approach on its next iteration.

🤖 Approved via automated review workflow"

echo "✅ Issue #${ISSUE_NUM} approved! Blocking label '${BLOCKING_LABEL}' removed."
