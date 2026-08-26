#!/usr/bin/env python3
"""issue-metrics.py — token / time / cost per issue, from worker transcripts.

WHY THIS EXISTS:
  Workers run headless (`claude -p --output-format stream-json`), and
  claude-worker-loop.sh tees every session to
  `$AUTOCODER_LOG_DIR/worker-<looppid>-<label>-<HHMMSS>.jsonl`. The terminal
  `result` event of each session already carries exactly what it cost to do the
  work — duration_ms, duration_api_ms, num_turns, total_cost_usd, and the full
  usage block — but nothing read it, so the price of a fix was visible only as a
  line item on a monthly bill with no way to attribute it to an issue.

  This turns those transcripts into a per-issue number, and (via
  post-issue-metrics.sh) a comment on the issue itself, so the cost of a change
  lives next to the change.

ATTRIBUTION CAVEATS — stated here and in the rendered comment, because these
numbers are otherwise easy to over-read:
  * Only `fix-<N>` sessions are attributable to an issue. `gate-*` sessions
    (issue selection) are shared overhead with no single owner and are excluded,
    so per-issue totals UNDERCOUNT what the swarm actually spent.
  * Aggregate mode sums EVERY session on an issue, including retried and
    abandoned attempts. That is deliberate — the money was really spent on that
    issue — but it means a hard issue's number includes its false starts.
  * Wall-clock is summed session duration, not elapsed calendar time. Sessions
    run back to back add up; a session idling between tool calls still counts.
  * A session still in flight has no `result` event. It is counted separately as
    `in_flight` and never folded into the totals, so a running fix cannot
    inflate (or, worse, silently zero) an issue's cost.

USAGE
  issue-metrics.py                        # table for every issue with transcripts
  issue-metrics.py 1455 1442              # only these issues
  issue-metrics.py --json
  issue-metrics.py --markdown 1455        # aggregate comment body for one issue
  issue-metrics.py --session PATH --markdown   # one session's comment body
  issue-metrics.py --since 2026-08-25     # filter by session end date
"""

import argparse
import datetime as dt
import json
import os
import re
import sys
from collections import defaultdict

LOG_DIR = os.environ.get("AUTOCODER_LOG_DIR", "/tmp/autocoder-logs")

# worker-<looppid>-fix-<issue>-<HHMMSS>.jsonl. The `fix-` segment is what makes a
# transcript attributable; gate transcripts match a different label and are
# deliberately not matched here.
NAME_RE = re.compile(r"^worker-(\d+)-fix-(\d+)-(\d{6})\.jsonl$")

MARKER_PREFIX = "<!-- autocoder-metrics"

EMPTY = {
    "sessions": 0, "in_flight": 0, "errors": 0,
    "duration_ms": 0, "duration_api_ms": 0, "num_turns": 0, "cost_usd": 0.0,
    "input_tokens": 0, "output_tokens": 0, "cache_read": 0, "cache_write": 0,
}


def new_agg():
    a = dict(EMPTY)
    a.update({"models": set(), "providers": set(), "first": None, "last": None,
              "files": []})
    return a


def read_session(path):
    """Parse one transcript. Returns None-ish dict with in_flight=True if the
    session has not finished (no terminal `result` event yet)."""
    result = None
    model = None
    with open(path, errors="replace") as fh:
        for line in fh:
            try:
                d = json.loads(line)
            except Exception:
                continue           # a partially-written last line is normal
            if d.get("type") == "result":
                result = d
            m = d.get("model") or (d.get("message") or {}).get("model")
            if m:
                model = m
    if result is None:
        return {"in_flight": True, "model": model}

    u = result.get("usage") or {}
    mu = result.get("modelUsage") or {}
    provider = next((v.get("provider") for v in mu.values() if v.get("provider")), None)
    return {
        "in_flight": False,
        "model": model,
        "provider": provider,
        "duration_ms": result.get("duration_ms") or 0,
        "duration_api_ms": result.get("duration_api_ms") or 0,
        "num_turns": result.get("num_turns") or 0,
        "cost_usd": result.get("total_cost_usd") or 0.0,
        "input_tokens": u.get("input_tokens") or 0,
        "output_tokens": u.get("output_tokens") or 0,
        "cache_read": u.get("cache_read_input_tokens") or 0,
        "cache_write": u.get("cache_creation_input_tokens") or 0,
        "is_error": bool(result.get("is_error")),
    }


def fold(agg, s, path):
    """Fold one parsed session into an aggregate."""
    agg["files"].append(os.path.basename(path))
    if s.get("model"):
        agg["models"].add(s["model"])
    if s["in_flight"]:
        agg["in_flight"] += 1
        return agg

    agg["sessions"] += 1
    if s.get("is_error"):
        agg["errors"] += 1
    if s.get("provider"):
        agg["providers"].add(s["provider"])
    for k in ("duration_ms", "duration_api_ms", "num_turns", "cost_usd",
              "input_tokens", "output_tokens", "cache_read", "cache_write"):
        agg[k] += s[k]

    # The filename carries only HHMMSS, so the calendar date comes from mtime —
    # which is the session's END, since the file is appended to throughout.
    end = dt.datetime.fromtimestamp(os.path.getmtime(path))
    start = end - dt.timedelta(milliseconds=s["duration_ms"])
    agg["first"] = start if agg["first"] is None else min(agg["first"], start)
    agg["last"] = end if agg["last"] is None else max(agg["last"], end)
    return agg


def issue_of(path):
    m = NAME_RE.match(os.path.basename(path))
    return int(m.group(2)) if m else None


def collect(only=None, since=None, log_dir=None):
    log_dir = log_dir or LOG_DIR
    issues = defaultdict(new_agg)
    if not os.path.isdir(log_dir):
        return issues
    for name in sorted(os.listdir(log_dir)):
        m = NAME_RE.match(name)
        if not m:
            continue
        issue = int(m.group(2))
        if only and issue not in only:
            continue
        path = os.path.join(log_dir, name)
        if since and dt.datetime.fromtimestamp(os.path.getmtime(path)).date() < since:
            continue
        fold(issues[issue], read_session(path), path)
    return issues


def hms(ms):
    total = int(ms // 1000)
    h, rem = divmod(total, 3600)
    m, s = divmod(rem, 60)
    return f"{h}h {m}m" if h else (f"{m}m {s}s" if m else f"{s}s")


def markdown(issue, a, session_file=None):
    """Render the issue comment. `session_file` set => one-session report."""
    marker = (f"{MARKER_PREFIX} session={session_file} -->" if session_file
              else f"{MARKER_PREFIX} aggregate -->")
    total_in = a["input_tokens"] + a["cache_read"] + a["cache_write"]
    scope = "this fix session" if session_file else f"{a['sessions']} session(s)"

    rows = [
        ("Agent wall-clock", hms(a["duration_ms"])),
        ("Model API time", hms(a["duration_api_ms"])),
        ("Turns", f"{a['num_turns']:,}"),
        ("Cost", f"${a['cost_usd']:,.2f}"),
        ("Input tokens (fresh)", f"{a['input_tokens']:,}"),
        ("Output tokens", f"{a['output_tokens']:,}"),
        ("Cache read / write", f"{a['cache_read']:,} / {a['cache_write']:,}"),
        ("Total input incl. cache", f"{total_in:,}"),
    ]
    if not session_file:
        sess = f"{a['sessions']}"
        if a["errors"]:
            sess += f" ({a['errors']} errored)"
        rows.insert(0, ("Agent sessions", sess))
    model = ", ".join(sorted(a["models"])) or "unknown"
    if a["providers"]:
        model += f" ({', '.join(sorted(a['providers']))})"
    rows.append(("Model", model))
    if a["first"] and a["last"]:
        rows.append(("Window", f"{a['first']:%Y-%m-%d %H:%M} → {a['last']:%H:%M}"))

    out = [marker, "### Implementation metrics (autocoder swarm)", "",
           "| Metric | Value |", "| --- | --- |"]
    out += [f"| {k} | {v} |" for k, v in rows]

    footnote = (
        f"<sub>Measured over {scope} from the headless worker transcript"
        f"{'' if session_file else 's'} "
        f"(<code>worker-*-fix-{issue}-*.jsonl</code>). "
    )
    if not session_file:
        footnote += "Includes retried and abandoned attempts on this issue. "
    footnote += ("Excludes shared issue-selection (<code>gate</code>) overhead, "
                 "so this undercounts total swarm cost.</sub>")
    out += ["", footnote]
    return "\n".join(out)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("issues", nargs="*", type=int)
    p.add_argument("--session", help="report on a single transcript file")
    p.add_argument("--issue", type=int, help="issue number for --session (else parsed from the filename)")
    p.add_argument("--json", action="store_true")
    p.add_argument("--markdown", action="store_true")
    p.add_argument("--since", help="YYYY-MM-DD; drop sessions that ended earlier")
    p.add_argument("--log-dir", default=LOG_DIR)
    args = p.parse_args()

    if args.session:
        if not os.path.isfile(args.session):
            print(f"issue-metrics: no such transcript: {args.session}", file=sys.stderr)
            return 2
        s = read_session(args.session)
        if s["in_flight"]:
            print("issue-metrics: session still in flight (no result event)", file=sys.stderr)
            return 3
        issue = args.issue or issue_of(args.session)
        if issue is None:
            print("issue-metrics: cannot infer issue number; pass --issue", file=sys.stderr)
            return 2
        a = fold(new_agg(), s, args.session)
        print(markdown(issue, a, session_file=os.path.basename(args.session))
              if args.markdown else json.dumps(s, indent=2))
        return 0

    since = dt.date.fromisoformat(args.since) if args.since else None
    data = collect(set(args.issues) or None, since, args.log_dir)
    if not data:
        print("issue-metrics: no matching transcripts", file=sys.stderr)
        return 1

    if args.markdown:
        for issue in sorted(data):
            print(markdown(issue, data[issue]))
            print()
        return 0

    if args.json:
        out = {}
        for issue, a in data.items():
            e = dict(a)
            e["models"] = sorted(a["models"])
            e["providers"] = sorted(a["providers"])
            e["first"] = a["first"].isoformat() if a["first"] else None
            e["last"] = a["last"].isoformat() if a["last"] else None
            out[str(issue)] = e
        print(json.dumps(out, indent=2))
        return 0

    print(f"{'ISSUE':>7} {'SESS':>5} {'FLY':>4} {'WALL':>9} {'TURNS':>7} "
          f"{'COST':>9} {'OUT_TOK':>10} {'CACHE_RD':>12}")
    tc = tt = 0.0
    for issue in sorted(data):
        a = data[issue]
        tc += a["cost_usd"]
        tt += a["duration_ms"]
        print(f"{issue:>7} {a['sessions']:>5} {a['in_flight']:>4} "
              f"{hms(a['duration_ms']):>9} {a['num_turns']:>7,} "
              f"${a['cost_usd']:>8,.2f} {a['output_tokens']:>10,} "
              f"{a['cache_read']:>12,}")
    print(f"{'TOTAL':>7} {'':>5} {'':>4} {hms(tt):>9} {'':>7} ${tc:>8,.2f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
