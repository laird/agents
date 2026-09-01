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
#   racing to push. A merge conflict is left ON DISK (not aborted) for the caller — the /fix
#   worker that just wrote this fix, sharing this same checkout — to resolve directly with
#   full context; only a caller that gives up applies the human-review label (#1766: this
#   script used to abort+escalate to needs-clarification on the FIRST conflict, before the
#   worker that could trivially resolve it ever got a look).
#
# USAGE:
#   merge-to-integration.sh --feature <branch> --issue <num> \
#     [--integration <branch>] [--test-cmd "<cmd>"]
#
# Assumes the current HEAD is (or can be switched to) <feature>. Returns:
#   0  merged + pushed to <integration>
#   1  push failure after a successful merge (no conflict — see exit 3 for that)
#   2  tests failed on the integrated tree
#   3  merge conflict — left unresolved in the worktree (NOT aborted, NO label change) for
#      the caller to resolve directly and re-launch; the caller escalates to
#      needs-clarification itself only if ITS OWN resolution attempt also fails

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

_advise_conflict() {
  echo "⚠️  Merge conflict integrating '${INTEGRATION_BRANCH}' into ${FEATURE}."
  echo "   Leaving the conflict ON DISK (not aborting) for the caller to resolve directly."
  # Deliberately NOT: git merge --abort, NOT touching the 'working' label, NOT adding
  # needs-clarification. The caller (this same worktree's /fix worker) just wrote this
  # fix and can usually resolve a mechanical conflict itself; a label change here would
  # be visible before that attempt even starts (#1766).
  issue_comment "$ISSUE_NUM" --body "⚠️ **Auto-merge to \`${INTEGRATION_BRANCH}\` hit a conflict** on branch \`${FEATURE}\`. The fix is committed there; the conflict has been left unresolved in the worktree for direct resolution. This is advisory only — no label change yet. If resolution doesn't succeed shortly, the issue will be escalated with \`needs-clarification\`." 2>/dev/null || true
  exit 3
}

# Make sure we are on the feature branch that holds the work.
git checkout "$FEATURE" 2>/dev/null || true

# 1. Bring the latest integration state INTO the feature branch so the eventual push
#    is a fast-forward. Never checks out the integration branch -> worktree-safe.
git fetch origin "$INTEGRATION_BRANCH" || { echo "❌ Could not fetch origin/${INTEGRATION_BRANCH}"; exit 1; }
if ! git merge --no-ff "origin/${INTEGRATION_BRANCH}" \
       -m "Merge origin/${INTEGRATION_BRANCH} into ${FEATURE} (pre-integration sync)"; then
  _advise_conflict
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
    _advise_conflict
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
# Leave HEAD on the feature branch locally; the next /fix run branches fresh from
# origin/<integration-branch>, so the stale local branch is harmless and gc-able.
exit 0
