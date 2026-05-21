"""Tests for the `--if-unset` flag on `issues-file.py update`.

Covers Phase 1 of the fix-loop token-efficiency design
(docs/specs/2026-05-21-fix-loop-token-efficiency-design.md §10).

The flag implements atomic claim semantics: if the target label is already
present, the update aborts with exit code 9 (race lost); otherwise the label
is added atomically under the existing flock.
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
        capture_output=True, text=True, env=env,
    )
    return r.stdout.strip(), r.stderr.strip(), r.returncode


@pytest.fixture
def idir(tmp_path):
    d = tmp_path / ".issues"
    d.mkdir()
    return d


def write_issue(idir, number, title, status="open", labels=None, body=""):
    labels = labels or []
    labels_yaml = "[" + ", ".join(labels) + "]"
    front = f"number: {number}\ntitle: {title}\nstatus: {status}\nlabels: {labels_yaml}\n"
    path = idir / f"{number:03d}.md"
    path.write_text(f"---\n{front}---\n{body}\n")
    return path


def get_labels(idir, number):
    out, _, rc = run(["get", str(number)], {"ISSUE_DIR_PATH": str(idir)})
    assert rc == 0, f"get failed: {out}"
    issue = json.loads(out)
    return [l["name"] for l in issue["labels"]]


class TestIfUnset:
    def test_if_unset_succeeds_when_label_absent(self, idir):
        """--if-unset adds the label when not present; exit 0."""
        write_issue(idir, 1, "T", status="open", labels=["bug"])
        _, _, rc = run(
            ["update", "1", "--add-label", "working", "--if-unset"],
            {"ISSUE_DIR_PATH": str(idir)},
        )
        assert rc == 0
        names = get_labels(idir, 1)
        assert "working" in names
        assert "bug" in names

    def test_if_unset_fails_when_label_present(self, idir):
        """--if-unset exits 9 when label already present; file unchanged."""
        write_issue(idir, 1, "T", status="working", labels=["working", "bug"])
        before = (idir / "001.md").read_text()
        _, _, rc = run(
            ["update", "1", "--add-label", "working", "--if-unset"],
            {"ISSUE_DIR_PATH": str(idir)},
        )
        assert rc == 9
        # File state must be untouched (no double-write, no label change).
        after = (idir / "001.md").read_text()
        assert before == after
        names = get_labels(idir, 1)
        # Exactly one `working` label remains.
        assert names.count("working") == 1

    def test_add_label_without_if_unset_is_idempotent(self, idir):
        """Regression: --add-label alone on an already-labeled issue exits 0 and
        does not produce a duplicate label entry."""
        write_issue(idir, 1, "T", status="working", labels=["working"])
        _, _, rc = run(
            ["update", "1", "--add-label", "working"],
            {"ISSUE_DIR_PATH": str(idir)},
        )
        assert rc == 0
        names = get_labels(idir, 1)
        assert names.count("working") == 1


class TestIfUnsetConcurrentClaim:
    def test_ten_concurrent_claimants_exactly_one_wins(self, idir):
        """Spawn 10 subprocesses racing to claim the same issue with
        --if-unset. Exactly one must exit 0; the other 9 must exit 9.
        The final issue file must contain exactly one `working` label."""
        write_issue(idir, 1, "T", status="open", labels=[])

        env = {**os.environ, "ISSUE_DIR_PATH": str(idir)}

        def claim():
            r = subprocess.run(
                ["python3", str(SCRIPT), "update", "1",
                 "--add-label", "working", "--if-unset"],
                capture_output=True, text=True, env=env,
            )
            return r.returncode

        # Use a thread pool so all subprocesses are launched as close to
        # simultaneously as possible. The flock in the script serializes
        # them; the --if-unset check decides the winner.
        with ThreadPoolExecutor(max_workers=10) as pool:
            futures = [pool.submit(claim) for _ in range(10)]
            codes = [f.result() for f in as_completed(futures)]

        winners = [c for c in codes if c == 0]
        losers = [c for c in codes if c == 9]
        others = [c for c in codes if c not in (0, 9)]

        assert others == [], f"unexpected exit codes: {others}"
        assert len(winners) == 1, f"expected 1 winner, got {len(winners)}: {codes}"
        assert len(losers) == 9, f"expected 9 losers, got {len(losers)}: {codes}"

        names = get_labels(idir, 1)
        assert names.count("working") == 1, f"duplicate labels: {names}"
