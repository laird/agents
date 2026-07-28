#!/bin/bash
# tests/test_issue_fns.sh — tests for issue-fns.sh thin dispatcher.
#
# The dispatcher's sole job is to route verb calls to the configured
# backend script. These tests use the file backend (issues-file.py)
# pointed at a temporary bucket-layout .issues/ directory.
#
# IMPORTANT — why this test runs inside its own throwaway git repo:
#
# issue-fns.sh sources issue-config.sh, which deliberately treats the *repo's*
# .autocoder.json as authoritative over an inherited ISSUE_SOURCE. Setting
# `ISSUE_SOURCE=file` on the command line therefore does NOT pin the backend:
# config resolution walks to the enclosing worktree and honours whatever that
# repo declares. When this repo declares `issueSource: github`, every assertion
# below silently ran against the live GitHub tracker — the file-backend checks
# failed, and `issue_create` filed a real "New one" issue on every single run
# (18 of them accumulated; see #47).
#
# So the fix is to give config resolution a repo of our own: a temp git repo
# carrying a .autocoder.json that points at the temp .issues/ directory. A
# poisoned `gh` on PATH then guarantees that a future regression in backend
# resolution fails loudly instead of mutating the real tracker.

PASS=0; FAIL=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../plugins/autocoder/scripts" && pwd)"

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -q "$needle"; then
    echo "PASS: $label"; PASS=$((PASS + 1))
  else
    echo "FAIL: $label — '$needle' not in output"; FAIL=$((FAIL + 1))
  fi
}

# ── Set up a bucket-layout file backend inside its own git repo ────────────
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
ISSUES_DIR="$TMP/.issues"
mkdir -p "$ISSUES_DIR/open" "$ISSUES_DIR/working" "$ISSUES_DIR/blocked" "$ISSUES_DIR/closed"

git -C "$TMP" init -q
cat > "$TMP/.autocoder.json" <<EOF
{
  "issueSource": "file",
  "issueDir": "$ISSUES_DIR"
}
EOF

# Poison `gh` so any accidental route to the GitHub backend fails loudly and
# leaves a trace, rather than silently writing to the real issue tracker.
mkdir -p "$TMP/bin"
GH_TRIPWIRE="$TMP/gh-was-called"
cat > "$TMP/bin/gh" <<EOF
#!/bin/bash
echo "REAL gh INVOKED FROM TEST: \$*" >> "$GH_TRIPWIRE"
echo "test_issue_fns.sh must never shell out to gh" >&2
exit 97
EOF
chmod +x "$TMP/bin/gh"

# Run a dispatcher expression with cwd inside the temp repo, so issue-config.sh
# resolves *that* repo's .autocoder.json rather than the checkout we live in.
run_ifns() {
  (cd "$TMP" && PATH="$TMP/bin:$PATH" \
     bash -c "source '$SCRIPT_DIR/issue-fns.sh'; $1") 2>/dev/null
}

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
OUT=$(run_ifns "issue_list")
assert_contains "issue_list returns JSON" '"title"' "$OUT"
assert_contains "issue_list returns test issue" 'Test issue' "$OUT"

# ── Test: issue_get returns specific issue ─────────────────────────────────
OUT=$(run_ifns "issue_get 1")
assert_contains "issue_get returns issue 1" '"number": 1' "$OUT"

# ── Test: issue_update --add-label (non-blocking, no rename) ──────────────
run_ifns "issue_update 1 --add-label P1"
assert_contains "issue_update --add-label P1 (non-blocking) preserves bucket" 'P1' "$(cat "$ISSUES_DIR/open/001.md")"

# ── Test: issue_update --add-label needs-design moves to blocked/ ─────────
run_ifns "issue_update 1 --add-label needs-design"
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

run_ifns "issue_claim 2"
if [ -f "$ISSUES_DIR/working/002.md" ] && [ ! -f "$ISSUES_DIR/open/002.md" ]; then
  echo "PASS: issue_claim moves open → working"; PASS=$((PASS + 1))
else
  echo "FAIL: claim didn't rename"; FAIL=$((FAIL + 1))
fi

# ── Test: issue_release (rename working → open since no blocking labels) ──
run_ifns "issue_release 2"
if [ -f "$ISSUES_DIR/open/002.md" ] && [ ! -f "$ISSUES_DIR/working/002.md" ]; then
  echo "PASS: issue_release moves working → open"; PASS=$((PASS + 1))
else
  echo "FAIL: release didn't rename"; FAIL=$((FAIL + 1))
fi

# ── Test: issue_any_claimable (exit 0 when open/ non-empty) ──────────────
run_ifns "issue_any_claimable"
RC=$?
if [ "$RC" -eq 0 ]; then
  echo "PASS: issue_any_claimable exits 0 when claimable work exists"; PASS=$((PASS + 1))
else
  echo "FAIL: any-claimable should be 0 (got $RC)"; FAIL=$((FAIL + 1))
fi

# ── Test: issue_close moves to closed/ ────────────────────────────────────
run_ifns "issue_close 2 --comment 'Fixed.'"
if [ -f "$ISSUES_DIR/closed/002.md" ] && [ ! -f "$ISSUES_DIR/open/002.md" ]; then
  echo "PASS: issue_close moves to closed/"; PASS=$((PASS + 1))
else
  echo "FAIL: close didn't rename"; FAIL=$((FAIL + 1))
fi

# Move issue 1 to closed/ as well to empty open/ for the next test
run_ifns "issue_close 1" || true

# ── Test: issue_any_claimable (exit 1 when open/ empty) ──────────────────
run_ifns "issue_any_claimable"
RC=$?
if [ "$RC" -eq 1 ]; then
  echo "PASS: issue_any_claimable exits 1 when no claimable work"; PASS=$((PASS + 1))
else
  echo "FAIL: any-claimable should be 1 on empty open/ (got $RC)"; FAIL=$((FAIL + 1))
fi

# ── Test: issue_create returns number ─────────────────────────────────────
OUT=$(run_ifns "issue_create --title 'New one' --body 'Details'")
assert_contains "issue_create returns number" '"number"' "$OUT"

# ── Test: the created issue landed in the temp dir, not the real tracker ──
if ls "$ISSUES_DIR"/open/*.md >/dev/null 2>&1; then
  echo "PASS: issue_create wrote to the temp file backend"; PASS=$((PASS + 1))
else
  echo "FAIL: issue_create did not write into $ISSUES_DIR/open/"; FAIL=$((FAIL + 1))
fi

# ── Test: no invocation ever shelled out to gh ────────────────────────────
# This is the guard against the regression that filed 18 junk issues (#47).
if [ -f "$GH_TRIPWIRE" ]; then
  echo "FAIL: test shelled out to real gh — $(wc -l < "$GH_TRIPWIRE") call(s):"
  sed 's/^/       /' "$GH_TRIPWIRE"
  FAIL=$((FAIL + 1))
else
  echo "PASS: no call reached the real gh CLI"; PASS=$((PASS + 1))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
