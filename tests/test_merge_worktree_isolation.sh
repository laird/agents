#!/bin/bash
# tests/test_merge_worktree_isolation.sh — pins #1821: merge-to-integration.sh
# must test and push the branch it was asked to merge, never whatever branch
# happens to be checked out in the caller's worktree by the time it actually
# runs.
#
# THE BUG: merge-to-integration.sh used to `git checkout "$FEATURE"` in the
# caller's own worktree, then fetch/merge/test/push there. merge-launch.sh
# runs it detached so the caller can move on immediately, and the /fix loop
# routinely reused that same worktree directory for the NEXT issue's branch
# before the first merge finished. Concretely: worker checks out
# feature/issue-A, commits, launches its (detached) merge, then — before that
# merge finishes — checks out feature/issue-B in the SAME directory. The
# detached merge for A, still running, would then test and push whatever B's
# checkout had left in that directory, not A's tree (observed for #1809/#1812
# on athena2-wt-1).
#
# THIS TEST reproduces that exact sequence for real, with a real git repo and
# a real detached merge-launch.sh, and asserts the fix (an isolated `git
# worktree add` keyed by issue number) makes the race harmless: branch B's
# checkout happening mid-flight must not change what branch A's merge tests
# or pushes.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$ROOT/plugins/autocoder/scripts"

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"; rm -f /tmp/autocoder-merge-19101.*; rm -rf /tmp/autocoder-merge-worktree-19101; git -C "$TMP/worker" worktree prune 2>/dev/null' EXIT

# ── Fixture: a bare "origin" plus a worker checkout, mimicking a worktree in
#    the swarm ─────────────────────────────────────────────────────────────
git init --bare -q "$TMP/origin.git"

git init -q "$TMP/worker"
cd "$TMP/worker" || exit 1
git config user.email "test@example.com"
git config user.name "Test"
git remote add origin "$TMP/origin.git"
# merge-to-integration.sh sources issue-fns.sh unconditionally, which resolves
# an issue backend at source time and hard-fails non-interactively if none is
# configured — this fixture never touches issues, so pin the file backend to
# avoid an unrelated "No issue source configured" failure.
export ISSUE_SOURCE=file
echo "base" > README.md
git add README.md
git commit -q -m "initial commit"
git branch -M master
git push -q origin master

# Branch A: the fix this test cares about isolating.
git checkout -q -b feature/issue-A
echo "fix-A" > fix-a.txt
git add fix-a.txt
git commit -q -m "Fix issue A"
git push -q -u origin feature/issue-A
FEATURE_A_SHA=$(git rev-parse HEAD)

# Launch A's merge DETACHED, exactly as fix.md does, from inside the worker
# checkout while it is still on feature/issue-A.
LAUNCH_OUT=$(bash "$SCRIPT_DIR/merge-launch.sh" --feature feature/issue-A --issue 19101 \
  --integration master --test-cmd "sleep 3 && test -f fix-a.txt && ! test -f fix-b.txt" 2>&1)
LAUNCH_RC=$?
[ "$LAUNCH_RC" -eq 0 ] && ok "merge-launch.sh launched A's merge" || bad "merge-launch.sh failed to launch (rc=$LAUNCH_RC): $LAUNCH_OUT"

# ── Reproduce the race: WHILE A's merge is still running in the background,
#    the SAME worker directory moves on to issue B — new branch, new commit,
#    same directory. This is exactly what the /fix loop does when it does not
#    wait for merge-poll.sh before claiming the next issue. ─────────────────
git checkout -q -b feature/issue-B
echo "fix-b" > fix-b.txt
git add fix-b.txt
git commit -q -m "Fix issue B"

# Give A's merge a moment to have started (it sleeps 3s in --test-cmd above,
# so this checkout of B lands squarely inside that window).
sleep 1
CURRENT_BRANCH_DURING_RACE=$(git branch --show-current)
[ "$CURRENT_BRANCH_DURING_RACE" = "feature/issue-B" ] && \
  ok "worker directory switched to feature/issue-B while A's merge is still in flight (race staged)" || \
  bad "test setup did not actually stage the race (on $CURRENT_BRANCH_DURING_RACE)"

# ── Wait for A's merge to finish and check what it actually did ─────────────
DEADLINE=$((SECONDS + 30))
while [ -f /tmp/autocoder-merge-19101.pid ] && [ $SECONDS -lt $DEADLINE ]; do
  OLD_PID=$(cat /tmp/autocoder-merge-19101.pid 2>/dev/null || echo "")
  [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null || break
  sleep 1
done

MERGE_LOG=$(cat /tmp/autocoder-merge-19101.log 2>/dev/null || echo "<no log>")
MERGE_EXIT=$(cat /tmp/autocoder-merge-19101.exit 2>/dev/null || echo "<no exit code — still running?>")

[ "$MERGE_EXIT" = "0" ] && ok "A's merge finished successfully (its --test-cmd saw fix-a.txt, not fix-b.txt)" \
  || bad "A's merge did not exit 0 (exit=$MERGE_EXIT) — log:
$MERGE_LOG"

# The whole point: master must now contain A's fix, and must NOT contain B's
# fix (B was never merged — it's still sitting uncommitted-to-origin on the
# worker's local branch). If master has fix-b.txt, A's gate tested/pushed B's
# tree instead of its own — the exact #1821 failure mode.
git fetch -q origin master
if git cat-file -e "origin/master:fix-a.txt" 2>/dev/null; then
  ok "origin/master contains fix-A's file"
else
  bad "origin/master is missing fix-a.txt — A's merge did not land A's own work"
fi

if git cat-file -e "origin/master:fix-b.txt" 2>/dev/null; then
  bad "origin/master contains fix-B's file — A's gate tested/pushed B's tree instead of its own (#1821 regression)"
else
  ok "origin/master does NOT contain fix-B's file — the race did not leak B's work into A's merge"
fi

# The worker directory's OWN checkout must be completely unaffected by the
# merge that ran alongside it — still on feature/issue-B, still has its own
# uncommitted-to-origin work, having never itself been touched.
FINAL_BRANCH=$(git branch --show-current)
[ "$FINAL_BRANCH" = "feature/issue-B" ] && ok "worker directory is still on feature/issue-B after A's merge completed (untouched)" \
  || bad "worker directory's checkout was mutated by A's merge (now on $FINAL_BRANCH)"

[ -f fix-b.txt ] && ok "worker directory still has fix-B's uncommitted work intact" \
  || bad "worker directory lost fix-B's work"

# The throwaway worktree must not outlive the merge.
[ -d "/tmp/autocoder-merge-worktree-19101" ] && bad "throwaway merge worktree was not cleaned up" \
  || ok "throwaway merge worktree was cleaned up after the run"

git worktree list --porcelain | grep -q "19101" && bad "git still lists a worktree entry for the finished merge" \
  || ok "git worktree list has no leftover entry for the finished merge"

TOTAL=$((PASS + FAIL))
echo "$PASS passed / $FAIL failed / $TOTAL total"
[ "$FAIL" -eq 0 ]
