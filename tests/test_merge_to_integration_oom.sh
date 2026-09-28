#!/bin/bash
# tests/test_merge_to_integration_oom.sh — an ancestor OOM-kill of
# merge-to-integration.sh's test-cmd invocation must be reported distinctly
# from a genuine test failure (athena2 #1540).
#
# The in-process detection added for issue #1250 (a SIGKILL'd vitest
# subshell) lives inside the log-owning subshell and cannot fire when the
# OOM killer instead hits an ANCESTOR of that subshell — including
# merge-to-integration.sh's own `bash -c "$TEST_CMD"` invocation. That case
# surfaces here only as the exit status of `bash -c`, so this test builds a
# real throwaway git repo (the property under test is the exit-code branch,
# not any particular test framework) and drives the script with a
# self-SIGKILLing --test-cmd to prove the ancestor case is now distinguished.

PASS=0; FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)/plugins/autocoder/scripts"
SCRIPT="$SCRIPT_DIR/merge-to-integration.sh"

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF "$needle"; then
    echo "PASS: $label"; PASS=$((PASS + 1))
  else
    echo "FAIL: $label — expected to find '$needle'"; FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF "$needle"; then
    echo "FAIL: $label — did not expect to find '$needle'"; FAIL=$((FAIL + 1))
  else
    echo "PASS: $label"; PASS=$((PASS + 1))
  fi
}

assert_eq() {
  local label="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    echo "PASS: $label"; PASS=$((PASS + 1))
  else
    echo "FAIL: $label — want '$want', got '$got'"; FAIL=$((FAIL + 1))
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

# ── Test 1: an ancestor SIGKILL of the test-cmd invocation is reported as an
#    infra kill, not a test failure, and the fix branch is preserved ────────
OUT=$(bash "$SCRIPT" --feature feature/issue-9999 --issue 9999 --integration main \
  --test-cmd 'kill -9 $$' 2>&1)
RC=$?
assert_eq "ancestor SIGKILL: exit code is 2 (tests-failed path)" "2" "$RC"
assert_contains "ancestor SIGKILL: reports an OOM/infra-kill, not a generic failure" \
  "$OUT" "ancestor OOM-kill"
assert_not_contains "ancestor SIGKILL: does NOT print the generic tests-fail message" \
  "$OUT" "Tests fail after integrating"

# ── Test 2: a genuine (non-signal) test failure still gets the original,
#    generic message — this must not regress ───────────────────────────────
OUT2=$(bash "$SCRIPT" --feature feature/issue-9999 --issue 9999 --integration main \
  --test-cmd 'exit 1' 2>&1)
RC2=$?
assert_eq "genuine failure: exit code is 2 (tests-failed path)" "2" "$RC2"
assert_contains "genuine failure: still reports the generic tests-fail message" \
  "$OUT2" "Tests fail after integrating"
assert_not_contains "genuine failure: does NOT claim an ancestor OOM-kill" \
  "$OUT2" "ancestor OOM-kill"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
