# Critical Implementation Review: 2026-05-19-pluggable-issue-source-implementation-plan (Round 1)

**Plan:** `docs/plans/2026-05-19-pluggable-issue-source-implementation-plan.md`
**Verified plan-level assumptions section:** present

⚠️ 4 commits since plan-write time (SHA de4e39c); cited file:line references re-checked under §1.

---

## 1. Verified-plan-assumptions cross-check

| # | Assumption | Status |
|---|-----------|--------|
| 1 | All 13 migration target files exist at their stated paths | ✅ Still holds — `ls` confirms all 13 present |
| 2 | All 13 files contain functional `gh issue` calls (counts as listed) | ✅ Still holds — `grep -c "gh issue"` matches stated counts exactly |
| 3 | Python 3.8+ available as `python3` | ✅ Still holds — `python3 --version` → Python 3.13.7 |
| 4 | `fcntl` module available in stdlib | ✅ Still holds — `python3 -c "import fcntl"` succeeds |
| 5 | `argparse` supports `required=True` on subparsers | ✅ Still holds — confirmed |
| 6 | All four directories exist | ✅ Still holds — `ls -d` confirmed all four |
| 7 | `gh issue list` accepts `--state {open\|closed\|all}` | ✅ Still holds — `gh issue list --help` confirms |
| 8 | `.agent/` mirror convention applies | ✅ Still holds — `CLAUDE.md` "Parallel Maintenance Requirement" section present |
| 9 | `"003".isdigit()` returns `True` | ✅ Still holds |
| 10 | `tests/` directory does NOT exist in the repo | ✅ Still holds — `ls -d tests/` → No such file or directory |
| 11 | `pytest 9.0.2` available | ✅ Still holds — `python3 -m pytest --version` → pytest 9.0.2 |
| 12 | `fcntl.LOCK_EX=2`, `LOCK_SH=1`, `LOCK_UN=8` | ✅ Still holds |
| 13 | `argparse choices=["open","closed","all"]` accepts "all" | ✅ Still holds — `Namespace(state='all')` confirmed |
| 14 | `glob("*.md")` does NOT match `.seq` | ✅ Still holds — empty list confirmed |
| 15 | `full-regression-test.md` uses `gh issue list --state all` at line 287 | ✅ Still holds — `grep -n "state all"` → line 287 confirmed |
| 16 | `docs/plans/` directory exists | ✅ Still holds |

All verified plan-level assumptions reconfirmed.

---

## 2. Literal-wrongness findings

### 2.1 Task 4 Step 1 test assertion fails — non-interactive fail-fast fires before `echo 0`

**Description:** The test in Task 4 Step 1:

```bash
assert_eq "script is sourceable" "0" "$(bash -c "source $SCRIPT; echo 0" 2>/dev/null || echo 1)"
```

`bash -c` creates a subprocess without a TTY. `.autocoder.json` does not exist in this repo. `issue-config.sh` falls through its cached-config block (nothing to read), then hits:

```bash
if [ ! -t 0 ] && [ ! -t 1 ]; then
  echo "Error: No issue source configured." >&2
  exit 1
fi
```

Both stdin and stdout are non-TTY in a `bash -c` subprocess, so `exit 1` fires. The shell exits before `echo 0` runs. The assertion receives "1", expected "0" — FAIL. Task 4 Step 3 ("Expected: all pass") cannot succeed as written.

**Evidence:** `ls .autocoder.json` → not found; empirical simulation confirms the assertion fails:

```
bash -c "source /tmp/test_ic_sim.sh; echo 0" 2>/dev/null || echo 1
→ "1"
```

**Proposed fix:** Pre-set `ISSUE_SOURCE` so the early-return at the top of `issue-config.sh` fires (`if [ -n "$ISSUE_SOURCE" ]; then return 0 ...; fi`):

```bash
assert_eq "script is sourceable" "0" "$(ISSUE_SOURCE=github bash -c "source $SCRIPT; echo 0" 2>/dev/null || echo 1)"
```

Empirical confirmation: `ISSUE_SOURCE=github bash -c "source /tmp/test_ic_early.sh; echo 0" 2>/dev/null || echo 1` → "0". ✅

---

### 2.2 `issue_create --priority` passes `--priority` to `issues-file.py create`, which rejects it as an unrecognized argument

**Description:** `record-issue.md` (Task 9 Step 1) calls:

```bash
RESULT=$(issue_create --title "$TITLE" --body "$BODY" --priority "$PRIORITY" ${LABEL_FLAGS})
```

`issue_create()` in `issue-fns.sh` (Task 5) dispatches raw args to each backend:

```bash
issue_create() {
  case "$ISSUE_SOURCE" in
    github) _ifns_gh_create "$@" ;;
    file)   _ifns_file create "$@" ;;   # <— passes --priority unchanged
    *)      "$ISSUE_BACKEND" create "$@" ;;
  esac
}
```

For the file backend, `_ifns_file create --title "$TITLE" --body "$BODY" --priority "$PRIORITY"` calls `python3 issues-file.py create --title ... --priority ...`. The `issues-file.py create` argparser (Task 1) has only `--title`, `--body`, and `--label`; no `--priority`:

```python
p_create = sub.add_parser("create")
p_create.add_argument("--title", required=True)
p_create.add_argument("--body", default="")
p_create.add_argument("--label", action="append", default=[])
# no --priority
```

argparse exits with "error: unrecognized arguments: --priority P2", causing `record-issue.md` to fail for every invocation with a priority on the file backend.

Contrast: `issue_list()` (same Task 5) correctly strips `--priority` before dispatch:

```bash
issue_list() {
  local args=() priority=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --priority) priority="$2"; shift 2 ;;
      *) args+=("$1"); shift ;;
    esac
  done
  [ -n "$priority" ] && args+=(--label "$priority")
  ...
}
```

`issue_create` has no equivalent conversion.

**Evidence:** Plan `docs/plans/2026-05-19-pluggable-issue-source-implementation-plan.md`:
- `issue_create()` at line 1304: raw `"$@"` dispatch, no `--priority` stripping
- `p_create` argparser near Task 1 Step 3: no `--priority` argument defined
- `record-issue.md` at line 1795: `issue_create --title ... --priority "$PRIORITY" ...`

**Proposed fix:** Apply the same `--priority → --label` conversion in `issue_create()` (Task 5):

```bash
issue_create() {
  local args=() priority=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --priority) priority="$2"; shift 2 ;;
      *) args+=("$1"); shift ;;
    esac
  done
  [ -n "$priority" ] && args+=(--label "$priority")
  case "$ISSUE_SOURCE" in
    github) _ifns_gh_create "${args[@]}" ;;
    file)   _ifns_file create "${args[@]}" ;;
    *)      "$ISSUE_BACKEND" create "${args[@]}" ;;
  esac
}
```

`_ifns_gh_create` already strips its own `--priority`; receiving `--label P2` instead is harmless and correct.

---

## 3. Forced decisions

No forced decisions found.

---

## 5. Recommendation

⚠️ **Approve with literal-wrongness fixes** — §1 has no failed assumptions; §3 is empty. Two fixes needed before subagent-driven-development:

1. Task 4 Step 1 test: pre-set `ISSUE_SOURCE=github` so the non-interactive fail-fast doesn't fire in the test subprocess.
2. Task 5 `issue_create()` in `issue-fns.sh`: add `--priority → --label` conversion (matching `issue_list()`'s pattern) before dispatching to the file backend.

Both are self-contained edits within their respective tasks. Apply via `update-implementation-plan`, then re-run `critical-implementation-review`.
