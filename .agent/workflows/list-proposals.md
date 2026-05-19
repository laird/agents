# List Pending Proposals

Display all AI-generated enhancement proposals awaiting human review and approval.

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

## Instructions

```bash
SCRIPT_DIR=$(
  if [ -d "$(pwd)/plugins/autocoder/scripts" ]; then echo "$(pwd)/plugins/autocoder/scripts"
  elif [ -d "$(pwd)/.claude-plugin/plugins/autocoder/scripts" ]; then echo "$(pwd)/.claude-plugin/plugins/autocoder/scripts"
  else find "$HOME/.claude/plugins/cache" -type d -name "scripts" -path "*/autocoder/*" 2>/dev/null | sort -V | tail -1
  fi
)
source "${SCRIPT_DIR}/issue-fns.sh"

echo "📋 Fetching pending proposals..."
echo ""

# Fetch all open issues with the proposal label
issue_list --state open --label "proposal" --limit 50 > /tmp/proposals.json

PROPOSAL_COUNT=$(cat /tmp/proposals.json | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")

if [ "$PROPOSAL_COUNT" -eq 0 ]; then
  echo "✅ No pending proposals!"
  echo ""
  echo "All AI-generated proposals have been reviewed."
  echo "Run '/fix' to generate new proposals if needed."
  exit 0
fi

echo "═══════════════════════════════════════════════════════════════"
echo "                    PENDING PROPOSALS ($PROPOSAL_COUNT)"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Display each proposal
cat /tmp/proposals.json | python3 -c "
import json
import sys
from datetime import datetime

proposals = json.load(sys.stdin)

for p in proposals:
    num = p['number']
    title = p['title']
    created = p.get('createdAt', 'Unknown')[:10]
    body = p.get('body', '')[:200].replace('\n', ' ')

    # Get priority label
    priority = 'P?'
    for label in p.get('labels', []):
        if label['name'] in ['P0', 'P1', 'P2', 'P3']:
            priority = label['name']
            break

    print(f'┌─ #{num} [{priority}] {title}')
    print(f'│  Created: {created}')
    print(f'│  {body}...')
    print(f'│')
    print(f'│  Actions:')
    print(f'│    Approve:  /approve-proposal {num}')
    print(f'│    Feedback: gh issue comment {num} --body \"Your feedback here\"')
    print(f'│    Reject:   gh issue close {num} --comment \"Rejected: reason\"')
    print(f'│    View:     gh issue view {num}')
    print(f'└────────────────────────────────────────────────────────────')
    print()
"

echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "📖 Quick Reference:"
echo ""
echo "  Approve a proposal (allow implementation):"
echo "    /approve-proposal <number>"
echo ""
echo "  Provide feedback (AI will refine):"
echo "    gh issue comment <number> --body \"Your feedback\""
echo "    /refine-proposal <number>"
echo ""
echo "  Reject a proposal:"
echo "    gh issue close <number> --comment \"Rejected: reason\""
echo ""
echo "  View full proposal details:"
echo "    gh issue view <number>"
echo ""
echo "═══════════════════════════════════════════════════════════════"
```

## Proposal Workflow

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
│  /list-proposals│                   │
└────────┬────────┘                   │
         │                            │
    ┌────┴────┐                       │
    │         │                       │
    ▼         ▼                       │
┌───────┐ ┌───────┐ ┌───────┐        │
│Approve│ │Feedback│ │Reject │        │
└───┬───┘ └───┬───┘ └───┬───┘        │
    │         │         │             │
    ▼         ▼         ▼             │
┌───────┐ ┌───────┐ ┌───────┐        │
│Remove │ │Comment│ │Close  │        │
│label  │ │+Refine│ │Issue  │        │
└───┬───┘ └───┬───┘ └───────┘        │
    │         │                       │
    ▼         └───────────────────────┘
┌─────────────────┐
│  /fix    │
│  Implements     │
└─────────────────┘
```

## See Also

- `/approve-proposal` - Approve a proposal for implementation
- `/fix` - Autonomous issue resolution (creates proposals)
- `/refine-proposal` - Incorporate feedback into a proposal
