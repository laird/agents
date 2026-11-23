"""landing-timings.py (writer) and landing-report.py (waste-first report, history mode)."""

from __future__ import annotations

import json
import os
import re
import stat
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pytest

SCRIPTS = Path(__file__).resolve().parent.parent / "plugins" / "autocoder" / "scripts"
WRITER = SCRIPTS / "landing-timings.py"
REPORT = SCRIPTS / "landing-report.py"


def write(log, *args):
    env = {k: v for k, v in os.environ.items() if k != "AUTOCODER_LANDING_REPO"}
    return subprocess.run([sys.executable, str(WRITER), "--log-path", str(log), *args], capture_output=True, text=True, env=env)


def report(*args, env=None, cwd=None):
    # Run outside this checkout: the report resolves a landed row's commit from the current directory's git log
    # when the row carries none, and this repository's own history must not stand in for a fixture's.
    e = {**os.environ, **(env or {})}
    r = subprocess.run([sys.executable, str(REPORT), *args], capture_output=True, text=True, env=e, cwd=cwd or tempfile.gettempdir())
    return r


def rows_of(path):
    return [json.loads(x) for x in Path(path).read_text().splitlines()]


# ── writer ──────────────────────────────────────────────────────────────────
def test_writer_rows_and_nulls_not_zeros(tmp_path):
    log = tmp_path / "l.jsonl"
    assert write(log, "change", "--issue", "7", "--event", "ready", "--ts", "2026-11-01T10:00:00Z").returncode == 0
    assert write(log, "batch", "--batch", "b1", "--members", "7,8", "--stage", "build=10", "--stage", "test=20.5",
                 "--verdict", "green").returncode == 0
    ch, ba = rows_of(log)
    assert ch == {"v": 1, "ts": "2026-11-01T10:00:00Z", "kind": "change", "issue": 7, "event": "ready", "batch": None, "cause": None, "repo": None}
    assert ba["gate_s"] == 30.5 and ba["stages"] == {"build": 10.0, "test": 20.5} and ba["members"] == [7, 8]
    assert ba["assembly_s"] is None and ba["discarded_gate_s"] is None and ba["push_rejected"] is None
    assert write(log, "plan", "--issue", "7", "--verdict", "skip", "--seconds", "12.5", "--ts", "2026-11-01T10:05:00Z").returncode == 0
    assert rows_of(log)[2] == {"v": 1, "ts": "2026-11-01T10:05:00Z", "kind": "plan", "issue": 7, "verdict": "skip", "seconds": 12.5, "batch": None, "repo": None}


@pytest.mark.parametrize("args,needle", [
    (["change", "--issue", "1", "--event", "returned"], "needs --cause"),
    (["change", "--issue", "1", "--event", "ready", "--cause", "defect"], "belongs to --event returned"),
    (["change", "--issue", "1", "--event", "ready", "--batch", "has space"], "not an id"),
    (["change", "--issue", "1", "--event", "ready", "--ts", "yesterday"], "--ts"),
    (["batch", "--batch", "b", "--members", "1", "--verdict", "red"], "needs --cause"),
    (["batch", "--batch", "b", "--members", ",", "--verdict", "green"], "names no change"),
    (["batch", "--batch", "b", "--members", "1", "--stage", "build"], "NAME=SECONDS"),
    (["batch", "--batch", "b", "--members", "1", "--gate-s", "-3"], "negative"),
    (["plan", "--issue", "1", "--verdict", "maybe", "--seconds", "1"], "invalid choice"),
    (["plan", "--issue", "1", "--verdict", "train", "--seconds", "-1"], "negative"),
])
def test_writer_refuses_bad_input_and_writes_nothing(tmp_path, args, needle):
    log = tmp_path / "l.jsonl"
    r = write(log, *args)
    assert r.returncode == 2 and needle in r.stderr
    assert not log.exists()


def test_writer_concurrent_appends_stay_whole_lines(tmp_path):
    log = tmp_path / "l.jsonl"
    with ThreadPoolExecutor(16) as ex:
        list(ex.map(lambda n: write(log, "change", "--issue", str(n), "--event", "claimed"), range(40)))
    assert sorted(r["issue"] for r in rows_of(log)) == list(range(40))


def test_shell_lib_is_best_effort(tmp_path):
    env = {**os.environ, "AUTOCODER_LANDING_TIMINGS": str(tmp_path / "l.jsonl")}
    script = f'source "{SCRIPTS}/landing-timings-lib.sh"; landing_change 3 landed --batch b; landing_change 4 returned; ' \
             f'landing_batch --batch b --members 3 --verdict green; echo done'
    r = subprocess.run(["bash", "-c", script], capture_output=True, text=True, env=env)
    assert r.returncode == 0 and r.stdout.strip() == "done" and r.stderr == ""
    assert [x["kind"] for x in rows_of(tmp_path / "l.jsonl")] == ["change", "batch"]  # the bad call wrote nothing


# ── report ──────────────────────────────────────────────────────────────────
def ch(issue, ts, event, cause=None, batch=None):
    return {"v": 1, "ts": ts, "kind": "change", "issue": issue, "event": event, "batch": batch, "cause": cause}


def ba(bid, ts, members, gate_s, verdict, cause=None, discarded=None, push_rejected=0, resyncs=0, stages=None):
    return {"v": 1, "ts": ts, "kind": "batch", "batch": bid, "members": members, "assembly_s": 60, "stages": stages or {},
            "gate_s": gate_s, "discarded_gate_s": discarded, "publish_s": 30, "verdict": verdict, "cause": cause,
            "resyncs": resyncs, "push_rejected": push_rejected}


def pl(issue, ts, verdict, seconds):
    return {"v": 1, "ts": ts, "kind": "plan", "issue": issue, "verdict": verdict, "seconds": seconds, "batch": None}


FIXTURE = [
    ch(1, "2026-11-02T08:00:00Z", "claimed"), ch(1, "2026-11-02T10:00:00Z", "ready"),
    ch(1, "2026-11-02T10:30:00Z", "batched", batch="b1"), ch(1, "2026-11-02T11:00:00Z", "returned", cause="defect", batch="b1"),
    ch(1, "2026-11-02T12:00:00Z", "ready"), ch(1, "2026-11-02T12:20:00Z", "batched", batch="b2"),
    ch(1, "2026-11-02T13:00:00Z", "landed", batch="b2"),
    ch(2, "2026-11-02T09:00:00Z", "claimed"), ch(2, "2026-11-02T09:30:00Z", "ready"),
    ch(2, "2026-11-02T10:30:00Z", "batched", batch="b1"), ch(2, "2026-11-02T11:00:00Z", "returned", cause="stale-base", batch="b1"),
    ch(2, "2026-11-02T12:20:00Z", "batched", batch="b2"), ch(2, "2026-11-02T13:00:00Z", "landed", batch="b2"),
    ch(2, "2026-11-02T09:40:00Z", "rebase"), ch(2, "2026-11-02T11:30:00Z", "rebase"), ch(2, "2026-11-02T11:35:00Z", "precheck"),
    ch(3, "2026-11-03T09:00:00Z", "ready"), ch(3, "2026-11-03T09:10:00Z", "batched", batch="b3"),
    ch(3, "2026-11-03T10:00:00Z", "landed", batch="b3"),
    ba("b1", "2026-11-02T11:00:00Z", [1, 2], 1800, "red", "defect", push_rejected=1, resyncs=1, stages={"build": 600, "test": 1200}),
    ba("b2", "2026-11-02T13:00:00Z", [1, 2], 2400, "green", discarded=600, resyncs=1),
    ba("b3", "2026-11-03T10:00:00Z", [3], 1800, "green"),
    pl(1, "2026-11-02T10:20:00Z", "train", 120), pl(2, "2026-11-02T10:21:00Z", "skip", 30), pl(3, "2026-11-03T09:05:00Z", "train", 60),
]


@pytest.fixture
def log(tmp_path):
    p = tmp_path / "l.jsonl"
    p.write_text("".join(json.dumps(r) + "\n" for r in FIXTURE) + "not json\n")
    return p


def test_report_waste_first_numbers(log):
    r = report("--log", str(log), "--json")
    assert r.returncode == 0 and "skipped 1 unreadable" in r.stderr
    a = json.loads(r.stdout)
    w = a["waste"]
    assert w["gate_s_total"] == 6000 and w["gate_s_wasted"] == 2400  # red b1 (1800) + b2's discarded 600
    assert w["by"] == {"red:defect": 1800, "re-gate after re-sync": 600}
    assert (w["changes_seen"], w["changes_returned"], w["useful_returned"]) == (3, 2, 1)
    assert w["returned_by_cause"] == {"defect": 1, "stale-base": 1}
    assert w["rebases_per_change"]["max"] == 2 and w["prechecks_per_change"]["max"] == 1
    b = a["batches"]
    assert b["size_distribution"] == {"1": 1, "2": 2} and b["push_rejected"] == 1 and b["resyncs"] == 2
    assert b["red_by_cause"] == {"defect": 1} and b["stage_s_total"] == {"build": 600, "test": 1200}
    p = a["planning"]
    assert (p["candidates"], p["s_total"], p["per_candidate_s"]["max"]) == (3, 210, 120)
    assert p["by_verdict"] == {"train": {"n": 2, "s": 180}, "skip": {"n": 1, "s": 30}}


def test_report_timings_and_capacity(log):
    a = json.loads(report("--log", str(log), "--json", "--bucket", "day").stdout)
    # build (claim to first READY): issue 1 2h, issue 2 30m, so p50 is 75m
    assert a["timings"]["build_s"]["p50"] == 4500
    # cycle (last READY to landed): issue 1 1h, issue 2 3.5h (its one READY 09:30), issue 3 50m
    assert a["timings"]["cycle_s"]["max"] == 12600 and a["timings"]["cycle_s"]["n"] == 3
    assert a["timings"]["wait_s"]["n"] == 3
    d = a["buckets"]
    assert d["2026-11-02"]["ready"] == 3 and d["2026-11-02"]["landed"] == 2 and d["2026-11-03"]["landed"] == 1
    assert d["2026-11-02"]["wasted_s"] == 2400 and d["2026-11-02"]["batches"] == 2
    assert d["2026-11-02"]["plan_s"] == 150 and d["2026-11-03"]["plan_s"] == 60


def test_report_window_and_text(log):
    out = report("--log", str(log), "--since", "2026-11-03").stdout
    assert "Gate-minutes thrown away: 0s of 30.0m = 0%" in out
    assert "Planning (candidate probes): 60s over 1 candidates" in out and "| planning |" in out
    assert out.index("## Waste") < out.index("## Time") < out.index("## Capacity")


def test_report_says_na_never_zero_when_not_measured(tmp_path):
    p = tmp_path / "l.jsonl"
    p.write_text(json.dumps(ch(9, "2026-11-01T00:00:00Z", "landed")) + "\n")
    out = report("--log", str(p)).stdout
    assert "Gate-minutes thrown away: n/a" in out and "Rebases per landed change: n/a" in out
    assert "Build (claim to READY): n/a" in out and "Planning (candidate probes): n/a" in out


def test_report_bad_date_exits_2(log):
    r = report("--log", str(log), "--since", "last tuesday")
    assert r.returncode == 2 and "cannot read --since" in r.stderr


# ── week mode (the weekly report) ───────────────────────────────────────────
def load_module():
    import importlib.util
    spec = importlib.util.spec_from_file_location("landing_report", REPORT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def test_week_window_is_monday_to_monday_and_last_is_the_completed_week():
    from datetime import datetime, timezone
    m = load_module()
    iso = lambda d: d.strftime("%Y-%m-%dT%H:%M:%SZ")
    since, until = m.week_window("2026-11-19")                       # a Thursday
    assert (iso(since), iso(until)) == ("2026-11-16T00:00:00Z", "2026-11-23T00:00:00Z")
    since, until = m.week_window("2026-11-16T23:59:00Z")             # the Monday itself, late
    assert (iso(since), iso(until)) == ("2026-11-16T00:00:00Z", "2026-11-23T00:00:00Z")
    monday_run = datetime(2026, 11, 23, 6, 17, tzinfo=timezone.utc)   # a Monday 06:17Z run reports the week that just ended
    since, until = m.week_window("last", today=monday_run)
    assert (iso(since), iso(until)) == ("2026-11-16T00:00:00Z", "2026-11-23T00:00:00Z")
    since, until = m.week_window(None, today=datetime(2026, 11, 29, tzinfo=timezone.utc))  # a Sunday: still the last COMPLETED week
    assert iso(since) == "2026-11-16T00:00:00Z"
    assert m.week_window("not a date") is None


def test_week_report_numbers_batches_and_regates(log):
    r = report("--log", str(log), "--week", "2026-11-04", "--json")   # the week of Mon 2026-11-02 holds the whole fixture
    assert r.returncode == 0, r.stderr
    a = json.loads(r.stdout)
    assert a["week"] == "2026-11-02" and a["window"] == {"since": "2026-11-02T00:00:00Z", "until": "2026-11-09T00:00:00Z"}
    rows = {b["batch"]: b for b in a["batch_rows"]}
    assert [b["batch"] for b in a["batch_rows"]] == ["b1", "b2", "b3"]              # time order
    assert rows["b1"]["landed"] == [] and rows["b1"]["returned"] == {"1": "defect", "2": "stale-base"} and rows["b1"]["open"] == []
    assert rows["b2"]["landed"] == [1, 2] and rows["b2"]["returned"] == {} and rows["b3"]["landed"] == [3]
    # b2 gates again the members red b1 gated: a re-gate of red:defect, its 2400 s of gate time; b3 is not
    assert rows["b1"]["regate_of"] is None and rows["b2"]["regate_of"] == "red:defect" and rows["b3"]["regate_of"] is None
    assert a["regates"] == {"count": 1, "gate_s": 2400, "by": {"red:defect": {"n": 1, "s": 2400, "unmeasured": 0}}}


def test_week_report_markdown_leads_with_the_week_and_lists_every_batch(log):
    out = report("--log", str(log), "--week", "2026-11-02").stdout
    assert out.startswith("# Landing report: week of 2026-11-02\n")
    assert out.index("## Week in numbers") < out.index("## Batches") < out.index("## Waste") < out.index("## Time")
    assert "- Batches: 3; members: 5 (1.7 per batch); sizes 1: 1, 2: 2" in out
    assert "- Changes landed: 3; returned: 2 (useful, a defect in the change: 1; waste: 1); by cause defect 1, stale-base 1; dropped at planning: 0" in out
    assert "- Gate-minutes: 1.7h in 3 measured batches; wasted 40.0m (40%); by cause red:defect 30.0m, re-gate after re-sync 10.0m" in out
    assert "- Median READY to landed: 60.0m (p90 " in out
    assert "- Planning: 3.5m over 3 candidate probes" in out
    assert "- Re-gates: 1 batches, 40.0m of gate time; by reason red:defect 1 (40.0m)" in out
    assert "| b1 | 2026-11-02T11:00:00Z | #1 #2 | red:defect | 30.0m | - | #1 (defect) #2 (stale-base) | - | - |" in out
    assert "| b2 | 2026-11-02T13:00:00Z | #1 #2 | green | 40.0m | #1 #2 | - | - | red:defect |" in out
    assert "- Re-gates by reason: red:defect: 1 (40.0m)" in out            # the general section carries it too


def test_week_report_with_no_batch_says_so_and_na(tmp_path):
    p = tmp_path / "l.jsonl"
    p.write_text(json.dumps(ch(9, "2026-11-04T00:00:00Z", "landed")) + "\n")
    out = report("--log", str(p), "--week", "2026-11-04").stdout
    assert "- Batches: 0; members: 0; sizes n/a" in out and "- Gate-minutes: n/a" in out
    assert "- Median READY to landed: n/a" in out and "- Re-gates: 0" in out and "(no batch in the window)" in out


def test_batches_flag_lists_batches_for_any_window_and_a_member_with_no_outcome_is_open(tmp_path):
    p = tmp_path / "l.jsonl"
    rows = [ch(4, "2026-11-05T09:00:00Z", "batched", batch="b4"), ba("b4", "2026-11-05T09:30:00Z", [4, 5], 600, "infra", "infra")]
    p.write_text("".join(json.dumps(r) + "\n" for r in rows))
    out = report("--log", str(p), "--since", "2026-11-05", "--batches").stdout
    assert out.startswith("# Landing report\n") and "## Week in numbers" not in out
    assert "| b4 | 2026-11-05T09:30:00Z | #4 #5 | infra:infra | 10.0m | - | - | #4 #5 | - |" in out


def test_an_outcome_in_the_same_second_as_the_next_batched_row_belongs_to_the_batch_it_ends(tmp_path):
    p = tmp_path / "l.jsonl"
    rows = [ch(4, "2026-11-05T09:00:00Z", "batched", batch="b4"), ba("b4", "2026-11-05T09:30:00Z", [4], 600, "green"),
            ch(4, "2026-11-05T09:40:00Z", "landed", batch="b4"), ch(4, "2026-11-05T09:40:00Z", "batched", batch="b5"),
            ba("b5", "2026-11-05T10:00:00Z", [4], 600, "green")]
    p.write_text("".join(json.dumps(r) + "\n" for r in rows))
    a = json.loads(report("--log", str(p), "--json").stdout)
    assert [(b["batch"], b["landed"], b["open"]) for b in a["batch_rows"]] == [("b4", [4], []), ("b5", [], [4])]


def test_a_gate_row_and_a_train_row_with_one_batch_id_count_once(tmp_path):
    # merge-to-integration.sh under AUTOCODER_LANDING_BATCH writes the seconds it measured; the train writes
    # the verdict it judged: one batch, the train's verdict, the gate's seconds and re-syncs, the members unioned
    p = tmp_path / "l.jsonl"
    rows = [ba("t1", "2026-11-05T09:30:00Z", [4], 600, "red", "defect", discarded=120, resyncs=2, stages={"build": 100}),
            {"v": 1, "ts": "2026-11-05T09:31:00Z", "kind": "batch", "batch": "t1", "members": [4, 5], "assembly_s": None, "stages": {},
             "gate_s": 601, "discarded_gate_s": None, "publish_s": None, "verdict": "infra", "cause": "infra", "resyncs": None, "push_rejected": None}]
    p.write_text("".join(json.dumps(r) + "\n" for r in rows))
    a = json.loads(report("--log", str(p), "--json").stdout)
    assert a["batches"]["count"] == 1 and a["batches"]["size_distribution"] == {"2": 1}
    b = a["batch_rows"][0]
    assert (b["members"], b["verdict"], b["cause"], b["gate_s"]) == ([4, 5], "infra", "infra", 601)
    assert a["waste"]["gate_s_total"] == 601 and a["waste"]["by"] == {"infra:infra": 601}
    assert a["batches"]["resyncs"] == 2 and a["batches"]["stage_s_total"] == {"build": 100}


@pytest.mark.parametrize("args,needle", [
    (["--week", "sometime"], "cannot read --week"),
    (["--week", "2026-11-02", "--since", "2026-11-01"], "drop --since/--until"),
])
def test_week_refuses_a_bad_spec_or_a_second_window(log, args, needle):
    r = report("--log", str(log), *args)
    assert r.returncode == 2 and needle in r.stderr


# ── the self-improvement loop on the week page (#395) ────────────────────────
TRACE_FIXTURES = Path(__file__).resolve().parent / "fixtures" / "traces"   # events dated 2026-11-20: the week of Mon 2026-11-16
LOOP_LEDGERS = ["--log", str(TRACE_FIXTURES / "landing-timings.jsonl"), "--issue-events", str(TRACE_FIXTURES / "issue-events.jsonl"),
                "--merge-events", str(TRACE_FIXTURES / "merge-events.jsonl"), "--week", "2026-11-20", "--ci", "off"]


def loop_env(tmp_path, **extra):
    return {"XDG_STATE_HOME": str(tmp_path), "AUTOCODER_LOG_DIR": str(TRACE_FIXTURES), **extra}


def jsonl(path, rows):
    path.write_text("".join(json.dumps(r) + "\n" for r in rows))
    return path


def result(ts, split, case, passed):
    return {"ts": ts, "case": case, "split": split, "repeat": 1, "pass": passed, "failed": [], "outcome": "landed", "gates": 1,
            "tool_calls": 10, "duration_s": 60, "worker": "fake", "harness": {"sha": "aaaa1111"}, "root": None}


def decision(ts, finding, verdict):
    return {"ts": ts, "finding": finding, "before": "aaaa1111", "after": "bbbb2222", "dev": {"before": [1, 2], "after": [2, 2]},
            "heldout": {"before": [1, 2], "after": [2, 2]}, "decision": verdict, "accepted": verdict == "accept", "reason": "r"}


def loop_line(out, name):
    return next(x for x in out.splitlines() if x.startswith(f"  - {name}: "))


def test_week_page_findings_are_the_analysts_over_the_weeks_traces(tmp_path):
    r = report(*LOOP_LEDGERS, "--eval-results", str(tmp_path / "none.jsonl"), env=loop_env(tmp_path))
    assert r.returncode == 0, r.stderr
    out = r.stdout
    assert out.index("## Week in numbers") < out.index("- Self-improvement loop:") < out.index("## Batches")
    # the analyst run by hand over the same ledgers and week
    traces = tmp_path / "traces.jsonl"
    subprocess.run([sys.executable, str(SCRIPTS / "trace-build.py"), "--landing-timings", str(TRACE_FIXTURES / "landing-timings.jsonl"),
                    "--issue-events", str(TRACE_FIXTURES / "issue-events.jsonl"), "--merge-events", str(TRACE_FIXTURES / "merge-events.jsonl"),
                    "--out", str(traces), "--since", "2026-11-16", "--until", "2026-11-23"],
                   check=True, capture_output=True, env={**os.environ, **loop_env(tmp_path)})
    analyst = json.loads(subprocess.run([sys.executable, str(SCRIPTS / "analyze-traces.py"), "--traces", str(traces), "--json"],
                                        check=True, capture_output=True, text=True).stdout)
    findings = analyst["findings"]
    assert len(findings) >= 3
    covered = len({t for f in findings for t in f["traces"]})
    top = "; ".join(f"{f['id']}: {f['key']}, {f['count']}" if f["key"] is not None else f"{f['id']}, {f['count']}" for f in findings[:3])
    assert loop_line(out, "Findings") == f"  - Findings: {len(findings)} classes covering {covered} of {analyst['corpus']} traces; top {top}"
    loop = json.loads(report(*LOOP_LEDGERS, "--json", "--eval-results", str(tmp_path / "none.jsonl"), env=loop_env(tmp_path)).stdout)["loop"]
    assert loop["findings"] == {"classes": len(findings), "traces": covered, "corpus": analyst["corpus"],
                                "top": [{"id": f["id"], "key": f["key"], "count": f["count"]} for f in findings[:3]]}


def test_week_page_counts_the_weeks_eval_runs_and_decisions_and_nothing_outside_it(tmp_path):
    results = jsonl(tmp_path / "results.jsonl", [
        result("2026-11-17T10:00:00Z", "dev", "c1", True), result("2026-11-17T11:00:00Z", "dev", "c1", False),
        result("2026-11-18T10:00:00Z", "dev", "c2", True),
        result("2026-11-19T10:00:00Z", "heldout", "h1", True), result("2026-11-19T11:00:00Z", "heldout", "h1", False),
        result("2026-11-15T23:59:59Z", "dev", "c3", True), result("2026-11-23T00:00:00Z", "heldout", "h2", True)])   # the weeks either side
    decisions = jsonl(tmp_path / "decisions.jsonl", [
        decision("2026-11-18T12:00:00Z", "gate-red-suite:tests/test_x.sh", "accept"),
        decision("2026-11-19T12:00:00Z", "gate-red-suite:tests/test_x.sh", "accept"),
        decision("2026-11-19T13:00:00Z", "reclaimed", "reject"),
        decision("2026-11-20T13:00:00Z", "verdict-nudged", "inconclusive"),
        decision("2026-11-24T13:00:00Z", "red-base", "reject")])                                                       # the next week
    args = [*LOOP_LEDGERS, "--eval-results", str(results), "--eval-decisions", str(decisions)]
    out = report(*args, env=loop_env(tmp_path)).stdout
    assert loop_line(out, "Evals") == "  - Evals: dev 2/3 passing over 2 cases; held-out 1/2 passing over 1 case"
    assert loop_line(out, "Changes") == "  - Changes: accepted 2 (gate-red-suite:tests/test_x.sh); rejected 1 (reclaimed); inconclusive 1 (verdict-nudged)"
    loop = json.loads(report(*args, "--json", env=loop_env(tmp_path)).stdout)["loop"]
    assert loop["evals"] == {"dev": {"passes": 2, "runs": 3, "cases": 2}, "heldout": {"passes": 1, "runs": 2, "cases": 1}}
    assert loop["changes"] == {"accept": {"n": 2, "findings": ["gate-red-suite:tests/test_x.sh"]},
                               "reject": {"n": 1, "findings": ["reclaimed"]}, "inconclusive": {"n": 1, "findings": ["verdict-nudged"]}}


def test_week_page_reads_the_eval_files_from_the_writers_environment(tmp_path):
    results = jsonl(tmp_path / "r.jsonl", [result("2026-11-17T10:00:00Z", "heldout", "h1", True)])
    decisions = jsonl(tmp_path / "d.jsonl", [{"ts": "2026-11-17T12:00:00Z", "finding": "reclaimed", "accepted": False}])   # the spec's row, no `decision`
    out = report(*LOOP_LEDGERS, env=loop_env(tmp_path, AUTOCODER_EVAL_RESULTS=str(results), AUTOCODER_EVAL_DECISIONS=str(decisions))).stdout
    assert loop_line(out, "Evals") == "  - Evals: dev n/a; held-out 1/1 passing over 1 case"
    assert loop_line(out, "Changes") == "  - Changes: accepted 0; rejected 1 (reclaimed); inconclusive 0"


def test_week_page_says_na_never_zero_for_a_missing_file_or_an_empty_week(tmp_path):
    out = report(*LOOP_LEDGERS, "--eval-results", str(tmp_path / "none.jsonl"), "--eval-decisions", str(tmp_path / "none2.jsonl"),
                 env=loop_env(tmp_path)).stdout
    assert loop_line(out, "Evals") == "  - Evals: n/a (no eval results file)"
    assert loop_line(out, "Changes") == "  - Changes: n/a (no eval decisions file)"
    old = jsonl(tmp_path / "old.jsonl", [result("2026-11-01T10:00:00Z", "dev", "c1", True)])
    out = report(*LOOP_LEDGERS, "--eval-results", str(old), env=loop_env(tmp_path)).stdout
    assert loop_line(out, "Evals") == "  - Evals: n/a (no eval run in the week)"


def test_week_page_loop_off_drops_the_block(tmp_path):
    r = report(*LOOP_LEDGERS, "--loop", "off", env=loop_env(tmp_path))
    assert r.returncode == 0 and "Self-improvement loop" not in r.stdout
    assert "loop" not in json.loads(report(*LOOP_LEDGERS, "--loop", "off", "--json", env=loop_env(tmp_path)).stdout)


def test_week_page_without_the_trace_tooling_says_so(tmp_path):
    alone = tmp_path / "scripts" / "landing-report.py"         # the report installed without its sibling scripts
    alone.parent.mkdir()
    alone.write_bytes(REPORT.read_bytes())
    r = subprocess.run([sys.executable, str(alone), *LOOP_LEDGERS], capture_output=True, text=True,
                       env={**os.environ, **loop_env(tmp_path)}, cwd=tempfile.gettempdir())
    assert r.returncode == 0, r.stderr
    assert loop_line(r.stdout, "Findings") == "  - Findings: n/a (trace tooling not installed)"


# ── history mode ────────────────────────────────────────────────────────────
def git(cwd, *a, env=None):
    e = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@e.x", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@e.x", **(env or {})}
    return subprocess.run(["git", *a], cwd=cwd, check=True, capture_output=True, text=True, env=e).stdout


@pytest.fixture
def history_env(tmp_path):
    repo = tmp_path / "repo"
    repo.mkdir()
    git(repo, "init", "-q", "-b", "master")
    d = lambda day: {"GIT_COMMITTER_DATE": f"2026-11-{day}T12:00:00Z", "GIT_AUTHOR_DATE": f"2026-11-{day}T12:00:00Z"}
    (repo / "a").write_text("1"); git(repo, "add", "-A"); git(repo, "commit", "-qm", "init", env=d("01"))
    (repo / "b").write_text("1"); git(repo, "add", "-A"); git(repo, "commit", "-qm", "#11: solo landing", env=d("02"))
    git(repo, "checkout", "-q", "master")
    for n in (12, 13):
        git(repo, "checkout", "-qb", f"feature/{n}", "master")
        (repo / f"f{n}").write_text("x"); git(repo, "add", "-A"); git(repo, "commit", "-qm", f"fix {n}", env=d("03"))
        git(repo, "checkout", "-q", "master")
        git(repo, "merge", "--no-ff", "-qm", f"train/T20261103: #{n} feature/{n} @ abc", f"feature/{n}", env=d("03"))
    git(repo, "merge", "--no-ff", "-qm", "Merge origin/master into train/T20261103", "feature/12", env=d("03"))
    (repo / "m").write_text("x"); git(repo, "add", "-A"); git(repo, "commit", "-qm", "#99: regenerated (mechanical)", env=d("03"))

    fake = tmp_path / "bin"
    fake.mkdir()
    gh = fake / "gh"
    gh.write_text('''#!/bin/bash
case "$1 $2" in
 "issue list") echo '[{"number":12,"title":"a","body":"","labels":[],"state":"CLOSED"}]';;
 "issue view") echo '{"number":12,"title":"a","body":"","labels":[],"state":"CLOSED","comments":[
   {"createdAt":"2026-11-02T08:00:00Z","body":"[swarm] claimed for w1"},
   {"createdAt":"2026-11-02T10:00:00Z","body":"READY: branch `x`"},
   {"createdAt":"2026-11-02T20:00:00Z","body":"train dropped this branch: it has a merge conflict"},
   {"createdAt":"2026-11-03T08:00:00Z","body":"READY again"},
   {"createdAt":"2026-11-03T08:30:00Z","body":"just chatting"}]}';;
 *) exit 1;;
esac
''')
    gh.chmod(gh.stat().st_mode | stat.S_IXUSR)
    me = tmp_path / "merge-events.jsonl"
    me.write_text("\n".join(json.dumps(e) for e in [
        {"ts": "2026-11-02T15:00:00Z", "event": "attempt", "issue": 12, "attempt": 1, "outcome": "gate-failed", "duration_s": 900, "push_retries": 0},
        {"ts": "2026-11-02T16:00:00Z", "event": "attempt", "issue": 12, "attempt": 2, "outcome": "conflict", "duration_s": 5},
        {"ts": "2026-11-02T17:00:00Z", "event": "push-retry", "issue": 12},
    ]) + "\n")
    env = {"PATH": f"{fake}:{os.environ['PATH']}", "ISSUE_SOURCE": "github"}
    return repo, me, env


def test_history_reconstructs_rows_from_tracker_git_and_merge_events(tmp_path, history_env):
    repo, me, env = history_env
    out = tmp_path / "rows.jsonl"
    r = report("--history", "--repo", str(repo), "--log", str(tmp_path / "none.jsonl"), "--merge-events", str(me),
               "--export-rows", str(out), "--json", env=env)
    assert r.returncode == 0, r.stderr
    rows = rows_of(out)
    ev = [(x["issue"], x["event"], x["cause"]) for x in rows if x["kind"] == "change" and x["issue"] == 12]
    assert (12, "claimed", None) in ev and ev.count((12, "ready", None)) == 2
    assert (12, "returned", "conflict") in ev          # the tracker comment, classified
    assert (12, "returned", "defect") in ev            # the gate-failed attempt
    assert (12, "landed", None) in ev                  # the train merge
    batches = {tuple(x["members"]) for x in rows if x["kind"] == "batch"}
    assert (11,) in batches and (12, 13) in batches    # solo landing; ONE train batch with both members
    assert not any(99 in x["members"] for x in rows if x["kind"] == "batch")  # mechanical commit skipped
    attempt = next(x for x in rows if x["kind"] == "batch" and x["gate_s"] == 900)
    assert attempt["verdict"] == "red" and attempt["cause"] == "defect"
    a = json.loads(r.stdout)
    assert a["waste"]["returned_by_cause"].keys() == {"conflict", "defect"}
    assert a["waste"]["gate_s_wasted"] == 900


def test_history_only_covers_the_time_before_the_writer(tmp_path, history_env):
    repo, me, env = history_env
    log = tmp_path / "l.jsonl"
    log.write_text(json.dumps(ch(12, "2026-11-03T00:00:00Z", "ready")) + "\n")  # writer began 11-03
    out = tmp_path / "rows.jsonl"
    report("--history", "--repo", str(repo), "--log", str(log), "--merge-events", str(me), "--export-rows", str(out), env=env)
    assert all(x["ts"] < "2026-11-03T00:00:00Z" for x in rows_of(out))


def test_history_failure_is_loud(tmp_path):
    repo = tmp_path / "empty"
    repo.mkdir()
    r = report("--history", "--repo", str(repo), "--log", str(tmp_path / "none.jsonl"), env={"ISSUE_SOURCE": "github", "PATH": "/usr/bin:/bin"})
    assert r.returncode == 3 and "history mode failed" in r.stderr


# ── one repository per report ───────────────────────────────────────────────
def repo_id_of(d):
    return subprocess.run(["bash", "-c", f'source "{SCRIPTS / "repo-id-fns.sh"}" && autocoder_repo_id "$1"', "_", str(d)],
                          capture_output=True, text=True, check=True).stdout.strip()


def test_writer_names_the_repository_from_the_flag_or_the_environment_and_null_without(tmp_path):
    log = tmp_path / "l.jsonl"
    env = {k: v for k, v in os.environ.items() if k != "AUTOCODER_LANDING_REPO"}
    assert subprocess.run([sys.executable, str(WRITER), "--log-path", str(log), "--repo", "agents-0123abcd", "change", "--issue", "1", "--event", "ready"],
                          capture_output=True, text=True, env=env).returncode == 0
    assert subprocess.run([sys.executable, str(WRITER), "--log-path", str(log), "batch", "--batch", "b1", "--members", "1"],
                          capture_output=True, text=True, env={**env, "AUTOCODER_LANDING_REPO": "worker-9baf1db6"}).returncode == 0
    assert subprocess.run([sys.executable, str(WRITER), "--log-path", str(log), "plan", "--issue", "1", "--verdict", "train", "--seconds", "1"],
                          capture_output=True, text=True, env=env).returncode == 0
    assert [r["repo"] for r in rows_of(log)] == ["agents-0123abcd", "worker-9baf1db6", None]
    r = subprocess.run([sys.executable, str(WRITER), "--log-path", str(log), "--repo", "not an id", "change", "--issue", "1", "--event", "ready"],
                       capture_output=True, text=True, env=env)
    assert r.returncode == 2 and "--repo" in r.stderr and len(rows_of(log)) == 3


def two_repo_log(tmp_path, mine):
    """A week of one repository (`mine`: a green batch of one, landed) beside a test run's fixture rows of
    another (a red batch of 1 s and a returned change, the shape that once counted on a real week page)
    and one row written before the field existed."""
    p = tmp_path / "l.jsonl"
    rows = [
        {"v": 1, "ts": "2026-11-18T10:00:00Z", "kind": "change", "issue": 10, "event": "ready", "batch": None, "cause": None, "repo": mine},
        {"v": 1, "ts": "2026-11-18T11:00:00Z", "kind": "change", "issue": 10, "event": "batched", "batch": "b1", "cause": None, "repo": mine},
        {"v": 1, "ts": "2026-11-18T11:30:00Z", "kind": "batch", "batch": "b1", "members": [10], "assembly_s": None, "stages": {}, "gate_s": 1800.0,
         "discarded_gate_s": None, "publish_s": None, "verdict": "green", "cause": None, "resyncs": 0, "push_rejected": 0, "repo": mine},
        {"v": 1, "ts": "2026-11-18T11:30:00Z", "kind": "change", "issue": 10, "event": "landed", "batch": "b1", "cause": None, "repo": mine},
        {"v": 1, "ts": "2026-11-18T12:00:00Z", "kind": "change", "issue": 11, "event": "landed", "batch": None, "cause": None},   # before the field
        {"v": 1, "ts": "2026-11-19T03:28:59Z", "kind": "batch", "batch": "solo-19301-1-1", "members": [19301], "assembly_s": None, "stages": {}, "gate_s": 1.0,
         "discarded_gate_s": 0.0, "publish_s": None, "verdict": "red", "cause": "red-integration", "resyncs": 0, "push_rejected": 0, "repo": "worker-9baf1db6"},
        {"v": 1, "ts": "2026-11-19T03:28:59Z", "kind": "change", "issue": 19301, "event": "batched", "batch": "solo-19301-1-1", "cause": None, "repo": "worker-9baf1db6"},
        {"v": 1, "ts": "2026-11-19T03:29:00Z", "kind": "change", "issue": 19301, "event": "returned", "batch": None, "cause": "other", "repo": "worker-9baf1db6"},
    ]
    p.write_text("".join(json.dumps(r) + "\n" for r in rows))
    return p


def test_report_keeps_one_repositorys_rows_and_names_the_rows_it_ignored(tmp_path):
    log = two_repo_log(tmp_path, "agents-0123abcd")
    r = report("--log", str(log), "--week", "2026-11-18", "--json", "--repo-id", "agents-0123abcd")
    assert r.returncode == 0, r.stderr
    a = json.loads(r.stdout)
    assert a["batches"]["count"] == 1 and a["landed"] == 2 and a["waste"]["returned_by_cause"] == {}
    assert a["waste"]["gate_s_wasted"] == 0
    assert "ignored 3 row(s) of other repositories (worker-9baf1db6 3); reporting agents-0123abcd" in r.stderr
    # --all-repos keeps them: the fixture batch and its return count again
    r = report("--log", str(log), "--week", "2026-11-18", "--json", "--all-repos")
    a = json.loads(r.stdout)
    assert a["batches"]["count"] == 2 and a["waste"]["returned_by_cause"] == {"other": 1} and "ignored" not in r.stderr
    # the two flags contradict each other
    r = report("--log", str(log), "--repo-id", "agents-0123abcd", "--all-repos")
    assert r.returncode == 2 and "contradict" in r.stderr


def test_report_derives_the_repository_from_the_directory_when_the_ledger_holds_its_rows(tmp_path):
    repo = tmp_path / "repo"
    repo.mkdir()
    subprocess.run(["git", "init", "-q", str(repo)], check=True)
    mine = repo_id_of(repo)
    log = two_repo_log(tmp_path, mine)
    r = report("--log", str(log), "--json", "--repo", str(repo))
    assert r.returncode == 0 and json.loads(r.stdout)["batches"]["count"] == 1
    assert f"ignored 3 row(s) of other repositories (worker-9baf1db6 3); reporting {mine}" in r.stderr
    # run from inside the repository: the current directory is the default
    r = subprocess.run([sys.executable, str(REPORT), "--log", str(log), "--json"], capture_output=True, text=True, cwd=repo)
    assert r.returncode == 0 and json.loads(r.stdout)["batches"]["count"] == 1 and "ignored 3 row(s)" in r.stderr
    # a ledger holding no row of this repository (a copy read elsewhere) is reported whole, with a notice, never empty
    other = tmp_path / "other"
    other.mkdir()
    subprocess.run(["git", "init", "-q", str(other)], check=True)
    r = report("--log", str(log), "--json", "--repo", str(other))
    assert r.returncode == 0 and json.loads(r.stdout)["batches"]["count"] == 2
    assert f"no row names this repository ({repo_id_of(other)}); the ledger holds rows of {mine}, worker-9baf1db6: reporting every row" in r.stderr


# ── a train's own gate passes are not batches ───────────────────────────────
def train_and_solo_log(tmp_path):
    """One train of two members beside the solo batch its gate wrote under the gate issue (5956) before the gate
    learned the train's id, plus that issue's batched and landed rows: the shape that doubled a week's batches."""
    p = tmp_path / "l.jsonl"
    rows = [
        {"v": 1, "ts": "2026-11-18T10:00:00Z", "kind": "change", "issue": 10, "event": "batched", "batch": "train-1", "cause": None},
        {"v": 1, "ts": "2026-11-18T10:00:00Z", "kind": "change", "issue": 11, "event": "batched", "batch": "train-1", "cause": None},
        {"v": 1, "ts": "2026-11-18T10:20:00Z", "kind": "batch", "batch": "solo-5956-1-1", "members": [5956], "assembly_s": None, "stages": {}, "gate_s": 1200.0,
         "discarded_gate_s": 0.0, "publish_s": None, "verdict": "green", "cause": None, "resyncs": 0, "push_rejected": 0},
        {"v": 1, "ts": "2026-11-18T10:20:00Z", "kind": "change", "issue": 5956, "event": "batched", "batch": "solo-5956-1-1", "cause": None},
        {"v": 1, "ts": "2026-11-18T10:20:00Z", "kind": "change", "issue": 5956, "event": "landed", "batch": "solo-5956-1-1", "cause": None},
        {"v": 1, "ts": "2026-11-18T10:20:30Z", "kind": "batch", "batch": "train-1", "members": [10, 11], "assembly_s": None, "stages": {}, "gate_s": 1230.0,
         "discarded_gate_s": None, "publish_s": None, "verdict": "green", "cause": None, "resyncs": None, "push_rejected": None},
        {"v": 1, "ts": "2026-11-18T10:21:00Z", "kind": "change", "issue": 10, "event": "landed", "batch": "train-1", "cause": None},
        {"v": 1, "ts": "2026-11-18T10:21:00Z", "kind": "change", "issue": 11, "event": "landed", "batch": "train-1", "cause": None},
    ]
    p.write_text("".join(json.dumps(r) + "\n" for r in rows))
    return p


def test_a_trains_own_gate_passes_are_dropped_with_the_gate_issues_rows_and_the_run_says_so(tmp_path):
    log = train_and_solo_log(tmp_path)
    r = report("--log", str(log), "--week", "2026-11-18", "--json", "--train-gate-issue", "5956")
    assert r.returncode == 0, r.stderr
    a = json.loads(r.stdout)
    assert a["batches"]["count"] == 1 and a["landed"] == 2 and a["waste"]["gate_s_total"] == 1230.0
    assert "dropped 1 batch row(s) that were a train's own gate passes (members [5956], the train gate issue) and 2 change/plan row(s)" in r.stderr
    # 0 keeps them (the old numbers: two batches, three landings, both gates' minutes)
    a = json.loads(report("--log", str(log), "--week", "2026-11-18", "--json", "--train-gate-issue", "0").stdout)
    assert a["batches"]["count"] == 2 and a["landed"] == 3 and a["waste"]["gate_s_total"] == 2430.0


def test_the_train_gate_issue_defaults_to_the_repositorys_configured_one(tmp_path):
    repo = tmp_path / "repo"
    repo.mkdir()
    subprocess.run(["git", "init", "-q", str(repo)], check=True)
    (repo / ".autocoder.json").write_text(json.dumps({"train": {"gateIssue": "5956"}}))
    log = train_and_solo_log(tmp_path)
    a = json.loads(report("--log", str(log), "--json", "--repo", str(repo)).stdout)
    assert a["batches"]["count"] == 1 and a["landed"] == 2
    # a linked worktree reads the main worktree's config
    wt = tmp_path / "wt"
    subprocess.run(["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@e.x", "commit", "-q", "--allow-empty", "-m", "seed"], check=True)
    subprocess.run(["git", "-C", str(repo), "worktree", "add", "-q", str(wt)], check=True)
    a = json.loads(subprocess.run([sys.executable, str(REPORT), "--log", str(log), "--json"], capture_output=True, text=True, cwd=wt).stdout)
    assert a["batches"]["count"] == 1
    # no configuration: nothing is dropped
    a = json.loads(report("--log", str(log), "--json", "--repo", str(tmp_path)).stdout)
    assert a["batches"]["count"] == 2


# ── CI verdict per landing (landing to CI verdict; landings before a red verdict) ───────────
SHA_A, SHA_B, SHA_C, SHA_D = "a" * 40, "b" * 40, "c" * 40, "d" * 40


def chs(issue, ts, sha, batch=None):
    return {**ch(issue, ts, "landed", batch=batch), "sha": sha}


def run(rid, status, conclusion, updated, name="tests", branch="master"):
    return {"id": rid, "name": name, "status": status, "conclusion": conclusion, "updated_at": updated, "event": "push", "head_branch": branch}


CI_FIXTURE = [
    chs(1, "2026-11-02T13:00:00Z", SHA_A, batch="b2"), chs(2, "2026-11-02T13:00:00Z", SHA_A, batch="b2"),   # one landing, two members
    chs(3, "2026-11-03T10:00:00Z", SHA_B, batch="b3"),                                                       # CI judges it red 2.5 h later
    chs(5, "2026-11-03T11:00:00Z", SHA_C, batch="b5"), chs(6, "2026-11-03T12:00:00Z", SHA_D, batch="b6"),   # both land before that verdict
    ch(7, "2026-11-03T13:00:00Z", "landed", batch="b7"),                                                      # a row with no commit (older writer)
    ba("b2", "2026-11-02T13:00:00Z", [1, 2], 2400, "green"), ba("b3", "2026-11-03T10:00:00Z", [3], 1800, "green"),
    ba("b5", "2026-11-03T11:00:00Z", [5], 1800, "green"), ba("b6", "2026-11-03T12:00:00Z", [6], 1800, "green"),
    ba("b7", "2026-11-03T13:00:00Z", [7], 1800, "green"),
]
CI_RUNS = {
    SHA_A: [run(101, "completed", "success", "2026-11-02T13:40:00Z"), run(102, "completed", "success", "2026-11-02T14:42:00Z", name="build"),
            run(103, "completed", "cancelled", "2026-11-02T13:05:00Z", name="docs"),      # a superseded run is no verdict
            run(104, "completed", "failure", "2026-11-02T13:30:00Z", branch="feature/x")],  # another branch's run is not this commit's verdict
    SHA_B: [run(201, "completed", "failure", "2026-11-03T12:30:00Z"), run(202, "in_progress", None, "2026-11-03T12:40:00Z", name="build")],
    SHA_C: [run(301, "completed", "success", "2026-11-03T11:30:00Z")],
    SHA_D: [run(401, "in_progress", None, "2026-11-03T12:10:00Z")],
}


def job(name, conclusion, completed, status="completed"):
    return {"name": name, "status": status, "conclusion": conclusion, "completed_at": completed}


BACKEND = "Backend Tests (vitest)"
# The jobs of the judging runs: 102 is A's green verdict (the last job to complete bounds it), 201 B's red (the FIRST
# red job bounds it, not the later one), 301 C's green with one job.
CI_JOBS = {
    "102": [job(BACKEND, "success", "2026-11-02T14:42:00Z"), job("lint", "success", "2026-11-02T13:50:00Z"), job("docs", None, None, status="in_progress")],
    "201": [job("lint", "success", "2026-11-03T10:05:00Z"), job("typecheck", "failure", "2026-11-03T12:35:00Z"), job(BACKEND, "failure", "2026-11-03T12:30:00Z")],
    "301": [job("tests", "success", "2026-11-03T11:30:00Z")],
}


def ci_env(tmp_path, runs=CI_RUNS, fail=False, jobs=CI_JOBS, jobs_fail=False):
    """A forge stand-in: `AUTOCODER_CI_RUNS_CMD` gets SHA and BRANCH, prints the commit's runs as JSON and logs the call;
    `AUTOCODER_CI_JOBS_CMD` gets RUN_ID and prints the run's jobs (jobs.log records the calls)."""
    d = tmp_path / "ci"
    d.mkdir(exist_ok=True)
    for sha, rs in runs.items():
        (d / f"{sha}.json").write_text(json.dumps(rs))
    cmd = d / "runs.sh"
    cmd.write_text("#!/usr/bin/env bash\nset -u\necho \"$1 $2\" >> \"$(dirname \"$0\")/calls.log\"\n"
                   + ("echo 'forge down' >&2; exit 7\n" if fail else "f=\"$(dirname \"$0\")/$1.json\"; [ -f \"$f\" ] && cat \"$f\" || echo '[]'\n"))
    cmd.chmod(0o755)
    for rid, js in (jobs or {}).items():
        (d / f"jobs-{rid}.json").write_text(json.dumps(js))
    jcmd = d / "jobs.sh"
    jcmd.write_text("#!/usr/bin/env bash\nset -u\necho \"$1\" >> \"$(dirname \"$0\")/jobs.log\"\n"
                    + ("echo 'jobs api down' >&2; exit 7\n" if jobs_fail else "f=\"$(dirname \"$0\")/jobs-$1.json\"; [ -f \"$f\" ] && cat \"$f\" || echo '[]'\n"))
    jcmd.chmod(0o755)
    return {"AUTOCODER_CI_RUNS_CMD": str(cmd), "AUTOCODER_CI_JOBS_CMD": str(jcmd)}, d / "calls.log"


def ci_log(tmp_path, rows=CI_FIXTURE):
    p = tmp_path / "l.jsonl"
    p.write_text("".join(json.dumps(r) + "\n" for r in rows))
    return p


def test_writer_landed_row_carries_its_commit_and_a_ci_verdict_row_is_a_kind(tmp_path):
    log = tmp_path / "l.jsonl"
    assert write(log, "change", "--issue", "7", "--event", "landed", "--sha", SHA_A, "--ts", "2026-11-01T10:00:00Z").returncode == 0
    assert rows_of(log)[0]["sha"] == SHA_A
    assert write(log, "change", "--issue", "7", "--event", "ready").returncode == 0 and "sha" not in rows_of(log)[1]
    r = write(log, "ci-verdict", "--sha", SHA_A, "--conclusion", "failure", "--run-id", "201", "--verdict-ts", "2026-11-01T12:30:00Z", "--ts", "2026-11-01T13:00:00Z")
    assert r.returncode == 0, r.stderr
    assert rows_of(log)[2] == {"v": 1, "ts": "2026-11-01T13:00:00Z", "kind": "ci-verdict", "sha": SHA_A, "run_id": "201",
                               "conclusion": "failure", "verdict_ts": "2026-11-01T12:30:00Z", "job": None, "workflows": None, "repo": None}
    r = write(log, "ci-verdict", "--sha", SHA_A, "--conclusion", "failure", "--run-id", "201", "--verdict-ts", "2026-11-01T12:30:00Z", "--job", " Backend Tests (vitest) ")
    assert r.returncode == 0 and rows_of(log)[3]["job"] == "Backend Tests (vitest)"


@pytest.mark.parametrize("args,needle", [
    (["change", "--issue", "1", "--event", "ready", "--sha", SHA_A], "belongs to --event landed"),
    (["change", "--issue", "1", "--event", "landed", "--sha", "xyz"], "not a commit"),
    (["ci-verdict", "--sha", SHA_A, "--conclusion", "unknown", "--verdict-ts", "2026-11-01T12:30:00Z"], "never cached"),
    (["ci-verdict", "--sha", SHA_A, "--conclusion", "pending", "--verdict-ts", "2026-11-01T12:30:00Z"], "never cached"),
    (["ci-verdict", "--sha", SHA_A, "--conclusion", "success"], "--verdict-ts"),
])
def test_writer_refuses_a_bad_commit_or_an_uncacheable_verdict(tmp_path, args, needle):
    r = write(tmp_path / "l.jsonl", *args)
    assert r.returncode == 2 and needle in r.stderr and not (tmp_path / "l.jsonl").exists()


def test_report_asks_the_forge_once_per_landed_commit_and_caches_the_terminal_verdicts(tmp_path):
    log = ci_log(tmp_path)
    env, calls = ci_env(tmp_path)
    r = report("--log", str(log), "--week", "2026-11-02", "--json", "--integration", "master", env=env)
    assert r.returncode == 0, r.stderr
    ci = json.loads(r.stdout)["ci"]
    # four landed commits (A has two members), one landed row with no commit; A, B, C judged, D still running
    assert (ci["landings"], ci["unrecorded"], ci["judged"], ci["pending"], ci["none"], ci["unknown"]) == (4, 1, 3, 1, 0, 0)
    # lags: A 13:00 -> 14:42 (the last run of the commit, the cancelled and the other branch's run ignored) = 6120 s,
    # B 10:00 -> 12:30 (the FIRST failing run: when the red surfaced) = 9000 s, C 1800 s
    assert ci["lag_s"] == {"n": 3, "p50": 6120, "p75": 7560, "max": 9000}
    assert [(x["sha"], x["issues"], x["lag_s"], x["run_id"], x["landings_before_verdict"]) for x in ci["red"]] == [(SHA_B, [3], 9000, "201", 2)]
    assert (ci["landings_before_red_verdicts"], ci["landings_before_red_verdicts_distinct"], ci["red_count"]) == (2, 2, 1)
    assert sorted(calls.read_text().split("\n")[:-1]) == sorted(f"{s} master" for s in (SHA_A, SHA_B, SHA_C, SHA_D))
    cached = [x for x in rows_of(log) if x["kind"] == "ci-verdict"]
    assert [(x["sha"], x["conclusion"], x["run_id"], x["verdict_ts"], x["job"]) for x in cached] == [
        (SHA_A, "success", "102", "2026-11-02T14:42:00Z", BACKEND), (SHA_B, "failure", "201", "2026-11-03T12:30:00Z", BACKEND), (SHA_C, "success", "301", "2026-11-03T11:30:00Z", "tests")]
    # the bounding job: the LAST job to complete of a green run (the in-progress one has no say), the FIRST red job of a red run
    assert ci["bounding_jobs"] == [{"job": BACKEND, "n": 2}, {"job": "tests", "n": 1}] and ci["job_unread"] == 0
    assert sorted(Path(str(calls).replace("calls.log", "jobs.log")).read_text().split()) == ["102", "201", "301"]
    # the second run reads the cache: only the pending commit is asked again, and the numbers are the same
    calls.unlink()
    a2 = json.loads(report("--log", str(log), "--week", "2026-11-02", "--json", env=env).stdout)["ci"]
    assert calls.read_text().split() == [SHA_D, "master"]
    assert (a2["judged"], a2["lag_s"], a2["cached"]) == (3, ci["lag_s"], 3) and len([x for x in rows_of(log) if x["kind"] == "ci-verdict"]) == 3


def test_week_page_rows_name_the_lag_the_reds_and_the_landings_before_their_verdicts(tmp_path):
    log = ci_log(tmp_path)
    env, _ = ci_env(tmp_path)
    out = report("--log", str(log), "--week", "2026-11-02", env=env).stdout
    assert "- Landing to CI verdict: p50 1.7h, p75 2.1h (n=3 of 4 landed commits; pending 1; 1 landed row carries no commit); " \
           "judged red by CI: 1 landing; landings that happened before those verdicts: 2; bounding job: Backend Tests (vitest) 2, tests 1" in out
    assert "| b3 | 2026-11-03T10:00:00Z | #3 | green | 30.0m | #3 | - | - | - | failure 2.5h in Backend Tests (vitest) (2 landed before the verdict) |" in out
    assert "| b2 | 2026-11-02T13:00:00Z | #1 #2 | green | 40.0m | #1 #2 | - | - | - | success 1.7h in Backend Tests (vitest) |" in out
    assert "| b6 | 2026-11-03T12:00:00Z | #6 | green | 30.0m | #6 | - | - | - | pending |" in out
    assert "| b7 | 2026-11-03T13:00:00Z | #7 | green | 30.0m | #7 | - | - | - | - |" in out
    assert "| CI verdict |" in out
    assert "- Landing to CI verdict: p50 1.7h, p75 2.1h, max 2.5h (n=3 of 4 landed commits" in out   # the Time section carries it too


def test_a_forge_that_cannot_be_reached_reads_unknown_never_zero_and_caches_nothing(tmp_path):
    log = ci_log(tmp_path)
    env, calls = ci_env(tmp_path, fail=True)
    r = report("--log", str(log), "--week", "2026-11-02", "--json", env=env)
    assert r.returncode == 0
    ci = json.loads(r.stdout)["ci"]
    assert (ci["landings"], ci["judged"], ci["unknown"], ci["lag_s"]["n"], ci["red_count"]) == (4, 0, 4, 0, None)   # unknown, never 0
    assert ci["landings_before_red_verdicts"] is None and "forge down" in (ci["forge_error"] or "")
    assert not [x for x in rows_of(log) if x["kind"] == "ci-verdict"]
    out = report("--log", str(log), "--week", "2026-11-02", env=env).stdout
    assert "- Landing to CI verdict: unknown (the forge could not be reached for 4 landed commits: " in out
    assert "judged red by CI: unknown" in out and "| unknown |" in out
    assert "red by CI: 0" not in out and "verdicts: 0" not in out
    assert "the forge could not be reached" in r.stderr


def test_ci_off_asks_nothing_and_reads_the_cache_it_has(tmp_path):
    log = ci_log(tmp_path)
    env, calls = ci_env(tmp_path)
    out = report("--log", str(log), "--week", "2026-11-02", "--ci", "off", env=env).stdout
    assert not calls.exists() and "- Landing to CI verdict: n/a (not queried, --ci off; 4 landed commits)" in out
    write(log, "ci-verdict", "--sha", SHA_B, "--conclusion", "failure", "--run-id", "201", "--verdict-ts", "2026-11-03T12:30:00Z")
    a = json.loads(report("--log", str(log), "--week", "2026-11-02", "--ci", "off", "--json", env=env).stdout)["ci"]
    assert not calls.exists() and (a["judged"], a["cached"], a["red_count"], a["landings_before_red_verdicts"]) == (1, 1, 1, 2)


def test_no_landed_row_with_a_commit_reads_na(log):
    env, calls = ci_env(log.parent)
    out = report("--log", str(log), "--week", "2026-11-02", env=env).stdout
    assert not calls.exists() and "- Landing to CI verdict: n/a (no landed row carries its commit)" in out


def test_ci_runs_without_the_commits_runs_are_none_not_a_verdict(tmp_path):
    log = ci_log(tmp_path, [chs(1, "2026-11-02T13:00:00Z", SHA_A), ba("b2", "2026-11-02T13:00:00Z", [1], 600, "green")])
    env, _ = ci_env(tmp_path, runs={})
    a = json.loads(report("--log", str(log), "--week", "2026-11-02", "--json", env=env).stdout)["ci"]
    assert (a["landings"], a["none"], a["judged"]) == (1, 1, 0) and not [x for x in rows_of(log) if x["kind"] == "ci-verdict"]
    out = report("--log", str(log), "--week", "2026-11-02", env=env).stdout
    assert "no run 1" in out and "| no run |" in out


def test_ci_workflow_filter_judges_only_the_named_workflows(tmp_path):
    log = ci_log(tmp_path, [chs(1, "2026-11-02T13:00:00Z", SHA_A), ba("b2", "2026-11-02T13:00:00Z", [1], 600, "green")])
    env, _ = ci_env(tmp_path)
    a = json.loads(report("--log", str(log), "--week", "2026-11-02", "--json", "--ci-workflow", "tests", env=env).stdout)["ci"]
    assert a["lag_s"]["max"] == 2400   # A's `tests` run ended 13:40; the later `build` run is not judged


def git_repo(tmp_path, subjects):
    """A checkout whose integration branch carries one commit per subject, in order; returns (dir, [sha...])."""
    d = tmp_path / "repo"
    d.mkdir()
    g = lambda *a: subprocess.run(["git", "-C", str(d), *a], capture_output=True, text=True, check=True, env={**os.environ, "GIT_AUTHOR_DATE": "2026-11-03T09:00:00Z", "GIT_COMMITTER_DATE": "2026-11-03T09:00:00Z"})
    g("init", "-q", "-b", "master")
    g("config", "user.email", "t@example.invalid")
    g("config", "user.name", "t")
    shas = []
    for i, subj in enumerate(subjects):
        (d / "f").write_text(str(i))
        g("add", "f")
        g("commit", "-q", "-m", subj)
        shas.append(g("rev-parse", "HEAD").stdout.strip())
    return d, shas


def test_a_landed_row_without_a_commit_is_resolved_from_the_integration_branch_by_batch_id_or_issue(tmp_path):
    # every commit shares one committer second (a rebased series does): the newest `#7` commit, the push's tip, is the landing
    repo, (train_sha, first_sha, solo_sha, other_sha) = git_repo(tmp_path, ["Issue #99: train/20261103T083000Z-1 (squashed: the branch contained merge commits)",
                                                                              "#7: the solo landing, first commit", "#7: the solo landing, its tip",
                                                                              "#8: a later landing of another issue"])
    rows = [ch(1, "2026-11-03T09:10:00Z", "landed", batch="train-20261103T083000Z-1"), ch(2, "2026-11-03T09:10:00Z", "landed", batch="train-20261103T083000Z-1"),
            ch(7, "2026-11-03T09:20:00Z", "landed", batch="solo-7-1-1700000000"),
            ch(5, "2026-11-03T09:30:00Z", "landed", batch="pub-1700000000-1"),           # nothing on the branch names it: stays unrecorded
            ch(7, "2026-11-01T09:20:00Z", "landed", batch="solo-7-1-1600000000"),        # the same issue two days earlier: no #7 commit at that time
            ba("train-20261103T083000Z-1", "2026-11-03T09:10:00Z", [1, 2], 600, "green")]
    log = tmp_path / "l.jsonl"
    log.write_text("".join(json.dumps(r) + "\n" for r in rows))
    env, calls = ci_env(tmp_path, runs={train_sha: [run(1, "completed", "success", "2026-11-03T10:10:00Z")],
                                        solo_sha: [run(2, "completed", "failure", "2026-11-03T11:20:00Z")]})
    a = json.loads(report("--log", str(log), "--week", "2026-11-02", "--json", "--repo", str(repo), env=env).stdout)
    ci = a["ci"]
    assert set(ci["by_sha"]) == {train_sha, solo_sha} and (ci["landings"], ci["unrecorded"], ci["judged"]) == (2, 1, 2)   # the pub row; the 11-01 row is outside the week
    assert ci["lag_s"] == {"n": 2, "p50": 5400, "p75": 6300, "max": 7200} and ci["red"][0]["issues"] == [7]
    assert sorted(calls.read_text().split("\n")[:-1]) == sorted(f"{s} master" for s in (train_sha, solo_sha))
    rows2 = {b["batch"]: b for b in a["batch_rows"]}
    assert rows2["train-20261103T083000Z-1"]["ci"]["status"] == "success"
    # the resolution is read-time: the ledger's landed rows are not rewritten, the verdicts are cached by commit
    assert [x for x in rows_of(log) if x["kind"] == "change" and x.get("sha")] == []
    assert sorted(x["sha"] for x in rows_of(log) if x["kind"] == "ci-verdict") == sorted([train_sha, solo_sha])


def test_ci_workflows_come_from_the_repositorys_config_and_a_cache_from_another_selection_is_not_reused(tmp_path):
    repo, _ = git_repo(tmp_path, ["unrelated"])
    (repo / ".autocoder.json").write_text(json.dumps({"ciWorkflows": ["tests"]}))
    log = ci_log(tmp_path, [chs(1, "2026-11-02T13:00:00Z", SHA_A), ba("b2", "2026-11-02T13:00:00Z", [1], 600, "green")])
    env, calls = ci_env(tmp_path)
    # a verdict cached over every workflow (the later `build` run) is not the `tests` verdict: the forge is asked
    write(log, "ci-verdict", "--sha", SHA_A, "--conclusion", "success", "--run-id", "102", "--verdict-ts", "2026-11-02T14:42:00Z")
    a = json.loads(report("--log", str(log), "--week", "2026-11-02", "--json", "--repo", str(repo), env=env).stdout)["ci"]
    assert (a["lag_s"]["max"], a["workflows"], a["cached"], a["queried"]) == (2400, ["tests"], 0, 1)
    cached = [x for x in rows_of(log) if x["kind"] == "ci-verdict"]
    assert [(x["workflows"], x["run_id"]) for x in cached] == [(None, "102"), (["tests"], "101")]
    out = report("--log", str(log), "--week", "2026-11-02", "--repo", str(repo), env=env).stdout
    assert "; workflows judged: tests" in out and calls.read_text().count(SHA_A) == 1   # the second run read the `tests` cache


def test_two_reds_count_a_landing_stacked_on_both_once_in_the_distinct_figure(tmp_path):
    sha_e = "e" * 40
    rows = [chs(1, "2026-11-03T10:00:00Z", SHA_B, batch="b3"), chs(2, "2026-11-03T10:30:00Z", sha_e, batch="b8"), chs(3, "2026-11-03T11:00:00Z", SHA_C, batch="b5"),
            ba("b3", "2026-11-03T10:00:00Z", [1], 600, "green"), ba("b8", "2026-11-03T10:30:00Z", [2], 600, "green"), ba("b5", "2026-11-03T11:00:00Z", [3], 600, "green")]
    log = ci_log(tmp_path, rows)
    env, _ = ci_env(tmp_path, runs={SHA_B: [run(1, "completed", "failure", "2026-11-03T12:30:00Z")], sha_e: [run(2, "completed", "failure", "2026-11-03T12:40:00Z")],
                                    SHA_C: [run(3, "completed", "success", "2026-11-03T11:30:00Z")]})
    a = json.loads(report("--log", str(log), "--week", "2026-11-02", "--json", env=env).stdout)["ci"]
    # C landed before both verdicts (counted per red: 2), E before B's (1): 3 in all, 2 distinct landings
    assert (a["red_count"], a["landings_before_red_verdicts"], a["landings_before_red_verdicts_distinct"]) == (2, 3, 2)
    out = report("--log", str(log), "--week", "2026-11-02", env=env).stdout
    assert "judged red by CI: 2 landings; landings that happened before those verdicts: 3 (2 distinct)" in out


# ── the adversarial review's cases (each was a wrong figure before its fix) ────────────────
def test_a_landing_past_the_windows_end_or_without_a_commit_still_counts_as_stacked_on_a_red(tmp_path):
    rows = [chs(3, "2026-11-03T23:00:00Z", SHA_B, batch="b3"), chs(5, "2026-11-04T00:30:00Z", SHA_C, batch="b5"),
            ch(6, "2026-11-04T01:00:00Z", "landed", batch="b6"),     # no commit: still a landing that happened before the verdict
            ba("b3", "2026-11-03T23:00:00Z", [3], 60, "green"), ba("b5", "2026-11-04T00:30:00Z", [5], 60, "green")]
    env, _ = ci_env(tmp_path, {SHA_B: [run(1, "completed", "failure", "2026-11-04T02:00:00Z")], SHA_C: [run(2, "completed", "success", "2026-11-04T01:00:00Z")]})
    a = json.loads(report("--log", str(ci_log(tmp_path, rows)), "--since", "2026-11-03", "--until", "2026-11-04", "--json", env=env).stdout)["ci"]
    # only B is in the window (judged); C landed after `until` and #6's row names no commit, both before B's verdict
    assert (a["landings"], a["red_count"], a["landings_before_red_verdicts"], a["landings_before_red_verdicts_distinct"]) == (1, 1, 2, 2)


def test_a_hand_written_prefix_of_a_commit_is_the_same_landing_and_the_writer_refuses_a_prefix(tmp_path):
    rows = [chs(1, "2026-11-03T10:00:00Z", SHA_A, batch="b1"), chs(2, "2026-11-03T10:00:00Z", SHA_A[:10], batch="b1"), ba("b1", "2026-11-03T10:00:00Z", [1, 2], 60, "green")]
    env, calls = ci_env(tmp_path, {SHA_A: [run(1, "completed", "success", "2026-11-03T11:00:00Z")]})
    a = json.loads(report("--log", str(ci_log(tmp_path, rows)), "--json", env=env).stdout)["ci"]
    assert (a["landings"], a["judged"], a["none"]) == (1, 1, 0) and calls.read_text().split() == [SHA_A, "master"]
    r = write(tmp_path / "w.jsonl", "change", "--issue", "1", "--event", "landed", "--sha", SHA_A[:10])
    assert r.returncode == 2 and "full object name" in r.stderr


def test_a_cached_row_that_says_unknown_is_not_a_verdict(tmp_path):
    rows = [chs(1, "2026-11-03T10:00:00Z", SHA_A, batch="b1"), ba("b1", "2026-11-03T10:00:00Z", [1], 60, "green"),
            {"v": 1, "ts": "2026-11-03T12:00:00Z", "kind": "ci-verdict", "sha": SHA_A, "run_id": None, "conclusion": "unknown", "verdict_ts": "2026-11-03T11:00:00Z", "workflows": None}]
    env, calls = ci_env(tmp_path, {SHA_A: [run(1, "completed", "success", "2026-11-03T11:00:00Z")]})
    a = json.loads(report("--log", str(ci_log(tmp_path, rows)), "--json", env=env).stdout)["ci"]
    assert (a["unknown"], a["judged"], a["queried"]) == (0, 1, 1) and calls.exists()


def test_ci_off_with_a_partial_cache_says_the_red_figures_are_floors(tmp_path):
    rows = [chs(1, "2026-11-03T10:00:00Z", SHA_A, batch="b1"), chs(2, "2026-11-03T11:00:00Z", SHA_B, batch="b2"),
            ba("b1", "2026-11-03T10:00:00Z", [1], 60, "green"), ba("b2", "2026-11-03T11:00:00Z", [2], 60, "green"),
            {"v": 1, "ts": "2026-11-03T12:00:00Z", "kind": "ci-verdict", "sha": SHA_A, "run_id": "1", "conclusion": "success", "verdict_ts": "2026-11-03T11:00:00Z", "workflows": None}]
    out = report("--log", str(ci_log(tmp_path, rows)), "--ci", "off", "--since", "2026-11-01").stdout
    assert "(n=1 of 2 landed commits; not queried 1); judged red by CI: 0 landings; landings that happened before those verdicts: 0 (both at least: 1 not queried of the landed commits)" in out


def test_a_verdict_before_the_landed_row_is_a_lag_of_zero_and_is_said(tmp_path):
    rows = [chs(1, "2026-11-03T10:00:00Z", SHA_A, batch="b1"), ba("b1", "2026-11-03T10:00:00Z", [1], 60, "green")]
    env, _ = ci_env(tmp_path, {SHA_A: [run(1, "completed", "success", "2026-11-03T09:50:00Z")]})
    out = report("--log", str(ci_log(tmp_path, rows)), "--since", "2026-11-01", "--batches", env=env).stdout
    assert "| success 0s |" in out and "(n=1 of 1 landed commits; 1 verdict before the row (lag 0))" in out and "-600" not in out


def test_bounding_job_is_the_first_red_job_of_a_red_run_and_the_last_completed_job_of_a_green_one():
    lr = load_module()
    jobs = [job("lint", "success", "2026-11-03T10:05:00Z"), job("typecheck", "failure", "2026-11-03T12:35:00Z"),
            job(BACKEND, "failure", "2026-11-03T12:30:00Z"), job("deploy", None, None, status="queued")]
    assert lr.bounding_job(jobs, "failure") == BACKEND
    assert lr.bounding_job(jobs, "success") == "lint"                      # the last SUCCESSFUL job of a green verdict
    assert lr.bounding_job([job("a", "success", "2026-11-03T10:00:00Z"), job("b", "success", None)], "success") == "a"   # an untimed job is first
    assert lr.bounding_job([job("a", "failure", None), job("b", "failure", "2026-11-03T10:00:00Z")], "failure") == "b"   # an untimed red job is last
    assert lr.bounding_job([job("a", None, None, status="in_progress")], "success") is None and lr.bounding_job([], "failure") is None
    assert lr.bounding_job([job("a", "cancelled", "2026-11-03T10:00:00Z")], "success") == "a"   # no successful job: the last completed one


def test_jobs_that_cannot_be_read_leave_the_bounding_job_not_read_and_the_verdict_still_cached(tmp_path):
    rows = [chs(1, "2026-11-03T10:00:00Z", SHA_A, batch="b1"), ba("b1", "2026-11-03T10:00:00Z", [1], 60, "green"),
            # a row cached before the writer carried the job (an older writer): judged, its job not read
            chs(2, "2026-11-03T11:00:00Z", SHA_B, batch="b2"), ba("b2", "2026-11-03T11:00:00Z", [2], 60, "green"),
            {"v": 1, "ts": "2026-11-03T12:00:00Z", "kind": "ci-verdict", "sha": SHA_B, "run_id": "9", "conclusion": "success", "verdict_ts": "2026-11-03T11:30:00Z", "workflows": None}]
    env, _ = ci_env(tmp_path, {SHA_A: [run(1, "completed", "failure", "2026-11-03T11:00:00Z")]}, jobs_fail=True)
    log = ci_log(tmp_path, rows)
    r = report("--log", str(log), "--json", "--since", "2026-11-01", env=env)
    a = json.loads(r.stdout)["ci"]
    assert (a["judged"], a["bounding_jobs"], a["job_unread"]) == (2, [], 2)
    assert [x["job"] for x in a["red"]] == [None]
    cached = [x for x in rows_of(log) if x["kind"] == "ci-verdict" and x["sha"] == SHA_A]
    assert len(cached) == 1 and cached[0]["job"] is None            # cached without the job, not refused
    assert "the jobs of 1 judging run(s) could not be read" in r.stderr and "jobs api down" in r.stderr
    out = report("--log", str(log), "--since", "2026-11-01", "--batches", env=env).stdout
    assert "; bounding job: not read" in out and "| failure 60.0m |" in out   # no " in <job>" on the cell


def test_a_completed_red_run_without_a_time_is_red_with_an_unknown_lag_and_is_not_cached(tmp_path):
    rows = [chs(1, "2026-11-03T10:00:00Z", SHA_A, batch="b1"), ba("b1", "2026-11-03T10:00:00Z", [1], 60, "green")]
    env, _ = ci_env(tmp_path, {SHA_A: [run(1, "completed", "failure", None)]})
    log = ci_log(tmp_path, rows)
    a = json.loads(report("--log", str(log), "--json", env=env).stdout)["ci"]
    assert a["by_sha"][SHA_A] == {"status": "failure", "lag_s": None, "job": None, "landings_before_verdict": None}
    assert (a["red_count"], a["judged"], a["untimed"], a["lag_s"]["n"]) == (1, 1, 0 + 1, 0)
    assert not [x for x in rows_of(log) if x["kind"] == "ci-verdict"]
    out = report("--log", str(log), "--since", "2026-11-01", "--batches", env=env).stdout
    assert "| failure (time unknown) |" in out and "1 judged without a time" in out


def test_all_repos_asks_no_forge_and_caches_nothing(tmp_path):
    repo, _ = git_repo(tmp_path, ["#1: x"])
    rows = [{**chs(1, "2026-11-03T10:00:00Z", SHA_A, batch="b1"), "repo": "ours-0123abcd"}, {**ba("b1", "2026-11-03T10:00:00Z", [1], 60, "green"), "repo": "ours-0123abcd"},
            {**chs(2, "2026-11-03T11:00:00Z", SHA_B, batch="b2"), "repo": "other-1234abcd"}, {**ba("b2", "2026-11-03T11:00:00Z", [2], 60, "green"), "repo": "other-1234abcd"}]
    log = ci_log(tmp_path, rows)
    env, calls = ci_env(tmp_path)
    r = report("--log", str(log), "--all-repos", "--repo", str(repo), env=env)
    assert r.returncode == 0 and not calls.exists() and not [x for x in rows_of(log) if x["kind"] == "ci-verdict"]
    assert "n/a (not queried, --all-repos: the CI verdict is asked of one repository; 2 landed commits)" in r.stdout
    assert "--all-repos: the CI verdict is not queried" in r.stderr


def test_history_mode_makes_one_landing_per_pushed_tip_not_per_member_commit(tmp_path):
    lr = load_module()
    repo, (first, tip) = git_repo(tmp_path, ["train/20261103T0830Z: #1 first member", "train/20261103T0830Z: #2 second member (the pushed tip)"])
    rows = lr.git_rows(str(repo), "master", None, re.compile(r"(?i)\b(?:train|batch)/([A-Za-z0-9._-]+):\s*#(\d+)"), re.compile(r"^$x"))
    landings, unrecorded = lr.landings_of(rows, None, None)
    assert unrecorded == 0 and {k: sorted(v["issues"]) for k, v in landings.items()} == {tip: [1, 2]}


def test_a_workflow_name_with_a_comma_is_one_name_and_its_cache_is_read(tmp_path):
    repo, _ = git_repo(tmp_path, ["unrelated"])
    (repo / ".autocoder.json").write_text(json.dumps({"ciWorkflows": ["Build, Test"]}))
    log = ci_log(tmp_path, [chs(1, "2026-11-02T13:00:00Z", SHA_A), ba("b2", "2026-11-02T13:00:00Z", [1], 600, "green")])
    env, calls = ci_env(tmp_path, runs={SHA_A: [run(1, "completed", "success", "2026-11-02T13:40:00Z", name="Build, Test")]})
    first = json.loads(report("--log", str(log), "--week", "2026-11-02", "--json", "--repo", str(repo), env=env).stdout)["ci"]
    second = json.loads(report("--log", str(log), "--week", "2026-11-02", "--json", "--repo", str(repo), env=env).stdout)["ci"]
    assert (first["queried"], first["cached"], second["queried"], second["cached"]) == (1, 0, 0, 1)
    assert [x["workflows"] for x in rows_of(log) if x["kind"] == "ci-verdict"] == [["Build, Test"]] and calls.read_text().count(SHA_A) == 1


def test_a_batch_row_shows_the_landing_nearest_its_time_when_the_landed_row_names_no_batch(tmp_path):
    rows = [chs(7, "2026-11-03T10:00:00Z", SHA_A, batch="b1"), ba("b1", "2026-11-03T10:00:00Z", [7], 600, "green"),
            chs(7, "2026-11-03T14:00:00Z", SHA_B), ch(7, "2026-11-03T13:50:00Z", "batched", batch="b9"), ba("b9", "2026-11-03T14:00:00Z", [7], 600, "green")]
    env, _ = ci_env(tmp_path, runs={SHA_A: [run(1, "completed", "success", "2026-11-03T10:30:00Z")], SHA_B: [run(2, "completed", "failure", "2026-11-03T16:00:00Z")]})
    out = report("--log", str(ci_log(tmp_path, rows)), "--week", "2026-11-02", env=env).stdout
    assert "| b1 | 2026-11-03T10:00:00Z | #7 | green | 10.0m | #7 | - | - | - | success 30.0m |" in out
    assert "| b9 | 2026-11-03T14:00:00Z | #7 | green | 10.0m | #7 | - | - | - | failure 2.0h |" in out


def test_the_resolver_reads_past_a_fast_forwarded_commit_with_an_old_date(tmp_path):
    d = tmp_path / "repo"
    d.mkdir()
    def g(*a, date="2026-11-03T09:00:00Z"):
        return subprocess.run(["git", "-C", str(d), *a], capture_output=True, text=True, check=True,
                              env={**os.environ, "GIT_AUTHOR_DATE": date, "GIT_COMMITTER_DATE": date}).stdout.strip()
    g("init", "-q", "-b", "master"); g("config", "user.email", "t@example.invalid"); g("config", "user.name", "t")
    shas = []
    for i, (subj, date) in enumerate([("Issue #99: train/20261103T083000Z-1 (squashed)", "2026-11-03T09:00:00Z"), ("an old-dated commit fast-forwarded in", "2026-10-20T09:00:00Z"), ("#8: a later landing", "2026-11-03T09:30:00Z")]):
        (d / "f").write_text(str(i)); g("add", "f"); g("commit", "-q", "-m", subj, date=date); shas.append(g("rev-parse", "HEAD"))
    rows = [ch(1, "2026-11-03T09:10:00Z", "landed", batch="train-20261103T083000Z-1"), ch(8, "2026-11-03T09:40:00Z", "landed", batch="solo-8-1-1")]
    log = ci_log(tmp_path, rows)
    a = json.loads(report("--log", str(log), "--week", "2026-11-02", "--json", "--repo", str(d), "--ci", "off", env={}).stdout)["ci"]
    assert set(a["by_sha"]) == {shas[0], shas[2]} and a["unrecorded"] == 0


def test_a_landing_in_the_same_second_as_the_red_landing_counts_as_stacked(tmp_path):
    sha_e = "e" * 40
    rows = [chs(1, "2026-11-03T10:00:00Z", SHA_B, batch="b3"), chs(2, "2026-11-03T10:00:00Z", sha_e, batch="b8"), chs(3, "2026-11-03T12:30:00Z", SHA_C, batch="b5"),
            ba("b3", "2026-11-03T10:00:00Z", [1], 600, "green"), ba("b8", "2026-11-03T10:00:00Z", [2], 600, "green"), ba("b5", "2026-11-03T12:30:00Z", [3], 600, "green")]
    env, _ = ci_env(tmp_path, runs={SHA_B: [run(1, "completed", "failure", "2026-11-03T12:30:00Z")], sha_e: [run(2, "completed", "success", "2026-11-03T11:00:00Z")],
                                    SHA_C: [run(3, "completed", "success", "2026-11-03T13:00:00Z")]})
    a = json.loads(report("--log", str(ci_log(tmp_path, rows)), "--week", "2026-11-02", "--json", env=env).stdout)["ci"]
    assert a["red"][0]["landings_before_verdict"] == 1     # E (same second as the landing) counts; C at the verdict's second does not


def test_a_completed_run_without_a_conclusion_is_not_a_success(tmp_path):
    lr = load_module()
    assert lr.judge_runs([run(1, "completed", None, "2026-11-03T10:00:00Z")], "master", set())[0] == "inconclusive"
    assert lr.judge_runs([run(1, "completed", None, "2026-11-03T10:00:00Z"), run(2, "completed", "cancelled", "2026-11-03T10:00:00Z")], "master", set())[0] == "cancelled"
    assert lr.judge_runs([run(1, "completed", None, "2026-11-03T10:00:00Z"), run(2, "completed", "success", "2026-11-03T10:05:00Z")], "master", set())[:1] == ("success",)


# ── READY to launch (the train daemon's row) ────────────────────────────────
def test_writer_accepts_a_launched_change_row(tmp_path):
    log = tmp_path / "l.jsonl"
    assert write(log, "change", "--issue", "7", "--event", "launched", "--ts", "2026-11-02T10:05:00Z").returncode == 0
    assert rows_of(log)[0]["event"] == "launched"


def test_week_and_full_reports_show_ready_to_launch_from_the_newest_ready_before_each_launch(tmp_path):
    p = tmp_path / "l.jsonl"
    rows = [ch(1, "2026-11-02T10:00:00Z", "ready"), ch(1, "2026-11-02T10:05:00Z", "launched"),       # 5 min
            ch(1, "2026-11-02T10:30:00Z", "batched", batch="b1"), ch(1, "2026-11-02T11:00:00Z", "returned", cause="defect", batch="b1"),
            ch(1, "2026-11-02T12:00:00Z", "ready"), ch(1, "2026-11-02T12:15:00Z", "launched"),       # a relaunch: 15 min, from the NEWER READY
            ch(1, "2026-11-02T12:20:00Z", "batched", batch="b2"), ch(1, "2026-11-02T13:00:00Z", "landed", batch="b2"),
            ch(2, "2026-11-02T09:30:00Z", "ready"), ch(2, "2026-11-02T09:31:00Z", "launched"),       # 1 min
            ch(3, "2026-11-02T09:00:00Z", "launched"),                                                 # no READY before it: not measured
            ba("b2", "2026-11-02T13:00:00Z", [1], 2400, "green")]
    p.write_text("".join(json.dumps(r) + "\n" for r in rows))
    a = json.loads(report("--log", str(p), "--week", "2026-11-02", "--json").stdout)
    assert a["timings"]["ready_to_launch_s"] == {"n": 3, "p50": 300, "p90": 780, "max": 900}   # p90 interpolates over 60, 300, 900
    out = report("--log", str(p), "--week", "2026-11-02").stdout
    assert "- READY to launch (a cycle took it): p50 5.0m, p90 13.0m, max 15.0m (n=3)" in out
    assert out.count("READY to launch (a cycle took it)") == 2   # the week summary and the Time section


def test_ready_to_launch_is_na_and_says_why_when_no_launched_row_exists(log):
    out = report("--log", str(log), "--week", "2026-11-02").stdout
    assert "- READY to launch (a cycle took it): n/a (no `launched` row" in out


# ── the worker idle gap (READY of the previous issue to the worker's next claim) ──────────
def ev(ts, worker, issue, event="claimed", repo=None):
    return {"v": 1, "ts": ts, "repo": repo, "issue": issue, "worker": worker, "branch": None, "event": event, "detail": {}}


def test_week_and_full_reports_show_the_worker_idle_gap_from_the_lifecycle_ledgers_claims(tmp_path):
    log = tmp_path / "l.jsonl"
    log.write_text("".join(json.dumps(r) + "\n" for r in [
        ch(1, "2026-11-02T10:00:00Z", "ready"),                     # w1 banked #1 at 10:00
        ch(2, "2026-11-02T11:00:00Z", "ready"),                     # w2 banked #2 at 11:00
        ch(3, "2026-11-02T12:00:00Z", "ready"),                     # w1 banked #3 at 12:00
        ba("b1", "2026-11-02T13:00:00Z", [1, 2, 3], 1800, "green")]))
    events = tmp_path / "events.jsonl"
    events.write_text("".join(json.dumps(e) + "\n" for e in [
        ev("2026-11-02T08:00:00Z", "w1", 1), ev("2026-11-02T10:30:00Z", "w1", 3),    # w1: 30 min idle after #1's READY
        ev("2026-11-02T12:05:00Z", "w1", 5),                                           # w1: 5 min after #3's READY
        ev("2026-11-02T09:00:00Z", "w2", 2), ev("2026-11-02T11:40:00Z", "w2", 4),    # w2: 40 min after #2's READY
        ev("2026-11-02T09:00:00Z", "w3", 6), ev("2026-11-02T10:00:00Z", "w3", 7),    # w3: #6 never reached READY: not measured
        ev("2026-11-02T10:00:00Z", "w1", 1, event="released"),                       # another event kind: ignored
        ev("2026-11-02T10:00:00Z", "w9", 1, repo="other-00000000"), ev("2026-11-02T10:10:00Z", "w9", 3, repo="other-00000000"),
    ]) + "garbage\n")
    a = json.loads(report("--log", str(log), "--week", "2026-11-02", "--json", "--issue-events", str(events), "--all-repos").stdout)
    # --all-repos: w9's rows count too (10 min); without it the rows name a repository this fixture is not run from
    assert a["workers"]["claims"] == 9
    assert a["workers"]["idle_gap_s"] == {"n": 4, "p50": 1200.0, "p90": 2220.0, "max": 2400.0} and a["workers"]["workers"] == 3   # 300, 600, 1800, 2400
    a = json.loads(report("--log", str(log), "--week", "2026-11-02", "--json", "--issue-events", str(events), "--repo-id", "mine-00000000").stdout)
    assert a["workers"]["idle_gap_s"]["n"] == 3 and a["workers"]["idle_gap_s"]["max"] == 2400.0, "rows naming another repository are dropped under --repo-id"
    out = report("--log", str(log), "--week", "2026-11-02", "--issue-events", str(events), "--repo-id", "mine-00000000").stdout
    assert "- Worker idle gap (READY of the previous issue to the next claim): p50 30.0m, p90 38.0m, max 40.0m (n=3 over 2 workers)" in out
    assert out.count("Worker idle gap (READY of the previous issue to the next claim)") == 2   # the week summary and the Time section


def test_the_idle_gap_is_na_and_says_why_without_a_lifecycle_ledger(log, tmp_path):
    out = report("--log", str(log), "--week", "2026-11-02", "--issue-events", str(tmp_path / "none.jsonl")).stdout
    assert "- Worker idle gap (READY of the previous issue to the next claim): n/a (no worker claimed a second issue after a READY in the window; no `claimed` lifecycle event read: pass --issue-events)" in out


# ── worker idle after a verdict (a PASS pre-check verdict to the issue's READY; the watchdog's nudges, #7134) ──
def vev(ts, worker, issue, event, **detail):
    return {**ev(ts, worker, issue, event=event), "detail": detail}


def test_week_and_full_reports_show_the_idle_time_after_a_verdict_and_the_watchdog_nudges(tmp_path):
    log = tmp_path / "l.jsonl"
    log.write_text("".join(json.dumps(r) + "\n" for r in [
        ch(1, "2026-11-02T10:00:00Z", "ready"),                     # w1 banked #1 at 10:00
        ch(2, "2026-11-02T11:00:00Z", "ready"),                     # w2 banked #2 at 11:00
        ch(4, "2026-11-02T09:00:00Z", "ready"),                     # #4's READY is BEFORE its verdict: a later run, not measured
        ba("b1", "2026-11-02T13:00:00Z", [1, 2, 4], 1800, "green")]))
    events = tmp_path / "events.jsonl"
    events.write_text("".join(json.dumps(e) + "\n" for e in [
        vev("2026-11-02T09:41:00Z", "w1", 1, "verdict", verdict="PASS", at="2026-11-02T09:40:00Z", log="/tmp/prebank-1.log"),   # 20 min to the READY
        vev("2026-11-02T10:51:00Z", "w2", 2, "verdict", verdict="PASS", at="2026-11-02T10:50:00Z", log="/tmp/prebank-2.log"),   # 10 min
        vev("2026-11-02T11:01:00Z", "w3", 3, "verdict", verdict="PASS", at="2026-11-02T11:00:00Z", log="/tmp/prebank-3.log"),   # no READY after it: not measured
        vev("2026-11-02T09:31:00Z", "w4", 4, "verdict", verdict="PASS", at="2026-11-02T09:30:00Z", log="/tmp/prebank-4.log"),   # READY before it only: not measured
        vev("2026-11-02T09:00:00Z", "w1", 1, "verdict", verdict="FAIL", at="2026-11-02T08:59:00Z", log="/tmp/prebank-1a.log"),  # a FAIL: not a wait to bank
        vev("2026-11-02T09:55:00Z", "w1", 1, "verdict-nudged", verdict="PASS", idle_s="900", log="/tmp/prebank-1.log"),         # the watchdog nudged w1 after 15 min
        vev("2026-11-02T12:00:00Z", "w5", 9, "verdict-nudged", verdict="DEAD", idle_s="1800", log="/tmp/prebank-9.log"),        # a dead run nudged
        vev("2026-11-09T12:00:00Z", "w5", 9, "verdict-nudged", verdict="DEAD", idle_s="99", log="/tmp/prebank-9.log"),          # next week: outside the window
        ev("2026-11-02T08:00:00Z", "w1", 1),                                                                                 # a claim: another kind, ignored here
    ]) + "garbage\n")
    a = json.loads(report("--log", str(log), "--week", "2026-11-02", "--json", "--issue-events", str(events), "--all-repos").stdout)
    assert a["verdicts"]["after_verdict_s"] == {"n": 2, "p50": 900.0, "p90": 1140.0, "max": 1200.0}   # 600 and 1200 seconds
    assert a["verdicts"]["workers"] == 2 and a["verdicts"]["verdicts"] == 5
    assert a["verdicts"]["nudges"] == 2 and a["verdicts"]["nudged_idle_s_total"] == 2700.0
    out = report("--log", str(log), "--week", "2026-11-02", "--issue-events", str(events), "--all-repos").stdout
    assert "- Worker idle after a verdict (a PASS pre-check verdict to the issue's READY): p50 15.0m, p90 19.0m, max 20.0m (n=2 over 2 workers); nudged 2 (45.0m idle when nudged)" in out
    assert out.count("Worker idle after a verdict (a PASS pre-check verdict to the issue's READY)") == 2   # the week summary and the Time section


def test_the_idle_time_after_a_verdict_is_na_and_says_why_without_verdict_events(log, tmp_path):
    out = report("--log", str(log), "--week", "2026-11-02", "--issue-events", str(tmp_path / "none.jsonl")).stdout
    assert "- Worker idle after a verdict (a PASS pre-check verdict to the issue's READY): n/a (no PASS verdict lifecycle event followed by a READY in the window; the verdict watchdog records them: pass --issue-events)" in out


# ── hotfix READY to landed ───────────────────────────────────────────────────
def lifecycle_event(issue, ts, event, branch, sha=None):
    return {"v": 1, "ts": ts, "repo": None, "issue": issue, "worker": f"mgr-gate-{issue}", "branch": branch, "event": event,
            "detail": ({"sha": sha, "integration": "master"} if sha else {})}


def test_week_report_hotfix_ready_to_landed_from_the_lifecycle_branch(tmp_path):
    """A hotfix is a lifecycle `landed` event from a hotfix/ branch; READY to landed is the lane's lead time, the
    median and the worst are printed, a landing over the threshold is named as a finding, and a hotfix with no READY
    before its landing is counted and named, never measured as zero. The tracker is off: the ledgers alone."""
    rows = [
        ch(10, "2026-11-02T10:00:00Z", "ready"), ch(10, "2026-11-02T10:08:00Z", "batched", batch="solo-10"), ch(10, "2026-11-02T10:08:00Z", "landed", batch="solo-10"),
        ch(11, "2026-11-02T11:00:00Z", "ready"), ch(11, "2026-11-02T11:40:00Z", "landed", batch="solo-11"),
        ch(12, "2026-11-02T12:00:00Z", "ready"), ch(12, "2026-11-02T12:05:00Z", "landed", batch="t1"),   # a train member, not a hotfix
        ch(13, "2026-11-02T13:00:00Z", "landed", batch="solo-13"),                                         # a hotfix with no READY row
        ba("solo-10", "2026-11-02T10:08:00Z", [10], 400, "green"), ba("solo-11", "2026-11-02T11:40:00Z", [11], 2300, "green"),
        ba("t1", "2026-11-02T12:05:00Z", [12], 1800, "green"), ba("solo-13", "2026-11-02T13:00:00Z", [13], 500, "green"),
    ]
    log = tmp_path / "l.jsonl"
    log.write_text("".join(json.dumps(r) + "\n" for r in rows))
    events = tmp_path / "events.jsonl"
    events.write_text("".join(json.dumps(e) + "\n" for e in [
        lifecycle_event(10, "2026-11-02T10:08:30Z", "landed", "hotfix/10", "a" * 40),
        lifecycle_event(11, "2026-11-02T11:40:30Z", "landed", "hotfix/11", "b" * 40),
        lifecycle_event(12, "2026-11-02T12:05:30Z", "landed", "train/x", "c" * 40),
        lifecycle_event(13, "2026-11-02T13:00:30Z", "landed", "hotfix/13", "d" * 40),
    ]))
    r = report("--log", str(log), "--week", "2026-11-02", "--issue-events", str(events), "--tracker", "off", "--json")
    assert r.returncode == 0, r.stderr
    h = json.loads(r.stdout)["hotfix"]
    assert h["hotfixes"] == 3 and h["ready_to_landed_s"]["n"] == 2
    assert h["ready_to_landed_s"]["p50"] == pytest.approx((510 + 2430) / 2)   # 8m30s and 40m30s, to the lifecycle event's time
    assert h["worst"] == {"s": 2430.0, "issue": 11} and h["over_threshold"] == [11] and h["unmeasured"] == [13]
    assert h["threshold_s"] == 900
    text = report("--log", str(log), "--week", "2026-11-02", "--issue-events", str(events), "--tracker", "off").stdout
    line = next(l for l in text.splitlines() if l.startswith("- Hotfix READY to landed"))
    assert "median 24.5m, worst 40.5m (#11) (n=2; over 15.0m: 1 (#11), a finding); 1 with no READY before the landing: #13" in line


def test_week_report_hotfix_row_says_na_when_none_landed_and_is_absent_from_nothing(log):
    text = report("--log", str(log), "--week", "2026-11-02").stdout
    line = next(l for l in text.splitlines() if l.startswith("- Hotfix READY to landed"))
    assert line.startswith("- Hotfix READY to landed (the lane's lead time): n/a (no hotfix landed in the window;")
    assert "over 15.0m is a finding" in line


def test_hotfix_measure_uses_the_tracker_label_and_the_ready_naming_the_landed_branch():
    import importlib.util
    from datetime import datetime, timezone
    spec = importlib.util.spec_from_file_location("landing_report", REPORT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    ts = lambda s: datetime.fromisoformat(s.replace("Z", "+00:00")).astimezone(timezone.utc)
    ev = {
        # labelled hotfix on a feature branch: two READYs, the newest naming the landed branch is the one that counts
        20: [(ts("2026-11-02T09:00:00Z"), "ready", {}), (ts("2026-11-02T09:50:00Z"), "landed", {})],
        # a train member with no label: not a hotfix
        21: [(ts("2026-11-02T09:00:00Z"), "ready", {}), (ts("2026-11-02T09:30:00Z"), "landed", {})],
    }
    lifecycle = {20: [(ts("2026-11-02T09:50:10Z"), "feature/issue-20-fix", "e" * 40)], 21: [(ts("2026-11-02T09:30:10Z"), "train/y", "f" * 40)]}
    labels = {20: {"hotfix", "P0"}, 21: {"P2"}}
    readies = {20: [(ts("2026-11-02T09:00:00Z"), "READY `feature/issue-20-old` @ 111"), (ts("2026-11-02T09:41:10Z"), "READY `feature/issue-20-fix` @ 222"), (ts("2026-11-02T09:45:00Z"), "READY `feature/issue-20-other` @ 333")]}
    asked = []
    h = mod.hotfix_ready_to_landed(ev, lifecycle, None, None, label="hotfix", labels_of=lambda n: (asked.append(n), labels.get(n))[1], readies_of=lambda n: readies.get(n, []))
    assert sorted(asked) == [20, 21]
    assert h["hotfixes"] == 1 and h["ready_to_landed_s"]["n"] == 1 and h["ready_to_landed_s"]["p50"] == 540.0   # 09:41:10 to 09:50:10
    assert h["over_threshold"] == [] and h["worst"] == {"s": 540.0, "issue": 20}
    # the tracker unreachable (labels None) and no hotfix/ branch: nothing is a hotfix, nothing is measured as one
    h2 = mod.hotfix_ready_to_landed(ev, lifecycle, None, None, label="hotfix", labels_of=lambda n: None, readies_of=None)
    assert h2["hotfixes"] == 0 and h2["ready_to_landed_s"]["n"] == 0
