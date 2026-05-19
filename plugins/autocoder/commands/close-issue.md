# Close Issue

Resolve and close an issue with an optional closing comment.

## Setup

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../scripts" 2>/dev/null && pwd || echo "plugins/autocoder/scripts")"
source "${SCRIPT_DIR}/issue-fns.sh"
```

## Usage

```
/close-issue 42
/close-issue 42 "Fixed in PR #87 by extracting auth module"
```

## Steps

1. Parse arguments:
   - First positional: issue number (required)
   - Optional second positional: closing comment

2. Close the issue:

```bash
if [ -n "$COMMENT" ]; then
  issue_close "$ISSUE_NUM" --comment "$COMMENT"
else
  issue_close "$ISSUE_NUM"
fi
```

3. Confirm: "Issue #N closed."

## See Also

- `/record-issue` - Create a new issue
- `/update-issue` - Modify an existing issue
- `/list-issues` - List open issues
