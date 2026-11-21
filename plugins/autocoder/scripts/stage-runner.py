#!/usr/bin/env python3
"""Stage runner: run a project's gate stages from a manifest, independent ones at the same time.

A gate command is usually one `&&` chain, so stages that do not depend on each other (a build, a
generated-files check, a lint, a typecheck) wait in line. This runner reads the stages from a JSON
manifest, runs the declared-independent ones side by side inside a concurrency and a memory budget,
keeps each stage's bounded output and verdict, and fails the run if any stage fails. Generic by
design: it knows nothing about any project. The manifest is the project's; the gate command in the
project's doctrine file becomes one invocation of this script.

    stage-runner.py --manifest gate-stages.json [--timings out.json] [--serial]
                    [--concurrency N] [--only a,b] [--list | --list-commands]
    stage-runner.py --stage-args out.json      # prints `--stage name=seconds ...` for landing_batch

Exit status: 0 every stage passed (and the tree guard held); 1 a stage failed, or the guard broke;
2 the manifest or the command line is wrong (nothing ran).

MANIFEST (JSON; keys not listed are rejected, so a typo is an error, not a silent default)

  {"version": 1,
   "title": "gate stage timings",        summary heading
   "concurrency": 4,                     stages running at once (default: min(4, cores))
   "memory_budget_mib": 10000,           sum of running stages' memory_mib; default = this
                                         process's cgroup memory.max minus headroom, else unbounded
   "memory_headroom_mib": 1024,
   "heartbeat_s": 60,                    a line when nothing printed for this long: gates run under
                                         a no-output watchdog, and output is printed in order
   "on_failure": "cancel" | "finish",    a stage failed: stop the running ones (default) or let them end
   "tree_guard": true,                   HEAD's tree and the tracked-file diff are recorded after the
                                         last exclusive stage and must be unchanged when the run ends
   "env": {"NAME": "{run_dir}/x"},       added to every stage's environment ({run_dir} expands)
   "stages": [ STAGE, ... ]}

  STAGE  {"name": "build",               unique; letters, digits, . _ -
          "cmd": "npm run build",        run as `bash -c` with pipefail, from --cwd (default: cwd).
                                         No `| tail`: the runner bounds the output itself
          "needs": ["install"],          stages that must PASS first (declared, never inferred)
          "conflicts": ["lint"],         never running at the same moment as these stages (symmetric;
                                         order is whichever is ready first). For a shared port, a shared
                                         build cache, a stage that rewrites files another one reads
          "exclusive": true,             a BARRIER: starts only when every stage declared before it
                                         has ended, runs alone, and every stage declared after it
                                         waits for it. For anything that mutates the tree or the
                                         environment (disk check, merge drivers, dependency install,
                                         regeneration, a baseline ratchet)
          "tail": 15,                    lines of output kept (default 15); a failing stage's tail is
                                         printed before the verdict
          "memory_mib": 6144,            declared peak; counted against the budget, exported as
                                         AUTOCODER_STAGE_MEMORY_MIB so the stage can size a heap. The
                                         summary shows each stage's measured peak (sum of the RSS of its
                                         processes, sampled each second) to calibrate it against
          "est_s": 120,                  expected seconds: of the ready stages the longest starts first
          "timeout_s": 7200}             optional; a safety bound for dead work, never an SLA

  GROUP  a STAGE with "stages": [...] and "wrapper": "tool {inner}" instead of "cmd". The group is
         one node of the outer schedule; the runner starts `wrapper` with {inner} replaced by ONE
         shell-quoted argument that runs this script on the group's inner stages. The wrapper is
         where state shared by those stages lives: an isolated database created once, a guard on the
         tree around them. Inner stages are scheduled the same way (own concurrency and budget).

Output order is the manifest's: a stage's block is printed once it and every stage declared before it
have ended, so the log reads the same whatever the scheduling. A block is a header line, the tail, and
nothing else; a failing stage's block comes before the final lines, and the LAST line of a run is the
verdict (`stage runner: PASS` or `stage runner: FAIL ...`), after the timings summary.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shlex
import signal
import subprocess
import sys
import tempfile
import time
from collections import deque
from pathlib import Path

NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
TOP_KEYS = {"version", "title", "concurrency", "memory_budget_mib", "memory_headroom_mib", "heartbeat_s",
            "on_failure", "tree_guard", "env", "stages"}
STAGE_KEYS = {"name", "cmd", "needs", "conflicts", "exclusive", "tail", "memory_mib", "est_s", "timeout_s",
              "wrapper", "stages"}
DEFAULT_TAIL = 15
GROUP_TAIL = 60
KILL_GRACE_S = 5.0


class ManifestError(Exception):
    pass


def rss_by_session() -> dict[int, int]:
    """Sum of resident pages (in MiB) per session id, from /proc; {} where /proc is unreadable."""
    out: dict[int, int] = {}
    page = os.sysconf("SC_PAGE_SIZE")
    try:
        entries = os.listdir("/proc")
    except OSError:
        return out
    for e in entries:
        if not e.isdigit():
            continue
        try:
            stat = Path(f"/proc/{e}/stat").read_text()
            sid = int(stat[stat.rindex(")") + 2:].split()[3])
            rss = int(Path(f"/proc/{e}/statm").read_text().split()[1])
        except (OSError, ValueError, IndexError):
            continue
        out[sid] = out.get(sid, 0) + rss * page // (1024 * 1024)
    return out


class Stage:
    def __init__(self, raw: dict, index: int, where: str):
        unknown = set(raw) - STAGE_KEYS
        if unknown:
            raise ManifestError(f"{where}: unknown stage key(s) {sorted(unknown)}")
        name = raw.get("name")
        if not isinstance(name, str) or not NAME_RE.match(name):
            raise ManifestError(f"{where}: stage #{index} needs a name matching {NAME_RE.pattern}, got {name!r}")
        self.name, self.index = name, index
        self.is_group = "stages" in raw
        if self.is_group == ("cmd" in raw):
            raise ManifestError(f"stage {name}: give exactly one of cmd or (wrapper + stages)")
        if self.is_group and not isinstance(raw.get("wrapper"), str):
            raise ManifestError(f"stage {name}: a group needs a wrapper containing {{inner}}")
        if self.is_group and "{inner}" not in raw["wrapper"]:
            raise ManifestError(f"stage {name}: wrapper must contain {{inner}}")
        if not self.is_group and "wrapper" in raw:
            raise ManifestError(f"stage {name}: wrapper belongs to a group (a stage with stages)")
        if not self.is_group and not isinstance(raw["cmd"], str):
            raise ManifestError(f"stage {name}: cmd must be a string")
        self.cmd = raw.get("cmd")
        self.wrapper = raw.get("wrapper")
        self.needs = list(raw.get("needs", []))
        if not all(isinstance(n, str) for n in self.needs):
            raise ManifestError(f"stage {name}: needs must be a list of stage names")
        self.conflicts = set(raw.get("conflicts", []))
        if not all(isinstance(n, str) for n in self.conflicts):
            raise ManifestError(f"stage {name}: conflicts must be a list of stage names")
        self.exclusive = bool(raw.get("exclusive", False))
        self.tail = _int(raw, "tail", GROUP_TAIL if self.is_group else DEFAULT_TAIL, name, lo=0)
        self.memory_mib = _int(raw, "memory_mib", 0, name, lo=0)
        self.est_s = _int(raw, "est_s", 0, name, lo=0)
        self.timeout_s = _int(raw, "timeout_s", 0, name, lo=0)
        self.children = None
        if self.is_group:
            self.children = parse_stages(raw["stages"], f"group {name}")
        # filled in by the scheduler
        self.deps: set[str] = set()
        self.status = "pending"  # pending running pass fail cancelled skipped notrun
        self.rc: int | None = None
        self.started: float | None = None
        self.ended: float | None = None
        self.out_path: Path | None = None
        self.proc: subprocess.Popen | None = None
        self.printed = False
        self.note = ""
        self.peak_mib = 0


def _int(raw: dict, key: str, default: int, name: str, lo: int) -> int:
    v = raw.get(key, default)
    if isinstance(v, bool) or not isinstance(v, int) or v < lo:
        raise ManifestError(f"stage {name}: {key} must be an integer >= {lo}, got {v!r}")
    return v


def parse_stages(raw_list, where: str) -> list[Stage]:
    if not isinstance(raw_list, list) or not raw_list:
        raise ManifestError(f"{where}: stages must be a non-empty list")
    stages = [Stage(r, i, where) for i, r in enumerate(raw_list)]
    names = [s.name for s in stages]
    dup = sorted({n for n in names if names.count(n) > 1})
    if dup:
        raise ManifestError(f"{where}: duplicate stage name(s) {dup}")
    for s in stages:
        for n in s.needs:
            if n not in names:
                raise ManifestError(f"{where}: stage {s.name} needs {n!r}, which is not a stage here "
                                    f"(a group's inner stages cannot need outer ones)")
            if n == s.name:
                raise ManifestError(f"{where}: stage {s.name} needs itself")
    for s in stages:
        for n in s.conflicts:
            if n not in names or n == s.name:
                raise ManifestError(f"{where}: stage {s.name} conflicts with {n!r}, which is not another stage here")
    for s in stages:  # mutual exclusion is symmetric whichever side declared it
        for n in list(s.conflicts):
            stages[names.index(n)].conflicts.add(s.name)
    _add_implicit_edges(stages, where)
    return stages


def _add_implicit_edges(stages: list[Stage], where: str) -> None:
    """Barriers: an exclusive stage waits for every earlier stage; every stage waits for earlier barriers."""
    for s in stages:
        s.deps = set(s.needs)
        for e in stages[: s.index]:
            if e.exclusive or s.exclusive:
                s.deps.add(e.name)
    by = {s.name: s for s in stages}
    state: dict[str, int] = {}

    def visit(n: str, path: list[str]) -> None:
        if state.get(n) == 2:
            return
        if state.get(n) == 1:
            raise ManifestError(f"{where}: dependency cycle {' -> '.join(path + [n])} "
                                f"(barrier ordering included: an exclusive stage waits for every earlier stage)")
        state[n] = 1
        for d in sorted(by[n].deps):
            visit(d, path + [n])
        state[n] = 2

    for s in stages:
        visit(s.name, [])


def load_manifest(path: Path) -> dict:
    try:
        data = json.loads(path.read_text())
    except OSError as e:
        raise ManifestError(f"cannot read manifest {path}: {e}") from e
    except ValueError as e:
        raise ManifestError(f"manifest {path} is not valid JSON: {e}") from e
    if not isinstance(data, dict):
        raise ManifestError(f"manifest {path}: top level must be an object")
    unknown = set(data) - TOP_KEYS
    if unknown:
        raise ManifestError(f"manifest {path}: unknown key(s) {sorted(unknown)}")
    if data.get("version") != 1:
        raise ManifestError(f"manifest {path}: version must be 1, got {data.get('version')!r}")
    if data.get("on_failure", "cancel") not in ("cancel", "finish"):
        raise ManifestError(f"manifest {path}: on_failure must be cancel or finish")
    env = data.get("env", {})
    if not isinstance(env, dict) or not all(isinstance(k, str) and isinstance(v, str) for k, v in env.items()):
        raise ManifestError(f"manifest {path}: env must map names to strings")
    data["_stages"] = parse_stages(data.get("stages"), f"manifest {path}")
    return data


def all_commands(stages: list[Stage]):
    for s in stages:
        if s.is_group:
            yield s.wrapper
            yield from all_commands(s.children)
        else:
            yield s.cmd


# ---------------------------------------------------------------- resources

def cgroup_memory_max_mib() -> int | None:
    try:
        for line in Path("/proc/self/cgroup").read_text().splitlines():
            if line.startswith("0::"):
                raw = (Path("/sys/fs/cgroup") / line[3:].lstrip("/") / "memory.max").read_text().strip()
                return int(raw) // (1024 * 1024) if raw.isdigit() else None
    except (OSError, ValueError):
        pass
    return None


def resolve_limits(manifest: dict, args) -> tuple[int, int | None]:
    cores = os.cpu_count() or 2
    conc = args.concurrency or int(os.environ.get("AUTOCODER_STAGE_CONCURRENCY", 0) or 0) \
        or manifest.get("concurrency") or min(4, cores)
    if args.serial or os.environ.get("AUTOCODER_STAGE_SERIAL") == "1":
        conc = 1
    budget = os.environ.get("AUTOCODER_STAGE_MEMORY_BUDGET_MIB") or manifest.get("memory_budget_mib")
    if budget is None:
        cg = cgroup_memory_max_mib()
        if cg:
            budget = max(cg - manifest.get("memory_headroom_mib", 1024), 1)
    return max(int(conc), 1), (int(budget) if budget else None)


# ---------------------------------------------------------------- tree guard

def tree_signature(cwd: str) -> str | None:
    def git(*a: str) -> str | None:
        r = subprocess.run(["git", "-C", cwd, *a], capture_output=True, text=True)
        return r.stdout if r.returncode == 0 else None
    tree = git("rev-parse", "HEAD^{tree}")
    if tree is None:
        return None
    porcelain = git("status", "--porcelain", "--untracked-files=no") or ""
    return f"{tree.strip()} tracked-changes:{hashlib.sha1(porcelain.encode()).hexdigest()[:12]}"


# ---------------------------------------------------------------- run

class Runner:
    def __init__(self, manifest: dict, stages: list[Stage], conc: int, budget: int | None, cwd: str,
                 run_dir: Path, out=sys.stdout, label: str = "stage runner"):
        self.m, self.stages, self.conc, self.budget, self.cwd = manifest, stages, conc, budget, cwd
        self.run_dir, self.out, self.label = run_dir, out, label
        self.by = {s.name: s for s in stages}
        self.failed: list[Stage] = []
        self.stopping = False
        self.t0 = time.monotonic()
        self.last_print = self.t0
        self.guard_before: str | None = None
        self.guard_note = ""
        self.last_sample = 0.0

    # -- output
    def say(self, text: str = "") -> None:
        print(text, file=self.out, flush=True)
        self.last_print = time.monotonic()

    def tail_of(self, s: Stage) -> list[str]:
        if s.tail == 0 or not s.out_path or not s.out_path.exists():
            return []
        with open(s.out_path, "rb") as f:
            lines = deque((ln.decode("utf-8", "replace").rstrip("\n") for ln in f), maxlen=s.tail)
        return list(lines)

    def flush_blocks(self) -> None:
        for s in self.stages:  # strictly in manifest order
            if s.printed:
                continue
            if s.status in ("pending", "running"):
                return
            self.print_block(s)
            s.printed = True

    def print_block(self, s: Stage) -> None:
        secs = f"{(s.ended or 0) - (s.started or 0):.0f} s" if s.started else "-"
        if s.status == "pass":
            self.say(f"── stage {s.name}: PASS in {secs}")
        elif s.status == "fail":
            self.say(f"── stage {s.name}: FAIL rc={s.rc} in {secs}{(' — ' + s.note) if s.note else ''}")
        elif s.status == "cancelled":
            self.say(f"── stage {s.name}: CANCELLED after {secs} (another stage failed first)")
        elif s.status == "skipped":
            self.say(f"── stage {s.name}: SKIPPED ({s.note})")
            return
        else:
            self.say(f"── stage {s.name}: NOT RUN ({s.note})")
            return
        for ln in self.tail_of(s):
            self.say(ln)

    # -- scheduling
    def stage_env(self, s: Stage) -> dict:
        env = dict(os.environ)
        for k, v in (self.m.get("env") or {}).items():
            env[k] = v.replace("{run_dir}", str(self.run_dir))
        env["AUTOCODER_STAGE_NAME"] = s.name
        env["AUTOCODER_STAGE_MEMORY_MIB"] = str(s.memory_mib)
        env["AUTOCODER_STAGE_RUN_DIR"] = str(self.run_dir)
        if s.is_group:
            env["AUTOCODER_STAGE_MEMORY_BUDGET_MIB"] = str(s.memory_mib) if s.memory_mib else \
                env.get("AUTOCODER_STAGE_MEMORY_BUDGET_MIB", "")
            if not env["AUTOCODER_STAGE_MEMORY_BUDGET_MIB"]:
                del env["AUTOCODER_STAGE_MEMORY_BUDGET_MIB"]
        return env

    def command_of(self, s: Stage) -> str:
        if not s.is_group:
            return s.cmd
        inner = " ".join(shlex.quote(a) for a in [
            sys.executable, os.path.abspath(__file__), "--manifest", self.m["_path"], "--group", s.name,
            "--cwd", self.cwd, "--run-dir", str(self.run_dir / f"group-{s.name}")])
        return s.wrapper.replace("{inner}", shlex.quote(inner))

    def start(self, s: Stage) -> None:
        s.out_path = self.run_dir / f"{s.index:02d}-{s.name}.log"
        s.started = time.monotonic()
        s.status = "running"
        try:
            fh = open(s.out_path, "wb")
            s.proc = subprocess.Popen(["bash", "-o", "pipefail", "-c", self.command_of(s)], cwd=self.cwd,
                                      env=self.stage_env(s), stdout=fh, stderr=subprocess.STDOUT,
                                      stdin=subprocess.DEVNULL, start_new_session=True)
            fh.close()
        except OSError as e:
            s.status, s.rc, s.ended = "fail", 127, time.monotonic()
            s.note = f"could not start: {e}"
            self.failed.append(s)

    def runnable(self, running: list[Stage]) -> list[Stage]:
        used = sum(r.memory_mib for r in running)
        ready = [s for s in self.stages if s.status == "pending"
                 and all(self.by[d].status == "pass" for d in s.deps)]
        ready.sort(key=lambda s: (-s.est_s, s.index))
        picked: list[Stage] = []
        for s in ready:
            if len(running) + len(picked) >= self.conc:
                break
            if s.exclusive and (running or picked):
                continue
            if picked and picked[0].exclusive:
                break
            if any(o.name in s.conflicts for o in running + picked):
                continue
            over = self.budget is not None and s.memory_mib and used + s.memory_mib > self.budget
            if over and (running or picked):
                continue  # waits for memory; a stage bigger than the budget still runs, alone
            picked.append(s)
            used += s.memory_mib
        return picked

    def settle(self, s: Stage, rc: int) -> None:
        s.rc, s.ended = rc, time.monotonic()
        s.status = "pass" if rc == 0 else "fail"
        if rc != 0:
            self.failed.append(s)

    def kill_group(self, s: Stage, sig: int) -> None:
        try:
            os.killpg(s.proc.pid, sig)
        except (ProcessLookupError, PermissionError):
            pass

    def cancel_running(self, running: list[Stage]) -> None:
        for s in running:
            self.kill_group(s, signal.SIGTERM)
        deadline = time.monotonic() + KILL_GRACE_S
        for s in running:
            while s.proc.poll() is None and time.monotonic() < deadline:
                time.sleep(0.05)
            if s.proc.poll() is None:
                self.kill_group(s, signal.SIGKILL)
            s.proc.wait()
            s.status, s.rc, s.ended = "cancelled", s.proc.returncode, time.monotonic()

    def mark_unreachable(self) -> None:
        changed = True
        while changed:
            changed = False
            for s in self.stages:
                if s.status != "pending":
                    continue
                bad = [d for d in sorted(s.deps) if self.by[d].status in ("fail", "skipped", "cancelled", "notrun")]
                if bad:
                    s.status, s.note = "skipped", f"needs {', '.join(bad)}, which did not pass"
                    changed = True

    def run(self) -> int:
        running: list[Stage] = []
        last_exclusive = max((s.index for s in self.stages if s.exclusive), default=-1)
        guard_armed = False
        if self.m.get("tree_guard") and last_exclusive == -1:
            self.guard_before, guard_armed = tree_signature(self.cwd), True
        hb = float(self.m.get("heartbeat_s", 60))
        self.say(f"{self.label}: {len(self.stages)} stage(s), concurrency {self.conc}, memory budget "
                 f"{str(self.budget) + ' MiB' if self.budget else 'unbounded'}, on failure {self.m.get('on_failure', 'cancel')}")
        while True:
            for s in list(running):
                rc = s.proc.poll()
                if rc is None and s.timeout_s and time.monotonic() - s.started > s.timeout_s:
                    self.kill_group(s, signal.SIGKILL)
                    s.proc.wait()
                    rc, s.note = 124, f"exceeded its {s.timeout_s} s timeout"
                if rc is not None:
                    running.remove(s)
                    self.settle(s, rc)
                    if self.m.get("tree_guard") and not guard_armed and s.index == last_exclusive and rc == 0 \
                            and not running:
                        self.guard_before, guard_armed = tree_signature(self.cwd), True
            if self.failed and not self.stopping:
                self.stopping = True
                if self.m.get("on_failure", "cancel") == "cancel":
                    self.cancel_running(running)
                    running = []
                self.mark_unreachable()
                for s in self.stages:
                    if s.status == "pending":
                        s.status, s.note = "notrun", "stopped after a failure"
            if not self.stopping:
                self.mark_unreachable()
                for s in self.runnable(running):
                    self.start(s)
                    if s.status == "running":
                        running.append(s)
                    # a stage that could not start is in self.failed; the next pass stops the run
            self.flush_blocks()
            if not running and all(s.status != "pending" for s in self.stages):
                break
            if not running and not self.stopping and not self.runnable(running) \
                    and any(s.status == "pending" for s in self.stages):
                # Nothing can start and nothing runs: cannot happen after validation; fail loudly if it does.
                stuck = [s.name for s in self.stages if s.status == "pending"]
                for s in self.stages:
                    if s.status == "pending":
                        s.status, s.note = "notrun", "scheduler deadlock"
                self.failed.append(self.by[stuck[0]])
                self.say(f"{self.label}: scheduler found no runnable stage among {stuck}; this is a bug")
            if running and time.monotonic() - self.last_sample >= 1.0:
                self.last_sample = time.monotonic()
                by_sid = rss_by_session()
                for s in running:
                    s.peak_mib = max(s.peak_mib, by_sid.get(s.proc.pid, 0))
            if running and hb and time.monotonic() - self.last_print >= hb:
                self.say("… still running: " + ", ".join(f"{s.name} ({time.monotonic() - s.started:.0f} s)" for s in running))
            time.sleep(0.05)
        self.flush_blocks()
        return self.finish(guard_armed)

    def finish(self, guard_armed: bool) -> int:
        wall = time.monotonic() - self.t0
        guard_broken = False
        if self.m.get("tree_guard") and guard_armed and self.guard_before is not None and not self.failed:
            after = tree_signature(self.cwd)
            if after != self.guard_before:
                guard_broken = True
                self.guard_note = (f"the tree changed while the stages after the last exclusive stage ran: "
                                   f"before {self.guard_before}, after {after}. A stage that mutates the tree "
                                   f"must be declared exclusive so it runs before the tree is recorded")
        self.summary(wall)
        if self.failed or guard_broken:
            if guard_broken:
                self.say(f"{self.label}: tree guard FAILED: {self.guard_note}")
            names = ", ".join(f"{s.name} (rc={s.rc})" for s in self.failed)
            self.say(f"{self.label}: FAIL{(' ' + names) if names else ''}{' + tree guard' if guard_broken else ''}"
                     f" in {wall:.0f} s")
            self._verdict = "fail"
            return 1
        self.say(f"{self.label}: PASS {len(self.stages)} stage(s) in {wall:.0f} s")
        self._verdict = "pass"
        return 0

    _verdict = "fail"

    def summary(self, wall: float) -> None:
        self.say(f"=== {self.m.get('title', 'gate stage timings')}")
        ran = [s for s in self.stages if s.started]
        width = max([len(s.name) for s in self.stages] + [5])
        for s in self.stages:
            if s.started:
                secs = (s.ended or time.monotonic()) - s.started
                mem = f"  peak {s.peak_mib:6d} MiB" if s.peak_mib else ""
                self.say(f"  {s.name:<{width}}  {secs:7.0f} s  +{s.started - self.t0:5.0f} s  {s.status.upper()}{mem}")
            else:
                self.say(f"  {s.name:<{width}}  {'-':>7}    {'':>7}  {s.status.upper()}")
        serial = sum((s.ended or 0) - s.started for s in ran if s.ended and s.started)
        self.say(f"  wall {wall:.0f} s; stages summed {serial:.0f} s; overlap saved {max(serial - wall, 0):.0f} s "
                 f"(concurrency {self.conc})")

    def results(self, wall: float | None = None) -> dict:
        wall = wall if wall is not None else time.monotonic() - self.t0
        return {"v": 1, "verdict": self._verdict, "wall_s": round(wall, 1), "stages": {
            s.name: {"seconds": round((s.ended - s.started), 1) if s.started and s.ended else None,
                     "status": s.status, "rc": s.rc, "peak_rss_mib": s.peak_mib or None, "start_s": round(s.started - self.t0, 1) if s.started else None}
            for s in self.stages}}


def select(stages: list[Stage], only: str | None, manifest_name: str) -> list[Stage]:
    if not only:
        return stages
    want = [n for n in only.split(",") if n]
    missing = [n for n in want if n not in {s.name for s in stages}]
    if missing:
        raise ManifestError(f"--only names unknown stage(s) {missing} in {manifest_name}")
    keep = set(want)
    grew = True
    while grew:  # a selected stage brings its declared and barrier prerequisites
        grew = False
        for s in stages:
            if s.name in keep and not s.deps <= keep:
                keep |= s.deps
                grew = True
    return [s for s in stages if s.name in keep]


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Run a project's gate stages from a manifest, in parallel where declared.")
    ap.add_argument("--manifest")
    ap.add_argument("--cwd", default=os.getcwd(), help="directory the stages run in (default: current)")
    ap.add_argument("--group", help="run one group's inner stages (what a group's wrapper invokes)")
    ap.add_argument("--only", help="comma-separated stage names (their prerequisites come with them)")
    ap.add_argument("--serial", action="store_true", help="concurrency 1: the old chain, for comparison")
    ap.add_argument("--concurrency", type=int)
    ap.add_argument("--timings", default=os.environ.get("AUTOCODER_STAGE_TIMINGS_FILE"),
                    help="write per-stage seconds and the verdict here (JSON)")
    ap.add_argument("--run-dir", help="keep stage logs here (default: a temp dir removed at the end)")
    ap.add_argument("--list", action="store_true", help="print the schedule and exit")
    ap.add_argument("--list-commands", action="store_true", help="print every command the manifest runs, one per line")
    ap.add_argument("--stage-args", metavar="RESULTS", help="print `--stage name=seconds` words from a --timings file")
    args = ap.parse_args(argv)

    if args.stage_args:
        data = json.loads(Path(args.stage_args).read_text())
        print(" ".join(f"--stage {n}={v['seconds']:.0f}" for n, v in data["stages"].items() if v["seconds"] is not None))
        return 0
    if not args.manifest:
        ap.error("--manifest is required")
    try:
        manifest = load_manifest(Path(args.manifest))
        manifest["_path"] = os.path.abspath(args.manifest)
        stages = manifest["_stages"]
        label = "stage runner"
        if args.group:
            grp = next((s for s in stages if s.name == args.group and s.is_group), None)
            if grp is None:
                raise ManifestError(f"--group {args.group!r} is not a group in {args.manifest}")
            stages, label = grp.children, f"stage runner [{grp.name}]"
        stages = select(stages, args.only, args.manifest)
        conc, budget = resolve_limits(manifest, args)
    except ManifestError as e:
        print(f"stage runner: {e}", file=sys.stderr)
        return 2
    if args.list_commands:
        print("\n".join(all_commands(stages)))
        return 0
    if args.list:
        for s in stages:
            kind = "group" if s.is_group else ("exclusive" if s.exclusive else "stage")
            print(f"{s.name}\t{kind}\tafter: {','.join(sorted(s.deps)) or '-'}")
        return 0

    own_dir = args.run_dir is None
    run_dir = Path(args.run_dir) if args.run_dir else Path(tempfile.mkdtemp(prefix="stage-runner."))
    run_dir.mkdir(parents=True, exist_ok=True)
    runner = Runner(manifest, stages, conc, budget, args.cwd, run_dir, label=label)
    interrupted = {"sig": None}

    def on_signal(signum, _frame):
        interrupted["sig"] = signum
        for s in stages:
            if s.proc and s.proc.poll() is None:
                runner.kill_group(s, signal.SIGTERM)
        raise SystemExit(128 + signum)

    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)
    try:
        rc = runner.run()
    finally:
        if args.timings:
            try:
                Path(args.timings).write_text(json.dumps(runner.results(), indent=1) + "\n")
            except OSError as e:
                print(f"stage runner: could not write timings to {args.timings}: {e}", file=sys.stderr)
        if own_dir:
            import shutil
            shutil.rmtree(run_dir, ignore_errors=True)
    return rc


if __name__ == "__main__":
    sys.exit(main())
