#!/usr/bin/env python3
"""Landing report: where the time and the gate-minutes of landing changes go. WASTE FIRST.

Reads landing-timings.jsonl (landing-timings.py). With --history it also reconstructs the same
rows for the period BEFORE the writer existed, from the issue tracker (through issue-fns.sh's
source abstraction), git history of the integration branch and, when present, the plugin's own
merge-events.jsonl, so a project can reproduce its baseline.

  landing-report.py [--since DATE] [--until DATE] [--bucket day|week] [--log PATH] [--json]
                    [--history [--repo DIR] [--integration BRANCH] [--merge-events PATH]
                               [--batch-subject-regex RE] [--skip-subject-regex RE] [--ready-regex RE] [--claim-regex RE]
                               [--rules JSON] [--export-rows PATH] [--limit N]]

Sections, in order: waste (gate-minutes thrown away; changes returned by cause; rebases and
pre-checks per change), then build time (claim to READY), wait after READY, cycle time, batch
size distribution, capacity against demand, rejected pushes, red batches by cause.
A figure the rows do not carry prints n/a, never 0.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import statistics
import subprocess
import sys
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
USEFUL_CAUSE = "defect"
DEFAULT_RULES = {
    # first match wins; evaluated on a comment that already matched the return pattern
    "return_pattern": r"(?i)needs-rebase|dropped from|train.*(dropped|failed|returned)|gate (failed|red)|returned to|bounced|rejected",
    "causes": [
        ["docs-resync", r"(?i)docs-resync|documents-only re-?sync"],
        ["red-integration", r"(?i)red (master|main|integration)|master is red"],
        ["infra", r"(?i)INFRASTRUCTURE|ENOSPC|disk (full|space)|out of memory|OOM|host condition"],
        ["conflict", r"(?i)conflict"],
        ["stale-base", r"(?i)stale|needs-rebase|behind (master|main|origin)|re-?sync"],
        ["defect", r"(?i)fail|red|regress|broke"],
    ],
}


# ── time helpers ───────────────────────────────────────────────────────────
def parse_ts(s):
    if not s:
        return None
    s = s.strip().replace("Z", "+00:00")
    try:
        d = datetime.fromisoformat(s)
    except ValueError:
        try:
            d = datetime.fromisoformat(s + "T00:00:00+00:00")
        except ValueError:
            return None
    return d if d.tzinfo else d.replace(tzinfo=timezone.utc)


def iso(d):
    return d.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def human(sec):
    if sec is None:
        return "n/a"
    sec = float(sec)
    if sec < 90:
        return f"{sec:.0f}s"
    if sec < 5400:
        return f"{sec / 60:.1f}m"
    if sec < 172800:
        return f"{sec / 3600:.1f}h"
    return f"{sec / 86400:.1f}d"


def pct(part, whole):
    return "n/a" if not whole else f"{100.0 * part / whole:.0f}%"


def quant(vals, q):
    if not vals:
        return None
    vals = sorted(vals)
    k = (len(vals) - 1) * q
    lo, hi = int(k), min(int(k) + 1, len(vals) - 1)
    return vals[lo] + (vals[hi] - vals[lo]) * (k - lo)


def dist(vals):
    if not vals:
        return {"n": 0, "p50": None, "p90": None, "max": None}
    return {"n": len(vals), "p50": quant(vals, 0.5), "p90": quant(vals, 0.9), "max": max(vals)}


def bucket_key(d, bucket):
    if bucket == "day":
        return d.strftime("%Y-%m-%d")
    monday = (d - timedelta(days=d.weekday())).strftime("%Y-%m-%d")
    return f"wk {monday}"


# ── reading rows ───────────────────────────────────────────────────────────
def load_rows(path):
    rows, bad = [], 0
    if path and Path(path).exists():
        for line in Path(path).read_text(errors="replace").splitlines():
            if not line.strip():
                continue
            try:
                r = json.loads(line)
                if isinstance(r, dict) and parse_ts(r.get("ts")) and r.get("kind") in ("change", "batch"):
                    rows.append(r)
                else:
                    bad += 1
            except json.JSONDecodeError:
                bad += 1
    return rows, bad


def default_log():
    env = os.environ.get("AUTOCODER_LANDING_TIMINGS")
    if env:
        return env
    state = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
    return os.path.join(state, "autocoder", "landing-timings.jsonl")


# ── analysis ───────────────────────────────────────────────────────────────
def analyze(rows, since, until, bucket="week"):
    def inwin(r):
        t = parse_ts(r["ts"])
        return (since is None or t >= since) and (until is None or t < until)

    ev = defaultdict(list)  # issue -> [(t, event, row)] up to `until`
    for r in rows:
        if r["kind"] == "change" and (until is None or parse_ts(r["ts"]) < until):
            ev[r["issue"]].append((parse_ts(r["ts"]), r["event"], r))
    for v in ev.values():
        v.sort(key=lambda x: x[0])
    batches = [r for r in rows if r["kind"] == "batch" and inwin(r)]

    # waste: gate-minutes
    measured = [b for b in batches if b.get("gate_s") is not None]
    total_gate = sum(b["gate_s"] for b in measured)
    wasted = 0.0
    waste_by = Counter()
    for b in measured:
        if b.get("verdict") in ("red", "aborted", "infra"):
            wasted += b["gate_s"]
            waste_by[f"{b['verdict']}:{b.get('cause') or 'unknown'}"] += b["gate_s"]
        elif b.get("discarded_gate_s"):
            wasted += b["discarded_gate_s"]
            waste_by["re-gate after re-sync"] += b["discarded_gate_s"]

    # returned
    seen = {i for i, es in ev.items() if any(inwin(e[2]) and e[1] in ("ready", "batched", "landed", "returned") for e in es)}
    ret_by = defaultdict(set)
    for i, es in ev.items():
        for t, e, r in es:
            if e == "returned" and inwin(r):
                ret_by[r.get("cause") or "unknown"].add(i)
    returned = set().union(*ret_by.values()) if ret_by else set()

    # per-change timings
    build, wait, cycle, total = [], [], [], []
    landed_issues = []
    for i, es in ev.items():
        landed = [t for t, e, r in es if e == "landed" and inwin(r)]
        claimed = [t for t, e, r in es if e == "claimed"]
        ready = [t for t, e, r in es if e == "ready"]
        if ready and claimed and any(since is None or t >= since for t in ready) and min(claimed) <= min(ready):
            build.append((min(ready) - min(claimed)).total_seconds())
        if not landed:
            continue
        lt = max(landed)
        landed_issues.append(i)
        rdy = [t for t in ready if t <= lt]
        bat = [t for t, e, r in es if e == "batched" and t <= lt]
        if rdy:
            fr = max(rdy)
            wait.append(((max(bat) if bat and max(bat) >= fr else lt) - fr).total_seconds())
            cycle.append((lt - fr).total_seconds())
        if claimed and min(claimed) <= lt:
            total.append((lt - min(claimed)).total_seconds())
    rebases = [sum(1 for t, e, r in ev[i] if e == "rebase") for i in landed_issues]
    prechecks = [sum(1 for t, e, r in ev[i] if e == "precheck") for i in landed_issues]
    rebase_recorded = any(e == "rebase" for es in ev.values() for t, e, r in es)
    precheck_recorded = any(e == "precheck" for es in ev.values() for t, e, r in es)

    sizes = Counter(len(b["members"]) for b in batches)
    stage_tot = Counter()
    for b in batches:
        for k, v in (b.get("stages") or {}).items():
            stage_tot[k] += v
    asm = [b["assembly_s"] for b in batches if b.get("assembly_s") is not None]
    pub = [b["publish_s"] for b in batches if b.get("publish_s") is not None]
    red = Counter(b.get("cause") or "unknown" for b in batches if b.get("verdict") in ("red", "aborted", "infra"))
    pushrej = sum(b.get("push_rejected") or 0 for b in batches)
    resyncs = sum(b.get("resyncs") or 0 for b in batches)

    # buckets: waste, returns and capacity vs demand
    bk = defaultdict(lambda: {"ready": 0, "landed": 0, "batches": 0, "gate_s": 0.0, "wasted_s": 0.0,
                              "returned": set(), "seen": set()})
    for i, es in ev.items():
        for t, e, r in es:
            if not inwin(r):
                continue
            b = bk[bucket_key(t, bucket)]
            if e == "ready":
                b["ready"] += 1
            elif e == "landed":
                b["landed"] += 1
            if e in ("ready", "batched", "landed", "returned"):
                b["seen"].add(i)
            if e == "returned":
                b["returned"].add(i)
    for r in batches:
        b = bk[bucket_key(parse_ts(r["ts"]), bucket)]
        b["batches"] += 1
        if r.get("gate_s") is not None:
            b["gate_s"] += r["gate_s"]
            if r.get("verdict") in ("red", "aborted", "infra"):
                b["wasted_s"] += r["gate_s"]
            elif r.get("discarded_gate_s"):
                b["wasted_s"] += r["discarded_gate_s"]

    return {
        "window": {"since": iso(since) if since else None, "until": iso(until) if until else None},
        "waste": {
            "gate_s_total": total_gate if measured else None, "gate_s_wasted": wasted if measured else None,
            "share": (wasted / total_gate) if measured and total_gate else None,
            "batches_measured": len(measured), "batches_unmeasured": len(batches) - len(measured),
            "by": dict(waste_by),
            "changes_seen": len(seen), "changes_returned": len(returned),
            "returned_by_cause": {k: len(v) for k, v in ret_by.items()},
            "useful_returned": len(ret_by.get(USEFUL_CAUSE, set())),
            "rebases_per_change": dist(rebases) if rebase_recorded else None,
            "prechecks_per_change": dist(prechecks) if precheck_recorded else None,
        },
        "timings": {"build_s": dist(build), "wait_s": dist(wait), "cycle_s": dist(cycle), "claim_to_landed_s": dist(total)},
        "batches": {"count": len(batches), "size_distribution": {str(k): v for k, v in sorted(sizes.items())},
                    "assembly_s": dist(asm), "publish_s": dist(pub), "stage_s_total": dict(stage_tot),
                    "resyncs": resyncs, "push_rejected": pushrej, "red_by_cause": dict(red)},
        "buckets": {k: {**v, "returned": len(v["returned"]), "seen": len(v["seen"])} for k, v in sorted(bk.items())},
        "landed": len(landed_issues),
    }


# ── markdown ───────────────────────────────────────────────────────────────
def render(a):
    w, t, b = a["waste"], a["timings"], a["batches"]
    out = ["# Landing report", "", f"Window: {a['window']['since'] or 'start'} to {a['window']['until'] or 'now'}", "",
           "## Waste (leads: only a defect in the change is a useful rejection)", ""]
    if w["share"] is None:
        out.append("- Gate-minutes thrown away: n/a (no batch row carries gate seconds)")
    else:
        out.append(f"- Gate-minutes thrown away: {human(w['gate_s_wasted'])} of {human(w['gate_s_total'])} = "
                   f"{w['share'] * 100:.0f}% ({w['batches_measured']} batches measured, {w['batches_unmeasured']} not)")
        for k, v in sorted(w["by"].items(), key=lambda kv: -kv[1]):
            out.append(f"  - {k}: {human(v)}")
    out.append(f"- Changes returned at least once: {w['changes_returned']} of {w['changes_seen']} = "
               f"{pct(w['changes_returned'], w['changes_seen'])}; useful (defect in the change): {w['useful_returned']}")
    for k, v in sorted(w["returned_by_cause"].items(), key=lambda kv: -kv[1]):
        out.append(f"  - {k}: {v}" + ("" if k == USEFUL_CAUSE else "  (waste)"))
    for label, d in (("Rebases per landed change", w["rebases_per_change"]), ("Pre-checks per landed change", w["prechecks_per_change"])):
        out.append(f"- {label}: " + ("n/a (not recorded)" if d is None else
                   f"p50 {d['p50']:.0f}, p90 {d['p90']:.0f}, max {d['max']:.0f} over {d['n']} changes"))
    out += ["", "## Time", ""]
    for label, key in (("Build (claim to READY)", "build_s"), ("Wait after READY (to taken into a batch)", "wait_s"),
                       ("Cycle (READY to landed)", "cycle_s"), ("Claim to landed", "claim_to_landed_s")):
        d = t[key]
        out.append(f"- {label}: " + ("n/a" if not d["n"] else f"p50 {human(d['p50'])}, p90 {human(d['p90'])}, max {human(d['max'])} (n={d['n']})"))
    out += ["", "## Batches", "", f"- Batches: {b['count']}; landed changes: {a['landed']}",
            "- Size distribution (members: batches): " + (", ".join(f"{k}: {v}" for k, v in b["size_distribution"].items()) or "n/a"),
            f"- Assembly: " + ("n/a" if not b["assembly_s"]["n"] else f"p50 {human(b['assembly_s']['p50'])}, p90 {human(b['assembly_s']['p90'])}"),
            f"- Publish: " + ("n/a" if not b["publish_s"]["n"] else f"p50 {human(b['publish_s']['p50'])}, p90 {human(b['publish_s']['p90'])}"),
            f"- Re-syncs: {b['resyncs']}; rejected pushes: {b['push_rejected']}",
            "- Red batches by cause: " + (", ".join(f"{k}: {v}" for k, v in sorted(b["red_by_cause"].items())) or "none")]
    if b["stage_s_total"]:
        tot = sum(b["stage_s_total"].values())
        out.append("- Gate stage time: " + ", ".join(f"{k} {human(v)} ({pct(v, tot)})" for k, v in sorted(b["stage_s_total"].items(), key=lambda kv: -kv[1])))
    out += ["", "## Capacity against demand", "",
            "| period | READY (demand) | landed (capacity) | backlog change | batches | gate time | wasted | returned/seen |",
            "|---|---|---|---|---|---|---|---|"]
    for k, v in a["buckets"].items():
        out.append(f"| {k} | {v['ready']} | {v['landed']} | {v['ready'] - v['landed']:+d} | {v['batches']} | "
                   f"{human(v['gate_s']) if v['gate_s'] else 'n/a'} | {pct(v['wasted_s'], v['gate_s'])} | {v['returned']}/{v['seen']} |")
    return "\n".join(out) + "\n"


# ── history mode ───────────────────────────────────────────────────────────
def sh(cmd, cwd):
    r = subprocess.run(cmd, cwd=cwd, shell=True, capture_output=True, text=True, executable="/bin/bash")
    return r.returncode, r.stdout, r.stderr


def classify(text, rules):
    for cause, pat in rules["causes"]:
        if re.search(pat, text):
            return cause
    return "other"


def tracker_rows(repo, rules, ready_re, claim_re, limit, only=None):
    """Change rows from the issue tracker's comments. `only` is the set of issue numbers to read (the
    ones that landed in the window): one tracker call each, so a big tracker is not read whole;
    None reads every issue issue_list returns. A tracker call that fails is reported, never silent."""
    from concurrent.futures import ThreadPoolExecutor

    fns = HERE / "issue-fns.sh"
    if only is None:
        rc, out, err = sh(f'source "{fns}" && issue_list --state all --limit {int(limit)}', repo)
        if rc != 0:
            raise RuntimeError(f"issue_list failed in {repo} (rc {rc}): {err.strip()[:300]}")
        only = {it["number"] for it in json.loads(out or "[]")}

    def one(n):
        rc, out, err = sh(f'source "{fns}" && issue_get {int(n)}', repo)
        if rc != 0:
            print(f"landing-report: issue_get {n} failed (rc {rc}): {err.strip()[:200]}", file=sys.stderr)
            return []
        rows, first_claim = [], True
        for c in (json.loads(out).get("comments") or []):
            ts, body = c.get("createdAt") or c.get("created_at"), c.get("body") or ""
            if not parse_ts(ts):
                continue
            head = body.strip()[:400]
            if ready_re.search(head):
                rows.append({"v": 1, "ts": ts, "kind": "change", "issue": n, "event": "ready", "batch": None, "cause": None})
            elif first_claim and claim_re.search(head):
                first_claim = False
                rows.append({"v": 1, "ts": ts, "kind": "change", "issue": n, "event": "claimed", "batch": None, "cause": None})
            elif re.search(rules["return_pattern"], head):
                rows.append({"v": 1, "ts": ts, "kind": "change", "issue": n, "event": "returned", "batch": None,
                             "cause": classify(head, rules)})
        return rows

    with ThreadPoolExecutor(8) as ex:
        return [r for part in ex.map(one, sorted(only)) for r in part]


def git_rows(repo, integration, since, batch_re, skip_re):
    """Landings and batches from first-parent history of the integration branch.

    A commit whose subject matches batch_re (group 1 the batch id, group 2 the issue number) is one
    member of that batch; every commit of one batch id forms ONE batch (the train's single gate). A
    commit starting `#N` that skip_re does not exclude is a batch of one. Commit time stands in for
    landing time, so wait and cycle read slightly short of a push-time record."""
    ref = f"origin/{integration}"
    if sh(f"git rev-parse --verify -q {ref}", repo)[0] != 0:
        ref = integration
    since_arg = f'--since="{iso(since)}"' if since else ""
    rc, out, err = sh(f'git log --first-parent {since_arg} --format="%H%x1f%cI%x1f%s" {ref}', repo)
    if rc != 0:
        raise RuntimeError(f"git log {ref} failed in {repo}: {err.strip()[:300]}")
    rows, groups = [], {}
    for line in out.splitlines():
        h, cdate, subj = (line.split("\x1f") + ["", "", ""])[:3]
        ts = iso(parse_ts(cdate))
        m = batch_re.search(subj)
        if m:
            g = groups.setdefault(m.group(1), {"ts": ts, "members": []})
            g["ts"] = max(g["ts"], ts)
            g["members"].append((int(m.group(2)), ts))
            continue
        m = re.match(r"#(\d+)\b", subj)
        if m and not skip_re.search(subj):
            groups[f"solo-{h[:10]}"] = {"ts": ts, "members": [(int(m.group(1)), ts)]}
    for bid, g in groups.items():
        members = sorted({n for n, _ in g["members"]})
        rows.append({"v": 1, "ts": g["ts"], "kind": "batch", "batch": bid, "members": members, "assembly_s": None,
                     "stages": {}, "gate_s": None, "discarded_gate_s": None, "publish_s": None, "verdict": "green",
                     "cause": None, "resyncs": None, "push_rejected": None})
        for n, ts in g["members"]:
            rows.append({"v": 1, "ts": ts, "kind": "change", "issue": n, "event": "landed", "batch": bid, "cause": None})
    return rows


def merge_event_rows(path):
    """The plugin's merge-events.jsonl: one attempt = one gate run with its duration and outcome."""
    rows = []
    if not path or not Path(path).exists():
        return rows
    for line in Path(path).read_text(errors="replace").splitlines():
        try:
            e = json.loads(line)
        except json.JSONDecodeError:
            continue
        if e.get("event") == "push-retry" and e.get("issue") is not None:
            continue
        if e.get("event") != "attempt" or e.get("issue") is None or not parse_ts(e.get("ts")):
            continue
        oc, n = e.get("outcome"), e["issue"]
        green = oc in ("landed", "parked")
        cause = {"conflict": "conflict", "gate-failed": "defect"}.get(oc, "other")
        bid = f"attempt-{n}-{e.get('attempt') or 0}-{e['ts']}"
        if oc not in ("skipped", "conflict"):
            rows.append({"v": 1, "ts": e["ts"], "kind": "batch", "batch": bid, "members": [n], "assembly_s": None, "stages": {},
                         "gate_s": e.get("duration_s"), "discarded_gate_s": None, "publish_s": None,
                         "verdict": "green" if green else ("red" if oc == "gate-failed" else "aborted"),
                         "cause": None if green else cause, "resyncs": e.get("push_retries"), "push_rejected": e.get("push_retries")})
        if oc == "landed":
            rows.append({"v": 1, "ts": e["ts"], "kind": "change", "issue": n, "event": "landed", "batch": bid, "cause": None})
        elif not green and oc != "skipped":
            rows.append({"v": 1, "ts": e["ts"], "kind": "change", "issue": n, "event": "returned", "batch": bid, "cause": cause})
    return rows


def history_rows(args, since, until, first_written):
    rules = json.loads(Path(args.rules).read_text()) if args.rules else DEFAULT_RULES
    ready_re = re.compile(args.ready_regex)
    claim_re = re.compile(args.claim_regex)
    batch_re = re.compile(args.batch_subject_regex)
    skip_re = re.compile(args.skip_subject_regex)
    repo = args.repo or os.getcwd()
    rows = git_rows(repo, args.integration, since, batch_re, skip_re)
    rows += merge_event_rows(args.merge_events)
    landed = {r["issue"] for r in rows if r["kind"] == "change" and (since is None or parse_ts(r["ts"]) >= since)
              and (until is None or parse_ts(r["ts"]) < until)}
    rows += tracker_rows(repo, rules, ready_re, claim_re, args.limit, None if args.all_issues else landed)
    # History covers only the time before the writer existed: never double count.
    if first_written:
        rows = [r for r in rows if parse_ts(r["ts"]) < first_written]
    return rows


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--since")
    p.add_argument("--until")
    p.add_argument("--bucket", choices=("day", "week"), default="week")
    p.add_argument("--log", default=None)
    p.add_argument("--json", action="store_true")
    p.add_argument("--history", action="store_true")
    p.add_argument("--repo")
    p.add_argument("--integration", default="master")
    p.add_argument("--merge-events", default=os.environ.get("AUTOCODER_MERGE_EVENTS"))
    p.add_argument("--batch-subject-regex", default=r"(?i)\b(?:train|batch)/([A-Za-z0-9._-]+):\s*#(\d+)")
    p.add_argument("--skip-subject-regex", default=r"(?i)\(mechanical\)|\(documents-only\)|^docs\(|^merge |^re-sync")
    p.add_argument("--ready-regex", default=r"^\W*(\[[^\]]*\]\s*)?(\w+:\s*)?READY\b")
    p.add_argument("--claim-regex", default=r"(?i)^\W*(\[[^\]]*\]\s*)?[^\n]{0,60}\bclaim(ed|ing)?\b")
    p.add_argument("--rules")
    p.add_argument("--export-rows")
    p.add_argument("--all-issues", action="store_true", help="read every tracker issue, not only those that landed in the window")
    p.add_argument("--limit", type=int, default=1000)
    a = p.parse_args(argv)
    since, until = parse_ts(a.since), parse_ts(a.until)
    if (a.since and not since) or (a.until and not until):
        print(f"landing-report: cannot read --since/--until ({a.since!r}, {a.until!r}); use YYYY-MM-DD or ISO-8601", file=sys.stderr)
        return 2
    rows, bad = load_rows(a.log or default_log())
    if bad:
        print(f"landing-report: skipped {bad} unreadable line(s) in {a.log or default_log()}", file=sys.stderr)
    if a.history:
        first = min((parse_ts(r["ts"]) for r in rows), default=None)
        try:
            h = history_rows(a, since, until, first)
        except (RuntimeError, json.JSONDecodeError, OSError) as e:
            print(f"landing-report: history mode failed: {e}", file=sys.stderr)
            return 3
        if a.export_rows:
            Path(a.export_rows).write_text("".join(json.dumps(r, separators=(",", ":")) + "\n" for r in h))
        rows = h + rows
    res = analyze(rows, since, until, a.bucket)
    sys.stdout.write(json.dumps(res, indent=1) + "\n" if a.json else render(res))
    return 0


if __name__ == "__main__":
    sys.exit(main())
