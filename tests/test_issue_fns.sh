#!/bin/bash
# tests/test_issue_fns.sh — tests for issue-fns.sh dispatch and translation
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

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if ! echo "$haystack" | grep -q "$needle"; then
    echo "PASS: $label"; PASS=$((PASS + 1))
  else
    echo "FAIL: $label — '$needle' unexpectedly in output"; FAIL=$((FAIL + 1))
  fi
}

# ── Set up a mock file backend ─────────────────────────────────────────────
TMP=$(mktemp -d)
ISSUES_DIR="$TMP/.issues"
mkdir -p "$ISSUES_DIR"

# Pre-populate one open issue
cat > "$ISSUES_DIR/001.md" <<'EOF'
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

# ── Test: issue_list --priority translates to --label ─────────────────────
OUT=$(ISSUE_SOURCE=file ISSUE_DIR_PATH="$ISSUES_DIR" \
  bash -c "source $SCRIPT_DIR/issue-fns.sh; issue_list --priority P1" 2>/dev/null)
assert_contains "issue_list --priority produces JSON" '\[' "$OUT"

# ── Test: issue_get returns specific issue ─────────────────────────────────
OUT=$(ISSUE_SOURCE=file ISSUE_DIR_PATH="$ISSUES_DIR" \
  bash -c "source $SCRIPT_DIR/issue-fns.sh; issue_get 1" 2>/dev/null)
assert_contains "issue_get returns issue 1" '"number": 1' "$OUT"

# ── Test: issue_update --add-label ────────────────────────────────────────
ISSUE_SOURCE=file ISSUE_DIR_PATH="$ISSUES_DIR" \
  bash -c "source $SCRIPT_DIR/issue-fns.sh; issue_update 1 --add-label needs-design" 2>/dev/null
assert_contains "issue_update adds label" 'needs-design' "$(cat "$ISSUES_DIR/001.md")"

# ── Test: issue_close ─────────────────────────────────────────────────────
ISSUE_SOURCE=file ISSUE_DIR_PATH="$ISSUES_DIR" \
  bash -c "source $SCRIPT_DIR/issue-fns.sh; issue_close 1 --comment 'Fixed.'" 2>/dev/null
assert_contains "issue_close sets status closed" 'status: closed' "$(cat "$ISSUES_DIR/001.md")"

# ── Test: issue_create ────────────────────────────────────────────────────
OUT=$(ISSUE_SOURCE=file ISSUE_DIR_PATH="$ISSUES_DIR" \
  bash -c "source $SCRIPT_DIR/issue-fns.sh; issue_create --title 'New one' --body 'Details'" 2>/dev/null)
assert_contains "issue_create returns number" '"number"' "$OUT"

rm -rf "$TMP"
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
