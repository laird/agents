"""Guards the ship gate (issue #35).

#26's PUSH_OK guard answers "did the push succeed?". It cannot answer "did this
reach the branch that ships?" A worker branching from a feature line pushes
fine, merges fine, tests fine — and closes the issue while the shipping branch
is untouched. Every signal is green and the tracker is wrong.

These tests build real throwaway git repos rather than mocking, because the
whole property under test is git ancestry.
"""

from __future__ import annotations

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
    REPO / "plugins" / "autocoder" / "commands" / "dev.md",
    REPO / ".agent" / "workflows" / "dev.md",
])
def test_dev_md_uses_the_gate_before_closing(mirror):
    text = mirror.read_text()
    assert "verify-shipped.sh" in text, (
        f"{mirror.name} closes issues without the ship gate (issue #35)"
    )
    assert "awaiting-integration" in text, (
        f"{mirror.name} does not label unshipped work"
    )


# ── Ship-branch resolution (issue #37) ──────────────────────────────────────
# The swarm's ship line is the integration branch, not master. That has to be
# fleet-wide, so resolution falls back to CLAUDE.md for headless workers that
# never source .envrc.

def test_resolves_ship_branch_from_claude_md(repo):
    """A worker with no env var must still find the ship branch."""
    r, commit = repo
    (r / "CLAUDE.md").write_text(
        "# Project\n\n## Branches\n\n"
        "**Ship branch**: `integration` — the branch that defines shipped.\n"
    )
    env = {k: v for k, v in __import__("os").environ.items()
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


def test_repo_declares_ship_branch_for_the_fleet():
    """The setting must live somewhere every worker reads, not just one shell."""
    envrc = (REPO / ".envrc").read_text()
    assert "CLAUDE_CODE_SHIP_BRANCH" in envrc, (
        ".envrc must export CLAUDE_CODE_SHIP_BRANCH — it is the tracked, "
        "fleet-wide env mechanism"
    )
    claude_md = (REPO / "CLAUDE.md").read_text()
    assert "**Ship branch**:" in claude_md, (
        "CLAUDE.md must declare the ship branch so headless workers and humans "
        "can resolve it without direnv"
    )


# ── The default branch always ships (issue #76) ─────────────────────────────
# The designation is read from the *local worktree's* CLAUDE.md, so two
# worktrees on different branches disagreed about the same commit. And a
# designation naming a branch that has been merged away stops advancing, which
# makes every later commit permanently un-shippable. These build a repo with a
# real origin, because the property under test is default-branch resolution.

@pytest.fixture
def repo_with_origin(tmp_path):
    """Clone-with-origin: master (default), plus a frozen integration line."""
    origin = tmp_path / "origin.git"
    sh(f"git init -q --bare -b master {origin}", tmp_path)

    seed = tmp_path / "seed"
    seed.mkdir()
    sh("git init -q -b master", seed)
    sh("git config user.email t@t; git config user.name t", seed)
    (seed / "a.txt").write_text("base\n")
    sh("git add -A && git commit -qm base", seed)
    sh(f"git remote add origin {origin} && git push -q origin master", seed)

    # An integration line that receives feature work, then stops advancing.
    sh("git checkout -q -b integration", seed)
    (seed / "b.txt").write_text("integration work\n")
    sh("git add -A && git commit -qm 'integration work'", seed)
    frozen = sh("git rev-parse HEAD", seed).stdout.strip()
    sh("git push -q origin integration", seed)

    # A feature line that reaches neither destination.
    sh("git checkout -q -b orphan", seed)
    (seed / "c.txt").write_text("orphan work\n")
    sh("git add -A && git commit -qm 'orphan work'", seed)
    orphan = sh("git rev-parse HEAD", seed).stdout.strip()
    sh("git push -q origin orphan", seed)

    # master advances past the integration line, as it does after a big merge.
    sh("git checkout -q master", seed)
    (seed / "d.txt").write_text("trunk work\n")
    sh("git add -A && git commit -qm 'trunk work'", seed)
    on_master = sh("git rev-parse HEAD", seed).stdout.strip()
    sh("git push -q origin master", seed)

    work = tmp_path / "work"
    sh(f"git clone -q {origin} {work}", tmp_path)
    sh("git config user.email t@t; git config user.name t", work)
    return work, on_master, frozen, orphan


def _run(cwd, *args):
    import os
    env = {k: v for k, v in os.environ.items() if k != "CLAUDE_CODE_SHIP_BRANCH"}
    return subprocess.run(["bash", str(SCRIPT), *args], cwd=str(cwd),
                          capture_output=True, text=True, env=env)


def test_default_branch_ships_even_when_the_designation_is_stale(repo_with_origin):
    """The #76 regression: a stale designation must not un-ship trunk work."""
    work, on_master, _frozen, _orphan = repo_with_origin
    (work / "CLAUDE.md").write_text("**Ship branch**: `integration`\n")
    res = _run(work, on_master)
    assert res.returncode == 0, (
        "a commit on the repo default branch must count as shipped even when "
        f"the ship branch designation points at a frozen line: {res.stdout}{res.stderr}"
    )
    assert "SHIPPED" in res.stdout


def test_env_pin_to_a_frozen_branch_still_ships_trunk_work(repo_with_origin):
    """.envrc outranks CLAUDE.md, so the env path needs the same guarantee."""
    import os
    work, on_master, _frozen, _orphan = repo_with_origin
    env = dict(os.environ, CLAUDE_CODE_SHIP_BRANCH="integration")
    res = subprocess.run(["bash", str(SCRIPT), on_master], cwd=str(work),
                         capture_output=True, text=True, env=env)
    assert res.returncode == 0, f"env pin must not un-ship trunk work: {res.stdout}"


def test_gate_still_blocks_work_on_neither_destination(repo_with_origin):
    """#35 must survive: work on a feature line alone is still NOT_SHIPPED."""
    work, _on_master, _frozen, orphan = repo_with_origin
    (work / "CLAUDE.md").write_text("**Ship branch**: `integration`\n")
    res = _run(work, orphan)
    assert res.returncode == 1, f"orphan work must not pass the gate: {res.stdout}"
    assert "NOT_SHIPPED" in res.stdout


def test_designated_ship_branch_still_counts(repo_with_origin):
    """The override keeps working: reaching it alone is enough."""
    work, _on_master, frozen, _orphan = repo_with_origin
    (work / "CLAUDE.md").write_text("**Ship branch**: `integration`\n")
    res = _run(work, frozen)
    assert res.returncode == 0, f"integration work must still ship: {res.stdout}"


def test_verdict_does_not_depend_on_which_worktree_asks(repo_with_origin):
    """The issue title: same commit, same answer, whichever branch you sit on."""
    work, on_master, _frozen, _orphan = repo_with_origin
    (work / "CLAUDE.md").write_text("**Ship branch**: `integration`\n")
    sh("git worktree add -q ../wt-int -b intline origin/integration", work)
    other = work.parent / "wt-int"
    (other / "CLAUDE.md").write_text("**Ship branch**: `integration`\n")

    a, b = _run(work, on_master), _run(other, on_master)
    assert a.returncode == b.returncode, (
        f"worktrees disagree: master-worktree={a.returncode} "
        f"integration-worktree={b.returncode}\n{a.stdout}\n{b.stdout}"
    )
    assert a.returncode == 0
