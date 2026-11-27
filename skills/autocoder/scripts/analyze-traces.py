#!/usr/bin/env python3
"""analyze-traces.py: recurring failure classes in a corpus of traces, against BEHAVIOR.md (#395, #422).

WHY THIS EXISTS:
  trace-build.py writes one trace per issue attempt. One trace is an anecdote; a failure that
  repeats across many is a harness fault worth an evaluation. This runs a registry of
  classifiers over the corpus, each citing the BEHAVIOR.md rules it detects and the harness
  surface it points at, and prints the findings in priority order: severity (count times the
  classifier's weight), then count. tests/test_behavior_spec.py imports `classifiers()` to keep
  the registry and the spec in step, so this module must import without side effects.

TICKS: a trace of `kind: "tick"` is one run of an operational loop (#422). Attempt classifiers never
  see one. A tick classifier sees one loop at a time, all of one repository's ticks of one loop id
  in start order, because its signal (a streak, a median, a cadence) exists only across runs; it
  returns evidence by trace id and its findings are keyed by loop id. "The corpus's end" is the
  latest tick start in it. A tick finding's share is of the ticks, an attempt finding's of the
  attempts. The judge reads attempts only.

JUDGE (off by default): --judge CMD runs CMD once per trace no classifier matched (every trace
  with --judge-all), with the judge prompt, then BEHAVIOR.md, then the trace's JSON on stdin. CMD
  prints a JSON array of {"rule", "evidence", "confidence"}. A non-zero exit, non-JSON, a
  non-array or an element without a string `rule` is a judge error: counted, never a finding.
  Judged findings sort after deterministic ones of equal severity and name the prompt file.

USAGE
  analyze-traces.py [--traces PATH] [--json] [--since DATE] [--until DATE] [--tool-error-share F]
                    [--judge CMD [--judge-all] [--spec PATH] [--judge-prompt PATH]]
  --since/--until keep attempts and ticks that started and plan drops that occurred in [since, until).
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import statistics
import sys
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path
from types import MappingProxyType
from typing import Callable, Mapping, NamedTuple

PLUGIN_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_TOOL_ERROR_SHARE = 0.25
MIN_TOOL_CALLS = 10
EXAMPLES = 3
JUDGE_TIMEOUT_S = 600
BOUNCE_S = 120
UNREAD_PLAN_STREAK = 3
TICK_STREAK = 3
TICK_MIN = 10
TICK_SLOW_FACTOR = 5
TICK_GAP_FACTOR = 5
TICK_NOOP_WINDOW = timedelta(hours=24)
TICK_FAILED = ("error", "timeout")

FIX_MD = "commands/fix.md § "
LANDING = FIX_MD + "Landing the Work"
RELEASE = FIX_MD + "CRITICAL: Release the 'working' Label Only on a Terminal Outcome"
REVIEW = FIX_MD + "Pre-Landing Review Gate"
LOOP = FIX_MD + "MANDATORY: Continuous Loop"


def ungrouped(evidence: dict) -> tuple:
    return (None,)


class Classifier(NamedTuple):
    id: str
    rules: tuple[str, ...]
    surface: str
    match: Callable[[dict], dict | None]
    group: Callable[[dict], tuple] = ungrouped
    weight: float = 1.0
    key_rules: Mapping[str, tuple[str, ...]] = MappingProxyType({})  # group key -> the rules its finding cites
    kind: str = "attempt"  # "tick": match takes a Loop and returns {trace id: evidence}
    group_evidence: Callable[[dict, str], dict] | None = None


class Loop(NamedTuple):
    """One repository's ticks of one loop id, in start order, and the corpus's end."""
    id: str
    starts: list[datetime]
    ticks: list[dict]
    end: datetime


def loops_of(ticks: list[dict]) -> list[Loop]:
    timed: dict[tuple, list[tuple]] = defaultdict(list)
    for t in ticks:
        started = parse_ts(t.get("started"))
        if started is not None:
            timed[(t.get("repo") or "", t.get("loop") or "")].append((started, t["trace_id"], t))
    if not timed:
        return []
    end = max(started for rows in timed.values() for started, _, _ in rows)
    loops = []
    for (_, loop_id), rows in sorted(timed.items()):
        rows.sort(key=lambda r: r[:2])
        loops.append(Loop(loop_id, [r[0] for r in rows], [r[2] for r in rows], end))
    return loops


def steps_of_kind(trace: dict, kind: str) -> list[dict]:
    return [s for s in trace.get("steps") or [] if s.get("kind") == kind]


def conflict_gates(trace: dict) -> list[dict]:
    return [g for g in trace.get("gates") or [] if g.get("outcome") == "conflict"]


def gate_red_suite(trace: dict) -> dict | None:
    failed = sorted({t for g in trace.get("gates") or [] for t in g.get("tests_failed") or []})
    return {"tests_failed": failed} if failed else None


def returned_by_cause(trace: dict) -> dict | None:
    causes = sorted({r.get("cause") or "other" for r in trace.get("returned") or []})
    return {"causes": causes, "returns": len(trace["returned"])} if causes else None


def conflict_escalated_early(trace: dict) -> dict | None:
    conflicts = conflict_gates(trace)
    if len(conflicts) != 1:
        return None
    gate = conflicts[0]
    if gate.get("escalated") is True or steps_of_kind(trace, "escalated"):
        return {"conflict_files": gate.get("conflict_files"), "reason": gate.get("reason")}
    return None


def conflict_retried_late(trace: dict) -> dict | None:
    n = len(conflict_gates(trace))
    return {"conflict_gates": n} if n >= 3 else None


def reclaimed(trace: dict) -> dict | None:
    if trace.get("next_attempt") and trace.get("outcome") not in ("landed", "escalated"):
        return {"outcome": trace["outcome"], "next_attempt": trace["next_attempt"]}
    return None


def claim_bounced(trace: dict) -> dict | None:
    """A claim dropped within BOUNCE_S of being taken, before any READY or gate (#402)."""
    released = steps_of_kind(trace, "released")
    if not released or trace.get("gates") or steps_of_kind(trace, "ready"):
        return None
    started, end = parse_ts(trace.get("started")), parse_ts(released[0].get("ts"))
    if started is None or end is None:
        return None
    seconds = (end - started).total_seconds()
    return {"seconds": int(seconds), "worker": trace.get("worker")} if 0 <= seconds <= BOUNCE_S else None


def landed_unreviewed(trace: dict) -> dict | None:
    """Silent when the review was not read (review null) or turned off (status skipped)."""
    review = trace.get("review")
    if trace.get("outcome") != "landed" or not review:
        return None
    if review["status"] == "no record" or (review["status"] == "reviewed" and review.get("verdict") != "pass"):
        return {"review": review["status"], "verdict": review.get("verdict")}
    return None


def review_left_important(trace: dict) -> dict | None:
    review = trace.get("review") or {}
    left = (review.get("resolutions") or {}).get("left", 0)
    important = (review.get("findings") or {}).get("important", 0)
    return {"left": left, "important": important} if left and important else None


def verdict_nudged(trace: dict) -> dict | None:
    n = len(steps_of_kind(trace, "verdict-nudged"))
    return {"nudges": n} if n else None


def red_base(trace: dict) -> dict | None:
    gates = [g.get("attempt") for g in trace.get("gates") or [] if g.get("red_base") is True]
    return {"gates": gates} if gates else None


def session_without_gate(trace: dict) -> dict | None:
    session = trace.get("session")
    if not session or session.get("is_error") is None or trace.get("gates"):
        return None
    if steps_of_kind(trace, "escalated") or steps_of_kind(trace, "released"):
        return None
    return {"is_error": session["is_error"], "num_turns": session.get("num_turns")}


def tool_errors(share: float) -> Callable[[dict], dict | None]:
    def match(trace: dict) -> dict | None:
        tools = (trace.get("session") or {}).get("tools") or {}
        calls, errors = tools.get("calls", 0), tools.get("errors", 0)
        if calls < MIN_TOOL_CALLS or errors / calls <= share:
            return None
        tool, counts = min(tools["by_name"].items(), key=lambda kv: (-kv[1]["errors"], kv[0]))
        return {"tool": tool, "error_share": round(errors / calls, 3), "calls": calls, "errors": errors,
                "tool_errors": counts["errors"]}
    return match


def plan_dropped(trace: dict) -> dict | None:
    """Use the longest (latest on ties) run in this attempt for each drop state."""
    by_state = {}
    for record in trace.get("plan") or []:
        state, streak = record["state"], record["streak"]
        if state not in by_state or streak >= by_state[state]["streak"]:
            by_state[state] = record
    return by_state or None


def plan_evidence(by_state: dict, state: str) -> dict:
    record = by_state[state]
    if state == "unread" and record["streak"] >= UNREAD_PLAN_STREAK:
        return {**record, "priority": "high"}
    return record


def tick_duration(trace: dict) -> float | None:
    return (trace.get("tick") or {}).get("duration_s")


def tick_error_streak(loop: Loop) -> dict[str, dict]:
    """Every tick in a run of TICK_STREAK or more consecutive error or timeout outcomes."""
    out, run = {}, []
    for t in loop.ticks + [None]:
        if t is not None and t.get("outcome") in TICK_FAILED:
            run.append(t)
            continue
        if len(run) >= TICK_STREAK:
            out.update({r["trace_id"]: {"loop": loop.id, "streak": len(run), "since": run[0]["started"],
                                        "outcome": r["outcome"], "error": (r.get("tick") or {}).get("error")}
                        for r in run})
        run = []
    return out


def tick_slow(loop: Loop) -> dict[str, dict]:
    """A tick that took more than TICK_SLOW_FACTOR times its loop's median, over TICK_MIN timed ticks."""
    timed = [(t, d) for t in loop.ticks if (d := tick_duration(t)) is not None]
    if len(timed) < TICK_MIN:
        return {}
    median = statistics.median(d for _, d in timed)
    if median <= 0:
        return {}
    return {t["trace_id"]: {"loop": loop.id, "duration_s": d, "median_s": median}
            for t, d in timed if d > TICK_SLOW_FACTOR * median}


def tick_noop_only(loop: Loop) -> dict[str, dict]:
    """The latest tick of a loop whose TICK_MIN or more ticks in the corpus's last day were all noops:
    one idle loop is one finding however often it ticks."""
    recent = [t for started, t in zip(loop.starts, loop.ticks) if started >= loop.end - TICK_NOOP_WINDOW]
    if len(recent) < TICK_MIN or any(t.get("outcome") != "noop" for t in recent):
        return {}
    return {recent[-1]["trace_id"]: {"loop": loop.id, "noop_ticks": len(recent), "since": recent[0]["started"]}}


def tick_missing(loop: Loop) -> dict[str, dict]:
    """The tick before a silence longer than TICK_GAP_FACTOR times its loop's median gap, over TICK_MIN
    ticks. The silence after the last tick runs to the corpus's end; `resumed` is then null."""
    if len(loop.starts) < TICK_MIN:
        return {}
    median = statistics.median((b - a).total_seconds() for a, b in zip(loop.starts, loop.starts[1:]))
    if median <= 0:
        return {}
    out = {}
    for i, t in enumerate(loop.ticks):
        resumed = loop.ticks[i + 1]["started"] if i + 1 < len(loop.ticks) else None
        gap = ((loop.starts[i + 1] if resumed else loop.end) - loop.starts[i]).total_seconds()
        if gap > TICK_GAP_FACTOR * median:
            out[t["trace_id"]] = {"loop": loop.id, "gap_s": int(gap), "median_gap_s": int(median), "resumed": resumed}
    return out


def by_loop(evidence: dict) -> tuple:
    return (evidence["loop"],)


def classifiers(tool_error_share: float = DEFAULT_TOOL_ERROR_SHARE) -> tuple[Classifier, ...]:
    return (
        Classifier("gate-red-suite", ("B01",), "gate", gate_red_suite, lambda ev: tuple(ev["tests_failed"])),
        Classifier("returned-by-cause", ("B01", "B02", "B08", "B09"), LANDING, returned_by_cause,
                   lambda ev: tuple(ev["causes"]),
                   key_rules={"defect": ("B01",), "conflict": ("B02",), "stale-base": ("B08",),
                              "red-integration": ("B09",)}),
        Classifier("conflict-escalated-early", ("B02",), LANDING, conflict_escalated_early),
        Classifier("conflict-retried-late", ("B03",), LANDING, conflict_retried_late),
        Classifier("reclaimed", ("B04",), RELEASE, reclaimed),
        Classifier("claim-bounced", ("B13",), "scripts/claim-issue.sh", claim_bounced),
        Classifier("landed-unreviewed", ("B05",), REVIEW, landed_unreviewed),
        Classifier("review-left-important", ("B06",), REVIEW, review_left_important),
        Classifier("verdict-nudged", ("B07",), LOOP, verdict_nudged),
        Classifier("red-base", ("B09",), "integration branch", red_base),
        Classifier("tool-errors", ("B10",), "tool", tool_errors(tool_error_share), lambda ev: (ev["tool"],)),
        Classifier("session-without-gate", ("B11",), RELEASE, session_without_gate),
        Classifier("plan-dropped", ("B18",), "train_lib.py:plan_queue", plan_dropped, tuple,
                   group_evidence=plan_evidence),
        Classifier("tick-error-streak", ("B14",), "loop", tick_error_streak, by_loop, kind="tick"),
        Classifier("tick-slow", ("B15",), "loop", tick_slow, by_loop, kind="tick"),
        Classifier("tick-noop-only", ("B16",), "loop", tick_noop_only, by_loop, kind="tick"),
        Classifier("tick-missing", ("B17",), "loop", tick_missing, by_loop, kind="tick"),
    )


def classify(traces: list[dict], registry: tuple[Classifier, ...]) -> tuple[dict, set]:
    """(hits by (classifier id, key), ids of the traces some classifier matched). Attempt classifiers
    see attempts one at a time; tick classifiers see ticks one loop at a time."""
    hits: dict[tuple, dict] = {}
    matched: set[str] = set()
    attempts = [t for t in traces if t.get("kind") != "tick"]
    loops = loops_of([t for t in traces if t.get("kind") == "tick"])
    for c in registry:
        if c.kind == "tick":
            found = [pair for loop in loops for pair in c.match(loop).items()]
        else:
            found = [(t["trace_id"], c.match(t)) for t in attempts
                     if not t.get("plan_only") or c.match is plan_dropped]
        for trace_id, evidence in found:
            if evidence is None:
                continue
            matched.add(trace_id)
            for key in c.group(evidence):
                hit = hits.setdefault((c.id, key), {"classifier": c, "traces": [], "evidence": []})
                hit["traces"].append(trace_id)
                example = c.group_evidence(evidence, key) if c.group_evidence else evidence
                if example.get("priority") == "high" and not hit.get("priority"):
                    hit["priority"] = "high"
                    hit["evidence"].insert(0, {"trace_id": trace_id, **example})
                    del hit["evidence"][EXAMPLES:]
                elif len(hit["evidence"]) < EXAMPLES:
                    hit["evidence"].append({"trace_id": trace_id, **example})
    return hits, matched


def parse_judgement(stdout: str) -> list[dict] | None:
    """The judge's findings, or None when its output breaks the contract."""
    try:
        items = json.loads(stdout)
    except ValueError:
        return None
    if not isinstance(items, list) or not all(isinstance(i, dict) and isinstance(i.get("rule"), str) for i in items):
        return None
    return items


def run_judge(traces: list[dict], cmd: str, preamble: str) -> tuple[list[dict], int]:
    judged, errors = [], 0
    for trace in traces:
        try:
            r = subprocess.run(cmd, shell=True, input=preamble + json.dumps(trace, indent=2) + "\n",
                               capture_output=True, text=True, timeout=JUDGE_TIMEOUT_S)
        except subprocess.TimeoutExpired:
            errors += 1
            continue
        items = parse_judgement(r.stdout) if r.returncode == 0 else None
        if items is None:
            errors += 1
            continue
        judged += [{"trace_id": trace["trace_id"], "rule": i["rule"], "evidence": i.get("evidence"),
                    "confidence": i.get("confidence")} for i in items]
    return judged, errors


def group_findings(hits: dict, judged: list[dict], sizes: dict[str, int], judge_prompt: str | None) -> list[dict]:
    """Findings in priority order: severity, count, deterministic before judged, then id and key.
    `sizes` counts the corpus's traces by kind; a share is of the finding's kind."""
    findings = []
    for (cid, key), hit in hits.items():
        c, count = hit["classifier"], len(hit["traces"])
        findings.append({"id": cid, "key": key, "kind": c.kind,
                         "rules": list(c.key_rules.get(key, ()) if c.key_rules else c.rules),
                         "surface": c.surface, "count": count, "traces": hit["traces"],
                         "share": round(count / sizes.get(cid, sizes[c.kind]), 3), "evidence": hit["evidence"],
                         "severity": count * c.weight, "judged": False,
                         **({"priority": hit["priority"]} if "priority" in hit else {})})
    by_rule: dict[str, list[dict]] = defaultdict(list)
    for item in judged:
        by_rule[item["rule"]].append(item)
    for rule, items in by_rule.items():
        ids = list(dict.fromkeys(i["trace_id"] for i in items))
        findings.append({"id": "judged", "key": rule, "kind": "attempt", "rules": [rule], "surface": None,
                         "count": len(ids), "traces": ids, "share": round(len(ids) / sizes["attempt"], 3),
                         "evidence": items[:EXAMPLES], "severity": float(len(ids)), "judged": True,
                         "judge_prompt": judge_prompt})
    findings.sort(key=lambda f: (f.get("priority") != "high", -f["severity"], -f["count"], f["judged"], f["id"], f["key"] or ""))
    return findings


def window_text(window: dict) -> str:
    if not window["since"] and not window["until"]:
        return "all"
    return f"{window['since'] or 'the start'} to {window['until'] or 'now'}"


def markdown(report: dict) -> str:
    lines = ["# Trace findings", ""]
    for f in report["findings"]:
        lines += [f"## {f['id']}" + (f": {f['key']}" if f["key"] is not None else ""), "",
                  f"- Rules: {', '.join(f['rules']) or 'none'}",
                  f"- Surface: {f['surface'] or 'none (judged)'}",
                  f"- Count: {f['count']} ({f['share']:.0%} of the {f['kind']}s)"]
        if f.get("priority"):
            lines.append(f'- Priority: {f["priority"]}')
        if f["judged"]:
            lines.append(f"- Judge prompt: {f['judge_prompt']}")
        lines += [f"- `{e['trace_id']}`: {json.dumps({k: v for k, v in e.items() if k != 'trace_id'})}"
                  for e in f["evidence"]]
        lines.append("")
    if not report["findings"]:
        lines += ["No findings." if report["corpus"] else "No traces in the corpus.", ""]
    lines += ["## Corpus", "",
              f"- Traces: {report['corpus']}",
              *([f"- Ticks among them: {report['ticks']}"] if report["ticks"] else []),
              f"- Window: {window_text(report['window'])}",
              f"- Matched by no classifier: {report['unmatched']}"]
    if report["judge"] is not None:
        j = report["judge"]
        lines.append(f"- Judge errors: {j['errors']} of {j['traces']} traces judged ({j['prompt']})")
    return "\n".join(lines)


def parse_bound(value: str) -> datetime:
    t = parse_ts(value)
    if t is None:
        raise argparse.ArgumentTypeError(f"not a date (YYYY-MM-DD or ISO-8601): {value}")
    return t


def parse_ts(value) -> datetime | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        t = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return t if t.tzinfo else t.replace(tzinfo=timezone.utc)


def read_traces(path: Path) -> list[dict]:
    try:
        lines = path.read_text(errors="replace").splitlines()
    except OSError:
        return []
    traces = []
    for line in lines:
        try:
            traces.append(json.loads(line))
        except ValueError:
            continue
    return traces


def default_traces_path() -> Path:
    if os.environ.get("AUTOCODER_TRACES"):
        return Path(os.environ["AUTOCODER_TRACES"])
    state = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
    return Path(state) / "autocoder" / "traces.jsonl"


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Name the failures that repeat across a corpus of traces.")
    p.add_argument("--traces", type=Path, default=default_traces_path())
    p.add_argument("--json", action="store_true")
    p.add_argument("--since", type=parse_bound, help="keep traces started at or after (YYYY-MM-DD or ISO)")
    p.add_argument("--until", type=parse_bound, help="keep traces started before (YYYY-MM-DD or ISO)")
    p.add_argument("--tool-error-share", type=float, default=DEFAULT_TOOL_ERROR_SHARE)
    p.add_argument("--judge", metavar="CMD", help="judge command; reads the prompt on stdin, prints a JSON array")
    p.add_argument("--judge-all", action="store_true", help="judge every trace, not only unmatched ones")
    p.add_argument("--spec", type=Path, default=PLUGIN_ROOT / "BEHAVIOR.md")
    p.add_argument("--judge-prompt", type=Path, default=PLUGIN_ROOT / "prompts" / "trace-judge.v1.md")
    args = p.parse_args(argv)

    def in_window(value) -> bool:
        stamp = parse_ts(value)
        if stamp is None:
            return not (args.since or args.until)
        return (args.since is None or stamp >= args.since) and (args.until is None or stamp < args.until)

    traces = []
    for trace in read_traces(args.traces):
        plan = [record for record in trace.get("plan") or [] if in_window(record.get("ts"))]
        if not trace.get("plan_only") and in_window(trace.get("started")):
            traces.append({**trace, "plan": plan} if "plan" in trace else trace)
        elif plan:
            traces.append({**trace, "plan": plan, "plan_only": True})
    hits, matched = classify(traces, classifiers(args.tool_error_share))
    ticks = sum(t.get("kind") == "tick" for t in traces)
    plan_only = sum(bool(t.get("plan_only")) for t in traces)

    judged, judge = [], None
    if args.judge:
        try:
            preamble = args.judge_prompt.read_text() + "\n\n" + args.spec.read_text() + "\n\n"
        except OSError as e:
            p.error(f"--judge needs the judge prompt and the spec (--judge-prompt, --spec): {e}")
        to_judge = [t for t in traces if t.get("kind") != "tick" and not t.get("plan_only")
                    and (args.judge_all or t["trace_id"] not in matched)]
        judged, errors = run_judge(to_judge, args.judge, preamble)
        judge = {"prompt": args.judge_prompt.name, "traces": len(to_judge), "errors": errors}

    report = {
        "corpus": len(traces),
        "ticks": ticks,
        "window": {"since": args.since.isoformat() if args.since else None,
                   "until": args.until.isoformat() if args.until else None},
        "unmatched": len(traces) - len(matched),
        "judge": judge,
        "findings": group_findings(hits, judged, {"attempt": len(traces) - ticks - plan_only, "plan-dropped": len(traces) - ticks, "tick": ticks},
                                   judge and judge["prompt"]),
    }
    print(json.dumps(report, indent=2) if args.json else markdown(report))
    return 0


if __name__ == "__main__":
    sys.exit(main())
