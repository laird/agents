#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255: never write the real event logs
# tests/test_review_blocked_md.sh — /review-blocked --prepare (#312, part of #308).
#
# The command text must strip --prepare before fetch-blocked-issues.sh (which
# rejects unknown options), key analyses with review-blocked-server.py --key (the
# key the review page looks up), skip fresh ones, and ask nothing while preparing.
# Both the Claude and Antigravity copies are checked.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
has() { if grep -qF -- "$3" "$2"; then ok "$1"; else bad "$1 — '$3' not in $2"; fi; }

for f in plugins/autocoder/commands/review-blocked.md .agent/workflows/review-blocked.md; do
  F="$ROOT/$f"
  has "$f: documents /review-blocked --prepare" "$F" "/review-blocked --prepare"
  has "$f: strips --prepare from the fetch arguments" "$F" 'fetch-blocked-issues.sh" "${FETCH_ARGS[@]}"'
  has "$f: keys analyses with the server's --key" "$F" 'review-blocked-server.py" --key "$ISSUE_NUM"'
  has "$f: skips an issue whose cached analysis is fresh" "$F" 'echo "FRESH #$ISSUE_NUM"'
  has "$f: stores analyses under that key" "$F" 'blocked-analysis-cache.py" put "$ISSUE_NUM" --updated-at "$KEY"'
  has "$f: the interactive flow reuses a fresh analysis" "$F" 'get "$ISSUE_NUM" --updated-at "$ANALYSIS_KEY"'
  PREP=$(sed -n '/^## Prepare Mode/,/^## Blocking Labels/p' "$F")
  [ -n "$PREP" ] && ok "$f: has a Prepare Mode section" || bad "$f: no Prepare Mode section"
  if printf '%s' "$PREP" | grep -q "AskUserQuestion" && ! printf '%s' "$PREP" | grep -q "never AskUserQuestion"; then
    bad "$f: Prepare Mode mentions AskUserQuestion other than to forbid it"
  else
    ok "$f: Prepare Mode asks nothing"
  fi
done

echo ""
echo "Tests: $FAIL failed, $PASS passed, $((PASS + FAIL)) total"
[ "$FAIL" -eq 0 ]
