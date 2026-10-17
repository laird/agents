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
  find "$HOME/.claude/plugins/cache" -type d -name "scripts" -path "*/autocoder/*" 2>/dev/null | sort -V | tail -1
)
if [ ! -f "${SCRIPT_DIR}/issue-fns.sh" ]; then
  echo "autocoder: cannot locate issue-fns.sh (resolved SCRIPT_DIR='${SCRIPT_DIR}')" >&2
  exit 1
fi
source "${SCRIPT_DIR}/issue-fns.sh"

# Stale-dispatcher guard: .agent/scripts may predate the dependency verbs.
if ! type issue_deps >/dev/null 2>&1; then
  SCRIPT_DIR=""
  for d in "$(pwd)/plugins/autocoder/scripts" "$(pwd)/.claude-plugin/plugins/autocoder/scripts" $(find "$HOME/.claude/plugins/cache" -maxdepth 4 -type d -name scripts -path "*autocoder*" 2>/dev/null | head -1); do
    [ -f "$d/issue-fns.sh" ] && SCRIPT_DIR="$d" && break
  done
  [ -n "$SCRIPT_DIR" ] && source "${SCRIPT_DIR}/issue-fns.sh"
  type issue_deps >/dev/null 2>&1 || { echo "❌ issue-fns.sh predates the dependency verbs (stale .agent/scripts?); cannot continue" >&2; exit 1; }
fi
```

## Usage

```
/list-issues
/list-issues --label needs-design
/list-issues --priority P0
/list-issues --state closed
/list-issues --stuck
```

## Steps

1. Parse arguments:
   - `--label <name>` — filter by label
   - `--priority P0|P1|P2|P3` — filter by priority label
   - `--state open|closed` — default `open`
   - `--limit N` — default 50
   - `--stuck` — report open issues that cannot make progress (see step 2)

2. If `--stuck` was passed, run the stuck report and stop — skip steps 3–4:

```bash
STUCK_FOUND=0
ISSUES=$(issue_list --state open --limit "${LIMIT:-200}")
while IFS=$'\t' read -r NUM TITLE; do
  [ -z "$NUM" ] && continue
  DEPS=$(issue_deps "$NUM"); RC=$?
  if [ "$RC" -ge 2 ]; then
    echo "❌ dependency lookup failed (rc=$RC) — backend error, or this backend's dependency verbs land in increment 2" >&2
    exit 1
  fi
  [ "$RC" -eq 1 ] && continue              # issue vanished mid-report — skip it
  if [ "$(echo "$DEPS" | jq '(.blockedBy | length) + (.blocks | length)')" -eq 0 ]; then
    continue                               # no edges recorded — never stuck
  fi
  MISSING=$(echo "$DEPS" | jq -r '[.blockedBy[] | select(.state == "missing").number] | join(", ")')
  if [ -n "$MISSING" ]; then
    echo "#$NUM  $TITLE"
    echo "    why: dangling-edge — blocked by missing issue(s): $MISSING"
    STUCK_FOUND=1
    continue
  fi
  TOTAL=$(echo "$DEPS" | jq '.blockedBy | length')
  NOPEN=$(echo "$DEPS" | jq '[.blockedBy[] | select(.state == "open")] | length')
  if [ "$TOTAL" -eq 0 ] || [ "$NOPEN" -ne "$TOTAL" ]; then
    continue                               # no blockers, or one already closed — progress possible
  fi
  OPEN_BLOCKERS=$(echo "$DEPS" | jq -r '[.blockedBy[] | select(.state == "open").number] | join(" ")')
  ALL_BLOCKED=1
  for B in $OPEN_BLOCKERS; do              # second hop — depth capped at 2, no deeper recursion
    BDEPS=$(issue_deps "$B"); RC=$?
    if [ "$RC" -ge 2 ]; then
      echo "❌ dependency lookup failed (rc=$RC) — backend error, or this backend's dependency verbs land in increment 2" >&2
      exit 1
    fi
    [ "$RC" -eq 1 ] && continue            # blocker vanished mid-report — never counts as claimable
    if [ "$(echo "$BDEPS" | jq '[.blockedBy[] | select(.state == "open")] | length')" -eq 0 ]; then
      ALL_BLOCKED=0; break                 # this blocker is claimable — not stuck
    fi
  done
  if [ "$ALL_BLOCKED" -eq 1 ]; then
    echo "#$NUM  $TITLE"
    echo "    why: cycle-suspect — every blocker ($OPEN_BLOCKERS) is open and itself blocked"
    STUCK_FOUND=1
  fi
done < <(echo "$ISSUES" | jq -r '.[] | "\(.number)\t\(.title)"')
if [ "$STUCK_FOUND" -eq 0 ]; then echo "No stuck issues."; fi
```

An issue is **stuck** only when:
- it carries at least one dangling edge (`"state": "missing"` in `blockedBy`) — an edge pointing at an issue that no longer exists; or
- it has blockers, **every** blocker is open, and each blocker is itself blocked (has at least one open blocker of its own — the second hop above; depth is capped at 2).

Issues whose blockers are merely open/claimable or in progress are **not** stuck — a worker will get to those blockers. Issues with no recorded edges are skipped entirely.

3. Fetch issues:

```bash
ISSUES=$(issue_list --state "${STATE:-open}" --limit "${LIMIT:-50}" ${LABEL_FLAGS})
```

Where `LABEL_FLAGS` is `--label <name>` for the label or priority provided.

4. Format and display. For each issue in the JSON array:

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
