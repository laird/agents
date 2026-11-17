#!/bin/bash
# feature-ref-fns.sh — resolve a feature branch NAME to the commit that should land.
#
# Why not `git rev-parse "$FEATURE"` (#143): every worktree on a host shares one
# local branch namespace. A stray local `feature/issue-N` — left by an unrelated
# earlier run in a sibling worktree — shadows the work the worker actually pushed
# to origin/feature/issue-N. If that stray branch is already an ancestor of the
# integration branch, the merge job takes its "already landed" path: it reports
# success, closes the issue, and deletes the real remote branch. The real fix
# never lands and nothing errors.
#
# The pushed remote branch is what the worker published and reviewed, so it is
# the source of truth. A local branch is used only when no remote branch of that
# name can be fetched (a direct invocation before any push, or offline fixtures).
#
#   resolve_feature_sha <git-dir> <feature-branch-name>
#     stdout: the commit SHA, or nothing if the name resolves nowhere
#     stderr: a warning when local and remote disagree, or the fetch failed
#     exit:   0 when a SHA was printed, 1 otherwise

resolve_feature_sha() {
  local dir="$1" feature="$2" local_sha="" remote_sha="" tracking
  tracking="refs/remotes/origin/${feature}"

  local_sha=$(git -C "$dir" rev-parse --verify -q "refs/heads/${feature}^{commit}" 2>/dev/null || true)

  if git -C "$dir" remote get-url origin >/dev/null 2>&1; then
    if git -C "$dir" fetch -q origin "+refs/heads/${feature}:${tracking}" 2>/dev/null; then
      remote_sha=$(git -C "$dir" rev-parse --verify -q "${tracking}^{commit}" 2>/dev/null || true)
    elif git -C "$dir" ls-remote --exit-code origin "refs/heads/${feature}" >/dev/null 2>&1; then
      # The branch exists on origin but could not be fetched: refuse to guess
      # from the local namespace, which is exactly the ref that can be stale.
      echo "⚠️  origin/${feature} exists but could not be fetched; not falling back to the local branch." >&2
      return 1
    fi
  fi

  if [ -n "$remote_sha" ]; then
    if [ -n "$local_sha" ] && [ "$local_sha" != "$remote_sha" ]; then
      echo "⚠️  Local branch '${feature}' (${local_sha:0:8}) differs from origin/${feature} (${remote_sha:0:8}); using origin's, which is what was pushed." >&2
    fi
    printf '%s\n' "$remote_sha"
    return 0
  fi

  if [ -n "$local_sha" ]; then
    printf '%s\n' "$local_sha"
    return 0
  fi

  # Not a branch anywhere: accept any other commit-ish (a SHA, a tag), as the
  # plain `git rev-parse "$FEATURE"` this replaces did.
  local other
  other=$(git -C "$dir" rev-parse --verify -q "${feature}^{commit}" 2>/dev/null || true)
  [ -n "$other" ] || return 1
  printf '%s\n' "$other"
}

# delete_feature_branch_if_at <git-dir> <feature-branch-name> <expected-sha>
# Deletes origin/<feature> only while it still points at <expected-sha>. A remote
# branch that moved, or that was never the commit this job landed, is left alone.
delete_feature_branch_if_at() {
  local dir="$1" feature="$2" expect="$3"
  [ -n "$expect" ] || return 1
  git -C "$dir" push -q --force-with-lease="refs/heads/${feature}:${expect}" \
    origin ":refs/heads/${feature}" 2>/dev/null
}
