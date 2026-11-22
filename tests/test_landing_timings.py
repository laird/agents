"""landing-timings.py (writer) and landing-report.py (waste-first report, history mode)."""

from __future__ import annotations

import json
import os
import stat
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pytest

SCRIPTS = Path(__file__).resolve().parent.parent / "plugins" / "autocoder" / "scripts"
WRITER = SCRIPTS / "landing-timings.py"
REPORT = SCRIPTS / "landing-report.py"


def write(log, *args):
    env = {k: v for k, v in os.environ.items() if k != "AUTOCODER_LANDING_REPO"}
    return subprocess.run([sys.executable, str(WRITER), "--log-path", str(log), *args], capture_output=True, text=True, env=env)


def report(*args, env=None):
    e = {**os.environ, **(env or {})}
    r = subprocess.run([sys.executable, str(REPORT), *args], capture_output=True, text=True, env=e)
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
