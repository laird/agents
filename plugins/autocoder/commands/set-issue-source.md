# Set Issue Source

Switch the configured issue backend. Optionally migrates existing issues.

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
   - Always offer: `jira` (Jira project via REST API)
   - Always offer: `ado` (Azure DevOps work items via REST API)
   - Offer `github` only if `git remote -v | grep -q "github.com"`
   - Offer any custom backend found in `.autocoder.json`'s `issueBackend` key

3. Ask: "Switch to which source? [file/github/jira/ado]"

   If the user picks `jira`, collect the non-secret connection settings and
   store them under a `jira` object in `.autocoder.json`. Secrets
   (`JIRA_EMAIL` + `JIRA_API_TOKEN`, or `JIRA_AUTH_HEADER` for a Server/DC
   personal access token) are **never** written to the repo — they are read
   from the environment at runtime.

```bash
# jira → collect base URL + project key (non-secret; safe to commit)
if [ "$NEW_SOURCE" = "jira" ]; then
  read -r -p "Jira base URL (e.g. https://acme.atlassian.net): " JIRA_URL
  read -r -p "Jira project key (e.g. ENG): " JIRA_PROJ
  python3 -c "
import json, os
path = '$AUTOCODER_JSON'
d = json.load(open(path)) if os.path.exists(path) else {}
d.setdefault('jira', {})
d['jira']['baseUrl'] = '$JIRA_URL'
d['jira']['project'] = '$JIRA_PROJ'
json.dump(d, open(path, 'w'), indent=2)
"
  echo "ℹ️  Export credentials before running agents:"
  echo "    export JIRA_EMAIL=you@acme.com JIRA_API_TOKEN=<token>"
  echo "    (or, for Server/DC:  export JIRA_AUTH_HEADER='Bearer <PAT>')"
fi

# ado → collect org URL + project (non-secret; safe to commit)
if [ "$NEW_SOURCE" = "ado" ]; then
  read -r -p "Azure DevOps org URL (e.g. https://dev.azure.com/myorg): " ADO_URL
  read -r -p "Azure DevOps project name: " ADO_PROJ
  python3 -c "
import json, os
path = '$AUTOCODER_JSON'
d = json.load(open(path)) if os.path.exists(path) else {}
d.setdefault('ado', {})
d['ado']['orgUrl'] = '$ADO_URL'
d['ado']['project'] = '$ADO_PROJ'
json.dump(d, open(path, 'w'), indent=2)
"
  echo "ℹ️  Export the PAT before running agents (never commit it):"
  echo "    export ADO_PAT=<personal access token with Work Items read/write>"
fi
```

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
