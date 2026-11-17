#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255: never write the real event logs
# tests/test_retro_reverts.sh — /retro step 1.2 counts reverts from the sentinel's
# Autocoder-Reverts trailers via revert-rate.sh, not a keyword grep (#251).
#
# Runs the block exactly as retro.md documents it, in a private temp repo.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

block() {  # the bash block under "**1.2 Analyze git log**"
  awk '/^\*\*1\.2 Analyze git log\*\*/{f=1} f&&/^```bash/{g=1;next} g&&/^```/{exit} g' "$1"
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
block "$ROOT/plugins/autocoder/commands/retro.md" > "$TMP/claude.sh"
block "$ROOT/.agent/workflows/retro.md" > "$TMP/agent.sh"
[ -s "$TMP/claude.sh" ] && cmp -s "$TMP/claude.sh" "$TMP/agent.sh" \
  && ok "the Claude and Antigravity copies of step 1.2 match" || bad "step 1.2 differs between copies (or is missing)"

cd "$TMP" || exit 1
git init -q repo && cd repo || exit 1
git config user.email t@example.com; git config user.name T
c() { echo "$RANDOM$RANDOM" >> f; git add f; git commit -q "$@"; }
c -m "#1: base"
c -m "#2: break the gate"; CULPRIT=$(git rev-parse HEAD)
c -m "Revert autocoder push ${CULPRIT:0:7} (issue #2)" -m "Autocoder-Reverts: ${CULPRIT}
Autocoder-Reverts-Issue: 2"
c -m "#3: oops, correct the typo"
c -m "#4: revert the colour change in words only"

OUT=$(SCRIPT_DIR="$ROOT/plugins/autocoder/scripts" SINCE_DATE="" bash "$TMP/claude.sh" 2>&1)
grep -q 'fatal:' <<<"$OUT" && bad "git errors in the block: $OUT" || ok "the default 1-year window runs without git errors"
grep -q '1 sentinel revert(s) / 4 landed issue(s) = 25.0%; reverted: #2' <<<"$OUT" \
  && ok "revert count, rate and reverted issue come from the trailer" || bad "rate line: $OUT"
CORR=$(sed -n '/Human corrections/,/multiple fix attempts/p' <<<"$OUT")
grep -q '#3: oops' <<<"$CORR" && ok "a hand correction is listed under human corrections" || bad "corrections: $CORR"
grep -q 'Revert autocoder push' <<<"$CORR" && bad "the sentinel revert is listed as a human correction" \
  || ok "the sentinel revert is not counted again as a human correction"

OUT=$(SCRIPT_DIR="$TMP/none" bash "$TMP/claude.sh" 2>&1)
grep -q 'revert-rate.sh not found' <<<"$OUT" && ok "an older plugin without revert-rate.sh gets a warning, not an error" \
  || bad "missing script: $OUT"

echo ""
echo "Tests: $FAIL failed, $PASS passed, $((PASS + FAIL)) total"
[ "$FAIL" -eq 0 ]
