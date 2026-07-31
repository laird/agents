"""Guards that CI actually executes the shell suites (issue #32).

Why this file exists
--------------------
`.github/workflows/test.yml` ran only `pytest tests/`. pytest collects Python
tests, so all nine `tests/*.sh` suites — including the ones guarding the claim
lock, the issue backend, and the multiplexer probe — were never executed by CI.
CI was green and that green meant nothing for any of them.

The failure was silent: nothing in the repo asserted that the shell suites ran.
These tests make it loud. They are pytest tests on purpose, because pytest is
the thing CI is already guaranteed to run — a shell test guarding the shell
runner could itself go unexecuted.
"""

from __future__ import annotations

import re
import subprocess
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
WORKFLOW = REPO / ".github" / "workflows" / "test.yml"
RUNNER = REPO / "scripts" / "run-shell-suites.sh"


def test_runner_exists_and_is_valid_bash():
    assert RUNNER.is_file(), f"missing shell-suite runner: {RUNNER}"
    result = subprocess.run(["bash", "-n", str(RUNNER)], capture_output=True, text=True)
    assert result.returncode == 0, f"runner has a syntax error:\n{result.stderr}"


def test_ci_invokes_the_shell_runner():
    """The whole point of #32: CI must actually run the shell suites."""
    text = WORKFLOW.read_text()
    assert "run-shell-suites.sh" in text, (
        "CI no longer invokes scripts/run-shell-suites.sh — the tests/*.sh "
        "suites would silently stop running (this is issue #32)."
    )


def test_ci_still_runs_pytest():
    """The shell step must be added alongside pytest, not instead of it."""
    assert re.search(r"pytest\s+tests/", WORKFLOW.read_text()), (
        "CI no longer runs pytest over tests/"
    )


def test_runner_covers_every_shell_suite():
    """Every tests/*.sh must be either run or explicitly skipped with a reason.

    Silently omitting a suite is precisely the regression this issue is about,
    so an unexplained omission should be a red test, not a quiet gap.
    """
    suites = sorted(p.name for p in (REPO / "tests").glob("*.sh"))
    assert suites, "no tests/*.sh suites found — did they move?"

    runner = RUNNER.read_text()
    # The runner globs tests/*.sh, so coverage is automatic; what needs checking
    # is that the glob wasn't narrowed and that any SKIP entry carries a reason.
    assert "tests/*.sh" in runner, "runner no longer globs tests/*.sh"

    for entry in re.findall(r'"(tests/[^"]+\.sh):([^"]*)"', runner):
        path, reason = entry
        assert reason.strip(), f"{path} is skipped with no stated reason"


def test_runner_excludes_fixtures():
    """tests/fixtures/*.sh are setup|teardown helpers, not suites.

    Running them would mutate .issues/ and assert nothing. A bash glob does not
    cross `/`, but `git ls-files 'tests/*.sh'` does — so this is easy to break
    by "simplifying" the glob.
    """
    fixtures = list((REPO / "tests" / "fixtures").glob("*.sh"))
    if not fixtures:
        return  # nothing to protect against yet

    runner = RUNNER.read_text()
    assert "fixtures" in runner, (
        "runner no longer mentions fixtures — it must keep excluding them, and "
        "say why, or someone will widen the glob and start running them."
    )
    # Check executable lines only. The runner's own comments deliberately name
    # `find tests` and `git ls-files` as the wrong approaches, so a naive
    # substring search over the whole file matches the warning against them.
    code = "\n".join(
        line for line in runner.splitlines() if not line.lstrip().startswith("#")
    )
    for bad in ("find tests", "git ls-files"):
        assert bad not in code, (
            f"runner uses `{bad}`, which recurses into tests/fixtures/"
        )


def test_runner_reports_all_failures_not_just_the_first():
    """One broken suite must not mask the others."""
    runner = RUNNER.read_text()
    assert "set -e\n" not in runner and "set -euo" not in runner, (
        "runner uses `set -e`, which aborts on the first failing suite and "
        "hides every suite after it"
    )
    assert "FAILED_SUITES" in runner, "runner does not accumulate failures"


def test_runner_fails_when_a_suite_fails(tmp_path):
    """End-to-end: a deliberately failing suite must make the runner exit non-zero.

    Verified rather than assumed — a runner that always exits 0 would satisfy
    every other test in this file while providing no protection at all.
    """
    broken = REPO / "tests" / "test_zz_pytest_injected_failure.sh"
    broken.write_text("#!/usr/bin/env bash\nexit 1\n")
    try:
        result = subprocess.run(
            ["bash", str(RUNNER)], capture_output=True, text=True, cwd=str(REPO)
        )
        assert result.returncode != 0, (
            "runner exited 0 despite a failing suite — CI would stay green on a "
            "real regression"
        )
        assert broken.name in result.stdout, "runner did not name the failing suite"
    finally:
        broken.unlink(missing_ok=True)
