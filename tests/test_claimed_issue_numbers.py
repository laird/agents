"""Guards branch-evidence exclusion in the candidate filter (issue #48).

/fix built its candidate list from labels alone. When a `working` label was
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
    REPO / "plugins" / "autocoder" / "commands" / "fix.md",
    REPO / ".agent" / "workflows" / "fix.md",
]
# #289 moved /fix's claim, selection and branch setup out of fix.md into
# claim-issue.sh, which both fix.md copies call. The selection code is checked
# there, in the plugin source and the Antigravity mirror.
CLAIM_SCRIPTS = [
    REPO / "plugins" / "autocoder" / "scripts" / "claim-issue.sh",
    REPO / ".agent" / "scripts" / "claim-issue.sh",
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
                   "fix/issue-idle-alias", "merge/fix-line-to-master",
                   # a hotfix lane's branch names its issue first
                   "hotfix/7177-retry-args", "hotfix/7190",
                   "hotfix/no-number-here", "release/2026-11-18"):
        sh(f"git branch {branch} master && git push -q origin {branch}", work)
    return work


def run(cwd, remote="origin"):
    r = subprocess.run(["bash", str(SCRIPT), remote], cwd=str(cwd),
                       capture_output=True, text=True)
    return r


def test_extracts_issue_numbers_from_branch_names(remote_repo):
    r = run(remote_repo)
    assert r.returncode == 0, r.stderr
    assert json.loads(r.stdout) == [8, 18, 20, 36, 51, 7177, 7190]


def test_hotfix_branches_count_and_a_release_tag_shaped_branch_does_not(remote_repo):
    """hotfix/<N>-<slug> and hotfix/<N> name their issue first;
    hotfix/no-number-here and release/2026-11-18 encode no issue."""
    nums = json.loads(run(remote_repo).stdout)
    assert 7177 in nums and 7190 in nums
    assert 2026 not in nums and 11 not in nums and 18 in nums  # 18 is fix/issue-18, not the date


def test_no_matching_branch_is_an_empty_list_not_an_exit(tmp_path):
    """Under pipefail a grep with no match used to end the pipeline non-zero."""
    origin = tmp_path / "o.git"; work = tmp_path / "w"
    sh(f"git init -q --bare {origin}", tmp_path)
    sh(f"git init -q -b master {work}", tmp_path)
    sh("git config user.email t@t; git config user.name t", work)
    (work / "f").write_text("x\n")
    sh("git add -A && git commit -qm base", work)
    sh(f"git remote add origin {origin}", work)
    sh("git push -q origin master", work)
    r = run(work)
    assert r.returncode == 0, r.stderr
    assert json.loads(r.stdout) == []


def test_ignores_branches_without_an_issue_number(remote_repo):
    """`fix/issue-idle-alias` and `merge/fix-line-to-master` encode no number."""
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
    """fix.md feeds this straight to `jq --argjson`; malformed output breaks it."""
    parsed = json.loads(run(remote_repo).stdout)
    assert isinstance(parsed, list)


@pytest.mark.parametrize("mirror", MIRRORS, ids=lambda p: str(p.parent.name))
def test_fix_md_delegates_claim_to_claim_issue_sh(mirror):
    """The selection checks below read claim-issue.sh; that only protects /fix
    while fix.md actually calls it."""
    assert '/claim-issue.sh" --' in mirror.read_text(), (
        f"{mirror} no longer runs claim-issue.sh, so the claimed-issue "
        "exclusion tested below is not what /fix runs (issue #48)"
    )


@pytest.mark.parametrize("script", CLAIM_SCRIPTS, ids=lambda p: str(p.parent.parent.name))
def test_claim_issue_excludes_claimed_issues(script):
    text = script.read_text()
    assert "claimed-issue-numbers.sh" in text, (
        f"{script} no longer consults branch evidence — a dropped "
        "`working` label would re-expose in-flight issues (issue #48)"
    )
    # Every select that picks claimable issues (it drops `working`) must also
    # drop issues with a live remote branch. #289 merged the top-issue and
    # candidate-list selects into one; a select added later must exclude too.
    selects = text.count('any(. == "working") | not')
    excludes = text.count("IN($claimed[])")
    assert selects >= 1, f"{script}: found no claimable-issue select"
    assert excludes == selects, (
        f"{script}: {selects} claimable-issue select(s) but {excludes} "
        "exclude claimed issues"
    )
    assert text.count('--argjson claimed "$CLAIMED_BY_BRANCH"') == selects


@pytest.mark.parametrize("script", CLAIM_SCRIPTS, ids=lambda p: str(p.parent.parent.name))
def test_claimed_var_defined_before_use(script):
    """`jq --argjson` with an unset var is a hard error, not a soft skip."""
    text = script.read_text()
    define = text.index("CLAIMED_BY_BRANCH=$(")
    first_use = text.index('--argjson claimed "$CLAIMED_BY_BRANCH"')
    assert define < first_use, (
        f"{script}: CLAIMED_BY_BRANCH is used before it is defined"
    )


@pytest.mark.parametrize("script", CLAIM_SCRIPTS, ids=lambda p: str(p.parent.parent.name))
def test_post_selection_arbitration_retained(script):
    """Branch evidence narrows the race; it does not replace the check."""
    text = script.read_text()
    assert "autocoder-claim" in text, (
        f"{script} dropped the #15 arbitration. Branch evidence cannot see "
        "unpushed claims or branches with no issue number in the name."
    )
