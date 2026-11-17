# Close Issue

Resolve and close an issue with an optional closing comment.

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
    if [ -f "$d/issue-fns.sh" ] && [ -f "$d/fix-loop-gate.sh" ]; then echo "$d"; exit 0; fi
  done
  # Fallback: the installed plugin. Only <ver>/scripts is a complete tree;
  # <ver>/skills/autocoder/scripts is a subset that sorts after it (#142).
  # Rank by the <ver> directory alone, not the whole path: with two marketplaces
  # in the cache, a whole-path sort lets the marketplace name decide (#201).
  find "$HOME/.claude/plugins/cache" -type d -name "scripts" -path "*/autocoder/*" -not -path "*/skills/*" 2>/dev/null \
    | while read -r d; do if [ -f "$d/issue-fns.sh" ] && [ -f "$d/fix-loop-gate.sh" ]; then echo "$d"; fi; done \
    | awk -F/ '{print $(NF-1) "\t" $0}' | sort -V -t$'\t' -k1,1 | tail -1 | cut -f2-
)
if [ ! -f "${SCRIPT_DIR}/issue-fns.sh" ]; then
  echo "autocoder: cannot locate issue-fns.sh (resolved SCRIPT_DIR='${SCRIPT_DIR}')" >&2
  exit 1
fi
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
