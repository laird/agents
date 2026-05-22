#!/bin/bash
# tests/test_issue_fns.sh — tests for issue-fns.sh thin dispatcher.
#
# The dispatcher's sole job is to route verb calls to the configured
# backend script. These tests use the file backend (issues-file.py)
# pointed at a temporary bucket-layout .issues/ directory.

PASS=0; FAIL=0
SCRIPT_DIR="plugins/autocoder/scripts"

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -q "$needle"; then
    echo "PASS: $label"; PASS=$((PASS + 1))
  else
    echo "FAIL: $label — '$needle' not in output"; FAIL=$((FAIL + 1))
  fi
}

# ── Set up a bucket-layout file backend ────────────────────────────────────
TMP=$(mktemp -d)
ISSUES_DIR="$TMP/.issues"
mkdir -p "$ISSUES_DIR/open" "$ISSUES_DIR/working" "$ISSUES_DIR/blocked" "$ISSUES_DIR/closed"

# Pre-populate one open issue
cat > "$ISSUES_DIR/open/001.md" <<'EOF'
---
number: 1
title: Test issue
labels: [bug]
status: open
---
Body text.
EOF

# ── Test: issue_list via file backend ─────────────────────────────────────
OUT=$(ISSUE_SOURCE=file ISSUE_DIR_PATH="$ISSUES_DIR" \
  bash -c "source $SCRIPT_DIR/issue-fns.sh; issue_list" 2>/dev/null)
assert_contains "issue_list returns JSON" '"title"' "$OUT"
assert_contains "issue_list returns test issue" 'Test issue' "$OUT"

# ── Test: issue_get returns specific issue ─────────────────────────────────
OUT=$(ISSUE_SOURCE=file ISSUE_DIR_PATH="$ISSUES_DIR" \
  bash -c "source $SCRIPT_DIR/issue-fns.sh; issue_get 1" 2>/dev/null)
assert_contains "issue_get returns issue 1" '"number": 1' "$OUT"

# ── Test: issue_update --add-label (non-blocking, no rename) ──────────────
ISSUE_SOURCE=file ISSUE_DIR_PATH="$ISSUES_DIR" \
  bash -c "source $SCRIPT_DIR/issue-fns.sh; issue_update 1 --add-label P1" 2>/dev/null
assert_contains "issue_update --add-label P1 (non-blocking) preserves bucket" 'P1' "$(cat "$ISSUES_DIR/open/001.md")"

# ── Test: issue_update --add-label needs-design moves to blocked/ ─────────
ISSUE_SOURCE=file ISSUE_DIR_PATH="$ISSUES_DIR" \
  bash -c "source $SCRIPT_DIR/issue-fns.sh; issue_update 1 --add-label needs-design" 2>/dev/null
if [ -f "$ISSUES_DIR/blocked/001.md" ] && [ ! -f "$ISSUES_DIR/open/001.md" ]; then
  echo "PASS: issue_update --add-label needs-design moves to blocked/"; PASS=$((PASS + 1))
else
  echo "FAIL: bucket transition didn't happen"; FAIL=$((FAIL + 1))
fi

# ── Test: issue_claim (rename open → working) ─────────────────────────────
# Use a fresh issue 2 without blocking labels for clean claim/release flow
cat > "$ISSUES_DIR/open/002.md" <<'EOF'
---
number: 2
title: Claimable issue
labels: [bug]
status: open
---
Body.
EOF

ISSUE_SOURCE=file ISSUE_DIR_PATH="$ISSUES_DIR" \
  bash -c "source $SCRIPT_DIR/issue-fns.sh; issue_claim 2" 2>/dev/null
if [ -f "$ISSUES_DIR/working/002.md" ] && [ ! -f "$ISSUES_DIR/open/002.md" ]; then
  echo "PASS: issue_claim moves open → working"; PASS=$((PASS + 1))
else
  echo "FAIL: claim didn't rename"; FAIL=$((FAIL + 1))
fi

# ── Test: issue_release (rename working → open since no blocking labels) ──
ISSUE_SOURCE=file ISSUE_DIR_PATH="$ISSUES_DIR" \
  bash -c "source $SCRIPT_DIR/issue-fns.sh; issue_release 2" 2>/dev/null
if [ -f "$ISSUES_DIR/open/002.md" ] && [ ! -f "$ISSUES_DIR/working/002.md" ]; then
  echo "PASS: issue_release moves working → open"; PASS=$((PASS + 1))
else
  echo "FAIL: release didn't rename"; FAIL=$((FAIL + 1))
fi

# ── Test: issue_any_claimable (exit 0 when open/ non-empty) ──────────────
ISSUE_SOURCE=file ISSUE_DIR_PATH="$ISSUES_DIR" \
  bash -c "source $SCRIPT_DIR/issue-fns.sh; issue_any_claimable" 2>/dev/null
RC=$?
if [ "$RC" -eq 0 ]; then
  echo "PASS: issue_any_claimable exits 0 when claimable work exists"; PASS=$((PASS + 1))
else
  echo "FAIL: any-claimable should be 0 (got $RC)"; FAIL=$((FAIL + 1))
fi

# ── Test: issue_close moves to closed/ ────────────────────────────────────
ISSUE_SOURCE=file ISSUE_DIR_PATH="$ISSUES_DIR" \
  bash -c "source $SCRIPT_DIR/issue-fns.sh; issue_close 2 --comment 'Fixed.'" 2>/dev/null
if [ -f "$ISSUES_DIR/closed/002.md" ] && [ ! -f "$ISSUES_DIR/open/002.md" ]; then
  echo "PASS: issue_close moves to closed/"; PASS=$((PASS + 1))
else
  echo "FAIL: close didn't rename"; FAIL=$((FAIL + 1))
fi

# Move issue 1 to closed/ as well to empty open/ for the next test
ISSUE_SOURCE=file ISSUE_DIR_PATH="$ISSUES_DIR" \
  bash -c "source $SCRIPT_DIR/issue-fns.sh; issue_close 1" 2>/dev/null || true

# ── Test: issue_any_claimable (exit 1 when open/ empty) ──────────────────
ISSUE_SOURCE=file ISSUE_DIR_PATH="$ISSUES_DIR" \
  bash -c "source $SCRIPT_DIR/issue-fns.sh; issue_any_claimable" 2>/dev/null
if [ "$?" -eq 1 ]; then
  echo "PASS: issue_any_claimable exits 1 when no claimable work"; PASS=$((PASS + 1))
else
  echo "FAIL: any-claimable should be 1 on empty open/"; FAIL=$((FAIL + 1))
fi

# ── Test: issue_create returns number ─────────────────────────────────────
OUT=$(ISSUE_SOURCE=file ISSUE_DIR_PATH="$ISSUES_DIR" \
  bash -c "source $SCRIPT_DIR/issue-fns.sh; issue_create --title 'New one' --body 'Details'" 2>/dev/null)
assert_contains "issue_create returns number" '"number"' "$OUT"

rm -rf "$TMP"
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
