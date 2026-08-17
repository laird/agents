"""Guards that CI actually executes the shell suites.

Why this file exists
--------------------
`.github/workflows/test.yml` once ran only `pytest tests/`. pytest collects
Python tests, so every `tests/*.sh` suite — including the ones guarding the
claim lock, the issue backend, and the multiplexer probe — went unexecuted by
CI. CI was green and that green meant nothing for any of them (issue #32).

#32 was fixed by adding a `shell` job, so the suites do run today. What was
never added is anything that keeps them running: the fix lived entirely in
YAML, and deleting that job would restore the original silence without failing
a single test.

These tests are that missing guard. They are pytest tests on purpose, because
pytest is the thing CI is already guaranteed to run — a shell test guarding the
shell runner could itself go unexecuted.
"""

from __future__ import annotations

import re
import subprocess
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
WORKFLOW = REPO / ".github" / "workflows" / "test.yml"
RUNNER = REPO / "scripts" / "run-shell-suites.sh"


def _workflow_code() -> str:
    """The workflow with comment-only lines stripped.

    Assertions about what CI *does* must read the executable YAML, never the
    raw text. The comments in test.yml name both `run-shell-suites.sh` and
    `pytest tests/` while explaining why they are there, so a plain substring
    search over the file stays green after the step that runs them is deleted —
    a guard that cannot fail. Verified by deleting the step and watching this
    test go red.
    """
    return "\n".join(
        line
        for line in WORKFLOW.read_text().splitlines()
        if not line.lstrip().startswith("#")
    )


def test_runner_exists_and_is_valid_bash():
    assert RUNNER.is_file(), f"missing shell-suite runner: {RUNNER}"
    result = subprocess.run(["bash", "-n", str(RUNNER)], capture_output=True, text=True)
    assert result.returncode == 0, f"runner has a syntax error:\n{result.stderr}"


def test_ci_invokes_the_shell_runner():
    """The whole point of #32: CI must actually run the shell suites.

    Keyed on a `run:` step, not the mere presence of the filename, so that
    deleting the step fails this test even though the surrounding comments
    still mention the runner.
    """
    assert re.search(r"run:\s*bash\s+scripts/run-shell-suites\.sh", _workflow_code()), (
        "no CI step runs `bash scripts/run-shell-suites.sh` — the tests/*.sh "
        "suites would silently stop running (a regression to issue #32)."
    )


def test_ci_still_runs_pytest():
    """The shell step must be added alongside pytest, not instead of it."""
    assert re.search(r"run:.*pytest\s+tests/", _workflow_code()), (
        "no CI step runs pytest over tests/"
    )


def test_runner_covers_every_shell_suite():
    """Every tests/test_*.sh must be either run or explicitly skipped with a reason.

    Silently omitting a suite is precisely the regression this issue is about,
    so an unexplained omission should be a red test, not a quiet gap.
    """
    suites = sorted(p.name for p in (REPO / "tests").glob("test_*.sh"))
    assert suites, "no tests/test_*.sh suites found — did they move?"

    runner = RUNNER.read_text()
    # The runner globs tests/test_*.sh, so coverage is automatic; what needs
    # checking is that the glob wasn't narrowed further and that any SKIP entry
    # carries a reason.
    assert "tests/test_*.sh" in runner, "runner no longer globs tests/test_*.sh"

    for entry in re.findall(r'"(tests/[^"]+\.sh):([^"]*)"', runner):
        path, reason = entry
        assert reason.strip(), f"{path} is skipped with no stated reason"


def test_runner_excludes_the_meta_runner():
    """tests/run-shell-suite.sh is a meta-runner, not a suite.

    It loops over every tests/test_*.sh itself and prints one aggregate summary
    for regression-test.sh's parser. Globbing it in as "a suite" would nest a
    full second run of everything inside a single top-level entry on every
    invocation. The test_ prefix on the real glob excludes it structurally, but
    this pins the intent so a future rename (e.g. dropping the prefix, or
    adding a same-shaped meta-runner) doesn't quietly reintroduce the nesting.
    """
    meta_runner = REPO / "tests" / "run-shell-suite.sh"
    if not meta_runner.is_file():
        return  # nothing to protect against yet

    # Check executable lines only — the runner's own comments narrate the
    # history of the glob (including the pre-narrowing `tests/*.sh` form) in
    # prose, which a whole-file substring search would misread as the glob.
    code = "\n".join(
        line for line in RUNNER.read_text().splitlines() if not line.lstrip().startswith("#")
    )
    assert "tests/*.sh" not in code, (
        "runner globs tests/*.sh again, which would pick up "
        "tests/run-shell-suite.sh as if it were a leaf suite and run "
        "everything a second time nested inside it"
    )


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
