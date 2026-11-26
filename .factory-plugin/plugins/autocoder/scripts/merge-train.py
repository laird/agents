#!/usr/bin/env python3
"""merge-train.py -- the merge queue and train planner (library: train_lib.py).

  queue   [--in-flight N,N] [--status-line]   the ordered queue of READY issues, one TSV row per item:
                                              order state issue branch tip rank created note basis
                                              (basis: `preflight` for a READY enqueue.sh posted from a
                                              host that does not gate, else `ready`)
  plan    [--size N] [--in-flight N,N]        the next train: `train`, `skip` and `drop` rows; exits 2
                                              with the planner's fault when the plan cannot be trusted;
                                              every merge runs hooks off, and each candidate's probe
                                              seconds go to stderr (`# plan: #N <kind> <s>s`)
  reopen  --issue N --member-branch B --landed SHA [--launched TS]
                                              reopen an issue a landing closed while a newer READY names
                                              a branch that landing did not carry
  carried --branch B                          exit 0 and print `in-train <issue> <branch> <tip>` (TSV) when the
                                              live train carries the branch (a lane launch refuses on it: the
                                              train's gate lands that work), else print `not-carried`, exit 1;
                                              never fetches
  gates                                       the live gates on this host (what the queue's `in-lane` reads):
                                              `<issue> <pid> <pidfile> <log>` (TSV) per live pidfile under
                                              `gateDirs`; never fetches
  depbot  [--status-line]                     the dependency-bot pass (train_depbot.py; `train.depbot` in the config):
                                              every open PR by a configured bot author gets a tracking issue with a
                                              READY the planner accepts (the `stack:` line) first in priority; a
                                              moved tip a new READY; a replaced PR supersedes its older issue. One
                                              TSV row per PR (`pr head tip issue action note`), the status segment
                                              last (`depbot: N open, oldest M passes`); exit 1 when the PR listing
                                              failed (`depbot: unknown (pr list failed)`), 4 when the pass is off

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
import train_depbot as D  # noqa: E402


def _ints(s):
    return [int(x) for x in (s or "").replace(",", " ").split()]


def _ledger_ready(cfg, issue, ts):
    import os
    import subprocess
    writer = T.SCRIPTS / "landing-timings.py"
    if not writer.is_file():
        return
    env = dict(os.environ)
    rid = T.repo_id(cfg)
    if rid and not env.get("AUTOCODER_LANDING_REPO"):
        env["AUTOCODER_LANDING_REPO"] = rid
    try:
        subprocess.run([sys.executable, str(writer), "change", "--issue", str(issue), "--event", "ready", "--ts", ts],
                       capture_output=True, text=True, env=env)
    except OSError:
        pass


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
    c = sub.add_parser("carried")
    c.add_argument("--branch", required=True)
    sub.add_parser("gates")
    b = sub.add_parser("depbot")
    b.add_argument("--status-line", action="store_true")
    a = ap.parse_args(argv)

    cfg = T.load_config(a.repo, a.config)
    if a.cmd == "carried":
        row = T.train_carries(cfg, a.branch)
        if row is None:
            print("not-carried")
            return 1
        print("\t".join(["in-train", row["issue"], row["branch"], row["tip"]]))
        return 0
    if a.cmd == "gates":
        for g in T.live_gates(cfg):
            print("\t".join(str(x) for x in (g["issue"], g["pid"], g["pidfile"], g["log"])))
        return 0
    if not a.no_fetch:
        f = T.git(cfg.repo, "fetch", cfg.remote, "-q")
        if f.returncode != 0:
            print(f"merge-train: git fetch {cfg.remote} failed in {cfg.repo}: {f.stderr.strip()}", file=sys.stderr)
            return 1
    try:
        if a.cmd == "queue":
            rows = T.plan_queue(cfg, _ints(a.in_flight))
            # The first sight of a READY is a `ready` row in the landing ledger (the comment's time as its
            # `ts`), whichever reader sees it first: this listing or a cycle. Best effort, never a failure.
            T.note_readys(cfg, rows, lambda issue, ts: _ledger_ready(cfg, issue, ts))
            if a.status_line:
                line = T.status_line(rows)
                if D.settings(cfg).enabled:   # the pass's own segment, from its last record: a listing never reads PRs
                    line += " | " + D.status_segment(D.load_record(cfg))
                print(line)
            for x in rows:
                print("\t".join(str(x[k]) for k in ("order", "state", "issue", "branch", "tip", "rank", "created", "note", "basis")))
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
        elif a.cmd == "depbot":
            st = D.settings(cfg)
            if not st.enabled:
                print("merge-train: the dependency-bot pass is off (no `train.depbot` object, or `enabled: false`)", file=sys.stderr)
                return 4
            ps = D.Pass(cfg, st).run()
            ps.save()
            if not a.status_line:
                for r in ps.rows:
                    print("\t".join(str(r[k]) for k in ("pr", "head", "tip", "issue", "action", "note")))
                for c in ps.closed:
                    print("\t".join(["-", "-", "-", str(c["issue"]), "closed", c["why"]]))
            print(D.status_segment(ps.record()))
            if ps.error:
                return 1
    except RuntimeError as e:
        print(f"merge-train: {e}", file=sys.stderr)
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main())
