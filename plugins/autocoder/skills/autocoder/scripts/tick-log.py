#!/usr/bin/env python3
"""tick-log.py: append one operational loop's run to ticks.jsonl (#422).

WHY THIS EXISTS:
  The loops around a swarm (a queue pass, a merge train's cycle hook, a health check, a sentinel
  tick, a watchdog) each kept a log of its own that nothing joined, so a loop that ticks without
  effect, fails every other run or takes ten times its median went unseen. Each run now appends
  one line here; trace-build.py turns each line into a trace and analyze-traces.py's tick
  classifiers read them. tick-fns.sh (tick_start, tick_end) calls this for shell loops.

FORMAT (version 1): one JSON object per line in
  ${AUTOCODER_TICKS:-${XDG_STATE_HOME:-$HOME/.local/state}/autocoder/ticks.jsonl}
  {"v": 1, "ts": "<ISO start, UTC>", "repo": "<repo id>", "loop": "<loop id>", "run_id": "<id>",
   "duration_s": 12.3|null, "outcome": "ok|noop|error|timeout", "observed": {...}, "actions": {...},
   "error": "<text>"|null}
  Loop ids are the writer's choice. `observed` holds what the run saw, `actions` what it did.

USAGE
  tick-log.py --loop L --outcome O [--run-id R] [--duration-s S] [--observed JSON] [--actions JSON]
              [--error TEXT] [--repo ID] [--ts ISO] [observed.KEY=VALUE | actions.KEY=VALUE | error=TEXT ...]
  A KEY=VALUE pair adds to --observed/--actions; a value that reads as a number is written as one,
  an empty value as null. --run-id defaults to the start time and this process id. --repo defaults
  to repo-id-fns.sh's autocoder_repo_id of the current checkout, else its directory name.

The file is never rotated. One write() of an O_APPEND line, so concurrent loops do not
interleave. Exits 1 with a line on stderr when the line cannot be written.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

OUTCOMES = ("ok", "noop", "error", "timeout")
NUMBER_RE = re.compile(r"^-?\d+(\.\d+)?$")
REPO_ID_FNS = Path(__file__).resolve().parent / "repo-id-fns.sh"


def ticks_path() -> Path:
    if os.environ.get("AUTOCODER_TICKS"):
        return Path(os.environ["AUTOCODER_TICKS"])
    state = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
    return Path(state) / "autocoder" / "ticks.jsonl"


def scalar(value: str):
    if value == "":
        return None
    if NUMBER_RE.match(value):
        return float(value) if "." in value else int(value)
    return value


def json_object(text: str) -> dict:
    value = json.loads(text)
    if not isinstance(value, dict):
        raise argparse.ArgumentTypeError(f"not a JSON object: {text}")
    return value


def default_repo() -> str:
    top = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True)
    directory = top.stdout.strip() if top.returncode == 0 and top.stdout.strip() else os.getcwd()
    r = subprocess.run(["bash", "-c", 'source "$1" && autocoder_repo_id "$2"', "_", str(REPO_ID_FNS), directory],
                       capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 and r.stdout.strip() else os.path.basename(directory)


def tick_line(a: argparse.Namespace) -> dict:
    observed, actions, error = dict(a.observed or {}), dict(a.actions or {}), a.error
    for pair in a.pairs:
        key, sep, value = pair.partition("=")
        section, dot, name = key.partition(".")
        if key == "error" and sep:
            error = value or None
        elif sep and dot and name and section in ("observed", "actions"):
            (observed if section == "observed" else actions)[name] = scalar(value)
        else:
            raise ValueError(f"not observed.KEY=VALUE, actions.KEY=VALUE or error=TEXT: {pair}")
    ts = a.ts or datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    return {"v": 1, "ts": ts, "repo": a.repo or default_repo(), "loop": a.loop,
            "run_id": a.run_id or f"{ts}-{os.getpid()}",
            "duration_s": None if a.duration_s is None else round(a.duration_s, 3),
            "outcome": a.outcome, "observed": observed, "actions": actions, "error": error}


def append(path: Path, row: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    # 0600 and O_NOFOLLOW: an error text can name paths and hosts.
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0), 0o600)
    try:
        os.write(fd, (json.dumps(row, separators=(",", ":")) + "\n").encode())
    finally:
        os.close(fd)


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Append one operational loop's run to ticks.jsonl.")
    p.add_argument("--loop", required=True)
    p.add_argument("--outcome", required=True, choices=OUTCOMES)
    p.add_argument("--run-id")
    p.add_argument("--duration-s", type=float)
    p.add_argument("--observed", type=json_object)
    p.add_argument("--actions", type=json_object)
    p.add_argument("--error")
    p.add_argument("--repo")
    p.add_argument("--ts", help="the run's start, ISO-8601 (default: now)")
    p.add_argument("pairs", nargs="*", metavar="observed.KEY=VALUE|actions.KEY=VALUE|error=TEXT")
    args = p.parse_args(argv)
    try:
        row = tick_line(args)
    except ValueError as e:
        p.error(str(e))
    try:
        append(ticks_path(), row)
    except OSError as e:
        print(f"tick-log: cannot write {ticks_path()}: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
