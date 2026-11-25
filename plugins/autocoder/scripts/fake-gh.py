#!/usr/bin/env python3
"""fake-gh.py: a `gh` stand-in for the GitHub issue surface the autocoder scripts use (#403).

WHY THIS EXISTS:
  eval-run.py's file-backend sandbox never runs the GitHub claim protocol (the label add, the
  claim marker comment, the read-back by createdAt), and the file backend folds comments into
  the issue body. So a finding about the claim race or the review record cannot be replayed
  there. Under a case's `backend: fake-github` a `gh` shim execs this script against a
  per-sandbox store, and the real issues-gh.sh, claim-issue.sh and fix-loop-gate.sh run
  unchanged. A form it does not know exits 1 with a `fake gh: unsupported` line on stderr, so a
  gap shows up as a failed run, never as a silent success.

STATE: FAKE_GH_STORE is a directory of <number>.json files. Each holds the document
  `gh issue view N --json number,title,body,state,labels,comments,...` prints, so
  trace-build.py --comments-dir reads the store as it is. Comments are kept in server order,
  and createdAt is the wall time of the post, because claim-window.sh measures its race window
  in server seconds. Every call is appended to FAKE_GH_LOG as {"argv": [...], "exit": N}.
  FAKE_GH_REPO (default example/project) names the repository. FAKE_GH_USER (default eval)
  authors issues and comments. Labels need no `gh label create` first.

FORMS:
  gh issue list [--state open|closed|all] [--label L]... [--limit N] [--json F,...] [--jq EXPR]
  gh issue view N [--json F,...] [--jq EXPR] [--comments]
  gh issue edit N [--add-label L]... [--remove-label L]... [--add-assignee A]...
  gh issue comment N --body TEXT
  gh issue close N [--comment TEXT] [--reason completed|"not planned"]
  gh issue reopen N
  gh issue create --title T --body B [--label L]...
  gh repo view --json F,... [--jq EXPR]
  gh api graphql [--paginate] -f K=V...   (issue-deps.sh's blockedBy query only; no blockers)
  Short flags (-L -q -l -b -t -c -r -s), `--flag=value` and comma-separated labels work as in gh.
"""

from __future__ import annotations

import fcntl
import json
import os
import subprocess
import sys
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone

# (group, verb) -> ({flag: "one" | "many" | "bool"}, positional count)
FORMS = {
    ("issue", "list"): ({"--state": "one", "--label": "many", "--limit": "one", "--json": "one", "--jq": "one"}, 0),
    ("issue", "view"): ({"--json": "one", "--jq": "one", "--comments": "bool"}, 1),
    ("issue", "edit"): ({"--add-label": "many", "--remove-label": "many", "--add-assignee": "many"}, 1),
    ("issue", "comment"): ({"--body": "one"}, 1),
    ("issue", "close"): ({"--comment": "one", "--reason": "one"}, 1),
    ("issue", "reopen"): ({}, 1),
    ("issue", "create"): ({"--title": "one", "--body": "one", "--label": "many"}, 0),
    ("repo", "view"): ({"--json": "one", "--jq": "one"}, 0),
    ("api", "graphql"): ({"--paginate": "bool", "-f": "many", "-F": "many"}, 0),
}
ALIASES = {"-L": "--limit", "-q": "--jq", "-l": "--label", "-b": "--body", "-t": "--title", "-c": "--comment",
           "-r": "--reason", "-s": "--state"}
LABEL_FLAGS = ("--label", "--add-label", "--remove-label")
ISSUE_FIELDS = ("number", "title", "body", "state", "stateReason", "labels", "comments", "assignees", "author",
                "createdAt", "updatedAt", "url")
CLOSE_REASONS = {"completed": "COMPLETED", "not planned": "NOT_PLANNED"}


class Fail(Exception):
    """A gh error: the message goes to stderr and the call exits 1."""


class Unsupported(Exception):
    """A form this fake does not answer."""


def repo() -> str:
    return os.environ.get("FAKE_GH_REPO", "example/project")


def user() -> str:
    return os.environ.get("FAKE_GH_USER", "eval")


def stamp(age_s: float = 0) -> str:
    return (datetime.now(timezone.utc) - timedelta(seconds=age_s)).strftime("%Y-%m-%dT%H:%M:%SZ")


# ── The store ────────────────────────────────────────────────────────────────
@contextmanager
def locked(store: str):
    """Serialise read-modify-write: racing workers post markers into the same issue."""
    os.makedirs(store, exist_ok=True)
    with open(os.path.join(store, ".lock"), "w") as fh:
        fcntl.flock(fh, fcntl.LOCK_EX)
        yield


def load(store: str, n: int) -> dict:
    try:
        with open(os.path.join(store, f"{n}.json")) as fh:
            return json.load(fh)
    except FileNotFoundError:
        raise Fail(f"GraphQL: Could not resolve to an issue or pull request with the number of {n}. "
                   "(repository.issue)") from None


def save(store: str, doc: dict) -> None:
    doc["updatedAt"] = stamp()
    path = os.path.join(store, f"{doc['number']}.json")
    with open(path + ".tmp", "w") as fh:
        json.dump(doc, fh, indent=2)
    os.replace(path + ".tmp", path)


def issues(store: str) -> list[dict]:
    """Every issue, newest first, as `gh issue list` orders them."""
    names = [f for f in os.listdir(store) if f.endswith(".json") and f[:-5].isdigit()] if os.path.isdir(store) else []
    return sorted((load(store, int(f[:-5])) for f in names), key=lambda d: -d["number"])


def create_issue(store: str, title: str, body: str, labels: list[str], state: str = "OPEN") -> dict:
    with locked(store):
        n = max((d["number"] for d in issues(store)), default=0) + 1
        now = stamp()
        doc = {"number": n, "title": title, "body": body, "state": state,
               "stateReason": "COMPLETED" if state == "CLOSED" else None,
               "labels": [{"name": name} for name in dict.fromkeys(labels)], "comments": [], "assignees": [],
               "author": {"login": user()}, "createdAt": now, "updatedAt": now, "url": f"https://github.com/{repo()}/issues/{n}"}
        save(store, doc)
    return doc


def add_comment(store: str, n: int, body: str, age_s: float = 0) -> str:
    """Append a comment; age_s backdates createdAt (eval-run.py stages old comments with it)."""
    with locked(store):
        doc = load(store, n)
        url = f"{doc['url']}#issuecomment-{n}{len(doc['comments']) + 1:04d}"
        doc["comments"].append({"author": {"login": user()}, "body": body, "createdAt": stamp(age_s), "url": url})
        save(store, doc)
    return url


def edit_issue(store: str, n: int, change) -> dict:
    with locked(store):
        doc = load(store, n)
        change(doc)
        save(store, doc)
    return doc


# ── Output ───────────────────────────────────────────────────────────────────
def pick(doc: dict, fields: str, known) -> dict:
    out = {}
    for f in fields.split(","):
        if f not in known:
            raise Fail(f'Unknown JSON field: "{f}"\nAvailable fields:\n  ' + "\n  ".join(sorted(known)))
        out[f] = doc.get(f)
    return out


def emit(value, jq: str | None) -> int:
    text = value if isinstance(value, str) else json.dumps(value, indent=2)
    if jq is None:
        print(text)
        return 0
    try:
        r = subprocess.run(["jq", "-r", jq], input=text, capture_output=True, text=True)
    except FileNotFoundError:
        raise Fail("fake gh: --jq needs the jq binary on PATH") from None
    sys.stdout.write(r.stdout)
    sys.stderr.write(r.stderr)
    return r.returncode


def label_names(doc: dict) -> list[str]:
    return [label["name"] for label in doc["labels"]]


def as_text(doc: dict, with_comments: bool) -> str:
    """gh's non-TTY `issue view`: tab-separated header lines, `--`, the body."""
    lines = [f"title:\t{doc['title']}", f"state:\t{doc['state']}", f"author:\t{doc['author']['login']}",
             f"labels:\t{', '.join(label_names(doc))}", f"comments:\t{len(doc['comments'])}",
             f"number:\t{doc['number']}", "--", doc["body"]]
    if with_comments:
        for c in doc["comments"]:
            lines += ["--", f"author:\t{c['author']['login']}", f"createdAt:\t{c['createdAt']}", "--", c["body"]]
    return "\n".join(lines)


# ── The forms ────────────────────────────────────────────────────────────────
def parse(argv: list[str]):
    key = tuple(argv[:2])
    if key not in FORMS:
        raise Unsupported
    spec, npos = FORMS[key]
    flags, pos, rest, i = {}, [], argv[2:], 0
    while i < len(rest):
        arg = rest[i]
        name, eq, value = arg.partition("=") if arg.startswith("--") else (arg, "", "")
        name = ALIASES.get(name, name)
        i += 1
        if name not in spec:
            if arg.startswith("-"):
                raise Unsupported
            pos.append(arg)
            continue
        if spec[name] == "bool":
            flags[name] = True
            continue
        if not eq:
            if i >= len(rest):
                raise Unsupported
            value, i = rest[i], i + 1
        values = [v.strip() for v in value.split(",") if v.strip()] if name in LABEL_FLAGS else [value]
        if spec[name] == "many":
            flags.setdefault(name, []).extend(values)
        else:
            flags[name] = value
    if len(pos) != npos:
        raise Unsupported
    numbers = [int(p.lstrip("#")) for p in pos if p.lstrip("#").isdigit()]
    if len(numbers) != len(pos):
        raise Unsupported
    return key, flags, numbers


def run(argv: list[str], store: str) -> int:
    key, flags, numbers = parse(argv)
    n = numbers[0] if numbers else None
    jq = flags.get("--jq")
    if key == ("issue", "list"):
        state = flags.get("--state", "open")
        if state not in ("open", "closed", "all"):
            raise Fail(f'invalid argument "{state}" for "-s, --state" flag: valid values are {{open|closed|all}}')
        want = flags.get("--label", [])
        found = [d for d in issues(store) if state == "all" or d["state"] == state.upper()]
        found = [d for d in found if all(w in label_names(d) for w in want)][:int(flags.get("--limit", 30))]
        if "--json" in flags:
            return emit([pick(d, flags["--json"], ISSUE_FIELDS) for d in found], jq)
        return emit("\n".join(f"{d['number']}\t{d['state']}\t{d['title']}\t{', '.join(label_names(d))}\t"
                              f"{d['updatedAt']}" for d in found), jq)
    if key == ("issue", "view"):
        doc = load(store, n)
        if "--json" in flags:
            return emit(pick(doc, flags["--json"], ISSUE_FIELDS), jq)
        return emit(as_text(doc, flags.get("--comments", False)), jq)
    if key == ("issue", "edit"):
        def change(doc):
            names = [x for x in label_names(doc) + flags.get("--add-label", []) if x not in flags.get("--remove-label", [])]
            doc["labels"] = [{"name": x} for x in dict.fromkeys(names)]
            doc["assignees"] += [{"login": a} for a in flags.get("--add-assignee", [])]
        print(edit_issue(store, n, change)["url"])
        return 0
    if key == ("issue", "comment"):
        if "--body" not in flags:
            raise Unsupported
        print(add_comment(store, n, flags["--body"]))
        return 0
    if key == ("issue", "close"):
        reason = CLOSE_REASONS.get(flags.get("--reason", "completed"))
        if reason is None:
            raise Fail(f"invalid reason {flags['--reason']!r}: valid values are completed and \"not planned\"")
        if flags.get("--comment"):
            add_comment(store, n, flags["--comment"])
        doc = edit_issue(store, n, lambda d: d.update(state="CLOSED", stateReason=reason))
        print(f"✓ Closed issue #{n} ({doc['title']})", file=sys.stderr)
        return 0
    if key == ("issue", "reopen"):
        doc = edit_issue(store, n, lambda d: d.update(state="OPEN", stateReason="REOPENED"))
        print(f"✓ Reopened issue #{n} ({doc['title']})", file=sys.stderr)
        return 0
    if key == ("issue", "create"):
        if "--title" not in flags or "--body" not in flags:
            raise Fail("must provide `--title` and `--body` when not running interactively")
        print(create_issue(store, flags["--title"], flags["--body"], flags.get("--label", []))["url"])
        return 0
    if key == ("repo", "view"):
        if "--json" not in flags:
            raise Unsupported
        owner, name = repo().split("/", 1)
        doc = {"nameWithOwner": repo(), "name": name, "owner": {"login": owner}, "url": f"https://github.com/{repo()}",
               "defaultBranchRef": {"name": "master"}}
        return emit(pick(doc, flags["--json"], doc), jq)
    # api graphql: only the open-issue blockedBy query issue-deps.sh sends.
    fields = dict(f.partition("=")[::2] for f in flags.get("-f", []) + flags.get("-F", []))
    if "blockedBy" not in fields.get("query", ""):
        raise Unsupported
    nodes = [{"number": d["number"], "blockedBy": {"nodes": []}} for d in issues(store) if d["state"] == "OPEN"]
    return emit({"data": {"repository": {"issues": {"pageInfo": {"hasNextPage": False, "endCursor": None},
                                                    "nodes": nodes}}}}, jq)


def main(argv: list[str]) -> int:
    code = 1
    try:
        store = os.environ.get("FAKE_GH_STORE")
        if not store:
            raise Fail("fake gh: FAKE_GH_STORE is not set")
        code = run(argv, store)
    except Unsupported:
        print(f"fake gh: unsupported form: gh {' '.join(argv)}", file=sys.stderr)
    except Fail as e:
        print(e, file=sys.stderr)
    finally:
        if os.environ.get("FAKE_GH_LOG"):
            with open(os.environ["FAKE_GH_LOG"], "a") as log:
                log.write(json.dumps({"argv": argv, "exit": code}) + "\n")
    return code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
