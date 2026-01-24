# List Issues Needing Feedback

Display all open GitHub issues that require human feedback or clarification.

## Usage

```bash
/list-needs-feedback
```

## What This Does

Lists all open GitHub issues with the `needs-feedback` label, showing:
- Issue number and title
- Priority level (P0-P3)
- Creation date
- Brief description

## Instructions

```bash
echo "💬 Fetching issues needing feedback..."
echo ""

# Ensure the needs-feedback label exists
if ! gh label list --json name --jq '.[].name' 2>/dev/null | grep -qFx "needs-feedback"; then
  echo "Creating 'needs-feedback' label..."
  gh label create "needs-feedback" --description "Issue requires human feedback or clarification" --color "d876e3" 2>/dev/null || true
fi

# Fetch all open issues with the needs-feedback label
gh issue list --state open --label "needs-feedback" --json number,title,body,labels,createdAt --limit 50 > /tmp/needs-feedback.json

ISSUE_COUNT=$(cat /tmp/needs-feedback.json | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")

if [ "$ISSUE_COUNT" -eq 0 ]; then
  echo "✅ No issues need feedback!"
  echo ""
  echo "All issues requiring feedback have been addressed."
  echo "Use 'gh issue edit <number> --add-label needs-feedback' to flag an issue."
  exit 0
fi

echo "═══════════════════════════════════════════════════════════════"
echo "                ISSUES NEEDING FEEDBACK ($ISSUE_COUNT)"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Display each issue
cat /tmp/needs-feedback.json | python3 -c "
import json
import sys
from datetime import datetime

issues = json.load(sys.stdin)

for i in issues:
    num = i['number']
    title = i['title']
    created = i.get('createdAt', 'Unknown')[:10]
    body = i.get('body', '')[:200].replace('\n', ' ')

    # Get priority label
    priority = 'P?'
    for label in i.get('labels', []):
        if label['name'] in ['P0', 'P1', 'P2', 'P3']:
            priority = label['name']
            break

    print(f'┌─ #{num} [{priority}] {title}')
    print(f'│  Created: {created}')
    print(f'│  {body}...')
    print(f'│')
    print(f'│  Actions:')
    print(f'│    Add Feedback:  gh issue comment {num} --body \"Your feedback here\"')
    print(f'│    Mark Resolved: gh issue edit {num} --remove-label \"needs-feedback\"')
    print(f'│    View:          gh issue view {num}')
    print(f'└────────────────────────────────────────────────────────────')
    print()
"

echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "📖 Quick Reference:"
echo ""
echo "  Provide feedback on an issue:"
echo "    gh issue comment <number> --body \"Your feedback\""
echo ""
echo "  Mark feedback as resolved:"
echo "    gh issue edit <number> --remove-label \"needs-feedback\""
echo ""
echo "  Flag another issue for feedback:"
echo "    gh issue edit <number> --add-label \"needs-feedback\""
echo ""
echo "  View full issue details:"
echo "    gh issue view <number>"
echo ""
echo "═══════════════════════════════════════════════════════════════"
```

## Feedback Workflow

```
┌─────────────────┐
│  AI or Human    │
│  Flags Issue    │
│  for Feedback   │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  Issue Tagged   │
│  needs-feedback │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  Human Reviews  │◄──────────────────┐
│/list-needs-feedback                 │
└────────┬────────┘                   │
         │                            │
    ┌────┴────┐                       │
    │         │                       │
    ▼         ▼                       │
┌───────┐ ┌───────┐                  │
│Provide│ │Defer  │                  │
│Feedback│ │       │                  │
└───┬───┘ └───┬───┘                  │
    │         │                       │
    ▼         └───────────────────────┘
┌───────────┐
│  Remove   │
│  Label    │
└───┬───────┘
    │
    ▼
┌─────────────────┐
│  AI Can         │
│  Continue Work  │
└─────────────────┘
```

## Common Feedback Scenarios

| Scenario | Action |
|----------|--------|
| Clarification needed | Comment with answer, remove label |
| Decision required | Comment with decision, remove label |
| More info needed from requester | Leave label, @ mention requester |
| Issue is unclear | Comment asking for clarification |
| Issue is out of scope | Close issue with explanation |

## See Also

- `/list-needs-design` - List issues needing design work
- `/list-proposals` - List AI-generated proposals awaiting approval
- `/brainstorm-issue` - Use AI to brainstorm an issue
- `/fix` - Autonomous issue resolution
