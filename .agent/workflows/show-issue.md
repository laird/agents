# Show Issue

Pretty-print a single issue regardless of which bucket it lives in. Hides the
underlying file path so callers don't need to know whether an issue is
`open/`, `working/`, `blocked/`, or `closed/`.

## Setup

```bash
SCRIPT_DIR=$(
  if [ -d "$(pwd)/.agent/scripts" ]; then echo "$(pwd)/.agent/scripts"
  elif [ -d "$(pwd)/plugins/autocoder/scripts" ]; then echo "$(pwd)/plugins/autocoder/scripts"
  elif [ -d "$(pwd)/.claude-plugin/plugins/autocoder/scripts" ]; then echo "$(pwd)/.claude-plugin/plugins/autocoder/scripts"
  else find "$HOME/.agent/plugins/cache" -type d -name "scripts" -path "*/autocoder/*" 2>/dev/null | sort -V | tail -1
  fi
)
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
