"""eval-author.py: scaffold a case from a finding, alternate its split, list and check cases (#395)."""

from __future__ import annotations

import importlib.util
import json
import os
import re
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "plugins" / "autocoder" / "scripts"
SCRIPT = SCRIPTS / "eval-author.py"
B02 = "A conflict or a rejected push is rebased and relaunched, never escalated on the first time"
FINDING = {"id": "conflict-escalated-early", "key": None, "rules": ["B02"], "surface": "commands/fix.md § Landing the Work",
           "count": 2, "traces": ["repo-a-1234abcd:12:1", "repo-a-1234abcd:20:1"], "share": 0.1,
           "evidence": [{"trace_id": "repo-a-1234abcd:12:1", "conflict_files": ["src/file.sh"], "reason": "conflict"}],
           "severity": 2.0, "judged": False}
SUITE = {**FINDING, "id": "gate-red-suite", "key": "tests/test_x.sh", "rules": ["B01"], "surface": "gate",
         "evidence": [{"trace_id": "repo-a-1234abcd:11:1", "tests_failed": ["tests/test_x.sh"]}]}


def load_author():
    spec = importlib.util.spec_from_file_location("eval_author", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def run(tmp_path, *args, cwd=None):
    env = {**os.environ, "XDG_STATE_HOME": str(tmp_path / "state"),
           "AUTOCODER_EVAL_CASES": str(tmp_path / "cases"), "AUTOCODER_EVAL_RESULTS": str(tmp_path / "results.jsonl")}
    return subprocess.run([sys.executable, str(SCRIPT), *args], capture_output=True, text=True, env=env,
                          cwd=cwd or tmp_path)


def new(tmp_path, finding=FINDING, *args):
    r = run(tmp_path, "new", "--finding", json.dumps(finding), *args)
    assert r.returncode == 0, r.stderr
    return Path(r.stdout.strip())


def complete(case_dir: Path, title="Add a retry flag to the sync script"):
    """Do what the author does: write the task and the title, so no TODO is left."""
    (case_dir / "task.md").write_text("The sync script should accept --retries N and retry a failed fetch.\n")
    case = json.loads((case_dir / "case.json").read_text())
    case["issue"]["title"] = title
    (case_dir / "case.json").write_text(json.dumps(case))


def test_new_scaffolds_case_json_with_the_tables_verifier(tmp_path):
    case_dir = new(tmp_path)
    assert case_dir == tmp_path / "cases" / "dev" / "conflict-escalated-early-001"
    case = json.loads((case_dir / "case.json").read_text())
    assert re.fullmatch(r"\d{4}-\d{2}-\d{2}", case.pop("authored"))
    assert case == {
        "v": 1, "id": "conflict-escalated-early-001", "split": "dev",
        "finding": {"id": "conflict-escalated-early", "key": None, "rules": ["B02"],
                    "traces": ["repo-a-1234abcd:12:1", "repo-a-1234abcd:20:1"]},
        "issue": {"title": "TODO: the issue title the worker sees", "labels": ["P2", "bug"]},
        "verify": {"outcome": "landed", "classifiers_silent": ["conflict-escalated-early"], "max_gates": 2,
                   "max_tool_calls": None, "steps_present": [], "steps_absent": []}}
    assert (case_dir / "seed").is_dir()


def test_task_md_carries_rule_text_evidence_and_todo_markers(tmp_path):
    task = (new(tmp_path) / "task.md").read_text()
    assert f"B02: {B02}" in task
    assert "`repo-a-1234abcd:12:1`" in task and "src/file.sh" in task
    assert task.count("TODO") >= 3


def test_split_alternates_per_finding_and_split_flag_forces(tmp_path):
    made = [new(tmp_path) for _ in range(3)]
    assert [(d.parent.name, d.name) for d in made] == [
        ("dev", "conflict-escalated-early-001"), ("heldout", "conflict-escalated-early-002"),
        ("dev", "conflict-escalated-early-003")]
    other = new(tmp_path, SUITE)
    assert (other.parent.name, other.name) == ("dev", "gate-red-suite-tests-test-x-sh-001")
    forced = new(tmp_path, SUITE, "--split", "dev")
    assert forced.parent.name == "dev"
    assert new(tmp_path, SUITE).parent.name == "dev"  # two of this finding before it, so dev again


def test_new_from_findings_file_by_index(tmp_path):
    report = tmp_path / "findings.json"
    report.write_text(json.dumps({"corpus": 20, "findings": [FINDING, SUITE]}))
    r = run(tmp_path, "new", "--findings-file", str(report), "--index", "1", "--id", "suite-case")
    assert r.returncode == 0, r.stderr
    case = json.loads((tmp_path / "cases" / "dev" / "suite-case" / "case.json").read_text())
    assert case["finding"]["id"] == "gate-red-suite" and case["verify"]["max_gates"] == 1
    assert run(tmp_path, "new", "--findings-file", str(report), "--index", "5").returncode == 2


def test_new_refuses_an_existing_id(tmp_path):
    new(tmp_path, FINDING, "--id", "one")
    assert run(tmp_path, "new", "--finding", json.dumps(FINDING), "--id", "one").returncode == 1


def test_list_filters_by_split(tmp_path):
    for _ in range(3):
        new(tmp_path)
    everything = run(tmp_path, "list").stdout.splitlines()
    held = run(tmp_path, "list", "--split", "heldout").stdout.splitlines()
    assert [line.split("\t")[:2] for line in everything] == [
        ["dev", "conflict-escalated-early-001"], ["dev", "conflict-escalated-early-003"],
        ["heldout", "conflict-escalated-early-002"]]
    assert [line.split("\t")[:2] for line in held] == [["heldout", "conflict-escalated-early-002"]]


def test_check_passes_a_completed_case_and_fails_a_scaffold(tmp_path):
    case_dir = new(tmp_path)
    r = run(tmp_path, "check")
    assert r.returncode == 1
    assert "dev/conflict-escalated-early-001: task.md still has a TODO" in r.stdout
    assert "dev/conflict-escalated-early-001: issue.title still has a TODO" in r.stdout
    complete(case_dir)
    r = run(tmp_path, "check")
    assert r.returncode == 0, r.stdout
    assert "1 case(s) ok" in r.stdout


def edit_case(case_dir: Path, **changes):
    case = json.loads((case_dir / "case.json").read_text())
    for dotted, value in changes.items():
        *path, last = dotted.split("__")
        node = case
        for k in path:
            node = node[k]
        node[last] = value
    (case_dir / "case.json").write_text(json.dumps(case))


DEFECTS = {
    "todo left": (lambda d: (d / "task.md").write_text("Fix it. TODO: say more\n"), "task.md still has a TODO"),
    "unknown classifier": (lambda d: edit_case(d, verify__classifiers_silent=["no-such-classifier"]),
                           "unknown classifier 'no-such-classifier'"),
    "unknown rule": (lambda d: edit_case(d, finding__rules=["B02", "B99"]), "unknown rule 'B99'"),
    "split mismatch": (lambda d: edit_case(d, split="heldout"), "split 'heldout' does not match its directory 'dev'"),
    "bad json": (lambda d: (d / "case.json").write_text("{not json"), "case.json is not valid JSON"),
    "unknown verify key": (lambda d: edit_case(d, verify__max_gate=1), "verify has an unknown key 'max_gate'"),
    "bad outcome": (lambda d: edit_case(d, verify__outcome="merged"), "verify.outcome 'merged'"),
}


@pytest.mark.parametrize("defect", sorted(DEFECTS))
def test_check_names_each_bad_case(tmp_path, defect):
    good, bad = (new(tmp_path, FINDING, "--id", name, "--split", "dev") for name in ("good-case", "bad-case"))
    complete(good)
    complete(bad)
    breaks, message = DEFECTS[defect]
    breaks(bad)
    r = run(tmp_path, "check")
    assert r.returncode == 1
    lines = r.stdout.splitlines()
    assert any(line.startswith("dev/bad-case: ") and message in line for line in lines), r.stdout
    assert not any(line.startswith("dev/good-case") for line in lines)


def test_check_flags_a_case_moved_to_the_other_split(tmp_path):
    case_dir = new(tmp_path)
    complete(case_dir)
    (tmp_path / "cases" / "heldout").mkdir()
    case_dir.rename(tmp_path / "cases" / "heldout" / case_dir.name)
    r = run(tmp_path, "check")
    assert r.returncode == 1
    assert "heldout/conflict-escalated-early-001: split 'dev' does not match its directory 'heldout'" in r.stdout


def test_every_classifier_has_a_default_verifier_that_checks_clean(tmp_path):
    author = load_author()
    ids = {c.id for c in author.ANALYST.classifiers()}
    assert set(author.VERIFY_DEFAULTS) == ids
    for cid in sorted(ids):
        complete(new(tmp_path, {**FINDING, "id": cid}))
    r = run(tmp_path, "check")
    assert r.returncode == 0, r.stdout


def test_cases_default_to_the_repository_root(tmp_path):
    repo = tmp_path / "repo"
    (repo / "sub").mkdir(parents=True)
    subprocess.run(["git", "init", "-q", str(repo)], check=True)
    env = {k: v for k, v in os.environ.items() if k != "AUTOCODER_EVAL_CASES"}
    env["XDG_STATE_HOME"] = str(tmp_path / "state")
    r = subprocess.run([sys.executable, str(SCRIPT), "new", "--finding", json.dumps(FINDING)],
                       capture_output=True, text=True, env=env, cwd=repo / "sub")
    assert r.returncode == 0, r.stderr
    assert (repo / ".autocoder" / "evals" / "dev" / "conflict-escalated-early-001" / "case.json").is_file()
