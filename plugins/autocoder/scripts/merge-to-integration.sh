#!/bin/bash
# merge-to-integration.sh — land a completed feature/enhancement branch on the shared
# integration branch (default: main) in a way that is safe for parallel git worktrees.
#
# WHY THIS EXISTS:
#   The /fix auto-merge step used to do `git checkout "$PARENT_BRANCH"; git merge; git push`,
#   where PARENT_BRANCH = the branch the worktree was currently on. In a parallel-worktree
#   swarm each worktree sits on its own `main-wt-N` branch (git forbids checking out `main`
#   in two worktrees at once), so fixes got merged into and pushed to per-worktree branches
#   and NEVER reached `main`. Work fragmented across main-wt-1/2/3 and was never integration-
#   tested together.
#
#   This helper instead lands the work on origin/<integration-branch> WITHOUT checking out
#   that branch locally (so it never contends with other worktrees), re-runs the test suite
#   on the combined tree, and pushes with a fetch+merge+retry loop to survive sibling workers
#   racing to push. Conflicts escalate to a human label instead of stranding work.
#
#   #1821: this used to do all of that IN the caller's own worktree — `git checkout
#   "$FEATURE"` right here, then fetch/merge/test/push in place. merge-launch.sh runs this
#   detached (#1693) so the caller can move on immediately; in practice the /fix loop reused
#   that same worktree for the NEXT issue's branch before this finished, so N gates ended up
#   sharing one working tree, each `git checkout`-ing a different branch into it mid-flight.
#   One gate's test run and push could observe (and push) a DIFFERENT branch's tree than the
#   one it was asked to verify — exactly the failure PUSH & MERGE CONTRACT exists to prevent.
#   The fix is isolation, not serialization: do all of this in a throwaway `git worktree add`
#   keyed to $ISSUE_NUM, so nothing another /fix iteration does to the caller's own checkout
#   can touch it. The throwaway worktree is removed unconditionally on exit — it exists only
#   to get this fix's tree tested and pushed, never to persist.
#
# USAGE:
#   merge-to-integration.sh --feature <branch> --issue <num> \
#     [--feature-sha <sha>] [--integration <branch>] [--test-cmd "<cmd>"]
#
#   --feature-sha pins the exact commit to test/push, resolved by the caller before anything
#   could move the branch out from under it (merge-launch.sh does this). When omitted, this
#   script resolves $FEATURE itself in the directory it was started from — sufficient for
#   direct/manual invocations, but exactly the lazy resolution #1821 exists to avoid, so
#   every caller in this repo passes --feature-sha.
#
# Returns:
#   0  merged + pushed to <integration>
#   1  conflict, push failure, or setup failure (issue is labelled needs-clarification on conflict)
#   2  tests failed on the integrated tree

set -uo pipefail

FEATURE=""
FEATURE_SHA=""
ISSUE_NUM=""
INTEGRATION_BRANCH="main"
TEST_CMD=""

while [ $# -gt 0 ]; do
  case "$1" in
    --feature)     FEATURE="$2"; shift 2 ;;
    --feature-sha) FEATURE_SHA="$2"; shift 2 ;;
    --issue)       ISSUE_NUM="$2"; shift 2 ;;
    --integration) INTEGRATION_BRANCH="${2:-main}"; shift 2 ;;
    --test-cmd)    TEST_CMD="$2"; shift 2 ;;
    *) echo "merge-to-integration.sh: unknown arg '$1'" >&2; exit 1 ;;
  esac
done

if [ -z "$FEATURE" ] || [ -z "$ISSUE_NUM" ]; then
  echo "merge-to-integration.sh: --feature and --issue are required" >&2
  exit 1
fi
: "${INTEGRATION_BRANCH:=main}"

# Capture the directory we were started in BEFORE doing anything else. This is the caller's
# worktree — the source of truth for "where is $FEATURE's work" when no --feature-sha was
# given, and the source of node_modules et al. we hardlink into the throwaway worktree below.
# It is deliberately not assumed to still be checked out to $FEATURE by the time we act on it.
CALLER_DIR="$(pwd)"

# issue_update / issue_comment live in the shared issue backend layer next to this script.
_MTI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=issue-fns.sh
source "${_MTI_DIR}/issue-fns.sh"

_escalate_conflict() {
  echo "❌ Merge conflict integrating '${INTEGRATION_BRANCH}' into ${FEATURE}."
  echo "   Aborting the merge and escalating issue #${ISSUE_NUM} for human resolution."
  git merge --abort 2>/dev/null || true
  issue_update "$ISSUE_NUM" --remove-label "working" 2>/dev/null || true
  issue_update "$ISSUE_NUM" --add-label "needs-clarification" 2>/dev/null || true
  issue_comment "$ISSUE_NUM" --body "⚠️ **Auto-merge to \`${INTEGRATION_BRANCH}\` hit a conflict** on branch \`${FEATURE}\` and needs manual resolution. The fix is committed on \`${FEATURE}\`; resolve against \`${INTEGRATION_BRANCH}\` and push, then close this issue." 2>/dev/null || true
  exit 1
}

# Resolve the exact commit to test/push. Prefer the SHA the caller pinned before we started;
# fall back to resolving $FEATURE in CALLER_DIR for direct invocations that skip --feature-sha.
if [ -z "$FEATURE_SHA" ]; then
  FEATURE_SHA=$(git -C "$CALLER_DIR" rev-parse "$FEATURE" 2>/dev/null || echo "")
fi
if [ -z "$FEATURE_SHA" ]; then
  echo "❌ Could not resolve '${FEATURE}' to a commit (no --feature-sha given and the branch is not in ${CALLER_DIR})." >&2
  exit 1
fi

# Isolated throwaway worktree (#1821) — keyed by issue number, matching the existing
# /tmp/autocoder-merge-<issue>.* convention (only one worker holds an issue's `working`
# lock at a time, so this is unique per in-flight merge). Never persists past this run.
WORKTREE_DIR="/tmp/autocoder-merge-worktree-${ISSUE_NUM}"
git -C "$CALLER_DIR" worktree remove --force "$WORKTREE_DIR" 2>/dev/null || true
rm -rf "$WORKTREE_DIR" 2>/dev/null || true
git -C "$CALLER_DIR" worktree prune 2>/dev/null || true

# --detach on the raw SHA (not the branch name) is required: $FEATURE is very likely still
# checked out in $CALLER_DIR, and git refuses to check out the same branch in two worktrees.
# A detached checkout of its tip commit carries the identical tree without that restriction.
if ! git -C "$CALLER_DIR" worktree add --detach "$WORKTREE_DIR" "$FEATURE_SHA"; then
  echo "❌ Could not create isolated worktree for ${FEATURE} (${FEATURE_SHA})." >&2
  exit 1
fi

_cleanup_worktree() {
  git -C "$CALLER_DIR" worktree remove --force "$WORKTREE_DIR" 2>/dev/null || rm -rf "$WORKTREE_DIR" 2>/dev/null || true
  git -C "$CALLER_DIR" worktree prune 2>/dev/null || true
}
trap _cleanup_worktree EXIT

cd "$WORKTREE_DIR" || { echo "❌ Could not enter isolated worktree ${WORKTREE_DIR}." >&2; exit 1; }

# Hardlink every top-level node_modules tree from the caller's checkout into this one so
# --test-cmd doesn't need a fresh install here (a brand-new worktree has none — it's
# git-ignored). Hardlinks share inodes with the source tree: instant, no meaningful extra
# disk. This matches, not upgrades, the trust the pre-#1821 in-place run already placed in
# whatever was installed in the caller's worktree — dependency freshness there is unchanged
# by this fix and out of scope for it.
#
# #1967: `cp -al` across a filesystem boundary (e.g. repo on ext4, $TMPDIR on tmpfs — true
# on some dev boxes) fails per-file with "Invalid cross-device link", succeeding only for
# directories and symlinks. Left unguarded that produces a tree of empty directory shells
# and dangling symlinks while still reporting success, so any --test-cmd needing a tool not
# already resolvable some other way fails with a confusing "not found" that reads as a
# problem with the change under test. Fall back to a real copy on failure — but `cp -a`
# into an already-partially-populated $rel (left behind by the failed `cp -al` attempt)
# nests the copy one level deeper (`$rel/$(basename "$nm")/...`) instead of merging, so the
# destination must be wiped first.
_hardlink_or_copy() {
  local src="$1" rel="$2"
  [ -e "$rel" ] && return 0
  mkdir -p "$(dirname "$rel")" 2>/dev/null || true
  if ! cp -al "$src" "$rel" 2>/dev/null; then
    rm -rf "$rel"
    cp -a "$src" "$rel" 2>/dev/null || true
  fi
}
while IFS= read -r nm; do
  rel="${nm#"$CALLER_DIR"/}"
  _hardlink_or_copy "$nm" "$rel"
done < <(find "$CALLER_DIR" -maxdepth 4 -type d -name node_modules 2>/dev/null | grep -v '/node_modules/.*/node_modules$')

# #1967: `make contracts-check` needs software-factory/packages/*/dist (gitignored build
# output) present, which a fresh worktree never has. Unlike node_modules this must be a
# real copy, never a hardlink: `git worktree add` checks out src/ with a brand-new mtime,
# so a hardlinked dist/ carrying the ORIGINAL build's older mtime reads as stale to
# check-software-factory-sync's freshness comparison even though the content is identical
# — and because a hardlink shares the inode, any process that touched it to fix the mtime
# would touch the caller's own dist/ too. Copy, then touch, so both problems are avoided.
while IFS= read -r d; do
  rel="${d#"$CALLER_DIR"/}"
  [ -e "$rel" ] && continue
  mkdir -p "$(dirname "$rel")" 2>/dev/null || true
  cp -a "$d" "$rel" 2>/dev/null || true
  find "$rel" -exec touch {} + 2>/dev/null || true
done < <(find "$CALLER_DIR/software-factory/packages" -mindepth 2 -maxdepth 2 -type d -name dist 2>/dev/null)

# 1. Bring the latest integration state INTO the feature branch so the eventual push
#    is a fast-forward. Never checks out the integration branch -> worktree-safe.
git fetch origin "$INTEGRATION_BRANCH" || { echo "❌ Could not fetch origin/${INTEGRATION_BRANCH}"; exit 1; }
if ! git merge --no-ff "origin/${INTEGRATION_BRANCH}" \
       -m "Merge origin/${INTEGRATION_BRANCH} into ${FEATURE} (pre-integration sync)"; then
  _escalate_conflict
fi

# 2. Re-run the test suite on the COMBINED tree (this fix + everyone else's merged work).
#    This is the step that catches cross-fix breakage before it lands on the integration branch.
if [ -n "$TEST_CMD" ]; then
  echo "🧪 Re-running tests on the integrated tree: $TEST_CMD"
  bash -c "$TEST_CMD"
  TEST_EXIT=$?
  if [ "$TEST_EXIT" -ne 0 ]; then
    # An exit code >=128 means bash -c's own child was killed by a signal (128+N),
    # not that it ran to completion and reported failure. The in-process OOM
    # detection for the vitest subshell (issue #1250, athena2 scripts/run-changed-
    # tests-gate.sh) cannot fire here: if the OOM killer instead hits this
    # bash -c "$TEST_CMD" invocation itself (an ancestor of the vitest subshell),
    # the process dies before any of that in-process messaging runs, and this
    # script would otherwise report the generic "tests fail" message below --
    # indistinguishable from a real regression (athena2 #1540).
    if [ "$TEST_EXIT" -ge 128 ]; then
      SIGNAL=$((TEST_EXIT - 128))
      echo "::error::merge-to-integration.sh's test invocation was killed by signal ${SIGNAL} (exit ${TEST_EXIT}) -- this matches an ancestor OOM-kill under shared-host memory pressure, not a test failure. Re-run once host load drops; do not treat this as evidence of a regression on '${FEATURE}'."
    else
      echo "❌ Tests fail after integrating '${INTEGRATION_BRANCH}'. NOT pushing."
      echo "   The fix remains on '${FEATURE}'; investigate the interaction with newly merged work."
    fi
    exit 2
  fi
else
  echo "⚠️  No --test-cmd provided; skipping post-integration re-test (not recommended)."
fi

# 3. Push the feature tip to the integration branch. If a sibling worker pushed in the
#    meantime the push is rejected; re-sync and retry.
PUSHED=0
for attempt in 1 2 3 4 5; do
  if git push origin "HEAD:${INTEGRATION_BRANCH}"; then
    PUSHED=1
    break
  fi
  echo "⚠️  Push to '${INTEGRATION_BRANCH}' rejected (a sibling worker likely pushed first); re-syncing (attempt ${attempt}/5)…"
  git fetch origin "$INTEGRATION_BRANCH" || break
  if ! git merge --no-ff "origin/${INTEGRATION_BRANCH}" \
         -m "Re-sync origin/${INTEGRATION_BRANCH} into ${FEATURE} (push retry ${attempt})"; then
    _escalate_conflict
  fi
done

# 3b. If the git transport itself is blocked (e.g. a proxy rejecting
#     git-receive-pack with HTTP 403), retrying cannot help — fall back to
#     publishing through the GitHub API, which reaches api.github.com instead.
if [ "$PUSHED" -ne 1 ]; then
  echo "⚠️  git push failed after 5 attempts — trying the GitHub API fallback…"
  if python3 "${_MTI_DIR}/api-push.py" HEAD \
       --target "$INTEGRATION_BRANCH" \
       --base "origin/${INTEGRATION_BRANCH}" \
       --message "Merge issue #${ISSUE_NUM} (${FEATURE}) into ${INTEGRATION_BRANCH}

Published via the GitHub API because the git transport is blocked."; then
    PUSHED=1
  fi
fi

if [ "$PUSHED" -ne 1 ]; then
  echo "❌ Could not publish to '${INTEGRATION_BRANCH}' (git push and API fallback both failed)."
  echo "   The fix is safe on '${FEATURE}'. NOT closing the issue — nothing landed."
  exit 1
fi

# 3c. Trust nothing: confirm the integration ref actually contains this work.
#     A zero exit status is not proof, and `git push --dry-run` is worse than
#     useless here — it succeeds against a blocked transport because it never
#     sends the pack. Compare the trees.
git fetch origin "$INTEGRATION_BRANCH" --quiet 2>/dev/null || true
LOCAL_TREE=$(git rev-parse "HEAD^{tree}")
REMOTE_TREE=$(git rev-parse "origin/${INTEGRATION_BRANCH}^{tree}" 2>/dev/null || echo "")
if [ -z "$REMOTE_TREE" ] || [ "$LOCAL_TREE" != "$REMOTE_TREE" ]; then
  echo "❌ Publication could not be verified for '${INTEGRATION_BRANCH}'."
  echo "   local tree  ${LOCAL_TREE}"
  echo "   remote tree ${REMOTE_TREE:-<none>}"
  echo "   NOT closing the issue — the tracker must never claim work landed when it did not."
  exit 1
fi

echo "✅ Issue #${ISSUE_NUM} merged into '${INTEGRATION_BRANCH}' and verified (tree ${LOCAL_TREE:0:8})."

# 4. Clean up the feature branch now that its work is on the integration branch.
git push origin --delete "$FEATURE" 2>/dev/null || true
# The throwaway worktree itself is removed by the EXIT trap. Any local $FEATURE branch ref
# in $CALLER_DIR is untouched by this script; the caller's own cleanup (or the next /fix
# run branching fresh from origin/<integration-branch>) handles it.
exit 0
