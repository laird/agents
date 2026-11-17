#!/bin/bash
# tests/test_merge_landed_then_edited.sh — a change that already landed (as a patch-equivalent
# commit) and was then edited by a sibling is recognised as landed, not escalated as
# "nothing landed"; a landed change that was REVERTED is still refused (#236).
#
# _nothing_left_to_land used to decide only by reverse-applying the feature diff to the
# integration tip. A later sibling edit to the same lines makes that fail, so the job
# escalated "dropped every commit… nothing landed" for work that had landed.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$ROOT/plugins/autocoder/scripts"
MTI="$SCRIPT_DIR/merge-to-integration.sh"
ISSUES_PY="$SCRIPT_DIR/issues-file.py"
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export ISSUE_SOURCE=file AUTOCODER_SPOT_CHECK_RATE=0 AUTOCODER_MERGE_QUEUE=0 CLAUDE_CODE_SHIP_BRANCH=master
export AUTOCODER_TMP="$TMP/tmp"; mkdir -p "$AUTOCODER_TMP"
export ISSUE_DIR_PATH="$TMP/issues" AUTOCODER_GATE_CACHE_DIR="$TMP/gate-cache" AUTOCODER_MERGE_EVENTS="$TMP/events.jsonl"
unset AUTOCODER_MERGE_ON_RED_BASE AUTOCODER_SCOPED_REGATE
mkdir -p "$TMP/issues"/{open,working,blocked,closed}

# setup <name> <issue>: origin + worker; feature/x changes line 2 of a.txt.
setup() {
  local d="$TMP/$1" n="$2"
  printf -- '---\nnumber: %s\ntitle: T\npriority: P3\nlabels: [bug]\nstatus: open\n---\nB.\n' "$n" > "$TMP/issues/open/$n.md"
  python3 "$ISSUES_PY" claim "$n" >/dev/null
  git init --bare -q "$d/origin.git"; git init -q "$d/w"
  cd "$d/w" || exit 1
  git config user.email t@example.com; git config user.name T
  git remote add origin "$d/origin.git"
  printf 'one\ntwo\nthree\n' > a.txt; git add -A; git commit -q -m base; git branch -M master
  git push -q origin master master:master-green
  git checkout -q -b feature/x; printf 'one\nTWO-feature\nthree\n' > a.txt; git commit -qam "feature edits line 2"
  FEAT=$(git rev-parse HEAD)
  # The same change lands on master under a different SHA (e.g. an earlier run's rebased push).
  git checkout -q master; git cherry-pick -x "$FEAT" >/dev/null; LANDED=$(git rev-parse HEAD)
}
state() { python3 "$ISSUES_PY" get "$1" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["state"])'; }

# ── 1. landed, then a sibling edited the same line ──────────────────────────
setup edited 23601
printf 'one\nTWO-sibling\nthree\n' > a.txt; git commit -qam "sibling edits line 2"; git push -q origin master
BEFORE=$(git -C "$TMP/edited/origin.git" rev-parse master)
OUT=$(cd "$TMP/edited/w" && bash "$MTI" --feature feature/x --issue 23601 --integration master \
  --test-cmd true --own-issue 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok "landed-then-edited: exits 0" || bad "landed-then-edited: rc=$RC: $(tail -6 <<<"$OUT")"
echo "$OUT" | grep -q "patch-equivalent" && ok "says it found the landed copy" || bad "no patch-equivalent message: $(tail -6 <<<"$OUT")"
echo "$OUT" | grep -q "NOT closing" && bad "still escalated as nothing landed" || ok "not escalated as nothing landed"
[ "$(git -C "$TMP/edited/origin.git" rev-parse master)" = "$BEFORE" ] && ok "nothing new pushed" || bad "origin/master moved"
[ "$(state 23601)" = "CLOSED" ] && ok "issue closed as landed" || bad "issue state $(state 23601)"

# ── 2. landed, then reverted: still refused ─────────────────────────────────
setup reverted 23602
git revert --no-edit "$LANDED" >/dev/null; git push -q origin master
OUT=$(cd "$TMP/reverted/w" && bash "$MTI" --feature feature/x --issue 23602 --integration master \
  --test-cmd true --own-issue 2>&1); RC=$?
[ "$RC" -ne 0 ] && ok "landed-then-reverted: refused (rc=$RC)" || bad "reverted change treated as landed"
echo "$OUT" | grep -q "NOT closing" && ok "says nothing landed" || bad "output: $(tail -6 <<<"$OUT")"
[ "$(state 23602)" != "CLOSED" ] && ok "reverted: issue left open" || bad "reverted issue was closed"

# ── 3. landed, then undone by hand (no "This reverts commit" message) ──────
# A manual undo or a squash/PR revert leaves no standard message; the lines are back to
# their pre-change state, so the change is not on the branch and must not be closed.
setup undone 23603
printf 'one\ntwo\nthree\n' > a.txt; git commit -qam "tidy up line 2"; git push -q origin master
OUT=$(cd "$TMP/undone/w" && bash "$MTI" --feature feature/x --issue 23603 --integration master \
  --test-cmd true --own-issue 2>&1); RC=$?
[ "$RC" -ne 0 ] && ok "landed-then-undone-by-hand: refused (rc=$RC)" || bad "manually undone change treated as landed"
[ "$(state 23603)" != "CLOSED" ] && ok "undone: issue left open" || bad "undone issue was closed"

echo ""
echo "Tests: $FAIL failed, $PASS passed, $((PASS + FAIL)) total"
[ "$FAIL" -eq 0 ]
