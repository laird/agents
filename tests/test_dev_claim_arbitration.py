"""Guards the race-safe claim arbitration in dev.md (issue #15).

Why this file exists
--------------------
The hardening was originally written into `plugins/autocoder/commands/fix.md` on
master. The `/fix` -> `/dev` rename reduced fix.md to a seven-line alias stub and
moved the real body to dev.md — but the arbitration did not come with it. So the
integration branch shipped a `/dev` whose claim was weaker than the `/fix` it
replaced, and merging that into master would have silently reverted the fix.

These tests pin the arbitration to dev.md (where the logic now lives) so a future
rename or refactor cannot drop it again without a red test.

As with test_dev_working_lock.py, dev.md is a slash-command body: these are
assertions on the bash that actually runs, plus mirror-parity checks. They are
deliberately structural, not behavioural.
"""

from __future__ import annotations

import re
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent

MIRRORS = [
    REPO / "plugins" / "autocoder" / "commands" / "dev.md",
    REPO / ".agent" / "workflows" / "dev.md",
]


def _arbitration_block(path: Path) -> str:
    """The claim-arbitration region, delimited by its own anchors.

    dev.md's fences cannot be paired reliably (a heredoc in the merge-mode
    section contains literal ``` markers), so we bound the region by content
    rather than by fence.
    """
    text = path.read_text()
    start = text.find("    # Remote branch is a stronger lock")
    assert start != -1, f"{path.name}: arbitration block not found"
    end = text.find("    ISSUE_CLAIMED=true", start)
    assert end != -1, f"{path.name}: arbitration block is unterminated"
    return text[start:end]

# Each element of the arbitration, with the reason it matters.
REQUIRED = {
    "issue_claim": "the primary lock must go through issue_claim, not a bare label add",
    "[autocoder-claim]": "GitHub backend needs an early marker comment to surface collisions",
    "CLAIM_MARKER_COUNT": "a competing-marker count is what detects the race",
    "PRIOR_STARTED": "orphaned start comments from abandoned runs must be detected",
    "sleep 3": "the settlement window must be long enough for a peer's marker to land",
    "issue_release": "the file backend releases by moving the issue back to open/",
    "REMOTE_BRANCH_EXISTS": "an existing remote branch is a stronger lock than the label",
}


@pytest.mark.parametrize("path", MIRRORS, ids=str)
@pytest.mark.parametrize("token,reason", sorted(REQUIRED.items()))
def test_arbitration_element_present(path, token, reason):
    assert token in path.read_text(), f"{path.name} lost {token!r} — {reason}"


@pytest.mark.parametrize("path", MIRRORS, ids=str)
def test_label_only_claim_is_gone(path):
    """The weak `add-label working` claim is what issue #15 reported."""
    text = path.read_text()
    assert '--add-label "working"' not in text, (
        f"{path.name} reintroduced a bare label-add claim. Claims must go through "
        "issue_claim so the file backend's atomic rename arbitrates."
    )


@pytest.mark.parametrize("path", MIRRORS, ids=str)
def test_race_backoff_releases_the_lock(path):
    """Losing the race must release the label, not silently `continue` holding it.

    The pre-fix loop claimed the issue, detected a competing worker, then
    `continue`d without releasing — leaking the lock and stranding the issue.
    """
    text = path.read_text()
    for marker in ("Releasing and trying next", "Releasing and aborting"):
        idx = text.find(marker)
        assert idx != -1, f"{path.name} has no {marker!r} back-off path"
        window = text[idx: idx + 400]
        assert "remove-label" in window or "issue_release" in window, (
            f"{path.name}: the {marker!r} path does not actually release the lock"
        )


@pytest.mark.parametrize("path", MIRRORS, ids=str)
def test_issue_num_assigned_before_claim(path):
    """The arbitration references $ISSUE_NUM; claiming an empty value is a no-op.

    The .agent mirror originally assigned ISSUE_NUM *after* the working-label
    check, so pasting the arbitration in verbatim would have claimed "".
    """
    text = path.read_text()
    assign = text.index("ISSUE_NUM=$(cat /tmp/top-issue.json")
    claim = text.index('issue_claim "$ISSUE_NUM"')
    assert assign < claim, (
        f"{path.name}: ISSUE_NUM is assigned after the first issue_claim — "
        "the claim would run against an empty issue number"
    )


def test_mirrors_share_identical_arbitration():
    """Parallel-maintenance requirement: the two platforms must not drift here."""
    claude, antigravity = (_arbitration_block(p) for p in MIRRORS)
    assert claude == antigravity, "claim arbitration drifted between the mirrors"


@pytest.mark.parametrize("path", MIRRORS, ids=str)
def test_arbitration_bash_is_syntactically_valid(path):
    """The fenced block containing the arbitration must actually parse.

    Two unrelated blocks in dev.md are illustrative pseudo-code and do not parse;
    this test targets only the block the arbitration lives in.
    """
    # dev.md's fences are ambiguous — a heredoc in the merge-mode section contains
    # literal ``` markers, so fence pairing cannot be trusted. Check the arbitration
    # snippet itself, delimited by its own anchors, which is the code under test.
    # It contains `continue`, so wrap it in a loop to make it a valid standalone unit.
    block = _arbitration_block(path)
    wrapped = "for _ in 1; do\n" + block + "\ndone\n"
    result = subprocess.run(["bash", "-n"], input=wrapped,
                            capture_output=True, text=True)
    assert result.returncode == 0, (
        f"{path.name}: arbitration has a bash syntax error:\n{result.stderr}"
    )
