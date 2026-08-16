# Update Issue

Modify an existing issue's labels, status, or priority.

## Setup

```bash
# Resolve the autocoder script directory. A project-local tree only wins if it is
# a COMPLETE override — i.e. it actually contains the file we are about to source.
# Testing for the directory alone let a stale vendored .agent/ or plugins/autocoder/
# tree, left behind by an old project import, shadow the installed plugin: the
# source below then failed and every issue_* call silently used the wrong backend.
SCRIPT_DIR=$(
  for d in "$(pwd)/.agent/scripts" \
           "$(pwd)/plugins/autocoder/scripts" \
           "$(pwd)/.claude-plugin/plugins/autocoder/scripts"; do
    if [ -f "$d/issue-fns.sh" ]; then echo "$d"; exit 0; fi
  done
  find "$HOME/.claude/plugins/cache" -type d -name "scripts" -path "*/autocoder/*" 2>/dev/null | sort -V | tail -1
)
if [ ! -f "${SCRIPT_DIR}/issue-fns.sh" ]; then
  echo "autocoder: cannot locate issue-fns.sh (resolved SCRIPT_DIR='${SCRIPT_DIR}')" >&2
  exit 1
fi
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
