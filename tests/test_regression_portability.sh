#!/bin/bash
# Tests for portable stat parsing in the regression suite (issue #20).
#
# The bug: every statistic was parsed with `grep -oP`. -P is a GNU extension
# that BSD/macOS grep rejects, so on macOS each parse failed and the trailing
# `|| echo "0"` turned that failure into a zero — reporting `0/0 passed,
# 0 failed` no matter what actually happened. A red run looked exactly like a
# green one, on the swarm's default platform.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUITE="$ROOT/plugins/autocoder/scripts/regression-test.sh"

# Files the issue names as carrying -P occurrences.
GUARDED_FILES=(
  "plugins/autocoder/scripts/regression-test.sh"
  ".agent/scripts/regression-test.sh"
  "plugins/autocoder/commands/full-regression-test.md"
  ".agent/workflows/full-regression-test.md"
  "plugins/autocoder/commands/fix.md"
  ".agent/workflows/fix.md"
)

fail() { echo "FAIL: $1" >&2; exit 1; }

# Always parse with BSD grep explicitly, so this test reproduces macOS behavior
# even where a GNU grep shadows it on PATH.
BSD_GREP=/usr/bin/grep

# ── 1. No `grep -P` / `grep -oP` survives anywhere ───────────────────────────
for rel in "${GUARDED_FILES[@]}"; do
  f="$ROOT/$rel"
  [ -f "$f" ] || fail "missing guarded file: $rel"
  if "$BSD_GREP" -n -e 'grep -oP' -e 'grep -P' "$f" >/dev/null 2>&1; then
    n=$("$BSD_GREP" -c -e 'grep -oP' -e 'grep -P' "$f")
    fail "$rel still has $n grep -P occurrence(s)"
  fi
done

# ── 2. The suite is syntactically valid ──────────────────────────────────────
bash -n "$SUITE" || fail "regression-test.sh has a syntax error"

# ── 3. Parsers extract correct counts under BSD grep ─────────────────────────
# Source the suite's parse helpers without running the suite.
if ! "$BSD_GREP" -q 'parse_stat()' "$SUITE"; then
  fail "regression-test.sh does not expose a parse_stat helper"
fi

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Jest-style unit output
cat > "$TMP/unit.log" <<'EOF'
Tests:       5 failed, 3 passed, 8 total
EOF

# Playwright JSON-style e2e output
cat > "$TMP/e2e.json" <<'EOF'
{"stats":{"expected": 12,"unexpected": 4,"skipped": 2}}
EOF

# Playwright text-style e2e output
cat > "$TMP/e2e.txt" <<'EOF'
  7 passed (3.2s)
  2 failed
  1 skipped
EOF

# shellcheck source=/dev/null
source "$SUITE" --source-only 2>/dev/null || {
  # Fall back to extracting the helper if --source-only is unsupported.
  eval "$(sed -n '/^parse_stat()/,/^}/p' "$SUITE")"
}

check() { # label expected actual
  [ "$2" = "$3" ] || fail "$1: expected [$2], got [$3]"
}

check "unit passed"  "3"  "$(parse_stat "$TMP/unit.log" 'Tests:.*[^0-9]([0-9]+) passed')"
check "unit failed"  "5"  "$(parse_stat "$TMP/unit.log" 'Tests:[^0-9]*([0-9]+) failed')"
check "unit total"   "8"  "$(parse_stat "$TMP/unit.log" 'Tests:.*[^0-9]([0-9]+) total')"
check "e2e expected" "12" "$(parse_stat "$TMP/e2e.json" '"expected":[[:space:]]*([0-9]+)')"
check "e2e unexpect" "4"  "$(parse_stat "$TMP/e2e.json" '"unexpected":[[:space:]]*([0-9]+)')"
check "e2e skipped"  "2"  "$(parse_stat "$TMP/e2e.json" '"skipped":[[:space:]]*([0-9]+)')"
check "txt passed"   "7"  "$(parse_stat "$TMP/e2e.txt" '([0-9]+) passed')"
check "txt failed"   "2"  "$(parse_stat "$TMP/e2e.txt" '([0-9]+) failed')"

# ── 4. A missing stat is distinguishable from a real zero ────────────────────
# This is the heart of the bug: an unparseable log must NOT silently read as 0.
echo "total garbage, no stats here" > "$TMP/garbage.log"
MISSING=$(parse_stat "$TMP/garbage.log" '([0-9]+) passed' || true)
[ -z "$MISSING" ] || fail "unparseable log must yield empty, not '$MISSING' (a fake zero)"

# A genuine zero must still parse as "0", not as missing.
echo "0 passed" > "$TMP/zero.log"
check "real zero" "0" "$(parse_stat "$TMP/zero.log" '([0-9]+) passed')"

# ── 5. Unconfigured / unexecutable suites must not report green ──────────────
"$BSD_GREP" -q 'SUITE_STATUS\|not_configured\|skipped_unconfigured' "$SUITE" \
  || fail "suite does not track a configured/executed status separate from counts"

# The suite must not blindly default to npm/playwright when nothing is configured.
if "$BSD_GREP" -qE '^\s*(TEST_COMMAND|UNIT_COMMAND)="npm test"' "$SUITE"; then
  fail "suite still hard-defaults to 'npm test' for an unconfigured repo"
fi

# ── 6. `cmd | tee` must not mask the runner's exit status ────────────────────
# This was a second, independent false-green source: the suite ran the test
# command as `$CMD 2>&1 | tee log`, whose exit status is TEE's (always 0), so a
# failing runner was reported "✅ PASSED". Demonstrated on master with npm
# ENOENT. Every such invocation must read PIPESTATUS instead.
tee_invocations=$("$BSD_GREP" -cE '^\s*\$(UNIT|E2E)_TEST_CMD 2>&1 \| tee' "$SUITE" || true)
pipestatus_reads=$("$BSD_GREP" -c 'PIPESTATUS\[0\]' "$SUITE" || true)
[ "$tee_invocations" -eq 0 ] || [ "$pipestatus_reads" -ge "$tee_invocations" ] \
  || fail "runner piped to tee without reading PIPESTATUS ($tee_invocations pipes, $pipestatus_reads PIPESTATUS reads)"

# The old `if $CMD | tee ...; then PASSED` shape must be gone entirely.
"$BSD_GREP" -qE 'if \$(UNIT|E2E)_TEST_CMD 2>&1 \| tee' "$SUITE" \
  && fail "suite still branches on the exit status of tee, not the runner"

echo "ok regression-portability"
