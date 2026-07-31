# List Issues Needing Feedback

Display all open issues that require human feedback or clarification. Uses the configured issue source (file or GitHub).

## Usage

```bash
/list-needs-feedback
```

## What This Does

Lists all open issues with the `needs-feedback` label, showing:
- Issue number and title
- Priority level (P0-P3)
- Creation date
- Brief description

## Instructions

```bash
SCRIPT_DIR=$(
  if [ -d "$(pwd)/.agent/scripts" ]; then echo "$(pwd)/.agent/scripts"
  elif [ -d "$(pwd)/plugins/autocoder/scripts" ]; then echo "$(pwd)/plugins/autocoder/scripts"
  elif [ -d "$(pwd)/.claude-plugin/plugins/autocoder/scripts" ]; then echo "$(pwd)/.claude-plugin/plugins/autocoder/scripts"
  else find "$HOME/.agent/plugins/cache" -type d -name "scripts" -path "*/autocoder/*" 2>/dev/null | sort -V | tail -1
  fi
)
source "${SCRIPT_DIR}/issue-fns.sh"

echo "💬 Fetching issues needing feedback..."
echo ""

# Ensure the needs-feedback label exists (GitHub backend only)
if [ "$ISSUE_SOURCE" = "github" ]; then
  if ! gh label list --json name --jq '.[].name' 2>/dev/null | grep -qFx "needs-feedback"; then
    echo "Creating 'needs-feedback' label..."
    gh label create "needs-feedback" --description "Issue requires human feedback or clarification" --color "d876e3" 2>/dev/null || true
  fi
fi

# Fetch all open issues with the needs-feedback label
issue_list --state blocked --label "needs-feedback" --limit 50 > /tmp/needs-feedback.json

ISSUE_COUNT=$(cat /tmp/needs-feedback.json | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")

if [ "$ISSUE_COUNT" -eq 0 ]; then
  echo "✅ No issues need feedback!"
  echo ""
  echo "All issues requiring feedback have been addressed."
  echo "Use '/update-issue <number> --add-label needs-feedback' to flag an issue."
  exit 0
fi

echo "═══════════════════════════════════════════════════════════════"
echo "                ISSUES NEEDING FEEDBACK ($ISSUE_COUNT)"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Backend-specific hints (no neutral slash commands for comment / single-issue view)
if [ "$ISSUE_SOURCE" = "file" ]; then
  COMMENT_CMD_TMPL="(echo '## Comment'; echo '\"<text>\"') >> \"${ISSUE_DIR_PATH}/{num}.md\""
  VIEW_CMD_TMPL="cat \"${ISSUE_DIR_PATH}/{num}.md\""
else
  COMMENT_CMD_TMPL="gh issue comment {num} --body \"<text>\""
  VIEW_CMD_TMPL="gh issue view {num}"
fi

# Display each issue
cat /tmp/needs-feedback.json | COMMENT_CMD_TMPL="$COMMENT_CMD_TMPL" VIEW_CMD_TMPL="$VIEW_CMD_TMPL" python3 -c "
import json
import os
import sys
from datetime import datetime

comment_cmd_tmpl = os.environ['COMMENT_CMD_TMPL']
view_cmd_tmpl = os.environ['VIEW_CMD_TMPL']
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
    print(f'│    Add Feedback:  {comment_cmd_tmpl.format(num=num)}')
    print(f'│    Mark Resolved: /update-issue {num} --remove-label \"needs-feedback\"')
    print(f'│    View:          {view_cmd_tmpl.format(num=num)}')
    print(f'└────────────────────────────────────────────────────────────')
    print()
"

echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "📖 Quick Reference:"
echo ""
echo "  Provide feedback on an issue:"
if [ "$ISSUE_SOURCE" = "file" ]; then
  echo "    Edit \"${ISSUE_DIR_PATH}/<number>.md\" and append your feedback"
else
  echo "    gh issue comment <number> --body \"Your feedback\""
fi
echo ""
echo "  Mark feedback as resolved:"
echo "    /update-issue <number> --remove-label \"needs-feedback\""
echo ""
echo "  Flag another issue for feedback:"
echo "    /update-issue <number> --add-label \"needs-feedback\""
echo ""
echo "  View full issue details:"
if [ "$ISSUE_SOURCE" = "file" ]; then
  echo "    cat \"${ISSUE_DIR_PATH}/<number>.md\""
else
  echo "    gh issue view <number>"
fi
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
- `/dev` - Autonomous issue resolution
