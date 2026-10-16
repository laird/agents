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
# GATE COST:
#   In 938 measured runs 41% of pushes lost the race to a sibling, and every lost race used
#   to re-run the full gate (8-30 minutes) on the re-synced tree. Three things cut that:
#
#   - Every gate run goes through gate-cache-fns.sh, keyed by <tree, command>. A tree this
#     host already recorded as passing (this worker earlier, or a sibling) is not run again.
#   - A rejected push re-gates only when the incoming commits overlap this change: a file
#     this fix touched, or a global path (lockfiles, manifests, build config, CI). A disjoint
#     re-sync is pushed as-is; the success line then names the gated tree and the published
#     tree separately instead of claiming the published tree was verified.
#       AUTOCODER_GATE_GLOBAL_PATHS  space-separated bash globs, matched against each
#         incoming path and its basename. Default:
#         package.json package-lock.json pnpm-lock.yaml yarn.lock Makefile Dockerfile*
#         tsconfig*.json *.config.* .github/* CLAUDE.md AGENTS.md
#       AUTOCODER_SCOPED_REGATE  default 1; 0 re-gates every re-sync that brought in work,
#         for a repo that wants the integration branch itself kept strictly green.
#   - When the gate fails on the integrated tree, origin/<integration> is gated ALONE in a
#     second throwaway worktree. If the base passes, this change broke it: exit 2. If the
#     base fails too, the integration branch is red independent of this change, so the work
#     is pushed anyway and the issue is told so (the post-merge sentinel owns red main).
#       AUTOCODER_MERGE_ON_RED_BASE  default 1; 0 restores exit 2 on a red base.
#
# USAGE:
#   merge-to-integration.sh --feature <branch> --issue <num> \
#     [--feature-sha <sha>] [--integration <branch>] [--test-cmd "<cmd>"] \
#     [--summary-file <path>] [--own-issue]
#
#   --test-cmd is the gate. When omitted it is resolved from the repo's AGENTS.md (falling
#   back to CLAUDE.md), '### Regression Test Suite' fenced block. If that yields nothing the
#   merge is refused before any fetch/merge/push, unless the change is documents-only.
#
#   --feature-sha pins the exact commit to test/push, resolved by the caller before anything
#   could move the branch out from under it (merge-launch.sh does this). When omitted, this
#   script resolves $FEATURE itself in the directory it was started from — sufficient for
#   direct/manual invocations, but exactly the lazy resolution #1821 exists to avoid, so
#   every caller in this repo passes --feature-sha.
#
# OWNING THE ISSUE:
#   --own-issue makes this job the owner of the issue from the moment it starts, so the
#   worker that launched it can move on instead of polling for 8-30 minutes. The worker
#   owns open → working (claim); this job owns everything after, through the backend's
#   lifecycle verbs (issue-fns.sh: handoff, park, escalate, requeue), never raw labels:
#     first act, before anything that can fail
#        → issue_handoff: `working` → `merging`. The worker writes NO label after the
#          launch returns; its late writes used to overwrite this job's fast-path outcome.
#     landed, gate passed on the published tree (or docs-only), and verify-shipped.sh
#     says the commit is on the ship branch
#        → issue_close with "✅ Issue Resolved" and the --summary-file contents
#     landed on any other basis (disjoint re-sync, red base) or not on the ship branch
#        → issue_park: `awaiting-integration` with a comment naming the landed commit
#          and the gated trees. The post-merge sentinel closes a parked issue once its
#          landed commit is on a green tip. Only `tested` and `docs-only` may close.
#     exit 1 / exit 2 before anything was pushed (conflict, gate failure, publish failure)
#        → issue_escalate --label needs-clarification, comment with the reason and the
#          last 40 lines of gate output
#     internal error AFTER the push succeeded
#        → issue_park (the work is on the branch; nothing is lost), never an escalation
#   Every transition converges: an issue that is already closed is left alone (the whole
#   run is skipped and a stale `merging` is retired), a feature SHA already on
#   origin/<integration> is not merged or gated again, and an issue someone already
#   parked stays parked. Without --own-issue none of this runs and the exit codes below
#   are the only outcome.
#
# PUBLISHED TIPS:
#   After a verified push the landed commit is also published as
#   refs/autocoder/tips/<integration>/<landed-sha>-<issue>, so the sentinel can map a
#   green tip back to the issues it proves. Failure to publish the ref is logged, never
#   fatal.
#
# Returns:
#   0  merged + pushed to <integration>
#   1  conflict, push failure, setup failure, or no test command
#   2  tests failed on the integrated tree and origin/<integration> passes alone

set -uo pipefail

FEATURE=""
FEATURE_SHA=""
ISSUE_NUM=""
INTEGRATION_BRANCH="main"
TEST_CMD=""
SUMMARY_FILE=""
OWN_ISSUE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --feature)      FEATURE="$2"; shift 2 ;;
    --feature-sha)  FEATURE_SHA="$2"; shift 2 ;;
    --issue)        ISSUE_NUM="$2"; shift 2 ;;
    --integration)  INTEGRATION_BRANCH="${2:-main}"; shift 2 ;;
    --test-cmd)     TEST_CMD="$2"; shift 2 ;;
    --summary-file) SUMMARY_FILE="$2"; shift 2 ;;
    --own-issue)    OWN_ISSUE=1; shift ;;
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
# shellcheck source=test-cmd-fns.sh
source "${_MTI_DIR}/test-cmd-fns.sh"
# shellcheck source=gate-cache-fns.sh
source "${_MTI_DIR}/gate-cache-fns.sh"

# `read -a` splits without pathname expansion, so `Dockerfile*` stays a pattern instead of
# becoming whatever Dockerfiles happen to exist in the current directory.
IFS=' ' read -r -a GATE_GLOBAL_PATHS <<< "${AUTOCODER_GATE_GLOBAL_PATHS:-package.json package-lock.json pnpm-lock.yaml yarn.lock Makefile Dockerfile* tsconfig*.json *.config.* .github/* CLAUDE.md AGENTS.md}"

# Gate output is kept so a failure comment can quote it.
GATE_LOG=$(mktemp "${TMPDIR:-/tmp}/autocoder-merge-${ISSUE_NUM}.gate.XXXXXX")
trap 'rm -f "$GATE_LOG"' EXIT

_issue_is_closed() {
  issue_get "$ISSUE_NUM" 2>/dev/null | grep -Eq '"state": *"CLOSED"'
}
_issue_has_label() {
  issue_get "$ISSUE_NUM" 2>/dev/null | grep -Eq "\"name\": *\"$1\""
}

# Set once a push to <integration> has succeeded. From then on a failure is bookkeeping,
# not lost work, and the issue is parked instead of escalated.
PUSHED=0

# Terminal failure, exits with $1. Under --own-issue an issue someone already closed is
# left alone; otherwise it is escalated (nothing landed) or parked (the push landed and
# only this job's bookkeeping failed), with the reason and the gate's tail.
_fail() {
  local code="$1" reason="$2" tail=""
  if [ "$OWN_ISSUE" -eq 1 ] && ! _issue_is_closed; then
    [ -s "$GATE_LOG" ] && tail=$(tail -n 40 "$GATE_LOG")
    tail="${tail:+

Last gate output:
\`\`\`
${tail}
\`\`\`}"
    if [ "$PUSHED" -eq 1 ]; then
      issue_park "$ISSUE_NUM" --comment "⚠️ **Auto-merge to \`${INTEGRATION_BRANCH}\` pushed, then hit an internal error** (exit ${code}): ${reason}

The work from \`${FEATURE}\` is on \`${INTEGRATION_BRANCH}\`; what failed was this job's bookkeeping after the push. Parked under \`awaiting-integration\` for the post-merge sentinel (or a human) to confirm and close.${tail}" 2>/dev/null || true
    else
      issue_escalate "$ISSUE_NUM" --label needs-clarification --comment "❌ **Auto-merge to \`${INTEGRATION_BRANCH}\` failed** (exit ${code}): ${reason}

The fix is committed on \`${FEATURE}\`; nothing from this run landed on \`${INTEGRATION_BRANCH}\`. Labelled \`needs-clarification\` for a human to look at.${tail}" 2>/dev/null || true
    fi
  fi
  exit "$code"
}

_escalate_conflict() {
  echo "❌ Merge conflict integrating '${INTEGRATION_BRANCH}' into ${FEATURE}."
  git merge --abort 2>/dev/null || true
  if [ "$OWN_ISSUE" -eq 1 ] && ! _issue_is_closed; then
    echo "   Aborting the merge and escalating issue #${ISSUE_NUM} for human resolution."
    issue_escalate "$ISSUE_NUM" --label needs-clarification --comment "⚠️ **Auto-merge to \`${INTEGRATION_BRANCH}\` hit a conflict** on branch \`${FEATURE}\` and needs manual resolution. The fix is committed on \`${FEATURE}\`; resolve against \`${INTEGRATION_BRANCH}\` and push, then close this issue." 2>/dev/null || true
  else
    echo "   Aborting the merge. The fix is committed on ${FEATURE}; resolve against ${INTEGRATION_BRANCH} by hand."
  fi
  exit 1
}

# Terminal success under --own-issue. $1 is the landed commit. Only a tree the gate
# passed (tested) or that needs no gate (docs-only) may close the issue, and only when
# verify-shipped.sh says the commit is on the ship branch. Every other landing is parked
# under `awaiting-integration` with PARK_NOTE (set by the publish-basis case below); the
# post-merge sentinel closes a parked issue once its landed commit is on a green tip.
PARK_NOTE=""
_park() {
  issue_park "$ISSUE_NUM" --comment "$1" 2>/dev/null || true
}
_close_or_park() {
  [ "$OWN_ISSUE" -eq 1 ] || return 0
  if _issue_is_closed; then
    echo "ℹ️  Issue #${ISSUE_NUM} is already closed; leaving it alone."
    return 0
  fi
  local landed="$1" summary ship_branch
  summary="Merged \`${FEATURE}\` into \`${INTEGRATION_BRANCH}\`."
  if [ -n "$SUMMARY_FILE" ] && [ -s "$SUMMARY_FILE" ]; then
    summary=$(cat "$SUMMARY_FILE")
  fi
  case "$PUBLISH_BASIS" in
    tested|docs-only|already-landed) ;;
    *)
      _park "⏳ **Landed on \`${INTEGRATION_BRANCH}\` as \`${landed}\`, not closed.** ${PARK_NOTE}

${summary}

Labelled \`awaiting-integration\`; the post-merge sentinel closes this issue once \`${landed}\` is on a green \`${INTEGRATION_BRANCH}\` tip.

🤖 Auto-merge (publish basis: ${PUBLISH_BASIS})"
      echo "⏳ Issue #${ISSUE_NUM} parked under awaiting-integration (${PUBLISH_BASIS}); the sentinel closes it once ${landed:0:8} is on a green tip."
      return 0 ;;
  esac
  if "${_MTI_DIR}/verify-shipped.sh" "$landed"; then
    if issue_close "$ISSUE_NUM" --comment "✅ **Issue Resolved**

${summary}

**Branch**: \`${FEATURE}\` (merged and deleted)

🤖 Auto-resolved by autonomous fix workflow"; then
      issue_update "$ISSUE_NUM" --remove-label "merging" 2>/dev/null || true
      echo "✅ Issue #${ISSUE_NUM} closed."
    else
      _park "⚠️ The work landed on \`${INTEGRATION_BRANCH}\` as \`${landed}\` but the tracker refused to close this issue. Parked under \`awaiting-integration\` for the sentinel or a human to close."
      echo "⚠️  Issue #${ISSUE_NUM} could not be closed; parked under 'awaiting-integration' with the work landed on '${INTEGRATION_BRANCH}'."
    fi
    return 0
  fi
  ship_branch="${CLAUDE_CODE_SHIP_BRANCH:-$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name 2>/dev/null || echo main)}"
  _park "⏳ **Fix complete, not yet shipped — leaving this issue OPEN**

The work is done, committed, and merged to \`${INTEGRATION_BRANCH}\` as \`${landed}\`. It has **not** reached \`${ship_branch}\`, so closing would assert something false.

**To ship**: \`${INTEGRATION_BRANCH}\` must merge to \`${ship_branch}\`.

Labelled \`awaiting-integration\` so it is findable rather than silently reopened as new work.

🤖 Ship gate (issue #35)"
  echo "⏳ Issue #${ISSUE_NUM} left OPEN — merged to ${INTEGRATION_BRANCH} but not on the shipping branch ${ship_branch}"
}

if [ "$OWN_ISSUE" -eq 1 ]; then
  if _issue_is_closed; then
    echo "ℹ️  Issue #${ISSUE_NUM} is already closed; nothing to merge."
    issue_update "$ISSUE_NUM" --remove-label "merging" 2>/dev/null || true
    exit 0
  fi
  # The hand-off is this job's first act, before anything that can fail, so a fast
  # failure path still finds the issue under `merging` and escalates it from there.
  if issue_handoff "$ISSUE_NUM" 2>/dev/null; then
    echo "ℹ️  Issue #${ISSUE_NUM} handed off: working → merging."
  else
    echo "⚠️  Could not hand issue #${ISSUE_NUM} off to this job (backend refused); continuing with the merge."
  fi
fi

# Resolve the exact commit to test/push. Prefer the SHA the caller pinned before we started;
# fall back to resolving $FEATURE in CALLER_DIR for direct invocations that skip --feature-sha.
if [ -z "$FEATURE_SHA" ]; then
  FEATURE_SHA=$(git -C "$CALLER_DIR" rev-parse "$FEATURE" 2>/dev/null || echo "")
fi
if [ -z "$FEATURE_SHA" ]; then
  echo "❌ Could not resolve '${FEATURE}' to a commit (no --feature-sha given and the branch is not in ${CALLER_DIR})." >&2
  _fail 1 "could not resolve '${FEATURE}' to a commit"
fi

# Resolve the gate BEFORE touching anything: an ungated push to the integration branch is
# never acceptable, so a missing command must stop us while the branch is still unmoved.
if [ -z "$TEST_CMD" ]; then
  _REPO_TOP=$(git -C "$CALLER_DIR" rev-parse --show-toplevel 2>/dev/null || echo "$CALLER_DIR")
  TEST_CMD=$(resolve_test_cmd "$_REPO_TOP")
  [ -n "$TEST_CMD" ] && echo "ℹ️  No --test-cmd given; using the Regression Test Suite command from the repo doctrine: $TEST_CMD"
fi
DOCS_ONLY=0
if [ -z "$TEST_CMD" ]; then
  if is_docs_only_diff "$CALLER_DIR" "$FEATURE_SHA" "$INTEGRATION_BRANCH"; then
    DOCS_ONLY=1
    echo "ℹ️  No test command, but ${FEATURE} changes documentation only; merging without a test run."
  else
    echo "❌ No test command: pass --test-cmd or add a '### Regression Test Suite' fenced block to AGENTS.md or CLAUDE.md." >&2
    echo "   Refusing to merge '${FEATURE}' into '${INTEGRATION_BRANCH}' untested. Nothing was fetched, merged, or pushed." >&2
    _fail 1 "no test command resolvable (pass --test-cmd or add a '### Regression Test Suite' block to AGENTS.md or CLAUDE.md)"
  fi
fi

# Isolated throwaway worktrees (#1821) — keyed by issue number, matching the existing
# /tmp/autocoder-merge-<issue>.* convention (only one worker holds an issue's `working`
# lock at a time, so this is unique per in-flight merge). Never persist past this run.
# The -base worktree exists only while the integration tip is gated alone.
WORKTREE_DIR="/tmp/autocoder-merge-worktree-${ISSUE_NUM}"
BASE_WORKTREE_DIR="${WORKTREE_DIR}-base"

_remove_worktree() {
  git -C "$CALLER_DIR" worktree remove --force "$1" 2>/dev/null || rm -rf "$1" 2>/dev/null || true
}
_cleanup_worktrees() {
  _remove_worktree "$WORKTREE_DIR"
  _remove_worktree "$BASE_WORKTREE_DIR"
  git -C "$CALLER_DIR" worktree prune 2>/dev/null || true
}
_cleanup_worktrees

# Hardlink every top-level node_modules tree from the caller's checkout into a throwaway
# worktree so --test-cmd doesn't need a fresh install there (a brand-new worktree has none —
# it's git-ignored). Hardlinks share inodes with the source tree: instant, no meaningful
# extra disk. This matches, not upgrades, the trust the pre-#1821 in-place run already
# placed in whatever was installed in the caller's worktree — dependency freshness there is
# unchanged by this fix and out of scope for it.
#
# #1967: `cp -al` across a filesystem boundary (e.g. repo on ext4, $TMPDIR on tmpfs — true
# on some dev boxes) fails per-file with "Invalid cross-device link", succeeding only for
# directories and symlinks. Left unguarded that produces a tree of empty directory shells
# and dangling symlinks while still reporting success, so any --test-cmd needing a tool not
# already resolvable some other way fails with a confusing "not found" that reads as a
# problem with the change under test. Fall back to a real copy on failure — but `cp -a`
# into an already-partially-populated destination (left behind by the failed `cp -al`
# attempt) nests the copy one level deeper (`$dst/$(basename "$src")/...`) instead of
# merging, so the destination must be wiped first.
_hardlink_or_copy() {
  local src="$1" dst="$2"
  [ -e "$dst" ] && return 0
  mkdir -p "$(dirname "$dst")" 2>/dev/null || true
  if ! cp -al "$src" "$dst" 2>/dev/null; then
    rm -rf "$dst"
    cp -a "$src" "$dst" 2>/dev/null || true
  fi
}

# #1967: `make contracts-check` needs software-factory/packages/*/dist (gitignored build
# output) present, which a fresh worktree never has. Unlike node_modules this must be a
# real copy, never a hardlink: `git worktree add` checks out src/ with a brand-new mtime,
# so a hardlinked dist/ carrying the ORIGINAL build's older mtime reads as stale to
# check-software-factory-sync's freshness comparison even though the content is identical
# — and because a hardlink shares the inode, any process that touched it to fix the mtime
# would touch the caller's own dist/ too. Copy, then touch, so both problems are avoided.
_seed_worktree_deps() {
  local dest="$1" nm d rel
  while IFS= read -r nm; do
    rel="${nm#"$CALLER_DIR"/}"
    _hardlink_or_copy "$nm" "$dest/$rel"
  done < <(find "$CALLER_DIR" -maxdepth 4 -type d -name node_modules 2>/dev/null | grep -v '/node_modules/.*/node_modules$')
  while IFS= read -r d; do
    rel="${d#"$CALLER_DIR"/}"
    [ -e "$dest/$rel" ] && continue
    mkdir -p "$(dirname "$dest/$rel")" 2>/dev/null || true
    cp -a "$d" "$dest/$rel" 2>/dev/null || true
    find "$dest/$rel" -exec touch {} + 2>/dev/null || true
  done < <(find "$CALLER_DIR/software-factory/packages" -mindepth 2 -maxdepth 2 -type d -name dist 2>/dev/null)
}

# --detach on the raw SHA (not the branch name) is required: $FEATURE is very likely still
# checked out in $CALLER_DIR, and git refuses to check out the same branch in two worktrees.
# A detached checkout of its tip commit carries the identical tree without that restriction.
if ! git -C "$CALLER_DIR" worktree add --detach "$WORKTREE_DIR" "$FEATURE_SHA"; then
  echo "❌ Could not create isolated worktree for ${FEATURE} (${FEATURE_SHA})." >&2
  _fail 1 "could not create the isolated merge worktree for ${FEATURE_SHA:0:8}"
fi
trap '_cleanup_worktrees; rm -f "$GATE_LOG"' EXIT

cd "$WORKTREE_DIR" || { echo "❌ Could not enter isolated worktree ${WORKTREE_DIR}." >&2; _fail 1 "could not enter ${WORKTREE_DIR}"; }
_seed_worktree_deps "$WORKTREE_DIR"

# 1. Bring the latest integration state INTO the feature branch so the eventual push
#    is a fast-forward. Never checks out the integration branch -> worktree-safe.
git fetch origin "$INTEGRATION_BRANCH" || { echo "❌ Could not fetch origin/${INTEGRATION_BRANCH}"; _fail 1 "could not fetch origin/${INTEGRATION_BRANCH}"; }
INT_SEEN_SHA=$(git rev-parse "origin/${INTEGRATION_BRANCH}")

# A previous run (or a human) may already have landed this exact commit; merging, gating
# and pushing it again would only add an empty merge commit. Go straight to the outcome.
if git merge-base --is-ancestor "$FEATURE_SHA" "$INT_SEEN_SHA"; then
  echo "ℹ️  ${FEATURE} (${FEATURE_SHA:0:8}) is already on origin/${INTEGRATION_BRANCH}; nothing to merge or gate."
  git push origin --delete "$FEATURE" 2>/dev/null || true
  if [ "$OWN_ISSUE" -eq 1 ] && _issue_has_label awaiting-integration; then
    # An earlier run parked it (disjoint, red base, or not shipped); landing nothing new
    # proves nothing new, so the sentinel keeps ownership.
    echo "ℹ️  Issue #${ISSUE_NUM} is parked under awaiting-integration from an earlier landing; leaving it to the sentinel."
    issue_update "$ISSUE_NUM" --remove-label "merging" 2>/dev/null || true
    exit 0
  fi
  PUBLISH_BASIS=already-landed
  _close_or_park "$FEATURE_SHA"
  exit 0
fi

# The files this change touches, measured against the integration tip as first seen. A
# later re-sync is re-gated only when its incoming files meet this set or a global path.
# No merge base (unrelated histories) means the set is unknown, so every re-sync re-gates.
FEATURE_BASE=$(git merge-base "$INT_SEEN_SHA" "$FEATURE_SHA" 2>/dev/null || echo "")
declare -A FEATURE_FILE_SET=()
if [ -n "$FEATURE_BASE" ]; then
  while IFS= read -r f; do
    [ -n "$f" ] && FEATURE_FILE_SET["$f"]=1
  done < <(git diff --name-only "$FEATURE_BASE" "$FEATURE_SHA")
fi

if ! git merge --no-ff "origin/${INTEGRATION_BRANCH}" \
       -m "Merge origin/${INTEGRATION_BRANCH} into ${FEATURE} (pre-integration sync)"; then
  _escalate_conflict
fi

# 2. Gate the COMBINED tree (this fix + everyone else's merged work). This is the step that
#    catches cross-fix breakage before it lands on the integration branch.
#
#    PUBLISH_BASIS is the one record of why the tree we push is allowed to land, and the
#    final success line is a case over it:
#      tested     the gate passed on exactly the tree we publish (TESTED_TREE)
#      docs-only  nothing for a test suite to verify
#      disjoint   the gate passed on TESTED_TREE; a later re-sync brought in files that
#                 touch neither this change nor a global path, so the published tree is
#                 by construction not the tested one
#      red-base   the gate failed on the integrated tree AND on origin/<integration> alone
#      red-base-disjoint
#                 red-base, then a disjoint re-sync: the published tree is neither tree
#                 the gate ran on
#    Only tested and docs-only let _close_or_park close the issue; the rest park it.
TESTED_TREE=""
PUBLISH_BASIS=""
RED_INTEGRATED_TREE=""
RED_BASE_TREE=""

_gate_integrated_tree() {
  if [ "$DOCS_ONLY" -eq 1 ]; then
    PUBLISH_BASIS=docs-only
    return 0
  fi
  local tree base_sha base_tree
  tree=$(git rev-parse "HEAD^{tree}")
  echo "🧪 Gating the integrated tree ${tree:0:8}: $TEST_CMD"
  if gate_cache_run "$WORKTREE_DIR" "$TEST_CMD" 2>&1 | tee -a "$GATE_LOG"; then
    TESTED_TREE="$tree"
    PUBLISH_BASIS=tested
    return 0
  fi

  base_sha=$(git rev-parse "origin/${INTEGRATION_BRANCH}")
  base_tree=$(git rev-parse "${base_sha}^{tree}")
  echo "❌ Tests fail on the integrated tree ${tree:0:8}."
  echo "   Gating origin/${INTEGRATION_BRANCH} (${base_sha:0:8}, tree ${base_tree:0:8}) alone to see whether this change broke it."
  _remove_worktree "$BASE_WORKTREE_DIR"
  if ! git -C "$CALLER_DIR" worktree add --detach "$BASE_WORKTREE_DIR" "$base_sha"; then
    echo "❌ Could not create a worktree for origin/${INTEGRATION_BRANCH}; treating the failure as this change's. NOT pushing."
    _fail 2 "tests fail on the integrated tree ${tree:0:8} (origin/${INTEGRATION_BRANCH} could not be gated alone)"
  fi
  _seed_worktree_deps "$BASE_WORKTREE_DIR"
  if gate_cache_run "$BASE_WORKTREE_DIR" "$TEST_CMD" 2>&1 | tee -a "$GATE_LOG"; then
    echo "❌ origin/${INTEGRATION_BRANCH} passes alone, so this change broke it. NOT pushing."
    echo "   The fix remains on '${FEATURE}'; investigate the interaction with newly merged work."
    _fail 2 "tests fail on the integrated tree ${tree:0:8} and pass on origin/${INTEGRATION_BRANCH} alone (tree ${base_tree:0:8}), so this change broke it"
  fi
  _remove_worktree "$BASE_WORKTREE_DIR"
  if [ "${AUTOCODER_MERGE_ON_RED_BASE:-1}" != "1" ]; then
    echo "❌ origin/${INTEGRATION_BRANCH} fails alone too (tree ${base_tree:0:8}), and AUTOCODER_MERGE_ON_RED_BASE=0. NOT pushing."
    _fail 2 "tests fail on the integrated tree ${tree:0:8} and on origin/${INTEGRATION_BRANCH} alone (tree ${base_tree:0:8}); AUTOCODER_MERGE_ON_RED_BASE=0 forbids landing on a red base"
  fi
  echo "⚠️  origin/${INTEGRATION_BRANCH} fails alone too (tree ${base_tree:0:8}): the integration branch is red independent of this change."
  echo "   Pushing anyway; the post-merge sentinel owns red ${INTEGRATION_BRANCH}."
  RED_INTEGRATED_TREE="$tree"
  RED_BASE_TREE="$base_tree"
  PUBLISH_BASIS=red-base
}
_gate_integrated_tree

_path_is_global() {
  local path="$1" glob
  for glob in "${GATE_GLOBAL_PATHS[@]}"; do
    # shellcheck disable=SC2053
    if [[ "$path" == $glob || "${path##*/}" == $glob ]]; then
      return 0
    fi
  done
  return 1
}

# Prints the first incoming path that obliges a re-gate (rc 0), or nothing (rc 1) when the
# incoming files are disjoint from this change and from every global path.
_resync_overlap() {
  local old="$1" new="$2" f
  if [ -z "$FEATURE_BASE" ]; then
    echo "every incoming file (no merge base with origin/${INTEGRATION_BRANCH})"
    return 0
  fi
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ -n "${FEATURE_FILE_SET[$f]+x}" ]; then
      echo "$f (a file this change touched)"
      return 0
    fi
    if _path_is_global "$f"; then
      echo "$f (a global path)"
      return 0
    fi
  done < <(git diff --name-only "$old" "$new")
  return 1
}

# 3. Push the feature tip to the integration branch. If a sibling worker pushed in the
#    meantime the push is rejected; re-sync and retry. A re-sync that brings in work
#    overlapping this change produces a tree nobody has tested, so it goes back through the
#    gate before the next push (and before the API fallback below, which publishes whatever
#    HEAD is). A disjoint re-sync is pushed as-is and recorded as such.
PUSH_VIA=""
for attempt in 1 2 3 4 5; do
  if git push origin "HEAD:${INTEGRATION_BRANCH}"; then
    PUSHED=1; PUSH_VIA=git
    break
  fi
  echo "⚠️  Push to '${INTEGRATION_BRANCH}' rejected (a sibling worker likely pushed first); re-syncing (attempt ${attempt}/5)…"
  git fetch origin "$INTEGRATION_BRANCH" || break
  INT_NEW_SHA=$(git rev-parse "origin/${INTEGRATION_BRANCH}")
  BEFORE_RESYNC=$(git rev-parse HEAD)
  if ! git merge --no-ff "origin/${INTEGRATION_BRANCH}" \
         -m "Re-sync origin/${INTEGRATION_BRANCH} into ${FEATURE} (push retry ${attempt})"; then
    _escalate_conflict
  fi
  if [ "$(git rev-parse HEAD)" != "$BEFORE_RESYNC" ]; then
    if [ "${AUTOCODER_SCOPED_REGATE:-1}" != "1" ]; then
      echo "ℹ️  Re-sync brought in new work and AUTOCODER_SCOPED_REGATE=0; re-gating the merged tree"
      _gate_integrated_tree
    elif OVERLAP=$(_resync_overlap "$INT_SEEN_SHA" "$INT_NEW_SHA"); then
      echo "ℹ️  Re-sync brings in ${OVERLAP}; re-gating the merged tree"
      _gate_integrated_tree
    else
      INCOMING_COUNT=$(git diff --name-only "$INT_SEEN_SHA" "$INT_NEW_SHA" | wc -l | tr -d ' ')
      echo "ℹ️  Disjoint re-sync (${INCOMING_COUNT} incoming files, none overlap this change); pushing the already-gated work"
      case "$PUBLISH_BASIS" in
        tested)   PUBLISH_BASIS=disjoint ;;
        red-base) PUBLISH_BASIS=red-base-disjoint ;;
      esac
    fi
  fi
  INT_SEEN_SHA="$INT_NEW_SHA"
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
    PUSHED=1; PUSH_VIA=api
  fi
fi

if [ "$PUSHED" -ne 1 ]; then
  echo "❌ Could not publish to '${INTEGRATION_BRANCH}' (git push and API fallback both failed)."
  echo "   The fix is safe on '${FEATURE}'. NOT closing the issue — nothing landed."
  _fail 1 "could not publish to '${INTEGRATION_BRANCH}' (git push and the API fallback both failed)"
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
  _fail 1 "publication could not be verified: local tree ${LOCAL_TREE:0:8}, remote tree ${REMOTE_TREE:-<none>}"
fi

# The commit that is now on origin/<integration> carrying this work. A git push landed
# HEAD itself; the API fallback minted a new commit, so the fetched remote tip is it.
if [ "$PUSH_VIA" = git ]; then
  LANDED_SHA=$(git rev-parse HEAD)
else
  LANDED_SHA=$(git rev-parse "origin/${INTEGRATION_BRANCH}")
fi

# The word "verified" is reserved for the one case where the gate passed on the very tree
# that is now on the integration branch. PARK_NOTE explains every other basis to the
# issue when _close_or_park parks it.
RED_BASE_NOTE="The gate failed on the integrated tree \`${RED_INTEGRATED_TREE}\` and also on \`origin/${INTEGRATION_BRANCH}\` alone (tree \`${RED_BASE_TREE}\`), so the integration branch was already red independent of this change. Branch \`${FEATURE}\` was pushed anyway"
case "$PUBLISH_BASIS" in
  docs-only)
    echo "✅ Issue #${ISSUE_NUM} merged into '${INTEGRATION_BRANCH}' (documentation-only change; no tests run; tree ${LOCAL_TREE:0:8})." ;;
  tested)
    if [ -n "$TESTED_TREE" ] && [ "$TESTED_TREE" = "$LOCAL_TREE" ]; then
      echo "✅ Issue #${ISSUE_NUM} merged into '${INTEGRATION_BRANCH}' and verified: tests passed on the published tree ${LOCAL_TREE:0:8}."
    else
      echo "❌ Internal error: published tree ${LOCAL_TREE:0:8} is not the tree the tests passed on (${TESTED_TREE:0:8})." >&2
      _fail 1 "internal error: published tree ${LOCAL_TREE:0:8} is not the tested tree ${TESTED_TREE:0:8}"
    fi ;;
  disjoint)
    PARK_NOTE="The gate passed on tree \`${TESTED_TREE}\`; a disjoint push-race re-sync then changed the published tree to \`${LOCAL_TREE}\`, which no gate has run on."
    echo "✅ Issue #${ISSUE_NUM} merged into '${INTEGRATION_BRANCH}' (disjoint re-sync; gated tree ${TESTED_TREE:0:8}, published tree ${LOCAL_TREE:0:8})." ;;
  red-base)
    PARK_NOTE="**Merged onto a red \`${INTEGRATION_BRANCH}\`.** ${RED_BASE_NOTE} (published tree \`${LOCAL_TREE}\`); the post-merge sentinel owns red \`${INTEGRATION_BRANCH}\`."
    echo "✅ Issue #${ISSUE_NUM} merged into '${INTEGRATION_BRANCH}' on a red base (gate failed on integrated tree ${RED_INTEGRATED_TREE:0:8} and on origin/${INTEGRATION_BRANCH} alone, tree ${RED_BASE_TREE:0:8}; published tree ${LOCAL_TREE:0:8}, which the gate did not pass)." ;;
  red-base-disjoint)
    PARK_NOTE="**Merged onto a red \`${INTEGRATION_BRANCH}\`, then re-synced.** ${RED_BASE_NOTE}, and a disjoint push-race re-sync then changed the published tree to \`${LOCAL_TREE}\`, which is neither tree the gate ran on; the post-merge sentinel owns red \`${INTEGRATION_BRANCH}\`."
    echo "✅ Issue #${ISSUE_NUM} merged into '${INTEGRATION_BRANCH}' on a red base followed by a disjoint re-sync (gate failed on integrated tree ${RED_INTEGRATED_TREE:0:8} and on origin/${INTEGRATION_BRANCH} alone, tree ${RED_BASE_TREE:0:8}; published tree ${LOCAL_TREE:0:8} is neither gated tree)." ;;
  *)
    echo "❌ Internal error: no publish basis recorded for tree ${LOCAL_TREE:0:8}." >&2
    _fail 1 "internal error: no publish basis recorded for tree ${LOCAL_TREE:0:8}" ;;
esac
# Without --own-issue nobody parks the issue, so a red-base landing still tells it.
case "$PUBLISH_BASIS" in
  red-base|red-base-disjoint)
    [ "$OWN_ISSUE" -eq 1 ] || issue_comment "$ISSUE_NUM" --body "⚠️ ${PARK_NOTE}" 2>/dev/null || true ;;
esac

# 3d. Publish the landed commit as a tip ref for the sentinel. Never fatal.
TIP_REF="refs/autocoder/tips/${INTEGRATION_BRANCH}/${LANDED_SHA}-${ISSUE_NUM}"
if git push origin "${LANDED_SHA}:${TIP_REF}" >/dev/null 2>&1; then
  echo "ℹ️  Published ${LANDED_SHA:0:8} as ${TIP_REF}."
else
  echo "⚠️  Could not publish ${TIP_REF} (not fatal; the sentinel will see the branch tip)."
fi

# 4. Clean up the feature branch now that its work is on the integration branch.
git push origin --delete "$FEATURE" 2>/dev/null || true
# The throwaway worktrees are removed by the EXIT trap. Any local $FEATURE branch ref
# in $CALLER_DIR is untouched by this script; the caller's own cleanup (or the next /fix
# run branching fresh from origin/<integration-branch>) handles it.

_close_or_park "$LANDED_SHA"
exit 0
