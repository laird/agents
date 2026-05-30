"""Tests for plugins/autocoder/scripts/analyze-gate-log.py.

See spec §13.1 (schema-defensive analyzer) and Phase 2.0 deliverables.
"""

import csv
import json
import os
import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).parent.parent
ANALYZER = REPO_ROOT / "plugins/autocoder/scripts/analyze-gate-log.py"
FIX_DIR = REPO_ROOT / "tests/fixtures"
SAMPLE_SESSION = FIX_DIR / "sample-session.jsonl"
SAMPLE_GATE = FIX_DIR / "sample-gate.jsonl"


def _materialize_gate(tmp_path: Path, session_path: Path) -> Path:
    """Copy sample-gate.jsonl into tmp, injecting `session_jsonl_path`
    pointing at the requested session jsonl so analyzer can join on it."""
    out = tmp_path / "gate.jsonl"
    lines = []
    for line in SAMPLE_GATE.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        rec = json.loads(line)
        rec["session_jsonl_path"] = str(session_path)
        lines.append(json.dumps(rec))
    out.write_text("\n".join(lines) + "\n")
    return out


def _run(args, env_override=None):
    env = {**os.environ, **(env_override or {})}
    r = subprocess.run(
        ["python3", str(ANALYZER)] + args,
        capture_output=True, text=True, env=env
    )
    return r


def _read_csv(path: Path):
    with path.open() as f:
        return list(csv.DictReader(f))


def test_golden_output(tmp_path):
    """Phase 2.0 blocker: known-token sample must produce known CSV values."""
    gate = _materialize_gate(tmp_path, SAMPLE_SESSION)
    out_csv = tmp_path / "out.csv"
    out_md = tmp_path / "out.md"

    r = _run([
        "--gate-log", str(gate),
        "--session-jsonl", str(SAMPLE_SESSION),
        "--out-csv", str(out_csv),
        "--out-md", str(out_md),
    ])
    assert r.returncode == 0, f"stderr: {r.stderr}"
    rows = _read_csv(out_csv)
    assert len(rows) == 3
    golden = rows[0]
    # Spec golden contract: first usage-bearing assistant record.
    assert golden["input_tokens"] == "1024", golden
    assert golden["cache_read_tokens"] == "8192", golden
    assert golden["cache_creation_tokens"] == "0", golden
    assert golden["output_tokens"] == "37", golden
    assert golden["model"] == "claude-sonnet-4-6"
    assert golden["outcome"] == "idle"
    # Markdown summary exists and is non-empty.
    md_text = out_md.read_text()
    assert "Gate-log analysis" in md_text
    assert "claude-sonnet-4-6" in md_text


def test_schema_check_fails_when_field_missing_in_every_record(tmp_path):
    """If `cache_read_input_tokens` is renamed in EVERY record, exit 2."""
    # Build a session jsonl where every assistant record renames the field.
    bad_session = tmp_path / "bad-session.jsonl"
    with SAMPLE_SESSION.open() as src, bad_session.open("w") as dst:
        for line in src:
            line = line.rstrip("\n")
            if not line:
                continue
            rec = json.loads(line)
            if rec.get("type") == "assistant":
                usage = rec["message"]["usage"]
                # Rename in every record.
                usage["cached_input_tokens"] = usage.pop("cache_read_input_tokens")
            dst.write(json.dumps(rec) + "\n")

    gate = _materialize_gate(tmp_path, bad_session)
    out_csv = tmp_path / "out.csv"
    out_md = tmp_path / "out.md"

    r = _run([
        "--gate-log", str(gate),
        "--session-jsonl", str(bad_session),
        "--out-csv", str(out_csv),
        "--out-md", str(out_md),
    ])
    assert r.returncode == 2, f"expected exit 2, got {r.returncode}; stderr: {r.stderr}"
    assert "cache_read_input_tokens" in r.stderr
    assert "missing in ALL" in r.stderr


def test_schema_check_warns_on_unknown_field(tmp_path):
    """Adding an unknown usage subfield triggers a stderr warning, exit 0."""
    mod_session = tmp_path / "mod-session.jsonl"
    lines_out = []
    injected = False
    with SAMPLE_SESSION.open() as src:
        for line in src:
            line = line.rstrip("\n")
            if not line:
                continue
            rec = json.loads(line)
            if not injected and rec.get("type") == "assistant":
                rec["message"]["usage"]["unexpected_field"] = "surprise"
                injected = True
            lines_out.append(json.dumps(rec))
    mod_session.write_text("\n".join(lines_out) + "\n")
    assert injected, "fixture must contain at least one assistant record"

    gate = _materialize_gate(tmp_path, mod_session)
    out_csv = tmp_path / "out.csv"
    out_md = tmp_path / "out.md"

    r = _run([
        "--gate-log", str(gate),
        "--session-jsonl", str(mod_session),
        "--out-csv", str(out_csv),
        "--out-md", str(out_md),
    ])
    assert r.returncode == 0, f"expected exit 0, got {r.returncode}; stderr: {r.stderr}"
    assert "unknown field" in r.stderr
    assert "unexpected_field" in r.stderr
