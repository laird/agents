#!/usr/bin/env python3
"""merge-train.py -- the merge queue and train planner (library: train_lib.py).

  queue   [--in-flight N,N] [--status-line]   the ordered queue of READY issues, one TSV row per item:
                                              order state issue branch tip rank created note
  plan    [--size N] [--in-flight N,N]        the next train: `train`, `skip` and `drop` rows; exits 2
                                              with the planner's fault when the plan cannot be trusted;
                                              every merge runs hooks off, and each candidate's probe
                                              seconds go to stderr (`# plan: #N <kind> <s>s`)
  reopen  --issue N --member-branch B --landed SHA [--launched TS]
                                              reopen an issue a landing closed while a newer READY names
                                              a branch that landing did not carry

Common: --repo DIR (default: the current directory), --config FILE (default: the main worktree's
.autocoder.json, key `train`), --no-fetch. Configuration and the overrides file are documented in
scripts/README.md ("Merge trains").
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import train_lib as T  # noqa: E402


def _ints(s):
    return [int(x) for x in (s or "").replace(",", " ").split()]


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", default=".")
    ap.add_argument("--config")
    ap.add_argument("--no-fetch", action="store_true")
    sub = ap.add_subparsers(dest="cmd", required=True)
    q = sub.add_parser("queue")
    q.add_argument("--in-flight", default="")
    q.add_argument("--status-line", action="store_true")
    p = sub.add_parser("plan")
    p.add_argument("--size", type=int)
    p.add_argument("--in-flight", default="")
    r = sub.add_parser("reopen")
    r.add_argument("--issue", required=True)
    r.add_argument("--member-branch", required=True)
    r.add_argument("--landed", required=True)
    r.add_argument("--launched")
    a = ap.parse_args(argv)

    cfg = T.load_config(a.repo, a.config)
    if not a.no_fetch:
        f = T.git(cfg.repo, "fetch", cfg.remote, "-q")
        if f.returncode != 0:
            print(f"merge-train: git fetch {cfg.remote} failed in {cfg.repo}: {f.stderr.strip()}", file=sys.stderr)
            return 1
    try:
        if a.cmd == "queue":
            rows = T.plan_queue(cfg, _ints(a.in_flight))
            if a.status_line:
                print(T.status_line(rows))
            for x in rows:
                print("\t".join(str(x[k]) for k in ("order", "state", "issue", "branch", "tip", "rank", "created", "note")))
        elif a.cmd == "plan":
            rows = T.plan_queue(cfg, _ints(a.in_flight))
            # Each candidate's probe time on stderr (a dry plan is not a cycle, so no timing row is written).
            out, fault = T.plan_train(cfg, rows, a.size, on_candidate=lambda i, k, s: print(f"# plan: #{i} {k} {s}s", file=sys.stderr))
            print("\n".join(out))
            if fault:
                print(f"fault\t{fault}")
                return 2
            if not any(x.startswith("train\t") for x in out):
                print("# no clean READY branch to train", file=sys.stderr)
        elif a.cmd == "reopen":
            done = T.reopen_if_newer_ready(cfg, a.issue, a.member_branch, a.landed, a.launched)
            print("reopened" if done else "not reopened")
    except RuntimeError as e:
        print(f"merge-train: {e}", file=sys.stderr)
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main())
