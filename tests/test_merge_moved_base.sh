#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255
# tests/test_merge_moved_base.sh — the base-alone retest measures the base the integrated
# tree was built on, and never takes another selection's cached pass for it (#375).
#   - master is red; its fix lands while this change's gate runs: the job re-syncs onto
#     the fixed tip and gates again, and lands, instead of blaming the change because the
#     NEW tip "passes alone";
#   - with the re-sync capped at 0, the base measured is the one the tree was built on
#     (red), so the change is not blamed either;
#   - a cached pass recorded for the base tree under the plain command (another change's
#     run) is not reused by the base-alone retest.

PASS=0; FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)/plugins/autocoder/scripts"
ISSUES_PY="$SCRIPT_DIR/issues-file.py"
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export AUTOCODER_SPOT_CHECK_RATE=0 ISSUE_SOURCE=file
export AUTOCODER_TMP="$TMP/tmp"; mkdir -p "$AUTOCODER_TMP"
export ISSUE_DIR_PATH="$TMP/issues"
export AUTOCODER_GATE_CACHE_DIR="$TMP/gate-cache"
export AUTOCODER_MERGE_EVENTS="$TMP/events.jsonl"
export CLAUDE_CODE_SHIP_BRANCH=master
unset AUTOCODER_MERGE_ON_RED_BASE AUTOCODER_SCOPED_REGATE AUTOCODER_GATE_RETEST_FILES AUTOCODER_MOVED_BASE_REGATES
mkdir -p "$TMP/issues"/{open,working,blocked,closed}

git init --bare -q "$TMP/origin.git"
git init -q "$TMP/worker"
cd "$TMP/worker" || exit 1
git config user.email t@example.com; git config user.name T
git remote add origin "$TMP/origin.git"
# master-green exists, so a red base may land (parked) rather than be refused.
echo base > README.md; echo good > t_broken.test; echo good > t_ok.test
git add -A; git commit -q -m init; git branch -M master; git push -q origin master master:master-green
git clone -q "$TMP/origin.git" "$TMP/fixer"
git -C "$TMP/fixer" config user.email f@example.com; git -C "$TMP/fixer" config user.name F

# break|fix master from the fixer clone (a landing by someone else).
master_set() {  # bad|good
  git -C "$TMP/fixer" pull -q origin master
  echo "$1" > "$TMP/fixer/t_broken.test"
  git -C "$TMP/fixer" commit -q -am "t_broken: $1"
  git -C "$TMP/fixer" push -q origin master
  git fetch -q origin; git checkout -q master; git reset -q --hard origin/master
}

# Diff-selected gate (src.txt maps to t_broken.test), as in test_merge_red_base_retest.sh.
# When $TMP/landfix exists the gate lands master's fix first, then runs: the fix lands
# while this change's gate is running on a tree built before it, and the shared
# origin/master ref moves with it (as a sibling job's fetch moves it).
# $1 = "full" selects every test file and names failures without a path.
cat > "$TMP/gate.sh" <<G
if [ -e "$TMP/landfix" ]; then
  rm -f "$TMP/landfix"
  ( cd "$TMP/fixer" && git pull -q origin master && echo good > t_broken.test \\
      && git commit -q -am "fix t_broken" && git push -q origin master ) >/dev/null 2>&1
  git fetch -q origin master   # a sibling's fetch: the shared origin/master ref moves mid-gate
fi
G
cat >> "$TMP/gate.sh" <<'G'
if [ "${1:-}" = full ]; then sel=$(ls *.test)
else sel=$(git diff --name-only origin/master HEAD | sed 's/^src\.txt$/t_broken.test/' | grep '\.test$'); fi
[ -n "${AUTOCODER_GATE_RETEST_FILES:-}" ] && sel=$AUTOCODER_GATE_RETEST_FILES
echo "selected: $(echo $sel)"
rc=0
for f in $sel; do
  if grep -q bad "$f" 2>/dev/null; then
    if [ "${1:-}" = full ]; then echo "::error::check ${f%.test} is broken"; else echo "FAIL $f"; fi
    rc=1
  fi
done
exit $rc
G

source "$SCRIPT_DIR/repo-id-fns.sh"
LOG=""
run_one() {  # <issue> <file to add> <content> <test-cmd>
  local issue="$1" state
  printf -- '---\nnumber: %s\ntitle: T\npriority: P2\nlabels: [bug]\nstatus: open\n---\nBody.\n' "$issue" > "$TMP/issues/open/${issue}.md"
  python3 "$ISSUES_PY" claim "$issue" >/dev/null
  git checkout -q -b "feature/i$issue" master
  echo "$3" > "$2"; git add -A; git commit -q -m "fix #$issue"; git push -q origin "feature/i$issue"
  state="$AUTOCODER_TMP/autocoder-merge-$(autocoder_repo_id "$TMP/worker")-${issue}"
  bash "$SCRIPT_DIR/merge-launch.sh" --feature "feature/i$issue" --issue "$issue" --integration master \
    --test-cmd "$4" --own-issue >/dev/null 2>&1 || { bad "launch $issue failed"; return 1; }
  for _ in $(seq 1 120); do [ -s "${state}.exit" ] && break; sleep 0.5; done
  LOG="${state}.log"
  git checkout -q master; git pull -q origin master
}
attempt() {
  python3 - "$AUTOCODER_MERGE_EVENTS" "$1" <<'PY'
import json, sys
for l in open(sys.argv[1]):
    e = json.loads(l)
    if e["event"] == "attempt" and e["issue"] == int(sys.argv[2]):
        print(e["outcome"], "red_base=" + json.dumps(e.get("red_base")))
PY
}

echo "=== master's fix lands during the gate: re-sync and re-gate, not a blame ==="
master_set bad
touch "$TMP/landfix"
run_one 37501 src.txt change "bash $TMP/gate.sh"
[ "$(attempt 37501)" = "landed red_base=false" ] && ok "the change lands on the fixed tip" || bad "attempt: $(attempt 37501); log: $(cat "$LOG")"
grep -q "origin/master has since moved to" "$LOG" && ok "the log says the tip moved during the gate" || bad "no moved-tip line: $(cat "$LOG")"
grep -q "so this change broke it" "$LOG" && bad "the change was blamed for master's fixed red" || ok "the change is not blamed"
grep -q "alone to see whether this change broke it" "$LOG" && bad "a base-alone run judged a tree built on a moved base" || ok "no base-alone verdict against the moved tip"
[ -f "$TMP/issues/closed/37501.md" ] && ok "the issue is closed" || bad "issue state: $(ls "$TMP"/issues/*/37501.md)"

echo "=== re-sync capped at 0: the base measured is the one the tree was built on ==="
master_set bad
RED=$(git rev-parse origin/master)
touch "$TMP/landfix"
AUTOCODER_MOVED_BASE_REGATES=0 run_one 37502 src.txt change2 "bash $TMP/gate.sh"
[ "$(attempt 37502)" = "parked red_base=true" ] && ok "the red base it was built on is recognised" || bad "attempt: $(attempt 37502); log: $(cat "$LOG")"
grep -q "Gating origin/master (${RED:0:8}," "$LOG" && ok "the base gated alone is the tree's own base ${RED:0:8}" || bad "base line: $(grep -n 'Gating origin' "$LOG")"
grep -q "so this change broke it" "$LOG" && bad "capped: the change was blamed" || ok "capped: the change is not blamed"

echo "=== a cached pass from another selection is not the base's verdict ==="
master_set bad
source "$SCRIPT_DIR/gate-cache-fns.sh"
gate_cache_put "$(git rev-parse 'origin/master^{tree}')" "bash $TMP/gate.sh full" pass >/dev/null
run_one 37503 other.txt change3 "bash $TMP/gate.sh full"
[ "$(attempt 37503)" = "parked red_base=true" ] && ok "the base is gated again and found red" || bad "attempt: $(attempt 37503); log: $(cat "$LOG")"
grep -q "gate-cache: pass recorded for tree" "$LOG" && bad "the base-alone retest reused a cached pass" || ok "no cached pass reused for the base"
grep -q "so this change broke it" "$LOG" && bad "cache: the change was blamed" || ok "cache: the change is not blamed"

echo ""

echo "=== the tip moves by a documents-only commit during the gate: judged against the built base, no re-sync (#390) ==="
# gate2 lands a documents-only commit on master mid-gate (a note page), then runs the gate.
cat > "$TMP/gate2.sh" <<G
if [ -e "$TMP/landdocs" ]; then
  rm -f "$TMP/landdocs"
  ( cd "$TMP/fixer" && git pull -q origin master && echo note > NOTES.md && git add NOTES.md \\
      && git commit -q -m "docs: a note" && git push -q origin master ) >/dev/null 2>&1
  git fetch -q origin master
fi
exec bash "$TMP/gate.sh" "\$@"
G
master_set bad
RED=$(git rev-parse origin/master)
touch "$TMP/landdocs"
run_one 37504 src.txt change4 "bash $TMP/gate2.sh"
[ "$(attempt 37504)" = "parked red_base=true" ] && ok "docs move: the red base it was built on is recognised" || bad "docs move attempt: $(attempt 37504); log: $(cat "$LOG")"
grep -q "documents-only file(s) since this tree was built" "$LOG" && ok "docs move: the log says the tip moved by documents only" || bad "docs move: no documents-only line: $(grep -nE 'moved|documents' "$LOG")"
grep -q "origin/master has since moved to" "$LOG" && bad "docs move: a re-sync re-gate ran for a documents-only delta" || ok "docs move: no re-sync re-gate"
grep -q "Gating origin/master (${RED:0:8}," "$LOG" && ok "docs move: the base gated alone is the tree's own base ${RED:0:8}" || bad "docs move base line: $(grep -n 'Gating origin' "$LOG")"
[ "$(git -C "$TMP/fixer" log --oneline -1 origin/master 2>/dev/null | grep -c 'docs: a note')" = 1 ] || git -C "$TMP/fixer" fetch -q origin
grep -q "so this change broke it" "$LOG" && bad "docs move: the change was blamed" || ok "docs move: the change is not blamed"

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
