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
    ("dev does not rise", baseline(dev_before=(2, 2), dev_after=(2, 2)), 1, "reject dev pass rate did not rise (2/2 -> 2/2)"),
    ("dev falls", baseline(dev_before=(2, 2), dev_after=(1, 2)), 1, "reject dev pass rate did not rise (2/2 -> 1/2)"),
    ("held-out falls", baseline(ho_before=(2, 2), ho_after=(1, 2)), 1, "reject heldout pass rate fell (2/2 -> 1/2)"),
    ("held-out below 1 stays put", baseline(ho_before=(0, 2), ho_after=(0, 2)), 1,
     "reject heldout pass rate did not rise from below 1 (0/2 -> 0/2)"),
    ("equal rates, fewer tool calls", baseline(dev_before=(2, 2), dev_after=(2, 2), ho_before=(2, 2), ho_after=(2, 2), calls_before=40, calls_after=25), 0, "accept"),
    ("equal rates, more tool calls", baseline(dev_before=(2, 2), dev_after=(2, 2), ho_before=(2, 2), ho_after=(2, 2), calls_before=25, calls_after=40), 1,
     "reject pass rates unchanged and mean tool calls did not fall (25.0 -> 40.0)"),
    ("equal rates, no tool calls recorded", baseline(dev_before=(2, 2), dev_after=(2, 2), ho_before=(2, 2), ho_after=(2, 2)), 1,
     "reject pass rates unchanged (dev 2/2 -> 2/2, heldout 2/2 -> 2/2) and tool calls not recorded"),
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
        "finding": "gate-red-suite:tests/test_x.sh", "comparison": None,
        "before": BEFORE, "after": AFTER,
        "dev": {"before": [1, 2], "after": [2, 2]}, "heldout": {"before": [1, 2], "after": [2, 2]},
        "manifest": {"before": {"dev": None, "heldout": None}, "after": {"dev": None, "heldout": None}},
        "grader": {"before": None, "after": None},
        "worker": {"before": "fake", "after": "fake"},
        "settings": {"before": {"dev": None, "heldout": None}, "after": {"dev": None, "heldout": None}},
        "repeats": {"before": {"dev": {"dev-1": 2}, "heldout": {"ho-1": 2}},
                    "after": {"dev": {"dev-1": 2}, "heldout": {"ho-1": 2}}},
        "cases": {
            "dev": {"dev-1": {"before": [1, 2], "after": [2, 2], "status": "improved"}},
            "heldout": {"ho-1": {"before": [1, 2], "after": [2, 2], "status": "improved"}},
        },
        "protected_regressions": [],
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


def stamp(rows, comparison, settings):
    stamped = []
    for row in rows:
        copied = dict(row)
        copied["comparison"] = comparison
        copied["manifest"] = settings["manifest"]
        copied["grader"] = settings["grader"]
        copied["worker"] = settings["worker"]
        copied["settings"] = dict(settings)
        stamped.append(copied)
    return stamped


DEV = {"manifest": "mani-dev", "grader": "grade-1", "worker": "fake", "repeat": 2, "timeout": 60}
HELD = {**DEV, "manifest": "mani-ho"}


def matched(comparison="cmp-a", dev_before=(1, 2), dev_after=(2, 2), ho_before=(1, 2), ho_after=(2, 2)):
    """One comparison's rows: dev and held-out each carry their own manifest."""
    dev = (stamp(runs(BEFORE, "dev", "dev-1", *dev_before), comparison, DEV)
           + stamp(runs(AFTER, "dev", "dev-1", *dev_after), comparison, DEV))
    held = (stamp(runs(BEFORE, "heldout", "ho-1", *ho_before), comparison, HELD)
            + stamp(runs(AFTER, "heldout", "ho-1", *ho_after), comparison, HELD))
    return dev + held


def test_rows_from_another_comparison_do_not_move_the_verdict(tmp_path):
    # Same harness shas, a later run. Scoped, it is ignored and the verdict accepts.
    # Counted, the pooled rows no longer match the planned repeat, so they cannot accept.
    poison = stamp(runs(BEFORE, "dev", "dev-1", 2, 2), "cmp-b", DEV) + stamp(runs(AFTER, "dev", "dev-1", 0, 2), "cmp-b", DEV)
    poison += stamp(runs(BEFORE, "heldout", "ho-1", 2, 2), "cmp-b", HELD) + stamp(runs(AFTER, "heldout", "ho-1", 0, 2), "cmp-b", HELD)
    rows = matched() + poison
    scoped = decide(tmp_path, rows, "--comparison", "cmp-a")
    assert (scoped.returncode, scoped.stdout.strip()) == (0, "accept")
    mixed = decide(tmp_path, rows)
    assert mixed.returncode == 3
    assert "dev-1 (4 vs planned 2)" in mixed.stdout
    recorded = decisions(tmp_path)[0]
    assert recorded["comparison"] == "cmp-a"
    assert recorded["manifest"] == {"before": {"dev": "mani-dev", "heldout": "mani-ho"},
                                    "after": {"dev": "mani-dev", "heldout": "mani-ho"}}
    assert recorded["grader"] == {"before": "grade-1", "after": "grade-1"}
    assert recorded["worker"] == {"before": "fake", "after": "fake"}
    assert recorded["settings"]["before"]["dev"]["repeat"] == 2
    assert recorded["repeats"] == {"before": {"dev": {"dev-1": 2}, "heldout": {"ho-1": 2}},
                                   "after": {"dev": {"dev-1": 2}, "heldout": {"ho-1": 2}}}


def test_unmatched_repeats_are_inconclusive(tmp_path):
    rows = matched(dev_after=(3, 3), ho_after=(3, 3))
    verdict = decide(tmp_path, rows, "--comparison", "cmp-a")
    assert verdict.returncode == 3
    assert verdict.stdout.strip().startswith("inconclusive dev case(s) with unmatched repeats: dev-1 (2 vs 3)")


def test_different_settings_are_inconclusive(tmp_path):
    rows = matched()
    for row in rows:
        if row["harness"]["sha"] == AFTER:
            row["settings"] = {**row["settings"], "worker": "other-model"}
            row["grader"] = "grade-2"
    verdict = decide(tmp_path, rows, "--comparison", "cmp-a")
    assert verdict.returncode == 3
    assert "different dev settings" in verdict.stdout


def test_a_missing_stamped_side_is_fewer_runs_not_different_settings(tmp_path):
    rows = [r for r in matched() if not (r["split"] == "heldout" and r["harness"]["sha"] == AFTER)]
    verdict = decide(tmp_path, rows, "--comparison", "cmp-a")
    assert verdict.returncode == 3
    assert verdict.stdout.strip().startswith("inconclusive heldout case(s) with fewer than 2 runs after: ho-1")


def test_a_second_batch_past_the_planned_repeat_is_not_pooled(tmp_path):
    verdict = decide(tmp_path, matched() + matched(), "--comparison", "cmp-a")
    assert verdict.returncode == 3
    assert verdict.stdout.strip().startswith(
        "inconclusive dev case(s) whose runs do not match the planned repeats before: dev-1 (4 vs planned 2)")


def test_a_whole_float_timeout_matches_an_int(tmp_path):
    rows = matched()
    for row in rows:
        if row["harness"]["sha"] == AFTER:
            row["settings"] = {**row["settings"], "timeout": 60.0}
    verdict = decide(tmp_path, rows, "--comparison", "cmp-a")
    assert (verdict.returncode, verdict.stdout.strip()) == (0, "accept")


def test_untagged_rows_stay_comparable_beside_stamped_rows_for_other_shas(tmp_path):
    other = "dddd4444"
    stamped = (stamp(runs(other, "dev", "dev-9", 0, 2), "cmp-z", DEV)
               + stamp(runs(other, "heldout", "ho-9", 0, 2), "cmp-z", HELD))
    verdict = decide(tmp_path, baseline() + stamped)
    assert (verdict.returncode, verdict.stdout.strip()) == (0, "accept")


def test_a_missing_results_file_is_inconclusive_not_an_error(tmp_path):
    env = {**os.environ, "XDG_STATE_HOME": str(tmp_path / "state")}
    env.pop("AUTOCODER_EVAL_RESULTS", None)
    env.pop("AUTOCODER_EVAL_DECISIONS", None)
    r = subprocess.run([sys.executable, str(SCRIPT), "--finding", "f", "--before", BEFORE, "--after", AFTER],
                       capture_output=True, text=True, env=env)
    assert (r.returncode, r.stdout.strip()) == (3, "inconclusive no dev case was run")
    assert decisions(tmp_path)[0]["dev"] == {"before": [0, 0], "after": [0, 0]}


def test_heldout_case_regression_blocks_an_aggregate_gain(tmp_path):
    rows = baseline(ho_before=(0, 2))
    rows += runs(BEFORE, "heldout", "protected", 2, 2) + runs(AFTER, "heldout", "protected", 1, 2)
    rows += runs(BEFORE, "dev", "stable", 2, 2) + runs(AFTER, "dev", "stable", 2, 2)
    result = decide(tmp_path, rows)
    assert result.returncode == 1
    record, = decisions(tmp_path)
    assert record["heldout"] == {"before": [2, 4], "after": [3, 4]}
    assert record["protected_regressions"] == ["protected"]
    assert record["cases"]["heldout"]["protected"] == {"before": [2, 2], "after": [1, 2], "status": "regressed"}
    assert record["cases"]["dev"]["stable"]["status"] == "unchanged"


@pytest.mark.parametrize("after_order", [(False, True), (True, False)])
def test_mixed_repeat_outcomes_are_inconclusive_regardless_of_order(tmp_path, after_order):
    rows = baseline()
    for sha, outcomes in ((BEFORE, (True, False)), (AFTER, after_order)):
        for repeat, passed in enumerate(outcomes, start=1):
            rows.append({**row(sha, "dev", "unstable", passed), "repeat": repeat})
    result = decide(tmp_path, rows)
    assert result.returncode == 3
    assert "conflicting repeat outcomes: dev/unstable" in result.stdout
    record, = decisions(tmp_path)
    assert record["cases"]["dev"]["unstable"] == {"before": [1, 2], "after": [1, 2], "status": "unchanged", "conflicting": True}


def test_uncertain_heldout_decline_remains_visible(tmp_path):
    rows = baseline() + runs(BEFORE, "heldout", "unstable", 2, 3) + runs(AFTER, "heldout", "unstable", 1, 3)
    assert decide(tmp_path, rows).returncode == 3
    record, = decisions(tmp_path)
    assert record["protected_regressions"] == ["unstable"]
    assert record["cases"]["heldout"]["unstable"]["status"] == "regressed"
    assert record["cases"]["heldout"]["unstable"]["conflicting"] is True
