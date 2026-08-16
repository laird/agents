# List Issues

List open issues, optionally filtered by label or priority.

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
  find "$HOME/.agent/plugins/cache" -type d -name "scripts" -path "*/autocoder/*" 2>/dev/null | sort -V | tail -1
)
if [ ! -f "${SCRIPT_DIR}/issue-fns.sh" ]; then
  echo "autocoder: cannot locate issue-fns.sh (resolved SCRIPT_DIR='${SCRIPT_DIR}')" >&2
  exit 1
fi
source "${SCRIPT_DIR}/issue-fns.sh"
```

## Usage

```
/list-issues
/list-issues --label needs-design
/list-issues --priority P0
/list-issues --state closed
```

## Steps

1. Parse arguments:
   - `--label <name>` — filter by label
   - `--priority P0|P1|P2|P3` — filter by priority label
   - `--state open|closed` — default `open`
   - `--limit N` — default 50

2. Fetch issues:

```bash
ISSUES=$(issue_list --state "${STATE:-open}" --limit "${LIMIT:-50}" ${LABEL_FLAGS})
```

Where `LABEL_FLAGS` is `--label <name>` for the label or priority provided.

3. Format and display. For each issue in the JSON array:

```bash
echo "$ISSUES" | python3 -c "
import json, sys
issues = json.load(sys.stdin)
if not issues:
    print('No issues found.')
    sys.exit(0)
for i in issues:
    labels = ', '.join(l['name'] for l in i.get('labels', []))
    print(f\"#{i['number']} [{labels}] {i['title']}\")
print(f'\n{len(issues)} issue(s).')
"
```

## Aliases

- `/list-needs-design` = `/list-issues --label needs-design`
- `/list-needs-feedback` = `/list-issues --label needs-feedback`

## See Also

- `/record-issue` - Create a new issue
- `/update-issue` - Modify an existing issue
- `/close-issue` - Close an issue
- `/set-issue-source` - Switch the issue backend
