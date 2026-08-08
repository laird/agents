#!/bin/bash
# tests/test_regression_test_runner.sh — guards regression-test.sh itself.
#
# Runs regression-test.sh in a scratch directory so the test is hermetic.

PASS=0; FAIL=0
SCRIPT="plugins/autocoder/scripts/regression-test.sh"

assert_exit() {
  local label="$1" expected="$2" actual="$3"
  if [ "$actual" -eq "$expected" ]; then
    echo "PASS: $label"; PASS=$((PASS + 1))
  else
    echo "FAIL: $label — expected exit $expected, got $actual"; FAIL=$((FAIL + 1))
  fi
}

assert_not_contains_file() {
  local label="$1" needle="$2" dir="$3"
  if find "$dir" -name "$needle" -maxdepth 3 2>/dev/null | grep -q .; then
    echo "FAIL: $label — '$needle' found under $dir"; FAIL=$((FAIL + 1))
  else
    echo "PASS: $label"; PASS=$((PASS + 1))
  fi
}

# ── Scratch workspace ─────────────────────────────────────────────────────────
ORIG=$(pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Minimal repo skeleton: CLAUDE.md with NO test commands (so both suites skip)
mkdir -p "$TMP"
cat > "$TMP/CLAUDE.md" <<'CLAUDE'
## Automated Testing & Issue Management

### Regression Test Suite
```bash
bash plugins/autocoder/scripts/regression-test.sh
```

### Test Framework Details

**Unit Tests**:
- Framework: (not configured)

**E2E Tests**:
- Not configured for this repository.

**Test Reports**:
- Location: `docs/test/regression-reports/`
CLAUDE

# Copy just the scripts the runner needs (it sources issue-fns.sh too)
mkdir -p "$TMP/plugins/autocoder/scripts"
cp "$ORIG/$SCRIPT" "$TMP/$SCRIPT"
# Provide a stub issue-fns.sh that does nothing (runner calls issue_list)
cat > "$TMP/plugins/autocoder/scripts/issue-fns.sh" <<'STUB'
issue_list() { echo '[]'; }
issue_comment() { :; }
issue_create() { :; }
STUB

cd "$TMP"

# ── Test 1: all suites skipped → non-zero exit ────────────────────────────────
bash "$SCRIPT" >/dev/null 2>&1
assert_exit "all-suites-skipped exits non-zero" 1 $?

# ── Test 2: report directory is NOT created with glob metacharacters ──────────
assert_not_contains_file "no tests/test_*.sh directory created" "test_*.sh" "$TMP"

cd "$ORIG"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
