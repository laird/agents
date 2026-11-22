#!/usr/bin/env python3
"""merge-train-run.py -- run a merge train cycle (library: train_run.py; planning: merge-train.py).

  run     [--size N]     one cycle: lease, preflight, plan up to the adaptive limit, assemble ONE tree,
                         gate it through merge-to-integration.sh, publish and close out, and on a red
                         attribute / re-gate the remaining members / bisect (see train_run.py)
  status                 the batch limit and its history, the live cycle record, queued tracker writes
  limit   [--set N]      print the adaptive batch limit; --set pins it (clamped to batchMin..batchMax)
  abandon                clear a cycle record without touching the tracker or any branch

Common: --repo DIR (default: the current directory), --config FILE (default: the main worktree's
.autocoder.json, key `train`). Keys: see train_run.py and scripts/README-merge-train-run.md.
Exit: 0 cycle ran (or nothing to train); 1 refused (lease held, preflight failed); 2 planner or scratch
fault (nobody blamed); 3 environment error.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import train_run as R  # noqa: E402


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
        return 0
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
