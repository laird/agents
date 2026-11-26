#!/usr/bin/env python3
"""eval-decide.py: keep or drop one harness change by its evaluation results (#395, slice 4).

WHY THIS EXISTS:
  A harness change is written against the dev cases of one finding. A change that fixes those cases
  and breaks behaviour elsewhere looks like progress when only the dev pass rate is read, so the
  held-out cases the proposer never saw decide too. Making that call by eye invites reading the
  numbers the way one hopes; this states the rule once and records every decision, so the week page
  can count what the loop kept and what it threw away.

INPUT: the result rows eval-run.py appends (--results, default ${AUTOCODER_EVAL_RESULTS:-
  ${XDG_STATE_HOME:-$HOME/.local/state}/autocoder/eval-results.jsonl}), split by `harness.sha`
  into the rows of --before and of --after (a given sha matches a row whose sha starts with it).
  --comparison keeps only rows stamped with that id, so a later run that reused the same sha
  cannot move this verdict (#434).

THE RULE, per split (dev, heldout), on pass rates:
  inconclusive  a split has no rows on either sha, or a case has fewer than --min-runs rows on
                either sha (a case run on one sha only has 0 on the other); or the two sides
                disagree on settings (case manifest, grader, worker, planned repeats); or a
                case's repeat counts do not match. Never accept on that.
  accept        the dev pass rate rose, and the held-out pass rate did not fall (and rose, when
                it was below 1); or both pass rates are unchanged and the mean tool_calls of the
                rows that carry it fell.
  reject        anything else, with the reason.

OUTPUT: `accept`, `reject <reason>` or `inconclusive <reason>` on stdout (--json prints the
  decision row instead); one row appended to --decisions (default ${AUTOCODER_EVAL_DECISIONS:-
  ${XDG_STATE_HOME:-$HOME/.local/state}/autocoder/eval-decisions.jsonl}) in one O_APPEND write.
  Exit 0 on accept, 1 on reject, 3 on inconclusive.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

SPLITS = ("dev", "heldout")
EXIT = {"accept": 0, "reject": 1, "inconclusive": 3}


def state_path(env_var: str, name: str) -> Path:
    if os.environ.get(env_var):
        return Path(os.environ[env_var])
    state = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
    return Path(state) / "autocoder" / name


def read_rows(path: Path) -> list[dict]:
    try:
        lines = path.read_text(errors="replace").splitlines()
    except OSError:
        return []
    rows, malformed = [], 0
    for line in lines:
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
    if malformed:
        print(f"eval-decide: skipped {malformed} malformed line(s) in {path}", file=sys.stderr)
    return rows


def row_sha(row: dict) -> str:
    harness = row.get("harness")
    return str(harness.get("sha") or "") if isinstance(harness, dict) else ""


def selected(row: dict, sha: str, comparison: str | None, split: str | None = None) -> bool:
    if comparison is not None and row.get("comparison") != comparison:
        return False
    if not row_sha(row).startswith(sha) or row.get("split") not in SPLITS or not row.get("case"):
        return False
    return split is None or row.get("split") == split


def tally(rows: list[dict], sha: str, comparison: str | None = None) -> tuple[dict, list[float]]:
    """({split: {case: [passes, runs]}}, the tool_calls of the rows that carry it) for one sha."""
    by_split: dict = {s: defaultdict(lambda: [0, 0]) for s in SPLITS}
    calls = []
    for row in rows:
        if not selected(row, sha, comparison):
            continue
        cell = by_split[row["split"]][str(row["case"])]
        cell[0] += row.get("pass") is True
        cell[1] += 1
        if isinstance(row.get("tool_calls"), (int, float)):
            calls.append(float(row["tool_calls"]))
    return by_split, calls


def totals(cases: dict) -> list[int]:
    return [sum(c[0] for c in cases.values()), sum(c[1] for c in cases.values())]


def mean(values: list[float]) -> float | None:
    return sum(values) / len(values) if values else None


def rate(pair: list[int]) -> float:
    return pair[0] / pair[1]


def fmt(before: list[int], after: list[int]) -> str:
    return f"{before[0]}/{before[1]} -> {after[0]}/{after[1]}"


def decide(before: dict, after: dict, mean_b: float | None, mean_a: float | None, min_runs: int) -> tuple[str, str]:
    """(decision, reason) from the per-case tallies of the two shas."""
    for split in SPLITS:
        cases = sorted(set(before[split]) | set(after[split]))
        if not cases:
            return "inconclusive", f"no {split} case was run"
        for side, tallies in (("before", before), ("after", after)):
            short = [c for c in cases if tallies[split].get(c, [0, 0])[1] < min_runs]
            if short:
                return "inconclusive", f"{split} case(s) with fewer than {min_runs} runs {side}: {', '.join(short)}"
        unmatched = [c for c in cases
                     if before[split].get(c, [0, 0])[1] != after[split].get(c, [0, 0])[1]]
        if unmatched:
            detail = ", ".join(
                f"{c} ({before[split].get(c, [0, 0])[1]} vs {after[split].get(c, [0, 0])[1]})"
                for c in unmatched)
            return "inconclusive", f"{split} case(s) with unmatched repeats: {detail}"
    dev_b, dev_a = totals(before["dev"]), totals(after["dev"])
    ho_b, ho_a = totals(before["heldout"]), totals(after["heldout"])
    if rate(dev_a) == rate(dev_b) and rate(ho_a) == rate(ho_b):
        if mean_b is None or mean_a is None:
            return "reject", f"pass rates unchanged (dev {fmt(dev_b, dev_a)}, heldout {fmt(ho_b, ho_a)}) and tool calls not recorded"
        if mean_a < mean_b:
            return "accept", f"pass rates unchanged; mean tool calls fell {mean_b:.1f} -> {mean_a:.1f}"
        return "reject", f"pass rates unchanged and mean tool calls did not fall ({mean_b:.1f} -> {mean_a:.1f})"
    if rate(dev_a) <= rate(dev_b):
        return "reject", f"dev pass rate did not rise ({fmt(dev_b, dev_a)})"
    if rate(ho_a) < rate(ho_b):
        return "reject", f"heldout pass rate fell ({fmt(ho_b, ho_a)})"
    if rate(ho_b) < 1 and rate(ho_a) == rate(ho_b):
        return "reject", f"heldout pass rate did not rise from below 1 ({fmt(ho_b, ho_a)})"
    return "accept", f"dev {fmt(dev_b, dev_a)}, heldout {fmt(ho_b, ho_a)}"


def _norm(value) -> str:
    return json.dumps(value, sort_keys=True) if isinstance(value, dict) else str(value)


def uniform(rows: list[dict], key: str):
    """(value, ok). value is None when no row carries key. ok is False when the carried values differ."""
    if not rows:
        return None, True
    seen: list = []
    for row in rows:
        value = row.get(key)
        marker = None if value is None else _norm(value)
        if marker not in seen:
            seen.append(marker)
    present = [m for m in seen if m is not None]
    if not present:
        return None, True
    if len(present) != 1 or len(seen) != 1:
        return None, False
    for row in rows:
        if row.get(key) is not None:
            return row[key], True
    return None, True


def belonging(rows: list[dict], sha: str, comparison: str | None, split: str | None = None) -> list[dict]:
    return [row for row in rows if selected(row, sha, comparison, split)]


def alignment_problem(rows: list[dict], before_sha: str, after_sha: str, comparison: str | None) -> str | None:
    """Why the two sides are not one comparison, or None when they are.

    Untagged rows (no settings) stay comparable: that is every ledger written before #434.
    A stamped comparison must agree, per split, on the settings eval-run recorded.
    """
    if comparison is None and not any(isinstance(row.get("settings"), dict) for row in rows):
        return None
    for split in SPLITS:
        for side, sha in (("before", before_sha), ("after", after_sha)):
            _value, ok = uniform(belonging(rows, sha, comparison, split), "settings")
            if not ok:
                return f"{side} {split} rows disagree on settings"
        before, _ = uniform(belonging(rows, before_sha, comparison, split), "settings")
        after, _ = uniform(belonging(rows, after_sha, comparison, split), "settings")
        if before is None and after is None:
            continue
        if before is None or after is None or _norm(before) != _norm(after):
            return f"different {split} settings between before and after"
    return None


def side_field(rows: list[dict], sha: str, comparison: str | None, key: str, split: str | None = None):
    value, ok = uniform(belonging(rows, sha, comparison, split), key)
    return value if ok else None


def repeat_counts(tallies: dict) -> dict:
    return {split: {case: pair[1] for case, pair in sorted(cases.items())} for split, cases in tallies.items()}


def append_row(path: Path, row: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
    try:
        os.write(fd, (json.dumps(row, separators=(",", ":")) + "\n").encode())
    finally:
        os.close(fd)


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Accept, reject or call inconclusive one harness change by its eval results.")
    p.add_argument("--finding", required=True, help="the finding (id[:key]) or case the change was written against")
    p.add_argument("--before", required=True, help="harness sha of the baseline")
    p.add_argument("--after", required=True, help="harness sha of the change")
    p.add_argument("--comparison", default=None, help="only rows eval-run stamped with this id")
    p.add_argument("--results", type=Path, default=state_path("AUTOCODER_EVAL_RESULTS", "eval-results.jsonl"))
    p.add_argument("--decisions", type=Path, default=state_path("AUTOCODER_EVAL_DECISIONS", "eval-decisions.jsonl"))
    p.add_argument("--min-runs", type=int, default=2, help="runs each case needs on each sha (default 2)")
    p.add_argument("--json", action="store_true", help="print the decision row instead of the verdict line")
    args = p.parse_args(argv)
    if args.min_runs < 1:
        p.error("--min-runs must be at least 1")

    rows = read_rows(args.results)
    before, calls_before = tally(rows, args.before, args.comparison)
    after, calls_after = tally(rows, args.after, args.comparison)
    calls = {"before": mean(calls_before), "after": mean(calls_after)}
    problem = alignment_problem(rows, args.before, args.after, args.comparison)
    if problem:
        decision, reason = "inconclusive", problem
    else:
        decision, reason = decide(before, after, calls["before"], calls["after"], args.min_runs)
    row = {
        "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "finding": args.finding, "comparison": args.comparison,
        "before": args.before, "after": args.after,
        **{split: {"before": totals(before[split]), "after": totals(after[split])} for split in SPLITS},
        "manifest": {side: {split: side_field(rows, sha, args.comparison, "manifest", split) for split in SPLITS}
                     for side, sha in (("before", args.before), ("after", args.after))},
        "grader": {side: side_field(rows, sha, args.comparison, "grader")
                   for side, sha in (("before", args.before), ("after", args.after))},
        "worker": {side: side_field(rows, sha, args.comparison, "worker")
                   for side, sha in (("before", args.before), ("after", args.after))},
        "settings": {side: {split: side_field(rows, sha, args.comparison, "settings", split) for split in SPLITS}
                     for side, sha in (("before", args.before), ("after", args.after))},
        "repeats": {"before": repeat_counts(before), "after": repeat_counts(after)},
        "tool_calls": calls,
        "decision": decision, "accepted": decision == "accept", "reason": reason,
    }
    append_row(args.decisions, row)
    print(json.dumps(row, indent=2) if args.json else ("accept" if decision == "accept" else f"{decision} {reason}"))
    return EXIT[decision]


if __name__ == "__main__":
    sys.exit(main())
