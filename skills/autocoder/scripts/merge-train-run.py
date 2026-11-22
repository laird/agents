#!/usr/bin/env python3
"""merge-train-run.py -- run a merge train cycle (library: train_run.py; planning: merge-train.py).

  run     [--size N]     one cycle: lease, preflight, plan up to the adaptive limit, assemble ONE tree,
                         gate it through merge-to-integration.sh, publish and close out, and on a red
                         attribute / re-gate the remaining members / bisect (see train_run.py)
  status                 the batch limit and its history, the live cycle record, queued tracker writes
  limit   [--set N]      print the adaptive batch limit; --set pins it (clamped to batchMin..batchMax)
  abandon                clear a cycle record without touching the tracker or any branch
  daemon  [--interval S] [--once] [--max-ticks N]
                         launch a cycle whenever the queue has a launchable item and no train holds the
                         lease; otherwise poll every S seconds (60). Holds, the lane and launched tips are
                         the queue's own rules. `daemon --stop` ends a running daemon at its next tick (a
                         running cycle finishes first); `--pause REASON` / `--resume` hold and release every
                         launch; `--status` says what it is doing. One daemon per state dir.

Common: --repo DIR (default: the current directory), --config FILE (default: the main worktree's
.autocoder.json, key `train`). Keys: see train_run.py and scripts/README-merge-train-run.md.
Exit: 0 cycle ran (or nothing to train); 1 refused (lease held, preflight failed); 2 planner or scratch
fault (nobody blamed); 3 environment error. daemon: 0 stopped, 1 another daemon holds the lock.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import train_run as R  # noqa: E402


def daemon_status(state):
    """`live (pid N since TS)` or `not running`, the pause reason when paused, and the last tick's verdict."""
    holder = R.Daemon.holder(state)
    parts = [f"live ({holder})" if holder else "not running"]
    pause = state.dir / "daemon.pause"
    if pause.exists():
        parts.append("paused: " + (pause.read_text(errors="replace").strip() or "no reason given"))
    if (state.dir / "daemon.stop").exists():
        parts.append("stop requested")
    last = R._read_json(state.dir / "daemon.json", {})
    if last:
        parts.append(f"last tick {last.get('ts')} {last.get('verdict')}" + (f" ({last['note']})" if last.get("note") else "")
                     + (" launchable " + " ".join(f"#{i}" for i in last["launchable"]) if last.get("launchable") else ""))
    return "; ".join(parts)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", default=".")
    ap.add_argument("--config")
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--size", type=int)
    sub.add_parser("status")
    lim = sub.add_parser("limit")
    lim.add_argument("--set", type=int, dest="set_to")
    sub.add_parser("abandon")
    d = sub.add_parser("daemon")
    d.add_argument("--interval", type=int, default=60, help="seconds between ticks when nothing is launchable (60)")
    d.add_argument("--once", action="store_true", help="one tick, then exit (tests, cron)")
    d.add_argument("--max-ticks", type=int, default=0)
    d.add_argument("--stop", action="store_true", help="end the running daemon at its next tick")
    d.add_argument("--pause", metavar="REASON", help="hold every launch until --resume")
    d.add_argument("--resume", action="store_true", help="release a --pause")
    d.add_argument("--status", action="store_true")
    a = ap.parse_args(argv)
    rc = R.load_run_config(a.repo, a.config)
    state = R.State(rc)
    if a.cmd == "run":
        code, _ = R.Cycle(rc).run(a.size)
        return code
    if a.cmd == "status":
        b = state.batch()
        print(f"batch limit {b['limit']} (start {rc.batch_start}, floor {rc.batch_min}, ceiling {rc.batch_max})")
        for h in b["history"][-8:]:
            print(f"  {h['ts']} size {h['size']} {h['verdict']} limit {h['limit']} -> {h['limit_after']}")
        c = state.cycle()
        print("live cycle: " + (json.dumps({k: c[k] for k in ("started", "limit", "trainBranches") if k in c}) if c else "none"))
        for m in c.get("members", []):
            print(f"  #{m['issue']} {m['branch']} {m['tip'][:10]} {m['status']}")
        print(f"queued tracker writes: {len(state.pending())}")
        print("daemon: " + daemon_status(state))
        return 0
    if a.cmd == "daemon":
        if a.status:
            print(daemon_status(state))
            return 0
        if a.stop:
            (state.dir / "daemon.stop").write_text(f"stop requested {R.now_iso()}\n")
            print("stop requested: " + daemon_status(state))
            return 0
        if a.pause is not None:
            (state.dir / "daemon.pause").write_text(a.pause.strip() + "\n")
            print("paused: " + daemon_status(state))
            return 0
        if a.resume:
            (state.dir / "daemon.pause").unlink(missing_ok=True)
            print("resumed: " + daemon_status(state))
            return 0
        return R.Daemon(rc, interval=a.interval, once=a.once, max_ticks=a.max_ticks).loop()
    if a.cmd == "limit":
        if a.set_to:
            b = state.batch()
            b["limit"] = min(max(a.set_to, rc.batch_min), rc.batch_max)
            R._write_json(state.dir / "batch.json", b)
        print(state.limit())
        return 0
    state.clear_cycle()
    print("cycle record cleared; a train branch on the remote, if any, is left for you to delete")
    return 0


if __name__ == "__main__":
    sys.exit(main())
