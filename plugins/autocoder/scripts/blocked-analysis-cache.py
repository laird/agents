#!/usr/bin/env python3
"""Per-issue cache of the agent's analysis of a blocked issue (#310, part of #308).

An analysis is prepared ahead of time (by `/review-blocked --prepare`) and read
back by the review GUI, so a human sees the options without waiting for an
agent. Each entry is keyed by the issue's `updatedAt`: when the issue changes,
the cached analysis no longer describes it and reads as stale.

    blocked-analysis-cache.py put <N> --updated-at <ts> --file analysis.json
    blocked-analysis-cache.py get <N> --updated-at <ts>
    blocked-analysis-cache.py list [--current issues.json]

`put` validates the analysis and refuses a malformed one (exit 2). `get` prints
the analysis as JSON, or exits 1 when nothing is cached or the cached
`updatedAt` differs from the one given. `list` never touches the network: it
prints every entry with its `updatedAt`, and a `stale` flag computed against
`--current` (a JSON list of issues, or an object with an `issues` list, each
with `number` and `updatedAt`; `fetch-blocked-issues.sh` output fits). Without
`--current`, or for an issue it does not mention, `stale` is null.

The cache lives in `$(git rev-parse --git-common-dir)/autocoder-blocked-analyses/`,
shared by every worktree and never committed. `AUTOCODER_BLOCKED_CACHE_DIR`
overrides it.

Analysis schema:

    {
      "summary": "one line",
      "options": [                       # 2 or 3 of them
        {"title": "...", "pros": ["..."], "cons": ["..."], "effort": "..."}
      ],
      "recommended": 0                   # index into options
    }
"""

import argparse
import json
import os
import subprocess
import sys
import tempfile

CACHE_SUBDIR = "autocoder-blocked-analyses"


def cache_dir():
    override = os.environ.get("AUTOCODER_BLOCKED_CACHE_DIR")
    if override:
        return override
    try:
        common = subprocess.run(
            ["git", "rev-parse", "--path-format=absolute", "--git-common-dir"],
            check=True, capture_output=True, text=True,
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        sys.exit("blocked-analysis-cache: not inside a git repository "
                 "(set AUTOCODER_BLOCKED_CACHE_DIR to use another directory)")
    return os.path.join(common, CACHE_SUBDIR)


def issue_number(text):
    if not text.isdigit() or int(text) <= 0:
        raise argparse.ArgumentTypeError(f"not an issue number: {text!r}")
    return int(text)


def entry_path(number):
    return os.path.join(cache_dir(), f"{number}.json")


def _nonempty_str(value):
    return isinstance(value, str) and value.strip() != ""


def _str_list(value):
    return isinstance(value, list) and all(_nonempty_str(v) for v in value)


def validate(analysis):
    """Return a list of problems; empty means the analysis is well formed."""
    if not isinstance(analysis, dict):
        return ["the analysis must be a JSON object"]
    problems = []
    if not _nonempty_str(analysis.get("summary")):
        problems.append("'summary' must be a non-empty string")
    elif "\n" in analysis["summary"].strip():
        problems.append("'summary' must be one line")
    options = analysis.get("options")
    if not isinstance(options, list) or not 2 <= len(options) <= 3:
        problems.append("'options' must be a list of 2 or 3 options")
        options = []
    for i, opt in enumerate(options):
        if not isinstance(opt, dict):
            problems.append(f"options[{i}] must be an object")
            continue
        if not _nonempty_str(opt.get("title")):
            problems.append(f"options[{i}].title must be a non-empty string")
        for key in ("pros", "cons"):
            if not _str_list(opt.get(key)):
                problems.append(f"options[{i}].{key} must be a list of non-empty strings")
        if not _nonempty_str(opt.get("effort")):
            problems.append(f"options[{i}].effort must be a non-empty string")
    rec = analysis.get("recommended")
    if isinstance(rec, bool) or not isinstance(rec, int):
        problems.append("'recommended' must be an integer index into 'options'")
    elif options and not 0 <= rec < len(options):
        problems.append(f"'recommended' is {rec}, outside options[0..{len(options) - 1}]")
    return problems


def read_entry(path):
    try:
        with open(path) as f:
            entry = json.load(f)
    except FileNotFoundError:
        return None
    except (OSError, ValueError) as e:
        print(f"blocked-analysis-cache: unreadable entry {path}: {e}", file=sys.stderr)
        return None
    if not isinstance(entry, dict) or "analysis" not in entry:
        print(f"blocked-analysis-cache: malformed entry {path}", file=sys.stderr)
        return None
    return entry


def cmd_put(args):
    try:
        with open(args.file) as f:
            analysis = json.load(f)
    except OSError as e:
        print(f"blocked-analysis-cache: cannot read {args.file}: {e}", file=sys.stderr)
        return 2
    except ValueError as e:
        print(f"blocked-analysis-cache: {args.file} is not valid JSON: {e}", file=sys.stderr)
        return 2
    problems = validate(analysis)
    if problems:
        print(f"blocked-analysis-cache: refusing malformed analysis for #{args.number}:",
              file=sys.stderr)
        for p in problems:
            print(f"  - {p}", file=sys.stderr)
        return 2
    directory = cache_dir()
    os.makedirs(directory, exist_ok=True)
    entry = {"number": args.number, "updatedAt": args.updated_at, "analysis": analysis}
    # Write then rename, so a reader never sees half an entry.
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=f".{args.number}.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(entry, f, indent=2)
            f.write("\n")
        os.replace(tmp, entry_path(args.number))
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise
    print(f"blocked-analysis-cache: cached analysis for #{args.number} (updatedAt {args.updated_at})")
    return 0


def cmd_get(args):
    entry = read_entry(entry_path(args.number))
    if entry is None:
        print(f"blocked-analysis-cache: no analysis cached for #{args.number}", file=sys.stderr)
        return 1
    if entry.get("updatedAt") != args.updated_at:
        print(f"blocked-analysis-cache: analysis for #{args.number} is stale "
              f"(cached for updatedAt {entry.get('updatedAt')}, issue is {args.updated_at})",
              file=sys.stderr)
        return 1
    print(json.dumps(entry["analysis"], indent=2))
    return 0


def load_current(path):
    with open(path) as f:
        data = json.load(f)
    if isinstance(data, dict):
        data = data.get("issues", [])
    current = {}
    for issue in data if isinstance(data, list) else []:
        if isinstance(issue, dict) and "number" in issue and "updatedAt" in issue:
            current[str(issue["number"])] = issue["updatedAt"]
    return current


def cmd_list(args):
    current = None
    if args.current:
        try:
            current = load_current(args.current)
        except (OSError, ValueError) as e:
            print(f"blocked-analysis-cache: cannot read --current {args.current}: {e}",
                  file=sys.stderr)
            return 2
    directory = cache_dir()
    names = os.listdir(directory) if os.path.isdir(directory) else []
    numbers = sorted(int(n[:-5]) for n in names if n.endswith(".json") and n[:-5].isdigit())
    rows = []
    for number in numbers:
        entry = read_entry(entry_path(number))
        if entry is None:
            continue
        stale = None
        if current is not None and str(number) in current:
            stale = current[str(number)] != entry.get("updatedAt")
        rows.append({"number": number, "updatedAt": entry.get("updatedAt"), "stale": stale})
    print(json.dumps(rows, indent=2))
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("put", help="store an analysis")
    p.add_argument("number", type=issue_number)
    p.add_argument("--updated-at", required=True)
    p.add_argument("--file", required=True)
    p.set_defaults(func=cmd_put)

    p = sub.add_parser("get", help="print a fresh cached analysis")
    p.add_argument("number", type=issue_number)
    p.add_argument("--updated-at", required=True)
    p.set_defaults(func=cmd_get)

    p = sub.add_parser("list", help="list cached entries")
    p.add_argument("--current", help="JSON issues with number and updatedAt, to compute stale")
    p.set_defaults(func=cmd_list)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
