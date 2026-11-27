"""Weekly reporting of idle intervals from the train's daemon tick journal."""

import json
import os

from test_landing_timings import report


def test_week_splits_observed_idle_time_and_clips_to_week(tmp_path):
    journal = tmp_path / "daemon-ticks.jsonl"
    ticks = [
        ("2026-11-15T23:59:30Z", 1, "idle", "2 held: red master #1"),
        ("2026-11-16T00:00:30Z", 1, "idle", ""),
        ("2026-11-16T00:01:30Z", 1, "paused", "maintenance"),
        ("2026-11-16T00:02:30Z", 1, "launching", ""),
        ("2026-11-16T00:12:00Z", 1, "idle", ""),
        ("2026-11-16T00:20:00Z", 1, "train-live", ""),
        ("2026-11-16T00:20:30Z", 1, "idle", ""),
        ("2026-11-16T00:21:30Z", 2, "train-live", ""),
        ("2026-11-22T23:59:30Z", 2, "paused", "maintenance"),
        ("2026-11-23T00:00:30Z", 2, "stopped", ""),
    ]
    journal.write_text("".join(json.dumps(dict(ts=ts, pid=pid, verdict=verdict, note=note, interval=60)) + "\n"
                               for ts, pid, verdict, note in ticks))
    args = ("--week", "2026-11-16", "--log", os.devnull, "--tracker", "off", "--ci", "off", "--loop", "off")
    env = {"AUTOCODER_TRAIN_STATE": str(tmp_path)}
    result = report(*args, "--json", env=env)
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)["train_idle_minutes"] == {
        "red_hold": 0.5, "no_launchable_item": 2, "paused": 1.5,
    }
    result = report(*args, env=env)
    assert result.returncode == 0, result.stderr
    assert "Train idle minutes: red hold 0.50, no launchable item 2.00, paused 1.50" in result.stdout


def test_week_without_tick_journal_shows_zeroes(tmp_path):
    result = report("--week", "2026-11-16", "--log", os.devnull, "--tracker", "off", "--ci", "off",
                    "--loop", "off", "--train-ticks", str(tmp_path / "missing"))
    assert result.returncode == 0, result.stderr
    assert "Train idle minutes: red hold 0.00, no launchable item 0.00, paused 0.00" in result.stdout
