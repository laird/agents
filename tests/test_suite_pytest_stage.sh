#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"
# tests/test_suite_pytest_stage.sh — run-shell-suite.sh runs tests/test_*.py too (#295),
# so a pytest failure fails the merge gate the way it fails CI:
#   - each python file is one suite: PASS/FAIL line, counted in the summary, named
#     in "Failing suites:" so the gate's flaky re-run can pass it back;
#   - a test_*.py argument runs just that file;
#   - with no pytest the files are skipped with a warning naming each, and that is a
#     failure under CI or AUTOCODER_REQUIRE_PYTEST=1.
#
# Runs a copy of the runner over throwaway tests. AUTOCODER_PYTEST points at a stub
# that runs each file with plain python3, so no real pytest is needed.

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

R="$TMP/repo"
mkdir -p "$R/tests/lib"
cp "$ROOT/tests/run-shell-suite.sh" "$R/tests/"
cp "$ROOT/tests/lib/private-event-logs.sh" "$R/tests/lib/"
printf '#!/bin/bash\nexit 0\n' > "$R/tests/test_shell_ok.sh"
printf 'import sys\nsys.exit(0)\n' > "$R/tests/test_py_ok.py"
printf 'import sys\nprint("assert 1 == 2")\nsys.exit(1)\n' > "$R/tests/test_py_bad.py"

# The stub is called as: <cmd> -q -p no:cacheprovider <file>. It logs each call.
STUB="$TMP/fake-pytest"
printf '#!/bin/bash\necho "$*" >> "%s/calls"\nexec python3 "${@: -1}"\n' "$TMP" > "$STUB"
chmod +x "$STUB"

suite() { (cd "$R" && env -u CI -u AUTOCODER_REQUIRE_PYTEST TMPDIR="$TMP" "$@" 2>&1); }

echo "=== python files run as suites ==="
OUT=$(suite env AUTOCODER_PYTEST="$STUB" bash tests/run-shell-suite.sh); RC=$?
[ "$RC" -ne 0 ] && ok "a failing python test fails the run" || bad "rc=$RC: $OUT"
echo "$OUT" | grep -qx "PASS  test_py_ok.py" && ok "passing file has a PASS line" || bad "no PASS line: $OUT"
echo "$OUT" | grep -qx "FAIL  test_py_bad.py" && ok "failing file has a FAIL line" || bad "no FAIL line: $OUT"
echo "$OUT" | grep -q "| assert 1 == 2" && ok "failing file's output is shown" || bad "no output excerpt: $OUT"
echo "$OUT" | grep -qx "Failing suites: test_py_bad.py" && ok "Failing suites names the python file" || bad "failing list: $OUT"
echo "$OUT" | grep -qx "Tests: 1 failed, 2 passed, 3 total" && ok "summary counts shell and python files" || bad "summary: $OUT"
grep -q -- "-p no:cacheprovider tests/test_py_ok.py" "$TMP/calls" && ok "pytest runs without its cache, one file per call" || bad "calls: $(cat "$TMP/calls")"
[ -z "$(find "$R" -name .pytest_cache -o -name __pycache__)" ] && ok "no cache left in the checkout" || bad "cache dirs left"

echo "=== a test_*.py argument runs just that file ==="
: > "$TMP/calls"
OUT=$(suite env AUTOCODER_PYTEST="$STUB" bash tests/run-shell-suite.sh test_py_ok.py); RC=$?
[ "$RC" -eq 0 ] && echo "$OUT" | grep -qx "Tests: 0 failed, 1 passed, 1 total" && ok "named python file alone" || bad "rc=$RC: $OUT"
[ "$(wc -l < "$TMP/calls")" -eq 1 ] && ok "only the named file ran" || bad "calls: $(cat "$TMP/calls")"
OUT=$(suite env AUTOCODER_PYTEST="$STUB" bash tests/run-shell-suite.sh tests/test_missing.py); RC=$?
[ "$RC" -ne 0 ] && echo "$OUT" | grep -q "FAIL  test_missing.py (no such test)" && ok "missing python file fails" || bad "rc=$RC: $OUT"

echo "=== no pytest: warn, and fail only where CI would run them ==="
rm "$R/tests/test_py_bad.py"
OUT=$(suite env AUTOCODER_PYTEST=none bash tests/run-shell-suite.sh); RC=$?
[ "$RC" -eq 0 ] && ok "missing pytest alone does not fail a local run" || bad "rc=$RC: $OUT"
echo "$OUT" | grep -q "^WARN  pytest not found.*skipped 1 python test files: test_py_ok.py" && ok "warning names the skipped files" || bad "no warning: $OUT"
echo "$OUT" | grep -qx "Tests: 0 failed, 1 passed, 1 total" && ok "skipped files are not counted as passed" || bad "summary: $OUT"
OUT=$(suite env AUTOCODER_PYTEST=none CI=true bash tests/run-shell-suite.sh); RC=$?
[ "$RC" -ne 0 ] && echo "$OUT" | grep -q "^FAIL  pytest-missing" && ok "CI without pytest fails" || bad "CI rc=$RC: $OUT"
OUT=$(suite env AUTOCODER_PYTEST=none AUTOCODER_REQUIRE_PYTEST=1 bash tests/run-shell-suite.sh); RC=$?
[ "$RC" -ne 0 ] && echo "$OUT" | grep -qx "Failing suites: pytest-missing" && ok "AUTOCODER_REQUIRE_PYTEST=1 without pytest fails" || bad "require rc=$RC: $OUT"

echo "=== no python files: no pytest stage at all ==="
rm "$R/tests/test_py_ok.py"
OUT=$(suite env AUTOCODER_PYTEST=none CI=true bash tests/run-shell-suite.sh); RC=$?
[ "$RC" -eq 0 ] && ! echo "$OUT" | grep -q pytest && ok "no python tests, nothing to warn about" || bad "rc=$RC: $OUT"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
