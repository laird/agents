# List Issues Needing Design

Display all open issues that require design work before implementation. Uses the configured issue source (file or GitHub).

## Usage

```bash
/list-needs-design
```

## What This Does

Lists all open issues with the `needs-design` label, showing:
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

echo "🎨 Fetching issues needing design..."
echo ""

# Ensure the needs-design label exists (GitHub backend only)
if [ "$ISSUE_SOURCE" = "github" ]; then
  if ! gh label list --json name --jq '.[].name' 2>/dev/null | grep -qFx "needs-design"; then
    echo "Creating 'needs-design' label..."
    gh label create "needs-design" --description "Issue requires design/architecture work before implementation" --color "7057ff" 2>/dev/null || true
  fi
fi

# Fetch all open issues with the needs-design label
issue_list --state blocked --label "needs-design" --limit 50 > /tmp/needs-design.json

ISSUE_COUNT=$(cat /tmp/needs-design.json | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")

if [ "$ISSUE_COUNT" -eq 0 ]; then
  echo "✅ No issues need design work!"
  echo ""
  echo "All issues requiring design have been addressed."
  echo "Use '/update-issue <number> --add-label needs-design' to flag an issue for design."
  exit 0
fi

echo "═══════════════════════════════════════════════════════════════"
echo "                 ISSUES NEEDING DESIGN ($ISSUE_COUNT)"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Backend-specific view hint (no neutral slash command for single-issue view)
if [ "$ISSUE_SOURCE" = "file" ]; then
  VIEW_CMD_TMPL="cat \"${ISSUE_DIR_PATH}/{num}.md\""
else
  VIEW_CMD_TMPL="gh issue view {num}"
fi

# Display each issue
cat /tmp/needs-design.json | VIEW_CMD_TMPL="$VIEW_CMD_TMPL" python3 -c "
import json
import os
import sys
from datetime import datetime

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
    print(f'│    Brainstorm:    /brainstorm-issue {num}')
    print(f'│    Mark Complete: /update-issue {num} --remove-label \"needs-design\"')
    print(f'│    View:          {view_cmd_tmpl.format(num=num)}')
    print(f'└────────────────────────────────────────────────────────────')
    print()
"

echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "📖 Quick Reference:"
echo ""
echo "  Brainstorm design for an issue:"
echo "    /brainstorm-issue <number>"
echo ""
echo "  Mark design as complete:"
echo "    /update-issue <number> --remove-label \"needs-design\""
echo ""
echo "  Flag another issue for design:"
echo "    /update-issue <number> --add-label \"needs-design\""
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

## Design Workflow

```
┌─────────────────┐
│  Issue Created  │
│  or Identified  │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  Flag for       │
│  Design Work    │
│  (needs-design) │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  Review Issues  │◄──────────────────┐
│/list-needs-design                   │
└────────┬────────┘                   │
         │                            │
    ┌────┴────┐                       │
    │         │                       │
    ▼         ▼                       │
┌───────┐ ┌───────────┐              │
│Brainstorm│ │Skip/Defer│              │
└───┬───┘ └─────┬─────┘              │
    │           │                     │
    ▼           │                     │
┌───────────┐   │                     │
│Design     │   │                     │
│Complete   │   │                     │
└───┬───────┘   │                     │
    │           │                     │
    ▼           │                     │
┌───────────┐   │                     │
│Remove     │   │                     │
│Label      │   │                     │
└───┬───────┘   │                     │
    │           └─────────────────────┘
    ▼
┌─────────────────┐
│  Ready for      │
│  Implementation │
└─────────────────┘
```

## See Also

- `/brainstorm-issue` - Use AI to brainstorm design for an issue
- `/list-needs-feedback` - List issues needing feedback
- `/list-proposals` - List AI-generated proposals awaiting approval
- `/fix` - Autonomous issue resolution
