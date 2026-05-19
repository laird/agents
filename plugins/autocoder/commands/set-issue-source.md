# Set Issue Source

Switch the configured issue backend. Optionally migrates existing issues.

## Setup

```bash
SCRIPT_DIR=$(
  if [ -d "$(pwd)/plugins/autocoder/scripts" ]; then echo "$(pwd)/plugins/autocoder/scripts"
  elif [ -d "$(pwd)/.claude-plugin/plugins/autocoder/scripts" ]; then echo "$(pwd)/.claude-plugin/plugins/autocoder/scripts"
  else find "$HOME/.claude/plugins/cache" -type d -name "scripts" -path "*/autocoder/*" 2>/dev/null | sort -V | tail -1
  fi
)
source "${SCRIPT_DIR}/issue-fns.sh"
MAIN_WORKTREE=$(git worktree list --porcelain | grep -m1 "^worktree" | cut -d' ' -f2)
AUTOCODER_JSON="${MAIN_WORKTREE}/.autocoder.json"
```

## Steps

1. Show the current source:

```bash
CURRENT=$(python3 -c "
import json, os
path = '$AUTOCODER_JSON'
d = json.load(open(path)) if os.path.exists(path) else {}
print(d.get('issueSource', 'not configured'))
")
echo "Current issue source: $CURRENT"
```

2. List available sources:
   - Always offer: `file` (`.issues/` directory)
   - Offer `github` only if `git remote -v | grep -q "github.com"`
   - Offer any custom backend found in `.autocoder.json`'s `issueBackend` key

3. Ask: "Switch to which source? [file/github]"

4. If the user selects a different source, offer migration:

```bash
# github → file
if [ "$CURRENT" = "github" ] && [ "$NEW_SOURCE" = "file" ]; then
  read -r -p "Import open GitHub issues to .issues/? [Y/n] " MIGRATE
  if [[ "${MIGRATE:-Y}" =~ ^[Yy]$ ]]; then
    mkdir -p "${MAIN_WORKTREE}/.issues"
    ISSUE_DIR_PATH="${MAIN_WORKTREE}/.issues" python3 "${SCRIPT_DIR}/issues-file.py" import-from-gh
    echo "✅ GitHub issues imported to .issues/"
  fi
fi

# file → github
if [ "$CURRENT" = "file" ] && [ "$NEW_SOURCE" = "github" ]; then
  read -r -p "Export open .issues/ entries to GitHub Issues? [Y/n] " MIGRATE
  if [[ "${MIGRATE:-Y}" =~ ^[Yy]$ ]]; then
    ISSUE_DIR_PATH="${ISSUE_DIR_PATH}" python3 "${SCRIPT_DIR}/issues-file.py" export-to-gh
    echo "✅ Issues exported to GitHub"
  fi
fi
```

5. Update `.autocoder.json`:

```bash
python3 -c "
import json, os
path = '$AUTOCODER_JSON'
d = json.load(open(path)) if os.path.exists(path) else {}
d['issueSource'] = '$NEW_SOURCE'
if '$NEW_SOURCE' == 'file':
    d['issueDir'] = '${MAIN_WORKTREE}/.issues'
json.dump(d, open(path, 'w'), indent=2)
"
echo "✅ Issue source switched to: $NEW_SOURCE"
```

6. Confirm the switch is complete.

## See Also

- `/list-issues` - List issues in the current backend
- `/record-issue` - Create a new issue
