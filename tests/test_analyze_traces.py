"""analyze-traces.py: classifiers, priority, report and the judged pass, on the fixture corpus (#395)."""

from __future__ import annotations

import importlib.util
import json
import os
import stat
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "plugins" / "autocoder" / "scripts"
FIXTURES = ROOT / "tests" / "fixtures" / "traces"
A, B = "repo-a-1234abcd", "repo-b-5678efgh"


def env_for(tmp_path, **extra):
    e = {k: v for k, v in os.environ.items() if k != "AUTOCODER_TRACES"}
    e.update({"XDG_STATE_HOME": str(tmp_path / "state"), "TZ": "UTC", **extra})
    return e


@pytest.fixture(scope="module")
def corpus(tmp_path_factory):
    tmp = tmp_path_factory.mktemp("corpus")
    out = tmp / "traces.jsonl"
    r = subprocess.run([sys.executable, str(SCRIPTS / "trace-build.py"),
                        "--issue-events", str(FIXTURES / "issue-events.jsonl"),
                        "--merge-events", str(FIXTURES / "merge-events.jsonl"),
                        "--landing-timings", str(FIXTURES / "landing-timings.jsonl"),
                        "--gate-log", str(FIXTURES / "gate.jsonl"),
                        "--log-dir", str(FIXTURES), "--comments-dir", str(FIXTURES / "comments"),
                        "--out", str(out)], capture_output=True, text=True, env=env_for(tmp))
    assert r.returncode == 0, r.stderr
    return out


def analyze(tmp_path, traces, *args, **extra_env):
    return subprocess.run([sys.executable, str(SCRIPTS / "analyze-traces.py"), "--traces", str(traces), *args],
                          capture_output=True, text=True, env=env_for(tmp_path, **extra_env))


def report(tmp_path, traces, *args, **extra_env):
    r = analyze(tmp_path, traces, "--json", *args, **extra_env)
    assert r.returncode == 0, r.stderr
    return json.loads(r.stdout)


@pytest.fixture(scope="module")
def full(corpus, tmp_path_factory):
    return report(tmp_path_factory.mktemp("report"), corpus)


def issues(trace_ids):
    return sorted((int(t.split(":")[1]) if t.startswith(A) else t for t in trace_ids), key=str)


def fired(rep, classifier_id):
    return issues({t for f in rep["findings"] if f["id"] == classifier_id for t in f["traces"]})


# Every classifier and exactly the fixture scenarios it fires on. A new scenario that trips a
# second classifier changes a row here.
EXPECTED = {
    "gate-red-suite": [11, 17],
    "returned-by-cause": [11, 12, 13, 17],
    "conflict-escalated-early": [12],
    "conflict-retried-late": [13],
    "reclaimed": [14],
    "landed-unreviewed": [15, f"{B}:100:1"],
    "review-left-important": [11],
    "verdict-nudged": [16],
    "red-base": [17],
    "tool-errors": [12],
    "session-without-gate": [19],
}


def load_analyst():
    spec = importlib.util.spec_from_file_location("analyze_traces", SCRIPTS / "analyze-traces.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_every_classifier_has_a_row():
    assert sorted(c.id for c in load_analyst().classifiers()) == sorted(EXPECTED)


@pytest.mark.parametrize("classifier_id", sorted(EXPECTED))
def test_classifier_fires_on_exactly_its_scenarios(full, classifier_id):
    assert fired(full, classifier_id) == sorted(EXPECTED[classifier_id], key=str)


def test_reclaimed_names_only_the_attempt_that_was_reclaimed(full):
    assert [f["traces"] for f in full["findings"] if f["id"] == "reclaimed"] == [[f"{A}:14:1"]]


def test_groups_split_findings_by_key(full):
    keyed = {(f["id"], f["key"]): (issues(f["traces"]), f["rules"]) for f in full["findings"]
             if f["id"] in ("gate-red-suite", "returned-by-cause", "tool-errors")}
    assert keyed == {
        ("gate-red-suite", "tests/test_x.sh"): ([11], ["B01"]),
        ("gate-red-suite", "tests/test_y.sh"): ([17], ["B01"]),
        ("returned-by-cause", "conflict"): ([12, 13], ["B02"]),
        ("returned-by-cause", "defect"): ([11], ["B01"]),
        ("returned-by-cause", "red-integration"): ([17], ["B09"]),
        ("tool-errors", "Bash"): ([12], ["B10"]),
    }


def test_tool_errors_names_the_most_failing_tool(full):
    f = next(f for f in full["findings"] if f["id"] == "tool-errors")
    assert f["evidence"][0] == {"trace_id": f"{A}:12:1", "tool": "Bash", "error_share": 0.333,
                                "calls": 12, "errors": 4, "tool_errors": 4}


def test_tool_error_share_threshold(tmp_path, corpus):
    assert fired(report(tmp_path, corpus, "--tool-error-share", "0.34"), "tool-errors") == []
    assert fired(report(tmp_path, corpus, "--tool-error-share", "0.3"), "tool-errors") == [12]


def test_findings_sorted_by_severity_then_count(full):
    keys = [(-f["severity"], -f["count"], f["judged"], f["id"], f["key"] or "") for f in full["findings"]]
    assert keys == sorted(keys)
    assert full["findings"][0]["severity"] == 2


def test_corpus_and_unmatched(full):
    assert (full["corpus"], full["unmatched"], full["judge"]) == (12, 3, None)
    assert full["window"] == {"since": None, "until": None}
    f = next(f for f in full["findings"] if f["id"] == "red-base")
    assert (f["count"], f["share"], f["surface"]) == (1, round(1 / 12, 3), "integration branch")


def test_since_until_filter_by_start(tmp_path, corpus):
    rep = report(tmp_path, corpus, "--since", "2026-11-20T13:00:00Z", "--until", "2026-11-20T15:00:00Z")
    assert rep["corpus"] == 3
    assert {f["id"] for f in rep["findings"]} == {"returned-by-cause", "conflict-retried-late", "reclaimed"}
    assert rep["window"]["since"].startswith("2026-11-20T13:00:00")


@pytest.mark.parametrize("trace,expected", [
    ({"outcome": "landed", "review": None}, None),
    ({"outcome": "landed", "review": {"status": "skipped"}}, None),
    ({"outcome": "landed", "review": {"status": "reviewed", "verdict": "pass"}}, None),
    ({"outcome": "returned", "review": {"status": "no record"}}, None),
    ({"outcome": "landed", "review": {"status": "no record"}}, {"review": "no record", "verdict": None}),
])
def test_landed_unreviewed_reads_only_a_review_record(trace, expected):
    match = {c.id: c.match for c in load_analyst().classifiers()}["landed-unreviewed"]
    assert match(trace) == expected


@pytest.mark.parametrize("gates,steps,fires", [
    ([{"outcome": "conflict", "escalated": False}], [{"kind": "escalated"}], True),
    ([{"outcome": "conflict", "escalated": True}], [], True),
    ([{"outcome": "conflict", "escalated": False}], [], False),
    ([{"outcome": "conflict", "escalated": True}, {"outcome": "conflict", "escalated": True}], [], False),
])
def test_conflict_escalated_early(gates, steps, fires):
    match = {c.id: c.match for c in load_analyst().classifiers()}["conflict-escalated-early"]
    assert (match({"gates": gates, "steps": steps}) is not None) == fires


def test_markdown_report(tmp_path, corpus):
    r = analyze(tmp_path, corpus)
    assert r.returncode == 0, r.stderr
    lines = r.stdout.splitlines()
    assert lines[0] == "# Trace findings"
    section = lines.index("## gate-red-suite: tests/test_x.sh")
    assert lines[section + 2:section + 6] == [
        "- Rules: B01", "- Surface: gate", "- Count: 1 (8% of the corpus)",
        f'- `{A}:11:1`: {{"tests_failed": ["tests/test_x.sh"]}}']
    assert "## red-base" in lines
    tail = lines[lines.index("## Corpus"):]
    assert tail == ["## Corpus", "", "- Traces: 12", "- Window: all", "- Matched by no classifier: 3"]


def test_empty_corpus(tmp_path):
    missing = tmp_path / "none.jsonl"
    r = analyze(tmp_path, missing)
    assert r.returncode == 0
    assert "No traces in the corpus." in r.stdout and "- Traces: 0" in r.stdout
    rep = report(tmp_path, missing)
    assert (rep["corpus"], rep["findings"], rep["unmatched"]) == (0, [], 0)


# ── judged pass ──────────────────────────────────────────────────────────────
def fake_judge(tmp_path, body):
    script = tmp_path / "judge.sh"
    script.write_text('#!/bin/sh\ninput=$(cat)\necho called >> "$JUDGE_CALLS"\n'
                      'printf "%s\\n" "$input" > "$JUDGE_LAST"\n' + body)
    script.chmod(script.stat().st_mode | stat.S_IXUSR)
    return str(script)


B12_FOR_ISSUE_10 = ('case "$input" in *\'"issue": 10,\'*) '
                    'echo \'[{"rule":"B12","evidence":"too large","confidence":0.9}]\';; *) echo \'[]\';; esac\n')


def judged_report(tmp_path, corpus, body, *args):
    calls, last = tmp_path / "calls", tmp_path / "last"
    rep = report(tmp_path, corpus, "--judge", fake_judge(tmp_path, body), *args,
                 JUDGE_CALLS=str(calls), JUDGE_LAST=str(last))
    n_calls = len(calls.read_text().splitlines()) if calls.exists() else 0
    return rep, n_calls, last


def test_judge_finding(tmp_path, corpus):
    rep, calls, _ = judged_report(tmp_path, corpus, B12_FOR_ISSUE_10)
    assert calls == 3
    assert rep["judge"] == {"prompt": "trace-judge.v1.md", "traces": 3, "errors": 0}
    judged = [f for f in rep["findings"] if f["judged"]]
    assert len(judged) == 1
    f = judged[0]
    assert (f["id"], f["key"], f["rules"], f["traces"], f["judge_prompt"]) == \
        ("judged", "B12", ["B12"], [f"{A}:10:1"], "trace-judge.v1.md")
    assert f["evidence"] == [{"trace_id": f"{A}:10:1", "rule": "B12", "evidence": "too large", "confidence": 0.9}]
    same = [g for g in rep["findings"] if g["severity"] == f["severity"]]
    assert same[-1]["judged"] and not any(g["judged"] for g in same[:-1])
    assert rep["unmatched"] == 3


def test_judge_input_is_prompt_then_spec_then_trace(tmp_path, corpus):
    prompt, spec = tmp_path / "prompt.v9.md", tmp_path / "spec.md"
    prompt.write_text("PROMPT-MARKER\n")
    spec.write_text("SPEC-MARKER\n")
    rep, _, last = judged_report(tmp_path, corpus, "echo '[]'\n", "--judge-prompt", str(prompt), "--spec", str(spec))
    text = last.read_text()
    assert text.index("PROMPT-MARKER") < text.index("SPEC-MARKER") < text.index('"trace_id"')
    assert rep["judge"]["prompt"] == "prompt.v9.md"


@pytest.mark.parametrize("body", [
    "echo 'not json'\n",
    "echo '{\"rule\": \"B12\"}'\n",
    "echo '[{\"evidence\": \"no rule\"}]'\n",
    "echo '[{\"rule\": 12}]'\n",
    "echo '[{\"rule\": \"B12\"}]'; exit 1\n",
])
def test_judge_errors_are_counted_never_findings(tmp_path, corpus, body):
    rep, calls, _ = judged_report(tmp_path, corpus, body)
    assert calls == 3
    assert rep["judge"]["errors"] == 3
    assert not [f for f in rep["findings"] if f["judged"]]


def test_judge_errors_in_markdown(tmp_path, corpus):
    r = analyze(tmp_path, corpus, "--judge", fake_judge(tmp_path, "echo 'not json'\n"),
                JUDGE_CALLS=str(tmp_path / "calls"), JUDGE_LAST=str(tmp_path / "last"))
    assert r.returncode == 0
    assert r.stdout.splitlines()[-1] == "- Judge errors: 3 of 3 traces judged (trace-judge.v1.md)"


def test_judge_all_judges_every_trace(tmp_path, corpus):
    rep, calls, _ = judged_report(tmp_path, corpus, B12_FOR_ISSUE_10, "--judge-all")
    assert calls == 12
    assert rep["judge"]["traces"] == 12

