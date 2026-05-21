#!/usr/bin/env python3
"""File-based issue backend. Manages .issues/NNN.md files.
All read-modify-write ops use fcntl.flock for safe concurrent access.

Environment:
  ISSUE_DIR_PATH  absolute path to .issues/ directory

Usage:
  issues-file.py list [--label L] [--state open|closed|all] [--limit N]
  issues-file.py get <number>
  issues-file.py update <number> [--add-label L] [--remove-label L] [--status S] [--assignee A]
  issues-file.py comment <number> --body "..."
  issues-file.py close <number> [--comment "..."]
  issues-file.py create --title "..." --body "..." [--label L]
  issues-file.py find-main-worktree
  issues-file.py import-from-gh
  issues-file.py export-to-gh
"""

import argparse
import fcntl
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


# ---------------------------------------------------------------------------
# Directory resolution
# ---------------------------------------------------------------------------

def get_issues_dir() -> Path:
    d = os.environ.get("ISSUE_DIR_PATH", "")
    if not d:
        sys.exit("Error: ISSUE_DIR_PATH not set. Source issue-config.sh first.")
    return Path(d)


def issue_path(issues_dir: Path, number: int) -> Path:
    return issues_dir / f"{number:03d}.md"


def seq_path(issues_dir: Path) -> Path:
    return issues_dir / ".seq"


# ---------------------------------------------------------------------------
# Frontmatter parsing (no external deps — we control the format)
# ---------------------------------------------------------------------------

def parse_issue_file(path: Path) -> dict:
    """Parse .issues/NNN.md into a dict with all fields + 'body' key."""
    content = path.read_text()
    if not content.startswith("---\n"):
        return {"body": content.strip()}
    end = content.find("\n---\n", 4)
    if end == -1:
        return {"body": content.strip()}
    front_text = content[4:end]
    body = content[end + 5:].strip()
    data = _parse_frontmatter(front_text)
    data["body"] = body
    return data


def _parse_frontmatter(text: str) -> dict:
    data = {}
    for line in text.splitlines():
        if ": " not in line and not line.endswith(":"):
            continue
        key, _, val = line.partition(": ")
        key = key.strip()
        val = val.strip()
        if val.startswith("[") and val.endswith("]"):
            inner = val[1:-1].strip()
            data[key] = [v.strip() for v in inner.split(",")] if inner else []
        elif re.fullmatch(r"\d+", val):
            data[key] = int(val)
        else:
            data[key] = val
    return data


def write_issue_file(path: Path, data: dict) -> None:
    """Write dict back to .issues/NNN.md (frontmatter + body)."""
    body = data.get("body", "")
    lines = []
    for key in ("number", "title", "priority", "labels", "status", "assignee"):
        if key not in data:
            continue
        val = data[key]
        if isinstance(val, list):
            lines.append(f"{key}: [{', '.join(val)}]")
        else:
            lines.append(f"{key}: {val}")
    front = "\n".join(lines)
    path.write_text(f"---\n{front}\n---\n{body}\n" if body else f"---\n{front}\n---\n")


# ---------------------------------------------------------------------------
# JSON output schema (matches gh issue list/view)
# ---------------------------------------------------------------------------

def to_gh_json(data: dict) -> dict:
    status = data.get("status", "open")
    state = "CLOSED" if status == "closed" else "OPEN"
    labels_raw = data.get("labels") or []
    labels = [{"name": l} for l in labels_raw]
    return {
        "number": data.get("number"),
        "title": data.get("title", ""),
        "body": data.get("body", ""),
        "state": state,
        "labels": labels,
        "comments": [],
    }


# ---------------------------------------------------------------------------
# Locking helpers
# ---------------------------------------------------------------------------

def lock_ex(fd):
    fcntl.flock(fd, fcntl.LOCK_EX)


def lock_sh(fd):
    fcntl.flock(fd, fcntl.LOCK_SH)


def unlock(fd):
    fcntl.flock(fd, fcntl.LOCK_UN)


# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------

def cmd_list(args):
    issues_dir = get_issues_dir()
    results = []
    for p in sorted(issues_dir.glob("*.md")):
        if p.name.startswith("."):
            continue
        with open(p, "r") as f:
            lock_sh(f.fileno())
            try:
                data = parse_issue_file(p)
            finally:
                unlock(f.fileno())
        status = data.get("status", "open")
        if args.state and args.state != "all":
            if args.state == "open" and status != "open":
                continue
            if args.state == "closed" and status != "closed":
                continue
        if args.label:
            labels = data.get("labels") or []
            if args.label not in labels:
                continue
        results.append(to_gh_json(data))
    if args.limit:
        results = results[:args.limit]
    print(json.dumps(results, indent=2))


def cmd_get(args):
    issues_dir = get_issues_dir()
    p = issue_path(issues_dir, args.number)
    if not p.exists():
        sys.exit(f"Error: issue {args.number} not found ({p})")
    with open(p, "r") as f:
        lock_sh(f.fileno())
        try:
            data = parse_issue_file(p)
        finally:
            unlock(f.fileno())
    print(json.dumps(to_gh_json(data), indent=2))


def cmd_update(args):
    issues_dir = get_issues_dir()
    p = issue_path(issues_dir, args.number)
    if not p.exists():
        sys.exit(f"Error: issue {args.number} not found")
    with open(p, "r+") as f:
        lock_ex(f.fileno())
        try:
            data = parse_issue_file(p)
            labels = list(data.get("labels") or [])

            if args.add_label:
                already_set = args.add_label in labels
                # Atomic claim semantics: if --if-unset, refuse to add a
                # label that is already present. Exit 9 lets callers (e.g.
                # fix-loop-gate.sh) detect a lost race without parsing
                # output. The flock above serializes all writers, so this
                # check-then-set is race-free.
                if args.if_unset and already_set:
                    sys.exit(9)
                if not already_set:
                    labels.append(args.add_label)
                if args.add_label == "working":
                    data["status"] = "working"

            if args.remove_label:
                labels = [l for l in labels if l != args.remove_label]
                if args.remove_label == "working":
                    data["status"] = "open"

            if args.status:
                data["status"] = args.status

            if args.assignee:
                data["assignee"] = args.assignee

            data["labels"] = labels
            write_issue_file(p, data)
        finally:
            unlock(f.fileno())


def cmd_comment(args):
    issues_dir = get_issues_dir()
    p = issue_path(issues_dir, args.number)
    if not p.exists():
        sys.exit(f"Error: issue {args.number} not found")
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M")
    blockquote = f"\n> **{ts}** {args.body}"
    with open(p, "r+") as f:
        lock_ex(f.fileno())
        try:
            data = parse_issue_file(p)
            data["body"] = (data.get("body") or "") + blockquote
            write_issue_file(p, data)
        finally:
            unlock(f.fileno())


def cmd_close(args):
    issues_dir = get_issues_dir()
    p = issue_path(issues_dir, args.number)
    if not p.exists():
        sys.exit(f"Error: issue {args.number} not found")
    with open(p, "r+") as f:
        lock_ex(f.fileno())
        try:
            data = parse_issue_file(p)
            data["status"] = "closed"
            if args.comment:
                ts = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M")
                data["body"] = (data.get("body") or "") + f"\n> **{ts}** {args.comment}"
            write_issue_file(p, data)
        finally:
            unlock(f.fileno())


def cmd_create(args):
    issues_dir = get_issues_dir()
    seq = seq_path(issues_dir)
    seq.touch()
    with open(seq, "r+") as f:
        lock_ex(f.fileno())
        try:
            existing = sorted(
                int(p.stem) for p in issues_dir.glob("*.md")
                if p.stem.isdigit()
            )
            number = (existing[-1] + 1) if existing else 1
            data = {
                "number": number,
                "title": args.title,
                "labels": args.label or [],
                "status": "open",
                "body": args.body or "",
            }
            write_issue_file(issue_path(issues_dir, number), data)
        finally:
            unlock(f.fileno())
    print(json.dumps({"number": number}))


def cmd_find_main_worktree():
    result = subprocess.run(
        ["git", "worktree", "list", "--porcelain"],
        capture_output=True, text=True, check=True
    )
    for line in result.stdout.splitlines():
        if line.startswith("worktree "):
            print(line.split(" ", 1)[1])
            return
    sys.exit("Error: could not find main worktree")


def cmd_import_from_gh():
    issues_dir = get_issues_dir()
    result = subprocess.run(
        ["gh", "issue", "list", "--state", "open",
         "--json", "number,title,body,labels,state", "--limit", "200"],
        capture_output=True, text=True, check=True
    )
    issues = json.loads(result.stdout)
    seq = seq_path(issues_dir)
    seq.touch()
    with open(seq, "r+") as f:
        lock_ex(f.fileno())
        try:
            for gh in issues:
                number = gh["number"]
                labels = [l["name"] for l in gh.get("labels", [])]
                data = {
                    "number": number,
                    "title": gh.get("title", ""),
                    "labels": labels,
                    "status": "open",
                    "body": gh.get("body", "") or "",
                }
                write_issue_file(issue_path(issues_dir, number), data)
        finally:
            unlock(f.fileno())
    print(f"Imported {len(issues)} issues to {issues_dir}")


def cmd_export_to_gh():
    issues_dir = get_issues_dir()
    exported = 0
    for p in sorted(issues_dir.glob("*.md")):
        if p.name.startswith("."):
            continue
        data = parse_issue_file(p)
        if data.get("status") == "closed":
            continue
        labels = data.get("labels") or []
        create_args = ["gh", "issue", "create",
                       "--title", data.get("title", ""),
                       "--body", data.get("body", "") or ""]
        for l in labels:
            create_args += ["--label", l]
        subprocess.run(create_args, check=True)
        exported += 1
    print(f"Exported {exported} issues to GitHub")


# ---------------------------------------------------------------------------
# Main / argument parsing
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(prog="issues-file.py")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_list = sub.add_parser("list")
    p_list.add_argument("--label")
    p_list.add_argument("--state", choices=["open", "closed", "all"])
    p_list.add_argument("--limit", type=int)

    p_get = sub.add_parser("get")
    p_get.add_argument("number", type=int)

    p_update = sub.add_parser("update")
    p_update.add_argument("number", type=int)
    p_update.add_argument("--add-label", dest="add_label")
    p_update.add_argument("--remove-label", dest="remove_label")
    p_update.add_argument("--status")
    p_update.add_argument("--assignee")
    p_update.add_argument(
        "--if-unset",
        dest="if_unset",
        action="store_true",
        help="With --add-label, fail with exit 9 if the label is already set "
             "(atomic claim, race-free under the per-issue flock).",
    )

    p_comment = sub.add_parser("comment")
    p_comment.add_argument("number", type=int)
    p_comment.add_argument("--body", required=True)

    p_close = sub.add_parser("close")
    p_close.add_argument("number", type=int)
    p_close.add_argument("--comment")

    p_create = sub.add_parser("create")
    p_create.add_argument("--title", required=True)
    p_create.add_argument("--body", default="")
    p_create.add_argument("--label", action="append", default=[])

    sub.add_parser("find-main-worktree")
    sub.add_parser("import-from-gh")
    sub.add_parser("export-to-gh")

    args = parser.parse_args()

    dispatch = {
        "list": cmd_list,
        "get": cmd_get,
        "update": cmd_update,
        "comment": cmd_comment,
        "close": cmd_close,
        "create": cmd_create,
        "find-main-worktree": lambda _: cmd_find_main_worktree(),
        "import-from-gh": lambda _: cmd_import_from_gh(),
        "export-to-gh": lambda _: cmd_export_to_gh(),
    }
    fn = dispatch.get(args.cmd)
    if fn:
        fn(args)
    else:
        sys.exit(f"Subcommand '{args.cmd}' not implemented")


if __name__ == "__main__":
    main()
