#!/usr/bin/env python3
"""Analyze gate-log records joined with Claude Code session-jsonl usage.

Inputs:
  --gate-log PATH        Gate-log jsonl (one record per tick).
  --session-jsonl PATH   Claude Code session jsonl. May be specified once
                         (used for all gate records that don't carry a
                         session_jsonl_path) or omitted (then every
                         gate-log record MUST carry session_jsonl_path).
  --out-csv PATH         Where to write the per-tick CSV.
  --out-md  PATH         Where to write the markdown summary.

Per spec §13.1/§13.2:
  - Real Anthropic schema places usage at message.usage.{input_tokens,
    cache_read_input_tokens, cache_creation_input_tokens, output_tokens}
    and model at message.model. We parse defensively.
  - Missing fields render as 'n/a'.
  - If ALL records in the sampled session(s) are missing an expected
    field, exit 2 (schema-drift). Missing in only some records does
    not fail.
  - Unknown top-level keys inside message.usage produce a stderr warning
    matching 'unknown field' but do not fail (additive Anthropic changes).

CSV columns: ts, outcome, model, input_tokens, cache_read_tokens,
cache_creation_tokens, output_tokens, gate_duration_ms, issues_scanned.

Markdown summary: aggregates per outcome and per model.
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import sys
from collections import defaultdict
from pathlib import Path
from typing import Iterable

EXPECTED_USAGE_FIELDS = (
    "input_tokens",
    "cache_read_input_tokens",
    "cache_creation_input_tokens",
    "output_tokens",
)

# Allowed extra fields inside usage that we know about. Anything else
# triggers a stderr warning.
KNOWN_USAGE_EXTRAS = {
    "server_tool_use",
    "service_tier",
    "cache_creation",
    "inference_geo",
    "iterations",
    "speed",
    # cache subfields sometimes inlined:
    "ephemeral_5m_input_tokens",
    "ephemeral_1h_input_tokens",
}


def warn(msg: str) -> None:
    sys.stderr.write(f"analyze-gate-log: warning: {msg}\n")


def load_jsonl(path: Path) -> list[dict]:
    out: list[dict] = []
    with path.open() as f:
        for ln, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                out.append(json.loads(line))
            except json.JSONDecodeError as e:
                warn(f"{path}:{ln}: invalid JSON: {e}")
    return out


def pick_session_usage(session_records: list[dict]) -> dict:
    """Walk a session jsonl; return the FIRST assistant message-record's
    usage block + model. Spec golden contract assumes the first
    usage-bearing assistant record is what we attribute the tick to.
    Returns {} if no such record found.

    Also surfaces unknown usage subfields as stderr warnings.
    """
    for rec in session_records:
        if rec.get("type") != "assistant":
            continue
        msg = rec.get("message") or {}
        usage = msg.get("usage")
        if not isinstance(usage, dict):
            continue
        # Warn on unknown usage subfields.
        for k in usage.keys():
            if k in EXPECTED_USAGE_FIELDS:
                continue
            if k in KNOWN_USAGE_EXTRAS:
                continue
            warn(f"unknown field in usage: {k!r}")
        return {
            "model": msg.get("model"),
            "usage": usage,
        }
    return {}


def schema_check(session_records: list[dict], session_path: Path) -> dict:
    """Verify EACH expected usage field appears at least once across
    assistant records. Returns a dict {field: count_present}.
    Fields with count_present==0 mean every record is missing them.
    """
    counts = {f: 0 for f in EXPECTED_USAGE_FIELDS}
    assistant_seen = 0
    for rec in session_records:
        if rec.get("type") != "assistant":
            continue
        msg = rec.get("message") or {}
        usage = msg.get("usage")
        if not isinstance(usage, dict):
            continue
        assistant_seen += 1
        for f in EXPECTED_USAGE_FIELDS:
            if f in usage:
                counts[f] += 1
    return {"counts": counts, "assistant_seen": assistant_seen}


def na(v):
    return "n/a" if v is None else v


def per_tick_row(gate_rec: dict, joined: dict) -> dict:
    usage = (joined.get("usage") or {})
    model = joined.get("model") or gate_rec.get("model")
    return {
        "ts": gate_rec.get("ts", "n/a"),
        "outcome": gate_rec.get("outcome", "n/a"),
        "model": na(model),
        "input_tokens": na(usage.get("input_tokens")),
        "cache_read_tokens": na(usage.get("cache_read_input_tokens")),
        "cache_creation_tokens": na(usage.get("cache_creation_input_tokens")),
        "output_tokens": na(usage.get("output_tokens")),
        "gate_duration_ms": na(gate_rec.get("gate_duration_ms")),
        "issues_scanned": na(gate_rec.get("issues_scanned")),
    }


def aggregate(rows: list[dict]) -> dict:
    """Return {by_outcome: {...}, by_model: {...}}, each value a dict of
    sum/count/avg per token type."""

    def _empty():
        return {"n": 0, "input_tokens": 0, "cache_read_tokens": 0,
                "cache_creation_tokens": 0, "output_tokens": 0}

    by_outcome: dict[str, dict] = defaultdict(_empty)
    by_model: dict[str, dict] = defaultdict(_empty)

    def add(bucket, row):
        bucket["n"] += 1
        for k in ("input_tokens", "cache_read_tokens",
                  "cache_creation_tokens", "output_tokens"):
            v = row[k]
            if isinstance(v, int):
                bucket[k] += v

    for r in rows:
        add(by_outcome[r["outcome"]], r)
        add(by_model[str(r["model"])], r)
    return {"by_outcome": dict(by_outcome), "by_model": dict(by_model)}


def render_markdown(rows: list[dict], agg: dict) -> str:
    lines = ["# Gate-log analysis", "",
             f"Total ticks: {len(rows)}", ""]
    lines.append("## Per outcome")
    lines.append("")
    lines.append("| outcome | n | input | cache_read | cache_create | output |")
    lines.append("|---|---:|---:|---:|---:|---:|")
    for k, v in sorted(agg["by_outcome"].items()):
        lines.append(
            f"| {k} | {v['n']} | {v['input_tokens']} | {v['cache_read_tokens']} "
            f"| {v['cache_creation_tokens']} | {v['output_tokens']} |"
        )
    lines.append("")
    lines.append("## Per model")
    lines.append("")
    lines.append("| model | n | input | cache_read | cache_create | output |")
    lines.append("|---|---:|---:|---:|---:|---:|")
    for k, v in sorted(agg["by_model"].items()):
        lines.append(
            f"| {k} | {v['n']} | {v['input_tokens']} | {v['cache_read_tokens']} "
            f"| {v['cache_creation_tokens']} | {v['output_tokens']} |"
        )
    lines.append("")
    return "\n".join(lines)


def write_csv(path: Path, rows: list[dict]) -> None:
    fieldnames = [
        "ts", "outcome", "model", "input_tokens", "cache_read_tokens",
        "cache_creation_tokens", "output_tokens",
        "gate_duration_ms", "issues_scanned",
    ]
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        for r in rows:
            w.writerow(r)


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Analyze gate-log against session jsonl.")
    default_gate = os.environ.get(
        "XDG_STATE_HOME",
        os.path.join(os.path.expanduser("~"), ".local", "state"),
    )
    p.add_argument("--gate-log",
                   default=str(Path(default_gate) / "autocoder" / "gate.jsonl"))
    p.add_argument("--session-jsonl", default=None,
                   help="Default session jsonl (used if a gate record has no session_jsonl_path).")
    p.add_argument("--out-csv", required=True)
    p.add_argument("--out-md", required=True)
    args = p.parse_args(argv)

    gate_path = Path(args.gate_log)
    if not gate_path.exists():
        sys.stderr.write(f"gate-log not found: {gate_path}\n")
        return 1

    gate_records = load_jsonl(gate_path)

    # Cache session-jsonl parsing per path.
    session_cache: dict[str, list[dict]] = {}

    def session_for(path_str: str) -> list[dict]:
        if path_str not in session_cache:
            p2 = Path(path_str)
            if not p2.exists():
                warn(f"session jsonl not found: {p2}")
                session_cache[path_str] = []
            else:
                session_cache[path_str] = load_jsonl(p2)
        return session_cache[path_str]

    # Schema-check aggregation across ALL sessions referenced.
    sessions_referenced: set[str] = set()
    rows: list[dict] = []
    for rec in gate_records:
        path_str = rec.get("session_jsonl_path") or args.session_jsonl
        if not path_str:
            warn("gate record has no session_jsonl_path and no default --session-jsonl provided")
            joined = {}
        else:
            sessions_referenced.add(path_str)
            joined = pick_session_usage(session_for(path_str))
        rows.append(per_tick_row(rec, joined))

    # Run schema-check over each referenced session and aggregate counts.
    # We treat "field missing in EVERY assistant record across ALL sampled
    # sessions" as the schema-drift failure mode (spec §13.1 + task brief).
    total_counts = {f: 0 for f in EXPECTED_USAGE_FIELDS}
    total_assistants = 0
    for path_str in sessions_referenced:
        c = schema_check(session_for(path_str), Path(path_str))
        total_assistants += c["assistant_seen"]
        for f, n in c["counts"].items():
            total_counts[f] += n

    schema_drift = False
    if total_assistants > 0:
        for f, n in total_counts.items():
            if n == 0:
                sys.stderr.write(
                    f"analyze-gate-log: error: expected field {f!r} missing in ALL "
                    f"{total_assistants} assistant records across sampled sessions\n"
                )
                schema_drift = True

    # Write outputs regardless (so CI can inspect).
    write_csv(Path(args.out_csv), rows)
    agg = aggregate(rows)
    Path(args.out_md).parent.mkdir(parents=True, exist_ok=True)
    Path(args.out_md).write_text(render_markdown(rows, agg))

    if schema_drift:
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
