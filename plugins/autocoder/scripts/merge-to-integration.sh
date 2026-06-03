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
# USAGE:
#   merge-to-integration.sh --feature <branch> --issue <num> \
#     [--integration <branch>] [--test-cmd "<cmd>"]
#
# Assumes the current HEAD is (or can be switched to) <feature>. Returns:
#   0  merged + pushed to <integration>
#   1  conflict or push failure (issue is labelled needs-clarification on conflict)
#   2  tests failed on the integrated tree

set -uo pipefail

FEATURE=""
ISSUE_NUM=""
INTEGRATION_BRANCH="main"
TEST_CMD=""

while [ $# -gt 0 ]; do
  case "$1" in
    --feature)     FEATURE="$2"; shift 2 ;;
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

# Make sure we are on the feature branch that holds the work.
git checkout "$FEATURE" 2>/dev/null || true

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
  if ! bash -c "$TEST_CMD"; then
    echo "❌ Tests fail after integrating '${INTEGRATION_BRANCH}'. NOT pushing."
    echo "   The fix remains on '${FEATURE}'; investigate the interaction with newly merged work."
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

if [ "$PUSHED" -ne 1 ]; then
  echo "❌ Could not push to '${INTEGRATION_BRANCH}' after 5 attempts. The fix is safe on '${FEATURE}'."
  exit 1
fi

echo "✅ Issue #${ISSUE_NUM} merged into '${INTEGRATION_BRANCH}' and pushed."

# 4. Clean up the feature branch now that its work is on the integration branch.
git push origin --delete "$FEATURE" 2>/dev/null || true
# Leave HEAD on the feature branch locally; the next /fix run branches fresh from
# origin/<integration-branch>, so the stale local branch is harmless and gc-able.
exit 0
