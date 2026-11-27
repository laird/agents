#!/usr/bin/env python3
"""eval-author.py: scaffold, list and check evaluation cases written from trace findings (#395).

WHY THIS EXISTS:
  analyze-traces.py names the failures that repeat. A finding only drives a harness change once
  it is a case a machine can run and grade: a small sandbox project, the issue a worker gets in
  it, and a verifier that reads the trace the attempt leaves. This writes the parts of a case
  that follow from the finding (the verifier, the rule text, the evidence) and leaves `TODO`
  markers for the parts only an author can write (the task and the seed); `check` refuses a
  case until they are written. eval-run.py runs the cases and imports this module's checks, so
  it must import without side effects.

CASES: <cases>/dev/<id>/ or <cases>/heldout/<id>/, each with case.json, task.md, and optionally
  seed/ and setup.sh (docs/specs/2026-11-25-failure-traces-design.md, slice 3). The split is
  the directory. Without --split a finding's cases alternate dev, heldout, dev, so each finding
  gets both. <cases> defaults to ${AUTOCODER_EVAL_CASES:-<repository root>/.autocoder/evals}.

USAGE
  eval-author.py new (--finding JSON | --findings-file PATH --index N) [--split dev|heldout]
                     [--cases DIR] [--id ID] [--spec PATH]
  eval-author.py list [--cases DIR] [--split dev|heldout]
  eval-author.py check [--cases DIR] [--spec PATH]
  --index is the finding's 0-based position in analyze-traces.py --json's `findings`.
  check exits 1 and prints one `<split>/<id>: <problem>` line per defect.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
PLUGIN_ROOT = SCRIPTS.parent
SPLITS = ("dev", "heldout")
OUTCOMES = ("landed", "returned", "escalated", "released", "abandoned", "open")
ID_RE = re.compile(r"^[a-z0-9][a-z0-9._-]*$")
RULE_ROW_RE = re.compile(r"^\|\s*(B\d+)\s*\|\s*([^|]*?)\s*\|")
DEFAULT_LABELS = ["P2", "bug"]
BACKENDS = ("file", "fake-github")

_spec = importlib.util.spec_from_file_location("analyze_traces", SCRIPTS / "analyze-traces.py")
ANALYST = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ANALYST)

# A verifier: every key, with the value that bounds nothing.
UNBOUNDED = {"outcome": None, "classifiers_silent": [], "max_gates": None, "max_tool_calls": None,
             "steps_present": [], "steps_absent": []}

# Classifier id -> the default verifier of a case written for its finding. A case passes when the
# classifier stays silent on the new trace and the attempt ends the way the rule says it should.
VERIFY_DEFAULTS = {
    "gate-red-suite": {"outcome": "landed", "classifiers_silent": ["gate-red-suite"], "max_gates": 1},
    "returned-by-cause": {"outcome": "landed", "classifiers_silent": ["returned-by-cause"], "max_gates": 1},
    "conflict-escalated-early": {"outcome": "landed", "classifiers_silent": ["conflict-escalated-early"],
                                 "max_gates": 2},
    "conflict-retried-late": {"outcome": "escalated", "classifiers_silent": ["conflict-retried-late"],
                              "max_gates": 2},
    "reclaimed": {"outcome": "landed", "classifiers_silent": ["reclaimed"], "steps_absent": ["released"]},
    "claim-bounced": {"outcome": "landed", "classifiers_silent": ["claim-bounced"], "max_gates": None},
    "landed-unreviewed": {"outcome": "landed", "classifiers_silent": ["landed-unreviewed"]},
    "review-left-important": {"outcome": "landed", "classifiers_silent": ["review-left-important"]},
    "verdict-nudged": {"outcome": "landed", "classifiers_silent": ["verdict-nudged"]},
    "red-base": {"outcome": None, "classifiers_silent": [], "max_gates": 1},
    "tool-errors": {"outcome": "landed", "classifiers_silent": ["tool-errors"]},
    "session-without-gate": {"outcome": None, "classifiers_silent": ["session-without-gate"]},
    "plan-dropped": {"outcome": None, "classifiers_silent": ["plan-dropped"]},
    # A tick classifier reads a loop's runs, not the attempt a case leaves, so a verifier cannot name it.
    "tick-error-streak": {"outcome": None, "classifiers_silent": []},
    "tick-slow": {"outcome": None, "classifiers_silent": []},
    "tick-noop-only": {"outcome": None, "classifiers_silent": []},
    "tick-missing": {"outcome": None, "classifiers_silent": []},
}
# A judged finding has no classifier: the attempt must still land.
JUDGED_VERIFY = {"outcome": "landed"}


def default_verify(classifier_id: str) -> dict:
    return {**UNBOUNDED, **VERIFY_DEFAULTS.get(classifier_id, JUDGED_VERIFY)}


def classifier_ids() -> set[str]:
    """The classifiers a verifier can name in classifiers_silent: those that read one attempt."""
    return {c.id for c in ANALYST.classifiers() if c.kind == "attempt"}


def read_rules(spec: Path) -> dict[str, str]:
    """Rule id -> rule text, from BEHAVIOR.md's table."""
    rules = {}
    for line in spec.read_text().splitlines():
        m = RULE_ROW_RE.match(line)
        if m:
            rules[m.group(1)] = m.group(2)
    return rules


def default_cases_dir() -> Path:
    if os.environ.get("AUTOCODER_EVAL_CASES"):
        return Path(os.environ["AUTOCODER_EVAL_CASES"])
    r = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True)
    top = r.stdout.strip() if r.returncode == 0 else ""
    return Path(top or ".") / ".autocoder" / "evals"


def case_dirs(cases: Path, split: str | None = None) -> list[tuple[str, Path]]:
    """(split, directory) of every case on disk, dev before heldout, each split by id."""
    return [(s, d) for s in SPLITS if split in (None, s) and (cases / s).is_dir()
            for d in sorted((cases / s).iterdir()) if d.is_dir()]


def read_case(case_dir: Path) -> dict | None:
    try:
        data = json.loads((case_dir / "case.json").read_text())
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


# ── Validation ───────────────────────────────────────────────────────────────
def str_list(value) -> bool:
    return isinstance(value, list) and all(isinstance(v, str) for v in value)


def bound(value) -> bool:
    return value is None or (isinstance(value, int) and not isinstance(value, bool) and value >= 0)


def verify_problems(verify, known: set[str]) -> list[str]:
    if not isinstance(verify, dict):
        return ["verify is not an object"]
    out = [f"verify has an unknown key {k!r}" for k in sorted(set(verify) - set(UNBOUNDED))]
    if verify.get("outcome") not in (None, *OUTCOMES):
        out.append(f"verify.outcome {verify['outcome']!r} is not one of {', '.join(OUTCOMES)}")
    for key in ("max_gates", "max_tool_calls"):
        if not bound(verify.get(key)):
            out.append(f"verify.{key} is not null or a non-negative integer")
    for key in ("classifiers_silent", "steps_present", "steps_absent"):
        if not str_list(verify.get(key, [])):
            out.append(f"verify.{key} is not a list of strings")
    if str_list(verify.get("classifiers_silent", [])):
        out += [f"unknown classifier {c!r} in verify.classifiers_silent"
                for c in verify.get("classifiers_silent", []) if c not in known]
    return out


def backend_problems(data: dict) -> list[str]:
    """`backend`, and the issue keys only fake-github seeds: `comments` ({body, age_s}) and `state`."""
    backend = data.get("backend", "file")
    if backend not in BACKENDS:
        return [f"backend {backend!r} is not one of {', '.join(BACKENDS)}"]
    issue = data.get("issue") if isinstance(data.get("issue"), dict) else {}
    staged = sorted(k for k in ("comments", "state") if k in issue)
    if backend != "fake-github":
        return [f"issue.{k} needs backend fake-github" for k in staged]
    out = []
    if issue.get("state", "open") not in ("open", "closed"):
        out.append(f"issue.state {issue['state']!r} is not open or closed")
    comments = issue.get("comments", [])
    if not isinstance(comments, list):
        return out + ["issue.comments is not a list"]
    for i, c in enumerate(comments):
        age = c.get("age_s") if isinstance(c, dict) else None
        if not isinstance(c, dict) or set(c) != {"body", "age_s"} or not isinstance(c["body"], str) \
                or isinstance(age, bool) or not isinstance(age, (int, float)) or age < 0:
            out.append(f"issue.comments[{i}] needs exactly a string body and a non-negative number age_s")
    return out


def case_problems(case_dir: Path, split: str, rules: set[str], known: set[str]) -> list[str]:
    """Every defect of one case; an empty list is a case the runner can run."""
    try:
        data = json.loads((case_dir / "case.json").read_text())
    except OSError:
        return ["no case.json"]
    except ValueError as e:
        return [f"case.json is not valid JSON ({e})"]
    if not isinstance(data, dict):
        return ["case.json is not an object"]
    out = []
    if data.get("v") != 1:
        out.append(f"case.json v is {data.get('v')!r}, not 1")
    if data.get("id") != case_dir.name:
        out.append(f"id {data.get('id')!r} does not match its directory {case_dir.name!r}")
    if data.get("split") != split:
        out.append(f"split {data.get('split')!r} does not match its directory {split!r}")
    finding = data.get("finding")
    if not isinstance(finding, dict) or not isinstance(finding.get("id"), str) or not str_list(finding.get("rules")):
        out.append("finding needs an id and a list of rules")
    else:
        out += [f"unknown rule {r!r} in finding.rules" for r in finding["rules"] if r not in rules]
    issue = data.get("issue")
    if not isinstance(issue, dict) or not isinstance(issue.get("title"), str) or not issue["title"].strip() \
            or not str_list(issue.get("labels", [])):
        out.append("issue needs a title and a list of labels")
    elif "TODO" in issue["title"]:
        out.append("issue.title still has a TODO")
    out += backend_problems(data)
    out += verify_problems(data.get("verify"), known)
    try:
        task = (case_dir / "task.md").read_text()
    except OSError:
        out.append("no task.md")
    else:
        if "TODO" in task:
            out.append("task.md still has a TODO")
        elif not task.strip():
            out.append("task.md is empty")
    if (case_dir / "seed").exists() and not (case_dir / "seed").is_dir():
        out.append("seed is not a directory")
    if (case_dir / "setup.sh").exists() and not (case_dir / "setup.sh").is_file():
        out.append("setup.sh is not a file")
    return out


# ── Scaffolding ──────────────────────────────────────────────────────────────
def slug(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")


def same_finding(case_dir: Path, finding: dict) -> bool:
    f = (read_case(case_dir) or {}).get("finding") or {}
    return f.get("id") == finding.get("id") and f.get("key") == finding.get("key")


def next_id(cases: Path, finding: dict) -> str:
    base = slug(finding["id"]) + (f"-{slug(str(finding['key']))}" if finding.get("key") is not None else "")
    taken = [int(m.group(1)) for _, d in case_dirs(cases) if (m := re.fullmatch(re.escape(base) + r"-(\d+)", d.name))]
    return f"{base}-{max(taken, default=0) + 1:03d}"


def task_text(case_id: str, split: str, finding: dict, rules: dict[str, str], verify: dict) -> str:
    key = f" (key: {finding['key']})" if finding.get("key") is not None else ""
    lines = [
        "TODO: write the issue body the worker gets: a small, real task in the seed project whose natural",
        "path runs into the failure below. Describe the work, not the failure, and never name the rule.",
        "",
        "TODO: put the project the task needs in seed/ (and setup.sh when the failure needs a second",
        "actor, such as a conflicting commit pushed to $ORIGIN), then delete the author notes below.",
        "",
        "---",
        "",
        f"TODO: delete these author notes for case {case_id} ({split}) before committing.",
        "",
        f"Finding: {finding['id']}{key}, {finding.get('count', len(finding.get('traces') or []))} trace(s), "
        f"surface {finding.get('surface') or 'none'}.",
        "",
        "Rules the failure breaks:",
    ]
    lines += [f"- {r}: {rules.get(r, 'not in the spec')}" for r in finding.get("rules") or []]
    lines += ["", "Evidence from the traces:"]
    lines += [f"- `{e.get('trace_id')}`: {json.dumps({k: v for k, v in e.items() if k != 'trace_id'})}"
              for e in finding.get("evidence") or []] or ["- none recorded"]
    lines += ["", f"Verifier (case.json): {json.dumps(verify)}", ""]
    return "\n".join(lines)


def load_finding(args) -> dict:
    if args.finding:
        finding = json.loads(args.finding)
    else:
        report = json.loads(Path(args.findings_file).read_text())
        findings = report["findings"] if isinstance(report, dict) else report
        if args.index is None or not 0 <= args.index < len(findings):
            raise ValueError(f"--index must be 0..{len(findings) - 1} for {args.findings_file}")
        finding = findings[args.index]
    if not isinstance(finding, dict) or not isinstance(finding.get("id"), str):
        raise ValueError("a finding is a JSON object with an `id`")
    return finding


def cmd_new(args) -> int:
    try:
        finding = load_finding(args)
    except (OSError, ValueError, KeyError) as e:
        print(f"eval-author: {e}", file=sys.stderr)
        return 2
    case_id = args.id or next_id(args.cases, finding)
    if not ID_RE.match(case_id):
        print(f"eval-author: case id {case_id!r} must match {ID_RE.pattern}", file=sys.stderr)
        return 2
    if any(d.name == case_id for _, d in case_dirs(args.cases)):
        print(f"eval-author: case {case_id} already exists", file=sys.stderr)
        return 1
    split = args.split or SPLITS[sum(same_finding(d, finding) for _, d in case_dirs(args.cases)) % 2]
    rules = read_rules(args.spec)
    verify = default_verify(finding["id"])
    case = {"v": 1, "id": case_id, "authored": datetime.now(timezone.utc).date().isoformat(), "split": split,
            "finding": {"id": finding["id"], "key": finding.get("key"), "rules": list(finding.get("rules") or []),
                        "traces": list(finding.get("traces") or [])},
            "issue": {"title": "TODO: the issue title the worker sees", "labels": list(DEFAULT_LABELS)},
            "verify": verify}
    case_dir = args.cases / split / case_id
    (case_dir / "seed").mkdir(parents=True)
    (case_dir / "case.json").write_text(json.dumps(case, indent=2) + "\n")
    (case_dir / "task.md").write_text(task_text(case_id, split, finding, rules, verify))
    print(case_dir)
    return 0


def cmd_list(args) -> int:
    for split, d in case_dirs(args.cases, args.split):
        data = read_case(d) or {}
        f = data.get("finding") or {}
        name = f"{f.get('id', '?')}" + (f": {f['key']}" if f.get("key") is not None else "")
        outcome = (data.get("verify") or {}).get("outcome") or "any"
        print(f"{split}\t{d.name}\t{name}\t{','.join(f.get('rules') or [])}\toutcome={outcome}")
    return 0


def cmd_check(args) -> int:
    rules, known = set(read_rules(args.spec)), classifier_ids()
    found = case_dirs(args.cases)
    bad = [f"{split}/{d.name}: {p}" for split, d in found for p in case_problems(d, split, rules, known)]
    for line in bad:
        print(line)
    if bad:
        print(f"eval-author: {len({b.split(':')[0] for b in bad})} of {len(found)} case(s) need work", file=sys.stderr)
        return 1
    print(f"{len(found)} case(s) ok")
    return 0


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Scaffold, list and check evaluation cases written from trace findings.")
    sub = p.add_subparsers(dest="cmd", required=True)
    new = sub.add_parser("new", help="scaffold a case from a finding")
    source = new.add_mutually_exclusive_group(required=True)
    source.add_argument("--finding", metavar="JSON", help="one finding object, as analyze-traces.py --json writes it")
    source.add_argument("--findings-file", metavar="PATH", help="an analyze-traces.py --json report")
    new.add_argument("--index", type=int, help="0-based position in the report's findings")
    new.add_argument("--split", choices=SPLITS)
    new.add_argument("--id", help="case id (default: <finding id>[-<key>]-NNN)")
    lst = sub.add_parser("list", help="print the cases")
    lst.add_argument("--split", choices=SPLITS)
    chk = sub.add_parser("check", help="validate every case; exit 1 naming each bad one")
    for sp in (new, lst, chk):
        sp.add_argument("--cases", type=Path, default=None, help="cases directory")
    for sp in (new, chk):
        sp.add_argument("--spec", type=Path, default=PLUGIN_ROOT / "BEHAVIOR.md", help="BEHAVIOR.md")
    args = p.parse_args(argv)
    args.cases = args.cases or default_cases_dir()
    if getattr(args, "spec", None) and not args.spec.is_file():
        p.error(f"cannot read the behaviour spec {args.spec}; pass --spec PATH")
    return {"new": cmd_new, "list": cmd_list, "check": cmd_check}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
