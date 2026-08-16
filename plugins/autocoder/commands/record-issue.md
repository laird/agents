# Record Issue

Create a new issue in the configured issue backend (GitHub Issues or file backend).

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
/record-issue
/record-issue "Fix the login bug"
/record-issue --priority P1 --label bug
```

## Steps

1. Parse arguments. Supported flags:
   - Positional: title string
   - `--priority P0|P1|P2|P3`
   - `--label <name>` (may be repeated)

2. If title not provided, ask: "What is the title of this issue?"

3. Ask for a description (body). If the user declines, use an empty string.

4. If priority not provided, ask: "Priority? [P0/P1/P2/P3, default P2]" — default `P2`.

5. Create the issue:

```bash
RESULT=$(issue_create --title "$TITLE" --body "$BODY" --priority "$PRIORITY" ${LABEL_FLAGS})
ISSUE_NUM=$(echo "$RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin)['number'])")
echo "✅ Issue #${ISSUE_NUM} created: ${TITLE}"
```

Where `LABEL_FLAGS` expands as `--label bug --label P1` etc. for each label provided.

6. Confirm to the user: "Issue #N created."

## See Also

- `/list-issues` - List open issues
- `/update-issue` - Modify an existing issue
- `/close-issue` - Close an issue
