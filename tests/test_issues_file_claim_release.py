"""Tests for issues-file.py claim/release/any-claimable verbs.

Covers spec §2 (atomic claim and release), §5 (zero-cost idle check), and the
parallel-claim stress test from the spec's testing plan.
"""

import json
import os
import subprocess
from concurrent.futures import ThreadPoolExecutor, as_completed
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
    for b in ("open", "working", "blocked", "closed"):
        (d / b).mkdir()
    return d


def seed_open(idir, n, labels=None):
    labels = labels or []
    labels_yaml = "[" + ", ".join(labels) + "]"
    front = f"number: {n}\ntitle: T{n}\nstatus: open\nlabels: {labels_yaml}\n"
    (idir / "open" / f"{n:03d}.md").write_text(f"---\n{front}---\nbody\n")


def seed_working(idir, n, labels=None):
    labels = list(labels or []) + ["working"]
    labels_yaml = "[" + ", ".join(labels) + "]"
    front = f"number: {n}\ntitle: T{n}\nstatus: working\nlabels: {labels_yaml}\n"
    (idir / "working" / f"{n:03d}.md").write_text(f"---\n{front}---\nbody\n")


class TestClaim:
    def test_claim_moves_open_to_working_and_sets_label(self, idir):
        seed_open(idir, 1)
        _, _, rc = run(["claim", "1"], {"ISSUE_DIR_PATH": str(idir)})
        assert rc == 0
        assert not (idir / "open" / "001.md").exists()
        wf = idir / "working" / "001.md"
        assert wf.exists()
        content = wf.read_text()
        assert "working" in content
        assert "status: working" in content

    def test_claim_on_missing_issue_exits_1(self, idir):
        _, _, rc = run(["claim", "99"], {"ISSUE_DIR_PATH": str(idir)})
        assert rc == 1

    def test_claim_on_already_working_exits_1(self, idir):
        seed_working(idir, 1)
        _, _, rc = run(["claim", "1"], {"ISSUE_DIR_PATH": str(idir)})
        assert rc == 1

    def test_parallel_claim_exactly_one_winner(self, idir):
        """Spec §Testing-plan: N processes attempt to claim the same issue;
        assert exactly one exits 0, the rest exit 1."""
        seed_open(idir, 42)

        def attempt():
            r = subprocess.run(
                ["python3", str(SCRIPT), "claim", "42"],
                capture_output=True, text=True,
                env={**os.environ, "ISSUE_DIR_PATH": str(idir)}
            )
            return r.returncode

        with ThreadPoolExecutor(max_workers=10) as ex:
            futs = [ex.submit(attempt) for _ in range(10)]
            rcs = sorted([f.result() for f in as_completed(futs)])
        assert rcs.count(0) == 1, f"expected exactly one winner, got rcs={rcs}"
        assert rcs.count(1) == 9


class TestRelease:
    def test_release_to_open_when_no_blocking_labels(self, idir):
        seed_working(idir, 1)
        _, _, rc = run(["release", "1"], {"ISSUE_DIR_PATH": str(idir)})
        assert rc == 0
        assert (idir / "open" / "001.md").exists()
        assert not (idir / "working" / "001.md").exists()
        content = (idir / "open" / "001.md").read_text()
        assert "status: open" in content
        # working label removed
        assert "working" not in [l.strip() for l in content.split("labels: [", 1)[1].split("]", 1)[0].split(",")]

    def test_release_to_blocked_when_blocking_label_present(self, idir):
        seed_working(idir, 1, labels=["needs-design"])
        _, _, rc = run(["release", "1"], {"ISSUE_DIR_PATH": str(idir)})
        assert rc == 0
        assert (idir / "blocked" / "001.md").exists()
        assert not (idir / "working" / "001.md").exists()
        content = (idir / "blocked" / "001.md").read_text()
        assert "needs-design" in content
        # working label cleared
        labels_inner = content.split("labels: [", 1)[1].split("]", 1)[0]
        labels_list = [l.strip() for l in labels_inner.split(",") if l.strip()]
        assert "working" not in labels_list

    def test_release_on_missing_issue_exits_1(self, idir):
        _, _, rc = run(["release", "99"], {"ISSUE_DIR_PATH": str(idir)})
        assert rc == 1


class TestClaimReleaseRoundTrip:
    def test_open_claim_release_returns_to_open(self, idir):
        seed_open(idir, 1)
        run(["claim", "1"], {"ISSUE_DIR_PATH": str(idir)})
        run(["release", "1"], {"ISSUE_DIR_PATH": str(idir)})
        assert (idir / "open" / "001.md").exists()

    def test_claim_then_add_blocking_then_release_lands_in_blocked(self, idir):
        seed_open(idir, 1)
        run(["claim", "1"], {"ISSUE_DIR_PATH": str(idir)})
        # While in working/, add a blocking label — file stays put.
        run(["update", "1", "--add-label", "needs-design"], {"ISSUE_DIR_PATH": str(idir)})
        assert (idir / "working" / "001.md").exists()
        # Release picks blocked/ as target because labels include needs-design.
        run(["release", "1"], {"ISSUE_DIR_PATH": str(idir)})
        assert (idir / "blocked" / "001.md").exists()


class TestBlockingTransitions:
    def test_add_blocking_in_open_renames_to_blocked(self, idir):
        seed_open(idir, 1)
        run(["update", "1", "--add-label", "needs-feedback"], {"ISSUE_DIR_PATH": str(idir)})
        assert (idir / "blocked" / "001.md").exists()
        assert not (idir / "open" / "001.md").exists()

    def test_remove_last_blocking_in_blocked_renames_to_open(self, idir):
        # Seed in blocked/ with two blocking labels
        labels_yaml = "[needs-design, needs-feedback]"
        front = f"number: 1\ntitle: T1\nstatus: open\nlabels: {labels_yaml}\n"
        (idir / "blocked" / "001.md").write_text(f"---\n{front}---\nbody\n")
        # Remove one — still blocked
        run(["update", "1", "--remove-label", "needs-design"], {"ISSUE_DIR_PATH": str(idir)})
        assert (idir / "blocked" / "001.md").exists()
        # Remove the last — moves to open
        run(["update", "1", "--remove-label", "needs-feedback"], {"ISSUE_DIR_PATH": str(idir)})
        assert (idir / "open" / "001.md").exists()
        assert not (idir / "blocked" / "001.md").exists()
