"""Tests for plugins/autocoder/scripts/stage-runner.py, driven with scripted stages.

Every stage here is a `sleep`, an `echo` or a `false`, so the tests own all timing and the
verdicts: independent stages overlap, declared and barrier ordering holds, a failing stage fails
the run with its failure block before the verdict, the memory budget serialises what does not fit,
a group's wrapper spans its inner stages, and the tree guard catches a mutation after the barrier.
"""

import json
import subprocess
import sys
import time
from pathlib import Path

import pytest

RUNNER = Path(__file__).parent.parent / "plugins/autocoder/scripts/stage-runner.py"


def run(tmp_path, stages, *extra, top=None, expect_rc=None, cwd=None):
    manifest = {"version": 1, "heartbeat_s": 0, **(top or {}), "stages": stages}
    mpath = tmp_path / "m.json"
    mpath.write_text(json.dumps(manifest))
    timings = tmp_path / "t.json"
    t0 = time.monotonic()
    p = subprocess.run([sys.executable, str(RUNNER), "--manifest", str(mpath), "--timings", str(timings),
                        "--cwd", str(cwd or tmp_path), *extra], capture_output=True, text=True, timeout=120)
    p.wall = time.monotonic() - t0
    p.timings = json.loads(timings.read_text()) if timings.exists() else None
    if expect_rc is not None:
        assert p.returncode == expect_rc, p.stdout + p.stderr
    return p


def st(name, cmd, **kw):
    return {"name": name, "cmd": cmd, **kw}


def test_independent_stages_overlap_and_serial_does_not(tmp_path):
    stages = [st("a", "sleep 1"), st("b", "sleep 1"), st("c", "sleep 1")]
    par = run(tmp_path, stages, expect_rc=0)
    assert par.wall < 2.3, par.stdout
    ser = run(tmp_path, stages, "--serial", expect_rc=0)
    assert ser.wall >= 3.0, ser.stdout
    assert par.stdout.rstrip().splitlines()[-1].startswith("stage runner: PASS")


def test_needs_orders_a_stage_after_its_prerequisite(tmp_path):
    p = run(tmp_path, [st("a", "sleep 0.6"), st("b", "true", needs=["a"]), st("c", "sleep 0.1")], expect_rc=0)
    s = p.timings["stages"]
    assert s["b"]["start_s"] >= s["a"]["start_s"] + s["a"]["seconds"] - 0.1
    assert s["c"]["start_s"] < s["a"]["start_s"] + s["a"]["seconds"]  # independent c did not wait


def test_exclusive_stage_is_a_barrier(tmp_path):
    p = run(tmp_path, [st("a", "sleep 0.5"), st("b", "sleep 0.5"),
                       st("barrier", "sleep 0.3", exclusive=True),
                       st("c", "sleep 0.5"), st("d", "sleep 0.5")], expect_rc=0)
    s = p.timings["stages"]
    end = lambda n: s[n]["start_s"] + s[n]["seconds"]  # noqa: E731
    assert s["barrier"]["start_s"] >= max(end("a"), end("b")) - 0.1
    assert min(s["c"]["start_s"], s["d"]["start_s"]) >= end("barrier") - 0.1
    assert abs(s["c"]["start_s"] - s["d"]["start_s"]) < 0.3  # c and d still overlap


def test_concurrency_limit_is_respected(tmp_path):
    p = run(tmp_path, [st(n, "sleep 0.5") for n in "abcd"], "--concurrency", "2", expect_rc=0)
    assert p.wall >= 1.0


def test_memory_budget_serialises_stages_that_do_not_fit(tmp_path):
    fits = run(tmp_path, [st("a", "sleep 0.6", memory_mib=400), st("b", "sleep 0.6", memory_mib=400)],
               top={"memory_budget_mib": 1000}, expect_rc=0)
    assert fits.wall < 1.15
    tight = run(tmp_path, [st("a", "sleep 0.6", memory_mib=600), st("b", "sleep 0.6", memory_mib=600)],
                top={"memory_budget_mib": 1000}, expect_rc=0)
    assert tight.wall >= 1.2


def test_stage_larger_than_budget_still_runs_alone(tmp_path):
    p = run(tmp_path, [st("big", "true", memory_mib=5000)], top={"memory_budget_mib": 1000}, expect_rc=0)
    assert p.timings["stages"]["big"]["status"] == "pass"


def test_stage_sees_its_declared_memory_and_manifest_env(tmp_path):
    p = run(tmp_path, [st("a", 'echo "mem=$AUTOCODER_STAGE_MEMORY_MIB name=$AUTOCODER_STAGE_NAME x=$X"', memory_mib=77)],
            top={"env": {"X": "{run_dir}/f"}}, expect_rc=0)
    assert "mem=77 name=a x=" in p.stdout and "/f" in p.stdout


def test_break_proof_failing_stage_fails_the_run_with_its_output_and_verdict_last(tmp_path):
    p = run(tmp_path, [st("ok", "echo fine"),
                       st("boom", "for i in $(seq 1 40); do echo line$i; done; echo BADTHING; exit 3", tail=5)],
            expect_rc=1)
    lines = p.stdout.splitlines()
    assert lines[-1].startswith("stage runner: FAIL boom (rc=3)")
    assert "BADTHING" in p.stdout and "line1\n" not in p.stdout  # tail only: bounded
    header = next(i for i, ln in enumerate(lines) if ln.startswith("── stage boom: FAIL rc=3"))
    summary = next(i for i, ln in enumerate(lines) if ln.startswith("==="))
    assert header < lines.index("BADTHING") < summary < len(lines) - 1  # failure block, summary, verdict
    assert p.timings["verdict"] == "fail"


def test_failure_cancels_running_stages_and_skips_dependents(tmp_path):
    p = run(tmp_path, [st("slow", "sleep 30"), st("bad", "sleep 0.3; exit 1"),
                       st("after", "true", needs=["bad"]), st("later", "true", needs=["after"])], expect_rc=1)
    assert p.wall < 10
    s = p.timings["stages"]
    assert s["slow"]["status"] == "cancelled" and s["bad"]["status"] == "fail"
    assert s["after"]["status"] == "skipped" and s["later"]["status"] == "skipped"
    assert "── stage slow: CANCELLED" in p.stdout


def test_on_failure_finish_lets_running_stages_end(tmp_path):
    p = run(tmp_path, [st("slow", "sleep 1; echo done-slow"), st("bad", "exit 1"),
                       st("never", "true", needs=["bad"])], top={"on_failure": "finish"}, expect_rc=1)
    assert p.timings["stages"]["slow"]["status"] == "pass" and "done-slow" in p.stdout


def test_output_is_in_manifest_order_whatever_finishes_first(tmp_path):
    p = run(tmp_path, [st("first", "sleep 0.8; echo FIRST"), st("second", "echo SECOND")], expect_rc=0)
    assert p.stdout.index("FIRST") < p.stdout.index("SECOND")


def test_pass_block_keeps_only_the_tail(tmp_path):
    p = run(tmp_path, [st("noisy", "seq 1 100", tail=3)], expect_rc=0)
    assert "\n98\n99\n100\n" in p.stdout and "\n97\n" not in p.stdout


def test_stage_pipefail_is_on(tmp_path):
    run(tmp_path, [st("p", "false | cat")], expect_rc=1)


def test_a_stage_that_cannot_start_is_a_failure(tmp_path):
    p = run(tmp_path, [st("x", "exit 127")], expect_rc=1)
    assert "rc=127" in p.stdout


def test_timeout_kills_a_dead_stage(tmp_path):
    p = run(tmp_path, [st("hang", "sleep 60", timeout_s=1)], expect_rc=1)
    assert p.wall < 10 and "timeout" in p.stdout


def test_heartbeat_prints_while_ordered_output_waits(tmp_path):
    p = run(tmp_path, [st("slow", "sleep 2.5")], top={"heartbeat_s": 1}, expect_rc=0)
    assert "… still running: slow" in p.stdout


def test_group_wrapper_spans_inner_stages_and_inner_stages_overlap(tmp_path):
    group = {"name": "db", "wrapper": "env WRAPPED=yes bash -c {inner}",
             "stages": [st("t1", 'echo "t1 sees $WRAPPED"; sleep 0.7'), st("t2", 'echo "t2 sees $WRAPPED"; sleep 0.7')]}
    p = run(tmp_path, [group], expect_rc=0)
    assert "t1 sees yes" in p.stdout and "t2 sees yes" in p.stdout
    assert p.wall < 1.6
    assert "stage runner [db]: PASS" in p.stdout


def test_group_failure_fails_the_outer_run_with_the_inner_block(tmp_path):
    group = {"name": "db", "wrapper": "bash -c {inner}", "stages": [st("t", "echo INNER-BAD; exit 4")]}
    p = run(tmp_path, [group], expect_rc=1)
    assert "INNER-BAD" in p.stdout and p.stdout.splitlines()[-1].startswith("stage runner: FAIL db")


def test_wrapper_that_fails_before_running_inner_fails_the_group(tmp_path):
    group = {"name": "db", "wrapper": "false {inner}", "stages": [st("t", "true")]}
    run(tmp_path, [group], expect_rc=1)


def _git_repo(path: Path) -> None:
    for cmd in (["init", "-q"], ["config", "user.email", "t@example.com"], ["config", "user.name", "t"]):
        subprocess.run(["git", "-C", str(path), *cmd], check=True)
    (path / "tracked.txt").write_text("one\n")
    subprocess.run(["git", "-C", str(path), "add", "tracked.txt"], check=True)
    subprocess.run(["git", "-C", str(path), "commit", "-qm", "init"], check=True)


def test_tree_guard_passes_when_the_mutation_is_in_an_exclusive_stage(tmp_path):
    repo = tmp_path / "r"; repo.mkdir(); _git_repo(repo)
    p = run(tmp_path, [st("regen", "echo two > tracked.txt", exclusive=True), st("a", "true"), st("b", "true")],
            top={"tree_guard": True}, cwd=repo, expect_rc=0)
    assert p.timings["verdict"] == "pass"


def test_tree_guard_fails_when_a_stage_after_the_barrier_changes_the_tree(tmp_path):
    repo = tmp_path / "r"; repo.mkdir(); _git_repo(repo)
    p = run(tmp_path, [st("barrier", "true", exclusive=True), st("sneaky", "echo two > tracked.txt")],
            top={"tree_guard": True}, cwd=repo, expect_rc=1)
    assert "tree guard FAILED" in p.stdout and "declared exclusive" in p.stdout
    assert p.stdout.splitlines()[-1].startswith("stage runner: FAIL") and "tree guard" in p.stdout.splitlines()[-1]


def test_tree_guard_catches_a_commit_by_a_stage(tmp_path):
    repo = tmp_path / "r"; repo.mkdir(); _git_repo(repo)
    p = run(tmp_path, [st("c", "echo two > tracked.txt && git commit -qam x")], top={"tree_guard": True},
            cwd=repo, expect_rc=1)
    assert "tree guard FAILED" in p.stdout


@pytest.mark.parametrize("manifest,needle", [
    ({"version": 1, "stages": [st("a", "true"), st("a", "true")]}, "duplicate"),
    ({"version": 1, "stages": [st("a", "true", needs=["zzz"])]}, "not a stage here"),
    ({"version": 1, "stages": [st("a", "true", needs=["b"]), st("b", "true", needs=["a"])]}, "cycle"),
    ({"version": 1, "stages": [st("a", "true", needs=["b"]), st("b", "true", exclusive=True)]}, "cycle"),
    ({"version": 1, "stages": [st("a", "true", tial=3)]}, "unknown stage key"),
    ({"version": 1, "bogus": 1, "stages": [st("a", "true")]}, "unknown key"),
    ({"version": 2, "stages": [st("a", "true")]}, "version must be 1"),
    ({"version": 1, "stages": []}, "non-empty"),
    ({"version": 1, "stages": [{"name": "g", "wrapper": "no inner", "stages": [st("a", "true")]}]}, "{inner}"),
    ({"version": 1, "stages": [{"name": "bad name", "cmd": "true"}]}, "name"),
])
def test_manifest_errors_exit_2_before_anything_runs(tmp_path, manifest, needle):
    (tmp_path / "m.json").write_text(json.dumps(manifest))
    p = subprocess.run([sys.executable, str(RUNNER), "--manifest", str(tmp_path / "m.json")],
                       capture_output=True, text=True)
    assert p.returncode == 2 and needle in p.stderr, p.stderr


def test_missing_manifest_exits_2(tmp_path):
    p = subprocess.run([sys.executable, str(RUNNER), "--manifest", str(tmp_path / "nope.json")], capture_output=True, text=True)
    assert p.returncode == 2 and "cannot read manifest" in p.stderr


def test_only_runs_the_named_stage_with_its_prerequisites(tmp_path):
    p = run(tmp_path, [st("a", "echo A"), st("b", "echo B", needs=["a"]), st("c", "echo C")], "--only", "b", expect_rc=0)
    assert "A" in p.stdout and "B" in p.stdout and "── stage c" not in p.stdout


def test_list_commands_includes_group_wrapper_and_inner_commands(tmp_path):
    m = {"version": 1, "stages": [st("a", "cmd-a"), {"name": "g", "wrapper": "wrap {inner}", "stages": [st("i", "cmd-inner")]}]}
    (tmp_path / "m.json").write_text(json.dumps(m))
    p = subprocess.run([sys.executable, str(RUNNER), "--manifest", str(tmp_path / "m.json"), "--list-commands"],
                       capture_output=True, text=True)
    assert p.stdout.split("\n")[:3] == ["cmd-a", "wrap {inner}", "cmd-inner"]


def test_stage_args_turns_timings_into_landing_batch_words(tmp_path):
    p = run(tmp_path, [st("a", "sleep 0.2"), st("b", "true")], expect_rc=0)
    q = subprocess.run([sys.executable, str(RUNNER), "--stage-args", str(tmp_path / "t.json")], capture_output=True, text=True)
    assert q.stdout.split() == ["--stage", "a=0", "--stage", "b=0"]


def test_conflicting_stages_never_overlap(tmp_path):
    p = run(tmp_path, [st("a", "sleep 0.6", conflicts=["b"]), st("b", "sleep 0.6"), st("c", "sleep 0.6")], expect_rc=0)
    s = p.timings["stages"]
    a_end, b_end = s["a"]["start_s"] + s["a"]["seconds"], s["b"]["start_s"] + s["b"]["seconds"]
    assert s["b"]["start_s"] >= a_end - 0.1 or s["a"]["start_s"] >= b_end - 0.1
    assert abs(s["c"]["start_s"] - min(s["a"]["start_s"], s["b"]["start_s"])) < 0.3  # c overlaps one of them


def test_conflict_with_an_unknown_stage_is_a_manifest_error(tmp_path):
    (tmp_path / "m.json").write_text(json.dumps({"version": 1, "stages": [st("a", "true", conflicts=["zz"])]}))
    p = subprocess.run([sys.executable, str(RUNNER), "--manifest", str(tmp_path / "m.json")], capture_output=True, text=True)
    assert p.returncode == 2 and "conflicts with" in p.stderr


def test_peak_memory_of_a_stage_is_measured(tmp_path):
    p = run(tmp_path, [st("hog", "python3 -c \"b = bytearray(150*1024*1024); import time; time.sleep(2.2)\"")], expect_rc=0)
    assert p.timings["stages"]["hog"]["peak_rss_mib"] >= 100
    assert "peak" in p.stdout


def test_peak_memory_counts_a_nested_runners_stages(tmp_path):
    """A group's inner stages run in sessions of their own; the group's peak must still include them."""
    inner = st("hog", "python3 -c \"b = bytearray(150*1024*1024); import time; time.sleep(2.2)\"")
    p = run(tmp_path, [{"name": "g", "wrapper": "bash -c {inner}", "stages": [inner]}], expect_rc=0)
    assert p.timings["stages"]["g"]["peak_rss_mib"] >= 100


def test_default_tail_applies_to_stages_without_their_own(tmp_path):
    p = run(tmp_path, [st("a", "seq 1 100"), st("b", "seq 1 100", tail=2)], top={"default_tail": 4}, expect_rc=0)
    assert "\n97\n98\n99\n100\n" in p.stdout and "\n99\n100\n" in p.stdout and "\n96\n" not in p.stdout
