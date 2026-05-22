# Issue Storage and Backend Abstraction Implementation Plan

> **For agentic workers:** REQUIRED: Use `superpowers:subagent-driven-development` to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Source spec:** `docs/superpowers/specs/2026-05-22-issue-storage-and-backend-abstraction-design.md` (commit SHA: `c0b3df6`)

**Goal:** Restructure the file-backed issue store into four buckets (open/working/blocked/closed), unify the gh and file backends behind a parallel 8-verb CLI, and add a zero-cost `any-claimable` preflight so `fix-loop` idles cheaply.

**Architecture:** Each issue backend is a self-contained script implementing the same CLI surface. `issue-fns.sh` becomes a pure dispatcher. State transitions on the file backend are atomic POSIX `rename(2)` between bucket directories under cooperative `flock`. The github backend keeps label-based semantics with a documented best-effort claim. Cross-worktree coordination is preserved by `issue-config.sh`'s existing main-worktree resolution.

**Tech stack:** Python 3.13 (`fcntl`, `argparse`, `pathlib`) for the file backend, bash + `gh` CLI 2.92 for the github backend, pytest + shell-script tests in `tests/`.

---

## File Structure

**Create**
- `plugins/autocoder/scripts/issues-gh.sh` — github backend implementing the uniform 8-verb CLI; takes over the inline `_ifns_gh_*` functions currently embedded in `issue-fns.sh`.
- `plugins/autocoder/scripts/README.md` — backend contract documentation and Jira-walkthrough.
- `plugins/autocoder/commands/show-issue.md` — slash command that hides bucket paths from users by dispatching to `issue_get`.
- `plugins/autocoder/commands/migrate-issues-layout.md` — slash command exposing `issues-file.py migrate-layout`.

**Modify**
- `plugins/autocoder/scripts/issues-file.py` — four-bucket layout, fd-based I/O, claim/release/any-claimable verbs, `.seq` as authoritative counter, `migrate-layout` subcommand. `--if-unset` retires.
- `plugins/autocoder/scripts/issue-fns.sh` — shrinks to a pure dispatcher; adds `issue_claim`, `issue_release`, `issue_any_claimable` wrappers.
- `plugins/autocoder/scripts/fix-loop-gate.sh` — `--if-unset` callsite replaced with `issue_claim`.
- `plugins/autocoder/commands/fix.md` — preflight block at the top, GitHub-only setup moves below.
- `plugins/autocoder/commands/fix-loop.md` — outer loop wraps `issue_any_claimable` with a case statement.
- `plugins/autocoder/commands/monitor-workers.md` — `--state open --label "working"` → `--state working`; blocking-label jq filter goes away; `issue_update --remove-label working` → `issue_release`.
- `plugins/autocoder/commands/list-needs-design.md`, `list-needs-feedback.md`, `list-proposals.md`, `approve-proposal.md`, `brainstorm-issue.md` — `--state open --label "<blocking>"` → `--state blocked --label "<blocking>"`.
- `.agent/workflows/fix.md`, `fix-loop.md`, `monitor-workers.md`, `list-needs-design.md`, `list-needs-feedback.md`, `list-proposals.md`, `approve-proposal.md`, `brainstorm-issue.md` — mirror of the plugin/command edits.

**Test**
- `tests/test_issues_file.py` — extend with cases for four-bucket layout, `resolve_path`, `migrate-layout`, fd-based I/O preserving comments across rename, cross-worktree resolution.
- `tests/test_issues_file_if_unset.py` — replace contents with claim/release/any-claimable contract tests (file becomes `tests/test_issues_file_claim_release.py`).
- `tests/test_issue_fns.sh` — verify the dispatcher routes verbs correctly to each backend script.

## Inherited from spec

Verified by `thorough-brainstorming` at spec-write time (`c0b3df6`); trusted as ground truth here:

- `plugins/autocoder/scripts/{issue-config.sh, issue-fns.sh, issues-file.py}` exist and have the responsibilities described in the spec.
- `.agent/scripts/` and `.agent/workflows/` exist for parallel maintenance.
- `parse_issue_file` and `write_issue_file` re-open by path (motivating the fd-based refactor).
- `cmd_update` supports `--if-unset` with `sys.exit(9)` on lost race.
- `cmd_create` currently globs `*.md` for max number; `.seq` exists only as a lock sentinel.
- `issue-fns.sh` contains inline `_ifns_gh_list/update/close/create` functions.
- `monitor-workers.md` lines 82/130/261/262 are the queries the migration plan targets.
- `list-needs-design.md`, `list-needs-feedback.md`, `list-proposals.md` use `--state open --label "<blocking>"`.
- The existing `monitor-workers.md:130` filter omits `needs-feedback`; the new design corrects this.
- `fix-loop-gate.sh` exists and is the consumer of the `--if-unset` exit-9 contract.
- `working` is currently both a label and a status; `proposal` is currently a blocking label.
- POSIX `rename(2)` is atomic on a single filesystem; `fcntl.flock` works on macOS/Linux; `gh issue edit --add-label X` is idempotent; `git worktree list --porcelain` lists the main worktree first; `find -maxdepth 1 -name -print -quit` is portable.

## Verified plan-level assumptions

Newly introduced by this plan and verified at plan-write time:

| # | Category | Assumption | Evidence |
|---|---|---|---|
| 1 | File path | `plugins/autocoder/scripts/issues-gh.sh` does not currently exist | `ls plugins/autocoder/scripts/issues-gh.sh` → "No such file or directory" |
| 2 | File path | `plugins/autocoder/scripts/README.md` does not currently exist | `ls plugins/autocoder/scripts/README.md` → "No such file or directory" |
| 3 | File path | `plugins/autocoder/commands/show-issue.md` does not currently exist | `ls` → "No such file or directory" |
| 4 | File path | `plugins/autocoder/commands/migrate-issues-layout.md` does not currently exist | `ls` → "No such file or directory" |
| 5 | Consumer | `fix-loop-gate.sh:159` is the ONLY external `--if-unset` consumer | `grep -rn "if-unset" plugins/ .agent/` returns only `fix-loop-gate.sh:159` and `issues-file.py:197,370,373` (declaration site) |
| 6 | Consumer | `parse_issue_file` / `write_issue_file` are called only inside `issues-file.py` | `grep -rn` shows 8 hits, all in `issues-file.py` (lines 54, 87, 151, 178, 192, 221, 236, 238, 251, 256). No external callers. |
| 7 | Consumer | `--state open --label "<blocking>"` queries appear in 7 files | `grep -rn "state open --label"` confirms: `list-needs-design.md`, `list-needs-feedback.md`, `list-proposals.md`, `approve-proposal.md`, `brainstorm-issue.md`, `monitor-workers.md` (lines 82, 261 with "working"), plus `.agent/workflows/` mirrors. `fix.md` and `full-regression-test.md` use non-blocking labels (`test-failure`, `enhancement`) and are not affected. |
| 8 | Consumer | `.agent/scripts/` does NOT contain `issue-config.sh`, `issue-fns.sh`, `issues-file.py`, or `fix-loop-gate.sh` | `diff <(ls plugins/autocoder/scripts/) <(ls .agent/scripts/)` — backend scripts are plugin-only. Task 8 mirrors only command-level files. |
| 9 | Consumer | `.agent/scripts/README.md` already exists with unrelated content | `ls .agent/scripts/README.md` returns the file; the new plugin-side `README.md` is distinct and does NOT overwrite this. |
| 10 | Consumer | All four `list-X` and `monitor-workers` query lines are mirrored exactly into `.agent/workflows/` at the same line numbers | grep confirms `.agent/workflows/list-needs-feedback.md:42`, `.agent/workflows/monitor-workers.md:82,261` are identical to plugin versions |
| 11 | Test infrastructure | Tests run via `pytest` (no `package.json`; Python project) | `tests/test_*.py` exist; `ls Makefile pyproject.toml package.json` → no `package.json`; `python3 --version` → 3.13.7 |
| 12 | Test infrastructure | `tests/test_issues_file_if_unset.py` is dedicated to `--if-unset` (replaceable, not just deletable) | Module docstring: "Tests for the `--if-unset` flag on `issues-file.py update`. Covers Phase 1 of the fix-loop token-efficiency design" (129 lines). |
| 13 | Commit convention | Recent commits use `category: subject` (lowercase, no Conventional-Commits scope) | `git log --format=%s -10` shows `docs:`, `ci:`, `chore:`, `chore(issues):` — flat prefix style. Plan tasks use the same. |
| 14 | Code-in-plan | Python `os.rename(src, dst)` raises `FileNotFoundError` when `src` doesn't exist | Standard library documented behavior; relied on by spec §2 claim/release snippets. |
| 15 | Code-in-plan | `find ... -print -quit \| grep -q .` produces exit 0 on any printed line, 1 on empty input | Verified via `echo yes \| grep -q .` (exit 0) and `true \| grep -q .` (exit 1). |
| 16 | Ordering | Task 1 must precede Tasks 3–7 (they call its new verbs) | `issue_claim`, `issue_release`, `issue_any_claimable` are introduced by Task 1; Tasks 3–6 call them. |
| 17 | Ordering | Task 2 can land alongside Task 1 (different files; the dispatcher slim doesn't depend on file-backend internals) | `issue-fns.sh` is a separate file from `issues-file.py`; Task 2's only dependency on Task 1 is the `claim`/`release`/`any-claimable` verb names, which are stable contract. |
| 18 | Ordering | Task 8 (.agent/ mirror) lands last so it picks up the final versions of edited command files | Mirror is a copy operation; no semantic ordering constraint beyond "after source files are stable." |
| 19 | Drift | Source spec is at the same HEAD as plan-write time | `git log -1 --format=%H -- docs/superpowers/specs/2026-05-22-issue-storage-and-backend-abstraction-design.md` → `c0b3df6` (HEAD). No drift. |

## Tasks

### Task 1: File backend overhaul

**Files:**
- Modify: `plugins/autocoder/scripts/issues-file.py`
- Test: `tests/test_issues_file.py` (extend), `tests/test_issues_file_if_unset.py` (rename to `tests/test_issues_file_claim_release.py` and rewrite)

- [ ] **Step 1: Rewrite `parse_issue_file` / `write_issue_file` to take a file object (fd-based I/O)**

  Replace the path-based helpers with fd-based equivalents. The two signatures become:

  ```python
  def parse_issue_file_fd(f) -> dict:
      f.seek(0)
      content = f.read()
      # ... existing parsing logic
      return data

  def write_issue_file_fd(f, data: dict) -> None:
      # ... existing serialization logic
      f.seek(0)
      f.truncate()
      f.write(text)
  ```

  Update every call site in `cmd_update` (line 192, 221), `cmd_comment` (line 236, 238), `cmd_close` (line 251, 256) to use the fd. The pattern becomes:

  ```python
  with open(p, "r+") as f:
      lock_ex(f.fileno())
      try:
          data = parse_issue_file_fd(f)
          # ... modify data
          write_issue_file_fd(f, data)
      finally:
          unlock(f.fileno())
  ```

  Keep `parse_issue_file(path)` as a thin wrapper for `cmd_list` and `cmd_get` (read-only path that doesn't need flock, since `list` is a snapshot view).

- [ ] **Step 2: Introduce the four-bucket layout helpers**

  ```python
  BUCKETS = ("open", "working", "blocked", "closed")
  BLOCKING_LABELS = {"needs-design", "needs-clarification", "needs-feedback",
                     "needs-approval", "too-complex", "future", "proposal"}

  def issue_path(issues_dir: Path, bucket: str, number: int) -> Path:
      return issues_dir / bucket / f"{number:03d}.md"

  def resolve_path(issues_dir: Path, number: int) -> tuple[str, Path]:
      """Return (bucket, path) for the first bucket holding this issue, with bounded retry on ENOENT."""
      for _ in range(3):
          for bucket in BUCKETS:
              p = issue_path(issues_dir, bucket, number)
              if p.exists():
                  return bucket, p
      raise FileNotFoundError(f"issue {number} not in any bucket")
  ```

- [ ] **Step 3: Implement `migrate-layout` subcommand**

  Add `cmd_migrate_layout` and wire it via argparse:

  ```python
  def cmd_migrate_layout(args):
      issues_dir = get_issues_dir()
      # Refuse if already migrated
      for bucket in BUCKETS:
          d = issues_dir / bucket
          if d.is_dir() and any(d.glob("*.md")):
              sys.exit(f"Error: {bucket}/ already contains .md files; already migrated")
      for bucket in BUCKETS:
          (issues_dir / bucket).mkdir(parents=True, exist_ok=True)
      counts = {b: 0 for b in BUCKETS}
      max_num = 0
      for p in sorted(issues_dir.glob("*.md")):
          if p.name.startswith("."):
              continue
          data = parse_issue_file(p)
          number = data.get("number", 0)
          max_num = max(max_num, number)
          status = data.get("status", "open")
          labels = data.get("labels") or []
          if status == "closed":
              bucket = "closed"
          elif status == "working":
              bucket = "working"
          elif any(l in BLOCKING_LABELS for l in labels):
              bucket = "blocked"
          else:
              bucket = "open"
          p.rename(issue_path(issues_dir, bucket, number))
          counts[bucket] += 1
      seq = seq_path(issues_dir)
      current_seq = int(seq.read_text().strip()) if seq.exists() and seq.read_text().strip() else 0
      if max_num > current_seq:
          seq.write_text(str(max_num) + "\n")
      print(f"Migrated: {counts}")
  ```

- [ ] **Step 4: Rewrite `cmd_create` to use `.seq` as authoritative**

  ```python
  def cmd_create(args):
      issues_dir = get_issues_dir()
      seq = seq_path(issues_dir)
      seq.touch()
      with open(seq, "r+") as f:
          lock_ex(f.fileno())
          try:
              raw = f.read().strip()
              current = int(raw) if raw else 0
              number = current + 1
              f.seek(0)
              f.truncate()
              f.write(str(number) + "\n")
          finally:
              unlock(f.fileno())
      data = {
          "number": number,
          "title": args.title,
          "labels": args.label or [],
          "status": "open",
          "body": args.body or "",
      }
      (issues_dir / "open").mkdir(parents=True, exist_ok=True)
      write_issue_file(issue_path(issues_dir, "open", number), data)
      print(json.dumps({"number": number}))
  ```

  Note: `write_issue_file(path)` remains as a path-based one-shot writer for `cmd_create` (no lock, file is newly created). The flock-only-via-fd rule applies to rmw, not initial-write.

- [ ] **Step 5: Implement `cmd_claim` and `cmd_release`**

  ```python
  def cmd_claim(args):
      issues_dir = get_issues_dir()
      src = issue_path(issues_dir, "open", args.number)
      dst = issue_path(issues_dir, "working", args.number)
      (issues_dir / "working").mkdir(parents=True, exist_ok=True)
      try:
          os.rename(src, dst)
      except FileNotFoundError:
          sys.exit(1)
      with open(dst, "r+") as f:
          lock_ex(f.fileno())
          try:
              data = parse_issue_file_fd(f)
              labels = list(data.get("labels") or [])
              if "working" not in labels:
                  labels.append("working")
              data["labels"] = labels
              data["status"] = "working"
              write_issue_file_fd(f, data)
          finally:
              unlock(f.fileno())

  def cmd_release(args):
      issues_dir = get_issues_dir()
      src = issue_path(issues_dir, "working", args.number)
      if not src.exists():
          sys.exit(1)
      with open(src, "r+") as f:
          lock_ex(f.fileno())
          try:
              data = parse_issue_file_fd(f)
              labels = [l for l in (data.get("labels") or []) if l != "working"]
              target = "blocked" if any(l in BLOCKING_LABELS for l in labels) else "open"
              data["labels"] = labels
              data["status"] = "blocked" if target == "blocked" else "open"
              write_issue_file_fd(f, data)
          finally:
              unlock(f.fileno())
      (issues_dir / target).mkdir(parents=True, exist_ok=True)
      dst = issue_path(issues_dir, target, args.number)
      try:
          os.rename(src, dst)
      except FileNotFoundError:
          sys.exit(1)
  ```

- [ ] **Step 6: Implement `cmd_any_claimable`**

  ```python
  def cmd_any_claimable(args):
      issues_dir = get_issues_dir()
      open_dir = issues_dir / "open"
      if not open_dir.is_dir():
          sys.exit(3)
      for p in open_dir.glob("*.md"):
          if not p.name.startswith("."):
              sys.exit(0)
      sys.exit(1)
  ```

- [ ] **Step 7: Update blocking-label transitions in `cmd_update`**

  When an `--add-label X` (X ∈ `BLOCKING_LABELS`) is applied to an issue in `open/`, the post-flock step renames `open/N.md → blocked/N.md`. When the last blocking label is removed from an issue in `blocked/`, rename back to `open/`. For issues in `working/`, the file stays put (frontmatter records the label; `release` picks the bucket later).

  Implementation outline added at the end of the existing flocked rmw block in `cmd_update`:

  ```python
  # After write_issue_file_fd(f, data) and before unlock:
  current_bucket = src.parent.name
  new_labels = data["labels"]
  has_blocking = any(l in BLOCKING_LABELS for l in new_labels if l != "working")
  if current_bucket == "open" and has_blocking:
      target_bucket = "blocked"
  elif current_bucket == "blocked" and not has_blocking:
      target_bucket = "open"
  else:
      target_bucket = None
  # ... unlock first, then rename outside the with-block:
  if target_bucket is not None:
      (issues_dir / target_bucket).mkdir(parents=True, exist_ok=True)
      try:
          os.rename(src, issue_path(issues_dir, target_bucket, args.number))
      except FileNotFoundError:
          pass  # Concurrent claim raced us; the file is in working/ now; ours-was-not-the-write-that-rooted-state-here
  ```

  Add an explicit error if `--add-label working` is called on an `open/` issue — that path is gone; use `claim` instead. Exit 2 (usage error).

- [ ] **Step 8: Retire `--if-unset`**

  Remove the `--if-unset` flag from the `update` argparse parser and the corresponding `if args.if_unset and already_set: sys.exit(9)` block in `cmd_update`. The contract for atomic claim is now `cmd_claim` (rename-first).

- [ ] **Step 9: Wire new verbs into argparse**

  ```python
  sub.add_parser("claim").add_argument("number", type=int)
  sub.add_parser("release").add_argument("number", type=int)
  sub.add_parser("any-claimable")
  sub.add_parser("migrate-layout")

  dispatch.update({
      "claim": cmd_claim,
      "release": cmd_release,
      "any-claimable": lambda _: cmd_any_claimable(_),
      "migrate-layout": lambda _: cmd_migrate_layout(_),
  })
  ```

  Also update `list` choices to include `blocked`: `p_list.add_argument("--state", choices=["open", "working", "blocked", "closed", "all"])`.

  Update `cmd_list` to walk the bucket directories based on `--state`:

  ```python
  def cmd_list(args):
      issues_dir = get_issues_dir()
      state = args.state or "open"
      buckets = BUCKETS if state == "all" else [state]
      results = []
      for bucket in buckets:
          d = issues_dir / bucket
          if not d.is_dir():
              continue
          for p in sorted(d.glob("*.md")):
              if p.name.startswith("."):
                  continue
              with open(p, "r") as f:
                  lock_sh(f.fileno())
                  try:
                      data = parse_issue_file_fd(f)
                  finally:
                      unlock(f.fileno())
              if args.label:
                  labels = data.get("labels") or []
                  if args.label not in labels:
                      continue
              results.append(to_gh_json(data))
      if args.limit:
          results = results[:args.limit]
      print(json.dumps(results, indent=2))
  ```

  Update `cmd_get`, `cmd_comment`, `cmd_close` to use `resolve_path(issues_dir, args.number)` to find the file regardless of bucket.

  Update `cmd_close` to rename to `closed/` after the flocked frontmatter update (same shape as `cmd_release`'s rename-after-flock).

  Exit-code contract: 0 = success, 1 = clean negative / not-found / race-lost, 2 = usage error, 3 = backend error.

- [ ] **Step 10: Update tests**

  - Rename `tests/test_issues_file_if_unset.py` → `tests/test_issues_file_claim_release.py`. Replace contents with tests for `claim`, `release`, `any-claimable`, and the blocking-label transitions on `cmd_update`. Include the parallel-claim stress test (spec §Testing-plan): N processes call `claim` on the same issue; assert exactly one exits 0.
  - Extend `tests/test_issues_file.py` to cover: `migrate-layout` against a mixed fixture (open/working/blocked-labeled/closed), `resolve_path` probe order, `--state blocked` listing, `cmd_close` lands the file in `closed/`, fd-based I/O preserving a concurrent comment across a rename (spec §2 race 2). Use `tmp_path` fixtures.

- [ ] **Step 11: Run the test suite**

  ```bash
  python3 -m pytest tests/test_issues_file.py tests/test_issues_file_claim_release.py -v
  ```

  All tests must pass before committing.

- [ ] **Step 12: Commit**

  ```bash
  git add plugins/autocoder/scripts/issues-file.py tests/test_issues_file.py tests/test_issues_file_claim_release.py
  git rm tests/test_issues_file_if_unset.py
  git commit -m "feat(issues-file): four-bucket layout, claim/release/any-claimable, fd-based I/O"
  ```

### Task 2: Extract gh backend; slim dispatcher

**Files:**
- Create: `plugins/autocoder/scripts/issues-gh.sh`
- Modify: `plugins/autocoder/scripts/issue-fns.sh`
- Test: `tests/test_issue_fns.sh`

- [ ] **Step 1: Write `issues-gh.sh` implementing the 8-verb CLI plus `any-claimable`**

  Structure as a `case "$1"` dispatcher over: `list`, `get`, `update`, `comment`, `close`, `create`, `claim`, `release`, `any-claimable`. Move the existing `_ifns_gh_list`, `_ifns_gh_update`, `_ifns_gh_close`, `_ifns_gh_create` function bodies into the corresponding case branches. Implement the new verbs:

  ```bash
  cmd_claim() {
      local n="$1"
      gh issue edit "$n" --add-label working >/dev/null || exit 3
      # Best-effort: gh has no atomic single-writer label edit; documented in spec §4
  }

  cmd_release() {
      local n="$1"
      gh issue edit "$n" --remove-label working >/dev/null || exit 3
  }

  cmd_any_claimable() {
      local count
      count=$(gh issue list --state open \
          --search 'no:label "working" no:label "needs-design" no:label "needs-clarification" no:label "needs-feedback" no:label "needs-approval" no:label "too-complex" no:label "future" no:label "proposal"' \
          -L 1 --json number --jq 'length') || exit 3
      [ "$count" -gt 0 ]
  }
  ```

  Make `issues-gh.sh` executable: `chmod +x plugins/autocoder/scripts/issues-gh.sh`.

  Update `list --state open` and `list --state blocked` in this script to apply the blocking-label search prefix as documented in spec §4 line 232.

- [ ] **Step 2: Rewrite `issue-fns.sh` as a pure dispatcher**

  Replace the body of `issue-fns.sh` with:

  ```bash
  #!/bin/bash
  # issue-fns.sh — thin dispatcher; backends live in issues-<backend>.{sh,py}
  if [ -z "$ISSUE_SOURCE" ]; then
      _ifns_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
      source "${_ifns_DIR}/issue-config.sh"
  fi
  _ifns_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

  _ifns_BACKEND_SCRIPT=$(case "$ISSUE_SOURCE" in
      github) echo "issues-gh.sh"   ;;
      file)   echo "issues-file.py" ;;
      *)      echo "$ISSUE_BACKEND" ;;
  esac)
  _ifns_BACKEND_BIN="${_ifns_DIR}/${_ifns_BACKEND_SCRIPT}"

  issue_list()          { "$_ifns_BACKEND_BIN" list          "$@"; }
  issue_get()           { "$_ifns_BACKEND_BIN" get           "$@"; }
  issue_update()        { "$_ifns_BACKEND_BIN" update        "$@"; }
  issue_comment()       { "$_ifns_BACKEND_BIN" comment       "$@"; }
  issue_close()         { "$_ifns_BACKEND_BIN" close         "$@"; }
  issue_create()        { "$_ifns_BACKEND_BIN" create        "$@"; }
  issue_claim()         { "$_ifns_BACKEND_BIN" claim         "$@"; }
  issue_release()       { "$_ifns_BACKEND_BIN" release       "$@"; }
  issue_any_claimable() { "$_ifns_BACKEND_BIN" any-claimable; }
  ```

  Delete the `_ifns_gh_*` functions and the `case "$ISSUE_SOURCE"` blocks inside the `issue_*` functions — they're replaced by per-call dispatch through the backend binary.

- [ ] **Step 3: Update `tests/test_issue_fns.sh`**

  Cover: each `issue_*` function invokes the correct backend script with the correct verb. Use a fake backend script that echoes its arguments to a known file; assert the dispatcher passes through verb name and flags. Cover both `ISSUE_SOURCE=file` and `ISSUE_SOURCE=github` paths.

- [ ] **Step 4: Run the dispatcher test**

  ```bash
  bash tests/test_issue_fns.sh
  ```

- [ ] **Step 5: Commit**

  ```bash
  git add plugins/autocoder/scripts/issues-gh.sh plugins/autocoder/scripts/issue-fns.sh tests/test_issue_fns.sh
  git commit -m "refactor(issue-fns): extract gh backend to issues-gh.sh; slim dispatcher"
  ```

### Task 3: Preflight in fix.md and fix-loop.md

**Files:**
- Modify: `plugins/autocoder/commands/fix.md`
- Modify: `plugins/autocoder/commands/fix-loop.md`

- [ ] **Step 1: Insert preflight at the top of `fix.md`'s executable section**

  Identify the first executable bash block in `fix.md` (currently the CLAUDE.md-reading block at around line 350). Insert this block **above** it, right after the SCRIPT_DIR resolution:

  ```bash
  source "${SCRIPT_DIR}/issue-fns.sh"
  issue_any_claimable
  case $? in
    0) ;;  # work exists; fall through
    1) echo "No claimable issues. Nothing to do."; exit 0 ;;
    *) echo "Backend error while checking for claimable issues"; exit 1 ;;
  esac
  ```

  Move the existing GitHub-only setup blocks (`gh repo view` identity switch, `gh label list` priority-labels setup — currently lines 368–419) to **after** the preflight.

- [ ] **Step 2: Rewrite `fix-loop.md`'s outer loop**

  Replace the existing while-loop body (currently lines around 244–254) with:

  ```bash
  while [ -f "$LOOP_STATE_FILE" ]; do
    issue_any_claimable
    case $? in
      0) /fix ;;
      1) echo "[$(date +%H:%M:%S)] idle" ;;
      *) echo "[$(date +%H:%M:%S)] backend error — see above; will retry next tick" ;;
    esac
    sleep "$INTERVAL"
  done
  ```

- [ ] **Step 3: Commit**

  ```bash
  git add plugins/autocoder/commands/fix.md plugins/autocoder/commands/fix-loop.md
  git commit -m "feat(fix-loop): zero-cost any-claimable preflight"
  ```

### Task 4: Backend contract README

**Files:**
- Create: `plugins/autocoder/scripts/README.md`

- [ ] **Step 1: Write the README**

  Five sections per spec §6:
  - **A. Architecture overview** — `issue-config.sh` detects, `issue-fns.sh` dispatches, `issues-<backend>` scripts implement.
  - **B. Backend contract** — the 9 subcommands (8 verbs + `any-claimable`), exit-code contract, JSON output schema, idempotency requirements, cross-worktree `ISSUE_DIR_PATH` discipline.
  - **C. Walkthrough: adding Jira** — 8-step recipe per spec §6 Section C.
  - **D. What NOT to do** — slash-command branching, reach-past-abstraction, baked-in label semantics.
  - **E. Contract test list** — round-trip, label ops, claim semantics (strict for file, best-effort for gh), comment append, empty-case, non-empty-case.

  No new code; pure documentation. Cross-reference the spec at `docs/superpowers/specs/2026-05-22-issue-storage-and-backend-abstraction-design.md`.

- [ ] **Step 2: Commit**

  ```bash
  git add plugins/autocoder/scripts/README.md
  git commit -m "docs(scripts): backend contract and Jira walkthrough"
  ```

### Task 5: Migrate fix-loop-gate.sh off `--if-unset`

**Files:**
- Modify: `plugins/autocoder/scripts/fix-loop-gate.sh`

- [ ] **Step 1: Replace the `--if-unset` callsite**

  At `fix-loop-gate.sh:159`, the current:

  ```bash
  if ! issue_update "$ISSUE_NUM" --add-label working --if-unset 2>/dev/null; then
  ```

  becomes:

  ```bash
  issue_claim "$ISSUE_NUM" 2>/dev/null
  claim_rc=$?
  if [ "$claim_rc" -ne 0 ]; then
  ```

  Adjust the surrounding error message ("lost race" if exit 1, else backend error if exit 3) — preserve the existing "another gate beat us" semantics. The comment block above the call (lines 23–24, 158) should be updated to describe `issue_claim` semantics instead of `--if-unset` exit-9.

- [ ] **Step 2: Run the gate test**

  ```bash
  bash tests/test_gate_md_bash.py 2>/dev/null || python3 -m pytest tests/test_gate_md_bash.py -v
  ```

  Confirms the gate still gates correctly.

- [ ] **Step 3: Commit**

  ```bash
  git add plugins/autocoder/scripts/fix-loop-gate.sh
  git commit -m "refactor(fix-loop-gate): use issue_claim instead of retired --if-unset"
  ```

### Task 6: Migrate state-query callers

**Files:**
- Modify: `plugins/autocoder/commands/monitor-workers.md`
- Modify: `plugins/autocoder/commands/list-needs-design.md`
- Modify: `plugins/autocoder/commands/list-needs-feedback.md`
- Modify: `plugins/autocoder/commands/list-proposals.md`
- Modify: `plugins/autocoder/commands/approve-proposal.md`
- Modify: `plugins/autocoder/commands/brainstorm-issue.md`

- [ ] **Step 1: Update each `list-X` command**

  In `list-needs-design.md:42`, `list-needs-feedback.md:42`, `list-proposals.md:34`, `approve-proposal.md:84`, `brainstorm-issue.md:71` — change `--state open --label "<blocking-label>"` to `--state blocked --label "<blocking-label>"`. The `--label` filter stays because a `blocked/` issue may carry multiple blocking labels.

- [ ] **Step 2: Update `monitor-workers.md`**

  - Lines 82, 261: `issue_list --state open --label "working"` → `issue_list --state working` (the `--label "working"` filter is redundant once the directory partitions).
  - Lines 79, 130, 262: the jq filter that excludes blocking labels becomes unnecessary once `--state open` is bucket-partitioned. Simplify:
    ```bash
    issue_list --state open | jq -r 'sort_by(.labels | map(select(.name | test("^P[0-3]$"))) | .[0].name // "P9") | .[].number'
    ```
    The needs-feedback / needs-design / etc. issues now live in `blocked/`, so `--state open` returns only claimable issues by directory.
  - Line ~122 (the recovery step): `issue_update <number> --remove-label "working"` → `issue_release <number>`.

- [ ] **Step 3: Commit**

  ```bash
  git add plugins/autocoder/commands/{monitor-workers,list-needs-design,list-needs-feedback,list-proposals,approve-proposal,brainstorm-issue}.md
  git commit -m "refactor(commands): migrate state-query callers to bucket-based --state"
  ```

### Task 7: Add /show-issue and /migrate-issues-layout slash commands

**Files:**
- Create: `plugins/autocoder/commands/show-issue.md`
- Create: `plugins/autocoder/commands/migrate-issues-layout.md`

- [ ] **Step 1: Write `show-issue.md`**

  Slash command that dispatches to `issue_get <number>` and pretty-prints the body. Hides the underlying bucket path so other commands (and humans) don't need to know which bucket an issue is in. Body shape matches existing list-X commands: SCRIPT_DIR resolution, sources `issue-fns.sh`, parses argv for the issue number, calls `issue_get`, pretty-prints title + body + labels + state from the returned JSON.

- [ ] **Step 2: Write `migrate-issues-layout.md`**

  Slash command that runs `python3 ${SCRIPT_DIR}/issues-file.py migrate-layout` against the file backend. Refuses to run if `ISSUE_SOURCE != file` (gh backend has no analogous migration). Prints the per-bucket count summary returned by the subcommand.

- [ ] **Step 3: Update `/set-issue-source` to detect old layout**

  In `plugins/autocoder/commands/set-issue-source.md`, when the user selects `file` against a directory containing top-level `*.md` (flat layout), prompt to run migration and offer to invoke `/migrate-issues-layout` automatically.

- [ ] **Step 4: Commit**

  ```bash
  git add plugins/autocoder/commands/show-issue.md plugins/autocoder/commands/migrate-issues-layout.md plugins/autocoder/commands/set-issue-source.md
  git commit -m "feat(commands): /show-issue and /migrate-issues-layout"
  ```

### Task 8: Mirror to .agent/workflows/

**Files:**
- Modify: `.agent/workflows/fix.md`, `.agent/workflows/fix-loop.md`, `.agent/workflows/monitor-workers.md`, `.agent/workflows/list-needs-design.md`, `.agent/workflows/list-needs-feedback.md`, `.agent/workflows/list-proposals.md`, `.agent/workflows/approve-proposal.md`, `.agent/workflows/brainstorm-issue.md`
- Create: `.agent/workflows/show-issue.md`, `.agent/workflows/migrate-issues-layout.md`

- [ ] **Step 1: Copy edited command files into `.agent/workflows/`**

  ```bash
  for f in fix.md fix-loop.md monitor-workers.md list-needs-design.md list-needs-feedback.md list-proposals.md approve-proposal.md brainstorm-issue.md show-issue.md migrate-issues-layout.md; do
      cp plugins/autocoder/commands/$f .agent/workflows/$f
  done
  ```

  Note: backend scripts (`issues-file.py`, `issues-gh.sh`, `issue-fns.sh`) have no `.agent/scripts/` counterpart (verified via `diff <(ls plugins/autocoder/scripts/) <(ls .agent/scripts/)`), so no mirror is needed there.

- [ ] **Step 2: Visual sanity-check that the copies match**

  ```bash
  for f in fix.md fix-loop.md monitor-workers.md list-needs-design.md list-needs-feedback.md list-proposals.md approve-proposal.md brainstorm-issue.md show-issue.md migrate-issues-layout.md; do
      diff -q plugins/autocoder/commands/$f .agent/workflows/$f
  done
  ```

  No output means all match.

- [ ] **Step 3: Commit**

  ```bash
  git add .agent/workflows/
  git commit -m "chore(agent): mirror command updates from plugins/autocoder/commands"
  ```

## Tasks NOT in this plan

(Inherited verbatim from the source spec's "Non-goals" section.)

- Backwards compatibility with the current flat `.issues/*.md` layout (one-shot migration only).
- Sharding closed issues by year or any other partition (flagged as a possible future change if closed-count goes to thousands).
- Cross-backend issue sync (e.g., mirroring gh into file). Out of scope; the existing `import-from-gh` / `export-to-gh` commands stay as-is.
