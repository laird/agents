#!/bin/bash
# tests/test_merge_to_integration_worktree_hijack.sh — pin athena2 #1736:
# merge-to-integration.sh must not report "merged and verified" when this
# worktree's HEAD is repointed mid-flight by a concurrent /fix invocation
# reusing the same directory for a different issue.
#
# The real incident: a second /fix ran `git checkout -b feature/issue-N
# origin/<integration>` in the SAME worktree directory while an in-flight
# merge-to-integration.sh for a different issue was still running its
# (multi-minute) test-cmd. Both the push (`HEAD:$INTEGRATION_BRANCH`) and the
# later tree-verification (`HEAD^{tree}`) re-read the worktree's mutable HEAD
# at the moment they ran, so they silently pushed/verified nothing (the
# hijacked branch happened to equal origin/main already) while reporting
# success. This test reproduces that exact hijack via --test-cmd, which runs
# `bash -c` in the script's own cwd — the same real git repository the
# checkout below repoints.

PASS=0; FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)/plugins/autocoder/scripts"
SCRIPT="$SCRIPT_DIR/merge-to-integration.sh"

assert_eq() {
  local label="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    echo "PASS: $label"; PASS=$((PASS + 1))
  else
    echo "FAIL: $label — want '$want', got '$got'"; FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF "$needle"; then
    echo "PASS: $label"; PASS=$((PASS + 1))
  else
    echo "FAIL: $label — expected to find '$needle'"; FAIL=$((FAIL + 1))
  fi
}

TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

ORIGIN="$TMP/origin.git"
WORK="$TMP/work"
git init --quiet --bare "$ORIGIN"

git init --quiet "$WORK"
cd "$WORK"
git config user.email test@example.com
git config user.name "Test"
git remote add origin "$ORIGIN"
echo "one" > README.md
git add README.md
git commit --quiet -m "initial"
git branch -M main
git push --quiet origin main

git checkout --quiet -b feature/issue-9999
echo "two" >> README.md
git add README.md
git commit --quiet -m "feature work"

# The hijack: a concurrent /fix branching a different issue in this same
# worktree, mid test-run.
OUT=$(bash "$SCRIPT" --feature feature/issue-9999 --issue 9999 --integration main \
  --test-cmd 'git checkout -b feature/issue-8888 origin/main' 2>&1)
RC=$?

MAIN_SHA=$(git ls-remote "$ORIGIN" main | cut -f1)
LANDED_CONTENT=$(git --git-dir="$ORIGIN" show "${MAIN_SHA}:README.md" 2>/dev/null || echo "")

assert_eq "script exits 0 (reports success)" "0" "$RC"
assert_contains "script claims the merge was verified" "$OUT" "merged into 'main' and verified"
assert_contains "the feature commit actually reached origin/main" "$LANDED_CONTENT" "two"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
