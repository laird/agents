# Critical Implementation Review: 2026-05-19-pluggable-issue-source (Round 1)

**Plan:** `docs/superpowers/plans/2026-05-19-pluggable-issue-source.md`
**Verified plan-level assumptions section:** present

---

## 1. Verified-plan-assumptions cross-check

| # | Assumption | Status |
|---|-----------|--------|
| 1 | All 13 migration target files exist | ✅ Still holds — `ls` confirms all 13 present |
| 2 | All 13 files contain functional `gh issue` calls (counts as listed) | ✅ Still holds — `grep -c "gh issue"` matches expected counts |
| 3 | Python 3.8+ available as `python3` | ✅ Still holds — `python3 --version` → Python 3.13.7 |
| 4 | `fcntl` module available in stdlib | ✅ Still holds — `python3 -c "import fcntl"` succeeds |
| 5 | `argparse` supports `required=True` on subparsers | ✅ Still holds |
| 6 | All four directories exist | ✅ Still holds |
| 7 | `gh issue list` accepts `--state {open\|closed\|all}` | ✅ Still holds — `gh issue list --help` shows `-s, --state string: {open\|closed\|all}` |
| 8 | `.agent/` mirror convention applies | ✅ Still holds |
| 9 | `"003".isdigit()` returns `True` | ✅ Still holds |

All verified plan-level assumptions reconfirmed.

---

## 2. Literal-wrongness findings

### 2.1 `_ifns_gh_create` uses `gh issue create --json number` — `gh issue create` has no `--json` flag

**Description:** Task 5's `_ifns_gh_create` function in `issue-fns.sh` calls:

```bash
gh issue create "${create_args[@]}" --json number \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(json.dumps({'number': d['number']}))"
```

`gh issue create` has no `--json` flag. `gh issue create --help` lists only: `-a/--assignee`, `-b/--body`, `-F/--body-file`, `-e/--editor`, `-l/--label`, `-m/--milestone`, `-p/--project`, `--recover`, `-T/--template`, `-t/--title`, `-w/--web`. No `--json`. The command would exit with an "unknown flag" error, `python3` would receive no input, and `_ifns_gh_create` would fail for every `issue_create` call on the GitHub backend.

All seven callers migrated in Tasks 6–9 (e.g., `regression-test.sh`, `full-regression-test.md`, `record-issue.md`) depend on `_ifns_gh_create` returning `{"number": N}` JSON. None would work.

**Evidence:** `gh issue create --help` output, confirmed empirically — no `--json` flag present.

**Proposed fix:** Parse the URL that `gh issue create` outputs by default:

```bash
_ifns_gh_create() {
  local title="" body="" labels=() priority=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --title)    title="$2"; shift 2 ;;
      --body)     body="$2"; shift 2 ;;
      --label)    labels+=("$2"); shift 2 ;;
      --priority) priority="$2"; shift 2 ;;
      *)          shift ;;
    esac
  done
  [ -n "$priority" ] && labels+=("$priority")
  local create_args=(--title "$title" --body "$body")
  for l in "${labels[@]}"; do create_args+=(--label "$l"); done
  local issue_url
  issue_url=$(gh issue create "${create_args[@]}")
  local number
  number=$(echo "$issue_url" | grep -oE '[0-9]+$')
  echo "{\"number\": $number}"
}
```

`gh issue create` always outputs the created issue URL (e.g., `https://github.com/owner/repo/issues/42`); `grep -oE '[0-9]+$'` reliably extracts the number.

---

### 2.2 `--state all` not supported in `issues-file.py list`; Task 8 migration silently drops it for GitHub backend

**Description:** `full-regression-test.md` line 287 uses:

```bash
gh issue list --state all --json number,title,labels,body --limit 200 > /tmp/gh-all-issues.json
```

Task 8 Step 3 migrates this to:

```bash
issue_list --limit 200 > /tmp/gh-all-issues.json
```

Two problems compound:

1. **GitHub backend behavior change:** `issue_list --limit 200` (no `--state`) → `_ifns_gh_list --limit 200` → `gh issue list --limit 200 --json ...` → `gh issue list` defaults to `--state open`. The "all issues" query becomes "open issues only," so closed test-failure issues are invisible to the regression analysis step, breaking its ability to detect already-tracked failures.

2. **File backend incompatibility with `--state all`:** Even if the migration correctly passed `--state all`, `issues-file.py list` uses `argparse` with `choices=["open", "closed"]`. Passing `--state all` would fail with argparse's "invalid choice" error, so `--state all` cannot be explicitly forwarded to the file backend.

The file backend's `cmd_list` with no `--state` (i.e., `args.state is None`) correctly returns all issues. But the GitHub backend path doesn't match: `_ifns_gh_list` without `--state` defaults to open-only.

**Evidence:** `full-regression-test.md:287` (`grep -n "state all" plugins/autocoder/commands/full-regression-test.md`). Plan Task 8 Step 3 "before/after" block. `gh issue list --help`: `-s, --state string: {open|closed|all} (default "open")`. `issues-file.py` Task 1 argparse: `p_list.add_argument("--state", choices=["open", "closed"])`.

**Proposed fix:** Two changes:

1. In `issues-file.py` Task 1, add `"all"` to choices and treat it as no-state filter:
   ```python
   p_list.add_argument("--state", choices=["open", "closed", "all"])
   ```
   In `cmd_list`:
   ```python
   if args.state and args.state != "all":
       if args.state == "open" and status != "open":
           continue
       if args.state == "closed" and status != "closed":
           continue
   ```

2. In Task 8 Step 3, migrate `gh issue list --state all ...` to `issue_list --state all ...` (not just `issue_list ...`):
   ```bash
   issue_list --state all --limit 200 > /tmp/gh-all-issues.json 2>/dev/null || echo "[]" > /tmp/gh-all-issues.json
   ```

Add a corresponding test in `tests/test_issues_file.py` (Task 1's test file):
```python
def test_state_all_returns_all_statuses(self, idir):
    write_issue(idir, 1, "Open", status="open")
    write_issue(idir, 2, "Working", status="working")
    write_issue(idir, 3, "Closed", status="closed")
    out, _, rc = run(["list", "--state", "all"], {"ISSUE_DIR_PATH": str(idir)})
    assert rc == 0
    issues = json.loads(out)
    assert len(issues) == 3
```

---

## 3. Forced decisions

No forced decisions found.

---

## 5. Recommendation

⚠️ **Approve with literal-wrongness fixes** — §1 has no failed assumptions; §3 is empty. Two fixes needed before subagent-driven-development:

1. Replace `gh issue create --json number` with URL-parsing in `_ifns_gh_create` (Task 5).
2. Add `"all"` to `issues-file.py list` choices and update Task 8 Step 3 migration to preserve `--state all` behavior.

Both are self-contained edits within their respective tasks. Plan is ready for `update-implementation-plan` to apply these fixes, then `subagent-driven-development`.
