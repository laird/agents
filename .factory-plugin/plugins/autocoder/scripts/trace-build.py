#!/usr/bin/env python3
"""trace-build.py: one trace per issue attempt, compiled from the ledgers the plugin writes (#395).

WHY THIS EXISTS:
  An attempt's story is spread over four ledgers and a transcript: issue-events.jsonl (the
  lifecycle), merge-events.jsonl (each gate's detail), landing-timings.jsonl (returned causes,
  rebases), gate.jsonl (the tick that claimed it) and the worker's stream-json transcript (tool
  calls, tool errors, the result). Nothing joined them, so a failure that repeats across
  attempts could not be named. This joins them, read-only, into the trace schema of
  docs/specs/2026-11-25-failure-traces-design.md; analyze-traces.py reads the result.

ATTEMPTS: one worker's claim of one (repo, issue), up to the next attempt's claim. issue_claim
  writes `claimed` and the worker's readback writes it again seconds later, so a `claimed` opens
  an attempt only when none is open, the open one has ended (a landed, escalated or released
  row since it started) or another worker wrote it and read it back within two minutes;
  otherwise it is a step of the open attempt. Another worker's claim with no readback lost the
  claim race: fix-loop-gate.sh moves on after a lost race and writes nothing more.
  Events before any claim (a rotated ledger, an older writer) open an implicit attempt with
  worker and branch null. A trace never mixes repositories. gate.jsonl names no repository, so
  a tick joins by issue number and time alone.

TERMINALS: the merge train lands most work, recording it only as a landing-timings `landed`
  change row, so that row is a terminal `landed` step like the lifecycle one; `ready`,
  `launched`, `batched` and `returned` rows are steps too. A `released` after a landing is the
  label cleanup and leaves the outcome `landed`. The train's gate issue (`train.gateIssue` in the
  main worktree's .autocoder.json, or --train-gate-issue) carries claims and no work, so its
  traces are dropped.

JOINS: a gate starts from each gate-end step and takes the detail of the merge-events attempt
  row with the same attempt number in the window; a merge row with no gate-end is a gate of its
  own. landing-timings rows join by (repo, issue) and window; a row from a writer that recorded
  no repository takes the one repository whose other rows name its issue. A transcript joins by
  the issue in its name and a time: its first `timestamp`/`ts` field (stream-json from
  `claude -p` has none), else the name's HHMMSS, local time as claude-worker-loop.sh's `date +%H%M%S`
  writes it, on the day nearest the attempt's start, else its mtime (checkout time in a git
  tree, so last). A transcript belongs to the one attempt whose start is nearest. Review records
  come from --comments-dir through issue-metrics.py's parser.

OUTPUT: JSON lines to --out (default ${AUTOCODER_TRACES:-${XDG_STATE_HOME:-$HOME/.local/state}/
  autocoder/traces.jsonl}; `-` is stdout), a whole-file rewrite so a rerun converges. Missing or
  empty ledgers give an empty file and exit 0. Malformed lines are skipped and counted per ledger
  on stderr.
"""

from __future__ import annotations

import argparse
import functools
import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
from collections import defaultdict
from dataclasses import dataclass
from datetime import datetime, time, timedelta, timezone
from pathlib import Path

_spec = importlib.util.spec_from_file_location(
    "issue_metrics", Path(__file__).resolve().parent / "issue-metrics.py")
METRICS = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(METRICS)

UTC = timezone.utc
TICK_LEAD = timedelta(minutes=10)
GATE_OUTCOMES_NOT_RETURNED = ("landed", "parked")
LANDING_STEPS = ("ready", "launched", "batched", "landed", "returned", "rebase", "precheck")
ATTEMPT_ENDS = ("landed", "escalated", "released")
READBACK = timedelta(minutes=2)
LANDING_ROW_KEYS = ("v", "ts", "kind", "repo", "issue", "event")
LEDGERS = {  # name: (environment override, file name beside the other ledgers)
    "issue-events": ("AUTOCODER_ISSUE_EVENTS", "issue-events.jsonl"),
    "merge-events": ("AUTOCODER_MERGE_EVENTS", "merge-events.jsonl"),
    "landing-timings": ("AUTOCODER_LANDING_TIMINGS", "landing-timings.jsonl"),
    "gate-log": (None, "gate.jsonl"),
}


def state_path(env_var: str | None, name: str) -> Path:
    if env_var and os.environ.get(env_var):
        return Path(os.environ[env_var])
    state = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
    return Path(state) / "autocoder" / name


def parse_ts(value) -> datetime | None:
    """An aware datetime, or None. A time without a zone is UTC, as every ledger writes UTC."""
    if not isinstance(value, str) or not value:
        return None
    try:
        t = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return t if t.tzinfo else t.replace(tzinfo=UTC)


def parse_bound(value: str) -> datetime:
    t = parse_ts(value)
    if t is None:
        raise argparse.ArgumentTypeError(f"not a date (YYYY-MM-DD or ISO-8601): {value}")
    return t


def first_not_none(*values):
    return next((v for v in values if v is not None), None)


def read_ledger(path: Path) -> tuple[list[dict], int]:
    """(rows, malformed line count). A missing ledger is an empty one."""
    rows, malformed = [], 0
    try:
        fh = open(path, errors="replace")
    except OSError:
        return rows, malformed
    with fh:
        for line in fh:
            if not line.strip():
                continue
            try:
                row = json.loads(line)
            except ValueError:
                malformed += 1
                continue
            if isinstance(row, dict):
                rows.append(row)
            else:
                malformed += 1
    return rows, malformed


Key = tuple  # (repo id | None, issue number)
Timed = tuple  # (datetime, row)


def index(rows: list[dict], keep, repo_id: str | None) -> dict[Key, list[Timed]]:
    """The rows `keep` accepts, by (repo, issue), each list in time order."""
    out: dict[Key, list[Timed]] = defaultdict(list)
    for row in rows:
        ts, issue = parse_ts(row.get("ts")), row.get("issue")
        if ts is None or not isinstance(issue, int) or not keep(row):
            continue
        if repo_id and row.get("repo") != repo_id:
            continue
        out[(row.get("repo"), issue)].append((ts, row))
    for timed in out.values():
        timed.sort(key=lambda p: p[0])
    return out


def with_repo(landing_rows: list[dict], other_rows: list[dict]) -> list[dict]:
    """Landing rows from writers that recorded no repository take the one repository whose other rows
    name the same issue; with none or several, the row stays without one."""
    repos: dict[int, set] = defaultdict(set)
    for row in other_rows:
        if row.get("repo"):
            repos[row.get("issue")].add(row["repo"])
    return [row if row.get("repo") or len(repos.get(row.get("issue"), ())) != 1
            else {**row, "repo": next(iter(repos[row["issue"]]))} for row in landing_rows]


def index_ticks(rows: list[dict]) -> dict[int, list[Timed]]:
    """Ticks by the issue their `claimed` names ("12", "#12" or "issue#12")."""
    out: dict[int, list[Timed]] = defaultdict(list)
    for row in rows:
        m = re.search(r"\d+", str(row.get("claimed") or ""))
        ts = parse_ts(row.get("ts"))
        if m and ts:
            out[int(m.group())].append((ts, row))
    return out


def tick_for(ticks: list[Timed], started: datetime) -> dict | None:
    """The tick written within the ten minutes before the attempt started, the latest if several."""
    near = [p for p in ticks if started - TICK_LEAD <= p[0] <= started]
    if not near:
        return None
    row = max(near, key=lambda p: p[0])[1]
    return {"tick_id": row.get("tick_id"), "model": row.get("model"),
            "gate_duration_ms": row.get("gate_duration_ms")}


@dataclass
class Attempt:
    repo: str | None
    issue: int
    n: int
    start: datetime
    started: str
    claim: dict | None
    next_attempt: str | None
    events: list[Timed]
    merges: list[Timed]
    landings: list[Timed]
    last: datetime
    transcript: Path | None = None


def attempts_of(key: Key, events: list[Timed], merges: list[Timed], landings: list[Timed]) -> list[Attempt]:
    """Split one (repo, issue)'s rows into attempts: [claim that opens one, the next such claim)."""
    ends = [ts for ts, row in events if row.get("event") in ATTEMPT_ENDS]
    ends += [ts for ts, row in landings if row.get("event") == "landed"]
    claims = [(ts, row) for ts, row in events if row.get("event") == "claimed"]

    def read_back(ts: datetime, worker) -> bool:
        return any(ts < t <= ts + READBACK and row.get("worker") == worker for t, row in claims)

    starts = []
    for ts, row in claims:
        if starts:
            start, _, claim = starts[-1]
            ended = any(start <= t <= ts for t in ends)
            same = claim is not None and claim.get("worker") == row.get("worker")
            lost_race = claim is not None and not same and not read_back(ts, row.get("worker"))
            if not ended and (same or lost_race):
                continue
        starts.append((ts, row["ts"], row))
    first = events[0] if events else min(merges + landings, key=lambda p: p[0])
    if not starts or first[0] < starts[0][0]:
        starts.insert(0, (first[0], first[1]["ts"], None))
    attempts = []
    for i, (start, started, claim) in enumerate(starts):
        nxt = starts[i + 1] if i + 1 < len(starts) else None

        def inside(rows: list[Timed]) -> list[Timed]:
            return [p for p in rows if p[0] >= start and (nxt is None or p[0] < nxt[0])]

        ev, me, la = inside(events), inside(merges), inside(landings)
        last = max([start] + [p[0] for p in ev + me + la])
        attempts.append(Attempt(key[0], key[1], i + 1, start, started, claim,
                                nxt[1] if nxt else None, ev, me, la, last))
    return attempts


# ── Transcripts ──────────────────────────────────────────────────────────────
def index_transcripts(log_dir: Path | None) -> dict[int, list[Path]]:
    out: dict[int, list[Path]] = defaultdict(list)
    if log_dir and log_dir.is_dir():
        for name in sorted(os.listdir(log_dir)):
            m = METRICS.NAME_RE.match(name)
            if m:
                out[int(m.group(2))].append(log_dir / name)
    return out


@functools.lru_cache(maxsize=None)
def first_stamp(path: Path) -> datetime | None:
    with open(path, errors="replace") as fh:
        for line in fh:
            try:
                d = json.loads(line)
            except ValueError:
                continue
            if isinstance(d, dict) and (d.get("timestamp") or d.get("ts")):
                return parse_ts(d.get("timestamp") or d.get("ts"))
    return None


def transcript_time(path: Path, started: datetime) -> datetime:
    stamp = first_stamp(path)
    if stamp:
        return stamp
    hhmmss = METRICS.NAME_RE.match(path.name).group(3)
    try:
        clock = time(int(hhmmss[:2]), int(hhmmss[2:4]), int(hhmmss[4:]))
    except ValueError:
        return datetime.fromtimestamp(path.stat().st_mtime, tz=UTC)
    day = started.astimezone().date()
    placed = [datetime.combine(day + timedelta(days=d), clock).astimezone() for d in (-1, 0, 1)]
    return min(placed, key=lambda t: abs(t - started))


def assign_transcripts(attempts: list[Attempt], paths: list[Path], slack: timedelta) -> None:
    """Give each transcript to the attempt whose start is nearest, among those whose window
    widened by `slack` holds its time; each attempt keeps the nearest transcript it was given."""
    best: dict[int, tuple] = {}
    for path in paths:
        fits = []
        for i, a in enumerate(attempts):
            t = transcript_time(path, a.start)
            if a.start - slack <= t <= a.last + slack:
                fits.append((abs(t - a.start), i))
        if not fits:
            continue
        dist, i = min(fits)
        if i not in best or (dist, str(path)) < best[i]:
            best[i] = (dist, str(path))
            attempts[i].transcript = path


def count_tools(path: Path) -> dict:
    """Tool calls and errors, each error charged to the tool its tool_use_id names."""
    names: dict = {}
    by_name: dict[str, dict] = defaultdict(lambda: {"calls": 0, "errors": 0})
    with open(path, errors="replace") as fh:
        for line in fh:
            try:
                d = json.loads(line)
            except ValueError:
                continue
            content = (d.get("message") or {}).get("content") if isinstance(d, dict) else None
            for block in content if isinstance(content, list) else ():
                if not isinstance(block, dict):
                    continue
                if block.get("type") == "tool_use":
                    name = block.get("name") or "unknown"
                    names[block.get("id")] = name
                    by_name[name]["calls"] += 1
                elif block.get("type") == "tool_result" and block.get("is_error"):
                    by_name[names.get(block.get("tool_use_id"), "unknown")]["errors"] += 1
    return {"calls": sum(v["calls"] for v in by_name.values()),
            "errors": sum(v["errors"] for v in by_name.values()),
            "by_name": dict(sorted(by_name.items()))}


def session_of(path: Path) -> dict:
    """A session with no result yet still reports its tools; the result's numbers are null."""
    s = METRICS.read_session(str(path))
    done = not s.get("in_flight")
    return {"path": str(path), "model": s.get("model"),
            "num_turns": s["num_turns"] if done else None,
            "duration_ms": s["duration_ms"] if done else None,
            "cost_usd": s["cost_usd"] if done else None,
            "is_error": s["is_error"] if done else None,
            "tools": count_tools(path)}


# ── One attempt's trace ──────────────────────────────────────────────────────
def gates_of(events: list[Timed], merges: list[Timed]) -> list[dict]:
    """One gate per gate-end step, with its merge row's detail; leftover merge rows are gates too."""
    rows_by_attempt: dict = defaultdict(list)
    for _, row in merges:
        rows_by_attempt[row.get("attempt")].append(row)

    def gate(n, end: dict, merge: dict) -> dict:
        return {"attempt": n,
                "outcome": first_not_none(end.get("outcome"), merge.get("outcome")),
                "duration_s": first_not_none(end.get("duration_s"), merge.get("duration_s")),
                "tests_failed": merge.get("gate_tests_failed"),
                "conflict_files": merge.get("files"),
                "red_base": merge.get("red_base"),
                "escalated": merge.get("escalated"),
                "reason": first_not_none(end.get("reason"), merge.get("reason"))}

    gates = []
    for _, row in events:
        if row.get("event") == "gate-end":
            end = row.get("detail") or {}
            matched = rows_by_attempt.get(end.get("attempt")) or [{}]
            gates.append(gate(end.get("attempt"), end, matched.pop(0)))
    gates += [gate(m.get("attempt"), {}, m) for rows in rows_by_attempt.values() for m in rows]
    return sorted(gates, key=lambda g: (g["attempt"] is None, g["attempt"] or 0))


def landing_detail(row: dict) -> dict:
    if row["event"] == "landed":
        return {"batch": row.get("batch"), "sha": row.get("sha")}
    return {k: v for k, v in row.items() if k not in LANDING_ROW_KEYS}


def steps_of(a: Attempt) -> list[dict]:
    timed = [(ts, {"ts": row["ts"], "kind": row["event"], "source": "issue-events",
                   "detail": row.get("detail") or {}}) for ts, row in a.events]
    timed += [(ts, {"ts": row["ts"], "kind": row["event"], "source": "landing-timings",
                    "detail": landing_detail(row)})
              for ts, row in a.landings if row.get("event") in LANDING_STEPS]
    timed.sort(key=lambda p: p[0])
    return [step for _, step in timed]


def outcome_of(steps: list[dict], gates: list[dict], a: Attempt, session: dict | None) -> tuple[str, str | None]:
    """(outcome, ended) by the spec's table, over this attempt's own steps and gates."""
    def last(kind: str) -> int | None:
        return next((i for i in range(len(steps) - 1, -1, -1) if steps[i]["kind"] == kind), None)

    landed, escalated = last("landed"), last("escalated")
    if landed is not None:
        return "landed", steps[landed]["ts"]
    if escalated is not None:
        return "escalated", steps[escalated]["ts"]
    release, gate_end = last("released"), last("gate-end")
    if release is not None and gate_end is not None and release < gate_end:
        release = None
    last_seen = max([(a.start, a.started)] + [(ts, row["ts"]) for ts, row in a.events + a.merges + a.landings],
                    key=lambda p: p[0])[1]
    ended = steps[release]["ts"] if release is not None else (last_seen if a.next_attempt else None)
    if gates and gates[-1]["outcome"] not in GATE_OUTCOMES_NOT_RETURNED and ended:
        return "returned", ended
    if release is not None:
        return "released", ended
    if a.next_attempt or (session and session["is_error"] is True):
        return "abandoned", ended or last_seen
    return "open", None


def review_of(issue: int, comments_dir: Path | None) -> dict | None:
    if comments_dir is None:
        return None
    rv = METRICS.review_of(METRICS.fetch_issue(issue, str(comments_dir)))
    if rv["status"] != "reviewed":
        return {"status": rv["status"]}
    return {k: rv[k] for k in ("status", "rounds", "verdict", "findings", "resolutions")}


def trace_of(a: Attempt, ticks: list[Timed], comments_dir: Path | None) -> dict:
    steps = steps_of(a)
    gates = gates_of(a.events, a.merges)
    session = session_of(a.transcript) if a.transcript else None
    outcome, ended = outcome_of(steps, gates, a, session)
    return {
        "v": 1,
        "trace_id": f"{a.repo}:{a.issue}:{a.n}",
        "repo": a.repo, "issue": a.issue, "attempt": a.n,
        "worker": (a.claim or {}).get("worker"), "branch": (a.claim or {}).get("branch"),
        "started": a.started, "ended": ended, "next_attempt": a.next_attempt,
        "outcome": outcome,
        "steps": steps,
        "gates": gates,
        "returned": [{"ts": row["ts"], "cause": row.get("cause")}
                     for _, row in a.landings if row.get("event") == "returned"],
        "session": session,
        "review": review_of(a.issue, comments_dir),
        "tick": tick_for(ticks, a.start),
    }


def build_traces(ledgers: dict[str, list[dict]], *, log_dir: Path | None = None,
                 comments_dir: Path | None = None, repo_id: str | None = None,
                 slack: timedelta = timedelta(hours=1),
                 since: datetime | None = None, until: datetime | None = None) -> list[dict]:
    events = index(ledgers["issue-events"], lambda r: r.get("v") == 1 and bool(r.get("event")), repo_id)
    merges = index(ledgers["merge-events"], lambda r: r.get("event") == "attempt", repo_id)
    landings = index(with_repo(ledgers["landing-timings"], ledgers["issue-events"] + ledgers["merge-events"]),
                     lambda r: r.get("kind") == "change", repo_id)
    ticks = index_ticks(ledgers["gate-log"])

    attempts: list[Attempt] = []
    for key in sorted(set(events) | set(merges) | set(landings), key=lambda k: (k[0] or "", k[1])):
        attempts += attempts_of(key, events.get(key, []), merges.get(key, []), landings.get(key, []))

    for issue, paths in index_transcripts(log_dir).items():
        assign_transcripts([a for a in attempts if a.issue == issue], paths, slack)

    return [trace_of(a, ticks.get(a.issue, []), comments_dir) for a in attempts
            if (since is None or a.start >= since) and (until is None or a.start < until)]


def autocoder_config(directory) -> dict:
    """The repository's main-worktree .autocoder.json as a dict ({} when there is none or it cannot be read).
    Copied from landing-report.py, which is too large to import for ten lines."""
    try:
        r = subprocess.run(["git", "-C", str(directory), "rev-parse", "--git-common-dir"], capture_output=True, text=True)
        main = (Path(directory) / r.stdout.strip()).resolve().parent if r.returncode == 0 and r.stdout.strip() else Path(directory)
        raw = json.loads((main / ".autocoder.json").read_text())
        return raw if isinstance(raw, dict) else {}
    except (OSError, ValueError, TypeError):
        return {}


def train_gate_issue(directory) -> int | None:
    """`train.gateIssue` of the repository's main-worktree .autocoder.json, or None when there is none."""
    try:
        n = int((autocoder_config(directory).get("train") or {}).get("gateIssue") or 0)
        return n or None
    except (ValueError, TypeError):
        return None


def write_traces(traces: list[dict], out: str) -> None:
    text = "".join(json.dumps(t, separators=(",", ":")) + "\n" for t in traces)
    if out == "-":
        sys.stdout.write(text)
        return
    path = Path(out)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=path.name + ".")
    with os.fdopen(fd, "w") as fh:
        fh.write(text)
    os.replace(tmp, path)


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Compile one trace per issue attempt from the autocoder ledgers.")
    for name, (env_var, file_name) in LEDGERS.items():
        p.add_argument(f"--{name}", type=Path, default=state_path(env_var, file_name))
    p.add_argument("--log-dir", type=Path, default=Path(METRICS.LOG_DIR), help="worker transcripts")
    p.add_argument("--comments-dir", type=Path,
                   help="<issue>.json documents as issue_get prints them; without it, review is null")
    p.add_argument("--out", default=str(state_path("AUTOCODER_TRACES", "traces.jsonl")), help="`-` for stdout")
    p.add_argument("--since", type=parse_bound, help="keep attempts started at or after (YYYY-MM-DD or ISO)")
    p.add_argument("--until", type=parse_bound, help="keep attempts started before (YYYY-MM-DD or ISO)")
    p.add_argument("--repo-id", help="only this repository (default: every repository)")
    p.add_argument("--slack", type=float, default=60.0, help="transcript join slack in minutes")
    p.add_argument("--repo", default=os.getcwd(),
                   help="the repository whose .autocoder.json names the train's gate issue (default: the current directory)")
    p.add_argument("--train-gate-issue", type=int,
                   help="drop this issue's traces (default: train.gateIssue from --repo's config; 0 keeps them)")
    args = p.parse_args(argv)

    ledgers, malformed = {}, {}
    for name in LEDGERS:
        ledgers[name], malformed[name] = read_ledger(getattr(args, name.replace("-", "_")))
    skipped = [f"{name} {count}" for name, count in malformed.items() if count]
    if skipped:
        print("trace-build: skipped malformed lines: " + ", ".join(skipped), file=sys.stderr)

    traces = build_traces(ledgers, log_dir=args.log_dir, comments_dir=args.comments_dir,
                          repo_id=args.repo_id, slack=timedelta(minutes=args.slack),
                          since=args.since, until=args.until)
    gate = args.train_gate_issue if args.train_gate_issue is not None else train_gate_issue(args.repo)
    if gate:
        kept = [t for t in traces if t["issue"] != gate]
        if len(kept) < len(traces):
            print(f"trace-build: dropped {len(traces) - len(kept)} traces of train gate issue {gate}", file=sys.stderr)
        traces = kept
    write_traces(traces, args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
