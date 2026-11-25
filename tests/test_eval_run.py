"""eval-run.py: sandboxes, fake workers, grading and the summary, end to end; the verifier on its own (#395)."""

from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "plugins" / "autocoder" / "scripts"
SCRIPT = SCRIPTS / "eval-run.py"
SHA = "0123456789abcdef0123456789abcdef01234567"
ROW_KEYS = {"ts", "case", "split", "repeat", "pass", "failed", "outcome", "gates", "tool_calls", "duration_s",
            "worker", "harness", "root"}
VERIFY = {"outcome": "landed", "classifiers_silent": ["conflict-escalated-early", "tool-errors"], "max_gates": 1,
          "max_tool_calls": 5, "steps_present": ["claimed", "landed"], "steps_absent": ["verdict-nudged"]}

# Each fake records what it saw under {root}, then plays one worker shape through the real event library.
PRELUDE = """#!/usr/bin/env bash
set -u
issue=$1 root=$3
source "{lib}/issue-events-lib.sh"
git log --oneline > "$root/seen-log.txt"
ls -A > "$root/seen-files.txt"
python3 "{lib}/issues-file.py" get "$issue" > "$root/seen-issue.json"
printf '%s\\n' "$XDG_STATE_HOME" "$AUTOCODER_LOG_DIR" > "$root/seen-env.txt"
touch "{marker}"
issue_event claimed "$issue"
"""
TOOL_CALL = ('{{"type":"assistant","message":{{"model":"model-a","content":[{{"type":"tool_use","id":"t{n}","name":"Bash","input":{{}}}}]}}}}\n'
             '{{"type":"user","message":{{"content":[{{"type":"tool_result","tool_use_id":"t{n}","content":"ok"}}]}}}}\n')
LANDS = ("cat <<'JSONL'\n" + '{"type":"system","subtype":"init","model":"model-a"}\n'
         + "".join(TOOL_CALL.format(n=n) for n in range(3))
         + '{"type":"result","subtype":"success","is_error":false,"duration_ms":1000,"num_turns":3,"total_cost_usd":0.01}\n'
         + "JSONL\n"
         + 'issue_event gate-end "$issue" attempt=1 outcome=landed duration_s=5\n'
         + 'issue_event landed "$issue" sha=abc1234 integration=master\n')
ESCALATES = 'issue_event escalated "$issue" label=needs-clarification reason=conflict\n'
HANGS = "sleep 30\n"


def write_case(cases: Path, split: str, case_id: str, *, setup: bool = False, verify=None, title="Add a greeting"):
    d = cases / split / case_id
    (d / "seed").mkdir(parents=True)
    (d / "seed" / "README.md").write_text("A tiny project.\n")
    (d / "task.md").write_text(f"Task for {case_id}: print a greeting from hello.sh.\n")
    (d / "case.json").write_text(json.dumps({
        "v": 1, "id": case_id, "authored": "2026-11-25", "split": split,
        "finding": {"id": "conflict-escalated-early", "key": None, "rules": ["B02"], "traces": ["repo-a-1234abcd:12:1"]},
        "issue": {"title": title, "labels": ["P2", "bug"]}, "verify": verify or VERIFY}))
    if setup:
        (d / "setup.sh").write_text('echo second > second.txt\ngit add second.txt\n'
                                    'git commit -q -m "Second actor commit"\ngit push -q "$ORIGIN" master\n')
    return d


@pytest.fixture
def env(tmp_path):
    (tmp_path / "tmp").mkdir()
    cases = tmp_path / "cases"
    write_case(cases, "dev", "case-a", setup=True)
    write_case(cases, "dev", "case-b")
    write_case(cases, "heldout", "case-h")
    return {**{k: v for k, v in os.environ.items() if not k.startswith("AUTOCODER_")},
            "XDG_STATE_HOME": str(tmp_path / "state"), "TMPDIR": str(tmp_path / "tmp"),
            "AUTOCODER_EVAL_CASES": str(cases), "AUTOCODER_EVAL_RESULTS": str(tmp_path / "results.jsonl"),
            "AUTOCODER_HARNESS_SHA": SHA,
            # A caller's own autocoder state must not reach the sandboxed worker.
            "AUTOCODER_ISSUE_EVENTS": str(tmp_path / "outer-issue-events.jsonl")}


def fake(tmp_path, name: str, body: str) -> str:
    path = tmp_path / f"{name}.sh"
    path.write_text(PRELUDE.format(lib=SCRIPTS, marker=tmp_path / f"{name}.ran") + body)
    return f"bash {path} {{issue}} {{repo}} {{root}}"


def run(env, *args):
    return subprocess.run([sys.executable, str(SCRIPT), *args], capture_output=True, text=True, env=env)


def run_json(env, *args):
    r = run(env, "--json", *args)
    assert r.returncode == 0, r.stderr
    return json.loads(r.stdout)


def test_passing_worker_passes_and_writes_result_rows(tmp_path, env):
    worker = fake(tmp_path, "lands", LANDS)
    report = run_json(env, "--worker", worker)
    rows = report["rows"]
    assert [(r["case"], r["split"], r["repeat"]) for r in rows] == [("case-a", "dev", 1), ("case-b", "dev", 1)]
    row = rows[0]
    assert set(row) == ROW_KEYS
    assert (row["pass"], row["failed"], row["outcome"], row["gates"], row["tool_calls"]) == (True, [], "landed", 1, 3)
    assert row["worker"] == worker and row["harness"] == {"sha": SHA}
    assert row["root"] is None  # a passing run's sandbox is deleted
    assert isinstance(row["duration_s"], float)
    assert [json.loads(x) for x in Path(env["AUTOCODER_EVAL_RESULTS"]).read_text().splitlines()] == rows
    assert report["splits"] == {"dev": {"runs": 2, "passes": 2, "cases": 2, "cases_passed": 2}}
    assert not (tmp_path / "outer-issue-events.jsonl").exists()


def test_the_worker_sees_the_seed_the_setup_commit_and_the_issue(tmp_path, env):
    rows = run_json(env, "--worker", fake(tmp_path, "lands", LANDS), "--case", "case-a", "--keep")["rows"]
    root = Path(rows[0]["root"])
    assert rows[0]["pass"] is True and root.is_dir()
    log = (root / "seen-log.txt").read_text()
    assert "Second actor commit" in log and "Seed the sandbox" in log
    assert {"README.md", ".autocoder.json", "CLAUDE.md"} <= set((root / "seen-files.txt").read_text().split())
    assert json.loads((root / "repo" / ".autocoder.json").read_text())["issueSource"] == "file"
    issue = json.loads((root / "seen-issue.json").read_text())
    assert issue["title"] == "Add a greeting" and issue["body"].startswith("Task for case-a")
    assert (root / "seen-env.txt").read_text().split() == [str(root / "state"), str(root / "logs")]
    transcripts = [p.name for p in (root / "logs").iterdir()]
    assert len(transcripts) == 1 and transcripts[0].startswith("worker-") and "-fix-1-" in transcripts[0]


def test_failing_worker_fails_on_outcome_and_keeps_its_root(tmp_path, env):
    rows = run_json(env, "--worker", fake(tmp_path, "escalates", ESCALATES), "--case", "case-b")["rows"]
    assert [(r["pass"], r["failed"], r["outcome"]) for r in rows] == [(False, ["outcome", "steps_present:landed"], "escalated")]
    assert Path(rows[0]["root"]).is_dir()


def test_a_worker_past_the_timeout_is_killed(tmp_path, env):
    rows = run_json(env, "--worker", fake(tmp_path, "hangs", HANGS), "--case", "case-b", "--timeout", "2")["rows"]
    assert rows[0]["pass"] is False and "timeout" in rows[0]["failed"]
    assert rows[0]["duration_s"] < 20


def test_repeat_split_and_case_selection(tmp_path, env):
    worker = fake(tmp_path, "lands", LANDS)
    rows = run_json(env, "--worker", worker, "--case", "case-b", "--repeat", "2")["rows"]
    assert [(r["case"], r["repeat"]) for r in rows] == [("case-b", 1), ("case-b", 2)]
    assert [r["case"] for r in run_json(env, "--worker", worker, "--split", "heldout")["rows"]] == ["case-h"]
    assert [r["case"] for r in run_json(env, "--worker", worker, "--split", "all")["rows"]] == ["case-a", "case-b", "case-h"]


def test_summary_table_lines(tmp_path, env):
    write_case(Path(env["AUTOCODER_EVAL_CASES"]), "heldout", "case-x", verify={**VERIFY, "outcome": "escalated"})
    r = run(env, "--worker", fake(tmp_path, "lands", LANDS), "--split", "all")
    assert r.returncode == 0, r.stderr
    lines = r.stdout.splitlines()
    assert lines[0].split() == ["CASE", "SPLIT", "PASS", "FAILED"]
    assert lines[1].split() == ["case-a", "dev", "1/1"]
    assert lines[4].split() == ["case-x", "heldout", "0/1", "outcome", "x1"]
    assert "split dev: 2/2 runs passed, 2/2 cases passed every repeat" in lines
    assert "split heldout: 1/2 runs passed, 1/2 cases passed every repeat" in lines
    assert any(line.startswith("kept for case-x: ") for line in lines)


def test_a_malformed_case_exits_2_before_any_worker_runs(tmp_path, env):
    write_case(Path(env["AUTOCODER_EVAL_CASES"]), "dev", "case-bad", title="TODO: a title")
    r = run(env, "--worker", fake(tmp_path, "lands", LANDS))
    assert r.returncode == 2
    assert "dev/case-bad: issue.title still has a TODO" in r.stderr
    assert not (tmp_path / "lands.ran").exists()
    assert run(env, "--worker", fake(tmp_path, "lands", LANDS), "--case", "no-such").returncode == 2
    assert not (tmp_path / "lands.ran").exists()


def test_harness_sha_falls_back_to_the_script_checkout(tmp_path, env):
    env = {k: v for k, v in env.items() if k != "AUTOCODER_HARNESS_SHA"}
    head = subprocess.run(["git", "rev-parse", "HEAD"], cwd=SCRIPTS, capture_output=True, text=True).stdout.strip()
    rows = run_json(env, "--worker", fake(tmp_path, "lands", LANDS), "--case", "case-b")["rows"]
    assert rows[0]["harness"] == {"sha": head}


# ── verify() on hand-built traces ────────────────────────────────────────────
def load_runner():
    spec = importlib.util.spec_from_file_location("eval_run", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture(scope="module")
def verify():
    return load_runner().verify


def trace(**over):
    base = {"trace_id": "repo-a-1234abcd:1:1", "outcome": "landed",
            "steps": [{"kind": "claimed"}, {"kind": "gate-end"}, {"kind": "landed"}],
            "gates": [{"attempt": 1, "outcome": "landed"}], "returned": [],
            "session": {"is_error": False, "tools": {"calls": 4, "errors": 0, "by_name": {"Bash": {"calls": 4, "errors": 0}}}},
            "review": None, "next_attempt": None}
    return {**base, **over}


UNBOUNDED = {"outcome": None, "classifiers_silent": [], "max_gates": None, "max_tool_calls": None,
             "steps_present": [], "steps_absent": []}
CONFLICT_ESCALATED = {"outcome": "escalated", "steps": [{"kind": "claimed"}, {"kind": "escalated"}],
                      "gates": [{"attempt": 1, "outcome": "conflict", "escalated": True, "conflict_files": ["a"]}]}
VERIFY_CASES = {
    "outcome holds": ({"outcome": "landed"}, {}, []),
    "outcome differs": ({"outcome": "landed"}, {"outcome": "escalated"}, ["outcome"]),
    "classifier silent": ({"classifiers_silent": ["conflict-escalated-early"]}, {}, []),
    "classifier fires": ({"classifiers_silent": ["conflict-escalated-early"]}, CONFLICT_ESCALATED,
                         ["classifiers_silent:conflict-escalated-early"]),
    "gates within bound": ({"max_gates": 1}, {}, []),
    "gates over bound": ({"max_gates": 1}, {"gates": [{"outcome": "conflict"}, {"outcome": "landed"}]}, ["max_gates"]),
    "tool calls within bound": ({"max_tool_calls": 4}, {}, []),
    "tool calls over bound": ({"max_tool_calls": 3}, {}, ["max_tool_calls"]),
    "tool calls unknown": ({"max_tool_calls": 3}, {"session": None}, ["max_tool_calls"]),
    "step present": ({"steps_present": ["landed"]}, {}, []),
    "step missing": ({"steps_present": ["landed", "gate-start"]}, {}, ["steps_present:gate-start"]),
    "step absent": ({"steps_absent": ["verdict-nudged"]}, {}, []),
    "step not absent": ({"steps_absent": ["verdict-nudged"]}, {"steps": [{"kind": "verdict-nudged"}]},
                        ["steps_absent:verdict-nudged"]),
    "null bounds pass anything": ({}, {**CONFLICT_ESCALATED, "session": None, "gates": [{}] * 9}, []),
}


@pytest.mark.parametrize("name", sorted(VERIFY_CASES))
def test_verify(verify, name):
    spec, over, failed = VERIFY_CASES[name]
    assert verify(trace(**over), {**UNBOUNDED, **spec}) == failed


def test_verify_without_a_trace_fails(verify):
    assert verify(None, UNBOUNDED) == ["trace"]
