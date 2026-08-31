#!/usr/bin/env python3
"""File-based issue backend. Manages .issues/{open,working,blocked,closed}/NNN.md files.

All read-modify-write ops use fcntl.flock for safe concurrent access. All I/O
inside a flock uses the locked file descriptor — never re-opens by path.

State transitions use POSIX atomic rename(2) between bucket directories. The
directory location is authoritative; frontmatter `status` is kept for
human-readability but the bucket wins on disagreement.

Environment:
  ISSUE_DIR_PATH  absolute path to .issues/ directory in the MAIN worktree.
                  All agents (including those in secondary worktrees) MUST
                  share this single directory; issue-config.sh resolves it.

Usage:
  issues-file.py list [--label L] [--state open|working|blocked|closed|all] [--limit N]
  issues-file.py get <number>
  issues-file.py update <number> [--add-label L] [--remove-label L] [--status S] [--assignee A]
  issues-file.py comment <number> --body "..."
  issues-file.py close <number> [--comment "..."]
  issues-file.py create --title "..." --body "..." [--label L]
  issues-file.py claim <number>
  issues-file.py release <number>
  issues-file.py any-claimable
  issues-file.py migrate-layout
  issues-file.py find-main-worktree
  issues-file.py import-from-gh
  issues-file.py export-to-gh

Exit codes:
  0 — success. For `any-claimable`: at least one claimable issue exists.
  1 — clean negative. For `any-claimable`: no claimable issues. For `claim`: race
      lost or not in open/. For get/update/comment/close/release: issue not found.
  2 — usage error.
  3 — backend error (e.g., open/ missing for any-claimable).
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


BUCKETS = ("open", "working", "blocked", "closed")

# Labels that mark an issue as needing human input before AI work can proceed.
# Their presence puts (or keeps) the issue in `blocked/` instead of `open/`.
BLOCKING_LABELS = frozenset({
    "needs-design",
    "needs-clarification",
    "needs-feedback",
    "needs-approval",
    "too-complex",
    "future",
    "proposal",
})


# ---------------------------------------------------------------------------
# Approved-work gate
# ---------------------------------------------------------------------------
# Mirrors issue-approval-lib.sh for the shell backends. When a required label
# is configured, an issue is claimable only if it carries that label, so
# approval is an explicit positive act rather than the absence of a blocking
# label. Unconfigured means no gate, which is the pre-existing behaviour.


def required_label() -> str:
    """The configured approval label, or "" when the gate is off.

    An explicitly empty AUTOCODER_REQUIRED_LABEL disables the gate even when
    the repo config sets one, so a one-off manual run needs no config edit.
    """
    env = os.environ.get("AUTOCODER_REQUIRED_LABEL")
    if env is not None:
        return env

    try:
        root = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, check=False,
        ).stdout.strip()
    except Exception:
        return ""
    if not root:
        return ""

    config = Path(root) / ".autocoder.json"
    try:
        value = json.loads(config.read_text()).get("requiredLabel", "")
    except Exception:
        return ""
    return value if isinstance(value, str) else ""


def labels_approved(labels, required: str) -> bool:
    return not required or required in (labels or [])


# ---------------------------------------------------------------------------
# Directory resolution
# ---------------------------------------------------------------------------

def get_issues_dir() -> Path:
    d = os.environ.get("ISSUE_DIR_PATH", "")
    if not d:
        sys.exit("Error: ISSUE_DIR_PATH not set. Source issue-config.sh first.")
    return Path(d)


def issue_path(issues_dir: Path, bucket: str, number: int) -> Path:
    return issues_dir / bucket / f"{number:03d}.md"


def seq_path(issues_dir: Path) -> Path:
    return issues_dir / ".seq"


def resolve_path(issues_dir: Path, number: int) -> tuple[str, Path]:
    """Return (bucket, path) for the first bucket holding this issue.

    Bounded retry handles the race where a concurrent rename moves the file
    between buckets between our probes. Three attempts is sufficient — a
    sustained rename storm on the same issue is itself a bug.
    """
    for _ in range(3):
        for bucket in BUCKETS:
            p = issue_path(issues_dir, bucket, number)
            if p.exists():
                return bucket, p
    raise FileNotFoundError(f"issue {number} not in any bucket")


# ---------------------------------------------------------------------------
# Frontmatter parsing — fd-based (mandatory) + path-based (read-only callers)
# ---------------------------------------------------------------------------

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


def _format_issue(data: dict) -> str:
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
    return f"---\n{front}\n---\n{body}\n" if body else f"---\n{front}\n---\n"


def _parse_text(content: str) -> dict:
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


def parse_issue_file_fd(f) -> dict:
    """Read+parse from a locked fd. Caller holds flock(f.fileno())."""
    f.seek(0)
    return _parse_text(f.read())


def write_issue_file_fd(f, data: dict) -> None:
    """Write to a locked fd. Caller holds flock(f.fileno())."""
    text = _format_issue(data)
    f.seek(0)
    f.truncate()
    f.write(text)
    f.flush()


def parse_issue_file(path: Path) -> dict:
    """Path-based read-only parse (no lock). Used by cmd_list/cmd_get/migrate.
    Safe because list/get are snapshot views; concurrent renames just shift
    which path holds the inode — both old and new paths reference identical
    content during the transition.
    """
    content = path.read_text()
    return _parse_text(content)


def write_issue_file(path: Path, data: dict) -> None:
    """Path-based write — only used by cmd_create (new file, no concurrent
    writers possible because the number was just allocated under .seq's flock).
    """
    path.write_text(_format_issue(data))


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


def _ensure_bucket(issues_dir: Path, bucket: str) -> None:
    (issues_dir / bucket).mkdir(parents=True, exist_ok=True)


# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------

def cmd_list(args):
    issues_dir = get_issues_dir()
    state = args.state or "open"
    buckets = list(BUCKETS) if state == "all" else [state]
    results = []
    for bucket in buckets:
        d = issues_dir / bucket
        if not d.is_dir():
            continue
        for p in sorted(d.glob("*.md")):
            if p.name.startswith("."):
                continue
            try:
                data = parse_issue_file(p)
            except FileNotFoundError:
                # Concurrent rename moved the file out from under us; skip.
                continue
            if args.label:
                labels = data.get("labels") or []
                if args.label not in labels:
                    continue
            # Only the claimable queue is gated. `working` and `blocked` are
            # deliberately not: an issue claimed before the gate was configured
            # must stay visible rather than look like a vanished worker.
            if bucket == "open" and not labels_approved(
                data.get("labels"), required_label()
            ):
                continue
            results.append(to_gh_json(data))
    if args.limit:
        results = results[:args.limit]
    print(json.dumps(results, indent=2))


def cmd_get(args):
    issues_dir = get_issues_dir()
    try:
        bucket, p = resolve_path(issues_dir, args.number)
    except FileNotFoundError:
        sys.exit(1)
    data = parse_issue_file(p)
    print(json.dumps(to_gh_json(data), indent=2))


def cmd_update(args):
    issues_dir = get_issues_dir()
    try:
        bucket, path = resolve_path(issues_dir, args.number)
    except FileNotFoundError:
        sys.exit(1)
    target_bucket = None
    with open(path, "r+") as f:
        lock_ex(f.fileno())
        try:
            data = parse_issue_file_fd(f)
            labels = list(data.get("labels") or [])
            if args.add_label:
                if args.add_label not in labels:
                    labels.append(args.add_label)
                if args.add_label == "working":
                    # Legacy/idempotent label-set. Does NOT rename to working/;
                    # only `claim` does that. Frontmatter status is updated for
                    # backward-readability.
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
            write_issue_file_fd(f, data)
            # Compute bucket transition based on POST-write labels (working
            # label is excluded from the blocking-set check).
            new_labels = [l for l in data["labels"] if l != "working"]
            has_blocking = any(l in BLOCKING_LABELS for l in new_labels)
            if bucket == "open" and has_blocking:
                target_bucket = "blocked"
            elif bucket == "blocked" and not has_blocking:
                target_bucket = "open"
        finally:
            unlock(f.fileno())
    if target_bucket is not None:
        _ensure_bucket(issues_dir, target_bucket)
        try:
            os.rename(path, issue_path(issues_dir, target_bucket, args.number))
        except FileNotFoundError:
            # Concurrent claim moved the file to working/ first; leave it.
            pass


def cmd_comment(args):
    issues_dir = get_issues_dir()
    try:
        bucket, p = resolve_path(issues_dir, args.number)
    except FileNotFoundError:
        sys.exit(1)
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M")
    blockquote = f"\n> **{ts}** {args.body}"
    with open(p, "r+") as f:
        lock_ex(f.fileno())
        try:
            data = parse_issue_file_fd(f)
            data["body"] = (data.get("body") or "") + blockquote
            write_issue_file_fd(f, data)
        finally:
            unlock(f.fileno())


def cmd_close(args):
    issues_dir = get_issues_dir()
    try:
        bucket, p = resolve_path(issues_dir, args.number)
    except FileNotFoundError:
        sys.exit(1)
    with open(p, "r+") as f:
        lock_ex(f.fileno())
        try:
            data = parse_issue_file_fd(f)
            data["status"] = "closed"
            # Strip the working label if present (closing an in-flight issue).
            data["labels"] = [l for l in (data.get("labels") or []) if l != "working"]
            if args.comment:
                ts = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M")
                data["body"] = (data.get("body") or "") + f"\n> **{ts}** {args.comment}"
            write_issue_file_fd(f, data)
        finally:
            unlock(f.fileno())
    _ensure_bucket(issues_dir, "closed")
    dst = issue_path(issues_dir, "closed", args.number)
    if p != dst:
        try:
            os.rename(p, dst)
        except FileNotFoundError:
            pass


def cmd_create(args):
    issues_dir = get_issues_dir()
    seq = seq_path(issues_dir)
    issues_dir.mkdir(parents=True, exist_ok=True)
    seq.touch()
    with open(seq, "r+") as f:
        lock_ex(f.fileno())
        try:
            raw = f.read().strip()
            current = int(raw) if raw else 0
            number = current + 1
            f.seek(0)
            f.truncate()
            f.write(str(number) + "\n")
        finally:
            unlock(f.fileno())
    data = {
        "number": number,
        "title": args.title,
        "labels": args.label or [],
        "status": "open",
        "body": args.body or "",
    }
    _ensure_bucket(issues_dir, "open")
    write_issue_file(issue_path(issues_dir, "open", number), data)
    print(json.dumps({"number": number}))


def cmd_claim(args):
    issues_dir = get_issues_dir()
    src = issue_path(issues_dir, "open", args.number)
    # Gate the claim itself, not just the queue. Issues reach a worker by
    # number from several paths -- a manager dispatch, /fix N, a resumed loop
    # -- and a filtered queue constrains none of them. Exit 1 is the clean
    # negative callers already handle for a lost claim race.
    required = required_label()
    if required:
        try:
            data = parse_issue_file(src)
        except FileNotFoundError:
            sys.exit(1)
        if not labels_approved(data.get("labels"), required):
            print(
                f"Issue #{args.number} is not approved for autonomous work: "
                f"it does not carry the '{required}' label.",
                file=sys.stderr,
            )
            print(
                "Add the label to approve it, or unset requiredLabel in "
                ".autocoder.json to disable the gate.",
                file=sys.stderr,
            )
            sys.exit(1)
    _ensure_bucket(issues_dir, "working")
    dst = issue_path(issues_dir, "working", args.number)
    try:
        os.rename(src, dst)
    except FileNotFoundError:
        sys.exit(1)
    # Winner: update frontmatter under flock via fd.
    with open(dst, "r+") as f:
        lock_ex(f.fileno())
        try:
            data = parse_issue_file_fd(f)
            labels = list(data.get("labels") or [])
            if "working" not in labels:
                labels.append("working")
            data["labels"] = labels
            data["status"] = "working"
            write_issue_file_fd(f, data)
        finally:
            unlock(f.fileno())


def cmd_release(args):
    issues_dir = get_issues_dir()
    src = issue_path(issues_dir, "working", args.number)
    if not src.exists():
        sys.exit(1)
    target_bucket = "open"
    with open(src, "r+") as f:
        lock_ex(f.fileno())
        try:
            data = parse_issue_file_fd(f)
            labels = [l for l in (data.get("labels") or []) if l != "working"]
            has_blocking = any(l in BLOCKING_LABELS for l in labels)
            target_bucket = "blocked" if has_blocking else "open"
            data["labels"] = labels
            data["status"] = "blocked" if has_blocking else "open"
            write_issue_file_fd(f, data)
        finally:
            unlock(f.fileno())
    _ensure_bucket(issues_dir, target_bucket)
    dst = issue_path(issues_dir, target_bucket, args.number)
    try:
        os.rename(src, dst)
    except FileNotFoundError:
        sys.exit(1)


def cmd_any_claimable(args):
    issues_dir = get_issues_dir()
    open_dir = issues_dir / "open"
    if not open_dir.is_dir():
        sys.exit(3)
    required = required_label()
    for p in open_dir.glob("*.md"):
        if p.name.startswith("."):
            continue
        if not required:
            sys.exit(0)
        try:
            data = parse_issue_file(p)
        except FileNotFoundError:
            # Concurrent claim renamed it out from under us; keep looking.
            continue
        if labels_approved(data.get("labels"), required):
            sys.exit(0)
    sys.exit(1)


def cmd_migrate_layout(args):
    issues_dir = get_issues_dir()
    if not issues_dir.is_dir():
        sys.exit(f"Error: ISSUE_DIR_PATH ({issues_dir}) does not exist")
    # Idempotency guard: refuse if any bucket already populated.
    for bucket in BUCKETS:
        d = issues_dir / bucket
        if d.is_dir() and any(d.glob("*.md")):
            sys.exit(f"Error: {bucket}/ already contains .md files; already migrated")
    for bucket in BUCKETS:
        (issues_dir / bucket).mkdir(parents=True, exist_ok=True)
    counts = {b: 0 for b in BUCKETS}
    max_num = 0
    for p in sorted(issues_dir.glob("*.md")):
        if p.name.startswith("."):
            continue
        data = parse_issue_file(p)
        number = data.get("number")
        if not isinstance(number, int):
            try:
                number = int(p.stem)
            except ValueError:
                continue
        if number > max_num:
            max_num = number
        status = data.get("status", "open")
        labels = data.get("labels") or []
        if status == "closed":
            bucket = "closed"
        elif status == "working" or "working" in labels:
            bucket = "working"
        elif any(l in BLOCKING_LABELS for l in labels):
            bucket = "blocked"
        else:
            bucket = "open"
        p.rename(issue_path(issues_dir, bucket, number))
        counts[bucket] += 1
    seq = seq_path(issues_dir)
    current_seq = 0
    if seq.exists():
        raw = seq.read_text().strip()
        current_seq = int(raw) if raw else 0
    if max_num > current_seq:
        seq.write_text(str(max_num) + "\n")
    print(f"Migrated: {counts}")


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
    _ensure_bucket(issues_dir, "open")
    result = subprocess.run(
        ["gh", "issue", "list", "--state", "open",
         "--json", "number,title,body,labels,state", "--limit", "200"],
        capture_output=True, text=True, check=True
    )
    issues = json.loads(result.stdout)
    seq = seq_path(issues_dir)
    seq.touch()
    max_num = 0
    with open(seq, "r+") as f:
        lock_ex(f.fileno())
        try:
            for gh in issues:
                number = gh["number"]
                if number > max_num:
                    max_num = number
                labels = [l["name"] for l in gh.get("labels", [])]
                data = {
                    "number": number,
                    "title": gh.get("title", ""),
                    "labels": labels,
                    "status": "open",
                    "body": gh.get("body", "") or "",
                }
                bucket = "blocked" if any(l in BLOCKING_LABELS for l in labels) else "open"
                _ensure_bucket(issues_dir, bucket)
                write_issue_file(issue_path(issues_dir, bucket, number), data)
            raw = f.read().strip()
            current = int(raw) if raw else 0
            if max_num > current:
                f.seek(0)
                f.truncate()
                f.write(str(max_num) + "\n")
        finally:
            unlock(f.fileno())
    print(f"Imported {len(issues)} issues to {issues_dir}")


def cmd_export_to_gh():
    issues_dir = get_issues_dir()
    exported = 0
    for bucket in ("open", "working", "blocked"):
        d = issues_dir / bucket
        if not d.is_dir():
            continue
        for p in sorted(d.glob("*.md")):
            if p.name.startswith("."):
                continue
            data = parse_issue_file(p)
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
    p_list.add_argument("--state", choices=["open", "working", "blocked", "closed", "all"])
    p_list.add_argument("--limit", type=int)

    p_get = sub.add_parser("get")
    p_get.add_argument("number", type=int)

    p_update = sub.add_parser("update")
    p_update.add_argument("number", type=int)
    p_update.add_argument("--add-label", dest="add_label")
    p_update.add_argument("--remove-label", dest="remove_label")
    p_update.add_argument("--status")
    p_update.add_argument("--assignee")

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

    p_claim = sub.add_parser("claim")
    p_claim.add_argument("number", type=int)

    p_release = sub.add_parser("release")
    p_release.add_argument("number", type=int)

    sub.add_parser("any-claimable")
    sub.add_parser("migrate-layout")
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
        "claim": cmd_claim,
        "release": cmd_release,
        "any-claimable": cmd_any_claimable,
        "migrate-layout": cmd_migrate_layout,
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
