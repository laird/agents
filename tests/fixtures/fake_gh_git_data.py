#!/usr/bin/env python3
"""A `gh api` stand-in for the GitHub Git Data endpoints api-push.py uses.

Backed by a real bare repository (FAKE_GH_REPO), so blobs, trees, commits and
refs it creates are the ones a later `git fetch` from that repository sees.
Each call is appended to FAKE_GH_LOG as "<METHOD> <path> <body>".

    FAKE_GH_FAIL_PATCHES=N   the first N PATCH calls fail with HTTP 422 and
                             leave the ref untouched (a sibling won the race)

Status semantics match GitHub's: a non-fast-forward PATCH without force, or a
POST of a ref that already exists, exits 1 with "HTTP 422" on stderr; a GET
of a missing ref exits 1 with "HTTP 404".
"""
import base64
import json
import os
import re
import subprocess
import sys
import tempfile


def fail(code, msg):
    print(f"gh: {msg} (HTTP {code})", file=sys.stderr)
    sys.exit(1)


def git(*args, input=None):
    r = subprocess.run(["git", "-C", REPO, *args], capture_output=True, input=input)
    if r.returncode != 0:
        fail(500, r.stderr.decode().strip())
    return r.stdout.decode().strip()


def git_ok(*args):
    return subprocess.run(["git", "-C", REPO, *args], capture_output=True).returncode == 0


REPO = os.environ["FAKE_GH_REPO"]
args = sys.argv[1:]
if not args or args[0] != "api":
    fail(400, f"fake gh only implements `gh api`, got {args!r}")
path = args[1]
method = "GET"
jq = None
body = None
i = 2
while i < len(args):
    if args[i] == "-X":
        method = args[i + 1]; i += 2
    elif args[i] == "--jq":
        jq = args[i + 1]; i += 2
    elif args[i] == "--input":
        body = json.load(sys.stdin); i += 2
    else:
        i += 1

with open(os.environ.get("FAKE_GH_LOG", os.devnull), "a") as log:
    log.write(f"{method} {path} {json.dumps(body) if body is not None else ''}\n")


def emit(obj):
    if jq == ".object.sha":
        print(obj["object"]["sha"])
    else:
        print(json.dumps(obj))


def ref_get(target):
    if not git_ok("rev-parse", "--verify", "-q", f"refs/heads/{target}"):
        fail(404, "Not Found")
    emit({"ref": f"refs/heads/{target}", "object": {"sha": git("rev-parse", f"refs/heads/{target}")}})


def ref_patch(target, sha, force):
    counter = os.environ.get("FAKE_GH_FAIL_PATCHES_STATE")
    budget = int(os.environ.get("FAKE_GH_FAIL_PATCHES", "0"))
    if budget and counter:
        used = int(open(counter).read() or 0) if os.path.exists(counter) else 0
        if used < budget:
            open(counter, "w").write(str(used + 1))
            fail(422, "Update is not a fast forward")
    if not git_ok("rev-parse", "--verify", "-q", f"refs/heads/{target}"):
        fail(422, "Reference does not exist")
    cur = git("rev-parse", f"refs/heads/{target}")
    if not force and not git_ok("merge-base", "--is-ancestor", cur, sha):
        fail(422, "Update is not a fast forward")
    git("update-ref", f"refs/heads/{target}", sha)
    emit({"ref": f"refs/heads/{target}", "object": {"sha": sha}})


def ref_post(ref, sha):
    if git_ok("rev-parse", "--verify", "-q", ref):
        fail(422, "Reference already exists")
    git("update-ref", ref, sha)
    emit({"ref": ref, "object": {"sha": sha}})


def blob_post(content, encoding):
    raw = base64.b64decode(content) if encoding == "base64" else content.encode()
    emit({"sha": git("hash-object", "-w", "--stdin", input=raw)})


def tree_post(base_tree, entries):
    # update-index insists on a work tree even in a bare repo; an empty temp dir satisfies it.
    with tempfile.NamedTemporaryFile(prefix="fake-gh-index.") as idx, tempfile.TemporaryDirectory() as wt:
        env = dict(os.environ, GIT_INDEX_FILE=idx.name, GIT_WORK_TREE=wt)

        def g(*a):
            r = subprocess.run(["git", "-C", REPO, *a], capture_output=True, env=env)
            if r.returncode != 0:
                fail(500, r.stderr.decode().strip())
            return r.stdout.decode().strip()

        g("read-tree", base_tree)
        for e in entries:
            if e.get("sha") is None:
                g("update-index", "--force-remove", "--", e["path"])
            else:
                g("update-index", "--add", "--cacheinfo", f"{e['mode']},{e['sha']},{e['path']}")
        emit({"sha": g("write-tree")})


def commit_get(sha):
    emit({"sha": sha, "tree": {"sha": git("rev-parse", f"{sha}^{{tree}}")}})


def commit_post(message, tree, parents):
    env = dict(os.environ, GIT_AUTHOR_NAME="fake gh", GIT_AUTHOR_EMAIL="gh@example.com",
               GIT_COMMITTER_NAME="fake gh", GIT_COMMITTER_EMAIL="gh@example.com")
    cmd = ["git", "-C", REPO, "commit-tree", tree]
    for p in parents:
        cmd += ["-p", p]
    r = subprocess.run(cmd, capture_output=True, input=message.encode(), env=env)
    if r.returncode != 0:
        fail(500, r.stderr.decode().strip())
    emit({"sha": r.stdout.decode().strip()})


m = re.match(r"repos/[^/]+/[^/]+/git/(.*)$", path)
if not m:
    fail(404, f"unhandled path {path}")
rest = m.group(1)
if method == "GET" and rest.startswith("ref/heads/"):
    ref_get(rest[len("ref/heads/"):])
elif method == "PATCH" and rest.startswith("refs/heads/"):
    ref_patch(rest[len("refs/heads/"):], body["sha"], bool(body.get("force")))
elif method == "POST" and rest == "refs":
    ref_post(body["ref"], body["sha"])
elif method == "POST" and rest == "blobs":
    blob_post(body["content"], body.get("encoding", "utf-8"))
elif method == "POST" and rest == "trees":
    tree_post(body["base_tree"], body["tree"])
elif method == "GET" and rest.startswith("commits/"):
    commit_get(rest[len("commits/"):])
elif method == "POST" and rest == "commits":
    commit_post(body["message"], body["tree"], body.get("parents", []))
else:
    fail(404, f"unhandled {method} {path}")
