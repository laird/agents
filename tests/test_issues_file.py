import json
import os
import subprocess
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
        assert "working" not in content.split("---")[1]

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


class TestFindMainWorktree:
    def test_returns_absolute_path(self):
        out, _, rc = run(["find-main-worktree"])
        assert rc == 0
        assert out.startswith("/")
        assert Path(out).is_dir()
