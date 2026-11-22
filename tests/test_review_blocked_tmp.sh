#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255: never write the real event logs
# tests/test_review_blocked_tmp.sh — /review-blocked keeps its issue queue in a private
# mktemp file per session, never a fixed /tmp path two sessions share (#329).
#
# 1. No copy of the command names /tmp/blocked-issues*.
# 2. The queue-advance block (Step 5), run against a fixture, drops one issue per run,
#    still writes valid JSON for the last one, and removes the file when the queue empties.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

COPIES="plugins/autocoder/commands/review-blocked.md .agent/workflows/review-blocked.md .pi/prompts/review-blocked.md"
for f in $COPIES; do
  grep -q "/tmp/blocked-issues" "$f" && bad "$f still names a fixed /tmp/blocked-issues path" || ok "$f names no fixed temp path"
  grep -q 'BLOCKED_FILE=$(mktemp' "$f" && ok "$f makes its queue file with mktemp" || bad "$f has no mktemp queue file"
done

for f in $COPIES; do
  # The Step 5 block: from its first comment to the closing fence.
  awk '/^# Remove processed issue from queue/{on=1} on&&/^```/{exit} on' "$f" > "$TMP/step5.sh"
  [ -s "$TMP/step5.sh" ] || { bad "$f: Step 5 block not found"; continue; }
  BLOCKED_FILE=$(mktemp "$TMP/autocoder-blocked-issues.XXXXXX")
  echo '{"issues":[{"number":1},{"number":2}],"total":2,"summary":{}}' > "$BLOCKED_FILE"
  out=$(BLOCKED_FILE="$BLOCKED_FILE" bash "$TMP/step5.sh" 2>&1)
  [ "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["issues"][0]["number"])' < "$BLOCKED_FILE")" = 2 ] \
    && ok "$f: advancing drops the reviewed issue" || bad "$f: queue not advanced: $out"
  printf '%s\n' "$out" | grep -q "1 blocked issue(s) remaining" && ok "$f: reports one left" || bad "$f: wrong remaining count: $out"
  out=$(BLOCKED_FILE="$BLOCKED_FILE" bash "$TMP/step5.sh" 2>&1)
  printf '%s\n' "$out" | grep -q "All blocked issues have been reviewed" && ok "$f: the last issue ends the review" || bad "$f: last issue did not end the review: $out"
  [ ! -e "$BLOCKED_FILE" ] && ok "$f: the queue file is removed at the end" || bad "$f: the queue file was left behind"
  ls "$TMP" | grep -q "autocoder-blocked-issues.*\." && bad "$f: a rewrite temp file was left: $(ls "$TMP")" || ok "$f: no rewrite temp file left"
  out=$(env -u BLOCKED_FILE bash "$TMP/step5.sh" 2>&1)
  printf '%s\n' "$out" | grep -q "set BLOCKED_FILE" && ok "$f: an unset BLOCKED_FILE stops the block" || bad "$f: unset BLOCKED_FILE not caught: $out"
done

TOTAL=$((PASS + FAIL))
echo "$PASS passed / $FAIL failed / $TOTAL total"
[ "$FAIL" -eq 0 ]
