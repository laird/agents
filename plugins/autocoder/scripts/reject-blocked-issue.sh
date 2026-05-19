#!/bin/bash
# Reject a blocked issue by closing it with a rejection comment
# Usage: reject-blocked-issue.sh <issue_number> <rejection_reason>

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/issue-fns.sh"

if [ $# -lt 2 ]; then
  echo "Usage: reject-blocked-issue.sh <issue_number> <rejection_reason>" >&2
  exit 1
fi

ISSUE_NUM="$1"
REJECT_REASON="$2"

# Close issue with rejection comment
issue_close "$ISSUE_NUM" --comment "❌ **Rejected**

**Reason**: ${REJECT_REASON}

**Rejected By**: Human review via /review-blocked

🤖 Rejected via automated review workflow"

echo "❌ Issue #${ISSUE_NUM} rejected and closed."
