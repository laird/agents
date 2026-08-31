#!/bin/bash
# tests/test_merge_conflict_advisory.sh — pins #1766: merge-to-integration.sh
# must NOT abort+escalate (remove 'working', add 'needs-clarification') on the
# FIRST merge conflict. It leaves the conflict ON DISK for the caller (the
# /fix worker that just wrote the fix, sharing this same checkout) to resolve
# directly, posts an advisory-only comment, and exits 3 — a distinct code from
# 1 (push failure) and 2 (test failure). The caller escalates to
# needs-clarification itself only if its own resolution attempt also fails.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$ROOT/plugins/autocoder/scripts"

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ── Fixture: a fakebin with the real merge-to-integration.sh but a stub
#    issue-fns.sh that just logs calls instead of hitting gh/the file backend.
mkdir -p "$TMP/fakebin"
cp "$SCRIPT_DIR/merge-to-integration.sh" "$TMP/fakebin/"
cp "$SCRIPT_DIR/api-push.py" "$TMP/fakebin/" 2>/dev/null || true

CALL_LOG="$TMP/calls.log"
: > "$CALL_LOG"
cat > "$TMP/fakebin/issue-fns.sh" << STUB
#!/bin/bash
issue_update()  { echo "issue_update \$*" >> "$CALL_LOG"; }
issue_comment() { echo "issue_comment \$*" >> "$CALL_LOG"; }
STUB

# ── Git fixture: a bare "origin" plus a feature-branch checkout that will
#    conflict with what lands on origin/main in the meantime.
BARE="$TMP/origin.git"
git init --bare -q "$BARE"

WORK="$TMP/work"
git init -q "$WORK"
(
  cd "$WORK"
  git config user.email "test@example.com"; git config user.name "Test"
  echo "original" > conflict.txt
  git add conflict.txt
  git commit -q -m "initial"
  git branch -M main
  git remote add origin "$BARE"
  git push -q origin main
  git checkout -q -b feature/test-1766
  echo "feature change" > conflict.txt
  git commit -q -am "feature change"
)

# Advance origin/main with a conflicting edit to the same line, via a second clone.
OTHER="$TMP/other"
git clone -q "$BARE" "$OTHER" 2>/dev/null
(
  cd "$OTHER"
  git checkout -q main
  git config user.email "test@example.com"; git config user.name "Test"
  echo "sibling change" > conflict.txt
  git commit -q -am "sibling change on main"
  git push -q origin main
)

# ── Run merge-to-integration.sh from the feature checkout. Expect a conflict.
cd "$WORK"
OUT=$(bash "$TMP/fakebin/merge-to-integration.sh" \
  --feature feature/test-1766 --issue 88801 --integration main --test-cmd "true" 2>&1)
RC=$?

[ "$RC" -eq 3 ] && ok "exits 3 on conflict (distinct from 1=push-failure, 2=test-failure)" \
  || bad "exit code on conflict (got $RC, want 3)"

if git status --short | grep -q "^UU conflict.txt"; then
  ok "conflict left ON DISK (not aborted) — caller can resolve it directly"
else
  bad "conflict was aborted/cleared instead of being left for the caller to resolve"
fi

if grep -q "issue_update" "$CALL_LOG"; then
  bad "issue_update was called on first conflict — label was changed (the #1766 regression)"
else
  ok "no issue_update call on first conflict — 'working' label untouched, no needs-clarification added"
fi

if grep -q "issue_comment" "$CALL_LOG"; then
  ok "an advisory comment was posted"
else
  bad "no comment posted at all — the fix worker/human has no signal a conflict happened"
fi

if grep -qi "needs manual resolution" "$CALL_LOG" || grep -qi "close this issue" "$CALL_LOG"; then
  bad "comment still reads as a hard human-escalation (pre-#1766 wording)"
else
  ok "comment reads as advisory, not a hard escalation"
fi

TOTAL=$((PASS + FAIL))
echo "$PASS passed / $FAIL failed / $TOTAL total"
[ "$FAIL" -eq 0 ]
