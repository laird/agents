#!/usr/bin/env python3
"""Publish a local branch through the GitHub Git Data API.

Fallback for when the git transport is blocked but api.github.com is reachable
(e.g. a TLS-intercepting proxy that rejects git-receive-pack with HTTP 403
while leaving fetch and the REST API working).

Recreates the branch content server-side: blob -> tree (patched onto the
remote branch's current commit) -> commit -> compare-and-swap ref update, then
verifies the published commit carries exactly the intended tree.

    api-push.py <local-ref> [--target <remote-branch>] [--base <ref>]
                [--repo owner/name] [--message <msg>] [--tree <sha>]

The ref update is conditional: the new commit's parent is the remote branch's
current sha and the PATCH is sent with force=false, so GitHub rejects it (422)
when the branch moved in between. On 422 the remote is re-read and the commit
rebuilt, up to five times. A remote tip the local branch does not contain is
refused rather than overwritten: the caller must re-sync first.

--tree pins the tree the caller gated. The push is refused when the local ref
no longer resolves to it, and verification compares the published commit's
tree to the pin, not to whatever the local ref resolves to now.

--base is used only when the target branch does not exist yet.

Exit status is 0 only when the remote branch contains the new commit and that
commit's tree is the intended one, so callers can safely gate an issue-close
on this.

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
CAS_ATTEMPTS = 5


def git(*args, binary=False):
    r = subprocess.run(["git", *args], capture_output=True, check=True)
    return r.stdout if binary else r.stdout.decode().strip()


def git_ok(*args):
    return subprocess.run(["git", *args], capture_output=True).returncode == 0


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
    status = git("diff", "--name-status", "--no-renames", f"{base}..{branch}")
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


def remote_ref_sha(repo, target):
    """Current sha of refs/heads/<target> on the remote, or None when it does not exist."""
    try:
        return gh_api(f"repos/{repo}/git/ref/heads/{target}", jq=".object.sha") or None
    except RuntimeError:
        return None


def ensure_local(sha, target):
    """Make sure the remote commit is in the local object store so git can diff against it."""
    if git_ok("cat-file", "-e", f"{sha}^{{commit}}"):
        return True
    subprocess.run(["git", "fetch", "origin", sha, "--quiet"], capture_output=True)
    if not git_ok("cat-file", "-e", f"{sha}^{{commit}}"):
        subprocess.run(["git", "fetch", "origin", f"refs/heads/{target}", "--quiet"], capture_output=True)
    return git_ok("cat-file", "-e", f"{sha}^{{commit}}")


def remote_is_behind(remote_sha, branch):
    """True when publishing branch's tree over remote_sha loses nothing.

    The remote tip is contained when it is an ancestor of the branch, or when
    its tree is the tree of some commit in the branch's history: a commit this
    script created earlier is a squash the branch never fetched, yet the branch
    carries every change it holds.
    """
    if git_ok("merge-base", "--is-ancestor", remote_sha, branch):
        return True
    remote_tree = git("rev-parse", f"{remote_sha}^{{tree}}")
    return remote_tree in git("log", "--format=%T", branch).split()


def verify(repo, commit, want_tree, target):
    """Confirm the remote branch contains our commit and that commit carries the intended tree.

    Compares tree OIDs — the only check that actually proves the content
    landed. An exit status, or a --dry-run, proves nothing. Ancestry rather
    than equality with the branch tip, because a sibling may land on top of
    us between the PATCH and this fetch.
    """
    subprocess.run(
        ["git", "fetch", "origin", f"refs/heads/{target}", "--quiet"],
        capture_output=True,
    )
    on_branch = git_ok("merge-base", "--is-ancestor", commit, "FETCH_HEAD")
    got_tree = git("rev-parse", f"{commit}^{{tree}}") if git_ok("cat-file", "-e", f"{commit}^{{commit}}") else ""
    return on_branch and got_tree == want_tree, got_tree


def push(branch, base, repo, message, target=None, tree_pin=None):
    target = target or branch
    local_tree = git("rev-parse", f"{branch}^{{tree}}")
    want_tree = tree_pin or local_tree
    if local_tree != want_tree:
        print(f"api-push: {branch} now resolves to tree {local_tree[:8]}, not the gated tree "
              f"{want_tree[:8]}; refusing to publish an untested tree", file=sys.stderr)
        return 1

    ref = f"refs/heads/{target}"
    for attempt in range(1, CAS_ATTEMPTS + 1):
        remote_sha = remote_ref_sha(repo, target)
        if remote_sha:
            if not ensure_local(remote_sha, target):
                print(f"api-push: cannot fetch origin/{target} ({remote_sha[:8]}) to diff against", file=sys.stderr)
                return 1
            if git("rev-parse", f"{remote_sha}^{{tree}}") == want_tree:
                print(f"api-push: origin/{target} already carries tree {want_tree[:8]}; nothing to publish")
                return 0
            if not remote_is_behind(remote_sha, branch):
                print(f"api-push: origin/{target} is at {remote_sha[:8]}, which {branch} does not contain; "
                      f"re-sync onto it and retry instead of overwriting it", file=sys.stderr)
                return 1
            base_sha = remote_sha
        else:
            base_sha = git("rev-parse", base)

        entries = tree_entries(repo, branch, base_sha)
        if not entries:
            print(f"api-push: {branch} has no changes against {base_sha[:8]}", file=sys.stderr)
            return 1
        base_tree = json.loads(gh_api(f"repos/{repo}/git/commits/{base_sha}"))["tree"]["sha"]
        tree = json.loads(
            gh_api(f"repos/{repo}/git/trees", "POST", {"base_tree": base_tree, "tree": entries})
        )["sha"]
        if tree != want_tree:
            print(f"api-push: server-side tree {tree[:8]} != intended tree {want_tree[:8]}; not updating {ref}",
                  file=sys.stderr)
            return 1
        commit = json.loads(
            gh_api(
                f"repos/{repo}/git/commits",
                "POST",
                {"message": message, "tree": tree, "parents": [base_sha]},
            )
        )["sha"]

        try:
            if remote_sha:
                gh_api(f"repos/{repo}/git/refs/heads/{target}", "PATCH", {"sha": commit, "force": False})
            else:
                gh_api(f"repos/{repo}/git/refs", "POST", {"ref": ref, "sha": commit})
        except RuntimeError as e:
            if "422" in str(e) and attempt < CAS_ATTEMPTS:
                print(f"api-push: {ref} moved under us (attempt {attempt}/{CAS_ATTEMPTS}); re-reading it")
                continue
            raise

        ok, got_tree = verify(repo, commit, want_tree, target)
        if not ok:
            print(
                f"api-push: VERIFICATION FAILED for {target} — "
                f"commit {commit[:8]} tree {got_tree or '<missing>'} != intended tree {want_tree}, "
                f"or the commit is not on origin/{target}",
                file=sys.stderr,
            )
            return 1
        print(f"api-push: published {branch} -> {target} as {commit[:8]} "
              f"(tree {want_tree[:8]} verified)")
        return 0
    print(f"api-push: {ref} kept moving; gave up after {CAS_ATTEMPTS} attempts", file=sys.stderr)
    return 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("branch")
    ap.add_argument("--target", default=None,
                    help="remote branch to update (default: same name as local ref)")
    ap.add_argument("--base", default="origin/master",
                    help="parent commit when the target branch does not exist yet")
    ap.add_argument("--repo", default=None)
    ap.add_argument("--message", default=None)
    ap.add_argument("--tree", default=None,
                    help="tree sha the caller gated; refuse and verify against it")
    a = ap.parse_args()
    repo = a.repo or infer_repo()
    message = a.message or git("log", "-1", "--format=%B", a.branch)
    try:
        return push(a.branch, a.base, repo, message, a.target, a.tree)
    except (RuntimeError, subprocess.CalledProcessError) as e:
        print(f"api-push: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
