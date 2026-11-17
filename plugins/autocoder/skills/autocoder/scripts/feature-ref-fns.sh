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

# shellcheck source=git-net-fns.sh
source "$(dirname "${BASH_SOURCE[0]}")/git-net-fns.sh"

resolve_feature_sha() {
  local dir="$1" feature="$2" local_sha="" remote_sha="" tracking
  tracking="refs/remotes/origin/${feature}"

  # Only a well-formed branch name is looked up as a branch. Anything else (a raw
  # SHA is well-formed too, harmlessly) must not reach the fetch refspec, where a
  # glob like `keep/*` would become a wildcard that force-updates every matching
  # remote-tracking ref.
  local is_branch=0
  git check-ref-format "refs/heads/${feature}" 2>/dev/null && is_branch=1

  [ "$is_branch" -eq 1 ] && \
    local_sha=$(git -C "$dir" rev-parse --verify -q "refs/heads/${feature}^{commit}" 2>/dev/null || true)

  if [ "$is_branch" -eq 1 ] && git -C "$dir" remote get-url origin >/dev/null 2>&1; then
    # Bounded (#220): a stalled connection must refuse, not hang the worker.
    local fetch_rc=0
    git_net -C "$dir" fetch -q origin "+refs/heads/${feature}:${tracking}" 2>/dev/null || fetch_rc=$?
    if [ "$fetch_rc" -eq 0 ]; then
      remote_sha=$(git -C "$dir" rev-parse --verify -q "${tracking}^{commit}" 2>/dev/null || true)
    elif git_net_timed_out "$fetch_rc" && [ -n "$local_sha" ]; then
      # Timed out: origin is not answering, so ls-remote would only stall again.
      echo "⚠️  Fetching origin/${feature} timed out after ${AUTOCODER_GIT_TIMEOUT:-60}s; not falling back to the local branch." >&2
      return 1
    else
      # Fall back to the local namespace ONLY when origin answered and has no such
      # branch (ls-remote --exit-code exits 2). Any other failure — origin
      # unreachable, auth, or the branch exists but would not fetch — leaves us
      # unable to tell the pushed work from a stray, so refuse rather than guess.
      local ls_rc=0
      git_net -C "$dir" ls-remote --exit-code origin "refs/heads/${feature}" >/dev/null 2>&1 || ls_rc=$?
      # Only a same-named local branch can be a stray, so only then is refusing
      # needed; a raw SHA or tag has nothing to shadow and resolves below.
      if [ "$ls_rc" -ne 2 ] && [ -n "$local_sha" ]; then
        echo "⚠️  Could not fetch origin/${feature} (ls-remote rc=${ls_rc}); not falling back to the local branch." >&2
        return 1
      fi
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
    echo "ℹ️  origin has no branch '${feature}'; using the local branch (${local_sha:0:8})." >&2
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
  git_net_long -C "$dir" push -q --force-with-lease="refs/heads/${feature}:${expect}" \
    origin ":refs/heads/${feature}" 2>/dev/null
}
