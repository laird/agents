"""Guards branch-evidence exclusion in the candidate filter (issue #48).

/dev built its candidate list from labels alone. When a `working` label was
dropped mid-flight (issue #14), the issue re-entered the claimable pool; the
#15 arbitration caught it only after a claim/back-off cycle, and the gap
between those is where a second worker also claimed. #30 ended up with two
workers on an 11-file structural merge that way.

A pushed branch is evidence that survives a lost label. These tests build real
git repos, because the property under test is what `git ls-remote` reports.
"""

from __future__ import annotations

import json
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
SCRIPT = REPO / "plugins" / "autocoder" / "scripts" / "claimed-issue-numbers.sh"
MIRRORS = [
    REPO / "plugins" / "autocoder" / "commands" / "dev.md",
    REPO / ".agent" / "workflows" / "dev.md",
]


def sh(cmd, cwd):
    return subprocess.run(cmd, cwd=cwd, shell=True, capture_output=True,
                          text=True, check=True)


@pytest.fixture
def remote_repo(tmp_path):
    """A bare 'origin' with branches mirroring the real observed names."""
    origin = tmp_path / "origin.git"
    work = tmp_path / "work"
    sh(f"git init -q --bare {origin}", tmp_path)
    sh(f"git init -q -b master {work}", tmp_path)
    sh("git config user.email t@t; git config user.name t", work)
    (work / "f").write_text("x\n")
    sh("git add -A && git commit -qm base", work)
    sh(f"git remote add origin {origin}", work)
    sh("git push -q origin master", work)
    for branch in ("feature/issue-20", "fix/issue-18", "feature/issue-36",
                   "fix/issue-8-rename-autofix-to-autocoder",
                   "enhancement/issue-51-auto",
                   "fix/issue-idle-alias", "merge/dev-line-to-master"):
        sh(f"git branch {branch} master && git push -q origin {branch}", work)
    return work


def run(cwd, remote="origin"):
    r = subprocess.run(["bash", str(SCRIPT), remote], cwd=str(cwd),
                       capture_output=True, text=True)
    return r


def test_extracts_issue_numbers_from_branch_names(remote_repo):
    r = run(remote_repo)
    assert r.returncode == 0, r.stderr
    assert json.loads(r.stdout) == [8, 18, 20, 36, 51]


def test_ignores_branches_without_an_issue_number(remote_repo):
    """`fix/issue-idle-alias` and `merge/dev-line-to-master` encode no number."""
    nums = json.loads(run(remote_repo).stdout)
    assert nums == sorted(set(nums)), "output must be sorted and deduplicated"
    # Nothing spurious crept in from the two number-less branches.
    assert all(isinstance(n, int) for n in nums)


def test_duplicate_numbers_across_prefixes_collapse(remote_repo):
    """feature/issue-20 and fix/issue-20 must yield 20 once, not twice."""
    sh("git branch fix/issue-20 master && git push -q origin fix/issue-20",
       remote_repo)
    nums = json.loads(run(remote_repo).stdout)
    assert nums.count(20) == 1


def test_fails_open_when_remote_unreachable(remote_repo):
    """A network blip must not stall the swarm by excluding everything."""
    r = run(remote_repo, remote="no-such-remote")
    assert r.returncode == 0, "must exit 0 so the caller continues"
    assert json.loads(r.stdout) == [], "must return an empty array, not garbage"
    assert "failing open" in r.stderr


def test_output_is_valid_json_array(remote_repo):
    """dev.md feeds this straight to `jq --argjson`; malformed output breaks it."""
    parsed = json.loads(run(remote_repo).stdout)
    assert isinstance(parsed, list)


@pytest.mark.parametrize("mirror", MIRRORS, ids=lambda p: str(p.parent.name))
def test_dev_md_excludes_claimed_issues(mirror):
    text = mirror.read_text()
    assert "claimed-issue-numbers.sh" in text, (
        f"{mirror.name} no longer consults branch evidence — a dropped "
        "`working` label would re-expose in-flight issues (issue #48)"
    )
    assert text.count("IN($claimed[])") == 2, (
        f"{mirror.name} must exclude claimed issues in BOTH the top-issue and "
        "candidate-list selects; found "
        f"{text.count('IN($claimed[])')}"
    )
    assert text.count('--argjson claimed "$CLAIMED_BY_BRANCH"') == 2


@pytest.mark.parametrize("mirror", MIRRORS, ids=lambda p: str(p.parent.name))
def test_claimed_var_defined_before_use(mirror):
    """`jq --argjson` with an unset var is a hard error, not a soft skip."""
    text = mirror.read_text()
    define = text.index("CLAIMED_BY_BRANCH=$(")
    first_use = text.index('--argjson claimed "$CLAIMED_BY_BRANCH"')
    assert define < first_use, (
        f"{mirror.name}: CLAIMED_BY_BRANCH is used before it is defined"
    )


@pytest.mark.parametrize("mirror", MIRRORS, ids=lambda p: str(p.parent.name))
def test_post_selection_arbitration_retained(mirror):
    """Branch evidence narrows the race; it does not replace the check."""
    text = mirror.read_text()
    assert "autocoder-claim" in text, (
        f"{mirror.name} dropped the #15 arbitration. Branch evidence cannot see "
        "unpushed claims or branches with no issue number in the name."
    )
