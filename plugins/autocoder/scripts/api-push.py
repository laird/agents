#!/usr/bin/env python3
"""Publish a local branch through the GitHub Git Data API.

Fallback for when the git transport is blocked but api.github.com is reachable
(e.g. a TLS-intercepting proxy that rejects git-receive-pack with HTTP 403
while leaving fetch and the REST API working).

Recreates the branch content server-side: blob -> tree (patched onto a base)
-> commit -> ref update, then verifies the published ref is byte-identical to
the local branch.

    api-push.py <local-ref> [--target <remote-branch>] [--base <ref>]
                [--repo owner/name] [--message <msg>]

Exit status is 0 only when the remote ref is verified identical to the local
branch, so callers can safely gate an issue-close on this.

Deliberate limitations (see issue #23):
  - Squashes the branch into a single commit on the remote. Fine for the
    one-issue-one-branch flow; it loses history on long branches.
  - API-created commits are not GPG-signed.
"""
import argparse
import base64
import json
import subprocess
import sys

MODE_BLOB = "100644"
MODE_EXEC = "100755"
MODE_SYMLINK = "120000"


def git(*args, binary=False):
    r = subprocess.run(["git", *args], capture_output=True, check=True)
    return r.stdout if binary else r.stdout.decode().strip()


def gh_api(path, method="GET", body=None, jq=None):
    cmd = ["gh", "api", path, "-X", method]
    if jq:
        cmd += ["--jq", jq]
    if body is not None:
        cmd += ["--input", "-"]
        r = subprocess.run(
            cmd, input=json.dumps(body), capture_output=True, text=True
        )
    else:
        r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"gh api {method} {path} failed: {r.stderr.strip()}")
    return r.stdout.strip()


def infer_repo():
    """owner/name from the origin remote, rather than hardcoding."""
    url = git("remote", "get-url", "origin")
    if url.startswith("git@"):
        path = url.split(":", 1)[1]
    else:
        path = url.split("github.com/", 1)[-1]
    return path[:-4] if path.endswith(".git") else path


def tree_entries(repo, branch, base):
    """Build Git Data API tree entries for branch's diff against base.

    Modes come from git itself, so the executable bit and symlinks survive —
    something the GraphQL createCommitOnBranch mutation cannot express.
    """
    entries = []
    status = git("diff", "--name-status", f"{base}..{branch}")
    for line in status.splitlines():
        if not line.strip():
            continue
        parts = line.split("\t")
        code, path = parts[0], parts[-1]
        if code.startswith("D"):
            # A null sha deletes the path from the base tree.
            entries.append({"path": path, "mode": MODE_BLOB, "type": "blob", "sha": None})
            continue
        mode = git("ls-tree", branch, "--", path).split()[0]
        if mode not in (MODE_BLOB, MODE_EXEC, MODE_SYMLINK):
            mode = MODE_BLOB
        content = git("show", f"{branch}:{path}", binary=True)
        # base64 so binary and non-UTF-8 content survive intact
        sha = json.loads(
            gh_api(
                f"repos/{repo}/git/blobs",
                "POST",
                {"content": base64.b64encode(content).decode("ascii"), "encoding": "base64"},
            )
        )["sha"]
        entries.append({"path": path, "mode": mode, "type": "blob", "sha": sha})
    return entries


def verify(repo, branch, target=None):
    """Confirm the published ref is byte-identical to the local branch.

    Compares tree OIDs — the only check that actually proves the content
    landed. An exit status, or a --dry-run, proves nothing.
    """
    target = target or branch
    subprocess.run(
        ["git", "fetch", "origin", f"refs/heads/{target}", "--quiet"],
        capture_output=True,
    )
    local = git("rev-parse", f"{branch}^{{tree}}")
    remote = git("rev-parse", "FETCH_HEAD^{tree}")
    return local == remote, local, remote


def push(branch, base, repo, message, target=None):
    target = target or branch
    base_sha = git("rev-parse", base)
    entries = tree_entries(repo, branch, base)
    if not entries:
        print(f"api-push: {branch} has no changes against {base}", file=sys.stderr)
        return 1

    base_tree = json.loads(gh_api(f"repos/{repo}/git/commits/{base_sha}"))["tree"]["sha"]
    tree = json.loads(
        gh_api(f"repos/{repo}/git/trees", "POST", {"base_tree": base_tree, "tree": entries})
    )["sha"]
    commit = json.loads(
        gh_api(
            f"repos/{repo}/git/commits",
            "POST",
            {"message": message, "tree": tree, "parents": [base_sha]},
        )
    )["sha"]

    ref = f"refs/heads/{target}"
    try:
        gh_api(f"repos/{repo}/git/refs/heads/{target}")
        gh_api(f"repos/{repo}/git/refs/heads/{target}", "PATCH", {"sha": commit, "force": True})
    except RuntimeError:
        gh_api(f"repos/{repo}/git/refs", "POST", {"ref": ref, "sha": commit})

    ok, local, remote = verify(repo, branch, target)
    if not ok:
        print(
            f"api-push: VERIFICATION FAILED for {target} — "
            f"local tree {local} != remote tree {remote}",
            file=sys.stderr,
        )
        return 1
    print(f"api-push: published {branch} -> {target} as {commit[:8]} "
          f"(tree {local[:8]} verified)")
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("branch")
    ap.add_argument("--target", default=None,
                    help="remote branch to update (default: same name as local ref)")
    ap.add_argument("--base", default="origin/master")
    ap.add_argument("--repo", default=None)
    ap.add_argument("--message", default=None)
    a = ap.parse_args()
    repo = a.repo or infer_repo()
    message = a.message or git("log", "-1", "--format=%B", a.branch)
    try:
        return push(a.branch, a.base, repo, message, a.target)
    except (RuntimeError, subprocess.CalledProcessError) as e:
        print(f"api-push: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
