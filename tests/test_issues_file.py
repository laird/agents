"""Tests for issues-file.py — four-bucket layout (open/working/blocked/closed).

Covers list/get/update/comment/close/create + migrate-layout + resolve_path
behavior + blocking-label transitions + cmd_close moving to closed/.
"""

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
    """Issue dir pre-initialized with empty bucket subdirectories."""
    d = tmp_path / ".issues"
    d.mkdir()
    for bucket in ("open", "working", "blocked", "closed"):
        (d / bucket).mkdir()
    return d


def write_issue(idir, number, title, bucket="open", labels=None, body="", assignee=None, status=None):
    """Write an issue into the named bucket. status defaults to match bucket."""
    if status is None:
        status = {"open": "open", "working": "working", "blocked": "open", "closed": "closed"}[bucket]
    labels = labels or []
    labels_yaml = "[" + ", ".join(labels) + "]"
    front = f"number: {number}\ntitle: {title}\nstatus: {status}\nlabels: {labels_yaml}\n"
    if assignee:
        front += f"assignee: {assignee}\n"
    path = idir / bucket / f"{number:03d}.md"
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

    def test_state_open_excludes_working_and_blocked(self, idir):
        write_issue(idir, 1, "Open", bucket="open")
        write_issue(idir, 2, "Working", bucket="working")
        write_issue(idir, 3, "Blocked", bucket="blocked", labels=["needs-design"])
        write_issue(idir, 4, "Closed", bucket="closed")
        out, _, rc = run(["list", "--state", "open"], {"ISSUE_DIR_PATH": str(idir)})
        assert rc == 0
        issues = json.loads(out)
        titles = [i["title"] for i in issues]
        assert "Open" in titles
        assert "Working" not in titles
        assert "Blocked" not in titles
        assert "Closed" not in titles

    def test_state_working_returns_only_working(self, idir):
        write_issue(idir, 1, "Open")
        write_issue(idir, 2, "Working", bucket="working")
        out, _, rc = run(["list", "--state", "working"], {"ISSUE_DIR_PATH": str(idir)})
        issues = json.loads(out)
        assert len(issues) == 1
        assert issues[0]["title"] == "Working"

    def test_state_blocked_returns_only_blocked(self, idir):
        write_issue(idir, 1, "Open")
        write_issue(idir, 2, "Blocked", bucket="blocked", labels=["needs-design"])
        out, _, rc = run(["list", "--state", "blocked"], {"ISSUE_DIR_PATH": str(idir)})
        issues = json.loads(out)
        assert len(issues) == 1
        assert issues[0]["title"] == "Blocked"

    def test_state_closed_returns_only_closed(self, idir):
        write_issue(idir, 1, "Open")
        write_issue(idir, 2, "Closed", bucket="closed")
        out, _, rc = run(["list", "--state", "closed"], {"ISSUE_DIR_PATH": str(idir)})
        issues = json.loads(out)
        assert len(issues) == 1
        assert issues[0]["title"] == "Closed"

    def test_state_all_returns_all_buckets(self, idir):
        write_issue(idir, 1, "Open")
        write_issue(idir, 2, "Working", bucket="working")
        write_issue(idir, 3, "Blocked", bucket="blocked", labels=["needs-design"])
        write_issue(idir, 4, "Closed", bucket="closed")
        out, _, rc = run(["list", "--state", "all"], {"ISSUE_DIR_PATH": str(idir)})
        issues = json.loads(out)
        assert len(issues) == 4

    def test_label_filter(self, idir):
        write_issue(idir, 1, "Bug issue", labels=["bug"])
        write_issue(idir, 2, "Other", labels=["enhancement"])
        out, _, rc = run(["list", "--label", "bug"], {"ISSUE_DIR_PATH": str(idir)})
        issues = json.loads(out)
        assert len(issues) == 1
        assert issues[0]["title"] == "Bug issue"


class TestGet:
    def test_get_from_open(self, idir):
        write_issue(idir, 7, "Dark mode", body="We need dark mode.")
        out, _, rc = run(["get", "7"], {"ISSUE_DIR_PATH": str(idir)})
        assert rc == 0
        issue = json.loads(out)
        assert issue["number"] == 7

    def test_get_resolves_across_buckets(self, idir):
        write_issue(idir, 1, "A", bucket="open")
        write_issue(idir, 2, "B", bucket="working")
        write_issue(idir, 3, "C", bucket="blocked", labels=["needs-design"])
        write_issue(idir, 4, "D", bucket="closed")
        for n, title in [(1, "A"), (2, "B"), (3, "C"), (4, "D")]:
            out, _, rc = run(["get", str(n)], {"ISSUE_DIR_PATH": str(idir)})
            assert rc == 0
            assert json.loads(out)["title"] == title

    def test_get_missing_exits_1(self, idir):
        _, _, rc = run(["get", "99"], {"ISSUE_DIR_PATH": str(idir)})
        assert rc == 1


class TestUpdate:
    def test_add_non_blocking_label_keeps_bucket(self, idir):
        write_issue(idir, 1, "T", labels=["bug"])
        run(["update", "1", "--add-label", "P1"], {"ISSUE_DIR_PATH": str(idir)})
        assert (idir / "open" / "001.md").exists()
        assert not (idir / "blocked" / "001.md").exists()

    def test_add_blocking_label_moves_to_blocked(self, idir):
        write_issue(idir, 1, "T", labels=["bug"])
        run(["update", "1", "--add-label", "needs-design"], {"ISSUE_DIR_PATH": str(idir)})
        assert not (idir / "open" / "001.md").exists()
        assert (idir / "blocked" / "001.md").exists()

    def test_remove_blocking_label_moves_back_to_open(self, idir):
        write_issue(idir, 1, "T", bucket="blocked", labels=["needs-design"])
        run(["update", "1", "--remove-label", "needs-design"], {"ISSUE_DIR_PATH": str(idir)})
        assert (idir / "open" / "001.md").exists()
        assert not (idir / "blocked" / "001.md").exists()

    def test_add_label_working_does_not_rename(self, idir):
        # Legacy/idempotent: --add-label working sets the label and frontmatter
        # status but does NOT rename to working/. Only `claim` does that.
        write_issue(idir, 1, "T")
        run(["update", "1", "--add-label", "working"], {"ISSUE_DIR_PATH": str(idir)})
        # File should still be in open/
        assert (idir / "open" / "001.md").exists()
        assert not (idir / "working" / "001.md").exists()
        content = (idir / "open" / "001.md").read_text()
        assert "working" in content


class TestComment:
    def test_appends_blockquote(self, idir):
        write_issue(idir, 1, "T", body="Original body.")
        run(["comment", "1", "--body", "Review done."], {"ISSUE_DIR_PATH": str(idir)})
        p = idir / "open" / "001.md"
        content = p.read_text()
        assert "Original body." in content
        assert "Review done." in content


class TestClose:
    def test_close_from_open_moves_to_closed(self, idir):
        write_issue(idir, 1, "T", bucket="open")
        run(["close", "1"], {"ISSUE_DIR_PATH": str(idir)})
        assert not (idir / "open" / "001.md").exists()
        assert (idir / "closed" / "001.md").exists()

    def test_close_from_working_moves_to_closed(self, idir):
        write_issue(idir, 1, "T", bucket="working", labels=["working"])
        run(["close", "1"], {"ISSUE_DIR_PATH": str(idir)})
        assert not (idir / "working" / "001.md").exists()
        assert (idir / "closed" / "001.md").exists()

    def test_close_from_blocked_moves_to_closed(self, idir):
        write_issue(idir, 1, "T", bucket="blocked", labels=["needs-design"])
        run(["close", "1"], {"ISSUE_DIR_PATH": str(idir)})
        assert (idir / "closed" / "001.md").exists()

    def test_close_appends_comment(self, idir):
        write_issue(idir, 1, "T")
        run(["close", "1", "--comment", "Done."], {"ISSUE_DIR_PATH": str(idir)})
        content = (idir / "closed" / "001.md").read_text()
        assert "Done." in content
        assert "status: closed" in content


class TestCreate:
    def test_creates_in_open_bucket(self, idir):
        out, _, rc = run(
            ["create", "--title", "New issue", "--body", "Details."],
            {"ISSUE_DIR_PATH": str(idir)}
        )
        assert rc == 0
        n = json.loads(out)["number"]
        assert (idir / "open" / f"{n:03d}.md").exists()

    def test_seq_authoritative_after_create(self, idir):
        # Manually pre-seed .seq above existing files to confirm .seq wins.
        (idir / ".seq").write_text("10\n")
        out, _, _ = run(["create", "--title", "T", "--body", ""], {"ISSUE_DIR_PATH": str(idir)})
        n = json.loads(out)["number"]
        assert n == 11

    def test_create_increments_seq_atomically(self, idir):
        nums = []
        for _ in range(3):
            out, _, _ = run(["create", "--title", "T", "--body", ""], {"ISSUE_DIR_PATH": str(idir)})
            nums.append(json.loads(out)["number"])
        assert nums == sorted(nums)  # monotonic
        assert len(set(nums)) == 3   # unique


class TestMigrateLayout:
    @pytest.fixture
    def flat_dir(self, tmp_path):
        """Issue dir with flat .issues/NNN.md (pre-migration shape)."""
        d = tmp_path / ".issues"
        d.mkdir()
        return d

    def _write_flat(self, flat_dir, number, status="open", labels=None):
        labels = labels or []
        labels_yaml = "[" + ", ".join(labels) + "]"
        front = f"number: {number}\ntitle: T{number}\nstatus: {status}\nlabels: {labels_yaml}\n"
        (flat_dir / f"{number:03d}.md").write_text(f"---\n{front}---\nbody\n")

    def test_classifies_by_status_and_labels(self, flat_dir):
        self._write_flat(flat_dir, 1, status="open")
        self._write_flat(flat_dir, 2, status="working", labels=["working"])
        self._write_flat(flat_dir, 3, status="open", labels=["needs-design"])
        self._write_flat(flat_dir, 4, status="closed")
        out, _, rc = run(["migrate-layout"], {"ISSUE_DIR_PATH": str(flat_dir)})
        assert rc == 0
        assert (flat_dir / "open" / "001.md").exists()
        assert (flat_dir / "working" / "002.md").exists()
        assert (flat_dir / "blocked" / "003.md").exists()
        assert (flat_dir / "closed" / "004.md").exists()

    def test_initializes_seq_to_max(self, flat_dir):
        self._write_flat(flat_dir, 5)
        self._write_flat(flat_dir, 12)
        self._write_flat(flat_dir, 9)
        run(["migrate-layout"], {"ISSUE_DIR_PATH": str(flat_dir)})
        seq = (flat_dir / ".seq").read_text().strip()
        assert int(seq) == 12

    def test_refuses_to_run_twice(self, flat_dir):
        self._write_flat(flat_dir, 1)
        out, _, rc = run(["migrate-layout"], {"ISSUE_DIR_PATH": str(flat_dir)})
        assert rc == 0
        _, err, rc2 = run(["migrate-layout"], {"ISSUE_DIR_PATH": str(flat_dir)})
        assert rc2 != 0
        assert "already migrated" in err.lower() or "already migrated" in err


class TestAnyClaimable:
    def test_exit_1_on_empty_open(self, idir):
        _, _, rc = run(["any-claimable"], {"ISSUE_DIR_PATH": str(idir)})
        assert rc == 1

    def test_exit_0_when_open_has_file(self, idir):
        write_issue(idir, 1, "T")
        _, _, rc = run(["any-claimable"], {"ISSUE_DIR_PATH": str(idir)})
        assert rc == 0

    def test_exit_1_when_only_blocked_or_closed(self, idir):
        write_issue(idir, 1, "Blocked", bucket="blocked", labels=["needs-design"])
        write_issue(idir, 2, "Closed", bucket="closed")
        _, _, rc = run(["any-claimable"], {"ISSUE_DIR_PATH": str(idir)})
        assert rc == 1

    def test_exit_3_when_open_missing(self, tmp_path):
        # Issues dir exists but open/ does not — backend error per contract.
        d = tmp_path / ".issues"
        d.mkdir()
        _, _, rc = run(["any-claimable"], {"ISSUE_DIR_PATH": str(d)})
        assert rc == 3


class TestFindMainWorktree:
    def test_returns_absolute_path(self):
        out, _, rc = run(["find-main-worktree"])
        assert rc == 0
        assert out.startswith("/")
        assert Path(out).is_dir()
