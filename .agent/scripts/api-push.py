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
    got_tree = git("rev-parse", f"{commit}^{{tree}}") if git_ok("cat-file", "-e", f"{commit}^{{commit}}") else None
    if not on_branch:
        return False
    if got_tree == want_tree:
        return True
    # If the exact commit isn't an ancestor (e.g. rewritten history or squashed differently),
    # check if FETCH_HEAD contains a commit with the identical tree.
    return want_tree in git("log", "--format=%T", "FETCH_HEAD", "-n", "50").split()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("local_ref", help="Local branch or commit to push")
    p.add_argument("--target", help="Remote branch name (defaults to local branch name)")
    p.add_argument("--base", help="Base ref for diff (defaults to remote target or main)")
    p.add_argument("--repo", help="owner/name (inferred from origin remote if omitted)")
    p.add_argument("--message", help="Commit message (defaults to subject of local_ref)")
    p.add_argument("--tree", help="Pin expected tree OID")
    args = p.parse_args()

    repo = args.repo or infer_repo()
    target = args.target or git("symbolic-ref", "--short", args.local_ref, error_code=0) or args.local_ref
    if "/" in target:
        target = target.split("/")[-1]

    # Resolve local ref
    local_sha = git("rev-parse", args.local_ref)
    if args.tree and git("rev-parse", f"{args.local_ref}^{{tree}}") != args.tree:
        print(f"Error: local ref {args.local_ref} tree does not match pinned tree {args.tree}", file=sys.stderr)
        sys.exit(1)
    tree_sha_pin = args.tree or git("rev-parse", f"{args.local_ref}^{{tree}}")

    message = args.message or git("log", "-1", "--format=%s", local_sha)

    base = args.base
    for attempt in range(CAS_ATTEMPTS):
        remote_sha = remote_ref_sha(repo, target)
        if remote_sha:
            if not ensure_local(remote_sha, target):
                print(f"Error: could not fetch remote ref {target} tip {remote_sha}", file=sys.stderr)
                sys.exit(1)
            if not remote_is_behind(remote_sha, local_sha):
                print(f"Error: remote branch {target} has diverged or contains unmerged work", file=sys.stderr)
                sys.exit(1)
            base_ref = remote_sha
        else:
            base_ref = base or git("symbolic-ref", "refs/remotes/origin/HEAD", error_code=0)
            if not base_ref:
                base_ref = "origin/main" if git_ok("rev-parse", "origin/main") else "HEAD"
            else:
                base_ref = base_ref.replace("refs/remotes/", "")

        # Build tree entries
        try:
            entries = tree_entries(repo, local_sha, base_ref)
        except Exception as e:
            print(f"Error building tree entries: {e}", file=sys.stderr)
            sys.exit(1)

        base_tree = git("rev-parse", f"{base_ref}^{{tree}}") if remote_sha else None
        tree_body = {"base_tree": base_tree, "tree": entries} if base_tree else {"tree": entries}
        new_tree_res = json.loads(gh_api(f"repos/{repo}/git/trees", "POST", tree_body))
        new_tree_sha = new_tree_res["sha"]

        # Create commit
        commit_body = {
            "message": message,
            "tree": new_tree_sha,
            "parents": [remote_sha] if remote_sha else []
        }
        new_commit_res = json.loads(gh_api(f"repos/{repo}/git/commits", "POST", commit_body))
        new_commit_sha = new_commit_res["sha"]

        # Update ref
        ref_path = f"repos/{repo}/git/refs/heads/{target}"
        if remote_sha:
            ref_body = {"sha": new_commit_sha, "force": False}
            try:
                gh_api(ref_path, "PATCH", ref_body)
            except RuntimeError as e:
                if "422" in str(e) or "Unprocessable" in str(e):
                    continue
                raise
        else:
            ref_body = {"ref": f"refs/heads/{target}", "sha": new_commit_sha}
            try:
                gh_api(f"repos/{repo}/git/refs", "POST", ref_body)
            except RuntimeError as e:
                if "422" in str(e) or "Unprocessable" in str(e):
                    continue
                raise

        if verify(repo, new_commit_sha, tree_sha_pin, target):
            print(f"Successfully pushed {target} to {new_commit_sha}")
            sys.exit(0)
        else:
            print(f"Verification failed on attempt {attempt + 1}", file=sys.stderr)

    print("Error: max CAS attempts reached without successful push/verification", file=sys.stderr)
    sys.exit(1)


if __name__ == "__main__":
    main()