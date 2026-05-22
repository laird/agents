#!/bin/bash
# tests/test_issues_file_cross_worktree.sh — verify Goal #5 of the design:
# all backend operations from a secondary worktree target the main worktree's
# .issues/ directory.

PASS=0; FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)/plugins/autocoder/scripts"

assert_eq() {
  local label="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    echo "PASS: $label"; PASS=$((PASS + 1))
  else
    echo "FAIL: $label — want '$want', got '$got'"; FAIL=$((FAIL + 1))
  fi
}

assert_exists() {
  local label="$1" path="$2"
  if [ -e "$path" ]; then
    echo "PASS: $label"; PASS=$((PASS + 1))
  else
    echo "FAIL: $label — '$path' missing"; FAIL=$((FAIL + 1))
  fi
}

# ── Set up: temp git repo as main worktree ────────────────────────────────
TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

MAIN="$TMP/main"
WT2="$TMP/wt2"
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
cat > "$MAIN/.issues/open/001.md" <<EOF
---
number: 1
title: Test issue
labels: [bug]
status: open
---
Body.
EOF

# Create a secondary worktree
git worktree add --quiet -b feature "$WT2" HEAD

# ── Test 1: ISSUE_DIR_PATH resolution from both worktrees ────────────────
MAIN_PATH=$(cd "$MAIN" && bash -c "source $SCRIPT_DIR/issue-config.sh && echo \$ISSUE_DIR_PATH")
WT2_PATH=$(cd "$WT2" && bash -c "source $SCRIPT_DIR/issue-config.sh && echo \$ISSUE_DIR_PATH")
assert_eq "ISSUE_DIR_PATH from main worktree" "$MAIN/.issues" "$MAIN_PATH"
assert_eq "ISSUE_DIR_PATH from secondary worktree resolves to main's .issues/" "$MAIN/.issues" "$WT2_PATH"

# ── Test 2: issue_list from secondary worktree returns main's issues ─────
OUT=$(cd "$WT2" && bash -c "source $SCRIPT_DIR/issue-fns.sh && issue_list --state open")
if echo "$OUT" | grep -q "Test issue"; then
  echo "PASS: issue_list from secondary worktree returns main's issue"; PASS=$((PASS + 1))
else
  echo "FAIL: issue_list didn't return main's issue"; FAIL=$((FAIL + 1))
fi

# ── Test 3: issue_claim from secondary worktree affects main's files ─────
cd "$WT2" && bash -c "source $SCRIPT_DIR/issue-fns.sh && issue_claim 1" 2>/dev/null
assert_exists "claim from wt2 moves file to main's working/" "$MAIN/.issues/working/001.md"
if [ ! -f "$MAIN/.issues/open/001.md" ]; then
  echo "PASS: claim from wt2 removed file from main's open/"; PASS=$((PASS + 1))
else
  echo "FAIL: file still in main's open/"; FAIL=$((FAIL + 1))
fi
# Ensure no stray .issues created in wt2
if [ ! -d "$WT2/.issues" ]; then
  echo "PASS: claim did NOT create .issues/ in secondary worktree"; PASS=$((PASS + 1))
else
  echo "FAIL: stray .issues/ in secondary worktree"; FAIL=$((FAIL + 1))
fi

# ── Test 4: issue_release from secondary worktree affects main ───────────
cd "$WT2" && bash -c "source $SCRIPT_DIR/issue-fns.sh && issue_release 1" 2>/dev/null
assert_exists "release from wt2 lands file in main's open/" "$MAIN/.issues/open/001.md"

# ── Test 5: issue_close from secondary worktree affects main ─────────────
cd "$WT2" && bash -c "source $SCRIPT_DIR/issue-fns.sh && issue_close 1" 2>/dev/null
assert_exists "close from wt2 lands file in main's closed/" "$MAIN/.issues/closed/001.md"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
