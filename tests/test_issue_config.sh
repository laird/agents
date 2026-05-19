#!/bin/bash
# tests/test_issue_config.sh — smoke tests for issue-config.sh
set -e
PASS=0; FAIL=0
SCRIPT="plugins/autocoder/scripts/issue-config.sh"

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "PASS: $label"; PASS=$((PASS + 1))
  else
    echo "FAIL: $label — expected '$expected', got '$actual'"; FAIL=$((FAIL + 1))
  fi
}

# Test: script is sourceable without errors (ISSUE_SOURCE pre-set triggers early return)
assert_eq "script is sourceable" "0" "$(ISSUE_SOURCE=github bash -c "source $SCRIPT; echo 0" 2>/dev/null || echo 1)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
