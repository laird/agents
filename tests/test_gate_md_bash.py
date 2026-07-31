"""Tests for the bash skeleton inside plugins/autocoder/commands/gate.md.

Honest scope note
-----------------
gate.md is a slash-command body. Most of its routing logic ("if phase=triage
loop over .issues[] and call issue_update", "if phase=fix invoke autocoder:dev
via Skill") is **prose for the LLM runtime to interpret**, not executable
bash. The only thing we can genuinely unit-test is the bash fenced block(s)
that actually run as shell:

    SCRIPT_DIR=$( ... locate plugins/autocoder/scripts ... )
    source "${SCRIPT_DIR}/issue-fns.sh"
    WORK_JSON="${AUTOCODER_WORK_JSON:-/tmp/autocoder-work.json}"
    bash "$SCRIPT_DIR/fix-loop-gate.sh"; GATE_RC=$?

That's it. The "phase = triage" / "phase = fix" / "phase = enhance" branches
in gate.md are markdown sections containing **example** snippets and prose
instructions. They are not wired together into a runnable `case $PHASE in
...` block. So:

  * We test that the extracted bash blocks are syntactically valid (`bash -n`).
  * We test that the main block correctly locates SCRIPT_DIR, sources
    issue-fns.sh, honors AUTOCODER_WORK_JSON, invokes fix-loop-gate.sh, and
    propagates its exit code into GATE_RC.
  * We assert (via the absence of certain constructs) that there is no
    `case $PHASE` / `if [ "$PHASE" = ... ]` dispatcher inside the bash — i.e.
    we explicitly document that phase routing is LLM-interpreted, not bash.

If a future revision of gate.md adds a real bash `case $PHASE` dispatcher,
this test file should be extended with per-phase functional assertions.
"""

from __future__ import annotations

import os
import re
import subprocess
import textwrap
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).parent.parent
GATE_MD = REPO_ROOT / "plugins/autocoder/commands/gate.md"
SCRIPTS_DIR = REPO_ROOT / "plugins/autocoder/scripts"

BASH_FENCE_RE = re.compile(r"```bash\n(.*?)```", re.DOTALL)


def _extract_bash_blocks(md_path: Path) -> list[str]:
    return BASH_FENCE_RE.findall(md_path.read_text())


# ─────────────────────────── basic extraction ────────────────────────────


def test_gate_md_has_at_least_one_bash_block():
    blocks = _extract_bash_blocks(GATE_MD)
    assert blocks, "gate.md must contain at least one ```bash ... ``` block"


def test_all_bash_blocks_are_syntactically_valid():
    """`bash -n` over every fenced bash block."""
    blocks = _extract_bash_blocks(GATE_MD)
    for i, block in enumerate(blocks):
        r = subprocess.run(
            ["bash", "-n", "-c", block],
            capture_output=True, text=True,
        )
        assert r.returncode == 0, (
            f"bash block #{i} in gate.md fails `bash -n`:\n"
            f"---block---\n{block}\n---stderr---\n{r.stderr}"
        )


# ──────────────────────── main block: structural ────────────────────────


def _main_block() -> str:
    """The first bash block — the gate skeleton itself (locates SCRIPT_DIR,
    sources issue-fns.sh, runs fix-loop-gate.sh)."""
    blocks = _extract_bash_blocks(GATE_MD)
    assert blocks, "no bash blocks found"
    return blocks[0]


def test_main_block_locates_script_dir():
    b = _main_block()
    assert "SCRIPT_DIR=" in b
    assert "plugins/autocoder/scripts" in b


def test_main_block_sources_issue_fns():
    b = _main_block()
    assert 'source "${SCRIPT_DIR}/issue-fns.sh"' in b


def test_main_block_honors_autocoder_work_json_env():
    b = _main_block()
    assert 'AUTOCODER_WORK_JSON:-/tmp/autocoder-work.json' in b


def test_main_block_invokes_fix_loop_gate_and_captures_rc():
    b = _main_block()
    assert 'bash "$SCRIPT_DIR/fix-loop-gate.sh"' in b
    assert "GATE_RC=$?" in b


def test_main_block_has_no_bash_phase_dispatcher():
    """Phase routing in gate.md is **prose for the LLM**, not bash. If this
    test ever fails, the routing has been moved into bash and the file needs
    per-phase functional tests. Update this file accordingly."""
    b = _main_block()
    assert "case $PHASE" not in b and "case \"$PHASE\"" not in b, (
        "Phase routing appears to have moved into bash — add per-phase "
        "functional tests to this file."
    )
    assert 'if [ "$PHASE"' not in b and "if [[ \"$PHASE\"" not in b


# ──────────────────────── main block: functional ────────────────────────


def _run_main_block(tmp_path: Path, fake_gate_rc: int, work_json_content: str | None):
    """Execute the main bash block with:
      * a shimmed SCRIPT_DIR layout under tmp_path containing a fake
        fix-loop-gate.sh that exits `fake_gate_rc` and (optionally) writes
        work.json, plus a real symlink/copy of issue-fns.sh and friends.
      * AUTOCODER_WORK_JSON pointed at tmp_path/work.json.

    Returns CompletedProcess of the bash invocation, with GATE_RC echoed on
    stdout so we can assert on it.
    """
    # Lay out a fake plugins/autocoder/scripts under tmp so the SCRIPT_DIR
    # detector's first branch ($(pwd)/plugins/autocoder/scripts) matches.
    fake_scripts = tmp_path / "plugins" / "autocoder" / "scripts"
    fake_scripts.mkdir(parents=True)

    # Copy real shell deps so `source issue-fns.sh` works.
    for name in ("issue-fns.sh", "issue-config.sh", "issues-file.py"):
        src = SCRIPTS_DIR / name
        (fake_scripts / name).write_bytes(src.read_bytes())
        (fake_scripts / name).chmod(0o755)

    work_json_path = tmp_path / "work.json"
    if work_json_content is not None:
        work_json_path.write_text(work_json_content)

    # Fake fix-loop-gate.sh: optionally writes work.json, then exits with the
    # configured rc. We don't want to invoke the real gate (which talks to
    # GitHub / queries a real issues dir).
    fake_gate = fake_scripts / "fix-loop-gate.sh"
    if work_json_content is not None:
        fake_gate.write_text(textwrap.dedent(f"""\
            #!/bin/bash
            cat > "{work_json_path}" <<'JSON'
{work_json_content}
JSON
            exit {fake_gate_rc}
        """))
    else:
        fake_gate.write_text(textwrap.dedent(f"""\
            #!/bin/bash
            exit {fake_gate_rc}
        """))
    fake_gate.chmod(0o755)

    # Wrap the main block with an echo of GATE_RC so the test can inspect it.
    wrapped = _main_block() + "\necho \"GATE_RC=$GATE_RC\"\n"

    env = {
        **os.environ,
        "AUTOCODER_WORK_JSON": str(work_json_path),
        # Force file backend so issue-fns.sh doesn't try to talk to gh.
        "ISSUE_SOURCE": "file",
        "ISSUE_DIR_PATH": str(tmp_path / "issues"),
    }
    (tmp_path / "issues").mkdir(exist_ok=True)

    return subprocess.run(
        ["bash", "-c", wrapped],
        cwd=tmp_path,
        env=env,
        capture_output=True, text=True,
    )


def test_main_block_propagates_idle_rc(tmp_path):
    """fix-loop-gate.sh exit 1 (idle) → GATE_RC=1."""
    r = _run_main_block(tmp_path, fake_gate_rc=1, work_json_content=None)
    assert r.returncode == 0, f"bash itself failed: {r.stderr}"
    assert "GATE_RC=1" in r.stdout, r.stdout


def test_main_block_propagates_config_error_rc(tmp_path):
    """fix-loop-gate.sh exit 2 (config error) → GATE_RC=2."""
    r = _run_main_block(tmp_path, fake_gate_rc=2, work_json_content=None)
    assert r.returncode == 0, f"bash itself failed: {r.stderr}"
    assert "GATE_RC=2" in r.stdout, r.stdout


@pytest.mark.parametrize("phase,issues", [
    ("triage", [101, 102]),
    ("fix", [42]),
    ("enhance", [99]),
])
def test_main_block_with_work_rc_zero_for_each_phase(tmp_path, phase, issues):
    """fix-loop-gate.sh exit 0 + work.json with each phase → GATE_RC=0 and
    the work.json is readable. The actual phase **routing** is prose and not
    executed by this bash block; we only verify the block doesn't crash and
    that the work.json is well-formed and reachable via AUTOCODER_WORK_JSON."""
    import json as _json
    work = {"phase": phase, "issues": issues}
    r = _run_main_block(tmp_path, fake_gate_rc=0,
                        work_json_content=_json.dumps(work))
    assert r.returncode == 0, f"bash failed: {r.stderr}"
    assert "GATE_RC=0" in r.stdout, r.stdout
    work_json_path = tmp_path / "work.json"
    assert work_json_path.exists()
    assert _json.loads(work_json_path.read_text()) == work


# ───────────────────────── prose-routing inventory ─────────────────────────


def test_gate_md_documents_all_three_phases_in_prose():
    """Sanity: the routing spec for triage/fix/enhance lives in prose
    sections. If any disappears, that's a content regression independent of
    the bash skeleton."""
    text = GATE_MD.read_text()
    assert "phase = `triage`" in text
    assert "phase = `fix` or `enhance`" in text or (
        "phase = `fix`" in text and "phase = `enhance`" in text
    )


def test_gate_md_documents_gate_rc_branches():
    """The 0/1/2 branching on GATE_RC is documented in prose too."""
    text = GATE_MD.read_text()
    assert "IDLE_NO_WORK_AVAILABLE" in text
    assert "GATE_CONFIG_ERROR" in text
