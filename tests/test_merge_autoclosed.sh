#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255: never write the real event logs
# tests/test_merge_autoclosed.sh — when the issue is closed while the merge job runs
# (GitHub closes it the moment the push lands if a commit says "Fix #N"), the job
# still posts its landing summary and retires `merging` (#209).
#
# It used to see "already closed" in _close_or_park and return silently: no summary,
# no review record, and a closed issue left carrying `merging` (seen on #145, #195).
# Here the gate command closes the issue as a side effect, which is the same race.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$ROOT/plugins/autocoder/scripts"
MTI="$SCRIPT_DIR/merge-to-integration.sh"
ISSUES_PY="$SCRIPT_DIR/issues-file.py"
ISSUE=20901

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export ISSUE_SOURCE=file
export AUTOCODER_TMP="$TMP/tmp"; mkdir -p "$AUTOCODER_TMP"
export ISSUE_DIR_PATH="$TMP/issues"
export AUTOCODER_GATE_CACHE_DIR="$TMP/gate-cache"
export AUTOCODER_MERGE_EVENTS="$TMP/events.jsonl"
export AUTOCODER_SPOT_CHECK_RATE=0
export CLAUDE_CODE_SHIP_BRANCH=master
unset AUTOCODER_MERGE_ON_RED_BASE AUTOCODER_SCOPED_REGATE

mkdir -p "$TMP/issues"/{open,working,blocked,closed}
printf -- '---\nnumber: %s\ntitle: Autoclosed\npriority: P2\nlabels: [bug]\nstatus: open\n---\nBody.\n' "$ISSUE" > "$TMP/issues/open/${ISSUE}.md"
python3 "$ISSUES_PY" claim "$ISSUE" >/dev/null

git init --bare -q "$TMP/origin.git"
git init -q "$TMP/worker"
cd "$TMP/worker" || exit 1
git config user.email t@example.com; git config user.name T
git remote add origin "$TMP/origin.git"
echo base > README.md; mkdir -p src; echo base > src/a.sh
git add -A; git commit -q -m init; git branch -M master; git push -q origin master master:master-green
git checkout -q -b feature/code master
echo change > src/a.sh; git commit -qam "fix"
printf '## Intent\nSummary text that must reach the issue.\n' > "$TMP/summary.md"

# The gate passes, and closes the issue on the way, as GitHub would on the push.
GATE="python3 '$ISSUES_PY' close $ISSUE >/dev/null 2>&1; true"
OUT=$(bash "$MTI" --feature feature/code --issue $ISSUE --integration master --test-cmd "$GATE" \
  --summary-file "$TMP/summary.md" --own-issue 2>&1); RC=$?

[ "$RC" -eq 0 ] && ok "merge exits 0" || bad "merge rc=$RC: $(tail -5 <<<"$OUT")"
[ "$(git -C "$TMP/origin.git" rev-parse master)" != "$(git -C "$TMP/worker" rev-parse master)" ] \
  && ok "the change landed on origin/master" || bad "nothing landed"
F=$(ls "$TMP"/issues/*/"${ISSUE}.md" 2>/dev/null | head -1)
grep -q "Summary text that must reach the issue." "$F" && ok "the landing summary was posted on the closed issue" \
  || bad "summary missing from the issue: $(cat "$F")"
grep -q "Landed on \`master\`" "$F" && ok "the comment names the landing" || bad "no landing comment"
LABELS=$(python3 "$ISSUES_PY" get "$ISSUE" | python3 -c 'import json,sys; print(" ".join(sorted(l["name"] for l in json.load(sys.stdin)["labels"])))')
case " $LABELS " in *" merging "*) bad "closed issue still carries merging ($LABELS)" ;; *) ok "merging retired ($LABELS)" ;; esac
echo "$OUT" | grep -q "posted the landing summary anyway" && ok "log says so" || bad "log: $(tail -3 <<<"$OUT")"

# ── fix.md no longer titles merge-mode commits with a closing keyword ──────────
for f in plugins/autocoder/commands/fix.md .agent/workflows/fix.md; do
  n=$(grep -c 'git commit -m "Fix #' "$ROOT/$f")
  [ "$n" -eq 0 ] && ok "$f: no 'Fix #N' commit template" || bad "$f: $n 'Fix #N' commit templates left"
done

echo ""
echo "Tests: $FAIL failed, $PASS passed, $((PASS + FAIL)) total"
[ "$FAIL" -eq 0 ]
