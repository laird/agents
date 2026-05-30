#!/usr/bin/env python3
"""Append one JSON record per /loop tick to the gate-log file.

Invoked by /autocoder:gate at gate exit. Writes a single line atomically
(O_APPEND on a single small write) to
  ${XDG_STATE_HOME:-$HOME/.local/state}/autocoder/gate.jsonl

Record shape (see spec §13.2):
  {"ts": ISO8601Z, "tick_id": "<session>-<epoch_ms>",
   "outcome": "idle|triage|fix|enhance|error",
   "model": "claude-...", "issues_scanned": N, "stale_swept": N,
   "claimed": "issue#" or null, "gate_duration_ms": N,
   "session_jsonl_path": "/path/to/<session>.jsonl"}

CLI:
  gate-log.py --outcome OUT --session SESSION_ID --session-jsonl PATH \
              [--model M] [--issues-scanned N] [--stale-swept N] \
              [--claimed ISSUE] [--gate-duration-ms N] [--log-path PATH]

The --log-path override is mainly for tests; production uses the
XDG default.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

VALID_OUTCOMES = ("idle", "triage", "fix", "enhance", "error")


def default_log_path() -> Path:
    state = os.environ.get("XDG_STATE_HOME") or os.path.join(
        os.path.expanduser("~"), ".local", "state"
    )
    return Path(state) / "autocoder" / "gate.jsonl"


def build_record(args: argparse.Namespace) -> dict:
    epoch_ms = int(time.time() * 1000)
    tick_id = f"{args.session}-{epoch_ms}"
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    claimed = args.claimed if args.claimed not in (None, "", "null") else None
    return {
        "ts": ts,
        "tick_id": tick_id,
        "outcome": args.outcome,
        "model": args.model,
        "issues_scanned": args.issues_scanned,
        "stale_swept": args.stale_swept,
        "claimed": claimed,
        "gate_duration_ms": args.gate_duration_ms,
        "session_jsonl_path": args.session_jsonl,
    }


def append_atomic(path: Path, record: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    line = json.dumps(record, separators=(",", ":")) + "\n"
    # O_APPEND on a single small write is atomic up to PIPE_BUF (>=512).
    # Our line is well under that for normal field values.
    fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
    try:
        os.write(fd, line.encode("utf-8"))
    finally:
        os.close(fd)


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Append a gate-log record.")
    p.add_argument("--outcome", required=True, choices=VALID_OUTCOMES)
    p.add_argument("--session", required=True, help="Claude session id")
    p.add_argument("--session-jsonl", required=True, help="Path to session jsonl")
    p.add_argument("--model", default=None)
    p.add_argument("--issues-scanned", type=int, default=0)
    p.add_argument("--stale-swept", type=int, default=0)
    p.add_argument("--claimed", default=None)
    p.add_argument("--gate-duration-ms", type=int, default=0)
    p.add_argument("--log-path", default=None,
                   help="Override gate.jsonl path (default: XDG_STATE_HOME/autocoder/gate.jsonl)")
    args = p.parse_args(argv)

    path = Path(args.log_path) if args.log_path else default_log_path()
    record = build_record(args)
    append_atomic(path, record)
    # Echo path for the gate so it can be picked up downstream.
    sys.stdout.write(str(path) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
