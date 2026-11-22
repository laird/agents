"""train_run.py -- train assembly, the gate, publish and the red-batch rules (CLI: merge-train-run.py).

Slice 2 of the merge train (slice 1, train_lib.py, reads the READY queue and plans the members).
One CYCLE: take the lease, run the project's preflight, plan up to `limit` members, assemble them
as ONE tree on a train branch, gate that tree through merge-to-integration.sh (its contract is
unchanged: exit 0 and a `merged into` line mean the branch landed), publish and close out with a
comment per member, and apply the red-batch rules.

Red-batch rules (every one learned from a measured miss):

  * A red that names members (a path in the failure that only some members' diffs touch) returns
    those members to their owners and RE-GATES THE REMAINING members as a new set: a hold-out never
    lets the rest land untested, and never leaves them behind unjudged.
  * A red that names nobody bisects. The first half is gated; a green half lands at once and the
    other half is red by inference (the batch failed and this half passed), so it splits without
    spending a gate on itself; a red half is split again and the other half, still unjudged, is
    gated. A single member left red is returned to its owner with the log. One bad member of eight
    costs at most three further gates while seven land.
  * An INFRASTRUCTURE red (a line `::error::<stage>: INFRASTRUCTURE ...`, which the stage prints
    when the host, not the tree, failed) re-gates the same set once and never drops, holds out or
    bisects anyone. A second one ends the cycle with everyone back in the queue, unfaulted.
  * An EMPTY landing (the gate's rebase dropped every commit as already upstream: the set changed
    only regenerated files, which the regeneration put back, or work already on the integration
    branch) is a terminal verdict, not a red: every member is marked `landed nothing`, told so once,
    dropped at that tip, and nobody is bisected or re-gated. Measured: a train of two such members
    bisected (held one out, re-gated the other alone) until it was killed by hand.
  * A candidate the queue reads as `regenerate-only` (train_lib: every changed path carries one of
    `regeneratedMergeDrivers`) is never planned; the cycle tells its issue ONCE per tip which files
    and why, so it costs no train slot and no second comment.
  * The plan reads each branch's CURRENT remote tip, fetched again right before planning (the
    preflight can take minutes). With `readyTip: named` (the default) a tip other than the sha its
    READY names is taken when it carries the same patches (a rebase onto the moved integration
    branch, a merge of it into the branch), told once per tip, and refused as `tip-moved` when it
    carries other work, told once per tip, until a READY names it. Measured on one project: a worker
    who rebased after a sibling landed waited a cycle, or a hand nudge, for a new READY to be read.
  * A RED-BASE refusal (merge-to-integration.sh's `merge-to-integration: RED-BASE -- ...` line:
    the files that failed on the integrated tree fail on the integration branch alone too, and
    landing on a red base is off) is the integration branch's red, nobody's to own: the cycle ends
    with everyone back in the queue unfaulted and the report names the integration branch; a
    re-gate on the same base would fail the same way. A landing on a red base (the default once
    a sentinel proved green) publishes as usual and the report says the red is the branch's.
  * Member accounting is in git and in `cycle.json`, never in the tracker: a failed tracker call
    is queued in `pending` and retried, and cannot change who is in a set, who landed or who was
    returned. A landing is proven by the member's commits being in the integration branch.

Adaptive batch size: the limit starts at `batchStart` (8), grows by one after a green first gate
(ceiling `batchMax`) and halves after a red one (floor `batchMin`); kept in `batch.json`.

Project tuning is only the `train` object of `.autocoder.json` (keys below), never code here.
"""

from __future__ import annotations

import fcntl
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

import train_lib as T

SCRIPTS = T.SCRIPTS
LANDED_RE = re.compile(r"✅ Issue #\d+ merged into ")
ERROR_LINE_RE = re.compile(r"^(::error::|❌)")
INFRA_RE_DEFAULT = r"^::error::[A-Za-z0-9_-]+: INFRASTRUCTURE"
# merge-to-integration.sh's lines for a rebase that left nothing to land (every commit dropped as
# already upstream), matched at the start of a line with the gate's own marker, never a test's quote
# of them; a gate that prints one and did not push landed nothing, whatever its exit code.
EMPTY_RE_DEFAULT = (r"^(❌|ℹ️) +Rebasing \S+ \(\w+\) .*(dropped every commit as already upstream|left nothing to land)"
                    r"|^ℹ️ +\S+ \(\w+\) is already on origin/\S+ as patch-equivalent commits .*nothing to land\.$")
NOTHING_LANDED = "landed nothing (regenerate-only or already on the integration branch)"
RED_BASE_RE = re.compile(r"^merge-to-integration: RED-BASE -- .*$", re.M)
PATH_TOKEN_RE = re.compile(r"[A-Za-z0-9_./@-]+\.[A-Za-z0-9]+")
IDENT = ["-c", "user.name=autocoder-train", "-c", "user.email=autocoder-train@localhost"]


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# ── configuration ───────────────────────────────────────────────────────────────────────
@dataclass
class RunConfig:
    cfg: T.Config
    gate: str = ""                 # command template; {train} {sha} {issue} {integration} {test_cmd} are shell-quoted
    gate_issue: str = "0"          # the issue id the gate runs under (names its lock and log)
    test_cmd: str = ""
    batch_start: int = 8
    batch_min: int = 2
    batch_max: int = 16
    max_gates: int = 16            # gates one cycle may spend after its first (a safety bound, never an SLA)
    infra_regates: int = 1
    infra_pattern: str = INFRA_RE_DEFAULT
    empty_pattern: str = EMPTY_RE_DEFAULT   # the gate's "nothing to land" line: terminal, never bisected
    report_issue: str = ""         # where batch-level notes go; empty = member issues only
    swarm: str = "merge-train"     # every tracker write starts with this
    timings_cmd: str = ""          # default: landing-timings.py beside this file, when present
    hooks: dict = field(default_factory=dict)   # preflight, regenerate, attribute, landed (plus slice 1's)
    gate_log_dir: Path = None


def load_run_config(repo, config_file=None, env=None) -> RunConfig:
    """Slice 1's Config plus the keys this slice reads from the same `train` object:
    gate, gateIssue, testCmd, batchStart, batchMin, batchMax, maxGates, infraRegates, infraPattern,
    emptyPattern, reportIssue, swarm, timingsCmd, gateLogDir, hooks.{preflight, regenerate, attribute, landed}."""
    env = os.environ if env is None else env
    cfg = T.load_config(repo, config_file, env)
    path = Path(config_file) if config_file else T._main_worktree(cfg.repo) / ".autocoder.json"
    raw = {}
    if path.is_file():
        raw = (json.loads(path.read_text()) or {}).get("train") or {}
    rc = RunConfig(
        cfg=cfg,
        gate=raw.get("gate") or "",
        gate_issue=str(env.get("AUTOCODER_TRAIN_GATE_ISSUE") or raw.get("gateIssue") or "0"),
        test_cmd=raw.get("testCmd") or "",
        batch_start=int(raw.get("batchStart") or 8),
        batch_min=int(raw.get("batchMin") or 2),
        batch_max=int(raw.get("batchMax") or 16),
        max_gates=int(raw.get("maxGates") or 16),
        infra_regates=int(raw.get("infraRegates") if raw.get("infraRegates") is not None else 1),
        infra_pattern=raw.get("infraPattern") or INFRA_RE_DEFAULT,
        empty_pattern=raw.get("emptyPattern") or EMPTY_RE_DEFAULT,
        report_issue=str(raw.get("reportIssue") or ""),
        swarm=raw.get("swarm") or "merge-train",
        timings_cmd=env.get("AUTOCODER_TRAIN_TIMINGS_CMD") or raw.get("timingsCmd") or "",
        hooks=dict(raw.get("hooks") or {}),
        gate_log_dir=Path(env.get("AUTOCODER_TRAIN_LOG_DIR") or raw.get("gateLogDir") or cfg.state_dir / "logs"),
    )
    rc.batch_min = max(1, rc.batch_min)
    rc.batch_max = max(rc.batch_min, rc.batch_max)
    rc.batch_start = min(max(rc.batch_start, rc.batch_min), rc.batch_max)
    return rc


# ── state: the batch limit, the cycle record, the dropped list, pending tracker writes ──
def _read_json(path, default):
    try:
        return json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return default


def _write_json(path, data):
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(p.suffix + ".tmp")
    tmp.write_text(json.dumps(data, indent=1, sort_keys=True))
    os.replace(tmp, p)


class State:
    """Everything a cycle remembers, under cfg.state_dir. Written after every transition, so a
    dead process leaves a record `reconcile()` can read against git."""

    def __init__(self, rc: RunConfig):
        self.rc = rc
        self.dir = rc.cfg.state_dir
        self.dir.mkdir(parents=True, exist_ok=True)

    # the adaptive limit
    def batch(self):
        b = _read_json(self.dir / "batch.json", {})
        b.setdefault("limit", self.rc.batch_start)
        b.setdefault("history", [])
        b["limit"] = min(max(int(b["limit"]), self.rc.batch_min), self.rc.batch_max)
        return b

    def limit(self):
        return self.batch()["limit"]

    def record_batch(self, size, verdict):
        b = self.batch()
        cur = b["limit"]
        if verdict == "green":
            nxt = min(self.rc.batch_max, cur + 1)
        elif verdict == "red":
            nxt = max(self.rc.batch_min, cur // 2)
        else:
            nxt = cur   # an infrastructure red or an abort says nothing about the batch size
        b["history"] = (b["history"] + [{"ts": now_iso(), "size": size, "verdict": verdict, "limit": cur, "limit_after": nxt}])[-50:]
        b["limit"] = nxt
        _write_json(self.dir / "batch.json", b)
        return cur, nxt

    # the cycle record
    @property
    def cycle_path(self):
        return self.dir / "cycle.json"

    def cycle(self):
        return _read_json(self.cycle_path, {})

    def save_cycle(self, c):
        _write_json(self.cycle_path, c)
        # slice 1's queue reads current.tsv for `in-train`
        rows = [f"{m['issue']}\t{m['branch']}\t{m['tip']}" for m in c.get("members", []) if m["status"] in ("planned", "assembled", "gating")]
        cur = self.dir / "current.tsv"
        if rows:
            cur.write_text("\n".join(rows) + "\n")
        elif cur.exists():
            cur.unlink()

    def clear_cycle(self):
        self.cycle_path.unlink(missing_ok=True)
        (self.dir / "current.tsv").unlink(missing_ok=True)

    def drop(self, issue, tip, reason):
        with open(self.dir / "dropped.tsv", "a") as f:
            f.write(f"{issue}\t{tip}\t{now_iso()}\t{reason}\n")

    # queue verdicts told once per (issue, tip): regenerate-only.tsv, tip-moved.tsv, followed-tip.tsv
    def told(self, kind, issue, tip):
        return any(row[:2] == [str(issue), tip] for row in T.read_rows(self.dir / f"{kind}.tsv"))

    def tell(self, kind, issue, tip):
        with open(self.dir / f"{kind}.tsv", "a") as f:
            f.write(f"{issue}\t{tip}\t{now_iso()}\n")

    def launched(self, issue, tip):
        p = self.rc.cfg.launched
        p.parent.mkdir(parents=True, exist_ok=True)
        with open(p, "a") as f:
            f.write(f"{issue} {tip}\n")

    # tracker writes that failed
    def pending(self):
        return _read_json(self.dir / "pending.json", [])

    def save_pending(self, rows):
        _write_json(self.dir / "pending.json", rows)


# ── the lease: one train at a time per repo and integration branch ──────────────────────
class Lease:
    """An flock on a file in the state dir, held for the life of the process (the OS releases it when
    the process dies, so there is no stale lease to sweep). The holder is written into the file."""

    def __init__(self, state: State):
        self.path = state.dir / "lease.lock"
        self.fd = None

    def acquire(self):
        self.fd = os.open(self.path, os.O_RDWR | os.O_CREAT, 0o644)
        try:
            fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            holder = os.pread(self.fd, 200, 0).decode(errors="replace").strip()
            os.close(self.fd)
            self.fd = None
            return False, holder or "unknown holder"
        os.ftruncate(self.fd, 0)
        os.pwrite(self.fd, f"pid {os.getpid()} since {now_iso()}\n".encode(), 0)
        return True, ""

    def release(self):
        if self.fd is not None:
            try:
                os.ftruncate(self.fd, 0)
                fcntl.flock(self.fd, fcntl.LOCK_UN)
            finally:
                os.close(self.fd)
                self.fd = None


# ── tracker writes that never change the member set ─────────────────────────────────────
class Reporter:
    """Comments and closes on the tracker. A failed call is queued in pending.json and retried by
    `flush()`; it never raises and never touches membership."""

    def __init__(self, rc: RunConfig, state: State, log):
        self.rc, self.state, self.log = rc, state, log

    def _do(self, row):
        c = self.rc.cfg
        body = f"{self.rc.swarm}: {row['body']}"
        if row.get("close"):
            T.tracker(c, "issue_close", str(row["issue"]), "--comment", body)
        else:
            T.tracker(c, "issue_comment", str(row["issue"]), "--body", body)

    def say(self, issue, body, close=False):
        row = {"issue": str(issue), "body": body, "close": bool(close)}
        try:
            self._do(row)
            return True
        except RuntimeError as e:
            self.log(f"tracker write to #{issue} failed ({e}); queued for retry, the member set is unchanged")
            self.state.save_pending(self.state.pending() + [row])
            return False

    def report(self, body):
        if self.rc.report_issue:
            self.say(self.rc.report_issue, body)

    def flush(self):
        left = []
        for row in self.state.pending():
            try:
                self._do(row)
            except RuntimeError:
                left.append(row)
        self.state.save_pending(left)
        return len(left)


# ── git helpers ─────────────────────────────────────────────────────────────────────────
def tip_landed(cfg: T.Config, tip, ref=None):
    """A member is landed when the integration branch carries its work: an ancestor, every commit
    patch-equivalent to one already there (the gate lands by rebase), or the content itself (the gate
    squashes a branch with merge commits, so a train lands as ONE commit). See T.landing_proof."""
    return bool(T.landing_proof(cfg, tip, ref))


def changed_files(cfg: T.Config, base, tip):
    mb = T.git(cfg.repo, "merge-base", base, tip).stdout.strip() or base
    return set(T.git(cfg.repo, "diff", "--name-only", "--no-renames", mb, tip).stdout.split())


def remote_tip(cfg: T.Config, branch):
    r = T.git(cfg.repo, "rev-parse", "--verify", "--quiet", cfg.remote_ref(branch) + "^{commit}")
    return r.stdout.strip() if r.returncode == 0 else ""


# ── the cycle ───────────────────────────────────────────────────────────────────────────
class Cycle:
    def __init__(self, rc: RunConfig, log=None):
        self.rc, self.cfg = rc, rc.cfg
        self.state = State(rc)
        self.log = log or (lambda m: print(f"{now_iso()} merge-train-run: {m}", flush=True))
        self.say = Reporter(rc, self.state, self.log)
        self.gates = 0
        self.seq = 0
        self.record = {}
        self.landed_total, self.returned_total = [], []
        self.repo_id = T.repo_id(rc.cfg)   # every ledger row names the repository (landing-timings.py --repo)

    # ----- timings (wqb's writer; best effort, never fails the cycle) -----
    def _ledger_env(self):
        env = dict(os.environ)
        if self.repo_id and not env.get("AUTOCODER_LANDING_REPO"):
            env["AUTOCODER_LANDING_REPO"] = self.repo_id
        return env

    def timing(self, *args):
        cmd = self.rc.timings_cmd
        if not cmd:
            w = SCRIPTS / "landing-timings.py"
            if not w.is_file():
                return
            cmd = f"{shlex.quote(sys.executable)} {shlex.quote(str(w))}"
        try:
            subprocess.run(["bash", "-c", f'{cmd} "$@"', "_", *map(str, args)], capture_output=True, text=True, env=self._ledger_env())
        except OSError:
            pass

    def note_readys(self, rows):
        """The queue's READYs reach the ledger as `ready` rows once each, stamped with the comment's time
        (train_lib.note_readys), so the report measures the wait after READY from the worker's post."""
        done = T.note_readys(self.cfg, rows, lambda issue, ts: self.timing("change", "--issue", issue, "--event", "ready", "--ts", ts))
        if done:
            self.log(f"{len(done)} READY row(s) recorded in the landing ledger: " + " ".join(f"#{i}" for i in done))

    def gate_end_event(self, since_iso, train, gate_s, reason):
        """A gate the host killed outright (an OOM kill of its whole scope, SIGKILL) runs no EXIT trap, so
        its lifecycle ledger has a `gate-start` and no `gate-end`; a gate that ended on a catchable signal
        wrote its own `aborted`. When no `gate-end` for the gate issue follows this gate's start, the train
        writes one: `aborted`, with the seconds and the line that decided the verdict. Best effort."""
        lib = SCRIPTS / "issue-events-lib.sh"
        if not lib.is_file():
            return
        path = Path(os.environ.get("AUTOCODER_ISSUE_EVENTS") or Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local" / "state") / "autocoder" / "issue-events.jsonl")
        issue = int(self.rc.gate_issue) if str(self.rc.gate_issue).isdigit() else None
        if path.is_file():
            for ln in reversed(path.read_text(errors="replace").splitlines()):
                try:
                    ev = json.loads(ln)
                except ValueError:
                    continue
                if ev.get("event") == "gate-end" and ev.get("issue") == issue and (ev.get("ts") or "") >= since_iso:
                    return   # the gate recorded its own end
        env = {**os.environ, "AUTOCODER_WORKER": self.rc.swarm, "AUTOCODER_EVENT_BRANCH": train}
        try:
            subprocess.run(["bash", "-c", 'source "$1" && { [ ! -f "$2" ] || source "$2"; } && cd "$3" && issue_event gate-end "$4" outcome=aborted duration_s="$5" reason="$6"',
                            "_", str(lib), str(SCRIPTS / "repo-id-fns.sh"), str(self.cfg.repo), str(self.rc.gate_issue), str(int(gate_s)), reason],
                           capture_output=True, text=True, env=env)
        except OSError:
            pass

    # ----- the publisher's batch marker: while a cycle is live the fast lane rides in its next publish -----
    def publisher(self, *args):
        pub = os.environ.get("AUTOCODER_TRAIN_PUBLISHER") or str(SCRIPTS / "publisher.sh")
        if not Path(pub).is_file():
            return
        try:
            r = subprocess.run(["bash", pub, *args, "--repo", str(self.cfg.repo), "--remote", self.cfg.remote],
                               capture_output=True, text=True)
            if r.returncode != 0:
                self.log(f"publisher.sh {args[0]} exited {r.returncode}: {(r.stdout + r.stderr).strip()[:200]}")
        except OSError as e:
            self.log(f"publisher.sh {args[0]} could not run: {e}")

    # ----- member records -----
    def _set_status(self, members, status, note=""):
        for m in self.record["members"]:
            if any(m["issue"] == x["issue"] for x in members):
                m["status"] = status
                if note:
                    m["note"] = note
        self.state.save_cycle(self.record)

    # ----- the cycle -----
    def run(self, size=None):
        """Returns (exit_code, summary lines). 0 = a cycle ran (landed or returned or empty); 1 = refused;
        2 = a planner or scratch fault (nobody blamed); 3 = a tracker or environment error."""
        lease = Lease(self.state)
        ok, holder = lease.acquire()
        if not ok:
            self.log(f"ABORT: a train is live ({holder}); one train at a time per repo and integration branch")
            return 1, []
        self.publisher("batch-begin", "--pid", str(os.getpid()))
        try:
            return self._run_locked(size)
        finally:
            self.publisher("batch-end", "--force")
            # The fast lane rides behind the batch: an entry enqueued while this cycle was live waited for
            # it, and no other writer is due, so this cycle lands the lane now, under the publisher's
            # leases, whatever its own verdict. An empty lane costs nothing (drain takes no lease then).
            self.publisher("drain", "--branch", self.cfg.integration)
            lease.release()

    def _run_locked(self, size):
        c = self.cfg
        f = T.git(c.repo, "fetch", c.remote, "-q")
        if f.returncode != 0:
            self.log(f"ABORT: git fetch {c.remote} failed in {c.repo}: {f.stderr.strip()}")
            return 3, []
        self.reconcile()
        pending = self.say.flush()
        if pending:
            self.log(f"{pending} tracker write(s) still queued from earlier cycles")
        pre = self.preflight()
        if pre:
            self.log(f"ABORT: the launch preflight failed; nothing was cut or planned:\n{pre}")
            return 1, []
        limit = size or self.state.limit()
        t_plan = time.time()
        # Fetch again right before the plan: the preflight can take minutes, and a tip pushed meanwhile (a
        # rebase after a sibling landed) is the tip the plan should classify, not the one the cycle opened on.
        f = T.git(c.repo, "fetch", c.remote, "-q")
        if f.returncode != 0:
            self.log(f"ABORT: git fetch {c.remote} failed in {c.repo} before the plan: {f.stderr.strip()}")
            return 3, []
        rows = T.plan_queue(c)
        self.note_readys(rows)
        self.tell_queue_verdicts(rows)
        # One `plan` timing row per candidate judged (seconds, verdict): the planning time of a cycle is their
        # sum, beside the gate time in the landing report. The merges run hooks off; the project's
        # regeneration runs once, on the assembled tree (assemble -> regenerate).
        out, fault = T.plan_train(c, rows, limit, on_candidate=lambda i, k, s: self.timing("plan", "--issue", i, "--verdict", k, "--seconds", f"{s:.1f}"))
        plan_s = int(time.time() - t_plan)
        for ln in out:
            if ln.startswith("drop\t"):
                _, issue, branch, tip, reason = ln.split("\t", 4)
                self.state.drop(issue, tip, f"planning: {reason}")
                self.say.say(issue, f"dropped at planning: `{branch}` @ `{tip}`: {reason}. Fix, push, post READY; it rejoins the next plan at its new tip.")
        if fault:
            self.log(f"planner fault, nobody is blamed: {fault}")
            return 2, []
        members = []
        for ln in out:
            if ln.startswith("train\t"):
                _, issue, branch, tip, note = (ln.split("\t", 4) + [""])[:5]
                members.append({"issue": issue, "branch": branch, "tip": self._full(tip, branch), "status": "planned", "note": note})
        if not members:
            self.log(f"no clean READY branch to train (planning took {plan_s}s)")
            return 0, []
        self.record = {"started": now_iso(), "limit": limit, "members": members, "sets": []}
        self.state.save_cycle(self.record)
        self.log(f"planned {len(members)} member(s) (limit {limit}) in {plan_s}s: " + " ".join(f"#{m['issue']}" for m in members))
        first = self.gate_set(members, first=True)
        if first == "red":
            self.bisect_or_attribute(members)
        elif first == "infra":
            self.log("infrastructure red twice: the cycle ends, every member stays in the queue unfaulted")
        elif first == "red-base":
            self.log(f"red {self.cfg.integration}: the cycle ends, every member stays in the queue unfaulted")
        elif first == "regen":
            self.log("the assembled tree could not be regenerated: the cycle ends, nobody blamed")
        elif first == "empty":
            self.log("nothing to land: the gate's rebase dropped every commit as already upstream; every member is marked landed nothing, no bisection")
        verdict = {"green": "green", "red": "red"}.get(first, first)
        cur, nxt = self.state.record_batch(len(members), "green" if first == "green" else "red" if first == "red" else "abort")
        self.log(f"batch limit {cur} -> {nxt} (first gate {verdict}); landed {len(self.landed_total)}, returned {len(self.returned_total)}")
        left = [m for m in self.record["members"] if m["status"] in ("planned", "assembled", "gating")]
        if left:
            self._set_status(left, "requeued", "left in the queue, unfaulted")
        self.state.clear_cycle()
        return 0, []

    def _full(self, tip, branch):
        r = T.git(self.cfg.repo, "rev-parse", "--verify", "--quiet", self.cfg.remote_ref(branch) + "^{commit}")
        full = r.stdout.strip()
        return full if full.startswith(tip) else (full or tip)

    def tell_queue_verdicts(self, rows):
        """Three queue verdicts are told to the issue ONCE per tip (a `<kind>.tsv` record in the state dir), so
        the owner learns them without a train slot and never twice:
          regenerate-only  which files it changes and why no train takes it; never planned at that tip
          tip-moved        the tip carries work the READY did not name; not READY until one names it
          followed         a rebased or fast-forwarded tip was taken in the named sha's place (same patches)
        The queue state keeps the first two out of the plan; the record only stops a second comment."""
        for r in rows:
            issue, tip = r["issue"], r["tip"]
            if r["state"] == "regenerate-only" and not self.state.told("regenerate-only", issue, tip):
                self.say.say(issue, f"not trained, `regenerate-only`: `{r['branch']}` @ `{tip}` {r['note']} "
                             f"No train takes this tip; a tip that also changes a source rejoins the queue with a new READY.")
                self.state.tell("regenerate-only", issue, tip)
                self.log(f"#{issue} ({r['branch']} @ {tip}) is regenerate-only: told once, never planned at this tip")
            elif r["state"] == "tip-moved" and not self.state.told("tip-moved", issue, tip):
                self.say.say(issue, f"not trained, `tip-moved`: `{r['branch']}` @ `{tip}`: {r['note']}.")
                self.state.tell("tip-moved", issue, tip)
                self.log(f"#{issue} ({r['branch']} @ {tip}) is tip-moved: told once, not READY until a READY names this tip")
            elif r.get("followed") and not self.state.told("followed-tip", issue, tip):
                self.say.say(issue, f"`{r['branch']}`: {r['followed']}. No new READY is needed for a rebase or fast-forward of the same work.")
                self.state.tell("followed-tip", issue, tip)
                self.log(f"#{issue} ({r['branch']} @ {tip}): {r['followed']}")

    # ----- preflight and reconcile -----
    def preflight(self):
        hook = self.rc.hooks.get("preflight")
        if not hook:
            return ""
        r = subprocess.run(["bash", "-c", hook], capture_output=True, text=True, cwd=str(self.cfg.repo))
        return "" if r.returncode == 0 else ((r.stdout + r.stderr).strip() or f"preflight hook exited {r.returncode}")

    def reconcile(self):
        """A record left by a dead process: the members git proves landed are closed out (the tracker
        is told, retried if it fails); the rest go back to the queue; the train branch is deleted."""
        old = self.state.cycle()
        if not old:
            return
        self.log(f"reconciling a cycle left by a dead process (started {old.get('started')})")
        self.record = old
        for m in old.get("members", []):
            if m["status"] in ("landed", "returned", "nothing"):
                continue
            proof = T.landing_proof(self.cfg, m["tip"])
            if proof:
                self._close_out(m, landed=T.git(self.cfg.repo, "rev-parse", self.cfg.ref).stdout.strip(), train=old.get("train", "?"), proof=proof)
            else:
                m["status"] = "requeued"
        for br in old.get("trainBranches", []):
            T.git(self.cfg.repo, "push", "-q", self.cfg.remote, "--delete", br)
        self.state.clear_cycle()

    # ----- assembly -----
    def assemble(self, members):
        """ONE tree: the integration branch plus each member's RECORDED tip, regenerated and pushed as a
        train branch. Returns (train_branch, sha, assembled, conflicted)."""
        c = self.cfg
        T.git(c.repo, "fetch", c.remote, "-q")
        scratch = T.scratch_prepare(c)
        ok, why = T.prepare_toolchain(c, scratch)
        if not ok:
            raise FaultError(f"the scratch toolchain is not working ({why}); fix the scratch at {scratch}")
        base = T.git(c.repo, "rev-parse", c.ref, check=True).stdout.strip()
        self.record["base"] = base
        self.seq += 1
        train = f"train/{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}-{self.seq}"
        assembled, conflicted = [], []
        for m in members:
            if not T.git(scratch, "cat-file", "-e", m["tip"] + "^{commit}").returncode == 0:
                T.git(scratch, "fetch", "-q", c.remote, m["branch"])
            now_tip = remote_tip(c, m["branch"])
            if T.git(scratch, "merge-base", "--is-ancestor", m["tip"], "HEAD").returncode == 0:
                assembled.append(m)   # a stack's lower slice carried by an earlier member
                continue
            verdict, detail = T.merge_into(c, scratch, m["tip"], message=f"member #{m['issue']}")
            if verdict == "clean":
                assembled.append(m)
                if now_tip and now_tip != m["tip"]:
                    self.say.say(m["issue"], f"`{m['branch']}` moved on origin to `{now_tip[:10]}` after the plan; the train carries `{m['tip'][:10]}` as planned and the newer tip is not in it. Post a new READY if it adds work.")
            else:
                conflicted.append((m, f"{verdict}: {detail}"))
        for m, why in conflicted:
            self._return_to_owner(m, f"conflicts with the integration branch plus the earlier members when the train is assembled ({why}). Rebase onto `{c.ref}`, push with lease, post READY; it rejoins the next train at its new tip.", cause="conflict", log_path=None)
        if not assembled:
            return None, None, [], conflicted
        self.regenerate(scratch, base, assembled)
        r = T.git(scratch, "push", "-q", c.remote, f"HEAD:refs/heads/{train}")
        if r.returncode != 0:
            raise FaultError(f"push of {train} to {c.remote} failed: {r.stderr.strip()}")
        sha = T.git(scratch, "rev-parse", "HEAD").stdout.strip()
        self.record.setdefault("trainBranches", []).append(train)
        return train, sha, assembled, [m for m, _ in conflicted]

    def regenerate(self, scratch, base, assembled):
        """The project's regeneration on the ASSEMBLED tree, committed, so the tree the gate records is the
        tree it publishes. A failure names the members whose diff touches the files its output names, else
        it is nobody's (a FaultError): the cycle ends, no member is blamed."""
        hook = self.rc.hooks.get("regenerate")
        if not hook:
            return
        env = {**os.environ, "AUTOCODER_TRAIN_BASE": base, "AUTOCODER_TRAIN_SCRATCH": str(scratch)}
        r = subprocess.run(["bash", "-c", hook], capture_output=True, text=True, cwd=str(scratch), env=env)
        if r.returncode != 0:
            tail = (r.stdout + r.stderr).strip()
            blamed = self.named_members(base, assembled, tail)
            raise FaultError(f"regeneration failed (exit {r.returncode}): {tail.splitlines()[-1][:200] if tail else '(no output)'}"
                             + (f"; members whose diff touches the files it names: {', '.join('#' + m['issue'] for m in blamed)}" if blamed else ""))
        if T.git(scratch, "status", "--porcelain").stdout.strip():
            T.git(scratch, "add", "-A", check=True)
            T.git(scratch, *IDENT, "commit", "-q", "-m", "regenerate on the assembled tree", check=True)

    # ----- the gate -----
    def gate_command(self, train, sha):
        q = shlex.quote
        c = self.cfg
        if self.rc.gate:
            return self.rc.gate.format(train=q(train), sha=q(sha), issue=q(self.rc.gate_issue), integration=q(c.integration), test_cmd=q(self.rc.test_cmd))
        cmd = (f"bash {q(str(SCRIPTS / 'merge-to-integration.sh'))} --feature {q(train)} --feature-sha {q(sha)} "
               f"--issue {q(self.rc.gate_issue)} --integration {q(c.integration)}")
        return cmd + (f" --test-cmd {q(self.rc.test_cmd)}" if self.rc.test_cmd else "")

    def run_gate(self, train, sha, tag, members=()):
        self.rc.gate_log_dir.mkdir(parents=True, exist_ok=True)
        log_path = self.rc.gate_log_dir / f"{train.replace('/', '-')}-{tag}.log"
        t0 = time.time()
        # The gate learns whose batch it is: merge-to-integration.sh then writes its landing-timings batch row
        # under the train's id with these members (stage seconds, discarded gate time, re-syncs), instead of
        # a solo batch of the gate issue beside the train's own row, which counted every gate twice. The
        # members are the SET BEING GATED, passed in: the record's `gating` status is not reset on the half a
        # bisection holds out, so reading it named siblings the gate never saw.
        env = {**self._ledger_env(), "AUTOCODER_LANDING_BATCH": train.replace("/", "-"),
               "AUTOCODER_LANDING_MEMBERS": ",".join(str(m["issue"]) for m in members)}
        with open(log_path, "w") as lf:
            r = subprocess.run(["bash", "-c", self.gate_command(train, sha)], stdout=lf, stderr=subprocess.STDOUT, cwd=str(self.cfg.repo), env=env)
        self.gates += 1
        return r.returncode, log_path, int(time.time() - t0)

    def judge(self, rc_code, log_path, members):
        """'green' | 'empty' | 'infra' | 'red' from the exit code, the log and git (a gate that pushed landed
        the members whatever it printed afterwards; a gate whose rebase left nothing to land is `empty`, a
        terminal verdict that blames nobody and is never bisected)."""
        text = log_path.read_text(errors="replace")
        T.git(self.cfg.repo, "fetch", self.cfg.remote, "-q")
        if rc_code == 0 and LANDED_RE.search(text):
            return "green", ""
        if members and all(tip_landed(self.cfg, m["tip"]) for m in members):
            return "green", ""
        empty = re.compile(self.rc.empty_pattern, re.M).search(text)
        if empty:
            return "empty", empty.group(0)[:300]
        infra = re.compile(self.rc.infra_pattern, re.M).search(text)
        if infra:
            return "infra", infra.group(0)[:300]
        red_base = RED_BASE_RE.search(text)
        if red_base:
            return "red-base", red_base.group(0)[:300]
        first = next((ln for ln in text.splitlines() if ERROR_LINE_RE.match(ln)), "")
        if not first and (rc_code < 0 or rc_code > 128):
            # Ended by a signal (a memory-cap kill, a host shutdown) with no verdict line of its own: the
            # host, not the tree, stopped it; nobody is blamed, bisected or held out.
            return "infra", f"the gate ended by signal (exit {rc_code}) with no verdict"
        return "red", first[:300] or f"gate exited {rc_code} with no ::error:: line"

    def gate_set(self, members, first=False):
        """Assemble and gate one set. Lands it on green. Returns 'green', 'red', 'infra', 'red-base', 'regen' or 'empty'
        (nothing to land: the members are marked landed nothing and dropped at their tips)."""
        infra_left = self.rc.infra_regates
        while True:
            t_asm = time.time()
            try:
                train, sha, assembled, _ = self.assemble(members)
            except FaultError as e:
                self.log(f"planner/scratch fault, nobody is blamed: {e}")
                self.say.report(f"train not gated: {e}")
                return "regen"
            if not assembled:
                return "green"   # everything conflicted and was returned; nothing to gate
            members = assembled
            self._set_status(members, "gating")
            for m in members:
                self.state.launched(m["issue"], m["tip"][:10])
            batch_id = train.replace("/", "-")
            assembly_s = int(time.time() - t_asm)
            for m in members:
                self.timing("change", "--issue", m["issue"], "--event", "batched", "--batch", batch_id)
            gate_since = now_iso()
            code, log_path, gate_s = self.run_gate(train, sha, f"g{self.gates + 1}", members)
            verdict, line = self.judge(code, log_path, members)
            self.log(f"{train} ({' '.join('#' + m['issue'] for m in members)}): gate {verdict}" + (f" ({line})" if line else ""))
            member_ids = ",".join(m["issue"] for m in members)
            # The train's batch row: assembly and gate seconds and the verdict it judged. The gate wrote the same
            # id with the seconds it measured and its stages; the report merges the two. A green batch gets a second
            # row with the publish seconds once the close-out is done.
            self.timing("batch", "--batch", batch_id, "--members", member_ids, "--assembly-s", assembly_s, "--gate-s", gate_s,
                        "--verdict", {"green": "green", "red": "red", "infra": "infra", "empty": "aborted", "red-base": "red"}[verdict],
                        *(["--cause", "infra"] if verdict == "infra" else ["--cause", "other"] if verdict == "empty"
                          else ["--cause", "red-integration"] if verdict == "red-base" else []))
            if verdict == "infra":
                self.gate_end_event(gate_since, train, gate_s, line)
            if verdict == "green":
                landed = T.git(self.cfg.repo, "rev-parse", self.cfg.ref).stdout.strip()
                t_pub = time.time()
                self.publish(train, members, landed, log_path)
                self.timing("batch", "--batch", batch_id, "--members", member_ids, "--publish-s", int(time.time() - t_pub), "--verdict", "green")
                return "green"
            T.git(self.cfg.repo, "push", "-q", self.cfg.remote, "--delete", train)
            if verdict == "empty":
                self.land_nothing(train, members, line, log_path)
                return "empty"
            kept = self.keep_log(log_path, train)
            self.record["lastRed"] = {"train": train, "line": line, "log": str(kept)}
            if verdict == "infra":
                if infra_left > 0:
                    infra_left -= 1
                    self.log(f"infrastructure red: re-gating the same {len(members)} member(s) once; nobody is dropped, held out or bisected")
                    self.say.report(f"{train}: infrastructure red (`{line[:200]}`); re-gating the same members once.")
                    continue
                return "infra"
            if verdict == "red-base":
                self.log(f"red {self.cfg.integration}, not a member's: the gate re-ran the failing file(s) on {self.cfg.ref} alone and they fail there too; nobody is dropped, held out, bisected or re-gated")
                self.say.report(f"{train}: red `{self.cfg.integration}`, not a member's (`{line[:200]}`). The gate re-ran the file(s) that failed on the integrated tree on `{self.cfg.ref}` alone and they fail there too, so no member owns this red: nobody dropped, held out or re-gated (it would fail the same way on the same base); every member stays in the queue as it is. Open or cite the issue for red `{self.cfg.integration}` and fix it forward; the next train takes them.")
                return "red-base"
            return "red"

    def land_nothing(self, train, members, line, log_path):
        """The gate's rebase dropped every commit as already upstream: the set's net change against the
        integration branch is nothing (regenerated files put back by the regeneration, or work already
        there). Terminal: every member is marked `landed nothing`, told once, dropped at its tip (the queue
        reads `train-dropped` and never plans that tip again); nothing is closed, nobody is bisected."""
        kept = self.keep_log(log_path, train)
        c = self.cfg
        for m in members:   # dropped FIRST: a death between the two must not offer the tip again
            self.state.drop(m["issue"], m["tip"][:10], NOTHING_LANDED)
        self._set_status(members, "nothing", NOTHING_LANDED)
        for m in members:
            self.timing("change", "--issue", m["issue"], "--event", "returned", "--cause", "other")
            self.say.say(m["issue"], f"{NOTHING_LANDED}: `{m['branch']}` @ `{m['tip'][:10]}` was in **{train}**, whose landing "
                         f"left nothing to land (`{line[:160]}`). The train's net change against `{c.ref}` is empty: a change to a "
                         f"regenerated file is put back by the regeneration, and work already on `{c.integration}` adds nothing. "
                         f"Not closed, not bisected; no train takes this tip again. If the branch should change a source, "
                         f"change it and post a new READY; otherwise close this issue by hand. Gate log: `{kept}` on the gate host.")
        self.say.report(f"{train}: nothing to land ({' '.join('#' + m['issue'] for m in members)}; `{line[:160]}`): "
                        f"every member marked landed nothing and dropped at its tip; no bisection.")
        self.log(f"{train}: nothing to land; {len(members)} member(s) marked landed nothing, no bisection")

    def keep_log(self, log_path, train):
        dest = self.rc.cfg.state_dir / "logs" / f"{train.replace('/', '-')}.red.log"
        dest.parent.mkdir(parents=True, exist_ok=True)
        if Path(log_path) != dest:
            shutil.copy(log_path, dest)
        return dest

    # ----- a red: attribute, then re-gate the remaining members, else bisect -----
    def named_members(self, base, members, text):
        """Members whose diff touches a path the failure text names. A path every member touches (a lockfile)
        names nobody. The project's `attribute` hook, when set, decides instead: it gets the text on stdin
        and the members as `issue<TAB>tip` rows in AUTOCODER_TRAIN_MEMBERS, and prints one issue per line."""
        hook = self.rc.hooks.get("attribute")
        if hook:
            rows = "\n".join(f"{m['issue']}\t{m['tip']}" for m in members)
            r = subprocess.run(["bash", "-c", hook], input=text, capture_output=True, text=True, cwd=str(self.cfg.repo),
                               env={**os.environ, "AUTOCODER_TRAIN_MEMBERS": rows, "AUTOCODER_TRAIN_BASE": base})
            named = set(r.stdout.split()) if r.returncode == 0 else set()
            return [m for m in members if m["issue"] in named]
        tokens = {t.lstrip("./") for t in PATH_TOKEN_RE.findall(text)}
        hits = []
        for m in members:
            if changed_files(self.cfg, base, m["tip"]) & tokens:
                hits.append(m)
        return hits if len(hits) < len(members) or len(members) == 1 else []

    def bisect_or_attribute(self, members):
        red = self.record["lastRed"]
        text = Path(red["log"]).read_text(errors="replace")
        base = T.git(self.cfg.repo, "rev-parse", self.cfg.ref).stdout.strip()
        named = self.named_members(base, members, text) if len(members) > 1 else []
        if named:
            for m in named:
                self._return_to_owner(m, f"the gate failed and this branch is the one the failure names: `{red['line'][:200]}`.", cause="defect", log_path=red["log"])
            rest = [m for m in members if m not in named]
            self.log(f"returned {', '.join('#' + m['issue'] for m in named)} (named by the failure); re-gating the remaining {len(rest)} as a new set")
            if rest and self.budget():
                if self.gate_set(rest) == "red":
                    self.bisect_or_attribute(rest)
            return
        self.bisect(members)

    def budget(self):
        if self.gates >= self.rc.max_gates + 1:
            self.log(f"gate budget ({self.rc.max_gates} after the first) spent: the undecided members stay in the queue, unfaulted")
            return False
        return True

    def bisect(self, members):
        """members is known red. Never lands untested work: a half is gated, or red by inference."""
        if len(members) == 1:
            m = members[0]
            red = self.record["lastRed"]
            self._return_to_owner(m, f"the gate failed with this branch in the set and passed without it (found by elimination or alone): `{red['line'][:200]}`.", cause="defect", log_path=red["log"])
            return
        half = (len(members) + 1) // 2
        a, b = members[:half], members[half:]
        if not self.budget():
            return
        va = self.gate_set(a)
        if va in ("green", "empty"):
            self.bisect(b)          # b is red by inference (an empty half carried none of the set's change)
        elif va == "red":
            self.bisect(a)
            if self.budget():
                vb = self.gate_set(b)
                if vb == "red":
                    self.bisect(b)
        # infra / regen: the cycle ends with everything undecided left in the queue

    # ----- publish and close-out -----
    def publish(self, train, members, landed, log_path):
        """Each member is proven against the LANDED commit (not the moving integration branch), closed out
        with the proof that applied, and only then the project's `landed` hook runs, once per landing."""
        c = self.cfg
        T.git(c.repo, "fetch", c.remote, "-q")
        red_base = RED_BASE_RE.search(Path(log_path).read_text(errors="replace")) if log_path else None
        if red_base:
            self.log(f"{train} landed on a red {c.integration}: {red_base.group(0)[:200]}")
            self.say.report(f"{train}: landed on a RED `{c.integration}` (`{red_base.group(0)[:200]}`): the file(s) that failed on the integrated tree fail on `{c.ref}` alone too, so that red is the integration branch's, not this train's; it was red before this landing and is red after it. Open or cite its issue and fix it forward.")
        proofs = {m["issue"]: T.landing_proof(c, m["tip"], landed) for m in members}
        unlanded = [m for m in members if not proofs[m["issue"]]]
        for m in members:
            if m in unlanded:
                continue
            self._close_out(m, landed, train, proofs[m["issue"]])
        if unlanded:
            self.log(f"{train}: the gate says landed but {', '.join('#' + m['issue'] for m in unlanded)} is not in {c.ref}: not closed, left in the queue")
            self._set_status(unlanded, "requeued", "not found in the integration branch after the gate; nothing closed")
            self.say.report(f"{train}: landed `{landed[:10]}` but {', '.join('#' + m['issue'] for m in unlanded)} is not in the integration branch; nothing closed for them.")
        else:
            self.say.report(f"{train}: landed `{landed[:10]}`: {' '.join('#' + m['issue'] for m in members)}")
        T.git(c.repo, "push", "-q", c.remote, "--delete", train)
        self.landed_hook(train, [m for m in members if m not in unlanded], unlanded, landed)

    def landed_hook(self, train, members, unlanded, landed):
        """The project's close-out after a landing (an upstream sync, a drift check, a deploy note), run in
        the repo with the landing in its environment: the integration branch moved, whether or not every
        member was proven in it. It cannot unland anything: a failure is logged and reported, the members
        stay closed."""
        hook = self.rc.hooks.get("landed")
        if not hook:
            return
        rows = lambda ms: "\n".join(f"{m['issue']}\t{m['tip']}\t{m['branch']}" for m in ms)
        env = {**os.environ, "AUTOCODER_TRAIN_LANDED": landed, "AUTOCODER_TRAIN_BASE": self.record.get("base", ""),
               "AUTOCODER_TRAIN_BRANCH": train, "AUTOCODER_TRAIN_INTEGRATION": self.cfg.integration,
               "AUTOCODER_TRAIN_MEMBERS": rows(members), "AUTOCODER_TRAIN_UNLANDED": rows(unlanded)}
        r = subprocess.run(["bash", "-c", hook], capture_output=True, text=True, cwd=str(self.cfg.repo), env=env)
        if r.returncode != 0:
            tail = ((r.stdout + r.stderr).strip().splitlines() or ["(no output)"])[-1][:200]
            self.log(f"landed hook exited {r.returncode} after {train} landed as {landed[:10]} (the landing stands): {tail}")
            self.say.report(f"{train}: the `landed` hook exited {r.returncode} after `{landed[:10]}` landed (`{tail}`); the landing stands, run the hook by hand.")

    def _close_out(self, m, landed, train, proof="ancestor"):
        c = self.cfg
        cur = remote_tip(c, m["branch"])
        kept = bool(cur) and not T.landing_proof(c, cur, landed)
        self._set_status([m], "landed", landed[:10])
        self.landed_total.append(m["issue"])
        self.timing("change", "--issue", m["issue"], "--event", "landed", "--batch", train.replace("/", "-"))
        self.say.say(m["issue"], f"landed on `{c.integration}` as `{landed[:10]}` in **{train}** (the tested tree is the published tree; landing proof: {proof}). Branch `{m['branch']}` @ `{m['tip'][:10]}` merged"
                     + (f"; origin/{m['branch']} kept at `{cur[:10]}` (moved after the plan, not in the train: re-bank it if it adds work)." if kept else " and deleted."), close=True)
        try:
            T.reopen_if_newer_ready(c, m["issue"], m["branch"], landed, who=self.rc.swarm)   # the train's prefix, so the queue never reads it as a READY
        except RuntimeError as e:
            self.log(f"could not check #{m['issue']} for a newer READY ({e}); reopen it by hand if its newest READY names another branch")
        if cur and not kept:
            T.git(c.repo, "push", "-q", c.remote, "--delete", m["branch"], f"--force-with-lease=refs/heads/{m['branch']}:{cur}")

    def _return_to_owner(self, m, why, cause, log_path):
        self._set_status([m], "returned", why[:200])
        self.returned_total.append(m["issue"])
        self.state.drop(m["issue"], m["tip"][:10], why[:200])
        self.timing("change", "--issue", m["issue"], "--event", "returned", "--cause", cause)
        keep = f" The gate log is kept at `{log_path}` on the gate host." if log_path else ""
        self.say.say(m["issue"], f"returned: `{m['branch']}` @ `{m['tip'][:10]}`: {why}{keep} Reproduce on the branch merged with `{self.cfg.ref}`, fix, push with lease, post READY; the next train takes it at its new tip.")
        self.log(f"returned #{m['issue']} ({m['branch']} @ {m['tip'][:10]}): {why[:160]}")


class FaultError(Exception):
    """The train's own machinery failed (scratch, toolchain, regeneration, push): no member is to blame."""
