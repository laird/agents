"""analyze-traces.py: classifiers, priority, report and the judged pass, on the fixture corpus (#395, #422)."""

from __future__ import annotations

import importlib.util
import json
import os
import stat
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "plugins" / "autocoder" / "scripts"
FIXTURES = ROOT / "tests" / "fixtures" / "traces"
A, B = "repo-a-1234abcd", "repo-b-5678efgh"


def env_for(tmp_path, **extra):
    e = {k: v for k, v in os.environ.items() if k not in ("AUTOCODER_TRACES", "AUTOCODER_TICKS")}
    e.update({"XDG_STATE_HOME": str(tmp_path / "state"), "TZ": "UTC", **extra})
    return e


def build_corpus(tmp, *extra):
    out = tmp / "traces.jsonl"
    r = subprocess.run([sys.executable, str(SCRIPTS / "trace-build.py"),
                        "--issue-events", str(FIXTURES / "issue-events.jsonl"),
                        "--merge-events", str(FIXTURES / "merge-events.jsonl"),
                        "--landing-timings", str(FIXTURES / "landing-timings.jsonl"),
                        "--gate-log", str(FIXTURES / "gate.jsonl"), "--train-gate-issue", "23",
                        "--log-dir", str(FIXTURES), "--comments-dir", str(FIXTURES / "comments"),
                        "--out", str(out), *extra], capture_output=True, text=True, env=env_for(tmp), cwd=tmp)
    assert r.returncode == 0, r.stderr
    return out


@pytest.fixture(scope="module")
def corpus(tmp_path_factory):
    return build_corpus(tmp_path_factory.mktemp("corpus"))


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
    "returned-by-cause": [11, 12, 13, 17, 21],
    "conflict-escalated-early": [12],
    "conflict-retried-late": [13],
    "reclaimed": [14, 22, 25],   # 25:1 bounced and was claimed again; 25:2 was not
    "claim-bounced": [25, 25],
    "landed-unreviewed": [15, f"{B}:100:1"],
    "review-left-important": [11],
    "verdict-nudged": [16],
    "red-base": [17],
    "tool-errors": [12],
    "session-without-gate": [19],
}


# The live-shape scenarios (20, 21, 22, 24 and 25 twice each) grew the corpus from 12; 20, 22:2, 24:1 and 24:2
# match nothing.
CORPUS, UNMATCHED = 20, 7


def load_analyst():
    spec = importlib.util.spec_from_file_location("analyze_traces", SCRIPTS / "analyze-traces.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_every_classifier_has_a_row():
    assert sorted(c.id for c in load_analyst().classifiers()) == sorted({**EXPECTED, **TICK_EXPECTED})


@pytest.mark.parametrize("classifier_id", sorted(EXPECTED))
def test_classifier_fires_on_exactly_its_scenarios(full, classifier_id):
    assert fired(full, classifier_id) == sorted(EXPECTED[classifier_id], key=str)


def test_reclaimed_names_only_the_attempt_that_was_reclaimed(full):
    assert [f["traces"] for f in full["findings"] if f["id"] == "reclaimed"] == [[f"{A}:14:1", f"{A}:22:1", f"{A}:25:1"]]


def test_claim_bounced_names_each_bounce_with_its_seconds_and_worker(full):
    # 22:1 was released five minutes after its claim, past the two-minute bound; 20 posted READY first.
    f = next(f for f in full["findings"] if f["id"] == "claim-bounced")
    assert (f["traces"], f["rules"], f["surface"]) == ([f"{A}:25:1", f"{A}:25:2"], ["B13"], "scripts/claim-issue.sh")
    assert f["evidence"] == [{"trace_id": f"{A}:25:1", "seconds": 25, "worker": "w1"},
                             {"trace_id": f"{A}:25:2", "seconds": 25, "worker": "w2"}]


def test_reclaimed_silent_on_a_claim_and_its_readback(full):
    # 20 and 21 each wrote `claimed` twice and landed on the train; 24 also saw a lost claim race.
    assert not {20, 21, 24} & set(fired(full, "reclaimed"))


def test_groups_split_findings_by_key(full):
    keyed = {(f["id"], f["key"]): (issues(f["traces"]), f["rules"]) for f in full["findings"]
             if f["id"] in ("gate-red-suite", "returned-by-cause", "tool-errors")}
    assert keyed == {
        ("gate-red-suite", "tests/test_x.sh"): ([11], ["B01"]),
        ("gate-red-suite", "tests/test_y.sh"): ([17], ["B01"]),
        ("returned-by-cause", "conflict"): ([12, 13], ["B02"]),
        ("returned-by-cause", "defect"): ([11], ["B01"]),
        ("returned-by-cause", "infra"): ([21], []),
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
    assert full["findings"][0]["severity"] == 3   # reclaimed: 14, 22 and 25:1


def test_corpus_and_unmatched(full):
    assert (full["corpus"], full["unmatched"], full["judge"]) == (CORPUS, UNMATCHED, None)
    assert full["window"] == {"since": None, "until": None}
    f = next(f for f in full["findings"] if f["id"] == "red-base")
    assert (f["count"], f["share"], f["surface"]) == (1, round(1 / CORPUS, 3), "integration branch")


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
        "- Rules: B01", "- Surface: gate", f"- Count: 1 ({1 / CORPUS:.0%} of the attempts)",
        f'- `{A}:11:1`: {{"tests_failed": ["tests/test_x.sh"]}}']
    assert "## red-base" in lines
    tail = lines[lines.index("## Corpus"):]
    assert tail == ["## Corpus", "", f"- Traces: {CORPUS}", "- Window: all", f"- Matched by no classifier: {UNMATCHED}"]


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
    assert calls == UNMATCHED
    assert rep["judge"] == {"prompt": "trace-judge.v1.md", "traces": UNMATCHED, "errors": 0}
    judged = [f for f in rep["findings"] if f["judged"]]
    assert len(judged) == 1
    f = judged[0]
    assert (f["id"], f["key"], f["rules"], f["traces"], f["judge_prompt"]) == \
        ("judged", "B12", ["B12"], [f"{A}:10:1"], "trace-judge.v1.md")
    assert f["evidence"] == [{"trace_id": f"{A}:10:1", "rule": "B12", "evidence": "too large", "confidence": 0.9}]
    same = [g for g in rep["findings"] if g["severity"] == f["severity"]]
    assert same[-1]["judged"] and not any(g["judged"] for g in same[:-1])
    assert rep["unmatched"] == UNMATCHED


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
    assert calls == UNMATCHED
    assert rep["judge"]["errors"] == UNMATCHED
    assert not [f for f in rep["findings"] if f["judged"]]


def test_judge_errors_in_markdown(tmp_path, corpus):
    r = analyze(tmp_path, corpus, "--judge", fake_judge(tmp_path, "echo 'not json'\n"),
                JUDGE_CALLS=str(tmp_path / "calls"), JUDGE_LAST=str(tmp_path / "last"))
    assert r.returncode == 0
    assert r.stdout.splitlines()[-1] == f"- Judge errors: {UNMATCHED} of {UNMATCHED} traces judged (trace-judge.v1.md)"


def test_judge_all_judges_every_trace(tmp_path, corpus):
    rep, calls, _ = judged_report(tmp_path, corpus, B12_FOR_ISSUE_10, "--judge-all")
    assert calls == CORPUS
    assert rep["judge"]["traces"] == CORPUS



# ── ticks (#422) ─────────────────────────────────────────────────────────────
# Tick classifier -> the fixture ticks it fires on (tests/fixtures/traces/ticks.jsonl). The healthy
# loop is the near miss: two errors in a row, and one run 4.5 times its median.
TICK_EXPECTED = {
    "tick-error-streak": [f"{A}:tick:streaky:02", f"{A}:tick:streaky:03", f"{A}:tick:streaky:04"],
    "tick-slow": [f"{A}:tick:slow:06"],
    "tick-noop-only": [f"{A}:tick:idle:12"],
    "tick-missing": [f"{A}:tick:lapsed:10", f"{B}:tick:stopped:10"],
}
TICKS = 63


@pytest.fixture(scope="module")
def mixed(tmp_path_factory):
    tmp = tmp_path_factory.mktemp("mixed")
    return report(tmp, build_corpus(tmp, "--ticks", str(FIXTURES / "ticks.jsonl")))


@pytest.mark.parametrize("classifier_id", sorted(TICK_EXPECTED))
def test_tick_classifier_fires_on_exactly_its_scenario(mixed, classifier_id):
    found = [f for f in mixed["findings"] if f["id"] == classifier_id]
    assert sorted(t for f in found for t in f["traces"]) == TICK_EXPECTED[classifier_id]
    assert {f["key"] for f in found} == {t.split(":")[2] for t in TICK_EXPECTED[classifier_id]}
    assert {(f["kind"], f["surface"]) for f in found} == {("tick", "loop")}


def test_no_attempt_classifier_sees_a_tick(full, mixed):
    def attempt_findings(rep):
        return [(f["id"], f["key"], f["traces"], f["evidence"], f["share"]) for f in rep["findings"] if f["kind"] == "attempt"]
    assert attempt_findings(mixed) == attempt_findings(full)
    assert not [t for f in mixed["findings"] if f["id"] in EXPECTED for t in f["traces"] if ":tick:" in t]


def test_tick_evidence_and_share(mixed):
    by_id = {f["id"]: f for f in mixed["findings"]}
    assert by_id["tick-slow"]["evidence"] == [
        {"trace_id": f"{A}:tick:slow:06", "loop": "slow", "duration_s": 60.0, "median_s": 10.0}]
    assert by_id["tick-slow"]["share"] == round(1 / TICKS, 3)
    assert by_id["tick-noop-only"]["evidence"] == [
        {"trace_id": f"{A}:tick:idle:12", "loop": "idle", "noop_ticks": 12, "since": "2026-11-20T12:00:00Z"}]
    gaps = {f["key"]: f["evidence"][0] for f in mixed["findings"] if f["id"] == "tick-missing"}
    assert gaps == {
        "lapsed": {"trace_id": f"{A}:tick:lapsed:10", "loop": "lapsed", "gap_s": 7200, "median_gap_s": 600,
                   "resumed": "2026-11-20T22:30:00Z"},
        "stopped": {"trace_id": f"{B}:tick:stopped:10", "loop": "stopped", "gap_s": 15300, "median_gap_s": 300,
                    "resumed": None}}
    streak = next(f for f in mixed["findings"] if f["id"] == "tick-error-streak")
    assert [(e["outcome"], e["streak"], e["error"]) for e in streak["evidence"]] == [
        ("error", 3, "lock held"), ("timeout", 3, "killed after 300s"), ("error", 3, "lock held")]


def test_corpus_counts_ticks(mixed, tmp_path):
    assert (mixed["corpus"], mixed["ticks"]) == (CORPUS + TICKS, TICKS)
    r = analyze(tmp_path, build_corpus(tmp_path, "--ticks", str(FIXTURES / "ticks.jsonl")))
    lines = r.stdout.splitlines()
    section = lines.index("## tick-slow: slow")
    assert lines[section + 2:section + 5] == ["- Rules: B15", "- Surface: loop", f"- Count: 1 ({1 / TICKS:.0%} of the ticks)"]
    assert lines[lines.index("## Corpus") + 2:lines.index("## Corpus") + 4] == [
        f"- Traces: {CORPUS + TICKS}", f"- Ticks among them: {TICKS}"]


def test_since_until_apply_to_ticks(tmp_path):
    corpus = build_corpus(tmp_path, "--ticks", str(FIXTURES / "ticks.jsonl"))
    rep = report(tmp_path, corpus, "--since", "2026-11-20T22:00:00Z", "--until", "2026-11-20T22:40:00Z")
    assert rep["ticks"] == 14   # healthy, streaky and slow 4 each, lapsed and idle 1 each
    assert {f["id"] for f in rep["findings"] if f["kind"] == "tick"} == {"tick-error-streak"}


def test_judge_reads_no_ticks(tmp_path):
    corpus = build_corpus(tmp_path, "--ticks", str(FIXTURES / "ticks.jsonl"))
    calls = tmp_path / "calls"
    rep = report(tmp_path, corpus, "--judge", fake_judge(tmp_path, "echo '[]'\n"), "--judge-all",
                 JUDGE_CALLS=str(calls), JUDGE_LAST=str(tmp_path / "last"))
    assert len(calls.read_text().splitlines()) == rep["judge"]["traces"] == CORPUS


def tick(minute, outcome="ok", duration=1.0, loop="l"):
    started = datetime(2026, 11, 20, tzinfo=timezone.utc) + timedelta(minutes=minute)
    return {"kind": "tick", "trace_id": f"r:tick:{loop}:{minute}", "repo": "r", "loop": loop,
            "started": started.strftime("%Y-%m-%dT%H:%M:%SZ"), "outcome": outcome, "tick": {"duration_s": duration}}


def tick_hits(classifier_id, ticks):
    analyst = load_analyst()
    c = {c.id: c for c in analyst.classifiers()}[classifier_id]
    return sorted(tid for loop in analyst.loops_of(ticks) for tid in c.match(loop))


@pytest.mark.parametrize("classifier_id,ticks,hits", [
    ("tick-noop-only", [tick(60 * i, "noop") for i in range(10)], ["r:tick:l:540"]),
    ("tick-noop-only", [tick(60 * i, "noop") for i in range(9)], []),
    ("tick-noop-only", [tick(60 * i, "ok" if i == 9 else "noop") for i in range(10)], []),
    # Older than the corpus's last day: the ok tick does not count, the ten noops after it do.
    ("tick-noop-only", [tick(0, "ok")] + [tick(1500 + 60 * i, "noop") for i in range(10)], ["r:tick:l:2040"]),
    ("tick-slow", [tick(i, duration=1.0) for i in range(9)] + [tick(9, duration=60.0)], ["r:tick:l:9"]),
    ("tick-slow", [tick(i, duration=1.0) for i in range(8)] + [tick(9, duration=60.0)], []),
    ("tick-slow", [tick(i, duration=None) for i in range(12)], []),
    ("tick-missing", [tick(i) for i in range(9)], []),
    ("tick-missing", [tick(i) for i in range(10)] + [tick(14)], []),
    ("tick-missing", [tick(i) for i in range(10)] + [tick(15)], ["r:tick:l:9"]),
    # Another loop's later tick is the corpus's end, so the silence after this loop's last tick counts.
    ("tick-missing", [tick(i) for i in range(10)] + [tick(60, loop="other")], ["r:tick:l:9"]),
    ("tick-error-streak", [tick(i, o) for i, o in enumerate(["error", "timeout", "ok", "error", "error"])], []),
    ("tick-error-streak", [tick(i, o) for i, o in enumerate(["ok", "timeout", "error", "error"])],
     ["r:tick:l:1", "r:tick:l:2", "r:tick:l:3"]),
])
def test_tick_classifier_bounds(classifier_id, ticks, hits):
    assert tick_hits(classifier_id, ticks) == hits
