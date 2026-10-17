#!/bin/bash
# tests/test_regression_test_exit.sh — regression-test.sh pipes the unit test command
# through tee; the run's verdict must be the command's exit code, not tee's. A suite that
# prints a clean summary and then exits non-zero (a crashed teardown, a runner error after
# the counts) must fail the run, and a passing one must still pass.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER="$ROOT/plugins/autocoder/scripts/regression-test.sh"

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# The runner sources issue-fns.sh from its own directory, so run a copy beside a stub.
mkdir -p "$TMP/scripts"
cp "$RUNNER" "$TMP/scripts/regression-test.sh"
printf '%s\n' "issue_list() { echo '[]'; }" 'issue_comment() { :; }' 'issue_create() { :; }' > "$TMP/scripts/issue-fns.sh"

run_with_exit() {  # <exit code of the fake suite>
  rm -rf "$TMP/repo"; mkdir -p "$TMP/repo"
  printf 'echo "Tests: 0 failed, 3 passed, 3 total"\nexit %s\n' "$1" > "$TMP/repo/suite.sh"
  cat > "$TMP/repo/CLAUDE.md" <<'MD'
### Unit Tests Only
```bash
bash suite.sh
```

**Test Reports**:
- Location: `reports`
MD
  (cd "$TMP/repo" && bash "$TMP/scripts/regression-test.sh" > "$TMP/out" 2>&1)
}

run_with_exit 1; RC=$?
[ "$RC" -ne 0 ] && ok "a failing test command fails the run" || bad "failing suite reported green: $(tail -5 "$TMP/out")"
grep -q "Status\*\*: ❌ FAILED" "$TMP"/repo/reports/*.md && ok "report marks the unit suite FAILED" || bad "report: $(cat "$TMP"/repo/reports/*.md)"

run_with_exit 0; RC=$?
[ "$RC" -eq 0 ] && ok "a passing test command passes the run" || bad "passing suite rc=$RC: $(tail -5 "$TMP/out")"
grep -q "Status\*\*: ✅ PASSED" "$TMP"/repo/reports/*.md && ok "report marks the unit suite PASSED" || bad "report: $(cat "$TMP"/repo/reports/*.md)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
