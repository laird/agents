# Show Issue

Pretty-print a single issue regardless of which bucket it lives in. Hides the
underlying file path so callers don't need to know whether an issue is
`open/`, `working/`, `blocked/`, or `closed/`.

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
/show-issue 42
```

## Steps

1. Parse the first positional argument as the issue number. Reject if missing or non-numeric.

2. Fetch and display the issue:

```bash
issue_json=$(issue_get "$ISSUE_NUM")
rc=$?
case $rc in
  0) ;;
  1) echo "Issue #$ISSUE_NUM not found"; exit 1 ;;
  *) echo "Backend error fetching issue #$ISSUE_NUM"; exit 1 ;;
esac
echo "$issue_json" | jq -r '
  "═══════════════════════════════════════════════════════════════",
  "#\(.number)  \(.title)",
  "State: \(.state)",
  "Labels: " + (.labels | map(.name) | join(", ")),
  "═══════════════════════════════════════════════════════════════",
  "",
  .body,
  ""
'
```

The output is identical across backends — the path detail (file backend's
bucket, github's URL, etc.) stays hidden.

## See Also

- `/list-issues` — list issues by state/label
- `/update-issue` — modify an issue's labels or status
- `/close-issue` — close an issue
