#!/bin/bash
# tests/test_regression_test_config.sh — regression-test.sh must not report a
# false green (issue #73).
#
# Three defects are covered:
#   1. REPORT_DIR was taken from the FIRST "Location: " line anywhere in
#      CLAUDE.md, which is the Unit Tests one (`tests/test_*.sh`), not the
#      Test Reports one. mkdir -p then created a directory whose literal name
#      contains a glob, poisoning later `tests/test_*.sh` expansions.
#   2. The unit-test command was read from a "### Unit Tests Only" header that
#      exists in no CLAUDE.md in this repo, so it always fell through to the
#      `npm test` default and got skipped.
#   3. A run in which every suite SKIPPED still printed "All tests passed" and
#      exited 0. Zero tests executed is not a pass.

PASS=0; FAIL=0
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/plugins/autocoder/scripts/regression-test.sh"

assert_eq() {
  local label="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    echo "PASS: $label"; PASS=$((PASS + 1))
  else
    echo "FAIL: $label — want '$want', got '$got'"; FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local label="$1" needle="$2" hay="$3"
  case "$hay" in
    *"$needle"*) echo "FAIL: $label — output unexpectedly contained '$needle'"; FAIL=$((FAIL + 1)) ;;
    *)           echo "PASS: $label"; PASS=$((PASS + 1)) ;;
  esac
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# A CLAUDE.md shaped exactly like this repo's: the Unit Tests "Location:" line
# appears BEFORE the Test Reports one, which is what triggered defect 1.
mkdir -p "$TMP/work"
cat > "$TMP/work/CLAUDE.md" <<'EOF'
# Test fixture

## Automated Testing & Issue Management

### Regression Test Suite
```bash
bash run-suite.sh
```

### Build Verification
```bash
true
```

### Test Framework Details

**Unit Tests**:
- Framework: plain `bash` assertion scripts
- Location: `tests/test_*.sh` (shell), `tests/test_*.py` (Python)

**E2E Tests**:
- Not configured for this repository.

**Test Reports**:
- Location: `docs/test/regression-reports/`

### Merge Mode
```
pr
```
EOF

cat > "$TMP/work/run-suite.sh" <<'EOF'
#!/bin/bash
echo "1 passed"
exit 0
EOF
chmod +x "$TMP/work/run-suite.sh"

cd "$TMP/work"
git init --quiet
git config user.email test@example.com
git config user.name "Test"
# The script bootstraps an issue source at startup; give it one so the run
# reaches the code under test. Issue writes are suppressed separately by
# REGRESSION_TEST_NO_ISSUES.
echo '{"issueSource": "github"}' > .autocoder.json

# Run with issue-creation disabled so the test never touches a real tracker.
OUTPUT=$(REGRESSION_TEST_NO_ISSUES=1 bash "$SCRIPT" 2>&1)
RC=$?

# ── Defect 1: report directory ────────────────────────────────────────────
if [ -e 'tests/test_*.sh' ]; then
  echo "FAIL: no glob-named directory is created — 'tests/test_*.sh' exists"
  FAIL=$((FAIL + 1))
else
  echo "PASS: no glob-named directory is created"
  PASS=$((PASS + 1))
fi

assert_not_contains "report path is not a glob" 'tests/test_*.sh/regression-' "$OUTPUT"

if ls docs/test/regression-reports/regression-*.md >/dev/null 2>&1; then
  echo "PASS: report written under docs/test/regression-reports"
  PASS=$((PASS + 1))
else
  echo "FAIL: report not written under docs/test/regression-reports"
  FAIL=$((FAIL + 1))
fi

# ── Defect 2: the configured suite actually runs ──────────────────────────
case "$OUTPUT" in
  *"1 passed"*) echo "PASS: configured suite command was executed"; PASS=$((PASS + 1)) ;;
  *)            echo "FAIL: configured suite command was not executed"; FAIL=$((FAIL + 1)) ;;
esac

assert_eq "exit code when the configured suite passes" "0" "$RC"

# ── Defect 3: all-skipped must not be a pass ──────────────────────────────
# A CLAUDE.md with no runnable suite config: every suite falls back to a
# node command, and with no package.json present both get skipped.
mkdir -p "$TMP/skipped"
cat > "$TMP/skipped/CLAUDE.md" <<'EOF'
# Test fixture with no test configuration
EOF

cd "$TMP/skipped"
git init --quiet
git config user.email test@example.com
git config user.name "Test"
echo '{"issueSource": "github"}' > .autocoder.json

SKIP_OUTPUT=$(REGRESSION_TEST_NO_ISSUES=1 bash "$SCRIPT" 2>&1)
SKIP_RC=$?

# Match on behaviour, not exact wording: the two script variants phrase this
# differently ("SKIPPED" vs "skipping."), and only the behaviour is the contract.
if printf '%s' "$SKIP_OUTPUT" | grep -qiE 'skip(ped|ping)'; then
  echo "PASS: all-skipped scenario did skip both suites"; PASS=$((PASS + 1))
else
  echo "FAIL: all-skipped scenario did not skip"; FAIL=$((FAIL + 1))
fi

assert_not_contains "all-skipped does not claim success" "All tests passed" "$SKIP_OUTPUT"

if [ "$SKIP_RC" -ne 0 ]; then
  echo "PASS: exit code is non-zero when every suite is skipped"
  PASS=$((PASS + 1))
else
  echo "FAIL: exit code is 0 when every suite is skipped — false green"
  FAIL=$((FAIL + 1))
fi

# ── The runner must not leak its own issue-backend bootstrap into suites ──
# issue-config.sh treats a pre-set ISSUE_SOURCE as authoritative, so a leaked
# value makes every test that builds a file-backend fixture talk to the wrong
# backend. The suite must observe those variables unset.
mkdir -p "$TMP/envleak"
cat > "$TMP/envleak/CLAUDE.md" <<'EOF'
# Test fixture

## Automated Testing & Issue Management

### Unit Tests Only
```bash
bash show-env.sh
```

**Test Reports**:
- Location: `docs/test/regression-reports/`
EOF

cat > "$TMP/envleak/show-env.sh" <<'EOF'
#!/bin/bash
echo "SEEN_ISSUE_SOURCE=[${ISSUE_SOURCE:-}]"
echo "SEEN_ISSUE_BACKEND=[${ISSUE_BACKEND:-}]"
echo "1 passed"
EOF
chmod +x "$TMP/envleak/show-env.sh"

cd "$TMP/envleak"
git init --quiet
git config user.email test@example.com
git config user.name "Test"
echo '{"issueSource": "github"}' > .autocoder.json

LEAK_OUTPUT=$(REGRESSION_TEST_NO_ISSUES=1 bash "$SCRIPT" 2>&1)

case "$LEAK_OUTPUT" in
  *"SEEN_ISSUE_SOURCE=[]"*)  echo "PASS: ISSUE_SOURCE is not leaked into the suite"; PASS=$((PASS + 1)) ;;
  *)                         echo "FAIL: ISSUE_SOURCE leaked into the suite"; FAIL=$((FAIL + 1)) ;;
esac

case "$LEAK_OUTPUT" in
  *"SEEN_ISSUE_BACKEND=[]"*) echo "PASS: ISSUE_BACKEND is not leaked into the suite"; PASS=$((PASS + 1)) ;;
  *)                         echo "FAIL: ISSUE_BACKEND leaked into the suite"; FAIL=$((FAIL + 1)) ;;
esac

# ── A FAILING suite must report red ───────────────────────────────────────
# `cmd | tee f` reports tee's exit code, not the suite's. Without pipefail,
# `if cmd | tee f; then PASSED` marked every failing suite as passing. This is
# the single most important assertion in this file: a test runner that cannot
# go red is worse than no test runner at all.
mkdir -p "$TMP/red"
cat > "$TMP/red/CLAUDE.md" <<'EOF'
# Test fixture

### Unit Tests Only
```bash
bash fail.sh
```

**Test Reports**:
- Location: `docs/test/regression-reports/`
EOF

cat > "$TMP/red/fail.sh" <<'EOF'
#!/bin/bash
echo "1 failed"
exit 1
EOF
chmod +x "$TMP/red/fail.sh"

cd "$TMP/red"
git init --quiet
git config user.email test@example.com
git config user.name "Test"
echo '{"issueSource": "github"}' > .autocoder.json

RED_OUTPUT=$(REGRESSION_TEST_NO_ISSUES=1 bash "$SCRIPT" 2>&1)
RED_RC=$?

if [ "$RED_RC" -ne 0 ]; then
  echo "PASS: a failing suite exits non-zero"; PASS=$((PASS + 1))
else
  echo "FAIL: a failing suite exits 0 — the runner cannot go red"; FAIL=$((FAIL + 1))
fi

assert_not_contains "a failing suite does not claim success" "All tests passed" "$RED_OUTPUT"

# ── Non-Jest summaries must be accepted; truly unparseable ones must not ──
# The stat parser keyed only on the Jest "Tests: N passed" form. Once the unit
# suite actually runs, this repo's own shell tests print "Results: 13 passed,
# 0 failed" — no "Tests:" prefix — so a fully green run was reported as
# "no parseable test summary" and exited 1. A false RED, the mirror image of
# the false green this file otherwise guards. The fallback must widen the
# accepted formats WITHOUT defeating the guard against a runner that produced
# no summary at all.
mkdir -p "$TMP/bare"
cat > "$TMP/bare/CLAUDE.md" <<'EOF'
# Test fixture

### Unit Tests Only
```bash
bash bare.sh
```

**Test Reports**:
- Location: `docs/test/regression-reports/`
EOF

cat > "$TMP/bare/bare.sh" <<'EOF'
#!/bin/bash
echo ""
echo "Results: 13 passed, 0 failed"
EOF
chmod +x "$TMP/bare/bare.sh"

cd "$TMP/bare"
git init --quiet
git config user.email test@example.com
git config user.name "Test"
echo '{"issueSource": "github"}' > .autocoder.json

BARE_OUTPUT=$(REGRESSION_TEST_NO_ISSUES=1 bash "$SCRIPT" 2>&1)
BARE_RC=$?

assert_eq "a non-Jest 'N passed' summary is accepted" "0" "$BARE_RC"
assert_not_contains "non-Jest summary is not called unparseable" "no parseable test summary" "$BARE_OUTPUT"

# The other direction: output with no counts at all is still an error.
mkdir -p "$TMP/unparseable"
cat > "$TMP/unparseable/CLAUDE.md" <<'EOF'
# Test fixture

### Unit Tests Only
```bash
bash silent.sh
```

**Test Reports**:
- Location: `docs/test/regression-reports/`
EOF

cat > "$TMP/unparseable/silent.sh" <<'EOF'
#!/bin/bash
echo "some output with no counts at all"
EOF
chmod +x "$TMP/unparseable/silent.sh"

cd "$TMP/unparseable"
git init --quiet
git config user.email test@example.com
git config user.name "Test"
echo '{"issueSource": "github"}' > .autocoder.json

UNP_OUTPUT=$(REGRESSION_TEST_NO_ISSUES=1 bash "$SCRIPT" 2>&1)
UNP_RC=$?

if [ "$UNP_RC" -ne 0 ]; then
  echo "PASS: output with no counts at all is still an error"; PASS=$((PASS + 1))
else
  echo "FAIL: output with no counts at all was treated as a pass"; FAIL=$((FAIL + 1))
fi

case "$UNP_OUTPUT" in
  *"no parseable test summary"*) echo "PASS: unparseable summary is reported as such"; PASS=$((PASS + 1)) ;;
  *)                             echo "FAIL: unparseable summary not reported"; FAIL=$((FAIL + 1)) ;;
esac

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
