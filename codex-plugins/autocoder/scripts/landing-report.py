#!/usr/bin/env python3
"""Landing report: where the time and the gate-minutes of landing changes go. WASTE FIRST.

Reads landing-timings.jsonl (landing-timings.py). With --history it also reconstructs the same
rows for the period BEFORE the writer existed, from the issue tracker (through issue-fns.sh's
source abstraction), git history of the integration branch and, when present, the plugin's own
merge-events.jsonl, so a project can reproduce its baseline.

  landing-report.py [--since DATE | --week [DATE|last]] [--until DATE] [--bucket day|week] [--batches]
                    [--log PATH] [--json] [--repo DIR] [--repo-id ID | --all-repos] [--train-gate-issue N]
                    [--ci auto|off] [--ci-runs-cmd CMD] [--ci-workflow NAME ...] [--integration BRANCH]
                    [--history [--integration BRANCH] [--merge-events PATH]
                               [--batch-subject-regex RE] [--skip-subject-regex RE] [--ready-regex RE] [--claim-regex RE]
                               [--rules JSON] [--export-rows PATH] [--limit N]]

Sections, in order: waste (gate-minutes thrown away; changes returned by cause; rebases and
pre-checks per change), then build time (claim to READY), wait after READY, cycle time, batch
size distribution, capacity against demand, rejected pushes, red batches by cause.
A figure the rows do not carry prints n/a, never 0.

ONE REPOSITORY PER REPORT. Every row names its repository (`repo`, repo-id-fns.sh's id; null in
rows written before the field existed). Two repositories on one host share the default file, and a
test run from a checkout without the private path once left fixture rows beside the real ones, which
the week's page counted as returns and a red batch. The report keeps the rows of ONE repository: the
`--repo-id` given, else the id of `--repo DIR` (default: the current directory) when the ledger holds
rows of it, and says on stderr how many rows of which other ids it ignored. A ledger holding no row of
the derived id is reported whole, with a notice naming the ids it does hold (a copy read on another
host, or an older ledger), so a page is never empty by accident; `--all-repos` keeps every row.

A TRAIN'S OWN GATE PASSES ARE NOT BATCHES. Before the gate learned the train's id (AUTOCODER_LANDING_BATCH),
every gate pass of a train wrote a solo batch of the issue the gate runs under (`train.gateIssue` in the
repository's .autocoder.json) beside the train's own row: on one week's page that issue was half the
batches and the landings, and every gate-minute counted twice. A batch row whose only member is that
issue, and that issue's change and plan rows, are dropped (`--train-gate-issue N` names it, default the
configured one; `0` keeps them), and the train rows own the passes. Rows the fixed gate writes never
have that shape.

WEEK MODE (`--week`): the weekly report. The window is one calendar week, Monday 00:00Z to the next
Monday: `--week 2026-11-16` is the week holding that date, a bare `--week` (or `--week last`) the
last COMPLETED week, so a Monday run reports the week that just ended. It adds, before the sections
above, "Week in numbers" (batches and members, changes landed, returned by cause and dropped at
planning, gate-minutes wasted by cause, median READY-to-landed, planning time, re-gates by reason)
and a table of every batch with each member's outcome (`--batches` adds that table to any window).
A RE-GATE is a batch that gates again a change an earlier, non-green batch of the window already
gated (the same members after an infrastructure red, the halves of a bisection after a red): its
reason is that earlier batch's verdict and cause, so the gate-minutes a red costs beyond its own
run are visible.

LANDING TO CI VERDICT. The gate is not the last word on a landing: the integration branch's own CI
runs on the landed commit, and when its runners queue, a red surfaces hours after the landing while
further landings stack on top of it. Every `landed` row names its commit (`sha`); the report groups
the window's landed rows by commit (one LANDING per commit, however many members), and for each
landing with no cached verdict asks the forge ONCE for that commit's runs on `--integration`
(`gh api .../actions/runs?head_sha=` in `--repo DIR`, or `--ci-runs-cmd` / `$AUTOCODER_CI_RUNS_CMD`,
a command given SHA and BRANCH that prints the runs as a JSON array, for another forge or a test).
The verdict is `failure` (or `timed_out` ...) at the time the FIRST failing run completed (when the
red surfaced), `success` at the time the last judged run completed, `cancelled` when every run was
superseded; a run still queued or running is `pending`, a commit with no run is `no run`, and a
forge that cannot be reached is `unknown`, never 0. A terminal verdict is cached in the ledger as a
`ci-verdict` row (landing-timings.py), so each commit is asked about once; pending and unknown are
asked again next time. `--ci off` asks nothing and reads the cache. `--ci-workflow NAME` (default:
`ciWorkflows` in the repository's .autocoder.json) judges only the named workflows: a repository
whose every push also runs a workflow that is red for reasons of its own, or a code scan that takes
an hour, names the judging ones; the cached row records the selection it was judged over. THE JOB
THAT BOUNDS THE VERDICT is read from the judging run's jobs (`gh api .../actions/runs/<id>/jobs`,
or `--ci-jobs-cmd` / `$AUTOCODER_CI_JOBS_CMD`, a command given RUN_ID that prints the jobs as a JSON
array): for a red, the first job to complete red (where the red surfaced); for a green, the last job
to complete (what the lag waited for). It is cached on the row (`job`) and counted, so the week page
says which job the landing-to-verdict lag IS, and a job that takes hours is a number every Monday, not
a guess; a run whose jobs cannot be read leaves it `not read`, never a name. The figures: landing to CI
verdict (p50, p75, max), the bounding jobs with their counts, the landings CI judged red, and how
many other landings happened between a red landing and its verdict (the ones that stacked on a red
nobody had seen yet); each batch row carries its landing's verdict, lag and bounding job.
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
RED_CONCLUSIONS = ("failure", "timed_out", "startup_failure", "action_required")
NO_VERDICT_CONCLUSIONS = ("cancelled", "skipped", "neutral", "stale")   # terminal, but no judgement of the commit
CI_NOT_JUDGED = ("pending", "none", "unknown", "not-queried")
CI_RUNS_TIMEOUT_S = 600   # one forge call; generous by doctrine, a dead forge reads unknown either way
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


def week_window(spec, today=None):
    """(since, until) of one calendar week, Monday 00:00Z to the next Monday.

    `spec` is a date inside the wanted week, or `last`/empty for the last COMPLETED week before
    `today` (UTC now by default): on a Monday that is the week that just ended. None when the spec
    is not a date."""
    today = today or datetime.now(timezone.utc)
    if spec in (None, "", "last"):
        ref = today - timedelta(days=7)
    else:
        ref = parse_ts(spec)
        if ref is None:
            return None
    monday = ref.astimezone(timezone.utc).replace(hour=0, minute=0, second=0, microsecond=0)
    monday -= timedelta(days=monday.weekday())
    return monday, monday + timedelta(days=7)


# ── reading rows ───────────────────────────────────────────────────────────
def load_rows(path):
    rows, bad = [], 0
    if path and Path(path).exists():
        for line in Path(path).read_text(errors="replace").splitlines():
            if not line.strip():
                continue
            try:
                r = json.loads(line)
                if isinstance(r, dict) and parse_ts(r.get("ts")) and r.get("kind") in ("change", "batch", "plan", "ci-verdict"):
                    rows.append(r)
                else:
                    bad += 1
            except json.JSONDecodeError:
                bad += 1
    return rows, bad


def repo_id_of(directory):
    """repo-id-fns.sh's id of a directory (`<basename>-<8 hex>` over the git common dir), or None when
    the helper is missing or the directory does not exist."""
    fns = Path(__file__).resolve().parent / "repo-id-fns.sh"
    if not fns.is_file() or not Path(directory).is_dir():
        return None
    r = subprocess.run(["bash", "-c", f'source "$1" && autocoder_repo_id "$2"', "_", str(fns), str(directory)],
                       capture_output=True, text=True)
    out = r.stdout.strip()
    return out if r.returncode == 0 and out else None


def autocoder_config(directory):
    """The repository's main-worktree .autocoder.json as a dict ({} when there is none or it cannot be read)."""
    try:
        r = subprocess.run(["git", "-C", str(directory), "rev-parse", "--git-common-dir"], capture_output=True, text=True)
        main = (Path(directory) / r.stdout.strip()).resolve().parent if r.returncode == 0 and r.stdout.strip() else Path(directory)
        raw = json.loads((main / ".autocoder.json").read_text())
        return raw if isinstance(raw, dict) else {}
    except (OSError, ValueError, TypeError):
        return {}


def train_gate_issue(directory):
    """`train.gateIssue` of the repository's main-worktree .autocoder.json (the issue a train's gate runs
    under, train_run's gate_issue), or None when there is none."""
    try:
        n = int((autocoder_config(directory).get("train") or {}).get("gateIssue") or 0)
        return n or None
    except (ValueError, TypeError):
        return None


def configured_ci_workflows(directory):
    """`ciWorkflows` of the repository's .autocoder.json: the workflow names whose runs on the integration branch are
    its CI verdict (a repository whose every push also runs a workflow that is red for reasons of its own, or a
    code scan that takes an hour, names the judging ones). Empty = every run on the branch."""
    raw = autocoder_config(directory).get("ciWorkflows")
    return [str(w) for w in raw if str(w).strip()] if isinstance(raw, list) else []


def without_train_gate_rows(rows, gate_issue, log=lambda m: print(m, file=sys.stderr)):
    """Drops the rows that were a train's own gate passes recorded as batches of their own: a batch whose only
    member is the train gate issue, and that issue's change and plan rows. The train rows own those passes."""
    if not gate_issue:
        return rows
    kept, batches, others = [], 0, 0
    for r in rows:
        if r["kind"] == "batch" and list(r.get("members") or []) == [gate_issue]:
            batches += 1
        elif r["kind"] in ("change", "plan") and r.get("issue") == gate_issue:
            others += 1
        else:
            kept.append(r)
    if batches or others:
        log(f"landing-report: dropped {batches} batch row(s) that were a train's own gate passes (members [{gate_issue}], the train gate issue) "
            f"and {others} change/plan row(s) of that issue; the train rows own those passes (--train-gate-issue 0 keeps them)")
    return kept


def one_repo(rows, repo_id, derived, log=lambda m: print(m, file=sys.stderr)):
    """The rows of one repository: `repo_id` when given (strict: rows of other ids are dropped, however
    many are left), else `derived` when at least one row names it. Rows naming no repository are kept.
    Returns the rows kept; says what was ignored, or why nothing was."""
    ids = Counter(r.get("repo") for r in rows if r.get("repo"))
    want = repo_id or (derived if derived in ids else None)
    if not want:
        if derived and ids:
            log(f"landing-report: no row names this repository ({derived}); the ledger holds rows of {', '.join(sorted(ids))}: "
                f"reporting every row (name one with --repo-id ID)")
        return rows
    kept = [r for r in rows if r.get("repo") in (None, want)]
    dropped = Counter(r.get("repo") for r in rows if r.get("repo") not in (None, want))
    if dropped:
        log(f"landing-report: ignored {sum(dropped.values())} row(s) of other repositories "
            f"({', '.join(f'{k} {v}' for k, v in sorted(dropped.items()))}); reporting {want} (--all-repos keeps them)")
    return kept


def default_log():
    env = os.environ.get("AUTOCODER_LANDING_TIMINGS")
    if env:
        return env
    state = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
    return os.path.join(state, "autocoder", "landing-timings.jsonl")


# ── analysis ───────────────────────────────────────────────────────────────
def merge_batches(batches):
    """One row per batch id, in time order. A train's gate (merge-to-integration.sh under
    AUTOCODER_LANDING_BATCH) and the train itself both write the train's id: the gate the seconds and
    re-syncs it measured, the train the verdict it judged. Later non-null fields win; members and stages
    are unioned; a field only one side carries is kept."""
    by = {}
    for b in sorted(batches, key=lambda b: parse_ts(b["ts"])):
        cur = by.get(b["batch"])
        if cur is None:
            by[b["batch"]] = dict(b)
            continue
        for k, v in b.items():
            if k == "members":
                cur[k] = sorted(set(cur.get(k) or []) | set(v or []))
            elif k == "stages":
                cur[k] = {**(cur.get(k) or {}), **(v or {})}
            elif v is not None:
                cur[k] = v
    return list(by.values())


def analyze(rows, since, until, bucket="week", ci=None):
    def inwin(r):
        t = parse_ts(r["ts"])
        return (since is None or t >= since) and (until is None or t < until)

    ev = defaultdict(list)  # issue -> [(t, event, row)] up to `until`
    for r in rows:
        if r["kind"] == "change" and (until is None or parse_ts(r["ts"]) < until):
            ev[r["issue"]].append((parse_ts(r["ts"]), r["event"], r))
    for v in ev.values():
        v.sort(key=lambda x: x[0])
    batches = merge_batches(r for r in rows if r["kind"] == "batch" and inwin(r))
    # planning: the train planner's candidate probes (one `plan` row each; seconds and verdict)
    plans = [r for r in rows if r["kind"] == "plan" and inwin(r) and isinstance(r.get("seconds"), (int, float))]
    plan_by = {}
    for r in plans:
        d = plan_by.setdefault(r.get("verdict") or "unknown", {"n": 0, "s": 0.0})
        d["n"] += 1
        d["s"] += r["seconds"]

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
    build, wait, cycle, total, launch = [], [], [], [], []
    landed_issues = []
    for i, es in ev.items():
        landed = [t for t, e, r in es if e == "landed" and inwin(r)]
        claimed = [t for t, e, r in es if e == "claimed"]
        ready = [t for t, e, r in es if e == "ready"]
        if ready and claimed and any(since is None or t >= since for t in ready) and min(claimed) <= min(ready):
            build.append((min(ready) - min(claimed)).total_seconds())
        # READY to launch: every `launched` row in the window (a cycle took the change), measured from the
        # newest READY before it; the same change relaunched after a return counts once per launch.
        for lt_, e_, r_ in es:
            if e_ == "launched" and inwin(r_):
                before = [t for t in ready if t <= lt_]
                if before:
                    launch.append((lt_ - max(before)).total_seconds())
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
    batch_rows, regates = batch_outcomes(ev, batches)
    ci_res = ci_figures(*(ci or ci_inputs(rows, since, until, {}, {"mode": "not-queried", "queried": 0, "cached": 0, "error": None})))
    annotate_batches_ci(batch_rows, rows, since, until, ci_res)

    # buckets: waste, returns and capacity vs demand
    bk = defaultdict(lambda: {"ready": 0, "landed": 0, "batches": 0, "gate_s": 0.0, "wasted_s": 0.0, "plan_s": 0.0,
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
    for r in plans:
        bk[bucket_key(parse_ts(r["ts"]), bucket)]["plan_s"] += r["seconds"]

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
        "timings": {"build_s": dist(build), "wait_s": dist(wait), "cycle_s": dist(cycle), "claim_to_landed_s": dist(total),
                    "ready_to_launch_s": dist(launch)},
        "batches": {"count": len(batches), "size_distribution": {str(k): v for k, v in sorted(sizes.items())},
                    "assembly_s": dist(asm), "publish_s": dist(pub), "stage_s_total": dict(stage_tot),
                    "resyncs": resyncs, "push_rejected": pushrej, "red_by_cause": dict(red)},
        "planning": {"candidates": len(plans), "s_total": sum(r["seconds"] for r in plans) if plans else None,
                     "per_candidate_s": dist([r["seconds"] for r in plans]), "by_verdict": plan_by},
        "buckets": {k: {**v, "returned": len(v["returned"]), "seen": len(v["seen"])} for k, v in sorted(bk.items())},
        "landed": len(landed_issues),
        "batch_rows": batch_rows,
        "regates": regates,
        "ci": ci_res,
    }


# ── CI verdict per landing ─────────────────────────────────────────────────
def landings_of(rows, since, until):
    """One landing per landed COMMIT in the window ({sha: {"sha", "ts" (the first landed row's time), "issues",
    "batch"}}) and the number of landed rows in the window that name no commit (an older writer)."""
    by, unrecorded = {}, 0
    for r in rows:
        if r["kind"] != "change" or r.get("event") != "landed":
            continue
        t = parse_ts(r["ts"])
        if (since is not None and t < since) or (until is not None and t >= until):
            continue
        sha = r.get("sha")
        if not sha:
            unrecorded += 1
            continue
        # a hand-written row may carry a prefix of a commit another row names in full: one landing, under the full name
        for known in list(by):
            if known != sha and (known.startswith(sha) or sha.startswith(known)):
                longer = max(known, sha, key=len)
                if longer != known:
                    by[longer] = by.pop(known)
                    by[longer]["sha"] = longer
                sha = longer
                break
        d = by.setdefault(sha, {"sha": sha, "ts": t, "issues": [], "batch": r.get("batch")})
        d["ts"] = min(d["ts"], t)
        if r["issue"] not in d["issues"]:
            d["issues"].append(r["issue"])
    return by, unrecorded


BATCH_ID_RE = re.compile(r"(?i)\b(?:train|batch)[/-]([A-Za-z0-9._-]+)")
SOLO_WINDOW_BEFORE_S, SOLO_WINDOW_AFTER_S = 24 * 3600, 600
RESOLVE_LOG_MAX = 20000   # first-parent commits read to resolve old rows' commits (a busy branch lands a few hundred a day)


def resolve_landed_commits(rows, repo_dir, integration, since, log=lambda m: print(m, file=sys.stderr)):
    """Gives a `landed` row written before the writer named its commit the commit the integration branch's
    first-parent log shows for it: a commit whose subject names the row's batch id (`train/<id>`, `batch/<id>`),
    else the newest commit starting `#<issue>` committed within a day before the row and ten minutes after it (the
    gate lands a rebased series; its committer time is before the push). Read-time only: the rows in the file are not
    rewritten, and a row nothing matches stays without a commit. Returns the number resolved."""
    todo = [r for r in rows if r["kind"] == "change" and r.get("event") == "landed" and not r.get("sha")]
    if not todo or not repo_dir or not (Path(repo_dir) / ".git").exists() and subprocess.run(["git", "-C", str(repo_dir), "rev-parse", "--git-dir"], capture_output=True).returncode != 0:
        return 0
    oldest = min(parse_ts(r["ts"]) for r in todo) - timedelta(seconds=SOLO_WINDOW_BEFORE_S)
    ref = f"origin/{integration}"
    if subprocess.run(["git", "-C", str(repo_dir), "rev-parse", "--verify", "-q", ref], capture_output=True).returncode != 0:
        ref = integration
    # No `--since`: git stops walking at the first commit older than it, and a fast-forwarded commit with an old date hides
    # every landing behind it. The walk is bounded by count and the cutoff is applied to each commit here.
    r = subprocess.run(["git", "-C", str(repo_dir), "log", "--first-parent", f"--max-count={RESOLVE_LOG_MAX}", "--format=%H%x1f%cI%x1f%s", ref],
                       capture_output=True, text=True)
    if r.returncode != 0:
        log(f"landing-report: could not read {ref} in {repo_dir} to resolve the commits of {len(todo)} landed row(s): {r.stderr.strip()[:200]}")
        return 0
    by_batch, by_issue = {}, defaultdict(list)
    for i, line in enumerate(r.stdout.splitlines()):
        h, cdate, subj = (line.split("\x1f") + ["", "", ""])[:3]
        t = parse_ts(cdate)
        if not t or t < oldest:
            continue
        m = BATCH_ID_RE.search(subj)
        if m:
            by_batch.setdefault(m.group(1), h)      # the newest commit naming the id (the log is newest first)
        m = re.match(r"#(\d+)\b", subj)
        if m:
            by_issue[int(m.group(1))].append((t, -i, h))   # a rebased series shares one second: the newest in the log wins the tie
    n = 0
    for row in todo:
        t = parse_ts(row["ts"])
        m = BATCH_ID_RE.search(str(row.get("batch") or ""))
        sha = by_batch.get(m.group(1)) if m else None
        if not sha:
            cands = [c for c in by_issue.get(row["issue"], []) if t - timedelta(seconds=SOLO_WINDOW_BEFORE_S) <= c[0] <= t + timedelta(seconds=SOLO_WINDOW_AFTER_S)]
            sha = max(cands)[2] if cands else None
        if sha:
            row["sha"] = sha
            n += 1
    if n:
        log(f"landing-report: resolved the commit of {n} of {len(todo)} landed row(s) that named none from {ref} (by batch id, else the issue's own commit)")
    return n


def cached_verdicts(rows, workflows=()):
    """The ledger's `ci-verdict` rows by commit (the last written wins), only those judged over the same workflow
    selection as this run (`workflows`, empty = every run on the branch): a verdict cached under another
    selection is not this one's."""
    want = sorted(set(workflows)) or None
    out = {}
    for r in rows:
        if r["kind"] == "ci-verdict" and r.get("sha") and parse_ts(r.get("verdict_ts")) and r.get("conclusion") \
                and r["conclusion"] not in CI_NOT_JUDGED and (sorted(set(r.get("workflows") or [])) or None) == want:
            out[r["sha"]] = {"status": r["conclusion"], "verdict_ts": parse_ts(r["verdict_ts"]), "run_id": r.get("run_id"),
                             "job": r.get("job") or None, "source": "cached"}
    return out


def run_time(r):
    return parse_ts(r.get("updated_at") or r.get("completed_at") or r.get("run_started_at"))


def judge_runs(runs, integration, workflows):
    """(status, verdict time, run id) from one commit's runs: a red conclusion at the FIRST failing run's end (when the
    red surfaced); `pending` while any kept run is not completed; `success` at the LAST successful run's end; `cancelled`
    when every completed run was superseded or skipped, `inconclusive` when none carries a conclusion; `none` when the
    commit has no run on the branch."""
    keep = [r for r in runs or [] if isinstance(r, dict)
            and not (integration and r.get("head_branch") and r["head_branch"] != integration)
            and not (workflows and r.get("name") not in workflows)]
    if not keep:
        return "none", None, None
    far = datetime.max.replace(tzinfo=timezone.utc)
    done = [r for r in keep if r.get("status") == "completed"]
    red = sorted((r for r in done if r.get("conclusion") in RED_CONCLUSIONS), key=lambda r: run_time(r) or far)   # a timed one first
    if red:
        return red[0]["conclusion"], run_time(red[0]), str(red[0].get("id") or "") or None
    if len(done) < len(keep):
        return "pending", None, None
    judged = [r for r in done if r.get("conclusion") == "success"]           # a completed run with no conclusion judged nothing
    timed = [r for r in (judged or done) if run_time(r)]
    last = max(timed, key=run_time) if timed else (judged or done)[-1]      # no run carries a time: the verdict stands, its time is unknown
    status = "success" if judged else ("cancelled" if any(r.get("conclusion") in NO_VERDICT_CONCLUSIONS for r in done) else "inconclusive")
    return status, run_time(last), str(last.get("id") or "") or None


def fetch_runs(cmd, repo_dir, sha, integration):
    """One commit's runs from the forge: `cmd` (SHA and BRANCH on its argv, a JSON array on stdout), else `gh api` in
    `repo_dir`. Returns (runs, None) or (None, error)."""
    if cmd:
        argv = ["bash", "-c", f'{cmd} "$@"', "_", sha, integration]
    else:
        argv = ["gh", "api", "-X", "GET", "repos/{owner}/{repo}/actions/runs", "-f", f"head_sha={sha}", "-f", f"branch={integration}",
                "-f", "per_page=100", "--jq", ".workflow_runs"]
    try:
        r = subprocess.run(argv, cwd=repo_dir if Path(repo_dir).is_dir() else None, capture_output=True, text=True, timeout=CI_RUNS_TIMEOUT_S)
    except (OSError, subprocess.TimeoutExpired) as e:
        return None, f"{argv[0]}: {e}"
    if r.returncode != 0:
        return None, (r.stderr.strip().splitlines() or [f"exit {r.returncode}"])[-1][:300]
    try:
        runs = json.loads(r.stdout or "[]")
    except json.JSONDecodeError as e:
        return None, f"unreadable runs JSON: {e}"
    if isinstance(runs, dict):
        runs = runs.get("workflow_runs") or []
    return (runs, None) if isinstance(runs, list) else (None, "the runs JSON is not a list")


def job_time(j):
    return parse_ts(j.get("completed_at") or j.get("updated_at"))


def bounding_job(jobs, status):
    """The job of the judging run that bounds the verdict: for a red verdict the FIRST job to complete with a red
    conclusion (where the red surfaced; a job carrying no time is last); for any other verdict the LAST job to
    complete (what the lag waited for; a job carrying no time is first). None when the run has no completed job."""
    done = [j for j in jobs or [] if isinstance(j, dict) and j.get("name") and j.get("status") == "completed"]
    if not done:
        return None
    far = datetime.max.replace(tzinfo=timezone.utc)
    near = datetime.min.replace(tzinfo=timezone.utc)
    if status in RED_CONCLUSIONS:
        red = [j for j in done if j.get("conclusion") in RED_CONCLUSIONS]
        return min(red, key=lambda j: job_time(j) or far)["name"] if red else None
    judged = [j for j in done if j.get("conclusion") == "success"] or done
    return max(judged, key=lambda j: job_time(j) or near)["name"]


def fetch_jobs(cmd, repo_dir, run_id):
    """One run's jobs from the forge: `cmd` (RUN_ID on its argv, a JSON array on stdout), else `gh api` in
    `repo_dir`. Returns (jobs, None) or (None, error)."""
    if cmd:
        argv = ["bash", "-c", f'{cmd} "$@"', "_", str(run_id)]
    else:
        argv = ["gh", "api", "-X", "GET", f"repos/{{owner}}/{{repo}}/actions/runs/{run_id}/jobs", "-f", "per_page=100", "--jq", ".jobs"]
    try:
        r = subprocess.run(argv, cwd=repo_dir if Path(repo_dir).is_dir() else None, capture_output=True, text=True, timeout=CI_RUNS_TIMEOUT_S)
    except (OSError, subprocess.TimeoutExpired) as e:
        return None, f"{argv[0]}: {e}"
    if r.returncode != 0:
        return None, (r.stderr.strip().splitlines() or [f"exit {r.returncode}"])[-1][:300]
    try:
        jobs = json.loads(r.stdout or "[]")
    except json.JSONDecodeError as e:
        return None, f"unreadable jobs JSON: {e}"
    if isinstance(jobs, dict):
        jobs = jobs.get("jobs") or []
    return (jobs, None) if isinstance(jobs, list) else (None, "the jobs JSON is not a list")


def resolve_ci(landings, cached, mode, fetch, judge, write, log=lambda m: print(m, file=sys.stderr), jobs_of=None):
    """Each landing's verdict: the cached one, else (mode `auto`) the forge's answer (`fetch(sha)` -> (runs, error)),
    judged by `judge(runs)`, its bounding job read by `jobs_of(run_id)` -> (jobs, error) when given, and cached by
    `write(sha, status, verdict_ts, run_id, job)` when terminal. Returns (verdicts by sha, meta: mode, queried,
    cached, unknown, error, jobs_unread)."""
    out, meta = {}, {"mode": mode, "queried": 0, "cached": 0, "error": None, "unknown": 0, "jobs_unread": 0, "jobs_error": None}
    for sha, L in sorted(landings.items(), key=lambda kv: kv[1]["ts"]):
        if sha in cached:
            out[sha] = cached[sha]
            meta["cached"] += 1
            continue
        if mode == "off":
            out[sha] = {"status": "not-queried", "verdict_ts": None, "run_id": None, "source": None}
            continue
        runs, err = fetch(sha)
        meta["queried"] += 1
        if err is not None:
            out[sha] = {"status": "unknown", "verdict_ts": None, "run_id": None, "source": "queried", "error": err}
            meta["error"] = meta["error"] or err
            meta["unknown"] += 1
            continue
        status, vts, rid = judge(runs)
        job = None
        if status not in CI_NOT_JUDGED and rid and jobs_of is not None:
            jobs, jerr = jobs_of(rid)
            if jerr is not None:
                meta["jobs_unread"] += 1
                meta["jobs_error"] = meta["jobs_error"] or jerr
            else:
                job = bounding_job(jobs, status)
        out[sha] = {"status": status, "verdict_ts": vts, "run_id": rid, "job": job, "source": "queried"}
        if status not in CI_NOT_JUDGED and vts is not None:     # an untimed verdict is reported, not cached: asked again
            write(sha, status, vts, rid, job)
    if meta["unknown"]:
        log(f"landing-report: the forge could not be reached for {meta['unknown']} landed commit(s) (CI verdict unknown, nothing cached): {meta['error']}")
    if meta["jobs_unread"]:
        log(f"landing-report: the jobs of {meta['jobs_unread']} judging run(s) could not be read (bounding job not read, the verdict cached without it): {meta['jobs_error']}")
    return out, meta


def every_landing(rows):
    """Every landing the ledger knows, in or out of the window, recorded commit or not: [(key, ts)], one per landed
    commit (key = the commit), and one per batch, else per row, for landed rows that name no commit (key = the batch
    id, else `issue@ts`). What a red verdict's "landings before it" are counted over: a landing just past the window's
    end, or one whose row carries no commit, still stacked on the red."""
    by = {}
    for r in rows:
        if r["kind"] != "change" or r.get("event") != "landed":
            continue
        t = parse_ts(r["ts"])
        key = r.get("sha") or (f"batch:{r['batch']}" if r.get("batch") else f"{r['issue']}@{r['ts']}")
        by[key] = min(by.get(key, t), t)
    return list(by.items())


def ci_inputs(rows, since, until, verdicts, meta):
    landings, unrecorded = landings_of(rows, since, until)
    return landings, unrecorded, verdicts, meta, every_landing(rows)


def ci_figures(landings, unrecorded, verdicts, meta, universe=None):
    """The CI figures of the window's landings. n/a and unknown are told apart from 0: a figure is None when the
    forge was not asked or could not answer for every landing that lacks a verdict. `universe` is every landing the
    ledger knows ([(key, ts)], every_landing), the set a red's stacked landings are counted over."""
    universe = universe if universe is not None else [(sha, L["ts"]) for sha, L in landings.items()]
    counts = Counter()
    jobs = Counter()
    lag, red = [], []
    for sha, L in landings.items():
        v = verdicts.get(sha) or {"status": "not-queried", "verdict_ts": None, "run_id": None}
        L["status"], L["verdict_ts"], L["run_id"], L["lag_s"], L["job"] = v["status"], v.get("verdict_ts"), v.get("run_id"), None, v.get("job") or None
        if v["status"] in CI_NOT_JUDGED:
            counts[v["status"]] += 1
            continue
        counts["judged"] += 1
        if L["job"]:
            jobs[L["job"]] += 1
        else:
            counts["job_unread"] += 1
        if v.get("verdict_ts") is None:
            counts["untimed"] += 1            # a terminal verdict whose runs carry no time: judged, lag unknown
            continue
        L["lag_s"] = (v["verdict_ts"] - L["ts"]).total_seconds()
        if L["lag_s"] < 0:                    # the row is written after the push; a verdict faster than that is a lag of 0
            counts["clamped"] += 1
            L["lag_s"] = 0.0
        lag.append(L["lag_s"])
    stacked = set()
    for L in sorted(landings.values(), key=lambda x: x["ts"]):
        L["landings_before_verdict"] = None
        if L["status"] not in RED_CONCLUSIONS or L["status"] in CI_NOT_JUDGED:
            continue
        if L["verdict_ts"] is not None:
            before = {k for k, t in universe if k != L["sha"] and L["ts"] <= t < L["verdict_ts"]}   # rows are second-resolution
            L["landings_before_verdict"] = len(before)
            stacked |= before
        red.append({"sha": L["sha"], "issues": L["issues"], "landed_ts": iso(L["ts"]), "verdict_ts": iso(L["verdict_ts"]) if L["verdict_ts"] else None,
                    "conclusion": L["status"], "lag_s": L["lag_s"], "run_id": L["run_id"], "job": L["job"], "landings_before_verdict": L["landings_before_verdict"]})
    unanswered = counts["unknown"] + counts["not-queried"]
    known = bool(counts["judged"]) or not unanswered     # nothing is known of the reds when every landing went unanswered
    return {"landings": len(landings), "unrecorded": unrecorded, "judged": counts["judged"], "pending": counts["pending"],
            "none": counts["none"], "unknown": counts["unknown"], "not_queried": counts["not-queried"],
            "untimed": counts["untimed"], "lag_clamped": counts["clamped"], "complete": not unanswered,
            "queried": meta.get("queried", 0), "cached": meta.get("cached", 0), "mode": meta.get("mode"), "forge_error": meta.get("error"),
            "off_reason": meta.get("off_reason"), "workflows": sorted(meta.get("workflows") or []),
            "lag_s": {"n": len(lag), "p50": quant(lag, 0.5), "p75": quant(lag, 0.75), "max": max(lag) if lag else None},
            "bounding_jobs": [{"job": j, "n": n} for j, n in jobs.most_common()], "job_unread": counts["job_unread"],
            "red": red, "red_count": len(red) if known else None,
            "landings_before_red_verdicts": sum(r["landings_before_verdict"] or 0 for r in red) if known else None,
            "landings_before_red_verdicts_distinct": len(stacked) if known else None,
            "by_sha": {sha: {"status": L["status"], "lag_s": L.get("lag_s"), "job": L.get("job"), "landings_before_verdict": L.get("landings_before_verdict")}
                       for sha, L in landings.items()}}


def annotate_batches_ci(batch_rows, rows, since, until, ci_res):
    """Each batch row gets the CI verdict of the commit its landed members landed in (`ci`: status, lag, landings
    before the verdict), None when no landed member names a commit."""
    by_issue_batch, by_issue = {}, defaultdict(list)
    for r in rows:
        if r["kind"] == "change" and r.get("event") == "landed" and r.get("sha"):
            by_issue_batch[(r["issue"], r.get("batch"))] = r["sha"]
            by_issue[r["issue"]].append((parse_ts(r["ts"]), r["sha"]))

    def nearest(n, bt):   # the issue's landed row closest to the batch's time, at or after it first (a re-landing is a later row)
        rows_ = by_issue.get(n) or []
        after = [(t, sha) for t, sha in rows_ if t >= bt]
        return min(after)[1] if after else (max(rows_)[1] if rows_ else None)

    for row in batch_rows:
        row["ci"] = None
        bt = parse_ts(row["ts"])
        for n in row["landed"]:
            sha = by_issue_batch.get((n, row["batch"])) or nearest(n, bt)
            if sha and sha in ci_res["by_sha"]:
                row["ci"] = dict(ci_res["by_sha"][sha], sha=sha)
                break


def ci_cell(c):
    """The Batches table cell: `success 1.7h`, `failure 2.5h (2 landed before the verdict)`, `pending`, `no run`, `unknown`, `-`."""
    if not c:
        return "-"
    st = c["status"]
    if st in CI_NOT_JUDGED:
        return {"none": "no run", "not-queried": "not queried"}.get(st, st)
    if c.get("lag_s") is None:
        return f"{st} (time unknown)"
    before = c.get("landings_before_verdict")
    return f"{st} {human(c['lag_s'])}" + (f" in {c['job']}" if c.get("job") else "") + (f" ({before} landed before the verdict)" if before else "")


def ci_lag_text(ci, with_max=False):
    """`p50 X, p75 Y[, max Z] (n=.. of .. landed commits; pending ..; ...)`, or the n/a / unknown that applies."""
    n = ci["landings"]
    if n == 0:
        return "n/a (no landed row carries its commit)" if ci["unrecorded"] else "n/a (nothing landed)"
    if ci["judged"] == 0 and ci["not_queried"] == n:
        return f"n/a (not queried, {ci.get('off_reason') or '--ci off'}; {n} landed commits)"
    if ci["judged"] == 0 and ci["unknown"] and ci["unknown"] + ci["not_queried"] == n:
        return f"unknown (the forge could not be reached for {ci['unknown']} landed commits: {ci['forge_error'] or 'no answer'})"
    d = ci["lag_s"]
    head = "n/a" if not d["n"] else f"p50 {human(d['p50'])}, p75 {human(d['p75'])}" + (f", max {human(d['max'])}" if with_max else "")
    parts = [f"n={d['n']} of {n} landed commits"]
    for key, label in (("pending", "pending"), ("none", "no run"), ("unknown", "unknown"), ("not_queried", "not queried")):
        if ci[key]:
            parts.append(f"{label} {ci[key]}")
    if ci["untimed"]:
        parts.append(f"{ci['untimed']} judged without a time")
    if ci["lag_clamped"]:
        parts.append(f"{ci['lag_clamped']} verdict{'s' if ci['lag_clamped'] != 1 else ''} before the row (lag 0)")
    if ci["unrecorded"]:
        parts.append(f"{ci['unrecorded']} landed row{'s carry' if ci['unrecorded'] != 1 else ' carries'} no commit")
    return head + " (" + "; ".join(parts) + ")"


def ci_job_text(ci):
    """`bounding job: Backend Tests (vitest) 41, lint 2 (not read for 1)`: the job that bounds each judged landing's
    verdict, by count, so the lag has a name; `bounding job: not read` when none was, nothing when nothing was judged."""
    if not ci["judged"]:
        return ""
    jobs, unread = ci.get("bounding_jobs") or [], ci.get("job_unread") or 0
    if not jobs:
        return "bounding job: not read"
    return "bounding job: " + ", ".join(f"{j['job']} {j['n']}" for j in jobs) + (f" (not read for {unread})" if unread else "")


def ci_red_text(ci):
    k, before = ci["red_count"], ci["landings_before_red_verdicts"]
    if k is None:
        return "judged red by CI: unknown; landings that happened before those verdicts: unknown"
    gaps = [f"{ci['unknown']} unknown"] * bool(ci["unknown"]) + [f"{ci['not_queried']} not queried"] * bool(ci["not_queried"])
    return f"judged red by CI: {k} landing{'s' if k != 1 else ''}; landings that happened before those verdicts: {before}" \
        + (f" ({ci['landings_before_red_verdicts_distinct']} distinct)" if k > 1 else "") \
        + (f" (both at least: {', '.join(gaps)} of the landed commits)" if gaps else "") \
        + (f"; workflows judged: {', '.join(ci['workflows'])}" if ci.get("workflows") else "")


def member_outcomes(es, bid, batch_ts):
    """One member's outcome in batch `bid`, read from its events: `landed`, `returned:<cause>` or `open`
    (no outcome row yet, or none the writer recorded). The span judged runs from the member's `batched`
    row for this batch (else the batch row's time) to its next `batched` row for another batch, because
    a train's `returned` rows name no batch."""
    starts = [t for t, e, r in es if e == "batched" and r.get("batch") == bid and t <= batch_ts]
    start = max(starts) if starts else batch_ts
    ends = [t for t, e, r in es if e == "batched" and r.get("batch") != bid and t > start]
    end = min(ends) if ends else None
    # rows are second-resolution: an outcome stamped in the same second as the next `batched` row belongs here
    span = [(e, r) for t, e, r in es if t >= start and (end is None or t < end or (t == end and e != "batched"))]
    if any(e == "landed" and r.get("batch") in (bid, None) for e, r in span):
        return "landed"
    returned = [r for e, r in span if e == "returned"]
    return f"returned:{returned[0].get('cause') or 'unknown'}" if returned else "open"


def batch_outcomes(ev, batches):
    """Per-batch rows (members and their outcomes) in time order, and the re-gates among them.

    A re-gate is a batch that gates again a change an earlier NON-GREEN batch of the window already
    gated: the same members after an infrastructure red, the halves of a bisection after a red, a
    member innocent of a red gated again without the culprit. Its reason is the latest such earlier
    batch's `verdict:cause`; counted once per batch with its gate seconds (n/a stays unmeasured).
    The culprit's own next gate after a `defect` return, fixed and re-READY'd, counts too: the ledger
    carries no tip to tell a fixed change from the same one, so the figure is a ceiling the README
    says so about."""
    rows, by, seen_red = [], {}, []
    for b in sorted(batches, key=lambda b: parse_ts(b["ts"])):
        bt, bid, members = parse_ts(b["ts"]), b["batch"], set(b["members"])
        outcomes = {n: member_outcomes(ev.get(n, []), bid, bt) for n in b["members"]}
        row = {"batch": bid, "ts": b["ts"], "members": list(b["members"]), "verdict": b.get("verdict"), "cause": b.get("cause"),
               "gate_s": b.get("gate_s"), "landed": [n for n, o in outcomes.items() if o == "landed"],
               "returned": {n: o.split(":", 1)[1] for n, o in outcomes.items() if o.startswith("returned:")},
               "open": [n for n, o in outcomes.items() if o == "open"], "regate_of": None}
        earlier = [(ts, reason) for ts, ms, reason in seen_red if ms & members]
        if earlier:
            reason = earlier[-1][1]
            row["regate_of"] = reason
            d = by.setdefault(reason, {"n": 0, "s": 0.0, "unmeasured": 0})
            d["n"] += 1
            if b.get("gate_s") is None:
                d["unmeasured"] += 1
            else:
                d["s"] += b["gate_s"]
        if b.get("verdict") in ("red", "aborted", "infra"):
            seen_red.append((bt, members, f"{b['verdict']}:{b.get('cause') or 'unknown'}"))
        rows.append(row)
    return rows, {"count": sum(d["n"] for d in by.values()), "gate_s": sum(d["s"] for d in by.values()), "by": by}


# ── markdown ───────────────────────────────────────────────────────────────
def ready_to_launch_text(t):
    """The READY-to-launch gap, or why it is n/a: a ledger written before the `launched` event existed carries none."""
    d = t.get("ready_to_launch_s") or {"n": 0}
    if not d["n"]:
        return "n/a (no `launched` row: the cycle that writes it is not installed, or nothing was launched)"
    return f"p50 {human(d['p50'])}, p90 {human(d['p90'])}, max {human(d['max'])} (n={d['n']})"


def render_week(a):
    """The weekly summary: one bullet per figure the week is judged by; n/a where the rows carry none."""
    w, t, b, p, rg = a["waste"], a["timings"], a["batches"], a["planning"], a["regates"]
    members = sum(len(r["members"]) for r in a["batch_rows"])
    returned_total = sum(w["returned_by_cause"].values())
    drop = (p["by_verdict"].get("drop") or {}).get("n", 0)
    out = ["## Week in numbers", "",
           f"- Batches: {b['count']}; members: {members}" + (f" ({members / b['count']:.1f} per batch)" if b["count"] else "")
           + "; sizes " + (", ".join(f"{k}: {v}" for k, v in b["size_distribution"].items()) or "n/a"),
           f"- Changes landed: {a['landed']}; returned: {returned_total} (useful, a defect in the change: {w['useful_returned']}; "
           f"waste: {returned_total - w['useful_returned']})" + ("; by cause " + ", ".join(f"{k} {v}" for k, v in sorted(w["returned_by_cause"].items(), key=lambda kv: -kv[1])) if returned_total else "")
           + f"; dropped at planning: {drop}"]
    if w["share"] is None:
        out.append("- Gate-minutes: n/a (no batch row carries gate seconds)")
    else:
        out.append(f"- Gate-minutes: {human(w['gate_s_total'])} in {w['batches_measured']} measured batches; wasted {human(w['gate_s_wasted'])} "
                   f"({w['share'] * 100:.0f}%)" + ("; by cause " + ", ".join(f"{k} {human(v)}" for k, v in sorted(w["by"].items(), key=lambda kv: -kv[1])) if w["by"] else ""))
    c = t["cycle_s"]
    out.append("- Median READY to landed: " + ("n/a" if not c["n"] else f"{human(c['p50'])} (p90 {human(c['p90'])}, n={c['n']})"))
    out.append("- READY to launch (a cycle took it): " + ready_to_launch_text(t))
    out.append("- Planning: " + ("n/a (not recorded)" if p["s_total"] is None else f"{human(p['s_total'])} over {p['candidates']} candidate probes"))
    out.append(f"- Landing to CI verdict: {ci_lag_text(a['ci'])}; {ci_red_text(a['ci'])}" + (f"; {ci_job_text(a['ci'])}" if ci_job_text(a['ci']) else ""))
    if rg["count"]:
        out.append(f"- Re-gates: {rg['count']} batches, {human(rg['gate_s'])} of gate time; by reason "
                   + ", ".join(f"{k} {v['n']} ({human(v['s'])}{', ' + str(v['unmeasured']) + ' unmeasured' if v['unmeasured'] else ''})"
                               for k, v in sorted(rg["by"].items(), key=lambda kv: -kv[1]["n"])))
    else:
        out.append("- Re-gates: 0")
    return out + [""]


def render_batches(a):
    """Every batch of the window with each member's outcome: the row a reader checks a number against."""
    out = ["## Batches", "", "| batch | gated (UTC) | members | verdict | gate | landed | returned | no outcome | re-gate of | CI verdict |",
           "|---|---|---|---|---|---|---|---|---|---|"]
    for r in a["batch_rows"]:
        verdict = (r["verdict"] or "n/a") + (f":{r['cause']}" if r["cause"] else "")
        out.append(f"| {r['batch']} | {r['ts']} | {' '.join('#' + str(n) for n in r['members'])} | {verdict} | {human(r['gate_s'])} | "
                   f"{' '.join('#' + str(n) for n in r['landed']) or '-'} | "
                   f"{' '.join(f'#{n} ({c})' for n, c in r['returned'].items()) or '-'} | "
                   f"{' '.join('#' + str(n) for n in r['open']) or '-'} | {r['regate_of'] or '-'} | {ci_cell(r.get('ci'))} |")
    if not a["batch_rows"]:
        out.append("| (no batch in the window) | | | | | | | | | |")
    return out + [""]


def render(a, week=None, batches=False):
    w, t, b = a["waste"], a["timings"], a["batches"]
    title = f"# Landing report: week of {week}" if week else "# Landing report"
    out = [title, "", f"Window: {a['window']['since'] or 'start'} to {a['window']['until'] or 'now'}", ""]
    if week:
        out += render_week(a)
    if week or batches:
        out += render_batches(a)
    out += ["## Waste (leads: only a defect in the change is a useful rejection)", ""]
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
    out.append("- READY to launch (a cycle took it): " + ready_to_launch_text(t))
    out.append(f"- Landing to CI verdict: {ci_lag_text(a['ci'], with_max=True)}; {ci_red_text(a['ci'])}" + (f"; {ci_job_text(a['ci'])}" if ci_job_text(a['ci']) else ""))
    out += ["", "## Batches", "", f"- Batches: {b['count']}; landed changes: {a['landed']}",
            "- Size distribution (members: batches): " + (", ".join(f"{k}: {v}" for k, v in b["size_distribution"].items()) or "n/a"),
            f"- Assembly: " + ("n/a" if not b["assembly_s"]["n"] else f"p50 {human(b['assembly_s']['p50'])}, p90 {human(b['assembly_s']['p90'])}"),
            f"- Publish: " + ("n/a" if not b["publish_s"]["n"] else f"p50 {human(b['publish_s']['p50'])}, p90 {human(b['publish_s']['p90'])}"),
            f"- Re-syncs: {b['resyncs']}; rejected pushes: {b['push_rejected']}",
            "- Red batches by cause: " + (", ".join(f"{k}: {v}" for k, v in sorted(b["red_by_cause"].items())) or "none"),
            "- Re-gates by reason: " + (", ".join(f"{k}: {v['n']} ({human(v['s'])})" for k, v in sorted(a["regates"]["by"].items(), key=lambda kv: -kv[1]["n"])) or "none")]
    if b["stage_s_total"]:
        tot = sum(b["stage_s_total"].values())
        out.append("- Gate stage time: " + ", ".join(f"{k} {human(v)} ({pct(v, tot)})" for k, v in sorted(b["stage_s_total"].items(), key=lambda kv: -kv[1])))
    p = a["planning"]
    if p["s_total"] is None:
        out.append("- Planning (candidate probes): n/a (not recorded)")
    else:
        d = p["per_candidate_s"]
        out.append(f"- Planning (candidate probes): {human(p['s_total'])} over {p['candidates']} candidates "
                   f"(p50 {human(d['p50'])}, p90 {human(d['p90'])}, max {human(d['max'])}); by verdict: "
                   + ", ".join(f"{k} {v['n']} ({human(v['s'])})" for k, v in sorted(p["by_verdict"].items(), key=lambda kv: -kv[1]["s"])))
    out += ["", "## Capacity against demand", "",
            "| period | READY (demand) | landed (capacity) | backlog change | batches | gate time | planning | wasted | returned/seen |",
            "|---|---|---|---|---|---|---|---|---|"]
    for k, v in a["buckets"].items():
        out.append(f"| {k} | {v['ready']} | {v['landed']} | {v['ready'] - v['landed']:+d} | {v['batches']} | "
                   f"{human(v['gate_s']) if v['gate_s'] else 'n/a'} | {human(v['plan_s']) if v['plan_s'] else 'n/a'} | "
                   f"{pct(v['wasted_s'], v['gate_s'])} | {v['returned']}/{v['seen']} |")
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
            g = groups.setdefault(m.group(1), {"ts": ts, "members": [], "tip": h})   # newest first: the first seen is the pushed tip
            g["ts"] = max(g["ts"], ts)
            g["members"].append((int(m.group(2)), ts))
            continue
        m = re.match(r"#(\d+)\b", subj)
        if m and not skip_re.search(subj):
            groups[f"solo-{h[:10]}"] = {"ts": ts, "members": [(int(m.group(1)), ts)], "tip": h}
    for bid, g in groups.items():
        members = sorted({n for n, _ in g["members"]})
        rows.append({"v": 1, "ts": g["ts"], "kind": "batch", "batch": bid, "members": members, "assembly_s": None,
                     "stages": {}, "gate_s": None, "discarded_gate_s": None, "publish_s": None, "verdict": "green",
                     "cause": None, "resyncs": None, "push_rejected": None})
        for n, ts in g["members"]:   # every member of one push landed in its tip, the commit CI ran on
            rows.append({"v": 1, "ts": ts, "kind": "change", "issue": n, "event": "landed", "batch": bid, "cause": None, "sha": g["tip"]})
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
    p.add_argument("--week", nargs="?", const="last", help="one calendar week, Monday to Monday: a date inside it, or `last` (the default) for the last completed week")
    p.add_argument("--batches", action="store_true", help="list every batch of the window with each member's outcome")
    p.add_argument("--bucket", choices=("day", "week"), default="week")
    p.add_argument("--log", default=None)
    p.add_argument("--json", action="store_true")
    p.add_argument("--history", action="store_true")
    p.add_argument("--repo", help="the repository directory (default: the current directory): its id selects the rows; --history reads its tracker and git log")
    p.add_argument("--repo-id", help="keep only the rows of this repository id (repo-id-fns.sh's `<basename>-<8 hex>`)")
    p.add_argument("--all-repos", action="store_true", help="keep the rows of every repository in the file")
    p.add_argument("--train-gate-issue", type=int, help="the issue a train's gate runs under (default: train.gateIssue of the repository's .autocoder.json); its solo batches are the trains' own gate passes and are dropped; 0 keeps them")
    p.add_argument("--integration", default="master", help="the integration branch: --history reads its log; the CI verdict is its runs on the landed commit")
    p.add_argument("--ci", choices=("auto", "off"), default="auto", help="auto: ask the forge once per landed commit with no cached verdict; off: read the cache only")
    p.add_argument("--ci-runs-cmd", default=os.environ.get("AUTOCODER_CI_RUNS_CMD") or None,
                   help="a command given SHA and BRANCH that prints the commit's CI runs as a JSON array (default: gh api in --repo)")
    p.add_argument("--ci-jobs-cmd", default=os.environ.get("AUTOCODER_CI_JOBS_CMD") or None,
                   help="a command given RUN_ID that prints the run's jobs as a JSON array, for the job that bounds the verdict (default: gh api in --repo)")
    p.add_argument("--ci-workflow", action="append", default=[], help="judge only this workflow name (repeatable; default: `ciWorkflows` of the repository's .autocoder.json, else every run on the branch)")
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
    since, until, week = parse_ts(a.since), parse_ts(a.until), None
    if (a.since and not since) or (a.until and not until):
        print(f"landing-report: cannot read --since/--until ({a.since!r}, {a.until!r}); use YYYY-MM-DD or ISO-8601", file=sys.stderr)
        return 2
    if a.week is not None:
        if a.since or a.until:
            print("landing-report: --week names the whole window; drop --since/--until", file=sys.stderr)
            return 2
        window = week_window(a.week)
        if window is None:
            print(f"landing-report: cannot read --week {a.week!r}; use YYYY-MM-DD (a date inside the week) or `last`", file=sys.stderr)
            return 2
        since, until = window
        week = since.strftime("%Y-%m-%d")
    if a.repo_id and a.all_repos:
        print("landing-report: --repo-id and --all-repos contradict each other", file=sys.stderr)
        return 2
    rows, bad = load_rows(a.log or default_log())
    if bad:
        print(f"landing-report: skipped {bad} unreadable line(s) in {a.log or default_log()}", file=sys.stderr)
    if not a.all_repos:
        rows = one_repo(rows, a.repo_id, None if a.repo_id else repo_id_of(a.repo or os.getcwd()))
    rows = without_train_gate_rows(rows, a.train_gate_issue if a.train_gate_issue is not None else train_gate_issue(a.repo or os.getcwd()))
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
    repo_dir = a.repo or os.getcwd()
    ids = {r.get("repo") for r in rows if r.get("repo")}
    derived = a.repo_id or repo_id_of(repo_dir)
    row_repo = derived if derived in ids else None
    resolve_landed_commits(rows, repo_dir, a.integration, since)
    landings, unrecorded = landings_of(rows, since, until)

    def fetch(sha):
        return fetch_runs(a.ci_runs_cmd, repo_dir, sha, a.integration)

    workflows = sorted(set(a.ci_workflow) or set(configured_ci_workflows(repo_dir)))

    def judge(runs):
        return judge_runs(runs, a.integration, set(workflows))

    def jobs_of(rid):
        return fetch_jobs(a.ci_jobs_cmd, repo_dir, rid)

    def write(sha, status, vts, rid, job=None):
        writer = HERE / "landing-timings.py"
        if not writer.is_file():
            print(f"landing-report: {writer} is missing; the CI verdict of {sha[:10]} is not cached", file=sys.stderr)
            return
        argv = [sys.executable, str(writer), "--log-path", a.log or default_log(), *(["--repo", row_repo] if row_repo else []),
                "ci-verdict", "--sha", sha, "--conclusion", status, "--verdict-ts", iso(vts), *(["--run-id", rid] if rid else []),
                *(["--job", job] if job else []), *(x for w in workflows for x in ("--workflow", w))]
        r = subprocess.run(argv, capture_output=True, text=True)
        if r.returncode != 0:
            print(f"landing-report: could not cache the CI verdict of {sha[:10]}: {r.stderr.strip()[:200]}", file=sys.stderr)
    ci_mode, off_reason = a.ci, "--ci off" if a.ci == "off" else None
    if a.all_repos and ci_mode != "off":
        # A commit's verdict is asked of, and cached under, its own repository; across every repository's rows this
        # checkout could only ask the wrong forge and tag the row with the wrong id.
        ci_mode, off_reason = "off", "--all-repos: the CI verdict is asked of one repository"
        print("landing-report: --all-repos: the CI verdict is not queried (it is asked of one repository); cached verdicts are read", file=sys.stderr)
    verdicts, meta = resolve_ci(landings, cached_verdicts(rows, workflows), ci_mode, fetch, judge, write, jobs_of=jobs_of)
    meta["workflows"], meta["off_reason"] = workflows, off_reason
    res = analyze(rows, since, until, a.bucket, ci=(landings, unrecorded, verdicts, meta, every_landing(rows)))
    if week:
        res["week"] = week
    sys.stdout.write(json.dumps(res, indent=1) + "\n" if a.json else render(res, week=week, batches=a.batches))
    return 0


if __name__ == "__main__":
    sys.exit(main())
