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
    return subprocess.run([sys.executable, str(WRITER), "--log-path", str(log), *args], capture_output=True, text=True)


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
    assert ch == {"v": 1, "ts": "2026-11-01T10:00:00Z", "kind": "change", "issue": 7, "event": "ready", "batch": None, "cause": None}
    assert ba["gate_s"] == 30.5 and ba["stages"] == {"build": 10.0, "test": 20.5} and ba["members"] == [7, 8]
    assert ba["assembly_s"] is None and ba["discarded_gate_s"] is None and ba["push_rejected"] is None


@pytest.mark.parametrize("args,needle", [
    (["change", "--issue", "1", "--event", "returned"], "needs --cause"),
    (["change", "--issue", "1", "--event", "ready", "--cause", "defect"], "belongs to --event returned"),
    (["change", "--issue", "1", "--event", "ready", "--batch", "has space"], "not an id"),
    (["change", "--issue", "1", "--event", "ready", "--ts", "yesterday"], "--ts"),
    (["batch", "--batch", "b", "--members", "1", "--verdict", "red"], "needs --cause"),
    (["batch", "--batch", "b", "--members", ",", "--verdict", "green"], "names no change"),
    (["batch", "--batch", "b", "--members", "1", "--stage", "build"], "NAME=SECONDS"),
    (["batch", "--batch", "b", "--members", "1", "--gate-s", "-3"], "negative"),
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


def test_report_window_and_text(log):
    out = report("--log", str(log), "--since", "2026-11-03").stdout
    assert "Gate-minutes thrown away: 0s of 30.0m = 0%" in out
    assert out.index("## Waste") < out.index("## Time") < out.index("## Capacity")


def test_report_says_na_never_zero_when_not_measured(tmp_path):
    p = tmp_path / "l.jsonl"
    p.write_text(json.dumps(ch(9, "2026-11-01T00:00:00Z", "landed")) + "\n")
    out = report("--log", str(p)).stdout
    assert "Gate-minutes thrown away: n/a" in out and "Rebases per landed change: n/a" in out
    assert "Build (claim to READY): n/a" in out


def test_report_bad_date_exits_2(log):
    r = report("--log", str(log), "--since", "last tuesday")
    assert r.returncode == 2 and "cannot read --since" in r.stderr


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
