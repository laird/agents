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
    report_issue: str = ""         # where batch-level notes go; empty = member issues only
    swarm: str = "merge-train"     # every tracker write starts with this
    timings_cmd: str = ""          # default: landing-timings.py beside this file, when present
    hooks: dict = field(default_factory=dict)   # preflight, regenerate, attribute (plus slice 1's)
    gate_log_dir: Path = None


def load_run_config(repo, config_file=None, env=None) -> RunConfig:
    """Slice 1's Config plus the keys this slice reads from the same `train` object:
    gate, gateIssue, testCmd, batchStart, batchMin, batchMax, maxGates, infraRegates, infraPattern,
    reportIssue, swarm, timingsCmd, gateLogDir, hooks.{preflight, regenerate, attribute}."""
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
    """A member is landed when its commits are in the integration branch: an ancestor, or (the gate
    lands by rebase, which rewrites commits) every commit patch-equivalent to one already there."""
    ref = ref or cfg.ref
    if T.git(cfg.repo, "merge-base", "--is-ancestor", tip, ref).returncode == 0:
        return True
    cherry = T.git(cfg.repo, "cherry", ref, tip)
    return cherry.returncode == 0 and not any(ln.startswith("+") for ln in cherry.stdout.splitlines())


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

    # ----- timings (wqb's writer; best effort, never fails the cycle) -----
    def timing(self, *args):
        cmd = self.rc.timings_cmd
        if not cmd:
            w = SCRIPTS / "landing-timings.py"
            if not w.is_file():
                return
            cmd = f"{shlex.quote(sys.executable)} {shlex.quote(str(w))}"
        try:
            subprocess.run(["bash", "-c", f'{cmd} "$@"', "_", *map(str, args)], capture_output=True, text=True)
        except OSError:
            pass

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
        try:
            return self._run_locked(size)
        finally:
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
        rows = T.plan_queue(c)
        out, fault = T.plan_train(c, rows, limit)
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
            self.log("no clean READY branch to train")
            return 0, []
        self.record = {"started": now_iso(), "limit": limit, "members": members, "sets": []}
        self.state.save_cycle(self.record)
        self.log(f"planned {len(members)} member(s) (limit {limit}): " + " ".join(f"#{m['issue']}" for m in members))
        first = self.gate_set(members, first=True)
        if first == "red":
            self.bisect_or_attribute(members)
        elif first == "infra":
            self.log("infrastructure red twice: the cycle ends, every member stays in the queue unfaulted")
        elif first == "regen":
            self.log("the assembled tree could not be regenerated: the cycle ends, nobody blamed")
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
            if m["status"] in ("landed", "returned"):
                continue
            if tip_landed(self.cfg, m["tip"]):
                self._close_out(m, landed=T.git(self.cfg.repo, "rev-parse", self.cfg.ref).stdout.strip(), train=old.get("train", "?"))
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

    def run_gate(self, train, sha, tag):
        self.rc.gate_log_dir.mkdir(parents=True, exist_ok=True)
        log_path = self.rc.gate_log_dir / f"{train.replace('/', '-')}-{tag}.log"
        t0 = time.time()
        with open(log_path, "w") as lf:
            r = subprocess.run(["bash", "-c", self.gate_command(train, sha)], stdout=lf, stderr=subprocess.STDOUT, cwd=str(self.cfg.repo))
        self.gates += 1
        return r.returncode, log_path, int(time.time() - t0)

    def judge(self, rc_code, log_path, members):
        """'green' | 'infra' | 'red' from the exit code, the log and git (a gate that pushed landed the
        members whatever it printed afterwards)."""
        text = log_path.read_text(errors="replace")
        T.git(self.cfg.repo, "fetch", self.cfg.remote, "-q")
        if rc_code == 0 and LANDED_RE.search(text):
            return "green", ""
        if members and all(tip_landed(self.cfg, m["tip"]) for m in members):
            return "green", ""
        infra = re.compile(self.rc.infra_pattern, re.M).search(text)
        if infra:
            return "infra", infra.group(0)[:300]
        first = next((ln for ln in text.splitlines() if ERROR_LINE_RE.match(ln)), "")
        return "red", first[:300] or f"gate exited {rc_code} with no ::error:: line"

    def gate_set(self, members, first=False):
        """Assemble and gate one set. Lands it on green. Returns 'green', 'red', 'infra' or 'regen'."""
        infra_left = self.rc.infra_regates
        while True:
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
            for m in members:
                self.timing("change", "--issue", m["issue"], "--event", "batched", "--batch", batch_id)
            code, log_path, gate_s = self.run_gate(train, sha, f"g{self.gates + 1}")
            verdict, line = self.judge(code, log_path, members)
            self.log(f"{train} ({' '.join('#' + m['issue'] for m in members)}): gate {verdict}" + (f" ({line})" if line else ""))
            self.timing("batch", "--batch", batch_id, "--members", ",".join(m["issue"] for m in members), "--gate-s", gate_s,
                        "--verdict", {"green": "green", "red": "red", "infra": "infra"}[verdict], *(["--cause", "infra"] if verdict == "infra" else []))
            if verdict == "green":
                landed = T.git(self.cfg.repo, "rev-parse", self.cfg.ref).stdout.strip()
                self.publish(train, members, landed, log_path)
                return "green"
            T.git(self.cfg.repo, "push", "-q", self.cfg.remote, "--delete", train)
            kept = self.keep_log(log_path, train)
            self.record["lastRed"] = {"train": train, "line": line, "log": str(kept)}
            if verdict == "infra":
                if infra_left > 0:
                    infra_left -= 1
                    self.log(f"infrastructure red: re-gating the same {len(members)} member(s) once; nobody is dropped, held out or bisected")
                    self.say.report(f"{train}: infrastructure red (`{line[:200]}`); re-gating the same members once.")
                    continue
                return "infra"
            return "red"

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
        if va == "green":
            self.bisect(b)          # b is red by inference
        elif va == "red":
            self.bisect(a)
            if self.budget():
                vb = self.gate_set(b)
                if vb == "red":
                    self.bisect(b)
        # infra / regen: the cycle ends with everything undecided left in the queue

    # ----- publish and close-out -----
    def publish(self, train, members, landed, log_path):
        c = self.cfg
        T.git(c.repo, "fetch", c.remote, "-q")
        unlanded = [m for m in members if not tip_landed(c, m["tip"])]
        for m in members:
            if m in unlanded:
                continue
            self._close_out(m, landed, train)
        if unlanded:
            self.log(f"{train}: the gate says landed but {', '.join('#' + m['issue'] for m in unlanded)} is not in {c.ref}: not closed, left in the queue")
            self._set_status(unlanded, "requeued", "not found in the integration branch after the gate; nothing closed")
            self.say.report(f"{train}: landed `{landed[:10]}` but {', '.join('#' + m['issue'] for m in unlanded)} is not in the integration branch; nothing closed for them.")
        else:
            self.say.report(f"{train}: landed `{landed[:10]}`: {' '.join('#' + m['issue'] for m in members)}")
        T.git(c.repo, "push", "-q", c.remote, "--delete", train)

    def _close_out(self, m, landed, train):
        c = self.cfg
        cur = remote_tip(c, m["branch"])
        kept = bool(cur) and not tip_landed(c, cur)
        self._set_status([m], "landed", landed[:10])
        self.landed_total.append(m["issue"])
        self.timing("change", "--issue", m["issue"], "--event", "landed", "--batch", train.replace("/", "-"))
        self.say.say(m["issue"], f"landed on `{c.integration}` as `{landed[:10]}` in **{train}** (the tested tree is the published tree). Branch `{m['branch']}` @ `{m['tip'][:10]}` merged"
                     + (f"; origin/{m['branch']} kept at `{cur[:10]}` (moved after the plan, not in the train: re-bank it if it adds work)." if kept else " and deleted."), close=True)
        try:
            T.reopen_if_newer_ready(c, m["issue"], m["branch"], landed)
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
