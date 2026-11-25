"""trace-build.py: one trace per issue attempt, from fixture ledgers and transcripts (#395)."""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "plugins" / "autocoder" / "scripts" / "trace-build.py"
FIXTURES = ROOT / "tests" / "fixtures" / "traces"
REPO_A, REPO_B = "repo-a-1234abcd", "repo-b-5678efgh"
LEDGER_ARGS = ["--issue-events", str(FIXTURES / "issue-events.jsonl"),
               "--merge-events", str(FIXTURES / "merge-events.jsonl"),
               "--landing-timings", str(FIXTURES / "landing-timings.jsonl"),
               "--gate-log", str(FIXTURES / "gate.jsonl")]


def run(tmp_path, *args, ledgers=LEDGER_ARGS, env=None):
    # TZ=UTC: a transcript name's HHMMSS is local time, and the fixtures are written in UTC.
    e = {k: v for k, v in os.environ.items() if k != "AUTOCODER_TRACES"}
    e.update({"XDG_STATE_HOME": str(tmp_path / "state"), "TZ": "UTC", **(env or {})})
    return subprocess.run([sys.executable, str(SCRIPT), *ledgers, *args], capture_output=True, text=True, env=e)


def build(tmp_path, *args):
    out = tmp_path / "traces.jsonl"
    r = run(tmp_path, "--log-dir", str(FIXTURES), "--comments-dir", str(FIXTURES / "comments"),
            "--out", str(out), *args)
    assert r.returncode == 0, r.stderr
    return {t["trace_id"]: t for t in map(json.loads, out.read_text().splitlines())}


@pytest.fixture(scope="module")
def traces(tmp_path_factory):
    return build(tmp_path_factory.mktemp("build"))


def a(issue, n=1):
    return f"{REPO_A}:{issue}:{n}"


def gate_detail(t):
    return [(g["attempt"], g["outcome"], g["tests_failed"], g["conflict_files"], g["red_base"], g["escalated"])
            for g in t["gates"]]


# trace id: outcome, ended, next_attempt, gates, returned causes, tick id
SCENARIOS = {
    a(10): ("landed", "2026-11-20T10:12:30Z", None,
            [(1, "landed", [], [], False, False)], [], "session1-1732095300000"),
    a(11): ("landed", "2026-11-20T11:22:30Z", None,
            [(1, "gate-failed", ["tests/test_x.sh"], [], False, False), (2, "landed", [], [], False, False)],
            ["defect"], "session2-1732098900000"),
    a(12): ("escalated", "2026-11-20T12:12:30Z", None,
            [(1, "conflict", [], ["src/file.sh"], False, True)], ["conflict"], "session3-1732102500000"),
    a(13): ("open", None, None, [(n, "conflict", [], ["src/a.sh"], False, False) for n in (1, 2, 3)],
            ["conflict"] * 3, None),
    a(14, 1): ("released", "2026-11-20T14:05:00Z", "2026-11-20T14:10:00Z", [], [], None),
    a(14, 2): ("open", None, None, [], [], None),
    a(15): ("landed", "2026-11-20T15:12:30Z", None, [(1, "landed", [], [], False, False)], [], None),
    a(16): ("landed", "2026-11-20T16:12:30Z", None, [(1, "landed", [], [], False, False)], [], None),
    a(17): ("open", None, None, [(1, "gate-failed", ["tests/test_y.sh"], [], True, False)],
            ["red-integration"], "session4-1732120320000"),
    a(18): ("landed", "2026-11-20T18:07:30Z", None,
            [(1, "conflict", [], ["src/b.sh"], False, False), (2, "landed", [], [], False, False)], [], None),
    a(19): ("abandoned", "2026-11-20T20:05:00Z", None, [], [], None),
    f"{REPO_B}:100:1": ("landed", "2026-11-20T19:12:30Z", None, [(1, "landed", [], [], False, False)], [], None),
}


def test_one_trace_per_attempt(traces):
    assert sorted(traces) == sorted(SCENARIOS)


@pytest.mark.parametrize("trace_id", sorted(SCENARIOS))
def test_scenario(traces, trace_id):
    outcome, ended, next_attempt, gates, causes, tick = SCENARIOS[trace_id]
    t = traces[trace_id]
    assert t["outcome"] == outcome
    assert t["ended"] == ended
    assert t["next_attempt"] == next_attempt
    assert gate_detail(t) == gates
    assert [r["cause"] for r in t["returned"]] == causes
    assert (t["tick"] or {}).get("tick_id") == tick


def test_implicit_attempt_starts_at_first_event(traces):
    t = traces[a(18)]
    assert t["worker"] is None and t["branch"] is None
    assert t["started"] == "2026-11-20T18:00:00Z"
    assert [s["kind"] for s in t["steps"]] == ["first-commit", "precheck", "gate-queued", "gate-start", "gate-end", "landed"]


def test_gate_takes_reason_from_gate_end_and_detail_from_merge_row(traces):
    gate = traces[a(12)]["gates"][0]
    assert gate["reason"] == "src/file.sh"
    assert gate["duration_s"] == 30


def test_no_merge_attempt_steps(traces):
    assert not [s for t in traces.values() for s in t["steps"] if s["source"] == "merge-events"]


def test_reclaim_keeps_worker_and_steps_per_attempt(traces):
    first, second = traces[a(14, 1)], traces[a(14, 2)]
    assert (first["worker"], [s["kind"] for s in first["steps"]]) == ("w1", ["claimed", "released"])
    assert (second["worker"], [s["kind"] for s in second["steps"]]) == ("w2", ["claimed"])


def test_session_counts_errors_per_tool(traces):
    s = traces[a(12)]["session"]
    assert Path(s["path"]).name == "worker-1002-fix-12-120000.jsonl"
    assert (s["model"], s["num_turns"], s["duration_ms"], s["cost_usd"], s["is_error"]) == ("model-b", 8, 60000, 1.2, False)
    assert s["tools"] == {"calls": 12, "errors": 4, "by_name": {
        "Bash": {"calls": 5, "errors": 4}, "Edit": {"calls": 1, "errors": 0}, "Read": {"calls": 6, "errors": 0}}}


def test_in_flight_session_reports_tools_so_far(traces):
    s = traces[a(13)]["session"]
    assert (s["num_turns"], s["duration_ms"], s["cost_usd"], s["is_error"]) == (None, None, None, None)
    assert s["tools"]["calls"] == 3 and s["tools"]["errors"] == 1 and s["tools"]["by_name"]["Edit"]["errors"] == 1


def test_sessions_join_only_their_own_attempt(traces):
    joined = {tid: Path(t["session"]["path"]).name for tid, t in traces.items() if t["session"]}
    assert joined == {
        a(10): "worker-1001-fix-10-100000.jsonl", a(11): "worker-1001-fix-11-110000.jsonl",
        a(12): "worker-1002-fix-12-120000.jsonl", a(13): "worker-1003-fix-13-130000.jsonl",
        a(17): "worker-1001-fix-17-170000.jsonl", a(19): "worker-1001-fix-19-200000.jsonl"}
    assert traces[a(19)]["session"]["is_error"] is True


def test_transcript_outside_the_slack_does_not_join(tmp_path):
    traces = build(tmp_path, "--slack", "0", "--since", "2026-11-20T12:00:00Z", "--until", "2026-11-20T12:00:01Z")
    assert traces[a(12)]["session"] is not None
    late = tmp_path / "logs"
    late.mkdir()
    (late / "worker-1002-fix-12-150000.jsonl").write_text((FIXTURES / "worker-1002-fix-12-120000.jsonl").read_text())
    r = run(tmp_path, "--log-dir", str(late), "--slack", "30", "--out", "-")
    assert json.loads(next(line for line in r.stdout.splitlines() if f'"{a(12)}"' in line))["session"] is None


def test_transcript_timestamp_field_wins_over_name(tmp_path):
    logs = tmp_path / "logs"
    logs.mkdir()
    lines = (FIXTURES / "worker-1002-fix-12-120000.jsonl").read_text().splitlines()
    stamped = [json.dumps({**json.loads(lines[0]), "timestamp": "2026-11-20T14:00:00Z"})] + lines[1:]
    (logs / "worker-1002-fix-12-120000.jsonl").write_text("\n".join(stamped) + "\n")
    r = run(tmp_path, "--log-dir", str(logs), "--slack", "30", "--out", "-")
    t12 = json.loads(next(line for line in r.stdout.splitlines() if f'"{a(12)}"' in line))
    assert t12["session"] is None


@pytest.mark.parametrize("trace_id,review", [
    (a(10), ("reviewed", "pass", 1, 1, 0)),
    (a(11), ("reviewed", "pass", 2, 0, 1)),
    (a(15), ("no record", None, None, None, None)),
    (a(18), ("skipped", None, None, None, None)),
    (f"{REPO_B}:100:1", ("reviewed", "fail", 1, 0, 0)),
])
def test_review_record(traces, trace_id, review):
    rv = traces[trace_id]["review"]
    findings, resolutions = rv.get("findings") or {}, rv.get("resolutions") or {}
    assert (rv["status"], rv.get("verdict"), findings.get("important"), findings.get("nit"),
            resolutions.get("left")) == review


def test_no_comments_dir_means_no_review(tmp_path):
    r = run(tmp_path, "--log-dir", str(tmp_path), "--out", "-")
    assert {json.loads(line)["review"] is None for line in r.stdout.splitlines()} == {True}


def test_repo_id_keeps_one_repository(tmp_path):
    traces = build(tmp_path, "--repo-id", REPO_B)
    assert list(traces) == [f"{REPO_B}:100:1"]


def test_same_issue_number_in_two_repos_is_two_traces(tmp_path):
    events = tmp_path / "issue-events.jsonl"
    rows = [{"v": 1, "ts": f"2026-11-20T0{h}:00:00Z", "repo": repo, "issue": 7, "worker": "w", "branch": "b",
             "event": "claimed", "detail": {}} for h, repo in ((1, REPO_A), (2, REPO_B))]
    events.write_text("".join(json.dumps(r) + "\n" for r in rows))
    r = run(tmp_path, "--out", "-", ledgers=["--issue-events", str(events), "--merge-events", str(tmp_path / "x"),
                                             "--landing-timings", str(tmp_path / "x"), "--gate-log", str(tmp_path / "x")])
    got = {t["trace_id"]: (t["next_attempt"], t["outcome"]) for t in map(json.loads, r.stdout.splitlines())}
    assert got == {f"{REPO_A}:7:1": (None, "open"), f"{REPO_B}:7:1": (None, "open")}


def test_since_and_until_filter_by_start(tmp_path):
    traces = build(tmp_path, "--since", "2026-11-20T14:00:00Z", "--until", "2026-11-20T16:00:00Z")
    assert sorted(traces) == [a(14, 1), a(14, 2), a(15)]
    assert build(tmp_path, "--since", "2026-11-21") == {}
    assert len(build(tmp_path, "--until", "2026-11-21")) == len(SCENARIOS)


def test_malformed_lines_counted_per_ledger(tmp_path):
    r = run(tmp_path, "--log-dir", str(tmp_path), "--out", str(tmp_path / "t.jsonl"))
    assert r.returncode == 0
    lines = [line for line in r.stderr.splitlines() if "malformed" in line]
    assert len(lines) == 1
    for ledger in ("issue-events 1", "merge-events 1", "landing-timings 1", "gate-log 1"):
        assert ledger in lines[0]


def test_rerun_converges(tmp_path):
    out = tmp_path / "traces.jsonl"
    args = ("--log-dir", str(FIXTURES), "--comments-dir", str(FIXTURES / "comments"), "--out", str(out))
    run(tmp_path, *args)
    first = out.read_bytes()
    run(tmp_path, *args)
    assert out.read_bytes() == first and first


def test_missing_ledgers_give_an_empty_file(tmp_path):
    out = tmp_path / "traces.jsonl"
    out.write_text("stale\n")
    missing = ["--issue-events", str(tmp_path / "none-1"), "--merge-events", str(tmp_path / "none-2"),
               "--landing-timings", str(tmp_path / "none-3"), "--gate-log", str(tmp_path / "none-4")]
    r = run(tmp_path, "--out", str(out), ledgers=missing)
    assert r.returncode == 0, r.stderr
    assert out.read_text() == ""


def test_out_dash_prints_to_stdout(tmp_path):
    r = run(tmp_path, "--log-dir", str(tmp_path), "--out", "-")
    assert len(r.stdout.splitlines()) == len(SCENARIOS)
    assert not (tmp_path / "state").exists()


def test_default_out_is_beside_the_ledgers_and_overridable(tmp_path):
    run(tmp_path, "--log-dir", str(tmp_path))
    assert len((tmp_path / "state" / "autocoder" / "traces.jsonl").read_text().splitlines()) == len(SCENARIOS)
    override = tmp_path / "elsewhere.jsonl"
    run(tmp_path, "--log-dir", str(tmp_path), env={"AUTOCODER_TRACES": str(override)})
    assert override.exists()
