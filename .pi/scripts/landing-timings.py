#!/usr/bin/env python3
"""Append landing-timing rows: one per CHANGE event, one per BATCH, one per PLAN candidate, one CI VERDICT per landed commit.

Generic by design: ids and numbers only, no project, branch or person names. A
project's gate, queue or train script calls this at the moments it owns; the
plugin's own merge-to-integration.sh does for the single-change gate.
landing-report.py reads the file.

File: ${AUTOCODER_LANDING_TIMINGS:-${XDG_STATE_HOME:-$HOME/.local/state}/autocoder/landing-timings.jsonl}
Writes are one O_APPEND write() of one line, so concurrent writers do not interleave.

  change --issue N --event EVENT [--batch ID] [--cause CAUSE] [--sha HEX] [--ts ISO]
      EVENT: claimed | ready | batched | landed | returned | rebase | precheck
      CAUSE (returned only): defect | conflict | stale-base | red-integration |
             infra | docs-resync | other
      Only `defect` is a useful rejection: the change itself was wrong.
      SHA (landed only): the commit now on the integration branch that carries the change; every
      member of one batch names the same one. The report looks the integration branch's CI verdict
      up by it; a landed row without it has no CI figure (n/a, never 0).
  batch --batch ID --members 1,2,3 [--assembly-s N] [--stage NAME=SECONDS ...]
        [--gate-s N] [--discarded-gate-s N] [--publish-s N]
        [--verdict green|red|aborted|infra] [--cause CAUSE] [--resyncs N]
        [--push-rejected N] [--ts ISO]
      gate_s defaults to the sum of the stages. discarded_gate_s is the gate time spent on
      trees a later re-sync replaced; it is waste even when the batch ends green.
  plan --issue N --verdict train|skip|drop|fault --seconds S [--batch ID] [--ts ISO]
      one candidate the train planner judged: what it decided and the seconds its probe took
      (prefilter, real merge, merge drivers). A cycle's planning time is the sum of its rows; the
      report shows it beside the gate time, because a probe that regenerates the tree per
      candidate is a fixed cost of every cycle nobody sees in a gate log.

  ci-verdict --sha HEX --conclusion C --verdict-ts ISO [--run-id ID] [--workflow NAME ...] [--ts ISO]
      the integration branch's CI verdict on one landed commit, written ONCE by landing-report.py
      when it first finds a terminal verdict (success, failure, cancelled, timed_out ...): run id,
      conclusion, the time CI reached it, and the workflows it judged (null = every run on the
      branch), so a verdict cached under one selection is never read under another. A pending run
      or an unreachable forge is never cached, so `unknown` and `pending` are refused: the report
      asks again next time.

  Every kind takes --repo ID (default $AUTOCODER_LANDING_REPO, else null): the repository the row
  belongs to (repo-id-fns.sh's autocoder_repo_id). Two repositories on one host share the default
  file, and a test run from a checkout that forgot the private path writes fixture rows beside the
  real ones; the report keeps the rows of the repository it reports on and names the rest.

Row schema (v1), also the contract for a project's own writers:
  {"v":1,"ts","kind":"change","issue":N,"event":E,"batch":ID|null,"cause":C|null,"repo":ID|null}
  {"v":1,"ts","kind":"batch","batch":ID,"members":[N..],"assembly_s","stages":{name:s},
   "gate_s","discarded_gate_s","publish_s","verdict","cause","resyncs","push_rejected","repo":ID|null}
  {"v":1,"ts","kind":"plan","issue":N,"verdict":V,"seconds":S,"batch":ID|null,"repo":ID|null}
  {"v":1,"ts","kind":"ci-verdict","sha":HEX,"run_id":ID|null,"conclusion":C,"verdict_ts":ISO,"workflows":[..]|null,"repo":ID|null}
  A `landed` change row carries "sha":HEX when its writer knew the landed commit (absent before).
Absent numbers are null, never 0: the report tells "not measured" from "took no time". `repo` is
null only for a writer that named none (rows written before the field existed).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

CHANGE_EVENTS = ("claimed", "ready", "batched", "landed", "returned", "rebase", "precheck")
CAUSES = ("defect", "conflict", "stale-base", "red-integration", "infra", "docs-resync", "other")
VERDICTS = ("green", "red", "aborted", "infra")
PLAN_VERDICTS = ("train", "skip", "drop", "fault")
UNCACHEABLE_CONCLUSIONS = ("unknown", "pending", "none", "")   # not a verdict: the report asks the forge again
SHA_RE = re.compile(r"^(?:[0-9a-f]{40}|[0-9a-f]{64})$")   # a FULL object name: a prefix would split one landing in two
CONCLUSION_RE = re.compile(r"^[a-z][a-z0-9_-]{0,39}$")
ID_RE = re.compile(r"^[A-Za-z0-9._:-]{1,80}$")
ISO_RE = re.compile(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")


def default_path() -> Path:
    env = os.environ.get("AUTOCODER_LANDING_TIMINGS")
    if env:
        return Path(env)
    state = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
    return Path(state) / "autocoder" / "landing-timings.jsonl"


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def append_atomic(path: Path, row: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    line = (json.dumps(row, separators=(",", ":"), sort_keys=False) + "\n").encode()
    fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_APPEND | getattr(os, "O_NOFOLLOW", 0), 0o600)
    try:
        os.write(fd, line)
    finally:
        os.close(fd)


def _id(value: str, what: str) -> str:
    if not ID_RE.match(value):
        raise ValueError(f"{what} {value!r} is not an id (letters, digits, . _ : - only, max 80)")
    return value


def _ts(value: str | None) -> str:
    if value is None:
        return now_iso()
    if not ISO_RE.match(value):
        raise ValueError(f"--ts {value!r} is not YYYY-MM-DDTHH:MM:SSZ")
    return value


def _repo(a: argparse.Namespace):
    value = a.repo if a.repo is not None else (os.environ.get("AUTOCODER_LANDING_REPO") or None)
    return _id(value, "--repo") if value else None


def _num(value, what: str):
    if value is None:
        return None
    if value < 0:
        raise ValueError(f"{what} {value} is negative")
    return value


def _sha(value: str) -> str:
    if not SHA_RE.match(value):
        raise ValueError(f"--sha {value!r} is not a commit (the full object name: 40 or 64 lower-case hex digits)")
    return value


def change_row(a: argparse.Namespace) -> dict:
    if a.event == "returned" and a.cause is None:
        raise ValueError("a returned change needs --cause")
    if a.cause is not None and a.event != "returned":
        raise ValueError("--cause belongs to --event returned")
    if a.sha is not None and a.event != "landed":
        raise ValueError("--sha belongs to --event landed")
    row = {"v": 1, "ts": _ts(a.ts), "kind": "change", "issue": a.issue, "event": a.event,
           "batch": _id(a.batch, "--batch") if a.batch else None, "cause": a.cause}
    if a.sha is not None:
        row["sha"] = _sha(a.sha)
    return row


def ci_verdict_row(a: argparse.Namespace) -> dict:
    if a.conclusion in UNCACHEABLE_CONCLUSIONS:
        raise ValueError(f"--conclusion {a.conclusion!r} is not a verdict and is never cached (the report asks the forge again)")
    if not CONCLUSION_RE.match(a.conclusion):
        raise ValueError(f"--conclusion {a.conclusion!r} is not a conclusion token (lower-case letters, digits, _ -)")
    if not ISO_RE.match(a.verdict_ts):
        raise ValueError(f"--verdict-ts {a.verdict_ts!r} is not YYYY-MM-DDTHH:MM:SSZ")
    workflows = sorted({w.strip() for w in (a.workflow or []) if w.strip()}) or None   # one arg per name: a name may hold a comma
    return {"v": 1, "ts": _ts(a.ts), "kind": "ci-verdict", "sha": _sha(a.sha),
            "run_id": _id(a.run_id, "--run-id") if a.run_id else None, "conclusion": a.conclusion, "verdict_ts": a.verdict_ts,
            "workflows": workflows}


def batch_row(a: argparse.Namespace) -> dict:
    stages: dict[str, float] = {}
    for item in a.stage or []:
        name, sep, secs = item.partition("=")
        try:
            stages[_id(name, "--stage name")] = _num(float(secs), "--stage seconds")
        except ValueError as e:
            raise ValueError(f"--stage {item!r} must be NAME=SECONDS ({e})") from e
        if not sep:
            raise ValueError(f"--stage {item!r} must be NAME=SECONDS")
    members = [int(m) for m in a.members.split(",") if m.strip()]
    if not members:
        raise ValueError("--members names no change")
    gate_s = a.gate_s if a.gate_s is not None else (sum(stages.values()) if stages else None)
    if a.verdict not in (None, "green") and a.cause is None:
        raise ValueError(f"a {a.verdict} batch needs --cause")
    return {"v": 1, "ts": _ts(a.ts), "kind": "batch", "batch": _id(a.batch, "--batch"),
            "members": members, "assembly_s": _num(a.assembly_s, "--assembly-s"), "stages": stages,
            "gate_s": _num(gate_s, "--gate-s"), "discarded_gate_s": _num(a.discarded_gate_s, "--discarded-gate-s"),
            "publish_s": _num(a.publish_s, "--publish-s"), "verdict": a.verdict, "cause": a.cause,
            "resyncs": a.resyncs, "push_rejected": a.push_rejected}


def plan_row(a: argparse.Namespace) -> dict:
    return {"v": 1, "ts": _ts(a.ts), "kind": "plan", "issue": a.issue, "verdict": a.verdict,
            "seconds": _num(a.seconds, "--seconds"), "batch": _id(a.batch, "--batch") if a.batch else None}


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="Append a landing-timings row.")
    p.add_argument("--log-path", default=None, help="override the file (tests)")
    p.add_argument("--repo", default=None, help="the repository id of the row (default $AUTOCODER_LANDING_REPO)")
    sub = p.add_subparsers(dest="kind", required=True)
    c = sub.add_parser("change")
    c.add_argument("--issue", type=int, required=True)
    c.add_argument("--event", required=True, choices=CHANGE_EVENTS)
    c.add_argument("--batch")
    c.add_argument("--cause", choices=CAUSES)
    c.add_argument("--sha", help="landed only: the commit on the integration branch that carries the change")
    c.add_argument("--ts")
    b = sub.add_parser("batch")
    b.add_argument("--batch", required=True)
    b.add_argument("--members", required=True)
    b.add_argument("--assembly-s", type=float)
    b.add_argument("--stage", action="append")
    b.add_argument("--gate-s", type=float)
    b.add_argument("--discarded-gate-s", type=float)
    b.add_argument("--publish-s", type=float)
    b.add_argument("--verdict", choices=VERDICTS)
    b.add_argument("--cause", choices=CAUSES)
    b.add_argument("--resyncs", type=int)
    b.add_argument("--push-rejected", type=int)
    b.add_argument("--ts")
    pl = sub.add_parser("plan")
    pl.add_argument("--issue", type=int, required=True)
    pl.add_argument("--verdict", required=True, choices=PLAN_VERDICTS)
    pl.add_argument("--seconds", type=float, required=True)
    pl.add_argument("--batch")
    pl.add_argument("--ts")
    cv = sub.add_parser("ci-verdict")
    cv.add_argument("--sha", required=True)
    cv.add_argument("--conclusion", required=True, help="the terminal conclusion CI reached (success, failure, cancelled, timed_out ...)")
    cv.add_argument("--verdict-ts", required=True, help="when CI reached it (ISO, UTC)")
    cv.add_argument("--run-id")
    cv.add_argument("--workflow", action="append", help="a workflow name the verdict was judged over (repeatable; default: every run on the branch)")
    cv.add_argument("--ts")
    return p


def main(argv: list[str] | None = None) -> int:
    a = parser().parse_args(argv)
    try:
        row = {"change": change_row, "batch": batch_row, "plan": plan_row, "ci-verdict": ci_verdict_row}[a.kind](a)
        row["repo"] = _repo(a)
    except ValueError as e:
        print(f"landing-timings: {e}", file=sys.stderr)
        return 2
    append_atomic(Path(a.log_path) if a.log_path else default_path(), row)
    return 0


if __name__ == "__main__":
    sys.exit(main())
