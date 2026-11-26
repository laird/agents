# Record Issue

Create a new issue in the configured issue backend (GitHub Issues or file backend).

## Setup

```bash
# Resolve SCRIPT_DIR — see scripts/README.md#script-dir
SCRIPT_DIR=$(
  for d in "$(pwd)/.agent/scripts" \
           "$(pwd)/plugins/autocoder/scripts" \
           "$(pwd)/.claude-plugin/plugins/autocoder/scripts"; do
    if [ -f "$d/issue-fns.sh" ]; then echo "$d"; exit 0; fi
  done
  # Fallback: the installed plugin. Only <ver>/scripts is a complete tree;
  # <ver>/skills/autocoder/scripts is a subset that sorts after it (#142).
  # Rank by the <ver> directory alone, not the whole path: with two marketplaces
  # in the cache, a whole-path sort lets the marketplace name decide (#201).
  found=$(
  find "$HOME/.agent/plugins/cache" -type d -name "scripts" -path "*/autocoder/*" -not -path "*/skills/*" 2>/dev/null \
    | while read -r d; do if [ -f "$d/issue-fns.sh" ]; then echo "$d"; fi; done \
    | awk -F/ '{print $(NF-1) "\t" $0}' | sort -V -t$'\t' -k1,1 | tail -1 | cut -f2-
  )
  if [ -n "$found" ]; then echo "$found"; exit 0; fi
  # Grok installs to ~/.grok/installed-plugins/<name>-<hash>/. The hash is in
  # the directory name, so the Claude cache glob */autocoder/* does not match.
  find "$HOME/.grok/installed-plugins" -type d -name "scripts" -path "*/autocoder-*/*" -not -path "*/skills/*" 2>/dev/null \
    | while read -r d; do if [ -f "$d/issue-fns.sh" ]; then echo "$d"; fi; done \
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
