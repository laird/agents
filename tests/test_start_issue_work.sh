#!/bin/bash
# Verify start-issue-work.sh establishes the visible issue ownership contract.

set -euo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)/plugins/autocoder/scripts"

assert_eq() {
  local label="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    echo "PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $label — want '$want', got '$got'"
    FAIL=$((FAIL + 1))
  fi
}

assert_file() {
  local label="$1" path="$2"
  if [ -f "$path" ]; then
    echo "PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $label — missing $path"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local label="$1" path="$2" needle="$3"
  if grep -Fq "$needle" "$path"; then
    echo "PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $label — did not find '$needle' in $path"
    FAIL=$((FAIL + 1))
  fi
}

TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT
MAIN="$TMP/main"
mkdir -p "$MAIN"
cd "$MAIN"
git init --quiet
git config user.email test@example.com
git config user.name "Test"
echo "test" > README.md
git add README.md
git commit --quiet -m "initial"

mkdir -p "$MAIN/.issues/open" "$MAIN/.issues/working" "$MAIN/.issues/blocked" "$MAIN/.issues/closed"
cat > "$MAIN/.autocoder.json" <<EOF
{"issueSource": "file", "issueDir": "$MAIN/.issues"}
EOF
cat > "$MAIN/.issues/open/011.md" <<EOF
---
number: 11
title: Real work
priority: P1
labels: [bug, P1]
status: open
---
Body.
EOF

bash "$SCRIPT_DIR/start-issue-work.sh" 11

assert_eq "switched to issue branch" "feature/issue-11" "$(git branch --show-current)"
assert_file "issue moved to working bucket" "$MAIN/.issues/working/011.md"
assert_contains "working label set" "$MAIN/.issues/working/011.md" "working"
assert_contains "start marker written" "$MAIN/.issues/working/011.md" "Automated Fix Started"
assert_contains "implementation marker written" "$MAIN/.issues/working/011.md" "Implementation Started"
assert_contains "branch included in comment" "$MAIN/.issues/working/011.md" "feature/issue-11"

bash "$SCRIPT_DIR/start-issue-work.sh" 11
assert_eq "same branch remains resumable" "feature/issue-11" "$(git branch --show-current)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
