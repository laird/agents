"""Guards the ship gate (issue #35).

#26's PUSH_OK guard answers "did the push succeed?". It cannot answer "did this
reach the branch that ships?" A worker branching from a feature line pushes
fine, merges fine, tests fine — and closes the issue while the shipping branch
is untouched. Every signal is green and the tracker is wrong.

These tests build real throwaway git repos rather than mocking, because the
whole property under test is git ancestry.
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
SCRIPT = REPO / "plugins" / "autocoder" / "scripts" / "verify-shipped.sh"


def sh(cmd, cwd, check=True):
    return subprocess.run(cmd, cwd=cwd, shell=True, capture_output=True,
                          text=True, check=check)


@pytest.fixture
def repo(tmp_path):
    """A repo with master, an integration line off master, and a feature off that."""
    r = tmp_path / "r"
    r.mkdir()
    sh("git init -q -b master", r)
    sh("git config user.email t@t; git config user.name t", r)
    (r / "a.txt").write_text("base\n")
    sh("git add -A && git commit -qm base", r)

    sh("git checkout -q -b integration", r)
    (r / "b.txt").write_text("integration work\n")
    sh("git add -A && git commit -qm 'integration work'", r)

    sh("git checkout -q -b feature", r)
    (r / "c.txt").write_text("feature work\n")
    sh("git add -A && git commit -qm 'feature work'", r)
    feature_commit = sh("git rev-parse HEAD", r).stdout.strip()

    sh("git checkout -q integration && git merge -q --no-ff feature -m merge", r)
    return r, feature_commit


def run_gate(repo_dir, commit, ship="master"):
    return subprocess.run(
        ["bash", str(SCRIPT), commit, ship],
        cwd=str(repo_dir), capture_output=True, text=True,
    )


def test_script_is_valid_bash():
    assert SCRIPT.is_file(), f"missing {SCRIPT}"
    r = subprocess.run(["bash", "-n", str(SCRIPT)], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr


def test_blocks_close_when_only_on_integration(repo):
    """The #35 case: merged to the integration line, absent from master."""
    r, commit = repo
    res = run_gate(r, commit)
    assert res.returncode == 1, (
        f"expected NOT_SHIPPED (exit 1), got {res.returncode}: {res.stdout}{res.stderr}"
    )
    assert "NOT_SHIPPED" in res.stdout


def test_allows_close_once_it_reaches_the_ship_branch(repo):
    r, commit = repo
    sh("git checkout -q master && git merge -q --no-ff integration -m ship", r)
    res = run_gate(r, commit)
    assert res.returncode == 0, (
        f"expected SHIPPED (exit 0), got {res.returncode}: {res.stdout}{res.stderr}"
    )
    assert "SHIPPED" in res.stdout


def test_integration_ancestry_would_have_passed(repo):
    """Documents why #35's literal proposal is insufficient.

    Testing ancestry of the *integration* branch passes for the very commit that
    is not shipped — which is the bug. This test pins that reasoning so nobody
    "simplifies" the gate back to checking the integration branch.
    """
    r, commit = repo
    on_integration = sh(f"git merge-base --is-ancestor {commit} integration",
                        r, check=False).returncode
    on_master = sh(f"git merge-base --is-ancestor {commit} master",
                   r, check=False).returncode
    assert on_integration == 0, "commit should be an ancestor of integration"
    assert on_master != 0, "commit should NOT be an ancestor of master"


def test_reports_where_the_work_is_parked(repo):
    """The caller needs to say what must merge, not just 'not shipped'."""
    r, commit = repo
    sh("git remote add origin . && git fetch -q origin '+refs/heads/*:refs/remotes/origin/*'", r)
    res = run_gate(r, commit)
    assert res.returncode == 1
    assert "PARKED_ON" in res.stdout, f"no parked-on hint: {res.stdout}"


def test_unresolvable_commit_is_an_error_not_a_pass(repo):
    """A typo must not read as 'shipped'."""
    r, _ = repo
    res = run_gate(r, "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef")
    assert res.returncode == 2, f"expected usage/resolve error, got {res.returncode}"


def test_missing_argument_is_an_error():
    res = subprocess.run(["bash", str(SCRIPT)], capture_output=True, text=True)
    assert res.returncode == 2


@pytest.mark.parametrize("mirror", [
    REPO / "plugins" / "autocoder" / "commands" / "fix.md",
    REPO / ".agent" / "workflows" / "fix.md",
])
def test_fix_md_uses_the_gate_before_closing(mirror):
    text = mirror.read_text()
    assert "verify-shipped.sh" in text, (
        f"{mirror.name} closes issues without the ship gate (issue #35)"
    )
    assert "awaiting-integration" in text, (
        f"{mirror.name} does not label unshipped work"
    )


# ── Ship-branch resolution (issue #37) ──────────────────────────────────────
# Resolution order: arg > CLAUDE_CODE_SHIP_BRANCH > CLAUDE.md > repo default >
# main. The CLAUDE.md fallback exists for headless workers (cron, tmux panes
# started without direnv) that never see the env var. THIS repo deliberately
# pins nothing — its shipping branch is the repo default (master) — so the
# config-file tests below run against throwaway repos only.

def test_resolves_ship_branch_from_claude_md(repo):
    """A worker with no env var must still find the ship branch."""
    r, commit = repo
    (r / "CLAUDE.md").write_text(
        "# Project\n\n## Branches\n\n"
        "**Ship branch**: `integration` — the branch that defines shipped.\n"
    )
    env = {k: v for k, v in os.environ.items()
           if k != "CLAUDE_CODE_SHIP_BRANCH"}
    res = subprocess.run(["bash", str(SCRIPT), commit], cwd=str(r),
                         capture_output=True, text=True, env=env)
    assert res.returncode == 0, (
        f"should resolve 'integration' from CLAUDE.md and report shipped: "
        f"{res.stdout}{res.stderr}"
    )
    assert "integration" in res.stdout


def test_explicit_arg_beats_claude_md(repo):
    """Precedence: argument wins over the config file."""
    r, commit = repo
    (r / "CLAUDE.md").write_text("**Ship branch**: `integration`\n")
    res = subprocess.run(["bash", str(SCRIPT), commit, "master"], cwd=str(r),
                         capture_output=True, text=True)
    assert res.returncode == 1, "explicit master should win and report NOT_SHIPPED"


def test_env_var_beats_claude_md_and_repo_pins_nothing(repo):
    """Precedence: CLAUDE_CODE_SHIP_BRANCH wins over the config file — and this
    repo ships from its default branch, so it must not pin a ship branch that
    would shadow repo-default resolution."""
    r, commit = repo
    (r / "CLAUDE.md").write_text("**Ship branch**: `integration`\n")
    env = dict(os.environ, CLAUDE_CODE_SHIP_BRANCH="master")
    res = subprocess.run(["bash", str(SCRIPT), commit], cwd=str(r),
                         capture_output=True, text=True, env=env)
    assert res.returncode == 1, "env var 'master' should win and report NOT_SHIPPED"

    # This repo's ship branch is the repo default (master): no pinned override.
    claude_md = (REPO / "CLAUDE.md").read_text()
    assert "**Ship branch**:" not in claude_md, (
        "CLAUDE.md must not pin a ship branch — this repo ships from the repo "
        "default branch (master)"
    )
    envrc = REPO / ".envrc"
    if envrc.is_file():
        assert "CLAUDE_CODE_SHIP_BRANCH" not in envrc.read_text(), (
            ".envrc must not pin CLAUDE_CODE_SHIP_BRANCH — this repo ships from "
            "the repo default branch (master)"
        )


# ── Default branch always ships (issue #76) ─────────────────────────────────
# A commit on the repo's default branch is always treated as SHIPPED, even
# when SHIP_BRANCH is set to something else. This prevents two worktrees with
# different CLAUDE.md files from returning different verdicts for the same commit.

@pytest.fixture
def two_worktree_repo(tmp_path):
    """A repo that simulates two worktrees with different CLAUDE.md files.

    master is the default. A feature commit lands on master (simulating the ship).
    origin/HEAD is explicitly set so resolve_default_branch returns 'master'.
    """
    r = tmp_path / "repo"
    r.mkdir()
    sh("git init -q -b master", r)
    sh("git config user.email t@t; git config user.name t", r)

    (r / "a.txt").write_text("base\n")
    sh("git add -A && git commit -qm base", r)

    sh("git checkout -q -b feature", r)
    (r / "fix.txt").write_text("fix\n")
    sh("git add -A && git commit -qm fix", r)
    feature_commit = sh("git rev-parse HEAD", r).stdout.strip()

    # Merge feature into master (the commit is now shipped)
    sh("git checkout -q master && git merge -q --no-ff feature -m 'ship feature'", r)

    # Set up origin so resolve_default_branch can find the default branch.
    # Using a bare clone as origin ensures origin/HEAD is properly set.
    origin = tmp_path / "origin.git"
    sh(f"git clone -q --bare '{r}' '{origin}'", tmp_path)
    sh(f"git remote add origin '{origin}'", r)
    sh("git fetch -q origin '+refs/heads/*:refs/remotes/origin/*'", r)
    sh("git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/master", r)

    return r, feature_commit


def test_default_branch_verdict_when_ship_branch_is_integration(two_worktree_repo):
    """Issue #76: a commit on master is SHIPPED even when CLAUDE.md designates
    an integration branch as the ship branch.

    Without the fix, a worktree whose CLAUDE.md says '**Ship branch**: integration'
    would report the commit as NOT_SHIPPED even though it reached master.
    """
    r, commit = two_worktree_repo
    # Simulate a worktree whose CLAUDE.md pins a different ship branch
    (r / "CLAUDE.md").write_text("**Ship branch**: `integration`\n")
    env = {k: v for k, v in os.environ.items() if k != "CLAUDE_CODE_SHIP_BRANCH"}
    res = subprocess.run(["bash", str(SCRIPT), commit], cwd=str(r),
                         capture_output=True, text=True, env=env)
    assert res.returncode == 0, (
        "commit on master should be SHIPPED even when CLAUDE.md pins integration: "
        f"{res.stdout}{res.stderr}"
    )
    assert "SHIPPED" in res.stdout


def test_verdict_consistent_across_worktrees(two_worktree_repo):
    """Issue #76 core property: both the 'ship-branch CLAUDE.md' worktree and
    the 'no CLAUDE.md' worktree return the same verdict for a commit on master.
    """
    r, commit = two_worktree_repo
    env = {k: v for k, v in os.environ.items() if k != "CLAUDE_CODE_SHIP_BRANCH"}

    # Worktree 1: CLAUDE.md designates integration as ship branch
    (r / "CLAUDE.md").write_text("**Ship branch**: `integration`\n")
    res1 = subprocess.run(["bash", str(SCRIPT), commit], cwd=str(r),
                          capture_output=True, text=True, env=env)

    # Worktree 2: no CLAUDE.md (repo default wins)
    (r / "CLAUDE.md").unlink()
    res2 = subprocess.run(["bash", str(SCRIPT), commit], cwd=str(r),
                          capture_output=True, text=True, env=env)

    assert res1.returncode == res2.returncode, (
        f"Inconsistent verdicts across worktrees: "
        f"with CLAUDE.md={res1.returncode}, without={res2.returncode}"
    )


def test_not_shipped_when_only_on_feature_branch(two_worktree_repo):
    """Issue #35 regression: a commit only on a feature branch must not be
    considered shipped because the default branch check passes (it doesn't).
    """
    r, _ = two_worktree_repo
    # Create a new commit that is only on a feature branch, never merged to master
    sh("git checkout -q -b stranded", r)
    (r / "stranded.txt").write_text("stranded\n")
    sh("git add -A && git commit -qm 'stranded commit'", r)
    stranded_commit = sh("git rev-parse HEAD", r).stdout.strip()

    env = {k: v for k, v in os.environ.items() if k != "CLAUDE_CODE_SHIP_BRANCH"}
    # Pass master explicitly so ship branch resolves (default-branch detection
    # does not work against the in-process bare clone used by this fixture).
    res = subprocess.run(["bash", str(SCRIPT), stranded_commit, "master"], cwd=str(r),
                         capture_output=True, text=True, env=env)
    assert res.returncode == 1, (
        "a commit only on a feature branch must be NOT_SHIPPED, "
        f"got {res.returncode}: {res.stdout}{res.stderr}"
    )
    assert "NOT_SHIPPED" in res.stdout
