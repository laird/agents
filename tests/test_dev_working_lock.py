"""Guards the 'working' claim-lock lifecycle in dev.md (issue #14).

Honest scope note
-----------------
dev.md is a slash-command body: the lock rules are **prose the LLM runtime
interprets**, not executable bash. There is no function to unit-test. What we
*can* test is that the document does not re-acquire the wording that caused the
bug — a blanket "always remove the label on any exit / before moving on", which
an agent reads as license to drop the lock after a partial commit. The issue
then re-enters the claimable pool while a worker still holds the branch, and a
peer double-claims it.

So these tests assert on the text itself, and are deliberately narrow:

  * the blanket "remove in ALL exit paths" phrasing is gone;
  * partial commits / batch boundaries / pauses are explicitly called out as
    NOT release points;
  * every remaining `--remove-label "working"` sits next to a terminal outcome
    (a close, an explicit release comment, or a failed-claim abort);
  * the Claude and Antigravity mirrors say the same thing.

If dev.md ever grows a real bash release function, replace these with
functional tests.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent

MIRRORS = [
    REPO / "plugins" / "autocoder" / "commands" / "dev.md",
    REPO / ".agent" / "workflows" / "dev.md",
]

# Wording that licensed the bug. Each must be absent from both mirrors.
BANNED_PHRASES = [
    "Remove it in ALL exit paths",
    "ALWAYS run this before moving to the next issue",
    "This applies to ALL outcomes: fixed, skipped, deferred, blocked, or errored",
    "MUST be removed when you stop working on an issue, regardless of the outcome",
]

# The rule the fix installs. Each must be present in both mirrors.
REQUIRED_PHRASES = [
    "Release the 'working' Label Only on a Terminal Outcome",
    "NEVER release the lock for any of these",
    "partial",
    "Explicit release",
]


@pytest.mark.parametrize("path", MIRRORS, ids=lambda p: p.name if "agent" not in str(p) else "agent/" + p.name)
def test_mirror_exists(path):
    assert path.is_file(), f"missing mirror: {path}"


@pytest.mark.parametrize("path", MIRRORS, ids=str)
@pytest.mark.parametrize("phrase", BANNED_PHRASES)
def test_blanket_release_wording_absent(path, phrase):
    """The blanket 'always release' instruction is what caused issue #14."""
    assert phrase not in path.read_text(), (
        f"{path.name} reintroduced blanket lock-release wording: {phrase!r}. "
        "The 'working' label must only be released on a terminal outcome."
    )


@pytest.mark.parametrize("path", MIRRORS, ids=str)
@pytest.mark.parametrize("phrase", REQUIRED_PHRASES)
def test_terminal_only_rule_present(path, phrase):
    assert phrase in path.read_text(), (
        f"{path.name} is missing the terminal-outcome lock rule: {phrase!r}"
    )


@pytest.mark.parametrize("path", MIRRORS, ids=str)
def test_partial_commit_named_as_non_release_point(path):
    """A partial commit is the exact trigger from the issue report."""
    text = path.read_text()
    assert re.search(r"partial\*{0,2}\s*commit", text, re.I), (
        f"{path.name} must explicitly name a partial commit as a non-release point"
    )


@pytest.mark.parametrize("path", MIRRORS, ids=str)
def test_every_release_site_is_terminal(path):
    """Each remaining release must sit beside a close, an explicit release, or a failed claim.

    We scan a window around every `--remove-label "working"` and require a
    terminal marker in it. This is a heuristic on prose, so it is intentionally
    permissive about *which* marker — only that some terminal justification is
    adjacent.
    """
    lines = path.read_text().splitlines()
    terminal_markers = (
        "issue_close",          # closing the issue
        "Releasing claim",      # explicit release comment
        "release comment",
        "add-blocking-label",   # blocking path releases for us
        "Releasing the 'working' lock and aborting",  # claim never started
        "aborting rather than",
        "Terminal outcome only",  # the documented-correct example
        "WRONG",                  # the documented anti-pattern example
        "release it via the explicit-release path",
        # Lost claim race (issue #15 arbitration). Releasing here is terminal in the
        # "claim never started" sense: we surrender the lock immediately and never
        # begin work, so there is no partial progress to protect.
        "Releasing and aborting",
        "Releasing and trying next",
    )

    offenders = []
    for i, line in enumerate(lines):
        if '--remove-label "working"' not in line:
            continue
        window = "\n".join(lines[max(0, i - 12): i + 8])
        if not any(m in window for m in terminal_markers):
            offenders.append((i + 1, line.strip()))

    assert not offenders, (
        f"{path.name} releases the 'working' lock with no adjacent terminal outcome "
        f"at lines {[n for n, _ in offenders]}. Partial progress must keep the lock."
    )


def test_mirrors_agree_on_lock_section():
    """Parallel-maintenance requirement: both platforms state the same rule."""
    heading = "## CRITICAL: Release the 'working' Label Only on a Terminal Outcome"

    def section(path):
        text = path.read_text()
        start = text.find(heading)
        assert start != -1, f"{path.name} has no lock-lifecycle section ({heading!r})"
        end = text.find("\n## ", start + 10)
        assert end != -1, f"{path.name} lock section is unterminated"
        return text[start:end]

    claude, antigravity = (section(p) for p in MIRRORS)
    assert claude == antigravity, (
        "dev.md lock sections have drifted between plugins/autocoder/commands/ "
        "and .agent/workflows/"
    )
