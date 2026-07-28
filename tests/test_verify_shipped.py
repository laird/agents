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
