# Update Issue

Modify an existing issue's labels, status, or priority.

## Setup

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../scripts" 2>/dev/null && pwd || echo "plugins/autocoder/scripts")"
source "${SCRIPT_DIR}/issue-fns.sh"
```

## Usage

```
/update-issue 42 --add-label needs-design
/update-issue 42 --remove-label working --add-label needs-approval
/update-issue 42 --priority P0
/update-issue 42 --status closed
```

## Steps

1. Parse arguments:
   - First positional: issue number (required)
   - `--add-label <name>` — add a label
   - `--remove-label <name>` — remove a label
   - `--priority P0|P1|P2|P3` — translates to `--add-label <priority>`
   - `--status open|working|closed`

2. Build the `issue_update` call from the parsed flags. Multiple flags may be combined.

3. Run the update:

```bash
issue_update "$ISSUE_NUM" $UPDATE_FLAGS
```

Where `UPDATE_FLAGS` expands to the parsed flag set (e.g., `--add-label needs-design --remove-label working`).

4. Confirm: "Issue #N updated."

## See Also

- `/record-issue` - Create a new issue
- `/close-issue` - Close an issue
- `/list-issues` - List open issues
