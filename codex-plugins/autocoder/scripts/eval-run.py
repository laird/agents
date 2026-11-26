#!/usr/bin/env python3
"""eval-run.py: run evaluation cases against a worker in throwaway sandboxes and grade the traces (#395).

WHY THIS EXISTS:
  A harness change is kept only when the cases written against it, and the held-out ones, pass
  more often after it than before. That needs every run to start from the same state and to be
  graded on what the worker did, never on what it said. Each run gets a fresh sandbox (a bare
  origin, a clone with the case's seed, the issue in the file backend), the worker runs in it
  with its own state dir, trace-build.py compiles the attempt from the ledgers the worker wrote,
  and `verify` checks that trace against the case's declarative verifier, reusing the analyst's
  classifiers. One result row per run goes to the results ledger, keyed by the harness commit.

SANDBOX (one per case and repeat, under the temp dir): origin.git (bare), repo/ (a clone with
  seed/ copied in, plus .autocoder.json and a CLAUDE.md naming merge mode and integration branch
  unless the seed brought them; one commit pushed to origin), then the case's setup.sh run in
  repo/ with ORIGIN set. `.issues/` is excluded from git in the clone. The worker command gets
  {issue}, {repo} and {root} substituted and runs in repo/ with XDG_STATE_HOME=<root>/state,
  AUTOCODER_LOG_DIR=<root>/logs and no other inherited AUTOCODER_* variable, its stdout written
  to logs/worker-<pid>-fix-<issue>-<HHMMSS>.jsonl as claude-worker-loop.sh names transcripts.
  The root is deleted after a passing run unless --keep.

BACKENDS: case.json's `backend` is `file` (the default) or `fake-github`. The file backend's
  claim is an atomic rename and it folds comments into the body, so the GitHub claim race and the
  review record never run there. Under fake-github the issue lives in <root>/gh-store, served by
  fake-gh.py through a `gh` shim in <root>/bin put first on the worker's PATH (calls logged to
  <root>/gh.log). The case's `issue.comments` are seeded with createdAt `age_s` seconds in the
  past, and trace-build.py reads the review record from the store. Either way .autocoder.json's
  issueSource names the backend, the seed's own file included.

RESULTS: one JSON line per run appended to --results (default ${AUTOCODER_EVAL_RESULTS:-
  ${XDG_STATE_HOME:-$HOME/.local/state}/autocoder/eval-results.jsonl}). harness.sha is
  AUTOCODER_HARNESS_SHA, else this script directory's git HEAD, else null. With --comparison the
  row also carries that id plus the case-manifest fingerprint, the grader fingerprint (the --spec
  file) and the settings both sides of the comparison must share (#434). Exit 0 whatever the
  verdicts; 2 for a malformed or unknown case, before any worker runs.

USAGE
  eval-run.py [--cases DIR] [--split dev|heldout|all] [--case ID ...] [--worker CMD] [--repeat N]
              [--timeout S] [--comparison ID] [--results PATH] [--keep] [--json] [--spec PATH]
  --split defaults to dev, or to all when --case names the cases.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("eval_author", SCRIPTS / "eval-author.py")
AUTHOR = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(AUTHOR)
_spec = importlib.util.spec_from_file_location("fake_gh", SCRIPTS / "fake-gh.py")
FAKE_GH = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(FAKE_GH)

DEFAULT_WORKER = 'claude -p --output-format stream-json --verbose "/autocoder:fix {issue}"'
DEFAULT_TIMEOUT_S = 3600
KILL_GRACE_S = 10
GIT_ENV = {"GIT_AUTHOR_NAME": "eval", "GIT_AUTHOR_EMAIL": "eval@example.invalid",
           "GIT_COMMITTER_NAME": "eval", "GIT_COMMITTER_EMAIL": "eval@example.invalid",
           "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "commit.gpgsign", "GIT_CONFIG_VALUE_0": "false"}
SANDBOX_CONFIG = {"issueSource": "file", "mergeMode": "merge", "integrationBranch": "master"}
ISSUE_SOURCE = {"file": "file", "fake-github": "github"}
SANDBOX_CLAUDE_MD = """# Sandbox project

### Merge Mode
```
merge
```

### Integration Branch
```
master
```
"""


# ── The verifier ─────────────────────────────────────────────────────────────
def verify(trace: dict | None, spec: dict) -> list[str]:
    """The names of the checks `trace` fails under the case's `verify` spec; [] is a pass.
    A classifier or step check is named `<check>:<id>`. No trace at all fails `trace`."""
    if trace is None:
        return ["trace"]
    failed = []
    if spec.get("outcome") is not None and trace.get("outcome") != spec["outcome"]:
        failed.append("outcome")
    registry = {c.id: c for c in AUTHOR.ANALYST.classifiers()}
    failed += [f"classifiers_silent:{cid}" for cid in spec.get("classifiers_silent") or []
               if registry[cid].match(trace) is not None]
    if spec.get("max_gates") is not None and len(trace.get("gates") or []) > spec["max_gates"]:
        failed.append("max_gates")
    calls = tool_calls(trace)
    if spec.get("max_tool_calls") is not None and (calls is None or calls > spec["max_tool_calls"]):
        failed.append("max_tool_calls")
    kinds = {s.get("kind") for s in trace.get("steps") or []}
    failed += [f"steps_present:{k}" for k in spec.get("steps_present") or [] if k not in kinds]
    failed += [f"steps_absent:{k}" for k in spec.get("steps_absent") or [] if k in kinds]
    return failed


def tool_calls(trace: dict) -> int | None:
    return (((trace.get("session") or {}).get("tools")) or {}).get("calls")


# ── One run ──────────────────────────────────────────────────────────────────
def git(cwd: Path, *args: str) -> None:
    subprocess.run(["git", *args], cwd=cwd, env={**os.environ, **GIT_ENV}, check=True, capture_output=True, text=True)


def build_sandbox(case_dir: Path, root: Path, backend: str) -> Path:
    origin, repo = root / "origin.git", root / "repo"
    git(root, "init", "-q", "--bare", "-b", "master", str(origin))
    git(root, "clone", "-q", str(origin), str(repo))
    git(repo, "symbolic-ref", "HEAD", "refs/heads/master")
    if (case_dir / "seed").is_dir():
        shutil.copytree(case_dir / "seed", repo, dirs_exist_ok=True)
    config_path = repo / ".autocoder.json"
    config = json.loads(config_path.read_text()) if config_path.exists() else dict(SANDBOX_CONFIG)
    config["issueSource"] = ISSUE_SOURCE[backend]
    config_path.write_text(json.dumps(config, indent=2) + "\n")
    if not (repo / "CLAUDE.md").exists():
        (repo / "CLAUDE.md").write_text(SANDBOX_CLAUDE_MD)
    git(repo, "add", "-A")
    git(repo, "commit", "-q", "-m", "Seed the sandbox")
    git(repo, "push", "-q", "-u", "origin", "master")
    if backend == "fake-github":
        (root / "bin").mkdir()
        shim = root / "bin" / "gh"
        shim.write_text(f"#!/bin/sh\nFAKE_GH_STORE={shlex.quote(str(root / 'gh-store'))} "
                        f"FAKE_GH_LOG={shlex.quote(str(root / 'gh.log'))} "
                        f"exec {shlex.quote(sys.executable)} {shlex.quote(str(SCRIPTS / 'fake-gh.py'))} \"$@\"\n")
        shim.chmod(0o755)
    with open(repo / ".git" / "info" / "exclude", "a") as fh:
        fh.write(".issues/\n")
    if (case_dir / "setup.sh").is_file():
        subprocess.run(["bash", str(case_dir / "setup.sh")], cwd=repo, check=True, capture_output=True,
                       env={**os.environ, **GIT_ENV, "ORIGIN": str(origin)})
    return repo


def create_issue(case: dict, task: str, root: Path, repo: Path) -> int:
    issue = case["issue"]
    if case.get("backend") == "fake-github":
        store = str(root / "gh-store")
        n = FAKE_GH.create_issue(store, issue["title"], task, issue.get("labels", []),
                                 state=issue.get("state", "open").upper())["number"]
        for c in issue.get("comments", []):
            FAKE_GH.add_comment(store, n, c["body"], age_s=c["age_s"])
        return n
    labels = [a for label in issue.get("labels", []) for a in ("--label", label)]
    r = subprocess.run([sys.executable, str(SCRIPTS / "issues-file.py"), "create", "--title", issue["title"],
                        "--body", task, *labels], cwd=repo, check=True, capture_output=True, text=True,
                       env={**os.environ, "ISSUE_DIR_PATH": str(repo / ".issues")})
    return json.loads(r.stdout)["number"]


def worker_env(root: Path, repo: Path, backend: str) -> dict:
    """The caller's environment without its autocoder state, pointed at the sandbox's."""
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(("AUTOCODER_", "FAKE_GH_")) and k not in ("ISSUE_SOURCE", "ISSUE_DIR_PATH", "ISSUE_BACKEND")}
    env.update({"XDG_STATE_HOME": str(root / "state"), "AUTOCODER_LOG_DIR": str(root / "logs"),
                "ISSUE_SOURCE": ISSUE_SOURCE[backend]})
    if backend == "fake-github":
        env["PATH"] = f"{root / 'bin'}{os.pathsep}{env.get('PATH', '')}"
    else:
        env["ISSUE_DIR_PATH"] = str(repo / ".issues")
    return env


def run_worker(template: str, issue: int, root: Path, repo: Path, env: dict, timeout: float) -> bool:
    """Run the worker to completion or `timeout`; True when it was killed for the timeout."""
    cmd = (template.replace("{issue}", str(issue)).replace("{repo}", shlex.quote(str(repo)))
           .replace("{root}", shlex.quote(str(root))))
    logs = root / "logs"
    logs.mkdir(exist_ok=True)
    stamp = datetime.now().strftime("%H%M%S")
    running = logs / f".worker-{stamp}.running"
    with open(running, "wb") as out, open(root / "worker.stderr", "wb") as err:
        p = subprocess.Popen(cmd, shell=True, cwd=repo, env=env, stdin=subprocess.DEVNULL, stdout=out,
                             stderr=err, start_new_session=True)
        running.rename(logs / f"worker-{p.pid}-fix-{issue}-{stamp}.jsonl")
        try:
            p.wait(timeout=timeout)
            return False
        except subprocess.TimeoutExpired:
            pass
        try:
            os.killpg(p.pid, signal.SIGTERM)
            p.wait(timeout=KILL_GRACE_S)
        except subprocess.TimeoutExpired:
            os.killpg(p.pid, signal.SIGKILL)
            p.wait()
        except ProcessLookupError:
            p.wait()
        return True


def graded_trace(root: Path, repo: Path, issue: int, env: dict) -> dict | None:
    """The issue's last attempt, as trace-build.py compiles it from the sandbox's ledgers and logs.
    The fake-github store holds issue_get documents, so it is the review record's comments dir."""
    out = root / "traces.jsonl"
    comments = ["--comments-dir", str(root / "gh-store")] if (root / "gh-store").is_dir() else []
    r = subprocess.run([sys.executable, str(SCRIPTS / "trace-build.py"), "--log-dir", str(root / "logs"),
                        "--out", str(out), *comments], cwd=repo, env=env, capture_output=True, text=True)
    if r.returncode != 0:
        (root / "trace-build.stderr").write_text(r.stderr)
        return None
    mine = [t for t in map(json.loads, out.read_text().splitlines()) if t.get("issue") == issue]
    return max(mine, key=lambda t: t.get("attempt") or 0) if mine else None


def run_case(split: str, case_dir: Path, repeat: int, args, sha: str | None) -> dict:
    case = json.loads((case_dir / "case.json").read_text())
    backend = case.get("backend", "file")
    root = Path(tempfile.mkdtemp(prefix=f"eval-{case['id']}-r{repeat}-"))
    began = time.monotonic()
    trace, failed = None, []
    try:
        repo = build_sandbox(case_dir, root, backend)
        issue = create_issue(case, (case_dir / "task.md").read_text(), root, repo)
    except subprocess.CalledProcessError as e:
        (root / "setup.stderr").write_text(f"{e.cmd}\n{e.stderr}")
        failed = ["setup"]
    except ValueError as e:  # the seed's .autocoder.json is not JSON
        (root / "setup.stderr").write_text(f"{e}\n")
        failed = ["setup"]
    if not failed:
        env = worker_env(root, repo, backend)
        timed_out = run_worker(args.worker, issue, root, repo, env, args.timeout)
        trace = graded_trace(root, repo, issue, env)
        failed = (["timeout"] if timed_out else []) + verify(trace, case["verify"])
    passed = not failed
    if passed and not args.keep:
        shutil.rmtree(root, ignore_errors=True)
    row = {"ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), "case": case["id"], "split": split,
           "backend": backend, "repeat": repeat, "pass": passed, "failed": failed, "outcome": (trace or {}).get("outcome"),
           "gates": len(trace["gates"]) if trace else None, "tool_calls": tool_calls(trace) if trace else None,
           "duration_s": round(time.monotonic() - began, 1), "worker": args.worker, "harness": {"sha": sha},
           "root": str(root) if root.exists() else None}
    if args.comparison:
        row["comparison"] = args.comparison
        row["manifest"] = args.manifest
        row["grader"] = args.grader
        row["settings"] = {"manifest": args.manifest, "grader": args.grader, "worker": args.worker,
                           "repeat": args.repeat, "timeout": args.timeout}
    return row


# ── Selection, summary and the CLI ───────────────────────────────────────────
def fingerprint(parts: list[bytes]) -> str:
    digest = hashlib.sha256()
    for part in parts:
        digest.update(part)
        digest.update(b"\0")
    return digest.hexdigest()[:16]


def manifest_id(selected: list[tuple[str, Path]]) -> str:
    parts = []
    for split, case_dir in sorted(selected, key=lambda item: (item[0], item[1].name)):
        parts.append(f"{split}/{case_dir.name}\n".encode() + (case_dir / "case.json").read_bytes())
    return fingerprint(parts)


def grader_id(spec: Path) -> str:
    return hashlib.sha256(spec.read_bytes()).hexdigest()[:16]


def harness_sha() -> str | None:
    if os.environ.get("AUTOCODER_HARNESS_SHA"):
        return os.environ["AUTOCODER_HARNESS_SHA"]
    r = subprocess.run(["git", "rev-parse", "HEAD"], cwd=SCRIPTS, capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 and r.stdout.strip() else None


def default_results() -> Path:
    if os.environ.get("AUTOCODER_EVAL_RESULTS"):
        return Path(os.environ["AUTOCODER_EVAL_RESULTS"])
    state = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
    return Path(state) / "autocoder" / "eval-results.jsonl"


def summarize(rows: list[dict]) -> dict:
    cases: dict[str, dict] = {}
    for row in rows:
        c = cases.setdefault(row["case"], {"case": row["case"], "split": row["split"], "passes": 0, "repeats": 0,
                                           "failed": Counter(), "kept": []})
        c["repeats"] += 1
        c["passes"] += row["pass"]
        c["failed"].update(row["failed"])
        if row["root"] and not row["pass"]:
            c["kept"].append(row["root"])
    splits: dict[str, dict] = {}
    for c in cases.values():
        s = splits.setdefault(c["split"], {"runs": 0, "passes": 0, "cases": 0, "cases_passed": 0})
        s["runs"] += c["repeats"]
        s["passes"] += c["passes"]
        s["cases"] += 1
        s["cases_passed"] += c["passes"] == c["repeats"]
    return {"cases": [{**c, "failed": dict(c["failed"])} for c in cases.values()], "splits": splits}


def table(summary: dict) -> str:
    width = max([len("CASE")] + [len(c["case"]) for c in summary["cases"]])
    lines = [f"{'CASE':<{width}}  {'SPLIT':<7}  {'PASS':>5}  FAILED"]
    for c in summary["cases"]:
        failed = ", ".join(f"{name} x{n}" for name, n in sorted(c["failed"].items()))
        passes = f"{c['passes']}/{c['repeats']}"
        lines.append(f"{c['case']:<{width}}  {c['split']:<7}  {passes:>5}  {failed}".rstrip())
    for name, s in summary["splits"].items():
        lines.append(f"split {name}: {s['passes']}/{s['runs']} runs passed, "
                     f"{s['cases_passed']}/{s['cases']} cases passed every repeat")
    lines += [f"kept for {c['case']}: {root}" for c in summary["cases"] for root in c["kept"]]
    return "\n".join(lines)


def select(cases: Path, split: str | None, wanted: list[str]) -> list[tuple[str, Path]]:
    split = split or ("all" if wanted else "dev")
    return [(s, d) for s, d in AUTHOR.case_dirs(cases, None if split == "all" else split)
            if not wanted or d.name in wanted]


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Run evaluation cases against a worker and grade the traces.")
    p.add_argument("--cases", type=Path, default=None, help="cases directory")
    p.add_argument("--split", choices=("dev", "heldout", "all"))
    p.add_argument("--case", dest="cases_wanted", action="extend", nargs="+", default=[], metavar="ID")
    p.add_argument("--worker", default=DEFAULT_WORKER, metavar="CMD", help="{issue}, {repo} and {root} are substituted")
    p.add_argument("--repeat", type=int, default=1)
    p.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT_S, help="seconds per worker run")
    p.add_argument("--comparison", default=None, help="id shared by every run of one baseline/candidate comparison")
    p.add_argument("--results", type=Path, default=None)
    p.add_argument("--keep", action="store_true", help="keep every sandbox, not only failing ones")
    p.add_argument("--json", action="store_true")
    p.add_argument("--spec", type=Path, default=AUTHOR.PLUGIN_ROOT / "BEHAVIOR.md", help="BEHAVIOR.md")
    args = p.parse_args(argv)
    cases = args.cases or AUTHOR.default_cases_dir()
    if not args.spec.is_file():
        p.error(f"cannot read the behaviour spec {args.spec}; pass --spec PATH")

    selected = select(cases, args.split, args.cases_wanted)
    missing = sorted(set(args.cases_wanted) - {d.name for _, d in selected})
    rules, known = set(AUTHOR.read_rules(args.spec)), AUTHOR.classifier_ids()
    bad = [f"no such case: {m}" for m in missing]
    bad += [f"{s}/{d.name}: {problem}" for s, d in selected for problem in AUTHOR.case_problems(d, s, rules, known)]
    if bad:
        print("\n".join(bad), file=sys.stderr)
        return 2

    if args.comparison is not None and not str(args.comparison).strip():
        p.error("--comparison must be a non-empty id")
    args.manifest = manifest_id(selected) if args.comparison else None
    args.grader = grader_id(args.spec) if args.comparison else None
    sha, results = harness_sha(), args.results or default_results()
    results.parent.mkdir(parents=True, exist_ok=True)
    rows = []
    for split, case_dir in selected:
        for n in range(1, args.repeat + 1):
            row = run_case(split, case_dir, n, args, sha)
            with open(results, "a") as fh:
                fh.write(json.dumps(row, separators=(",", ":")) + "\n")
            rows.append(row)
    summary = summarize(rows)
    if args.json:
        print(json.dumps({"rows": rows, **summary}, indent=2))
    else:
        print(table(summary) if rows else "No cases to run.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
