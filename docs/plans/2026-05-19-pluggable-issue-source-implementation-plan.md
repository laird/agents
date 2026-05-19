# Pluggable Issue Source Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a file-based issue backend (`.issues/NNN.md`) alongside GitHub Issues, with a shared shell function layer (`issue_list`, `issue_get`, etc.) that all existing commands route through transparently.

**Architecture:** `issue-config.sh` detects and caches the backend choice; `issue-fns.sh` provides six shell functions that dispatch to either `gh` (GitHub) or `issues-file.py` (file); all 13 existing files with `gh issue` calls are migrated to use the functions. Five new user-facing command files and five management commands complete the surface area. Everything is mirrored to `.agent/` per repo convention.

**Tech Stack:** bash 5+, Python 3.8+ stdlib only (no PyYAML — custom frontmatter parser), `gh` CLI (GitHub backend), `fcntl.flock` (per-file locking on macOS + Linux).

**Source spec:** `docs/superpowers/specs/2026-05-19-pluggable-issue-source-design.md` (commit SHA: de4e39c)

---

## Inherited from spec

These assumptions were verified by `thorough-brainstorming` at spec-write time. Treat as ground truth.

| # | Assumption |
|---|-----------|
| 1 | `gh issue list` accepts `--label`, `--limit`, `--state` |
| 2 | `gh issue list` does NOT accept `--priority` or `--status` |
| 3 | `gh issue create` accepts `--label` but NOT `--priority` or `--json` |
| 4 | `gh issue edit` accepts `--add-label` and `--remove-label` |
| 5 | `gh issue edit` does NOT accept `--status` or `--assignee`; `--add-assignee`/`--remove-assignee` take GitHub logins |
| 6 | `gh issue close` accepts `--comment` |
| 7 | `gh issue reopen` exists |
| 8 | `gh issue list --json` supports `number, title, body, labels, state` |
| 9 | Python `fcntl.flock` available on macOS |
| 10 | Shell `flock` NOT available on macOS |
| 11 | `git worktree list --porcelain \| grep -m1 "^worktree" \| cut -d' ' -f2` returns main worktree path |
| 12 | 13 files with functional `gh issue` calls in migration scope (`autocoder-help.md` excluded — doc only) |

---

## Verified plan-level assumptions

These assumptions were verified empirically during plan review (2026-05-19).

| # | Assumption | Evidence |
|---|-----------|---------|
| 1 | All 13 migration target files exist at their stated paths | `ls` confirmed all 13 present |
| 2 | All 13 migration targets contain functional `gh issue` calls (counts: add-blocking-label.sh=3, approve-blocked-issue.sh=2, reject-blocked-issue.sh=1, fetch-blocked-issues.sh=1, regression-test.sh=3, fix.md=46, approve-proposal.md=3, brainstorm-issue.md=5, full-regression-test.md=10, list-needs-design.md=7, list-needs-feedback.md=9, list-proposals.md=7, monitor-workers.md=6) | `grep -c "gh issue"` on each file |
| 3 | Python 3.8+ available as `python3` | `python3 --version` → Python 3.13.7 |
| 4 | `fcntl` module available in stdlib | `python3 -c "import fcntl"` succeeds |
| 5 | `argparse` supports `required=True` on subparsers (Python 3.7+) | `python3 -c "import argparse; p=argparse.ArgumentParser(); s=p.add_subparsers(dest='cmd', required=True)"` succeeds |
| 6 | `plugins/autocoder/scripts/`, `plugins/autocoder/commands/`, `.agent/scripts/`, `.agent/workflows/` all exist | `ls` confirmed all directories present |
| 7 | `gh issue list` accepts `--state {open\|closed\|all}` | `gh issue list --help` shows `-s, --state string: Filter by state: {open\|closed\|all} (default "open")` |
| 8 | `.agent/` mirror convention applies to new scripts and commands | `CLAUDE.md` "Parallel Maintenance Requirement" section confirms |
| 9 | `"003".isdigit()` returns `True` in Python (zero-padded numerics) | `python3 -c "print('003'.isdigit())"` → True |
| 10 | `tests/` directory does NOT exist in the repo | `ls -d tests/` → No such file or directory |
| 11 | `pytest 9.0.2` available as `python3 -m pytest` | `python3 -m pytest --version` → pytest 9.0.2 |
| 12 | `fcntl.LOCK_EX=2`, `LOCK_SH=1`, `LOCK_UN=8` (no surprises for lock_ex/lock_sh/unlock helpers) | `python3 -c "import fcntl; print(fcntl.LOCK_EX, fcntl.LOCK_SH, fcntl.LOCK_UN)"` → 2 1 8 |
| 13 | `argparse choices=["open","closed","all"]` accepts "all" without error | `python3 -c "import argparse; p=argparse.ArgumentParser(); p.add_argument('--state', choices=['open','closed','all']); print(p.parse_args(['--state','all']))"` → succeeds |
| 14 | `glob("*.md")` does NOT match `.seq` (hidden file protection not needed — only `*.md` matches needed) | `python3 -c "from pathlib import Path; import tempfile, os; d=Path(tempfile.mkdtemp()); (d/'.seq').touch(); print(list(d.glob('*.md')))"` → `[]` |
| 15 | `full-regression-test.md` uses `gh issue list --state all` at line 287 | `grep -n "state all" plugins/autocoder/commands/full-regression-test.md` → line 287 confirmed |
| 16 | `docs/plans/` directory exists | `ls -d docs/plans/` → exists |

---

## File Structure

**New files:**
- `plugins/autocoder/scripts/issues-file.py` — file backend; all `.issues/` read/write
- `plugins/autocoder/scripts/issue-config.sh` — detection, caching, env exports
- `plugins/autocoder/scripts/issue-fns.sh` — six dispatch functions
- `plugins/autocoder/commands/record-issue.md` — create an issue
- `plugins/autocoder/commands/update-issue.md` — modify labels/status
- `plugins/autocoder/commands/close-issue.md` — close an issue
- `plugins/autocoder/commands/list-issues.md` — list/filter issues
- `plugins/autocoder/commands/set-issue-source.md` — switch backends
- `tests/test_issues_file.py` — pytest suite for `issues-file.py`
- `tests/test_issue_fns.sh` — bash smoke tests for `issue-fns.sh`
- `.agent/scripts/issues-file.py`, `.agent/scripts/issue-config.sh`, `.agent/scripts/issue-fns.sh` — mirrors
- `.agent/workflows/record-issue.md` … `.agent/workflows/set-issue-source.md` — mirrors

**Modified files (migration — 13 files):**
- `plugins/autocoder/scripts/add-blocking-label.sh`
- `plugins/autocoder/scripts/approve-blocked-issue.sh`
- `plugins/autocoder/scripts/reject-blocked-issue.sh`
- `plugins/autocoder/scripts/fetch-blocked-issues.sh`
- `plugins/autocoder/scripts/regression-test.sh`
- `plugins/autocoder/commands/fix.md`
- `plugins/autocoder/commands/approve-proposal.md`
- `plugins/autocoder/commands/brainstorm-issue.md`
- `plugins/autocoder/commands/full-regression-test.md`
- `plugins/autocoder/commands/list-needs-design.md`
- `plugins/autocoder/commands/list-needs-feedback.md`
- `plugins/autocoder/commands/list-proposals.md`
- `plugins/autocoder/commands/monitor-workers.md`
- All `.agent/` mirrors of the above
- `README.md`, `CLAUDE.md`, `GEMINI.md` (if present)

---

## Task 1: `issues-file.py` — scaffolding + `list` and `get`

**Files:**
- Create: `plugins/autocoder/scripts/issues-file.py`
- Create: `tests/test_issues_file.py`

- [ ] **Step 1: Create the `tests/` directory and test file with fixtures and list/get tests**

```bash
mkdir -p tests
```

```python
# tests/test_issues_file.py
import json
import os
import subprocess
import textwrap
from pathlib import Path

import pytest

SCRIPT = Path(__file__).parent.parent / "plugins/autocoder/scripts/issues-file.py"


def run(args, env_override=None):
    env = {**os.environ, **(env_override or {})}
    r = subprocess.run(
        ["python3", str(SCRIPT)] + args,
        capture_output=True, text=True, env=env
    )
    return r.stdout.strip(), r.stderr.strip(), r.returncode


@pytest.fixture
def idir(tmp_path):
    d = tmp_path / ".issues"
    d.mkdir()
    return d


def write_issue(idir, number, title, status="open", labels=None, body="", assignee=None):
    labels = labels or []
    labels_yaml = "[" + ", ".join(labels) + "]"
    front = f"number: {number}\ntitle: {title}\nstatus: {status}\nlabels: {labels_yaml}\n"
    if assignee:
        front += f"assignee: {assignee}\n"
    path = idir / f"{number:03d}.md"
    path.write_text(f"---\n{front}---\n{body}\n")
    return path


class TestList:
    def test_empty_dir_returns_empty_array(self, idir):
        out, _, rc = run(["list"], {"ISSUE_DIR_PATH": str(idir)})
        assert rc == 0
        assert json.loads(out) == []

    def test_lists_open_issue(self, idir):
        write_issue(idir, 1, "Fix login bug", labels=["bug"])
        out, _, rc = run(["list"], {"ISSUE_DIR_PATH": str(idir)})
        assert rc == 0
        issues = json.loads(out)
        assert len(issues) == 1
        assert issues[0]["number"] == 1
        assert issues[0]["title"] == "Fix login bug"
        assert issues[0]["state"] == "OPEN"
        assert any(l["name"] == "bug" for l in issues[0]["labels"])

    def test_state_open_excludes_working(self, idir):
        write_issue(idir, 1, "Open", status="open")
        write_issue(idir, 2, "Working", status="working")
        write_issue(idir, 3, "Closed", status="closed")
        out, _, rc = run(["list", "--state", "open"], {"ISSUE_DIR_PATH": str(idir)})
        assert rc == 0
        issues = json.loads(out)
        titles = [i["title"] for i in issues]
        assert "Open" in titles
        assert "Working" not in titles
        assert "Closed" not in titles

    def test_state_closed_returns_only_closed(self, idir):
        write_issue(idir, 1, "Open", status="open")
        write_issue(idir, 2, "Closed", status="closed")
        out, _, rc = run(["list", "--state", "closed"], {"ISSUE_DIR_PATH": str(idir)})
        issues = json.loads(out)
        assert len(issues) == 1
        assert issues[0]["title"] == "Closed"

    def test_state_all_returns_all_statuses(self, idir):
        write_issue(idir, 1, "Open", status="open")
        write_issue(idir, 2, "Working", status="working")
        write_issue(idir, 3, "Closed", status="closed")
        out, _, rc = run(["list", "--state", "all"], {"ISSUE_DIR_PATH": str(idir)})
        assert rc == 0
        issues = json.loads(out)
        assert len(issues) == 3

    def test_label_filter(self, idir):
        write_issue(idir, 1, "Bug issue", labels=["bug"])
        write_issue(idir, 2, "Design issue", labels=["needs-design"])
        out, _, rc = run(["list", "--label", "bug"], {"ISSUE_DIR_PATH": str(idir)})
        issues = json.loads(out)
        assert len(issues) == 1
        assert issues[0]["title"] == "Bug issue"

    def test_limit(self, idir):
        for i in range(1, 6):
            write_issue(idir, i, f"Issue {i}")
        out, _, rc = run(["list", "--limit", "2"], {"ISSUE_DIR_PATH": str(idir)})
        issues = json.loads(out)
        assert len(issues) == 2


class TestGet:
    def test_get_existing_issue(self, idir):
        write_issue(idir, 7, "Dark mode", body="We need dark mode.")
        out, _, rc = run(["get", "7"], {"ISSUE_DIR_PATH": str(idir)})
        assert rc == 0
        issue = json.loads(out)
        assert issue["number"] == 7
        assert issue["title"] == "Dark mode"
        assert "We need dark mode." in issue["body"]

    def test_get_missing_issue_exits_nonzero(self, idir):
        _, err, rc = run(["get", "99"], {"ISSUE_DIR_PATH": str(idir)})
        assert rc != 0
        assert "99" in err
```

- [ ] **Step 2: Run tests — confirm they all fail (script doesn't exist yet)**

```bash
python3 -m pytest tests/test_issues_file.py -v 2>&1 | head -20
```
Expected: errors about missing script or `ModuleNotFoundError`.

- [ ] **Step 3: Create `issues-file.py` with scaffolding + `list` + `get`**

```python
#!/usr/bin/env python3
"""File-based issue backend. Manages .issues/NNN.md files.
All read-modify-write ops use fcntl.flock for safe concurrent access.

Environment:
  ISSUE_DIR_PATH  absolute path to .issues/ directory

Usage:
  issues-file.py list [--label L] [--state open|closed|all] [--limit N]
  issues-file.py get <number>
  issues-file.py update <number> [--add-label L] [--remove-label L] [--status S] [--assignee A]
  issues-file.py comment <number> --body "..."
  issues-file.py close <number> [--comment "..."]
  issues-file.py create --title "..." --body "..." [--label L]
  issues-file.py find-main-worktree
  issues-file.py import-from-gh
  issues-file.py export-to-gh
"""

import argparse
import fcntl
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


# ---------------------------------------------------------------------------
# Directory resolution
# ---------------------------------------------------------------------------

def get_issues_dir() -> Path:
    d = os.environ.get("ISSUE_DIR_PATH", "")
    if not d:
        sys.exit("Error: ISSUE_DIR_PATH not set. Source issue-config.sh first.")
    return Path(d)


def issue_path(issues_dir: Path, number: int) -> Path:
    return issues_dir / f"{number:03d}.md"


def seq_path(issues_dir: Path) -> Path:
    return issues_dir / ".seq"


# ---------------------------------------------------------------------------
# Frontmatter parsing (no external deps — we control the format)
# ---------------------------------------------------------------------------

def parse_issue_file(path: Path) -> dict:
    """Parse .issues/NNN.md into a dict with all fields + 'body' key."""
    content = path.read_text()
    if not content.startswith("---\n"):
        return {"body": content.strip()}
    end = content.find("\n---\n", 4)
    if end == -1:
        return {"body": content.strip()}
    front_text = content[4:end]
    body = content[end + 5:].strip()
    data = _parse_frontmatter(front_text)
    data["body"] = body
    return data


def _parse_frontmatter(text: str) -> dict:
    data = {}
    for line in text.splitlines():
        if ": " not in line and not line.endswith(":"):
            continue
        key, _, val = line.partition(": ")
        key = key.strip()
        val = val.strip()
        if val.startswith("[") and val.endswith("]"):
            inner = val[1:-1].strip()
            data[key] = [v.strip() for v in inner.split(",")] if inner else []
        elif re.fullmatch(r"\d+", val):
            data[key] = int(val)
        else:
            data[key] = val
    return data


def write_issue_file(path: Path, data: dict) -> None:
    """Write dict back to .issues/NNN.md (frontmatter + body)."""
    body = data.get("body", "")
    lines = []
    for key in ("number", "title", "priority", "labels", "status", "assignee"):
        if key not in data:
            continue
        val = data[key]
        if isinstance(val, list):
            lines.append(f"{key}: [{', '.join(val)}]")
        else:
            lines.append(f"{key}: {val}")
    front = "\n".join(lines)
    path.write_text(f"---\n{front}\n---\n{body}\n" if body else f"---\n{front}\n---\n")


# ---------------------------------------------------------------------------
# JSON output schema (matches gh issue list/view)
# ---------------------------------------------------------------------------

def to_gh_json(data: dict) -> dict:
    status = data.get("status", "open")
    state = "CLOSED" if status == "closed" else "OPEN"
    labels_raw = data.get("labels") or []
    labels = [{"name": l} for l in labels_raw]
    return {
        "number": data.get("number"),
        "title": data.get("title", ""),
        "body": data.get("body", ""),
        "state": state,
        "labels": labels,
        "comments": [],
    }


# ---------------------------------------------------------------------------
# Locking helpers
# ---------------------------------------------------------------------------

def lock_ex(fd):
    fcntl.flock(fd, fcntl.LOCK_EX)


def lock_sh(fd):
    fcntl.flock(fd, fcntl.LOCK_SH)


def unlock(fd):
    fcntl.flock(fd, fcntl.LOCK_UN)


# ---------------------------------------------------------------------------
# Subcommands: list, get
# ---------------------------------------------------------------------------

def cmd_list(args):
    issues_dir = get_issues_dir()
    results = []
    for p in sorted(issues_dir.glob("*.md")):
        if p.name.startswith("."):
            continue
        with open(p, "r") as f:
            lock_sh(f.fileno())
            try:
                data = parse_issue_file(p)
            finally:
                unlock(f.fileno())
        status = data.get("status", "open")
        # Apply --state filter ("all" passes everything through)
        if args.state and args.state != "all":
            if args.state == "open" and status != "open":
                continue
            if args.state == "closed" and status != "closed":
                continue
        # Apply --label filter
        if args.label:
            labels = data.get("labels") or []
            if args.label not in labels:
                continue
        results.append(to_gh_json(data))
    if args.limit:
        results = results[:args.limit]
    print(json.dumps(results, indent=2))


def cmd_get(args):
    issues_dir = get_issues_dir()
    p = issue_path(issues_dir, args.number)
    if not p.exists():
        sys.exit(f"Error: issue {args.number} not found ({p})")
    with open(p, "r") as f:
        lock_sh(f.fileno())
        try:
            data = parse_issue_file(p)
        finally:
            unlock(f.fileno())
    print(json.dumps(to_gh_json(data), indent=2))


# ---------------------------------------------------------------------------
# Main / argument parsing
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(prog="issues-file.py")
    sub = parser.add_subparsers(dest="cmd", required=True)

    # list
    p_list = sub.add_parser("list")
    p_list.add_argument("--label")
    p_list.add_argument("--state", choices=["open", "closed", "all"])
    p_list.add_argument("--limit", type=int)

    # get
    p_get = sub.add_parser("get")
    p_get.add_argument("number", type=int)

    # update (stub — Task 2)
    p_update = sub.add_parser("update")
    p_update.add_argument("number", type=int)
    p_update.add_argument("--add-label", dest="add_label")
    p_update.add_argument("--remove-label", dest="remove_label")
    p_update.add_argument("--status")
    p_update.add_argument("--assignee")

    # comment (stub — Task 2)
    p_comment = sub.add_parser("comment")
    p_comment.add_argument("number", type=int)
    p_comment.add_argument("--body", required=True)

    # close (stub — Task 2)
    p_close = sub.add_parser("close")
    p_close.add_argument("number", type=int)
    p_close.add_argument("--comment")

    # create (stub — Task 2)
    p_create = sub.add_parser("create")
    p_create.add_argument("--title", required=True)
    p_create.add_argument("--body", default="")
    p_create.add_argument("--label", action="append", default=[])

    # migration subcommands (stub — Task 3)
    sub.add_parser("find-main-worktree")
    sub.add_parser("import-from-gh")
    sub.add_parser("export-to-gh")

    args = parser.parse_args()

    if args.cmd == "list":
        cmd_list(args)
    elif args.cmd == "get":
        cmd_get(args)
    else:
        sys.exit(f"Subcommand '{args.cmd}' not yet implemented")


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run list/get tests — confirm they pass**

```bash
python3 -m pytest tests/test_issues_file.py::TestList tests/test_issues_file.py::TestGet -v
```
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add plugins/autocoder/scripts/issues-file.py tests/test_issues_file.py
git commit -m "feat: add issues-file.py scaffolding with list and get subcommands"
```

---

## Task 2: `issues-file.py` — write operations: `update`, `comment`, `close`, `create`

**Files:**
- Modify: `plugins/autocoder/scripts/issues-file.py`
- Modify: `tests/test_issues_file.py`

- [ ] **Step 1: Add write-operation tests to `tests/test_issues_file.py`**

Append these classes to the test file:

```python
class TestUpdate:
    def test_add_label(self, idir):
        write_issue(idir, 1, "T", labels=["bug"])
        run(["update", "1", "--add-label", "P1"], {"ISSUE_DIR_PATH": str(idir)})
        out, _, _ = run(["get", "1"], {"ISSUE_DIR_PATH": str(idir)})
        issue = json.loads(out)
        names = [l["name"] for l in issue["labels"]]
        assert "bug" in names
        assert "P1" in names

    def test_add_label_working_sets_status(self, idir):
        write_issue(idir, 1, "T", status="open")
        run(["update", "1", "--add-label", "working"], {"ISSUE_DIR_PATH": str(idir)})
        out, _, _ = run(["get", "1"], {"ISSUE_DIR_PATH": str(idir)})
        issue = json.loads(out)
        # state is OPEN (working maps to OPEN in schema) — check raw file
        p = idir / "001.md"
        content = p.read_text()
        assert "status: working" in content
        assert "working" in [l["name"] for l in issue["labels"]]

    def test_remove_label_working_sets_status_open(self, idir):
        write_issue(idir, 1, "T", status="working", labels=["working"])
        run(["update", "1", "--remove-label", "working"], {"ISSUE_DIR_PATH": str(idir)})
        p = idir / "001.md"
        content = p.read_text()
        assert "status: open" in content
        assert "working" not in content.split("---")[1]  # not in frontmatter labels

    def test_remove_non_working_label_no_status_change(self, idir):
        write_issue(idir, 1, "T", status="open", labels=["bug", "P1"])
        run(["update", "1", "--remove-label", "bug"], {"ISSUE_DIR_PATH": str(idir)})
        p = idir / "001.md"
        content = p.read_text()
        assert "status: open" in content
        assert "bug" not in content

    def test_set_status_directly(self, idir):
        write_issue(idir, 1, "T", status="open")
        run(["update", "1", "--status", "working"], {"ISSUE_DIR_PATH": str(idir)})
        p = idir / "001.md"
        assert "status: working" in p.read_text()

    def test_set_assignee(self, idir):
        write_issue(idir, 1, "T")
        run(["update", "1", "--assignee", "feat-login"], {"ISSUE_DIR_PATH": str(idir)})
        p = idir / "001.md"
        assert "assignee: feat-login" in p.read_text()


class TestComment:
    def test_appends_blockquote(self, idir):
        write_issue(idir, 1, "T", body="Original body.")
        run(["comment", "1", "--body", "Review done."], {"ISSUE_DIR_PATH": str(idir)})
        p = idir / "001.md"
        content = p.read_text()
        assert "Original body." in content
        assert "> " in content
        assert "Review done." in content


class TestClose:
    def test_sets_status_closed(self, idir):
        write_issue(idir, 1, "T", status="open")
        run(["close", "1"], {"ISSUE_DIR_PATH": str(idir)})
        p = idir / "001.md"
        assert "status: closed" in p.read_text()

    def test_appends_comment_if_given(self, idir):
        write_issue(idir, 1, "T", status="open")
        run(["close", "1", "--comment", "Done."], {"ISSUE_DIR_PATH": str(idir)})
        p = idir / "001.md"
        content = p.read_text()
        assert "status: closed" in content
        assert "Done." in content


class TestCreate:
    def test_creates_file_and_returns_number(self, idir):
        out, _, rc = run(
            ["create", "--title", "New issue", "--body", "Details."],
            {"ISSUE_DIR_PATH": str(idir)}
        )
        assert rc == 0
        result = json.loads(out)
        assert "number" in result
        n = result["number"]
        p = idir / f"{n:03d}.md"
        assert p.exists()
        assert "New issue" in p.read_text()

    def test_create_allocates_sequential_numbers(self, idir):
        write_issue(idir, 3, "Existing")
        out, _, _ = run(
            ["create", "--title", "Next", "--body", ""],
            {"ISSUE_DIR_PATH": str(idir)}
        )
        result = json.loads(out)
        assert result["number"] == 4

    def test_create_with_labels(self, idir):
        out, _, _ = run(
            ["create", "--title", "T", "--body", "", "--label", "bug", "--label", "P1"],
            {"ISSUE_DIR_PATH": str(idir)}
        )
        n = json.loads(out)["number"]
        p = idir / f"{n:03d}.md"
        content = p.read_text()
        assert "bug" in content
        assert "P1" in content
```

- [ ] **Step 2: Run new tests — confirm they fail**

```bash
python3 -m pytest tests/test_issues_file.py::TestUpdate tests/test_issues_file.py::TestComment tests/test_issues_file.py::TestClose tests/test_issues_file.py::TestCreate -v 2>&1 | tail -20
```
Expected: FAIL — subcommands return "not yet implemented".

- [ ] **Step 3: Implement `update`, `comment`, `close`, `create` in `issues-file.py`**

Add these functions above `main()`:

```python
def cmd_update(args):
    issues_dir = get_issues_dir()
    p = issue_path(issues_dir, args.number)
    if not p.exists():
        sys.exit(f"Error: issue {args.number} not found")
    with open(p, "r+") as f:
        lock_ex(f.fileno())
        try:
            data = parse_issue_file(p)
            labels = list(data.get("labels") or [])

            if args.add_label:
                if args.add_label not in labels:
                    labels.append(args.add_label)
                # working label coupling
                if args.add_label == "working":
                    data["status"] = "working"

            if args.remove_label:
                labels = [l for l in labels if l != args.remove_label]
                # working label coupling
                if args.remove_label == "working":
                    data["status"] = "open"

            if args.status:
                data["status"] = args.status

            if args.assignee:
                data["assignee"] = args.assignee

            data["labels"] = labels
            write_issue_file(p, data)
        finally:
            unlock(f.fileno())


def cmd_comment(args):
    issues_dir = get_issues_dir()
    p = issue_path(issues_dir, args.number)
    if not p.exists():
        sys.exit(f"Error: issue {args.number} not found")
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M")
    blockquote = f"\n> **{ts}** {args.body}"
    with open(p, "r+") as f:
        lock_ex(f.fileno())
        try:
            data = parse_issue_file(p)
            data["body"] = (data.get("body") or "") + blockquote
            write_issue_file(p, data)
        finally:
            unlock(f.fileno())


def cmd_close(args):
    issues_dir = get_issues_dir()
    p = issue_path(issues_dir, args.number)
    if not p.exists():
        sys.exit(f"Error: issue {args.number} not found")
    with open(p, "r+") as f:
        lock_ex(f.fileno())
        try:
            data = parse_issue_file(p)
            data["status"] = "closed"
            if args.comment:
                ts = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M")
                data["body"] = (data.get("body") or "") + f"\n> **{ts}** {args.comment}"
            write_issue_file(p, data)
        finally:
            unlock(f.fileno())


def cmd_create(args):
    issues_dir = get_issues_dir()
    seq = seq_path(issues_dir)
    # Ensure .seq exists for locking
    seq.touch()
    with open(seq, "r+") as f:
        lock_ex(f.fileno())
        try:
            existing = sorted(
                int(p.stem) for p in issues_dir.glob("*.md")
                if p.stem.isdigit()
            )
            number = (existing[-1] + 1) if existing else 1
            data = {
                "number": number,
                "title": args.title,
                "labels": args.label or [],
                "status": "open",
                "body": args.body or "",
            }
            write_issue_file(issue_path(issues_dir, number), data)
        finally:
            unlock(f.fileno())
    print(json.dumps({"number": number}))
```

Update the `main()` dispatch to call these:

```python
    elif args.cmd == "update":
        cmd_update(args)
    elif args.cmd == "comment":
        cmd_comment(args)
    elif args.cmd == "close":
        cmd_close(args)
    elif args.cmd == "create":
        cmd_create(args)
```

- [ ] **Step 4: Run all tests — confirm they pass**

```bash
python3 -m pytest tests/test_issues_file.py -v
```
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add plugins/autocoder/scripts/issues-file.py tests/test_issues_file.py
git commit -m "feat: implement issues-file.py write operations (update, comment, close, create)"
```

---

## Task 3: `issues-file.py` — migration subcommands

**Files:**
- Modify: `plugins/autocoder/scripts/issues-file.py`
- Modify: `tests/test_issues_file.py`

- [ ] **Step 1: Add smoke tests**

Append to `tests/test_issues_file.py`:

```python
class TestFindMainWorktree:
    def test_returns_absolute_path(self):
        out, _, rc = run(["find-main-worktree"])
        assert rc == 0
        assert out.startswith("/")
        assert Path(out).is_dir()
```

- [ ] **Step 2: Run — confirm fail**

```bash
python3 -m pytest tests/test_issues_file.py::TestFindMainWorktree -v
```
Expected: FAIL.

- [ ] **Step 3: Implement migration subcommands**

Add these functions above `main()`:

```python
def cmd_find_main_worktree():
    result = subprocess.run(
        ["git", "worktree", "list", "--porcelain"],
        capture_output=True, text=True, check=True
    )
    for line in result.stdout.splitlines():
        if line.startswith("worktree "):
            print(line.split(" ", 1)[1])
            return
    sys.exit("Error: could not find main worktree")


def cmd_import_from_gh():
    issues_dir = get_issues_dir()
    result = subprocess.run(
        ["gh", "issue", "list", "--state", "open",
         "--json", "number,title,body,labels,state", "--limit", "200"],
        capture_output=True, text=True, check=True
    )
    issues = json.loads(result.stdout)
    seq = seq_path(issues_dir)
    seq.touch()
    with open(seq, "r+") as f:
        lock_ex(f.fileno())
        try:
            for gh in issues:
                number = gh["number"]
                labels = [l["name"] for l in gh.get("labels", [])]
                data = {
                    "number": number,
                    "title": gh.get("title", ""),
                    "labels": labels,
                    "status": "open",
                    "body": gh.get("body", "") or "",
                }
                write_issue_file(issue_path(issues_dir, number), data)
        finally:
            unlock(f.fileno())
    print(f"Imported {len(issues)} issues to {issues_dir}")


def cmd_export_to_gh():
    issues_dir = get_issues_dir()
    exported = 0
    for p in sorted(issues_dir.glob("*.md")):
        if p.name.startswith("."):
            continue
        data = parse_issue_file(p)
        if data.get("status") == "closed":
            continue
        labels = data.get("labels") or []
        create_args = ["gh", "issue", "create",
                       "--title", data.get("title", ""),
                       "--body", data.get("body", "") or ""]
        for l in labels:
            create_args += ["--label", l]
        subprocess.run(create_args, check=True)
        exported += 1
    print(f"Exported {exported} issues to GitHub")
```

Update `main()` dispatch:

```python
    elif args.cmd == "find-main-worktree":
        cmd_find_main_worktree()
    elif args.cmd == "import-from-gh":
        cmd_import_from_gh()
    elif args.cmd == "export-to-gh":
        cmd_export_to_gh()
```

- [ ] **Step 4: Run tests**

```bash
python3 -m pytest tests/test_issues_file.py -v
```
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add plugins/autocoder/scripts/issues-file.py tests/test_issues_file.py
git commit -m "feat: add find-main-worktree, import-from-gh, export-to-gh to issues-file.py"
```

---

## Task 4: `issue-config.sh` — detection, caching, non-interactive fail-fast

**Files:**
- Create: `plugins/autocoder/scripts/issue-config.sh`
- Create: `tests/test_issue_config.sh`

- [ ] **Step 1: Write the test script**

```bash
#!/bin/bash
# tests/test_issue_config.sh — smoke tests for issue-config.sh
set -e
PASS=0; FAIL=0
SCRIPT="plugins/autocoder/scripts/issue-config.sh"

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "PASS: $label"; ((PASS++))
  else
    echo "FAIL: $label — expected '$expected', got '$actual'"; ((FAIL++))
  fi
}

# Test: script is sourceable without errors
assert_eq "script is sourceable" "0" "$(bash -c "source $SCRIPT; echo 0" 2>/dev/null || echo 1)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 2: Create `issue-config.sh`**

```bash
#!/bin/bash
# issue-config.sh — detect and cache the issue backend
# Source this file. Exports: ISSUE_SOURCE, ISSUE_DIR_PATH, ISSUE_BACKEND
# Non-interactive mode: exits 1 with error if no cached config and no TTY.

# Avoid re-running if already loaded
if [ -n "$ISSUE_SOURCE" ]; then
  return 0 2>/dev/null || exit 0
fi

_ic_MAIN_WORKTREE=$(git worktree list --porcelain 2>/dev/null | grep -m1 "^worktree" | cut -d' ' -f2)
_ic_JSON="${_ic_MAIN_WORKTREE}/.autocoder.json"

# ── 1. Read cached config ──────────────────────────────────────────────────
if [ -f "$_ic_JSON" ]; then
  _ic_SOURCE=$(python3 -c "
import json, sys
try:
    d = json.load(open('$_ic_JSON'))
    print(d.get('issueSource', ''))
except Exception:
    print('')
" 2>/dev/null)
  if [ -n "$_ic_SOURCE" ]; then
    export ISSUE_SOURCE="$_ic_SOURCE"
    if [ "$ISSUE_SOURCE" = "file" ]; then
      _ic_DIR=$(python3 -c "
import json
d = json.load(open('$_ic_JSON'))
print(d.get('issueDir', ''))
" 2>/dev/null)
      export ISSUE_DIR_PATH="${_ic_DIR:-${_ic_MAIN_WORKTREE}/.issues}"
    fi
    _ic_BACKEND=$(python3 -c "
import json
d = json.load(open('$_ic_JSON'))
print(d.get('issueBackend', ''))
" 2>/dev/null)
    if [ -n "$_ic_BACKEND" ]; then
      export ISSUE_BACKEND="$_ic_BACKEND"
    fi
    return 0 2>/dev/null || exit 0
  fi
fi

# ── 2. Non-interactive fail-fast ───────────────────────────────────────────
if [ ! -t 0 ] && [ ! -t 1 ]; then
  echo "Error: No issue source configured." >&2
  echo "Run /set-issue-source to choose an issue source before running autonomous commands." >&2
  exit 1
fi

# ── 3. Check for .issues/ directory ───────────────────────────────────────
_ic_ISSUES_DIR="${_ic_MAIN_WORKTREE}/.issues"
if [ -d "$_ic_ISSUES_DIR" ]; then
  echo "Found .issues/ — using it as the issue source."
  read -r -p "Use .issues/ as the issue source? [Y/n] " _ic_CONFIRM
  _ic_CONFIRM="${_ic_CONFIRM:-Y}"
  if [[ "$_ic_CONFIRM" =~ ^[Yy]$ ]]; then
    python3 -c "
import json, os
path = '$_ic_JSON'
d = json.load(open(path)) if os.path.exists(path) else {}
d['issueSource'] = 'file'
d['issueDir'] = '$_ic_ISSUES_DIR'
json.dump(d, open(path, 'w'), indent=2)
"
    export ISSUE_SOURCE="file"
    export ISSUE_DIR_PATH="$_ic_ISSUES_DIR"
    return 0 2>/dev/null || exit 0
  fi
fi

# ── 4. Check for GitHub remote ─────────────────────────────────────────────
if git remote -v 2>/dev/null | grep -q "github.com"; then
  echo "No local issues directory found. This repo is on GitHub — using gh issues."
  read -r -p "Use GitHub Issues? [Y/n] " _ic_CONFIRM
  _ic_CONFIRM="${_ic_CONFIRM:-Y}"
  if [[ "$_ic_CONFIRM" =~ ^[Yy]$ ]]; then
    python3 -c "
import json, os
path = '$_ic_JSON'
d = json.load(open(path)) if os.path.exists(path) else {}
d['issueSource'] = 'github'
json.dump(d, open(path, 'w'), indent=2)
"
    export ISSUE_SOURCE="github"
    return 0 2>/dev/null || exit 0
  fi
fi

# ── 5. Neither found — ask user ────────────────────────────────────────────
echo ""
echo "No issue source found. Choose:"
echo "  1) Create .issues/ directory and use file backend"
if git remote -v 2>/dev/null | grep -q "github.com"; then
  echo "  2) Use GitHub Issues"
fi
read -r -p "Choice [1]: " _ic_CHOICE
_ic_CHOICE="${_ic_CHOICE:-1}"

if [ "$_ic_CHOICE" = "1" ]; then
  mkdir -p "$_ic_ISSUES_DIR"
  python3 -c "
import json, os
path = '$_ic_JSON'
d = json.load(open(path)) if os.path.exists(path) else {}
d['issueSource'] = 'file'
d['issueDir'] = '$_ic_ISSUES_DIR'
json.dump(d, open(path, 'w'), indent=2)
"
  export ISSUE_SOURCE="file"
  export ISSUE_DIR_PATH="$_ic_ISSUES_DIR"
elif [ "$_ic_CHOICE" = "2" ]; then
  python3 -c "
import json, os
path = '$_ic_JSON'
d = json.load(open(path)) if os.path.exists(path) else {}
d['issueSource'] = 'github'
json.dump(d, open(path, 'w'), indent=2)
"
  export ISSUE_SOURCE="github"
fi
```

- [ ] **Step 3: Run the test**

```bash
bash tests/test_issue_config.sh
```
Expected: all pass.

- [ ] **Step 4: Commit**

```bash
git add plugins/autocoder/scripts/issue-config.sh tests/test_issue_config.sh
git commit -m "feat: add issue-config.sh — detection, caching, non-interactive fail-fast"
```

---

## Task 5: `issue-fns.sh` — shell function layer

**Files:**
- Create: `plugins/autocoder/scripts/issue-fns.sh`
- Create: `tests/test_issue_fns.sh`

- [ ] **Step 1: Write the test script**

```bash
#!/bin/bash
# tests/test_issue_fns.sh — tests for issue-fns.sh dispatch and translation
set -e
PASS=0; FAIL=0
SCRIPT_DIR="plugins/autocoder/scripts"

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -q "$needle"; then
    echo "PASS: $label"; ((PASS++))
  else
    echo "FAIL: $label — '$needle' not in output"; ((FAIL++))
  fi
}

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if ! echo "$haystack" | grep -q "$needle"; then
    echo "PASS: $label"; ((PASS++))
  else
    echo "FAIL: $label — '$needle' unexpectedly in output"; ((FAIL++))
  fi
}

# ── Set up a mock file backend ─────────────────────────────────────────────
TMP=$(mktemp -d)
ISSUES_DIR="$TMP/.issues"
mkdir -p "$ISSUES_DIR"

# Pre-populate one open issue
cat > "$ISSUES_DIR/001.md" <<'EOF'
---
number: 1
title: Test issue
labels: [bug]
status: open
---
Body text.
EOF

# ── Test: issue_list via file backend ─────────────────────────────────────
OUT=$(ISSUE_SOURCE=file ISSUE_DIR_PATH="$ISSUES_DIR" \
  bash -c "source $SCRIPT_DIR/issue-fns.sh; issue_list" 2>/dev/null)
assert_contains "issue_list returns JSON" '"title"' "$OUT"
assert_contains "issue_list returns test issue" 'Test issue' "$OUT"

# ── Test: issue_list --priority translates to --label ─────────────────────
OUT=$(ISSUE_SOURCE=file ISSUE_DIR_PATH="$ISSUES_DIR" \
  bash -c "source $SCRIPT_DIR/issue-fns.sh; issue_list --priority P1" 2>/dev/null)
# P1 label doesn't exist on our test issue, so result should be empty array
assert_contains "issue_list --priority produces JSON" '[' "$OUT"

# ── Test: issue_get returns specific issue ─────────────────────────────────
OUT=$(ISSUE_SOURCE=file ISSUE_DIR_PATH="$ISSUES_DIR" \
  bash -c "source $SCRIPT_DIR/issue-fns.sh; issue_get 1" 2>/dev/null)
assert_contains "issue_get returns issue 1" '"number": 1' "$OUT"

# ── Test: issue_update --add-label ────────────────────────────────────────
ISSUE_SOURCE=file ISSUE_DIR_PATH="$ISSUES_DIR" \
  bash -c "source $SCRIPT_DIR/issue-fns.sh; issue_update 1 --add-label needs-design" 2>/dev/null
assert_contains "issue_update adds label" 'needs-design' "$(cat $ISSUES_DIR/001.md)"

# ── Test: issue_close ─────────────────────────────────────────────────────
ISSUE_SOURCE=file ISSUE_DIR_PATH="$ISSUES_DIR" \
  bash -c "source $SCRIPT_DIR/issue-fns.sh; issue_close 1 --comment 'Fixed.'" 2>/dev/null
assert_contains "issue_close sets status closed" 'status: closed' "$(cat $ISSUES_DIR/001.md)"

# ── Test: issue_create ────────────────────────────────────────────────────
OUT=$(ISSUE_SOURCE=file ISSUE_DIR_PATH="$ISSUES_DIR" \
  bash -c "source $SCRIPT_DIR/issue-fns.sh; issue_create --title 'New one' --body 'Details'" 2>/dev/null)
assert_contains "issue_create returns number" '"number"' "$OUT"

rm -rf "$TMP"
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 2: Run — confirm failures**

```bash
bash tests/test_issue_fns.sh
```
Expected: failures — script doesn't exist yet.

- [ ] **Step 3: Create `issue-fns.sh`**

Note on `_ifns_gh_create`: `gh issue create` outputs the created issue URL (e.g., `https://github.com/owner/repo/issues/42`) — it has no `--json` flag. Extract the number by parsing the trailing digits of that URL.

```bash
#!/bin/bash
# issue-fns.sh — shared shell function layer for issue backend dispatch.
# Source this file; do not execute it directly.
# Provides: issue_list, issue_get, issue_update, issue_comment, issue_close, issue_create

# Bootstrap: source issue-config.sh if not already loaded
if [ -z "$ISSUE_SOURCE" ]; then
  _ifns_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=issue-config.sh
  source "${_ifns_DIR}/issue-config.sh"
fi

_ifns_PY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/issues-file.py"

# ── Internal: dispatch to file backend ────────────────────────────────────
_ifns_file() {
  python3 "$_ifns_PY" "$@"
}

# ── Internal: GitHub backend implementations ──────────────────────────────
_ifns_gh_list() {
  local args=() priority=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --priority) priority="$2"; shift 2 ;;
      *) args+=("$1"); shift ;;
    esac
  done
  [ -n "$priority" ] && args+=(--label "$priority")
  gh issue list "${args[@]}" --json number,title,body,labels,state
}

_ifns_gh_update() {
  local number="$1"; shift
  local add_labels=() remove_labels=() status=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --add-label)    add_labels+=("$2"); shift 2 ;;
      --remove-label) remove_labels+=("$2"); shift 2 ;;
      --status)       status="$2"; shift 2 ;;
      --assignee)     shift 2 ;;  # file-backend-only; stripped here
      *)              shift ;;
    esac
  done
  # --status translation
  if [ -n "$status" ]; then
    case "$status" in
      closed)  gh issue close "$number" ;;
      open)    gh issue reopen "$number" ;;
      working) gh issue edit "$number" --add-label "working" ;;
    esac
  fi
  # Label changes
  local edit_args=()
  for l in "${add_labels[@]}";    do edit_args+=(--add-label    "$l"); done
  for l in "${remove_labels[@]}"; do edit_args+=(--remove-label "$l"); done
  [ "${#edit_args[@]}" -gt 0 ] && gh issue edit "$number" "${edit_args[@]}"
}

_ifns_gh_close() {
  local number="$1"; shift
  local comment=""
  while [[ $# -gt 0 ]]; do
    case "$1" in --comment) comment="$2"; shift 2 ;; *) shift ;; esac
  done
  if [ -n "$comment" ]; then
    gh issue close "$number" --comment "$comment"
  else
    gh issue close "$number"
  fi
}

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
  # gh issue create outputs the URL (e.g. https://github.com/owner/repo/issues/42)
  local issue_url
  issue_url=$(gh issue create "${create_args[@]}")
  local number
  number=$(echo "$issue_url" | grep -oE '[0-9]+$')
  echo "{\"number\": $number}"
}

# ── Public functions ──────────────────────────────────────────────────────

issue_list() {
  local args=() priority=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --priority) priority="$2"; shift 2 ;;
      *) args+=("$1"); shift ;;
    esac
  done
  [ -n "$priority" ] && args+=(--label "$priority")
  case "$ISSUE_SOURCE" in
    github) _ifns_gh_list "${args[@]}" ;;
    file)   _ifns_file list "${args[@]}" ;;
    *)      "$ISSUE_BACKEND" list "${args[@]}" ;;
  esac
}

issue_get() {
  case "$ISSUE_SOURCE" in
    github) gh issue view "$1" --json number,title,body,labels,state,comments ;;
    file)   _ifns_file get "$@" ;;
    *)      "$ISSUE_BACKEND" get "$@" ;;
  esac
}

issue_update() {
  case "$ISSUE_SOURCE" in
    github) _ifns_gh_update "$@" ;;
    file)   _ifns_file update "$@" ;;
    *)      "$ISSUE_BACKEND" update "$@" ;;
  esac
}

issue_comment() {
  case "$ISSUE_SOURCE" in
    github)
      local number="$1"; shift
      local body=""
      while [[ $# -gt 0 ]]; do
        case "$1" in --body) body="$2"; shift 2 ;; *) shift ;; esac
      done
      gh issue comment "$number" --body "$body"
      ;;
    file) _ifns_file comment "$@" ;;
    *)    "$ISSUE_BACKEND" comment "$@" ;;
  esac
}

issue_close() {
  case "$ISSUE_SOURCE" in
    github) _ifns_gh_close "$@" ;;
    file)   _ifns_file close "$@" ;;
    *)      "$ISSUE_BACKEND" close "$@" ;;
  esac
}

issue_create() {
  case "$ISSUE_SOURCE" in
    github) _ifns_gh_create "$@" ;;
    file)   _ifns_file create "$@" ;;
    *)      "$ISSUE_BACKEND" create "$@" ;;
  esac
}
```

- [ ] **Step 4: Run tests**

```bash
bash tests/test_issue_fns.sh
```
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add plugins/autocoder/scripts/issue-fns.sh tests/test_issue_fns.sh
git commit -m "feat: add issue-fns.sh — six dispatch functions with priority/status translation"
```

---

## Task 6: Migrate shell scripts (5 files)

**Files:**
- Modify: `plugins/autocoder/scripts/add-blocking-label.sh`
- Modify: `plugins/autocoder/scripts/approve-blocked-issue.sh`
- Modify: `plugins/autocoder/scripts/reject-blocked-issue.sh`
- Modify: `plugins/autocoder/scripts/fetch-blocked-issues.sh`
- Modify: `plugins/autocoder/scripts/regression-test.sh`

No automated tests — these call `gh` at runtime. Verify by reading the diff and confirming each replacement is semantically correct.

The migration pattern for every shell script:

1. Add after `set -e`:
   ```bash
   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
   source "${SCRIPT_DIR}/issue-fns.sh"
   ```
2. Replace each `gh issue` call with the equivalent `issue_*` function.
3. Remove `--json <fields>` arguments (our functions always return full JSON).
4. Replace `gh issue list ... --jq '<expr>'` with `issue_list ... | jq '<expr>'`.

- [ ] **Step 1: Migrate `add-blocking-label.sh`**

Replace:
```bash
gh issue edit "$ISSUE_NUM" --add-label "$BLOCKING_LABEL"
```
With:
```bash
issue_update "$ISSUE_NUM" --add-label "$BLOCKING_LABEL"
```

Replace:
```bash
gh issue comment "$ISSUE_NUM" --body "$COMMENT_BODY"
```
With:
```bash
issue_comment "$ISSUE_NUM" --body "$COMMENT_BODY"
```

Replace:
```bash
gh issue edit "$ISSUE_NUM" --remove-label "working" 2>/dev/null || true
```
With:
```bash
issue_update "$ISSUE_NUM" --remove-label "working" 2>/dev/null || true
```

Add `source` line after `set -e`. Verify no `gh issue` calls remain:
```bash
grep "gh issue" plugins/autocoder/scripts/add-blocking-label.sh
```
Expected: no output.

- [ ] **Step 2: Migrate `approve-blocked-issue.sh`**

Replace:
```bash
gh issue edit "$ISSUE_NUM" --remove-label "$BLOCKING_LABEL"
```
With:
```bash
issue_update "$ISSUE_NUM" --remove-label "$BLOCKING_LABEL"
```

Replace:
```bash
gh issue comment "$ISSUE_NUM" --body "..."
```
With:
```bash
issue_comment "$ISSUE_NUM" --body "..."
```

Add `source` line. Verify:
```bash
grep "gh issue" plugins/autocoder/scripts/approve-blocked-issue.sh
```
Expected: no output.

- [ ] **Step 3: Migrate `reject-blocked-issue.sh`**

Replace:
```bash
gh issue close "$ISSUE_NUM" --comment "❌ **Rejected**..."
```
With:
```bash
issue_close "$ISSUE_NUM" --comment "❌ **Rejected**..."
```

Add `source` line. Verify:
```bash
grep "gh issue" plugins/autocoder/scripts/reject-blocked-issue.sh
```
Expected: no output.

- [ ] **Step 4: Migrate `fetch-blocked-issues.sh`**

Replace:
```bash
gh issue list --state open --json number,title,labels,body,comments --limit 200 > /tmp/all-issues.json
```
With:
```bash
issue_list --state open --limit 200 > /tmp/all-issues.json
```

Remove the `gh label list` / label creation block — this is GitHub-specific label management. Add a guard:
```bash
if [ "$ISSUE_SOURCE" = "github" ]; then
  # Create blocking labels if they don't exist (GitHub only)
  EXISTING_LABELS=$(gh label list --json name --jq '.[].name' 2>/dev/null || echo "")
  # ... existing label creation code ...
fi
```

Add `source` line. Verify:
```bash
grep "gh issue" plugins/autocoder/scripts/fetch-blocked-issues.sh
```
Expected: no output.

- [ ] **Step 5: Migrate `regression-test.sh`**

Replace:
```bash
gh issue list --state open --json number,title,labels,body --limit 100 > /tmp/gh-issues.json
```
With:
```bash
issue_list --state open --limit 100 > /tmp/gh-issues.json
```

Replace:
```bash
gh issue comment "$EXISTING_ISSUE" --body "..."
```
With:
```bash
issue_comment "$EXISTING_ISSUE" --body "..."
```

Replace:
```bash
gh issue create \
  --title "..." \
  --body "..." \
  --label "..."
```
With:
```bash
RESULT=$(issue_create --title "..." --body "..." --label "...")
```

Add `source` line. Verify:
```bash
grep "gh issue" plugins/autocoder/scripts/regression-test.sh
```
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add plugins/autocoder/scripts/add-blocking-label.sh \
        plugins/autocoder/scripts/approve-blocked-issue.sh \
        plugins/autocoder/scripts/reject-blocked-issue.sh \
        plugins/autocoder/scripts/fetch-blocked-issues.sh \
        plugins/autocoder/scripts/regression-test.sh
git commit -m "feat: migrate shell scripts from gh issue to issue_* functions"
```

---

## Task 7: Migrate `fix.md` (46 `gh issue` calls)

**Files:**
- Modify: `plugins/autocoder/commands/fix.md`

`fix.md` is a Claude Code command protocol document. Its `gh issue` calls appear in bash code blocks that the agent executes. The migration adds a sourcing preamble and replaces each call.

- [ ] **Step 1: Add sourcing preamble to `fix.md`**

Near the top of `fix.md`, in the "Setup" or first bash block where the agent initialises its environment, add:

```bash
# Source issue function layer (routes to GitHub or file backend)
source plugins/autocoder/scripts/issue-fns.sh
```

If `fix.md` has no dedicated setup section, add this as the first bash block with the comment "Environment setup".

- [ ] **Step 2: Replace `gh issue list` calls in `fix.md`**

Pattern to replace (there are several variants):
```bash
# Before:
gh issue list --state open --json number,title,body,labels --limit 100 > /tmp/all-open-issues.json
gh issue list --state open --json number,title,body,labels --limit 100 > /tmp/all-issues.json
# After:
issue_list --state open --limit 100 > /tmp/all-open-issues.json
issue_list --state open --limit 100 > /tmp/all-issues.json
```

For `--jq` forms:
```bash
# Before:
gh issue list --state open --json number,title,body,labels --limit 100 --jq '.[].number'
# After:
issue_list --state open --limit 100 | jq -r '.[].number'
```

- [ ] **Step 3: Replace `gh issue view` calls**

```bash
# Before:
gh issue view "$SPECIFIED_ISSUE" --json number,title,body,labels > /tmp/top-issue.json
gh issue view "$ISSUE_NUM" --json comments --jq '[.comments[...]] | length'
# After:
issue_get "$SPECIFIED_ISSUE" > /tmp/top-issue.json
issue_get "$ISSUE_NUM" | jq '[.comments[] | select(...)] | length'
```

- [ ] **Step 4: Replace `gh issue edit` calls (claiming + label management)**

```bash
# Before:
gh issue edit "$ISSUE_NUM" --add-label "working" 2>/dev/null || true
gh issue edit "$ISSUE_NUM" --remove-label "working" 2>/dev/null || true
gh issue edit "$ISSUE_NUM" --add-label "needs-design"
# After:
issue_update "$ISSUE_NUM" --add-label "working" 2>/dev/null || true
issue_update "$ISSUE_NUM" --remove-label "working" 2>/dev/null || true
issue_update "$ISSUE_NUM" --add-label "needs-design"
```

- [ ] **Step 5: Replace `gh issue comment` calls**

```bash
# Before:
gh issue comment "$ISSUE_NUM" --body "🤖 **Automated Fix Started**..."
# After:
issue_comment "$ISSUE_NUM" --body "🤖 **Automated Fix Started**..."
```

- [ ] **Step 6: Replace `gh issue close` calls**

```bash
# Before:
gh issue close "$ISSUE_NUM" --comment "✅ **Issue Resolved**..."
# After:
issue_close "$ISSUE_NUM" --comment "✅ **Issue Resolved**..."
```

- [ ] **Step 7: Replace `gh issue create` calls (sub-task creation)**

```bash
# Before:
SUBTASK_NUM=$(gh issue create \
  --title "Sub-task: ..." \
  --body "..." \
  --label "P1" | grep -oP '#\K[0-9]+')
# After:
SUBTASK_RESULT=$(issue_create --title "Sub-task: ..." --body "..." --label "P1")
SUBTASK_NUM=$(echo "$SUBTASK_RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin)['number'])")
```

- [ ] **Step 8: Verify no `gh issue` calls remain**

```bash
grep -n "gh issue" plugins/autocoder/commands/fix.md
```
Expected: no output. If any remain, fix them before committing.

- [ ] **Step 9: Commit**

```bash
git add plugins/autocoder/commands/fix.md
git commit -m "feat: migrate fix.md from gh issue to issue_* functions (46 calls)"
```

---

## Task 8: Migrate remaining 7 command files

**Files:**
- Modify: `plugins/autocoder/commands/approve-proposal.md`
- Modify: `plugins/autocoder/commands/brainstorm-issue.md`
- Modify: `plugins/autocoder/commands/full-regression-test.md`
- Modify: `plugins/autocoder/commands/list-needs-design.md`
- Modify: `plugins/autocoder/commands/list-needs-feedback.md`
- Modify: `plugins/autocoder/commands/list-proposals.md`
- Modify: `plugins/autocoder/commands/monitor-workers.md`

Same pattern as Task 7: add sourcing preamble, replace all `gh issue` calls.

- [ ] **Step 1: Migrate `approve-proposal.md` (3 calls)**

Add sourcing preamble. Then:
```bash
# Before:
ISSUE_NUMBERS=($(gh issue list --state open --label "proposal" --json number --jq '.[].number'))
ISSUE_INFO=$(gh issue view "$num" --json number,title,labels,state 2>/dev/null)
gh issue edit "$num" --remove-label "proposal" >/dev/null 2>&1
# After:
ISSUE_NUMBERS=($(issue_list --state open --label "proposal" | jq -r '.[].number'))
ISSUE_INFO=$(issue_get "$num" 2>/dev/null)
issue_update "$num" --remove-label "proposal" >/dev/null 2>&1
```

Verify: `grep "gh issue" plugins/autocoder/commands/approve-proposal.md` → no output.

- [ ] **Step 2: Migrate `brainstorm-issue.md` (5 calls)**

```bash
# Before:
ISSUE_NUM=$(gh issue list --state open --label "needs-design" --json number --jq '.[0].number' 2>/dev/null)
gh issue view "$ISSUE_NUM" --json number,title,body,labels,comments > /tmp/brainstorm-issue.json
gh issue comment "$ISSUE_NUM" --body "$(cat <<'BRAINSTORM_BODY' ..."
# After:
ISSUE_NUM=$(issue_list --state open --label "needs-design" | jq -r '.[0].number // empty' 2>/dev/null)
issue_get "$ISSUE_NUM" > /tmp/brainstorm-issue.json
issue_comment "$ISSUE_NUM" --body "$(cat <<'BRAINSTORM_BODY' ..."
```

Note: any documentation prose referencing `gh issue edit <number> --add-label needs-design` should be updated to `issue_update <ISSUE_NUM> --add-label needs-design` for consistency.

Verify: `grep "gh issue" plugins/autocoder/commands/brainstorm-issue.md` → no output.

- [ ] **Step 3: Migrate `full-regression-test.md` (10 calls)**

```bash
# Before (line 287):
gh issue list --state all --json number,title,labels,body --limit 200 > /tmp/gh-all-issues.json 2>/dev/null || echo "[]" > /tmp/gh-all-issues.json
# After (--state all preserved — needed to include closed test-failure issues):
issue_list --state all --limit 200 > /tmp/gh-all-issues.json 2>/dev/null || echo "[]" > /tmp/gh-all-issues.json

# Before:
gh issue list --state open --label "test-failure" --json number,title,labels,body --limit 200 > /tmp/gh-open-issues.json 2>/dev/null || echo "[]" > /tmp/gh-open-issues.json
gh issue comment "$issue_num" --body "..."
gh issue close "$issue_num" --comment "Verified fixed..."
gh issue reopen "$EXISTING" 2>/dev/null || true
gh issue create --title "..." --body "..." --label "..."
# After:
issue_list --state open --label "test-failure" --limit 200 > /tmp/gh-open-issues.json 2>/dev/null || echo "[]" > /tmp/gh-open-issues.json
issue_comment "$issue_num" --body "..."
issue_close "$issue_num" --comment "Verified fixed..."
issue_update "$EXISTING" --status open 2>/dev/null || true
RESULT=$(issue_create --title "..." --body "..." --label "...")
```

Note: `gh issue reopen` becomes `issue_update N --status open` (dispatches to `gh issue reopen` on GitHub backend, or sets `status: open` on file backend).

Verify: `grep "gh issue" plugins/autocoder/commands/full-regression-test.md` → no output.

- [ ] **Step 4: Migrate list wrappers (`list-needs-design.md`, `list-needs-feedback.md`, `list-proposals.md`)**

These become thin wrappers. Replace the entire `gh issue list` call in each with the corresponding `issue_list` call:

`list-needs-design.md`:
```bash
# Before:
gh issue list --state open --label "needs-design" --json number,title,labels,body ...
# After:
issue_list --state open --label "needs-design"
```

`list-needs-feedback.md`:
```bash
issue_list --state open --label "needs-feedback"
```

`list-proposals.md`:
```bash
issue_list --state open --label "proposal"
```

Add sourcing preamble to each. Any `--jq` forms become `| jq '...'`.

Verify each: `grep "gh issue" plugins/autocoder/commands/list-needs-design.md` → no output. Same for the other two.

- [ ] **Step 5: Migrate `monitor-workers.md` (6 calls)**

```bash
# Before:
gh issue list --state open --json number,title,labels --jq '.[] | select(...) | "#\(.number): \(.title)"'
gh issue list --state open --label "working" --json number,title --jq '.[] | "#\(.number): \(.title)"'
gh issue edit <number> --remove-label "working"
gh issue list --state open --json number,title,labels --jq '[.[] | select(...)] | sort_by(...) | .[].number'
WORKING=$(gh issue list --state open --label "working" --json number --jq 'length')
UNBLOCKED=$(gh issue list --state open --json number,labels --jq '[.[] | select(...)] | length')
# After:
issue_list --state open | jq -r '.[] | select(...) | "#\(.number): \(.title)"'
issue_list --state open --label "working" | jq -r '.[] | "#\(.number): \(.title)"'
issue_update <number> --remove-label "working"
issue_list --state open | jq -r '[.[] | select(...)] | sort_by(...) | .[].number'
WORKING=$(issue_list --state open --label "working" | jq 'length')
UNBLOCKED=$(issue_list --state open | jq '[.[] | select(...)] | length')
```

Verify: `grep "gh issue" plugins/autocoder/commands/monitor-workers.md` → no output.

- [ ] **Step 6: Commit**

```bash
git add plugins/autocoder/commands/approve-proposal.md \
        plugins/autocoder/commands/brainstorm-issue.md \
        plugins/autocoder/commands/full-regression-test.md \
        plugins/autocoder/commands/list-needs-design.md \
        plugins/autocoder/commands/list-needs-feedback.md \
        plugins/autocoder/commands/list-proposals.md \
        plugins/autocoder/commands/monitor-workers.md
git commit -m "feat: migrate remaining command files from gh issue to issue_* functions"
```

---

## Task 9: New command files

**Files:**
- Create: `plugins/autocoder/commands/record-issue.md`
- Create: `plugins/autocoder/commands/update-issue.md`
- Create: `plugins/autocoder/commands/close-issue.md`
- Create: `plugins/autocoder/commands/list-issues.md`
- Create: `plugins/autocoder/commands/set-issue-source.md`

- [ ] **Step 1: Create `record-issue.md`**

```markdown
# Record Issue

Create a new issue in the configured issue backend (GitHub Issues or file backend).

## Setup

```bash
source plugins/autocoder/scripts/issue-fns.sh
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
```

- [ ] **Step 2: Create `update-issue.md`**

```markdown
# Update Issue

Modify an existing issue's labels, status, or priority.

## Setup

```bash
source plugins/autocoder/scripts/issue-fns.sh
```

## Usage

```
/update-issue 42 --add-label needs-design
/update-issue 42 --remove-label working --add-label needs-approval
/update-issue 42 --priority P0
/update-issue 42 --status closed
```

## Steps

1. Parse arguments:
   - First positional: issue number (required)
   - `--add-label <name>` — add a label
   - `--remove-label <name>` — remove a label
   - `--priority P0|P1|P2|P3` — translates to `--add-label <priority>`
   - `--status open|working|closed`

2. Build the `issue_update` call from the parsed flags. Multiple flags may be combined.

3. Run the update:

```bash
issue_update "$ISSUE_NUM" $UPDATE_FLAGS
```

Where `UPDATE_FLAGS` expands to the parsed flag set (e.g., `--add-label needs-design --remove-label working`).

4. Confirm: "Issue #N updated."
```

- [ ] **Step 3: Create `close-issue.md`**

```markdown
# Close Issue

Resolve and close an issue with an optional closing comment.

## Setup

```bash
source plugins/autocoder/scripts/issue-fns.sh
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
```

- [ ] **Step 4: Create `list-issues.md`**

```markdown
# List Issues

List open issues, optionally filtered by label or priority.

## Setup

```bash
source plugins/autocoder/scripts/issue-fns.sh
```

## Usage

```
/list-issues
/list-issues --label needs-design
/list-issues --priority P0
/list-issues --state closed
```

## Steps

1. Parse arguments:
   - `--label <name>` — filter by label
   - `--priority P0|P1|P2|P3` — filter by priority label
   - `--state open|closed` — default `open`
   - `--limit N` — default 50

2. Fetch issues:

```bash
ISSUES=$(issue_list --state "${STATE:-open}" --limit "${LIMIT:-50}" ${LABEL_FLAGS})
```

Where `LABEL_FLAGS` is `--label <name>` for the label or priority provided.

3. Format and display. For each issue in the JSON array:

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
```

- [ ] **Step 5: Create `set-issue-source.md`**

```markdown
# Set Issue Source

Switch the configured issue backend. Optionally migrates existing issues.

## Setup

```bash
source plugins/autocoder/scripts/issue-fns.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)"
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
```

- [ ] **Step 6: Commit**

```bash
git add plugins/autocoder/commands/record-issue.md \
        plugins/autocoder/commands/update-issue.md \
        plugins/autocoder/commands/close-issue.md \
        plugins/autocoder/commands/list-issues.md \
        plugins/autocoder/commands/set-issue-source.md
git commit -m "feat: add record-issue, update-issue, close-issue, list-issues, set-issue-source commands"
```

---

## Task 10: Mirror everything to `.agent/`

**Files:**
- Create/Modify: all `.agent/scripts/` and `.agent/workflows/` mirrors

Per repository convention, every `plugins/autocoder/scripts/` file has a mirror in `.agent/scripts/` and every `plugins/autocoder/commands/` file has a mirror in `.agent/workflows/`. The mirrors are identical copies.

- [ ] **Step 1: Mirror new scripts**

```bash
cp plugins/autocoder/scripts/issues-file.py   .agent/scripts/issues-file.py
cp plugins/autocoder/scripts/issue-config.sh  .agent/scripts/issue-config.sh
cp plugins/autocoder/scripts/issue-fns.sh     .agent/scripts/issue-fns.sh
```

- [ ] **Step 2: Mirror migrated scripts**

```bash
cp plugins/autocoder/scripts/add-blocking-label.sh    .agent/scripts/add-blocking-label.sh
cp plugins/autocoder/scripts/approve-blocked-issue.sh .agent/scripts/approve-blocked-issue.sh
cp plugins/autocoder/scripts/reject-blocked-issue.sh  .agent/scripts/reject-blocked-issue.sh
cp plugins/autocoder/scripts/fetch-blocked-issues.sh  .agent/scripts/fetch-blocked-issues.sh
cp plugins/autocoder/scripts/regression-test.sh       .agent/scripts/regression-test.sh
```

- [ ] **Step 3: Mirror new command files**

```bash
cp plugins/autocoder/commands/record-issue.md     .agent/workflows/record-issue.md
cp plugins/autocoder/commands/update-issue.md     .agent/workflows/update-issue.md
cp plugins/autocoder/commands/close-issue.md      .agent/workflows/close-issue.md
cp plugins/autocoder/commands/list-issues.md      .agent/workflows/list-issues.md
cp plugins/autocoder/commands/set-issue-source.md .agent/workflows/set-issue-source.md
```

- [ ] **Step 4: Mirror migrated command files**

```bash
cp plugins/autocoder/commands/fix.md                  .agent/workflows/fix.md
cp plugins/autocoder/commands/approve-proposal.md     .agent/workflows/approve-proposal.md
cp plugins/autocoder/commands/brainstorm-issue.md     .agent/workflows/brainstorm-issue.md
cp plugins/autocoder/commands/full-regression-test.md .agent/workflows/full-regression-test.md
cp plugins/autocoder/commands/list-needs-design.md    .agent/workflows/list-needs-design.md
cp plugins/autocoder/commands/list-needs-feedback.md  .agent/workflows/list-needs-feedback.md
cp plugins/autocoder/commands/list-proposals.md       .agent/workflows/list-proposals.md
cp plugins/autocoder/commands/monitor-workers.md      .agent/workflows/monitor-workers.md
```

- [ ] **Step 5: Verify no `gh issue` calls remain in `.agent/` files**

```bash
grep -rl "gh issue" .agent/scripts/ .agent/workflows/
```
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add .agent/
git commit -m "feat: mirror all issue-source files to .agent/ (Antigravity/Gemini support)"
```

---

## Task 11: Documentation

**Files:**
- Modify: `README.md`
- Modify: `CLAUDE.md`
- Modify: `GEMINI.md` (if present)

- [ ] **Step 1: Add "Adding a Custom Issue Backend" section to `README.md`**

Find or create the `## Adding a Custom Issue Backend` section. Add:

```markdown
## Adding a Custom Issue Backend

The issue system is pluggable. Any executable that implements the backend contract can be used as an issue source.

### Backend Contract

Your backend must accept these subcommands:

| Subcommand | Args | Output |
|-----------|------|--------|
| `list` | `[--label L] [--state open\|closed\|all] [--limit N]` | JSON array — `gh issue list` schema |
| `get` | `<number>` | JSON object — `gh issue view` schema |
| `update` | `<number> [--add-label L] [--remove-label L] [--status S]` | exit code |
| `comment` | `<number> --body "..."` | exit code |
| `close` | `<number> [--comment "..."]` | exit code |
| `create` | `--title "..." --body "..." [--label L]` | `{"number": N}` |

`list` and `get` must output JSON matching `gh issue list --json number,title,body,labels,state` and `gh issue view --json number,title,body,labels,state,comments` respectively.

Note: `--priority` is translated to `--label` by `issue-fns.sh` before reaching backends. Backends only receive `--label`.

### Registering Your Backend

In `.autocoder.json`:

```json
{
  "issueSource": "jira",
  "issueBackend": "./scripts/backends/jira-backend.sh"
}
```

### Minimal Template

```bash
#!/bin/bash
SUBCOMMAND="$1"; shift
case "$SUBCOMMAND" in
  list)    echo "[]" ;;
  get)     echo "{}" ;;
  update)  exit 0 ;;
  comment) exit 0 ;;
  close)   exit 0 ;;
  create)  echo '{"number": 1}' ;;
  *) echo "Unknown: $SUBCOMMAND" >&2; exit 1 ;;
esac
```

### Distributed Lock Pattern

For backends that need distributed locking (multiple parallel agents claiming issues), implement `status: open|working|closed` semantics in your `update` subcommand. Agents call `update N --add-label working` to claim and `update N --remove-label working` to release. The `list --state open` call must exclude claimed issues.
```

- [ ] **Step 2: Add issue management note to `CLAUDE.md`**

Find the appropriate section in `CLAUDE.md` (e.g., after "Key Characteristics") and add:

```markdown
## Issue Management

This project uses a pluggable issue source. Run `/set-issue-source` before running autonomous agents for the first time. Issue state is shared across all agents via `.issues/` at the repo root (file backend) or via GitHub Issues (github backend) — whichever is configured in `.autocoder.json`.
```

- [ ] **Step 3: Add same note to `GEMINI.md` (if it exists)**

```bash
if [ -f GEMINI.md ]; then
  # Add the same Issue Management section
  printf '\n## Issue Management\n\nThis project uses a pluggable issue source. Run the equivalent of `/set-issue-source` before running autonomous agents for the first time. Issue state is shared across all agents via `.issues/` at the repo root (file backend) or via GitHub Issues (github backend) — whichever is configured in `.autocoder.json`.\n' >> GEMINI.md
fi
```

- [ ] **Step 4: Commit**

```bash
git add README.md CLAUDE.md
[ -f GEMINI.md ] && git add GEMINI.md
git commit -m "docs: add custom issue backend guide to README; add issue management notes to CLAUDE.md/GEMINI.md"
```

---

## Self-Review

**Spec coverage check:**

| Spec requirement | Covered by |
|-----------------|-----------|
| File-based issue store (`.issues/NNN.md`) | Task 1–3: `issues-file.py` |
| Auto-detection (`.autocoder.json` → `.issues/` → GitHub) | Task 4: `issue-config.sh` |
| Non-interactive fail-fast | Task 4: `issue-config.sh` |
| Six-function shell layer | Task 5: `issue-fns.sh` |
| `--priority` → `--label` translation | Task 5: `issue-fns.sh` |
| `--status` GitHub translation table | Task 5: `issue-fns.sh` |
| `--assignee` file-backend-only stripping | Task 5: `issue-fns.sh` |
| `working` label/status coupling | Task 2: `issues-file.py` `cmd_update` |
| Per-file `fcntl.flock` locking | Task 2: `issues-file.py` |
| `.issues/.seq` lock for create | Task 2: `issues-file.py` `cmd_create` |
| Migration of 13 shell scripts + command files | Tasks 6–8 |
| `record-issue`, `update-issue`, `close-issue`, `list-issues`, `set-issue-source` | Task 9 |
| `.agent/` mirroring | Task 10 |
| README extensibility docs | Task 11 |
| CLAUDE.md / GEMINI.md note | Task 11 |
| `import-from-gh` / `export-to-gh` | Task 3 |
| Backend contract (Section 4) | Task 5: `issue-fns.sh` dispatches to contract-compliant backends |
| `--state all` support (file backend + full-regression-test migration) | Task 1: `issues-file.py list --state all`; Task 8 Step 3: `issue_list --state all` |

All spec sections covered. ✅

**Placeholder scan:** No TBD/TODO in this plan. All code steps are complete. ✅

**Type consistency:** `issue_list`, `issue_get`, `issue_update`, `issue_comment`, `issue_close`, `issue_create` — names consistent across Tasks 5, 6, 7, 8, 9. `ISSUE_SOURCE`, `ISSUE_DIR_PATH`, `ISSUE_BACKEND` — env var names consistent across Tasks 4, 5. ✅

**CIR fixes applied:**
- `_ifns_gh_create` uses URL parsing (`grep -oE '[0-9]+$'`) instead of invalid `--json number` flag (Task 5).
- `issues-file.py list` accepts `--state all` (Task 1); `full-regression-test.md` migration preserves `--state all` (Task 8 Step 3). ✅
