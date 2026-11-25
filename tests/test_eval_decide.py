"""eval-decide.py: the accept / reject / inconclusive rule over hand-written result rows (#395, slice 4)."""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parent.parent / "plugins" / "autocoder" / "scripts" / "eval-decide.py"
BEFORE, AFTER = "aaaa1111", "bbbb2222"


def row(sha, split, case, passed, tool_calls=None):
    return {"ts": "2026-11-20T12:00:00Z", "case": case, "split": split, "repeat": 1, "pass": passed,
            "failed": [] if passed else ["outcome"], "outcome": "landed" if passed else "escalated", "gates": 1,
            "tool_calls": tool_calls, "duration_s": 60, "worker": "fake", "harness": {"sha": sha}, "root": None}


def runs(sha, split, case, passes, total, tool_calls=None):
    """`total` rows of one case on one sha, the first `passes` of them passing."""
    return [row(sha, split, case, i < passes, tool_calls) for i in range(total)]


def decide(tmp_path, rows, *extra, finding="gate-red-suite:tests/test_x.sh"):
    results = tmp_path / "results.jsonl"
    results.write_text("".join(json.dumps(r) + "\n" for r in rows))
    env = {k: v for k, v in os.environ.items() if k not in ("AUTOCODER_EVAL_RESULTS", "AUTOCODER_EVAL_DECISIONS")}
    env["XDG_STATE_HOME"] = str(tmp_path / "state")
    return subprocess.run([sys.executable, str(SCRIPT), "--finding", finding, "--before", BEFORE, "--after", AFTER,
                           "--results", str(results), *extra], capture_output=True, text=True, env=env)


def decisions(tmp_path):
    path = tmp_path / "state" / "autocoder" / "eval-decisions.jsonl"
    return [json.loads(x) for x in path.read_text().splitlines()]


def baseline(dev_before=(1, 2), dev_after=(2, 2), ho_before=(1, 2), ho_after=(2, 2), calls_before=None, calls_after=None):
    return (runs(BEFORE, "dev", "dev-1", *dev_before, calls_before) + runs(AFTER, "dev", "dev-1", *dev_after, calls_after)
            + runs(BEFORE, "heldout", "ho-1", *ho_before, calls_before) + runs(AFTER, "heldout", "ho-1", *ho_after, calls_after))


@pytest.mark.parametrize("name,rows,code,verdict", [
    ("dev and held-out both rise", baseline(), 0, "accept"),
    ("held-out already perfect and stays so", baseline(ho_before=(2, 2), ho_after=(2, 2)), 0, "accept"),
    ("dev does not rise", baseline(dev_before=(1, 2), dev_after=(1, 2)), 1, "reject dev pass rate did not rise (1/2 -> 1/2)"),
    ("dev falls", baseline(dev_before=(2, 2), dev_after=(1, 2)), 1, "reject dev pass rate did not rise (2/2 -> 1/2)"),
    ("held-out falls", baseline(ho_before=(2, 2), ho_after=(1, 2)), 1, "reject heldout pass rate fell (2/2 -> 1/2)"),
    ("held-out below 1 stays put", baseline(ho_before=(1, 2), ho_after=(1, 2)), 1,
     "reject heldout pass rate did not rise from below 1 (1/2 -> 1/2)"),
    ("equal rates, fewer tool calls", baseline(dev_after=(1, 2), ho_after=(1, 2), calls_before=40, calls_after=25), 0, "accept"),
    ("equal rates, more tool calls", baseline(dev_after=(1, 2), ho_after=(1, 2), calls_before=25, calls_after=40), 1,
     "reject pass rates unchanged and mean tool calls did not fall (25.0 -> 40.0)"),
    ("equal rates, no tool calls recorded", baseline(dev_after=(1, 2), ho_after=(1, 2)), 1,
     "reject pass rates unchanged (dev 1/2 -> 1/2, heldout 1/2 -> 1/2) and tool calls not recorded"),
    ("one run per case", baseline(dev_before=(0, 1), dev_after=(1, 1)), 3,
     "inconclusive dev case(s) with fewer than 2 runs before: dev-1"),
    ("no held-out case", runs(BEFORE, "dev", "dev-1", 0, 2) + runs(AFTER, "dev", "dev-1", 2, 2), 3,
     "inconclusive no heldout case was run"),
    ("a case run on one sha only", baseline() + runs(AFTER, "dev", "dev-2", 2, 2), 3,
     "inconclusive dev case(s) with fewer than 2 runs before: dev-2"),
])
def test_rule(tmp_path, name, rows, code, verdict):
    r = decide(tmp_path, rows)
    assert (r.returncode, r.stdout.strip()) == (code, verdict), name


def test_the_decision_row_is_appended_with_the_tallies_per_split(tmp_path):
    rows = baseline(calls_before=30, calls_after=20) + [row("cccc3333", "dev", "dev-1", True)]   # another sha's row is not counted
    assert decide(tmp_path, rows).returncode == 0
    assert decide(tmp_path, rows, "--min-runs", "3").returncode == 3
    first, second = decisions(tmp_path)
    assert {k: v for k, v in first.items() if k != "ts"} == {
        "finding": "gate-red-suite:tests/test_x.sh", "before": BEFORE, "after": AFTER,
        "dev": {"before": [1, 2], "after": [2, 2]}, "heldout": {"before": [1, 2], "after": [2, 2]},
        "tool_calls": {"before": 30.0, "after": 20.0},
        "decision": "accept", "accepted": True, "reason": "dev 1/2 -> 2/2, heldout 1/2 -> 2/2"}
    assert first["ts"].endswith("Z")
    assert second["decision"] == "inconclusive" and second["accepted"] is False


def test_json_prints_the_row_and_a_short_sha_matches(tmp_path):
    rows = baseline()
    results = tmp_path / "results.jsonl"
    results.write_text("".join(json.dumps(r) + "\n" for r in rows) + "not json\n")
    out = tmp_path / "decisions.jsonl"
    r = subprocess.run([sys.executable, str(SCRIPT), "--finding", "reclaimed", "--before", BEFORE[:4], "--after", AFTER[:4],
                        "--results", str(results), "--decisions", str(out), "--json"],
                       capture_output=True, text=True, env={**os.environ, "XDG_STATE_HOME": str(tmp_path / "state")})
    assert r.returncode == 0 and "skipped 1 malformed line" in r.stderr
    printed = json.loads(r.stdout)
    assert printed == json.loads(out.read_text()) and printed["dev"] == {"before": [1, 2], "after": [2, 2]}


def test_the_decisions_path_follows_the_environment(tmp_path):
    target = tmp_path / "elsewhere.jsonl"
    results = tmp_path / "results.jsonl"
    results.write_text("".join(json.dumps(r) + "\n" for r in baseline()))
    r = subprocess.run([sys.executable, str(SCRIPT), "--finding", "f", "--before", BEFORE, "--after", AFTER, "--results", str(results)],
                       capture_output=True, text=True,
                       env={**os.environ, "XDG_STATE_HOME": str(tmp_path / "state"), "AUTOCODER_EVAL_DECISIONS": str(target)})
    assert r.returncode == 0 and len(target.read_text().splitlines()) == 1
    assert not (tmp_path / "state" / "autocoder" / "eval-decisions.jsonl").exists()


def test_a_missing_results_file_is_inconclusive_not_an_error(tmp_path):
    env = {**os.environ, "XDG_STATE_HOME": str(tmp_path / "state")}
    env.pop("AUTOCODER_EVAL_RESULTS", None)
    env.pop("AUTOCODER_EVAL_DECISIONS", None)
    r = subprocess.run([sys.executable, str(SCRIPT), "--finding", "f", "--before", BEFORE, "--after", AFTER],
                       capture_output=True, text=True, env=env)
    assert (r.returncode, r.stdout.strip()) == (3, "inconclusive no dev case was run")
    assert decisions(tmp_path)[0]["dev"] == {"before": [0, 0], "after": [0, 0]}
