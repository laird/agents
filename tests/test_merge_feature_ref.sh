#!/bin/bash
# tests/test_merge_feature_ref.sh — pins #143: the merge job must land the work
# that was pushed to origin/<feature>, not a stray local branch of the same name.
#
# THE BUG: every worktree on a host shares one local branch namespace.
# merge-launch.sh resolved `--feature feature/issue-N` with a bare
# `git rev-parse`, which picks the LOCAL branch. A stray local feature/issue-N
# from an unrelated earlier run, already an ancestor of master, sent the job down
# its "already on origin/master" path: it reported success, closed the issue, and
# deleted origin/feature/issue-N — the branch holding the real, unmerged work.
#
# This fixture builds exactly that: real work pushed to origin/feature/issue-7
# from a differently-named local branch, plus a stray local feature/issue-7
# sitting on master's history.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$ROOT/plugins/autocoder/scripts"

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap 'git -C "$TMP/worker" worktree prune 2>/dev/null; rm -rf "$TMP"' EXIT
export AUTOCODER_TMP="$TMP/tmp"; mkdir -p "$AUTOCODER_TMP"
export AUTOCODER_GATE_CACHE_DIR="$TMP/gate-cache"
export ISSUE_SOURCE=file   # issue-fns.sh needs a backend; this fixture touches no issues

# shellcheck source=../plugins/autocoder/scripts/feature-ref-fns.sh
source "$SCRIPT_DIR/feature-ref-fns.sh"

git init --bare -q "$TMP/origin.git"
git init -q "$TMP/worker"
cd "$TMP/worker" || exit 1
git config user.email "test@example.com"
git config user.name "Test"
git remote add origin "$TMP/origin.git"
echo base > README.md && git add README.md && git commit -q -m "initial"
git branch -M master
git push -q origin master
STRAY_SHA=$(git rev-parse HEAD)

# The real work, pushed to origin/feature/issue-7 from a differently-named branch.
git checkout -q -b work-7
echo real > real.txt && git add real.txt && git commit -q -m "real fix for #7"
REAL_SHA=$(git rev-parse HEAD)
git push -q origin "work-7:refs/heads/feature/issue-7"
# The stray: a local feature/issue-7 already on master's history.
git branch feature/issue-7 "$STRAY_SHA"
git checkout -q master

# ── resolve_feature_sha ─────────────────────────────────────────────────────
GOT=$(resolve_feature_sha "$TMP/worker" feature/issue-7 2>"$TMP/warn")
[ "$GOT" = "$REAL_SHA" ] && ok "resolves to origin's commit, not the stray local branch" \
  || bad "resolved to ${GOT:0:8}, expected origin's ${REAL_SHA:0:8} (stray is ${STRAY_SHA:0:8})"
grep -q "differs from origin/feature/issue-7" "$TMP/warn" && ok "warns when local and origin disagree" \
  || bad "no divergence warning: $(cat "$TMP/warn")"

git branch -q local-only "$REAL_SHA"
GOT=$(resolve_feature_sha "$TMP/worker" local-only 2>/dev/null)
[ "$GOT" = "$REAL_SHA" ] && ok "falls back to the local branch when origin has none" \
  || bad "local-only fallback gave '${GOT}'"

GOT=$(resolve_feature_sha "$TMP/worker" "$STRAY_SHA" 2>/dev/null)
[ "$GOT" = "$STRAY_SHA" ] && ok "still accepts a raw SHA" || bad "raw SHA gave '${GOT}'"

if resolve_feature_sha "$TMP/worker" no/such-branch >/dev/null 2>&1; then
  bad "an unknown name resolved to something"
else
  ok "an unknown name resolves to nothing (exit 1)"
fi

# ── delete_feature_branch_if_at ─────────────────────────────────────────────
git push -q origin "$REAL_SHA:refs/heads/feature/issue-8"
delete_feature_branch_if_at "$TMP/worker" feature/issue-8 "$STRAY_SHA"
git ls-remote --exit-code origin refs/heads/feature/issue-8 >/dev/null \
  && ok "refuses to delete a remote branch that is not at the landed commit" \
  || bad "deleted origin/feature/issue-8 although it held unlanded work"
delete_feature_branch_if_at "$TMP/worker" feature/issue-8 "$REAL_SHA"
git ls-remote --exit-code origin refs/heads/feature/issue-8 >/dev/null \
  && bad "did not delete a remote branch at the landed commit" \
  || ok "deletes the remote branch when it is at the landed commit"

# ── merge-launch.sh pins origin's commit ────────────────────────────────────
# Read the pinned SHA from the generated wrapper; the gate itself is irrelevant.
bash "$SCRIPT_DIR/merge-launch.sh" --feature feature/issue-7 --issue 14307 \
  --integration master --test-cmd "true" >/dev/null 2>&1
RUN=$(ls "$AUTOCODER_TMP"/autocoder-merge-*-14307.run.sh 2>/dev/null | head -1)
if [ -n "$RUN" ] && grep -q -- "--feature-sha $REAL_SHA" "$RUN"; then
  ok "merge-launch.sh pins origin/feature/issue-7's commit"
else
  bad "merge-launch.sh pinned the wrong commit: $(grep -o -- '--feature-sha [0-9a-f]*' "$RUN" 2>/dev/null)"
fi
# ── end to end: the detached job lands the real work ────────────────────────
EXIT_FILE=""
for _ in $(seq 1 120); do
  EXIT_FILE=$(ls "$AUTOCODER_TMP"/autocoder-merge-*-14307.exit 2>/dev/null | head -1)
  [ -n "$EXIT_FILE" ] && break
  sleep 1
done
[ -n "$EXIT_FILE" ] || bad "the detached merge job did not finish within 120s"
git fetch -q origin
git merge-base --is-ancestor "$REAL_SHA" origin/master \
  && ok "the merge job landed the real work on master" \
  || bad "real work did not land: $(tail -5 "$AUTOCODER_TMP"/autocoder-merge-*-14307.log 2>/dev/null)"
git cat-file -e origin/master:real.txt 2>/dev/null && ok "real.txt is on origin/master" \
  || bad "real.txt is missing from origin/master"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
