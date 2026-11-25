#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255
# tests/test_merge_red_base_retest.sh — the base-alone retest re-runs the files that failed
# on the integrated tree (#298). The gate command here selects tests by the tree's diff,
# as a "tests mapped to changed sources" stage does: on origin/master alone the diff is
# empty, so a plain re-run selects nothing and passes, and the worker is blamed for a red
# base. The merge job passes the failed files in AUTOCODER_GATE_RETEST_FILES; a command
# that honours it re-runs them on the base, and the red base is recognised.
#   - the red base lands (parked), with a per-file "fails on origin/master too" line;
#   - a failure line that quotes its own worktree path still compares equal;
#   - a file that passes on the base is reported as this change's, and bounced;
#   - the base run's gate-cache record is keyed by the file list, not the plain command.

PASS=0; FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)/plugins/autocoder/scripts"
MTI="$SCRIPT_DIR/merge-to-integration.sh"
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
unset AUTOCODER_MERGE_ON_RED_BASE AUTOCODER_SCOPED_REGATE AUTOCODER_GATE_RETEST_FILES
mkdir -p "$TMP/issues"/{open,working,blocked,closed}

git init --bare -q "$TMP/origin.git"
git init -q "$TMP/worker"
cd "$TMP/worker" || exit 1
git config user.email t@example.com; git config user.name T
git remote add origin "$TMP/origin.git"
# master carries the defect: t_broken.test fails. master-green exists, so a red base may land.
echo base > README.md; echo bad > t_broken.test; echo good > t_ok.test
git add -A; git commit -q -m init; git branch -M master; git push -q origin master master:master-green

# Selects the test files changed against origin/master, with src.txt mapped to
# t_broken.test; AUTOCODER_GATE_RETEST_FILES, when set, replaces the selection.
# A test file fails when it contains "bad". $1 = "abs" names failures by absolute path.
cat > "$TMP/gate.sh" <<'G'
sel=$(git diff --name-only origin/master HEAD | sed 's/^src\.txt$/t_broken.test/' | grep '\.test$')
[ -n "${AUTOCODER_GATE_RETEST_FILES:-}" ] && sel=$AUTOCODER_GATE_RETEST_FILES
echo "selected: $(echo $sel)"
rc=0
for f in $sel; do
  if grep -q bad "$f" 2>/dev/null; then
    if [ "${1:-}" = abs ]; then echo "FAIL $PWD/$f"; else echo "FAIL $f"; fi
    rc=1
  fi
done
# #7130: a stage runner's summary line carrying this run's wall time (never equal between two runs)
if [ "$rc" -ne 0 ] && [ -e "${AUTOCODER_TMP}/../wall" ]; then echo "::error::run-gate-stages: FAIL (stage runner rc 1; fail wall $(date +%s%N | cut -c8-13 | sed 's/^\(.*\)\(.\)$/\1.\2/') s; failed: db-tests)"; fi
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

echo "=== a diff-selected failure on a red base is recognised as the base's ==="
run_one 29801 src.txt change "bash $TMP/gate.sh"
[ "$(attempt 29801)" = "parked red_base=true" ] && ok "red base lands (parked), not bounced" || bad "attempt: $(attempt 29801); log: $(cat "$LOG")"
grep -q 'AUTOCODER_GATE_RETEST_FILES="t_broken.test"' "$LOG" && ok "the base run is told the failed file" || bad "no retest line: $(cat "$LOG")"
grep -q "t_broken.test: fails on origin/master too" "$LOG" && ok "per-file report: fails on the base too" || bad "no per-file line: $(cat "$LOG")"
ls "$AUTOCODER_GATE_CACHE_DIR" | grep -q -- '-rt[0-9a-f]\{12\}$' && ok "the retest record is keyed by its file list" || bad "cache keys: $(ls "$AUTOCODER_GATE_CACHE_DIR")"
grep -q "^merge-to-integration: RED-BASE -- origin/master (.*) fails alone too with the same 1 named failure(s) in t_broken.test: red master, not this change's.$" "$LOG" \
  && ok "one RED-BASE line names the base and the file" || bad "no RED-BASE line: $(grep -n 'RED-BASE\|alone' "$LOG")"
grep -q "so this change broke it" "$LOG" && bad "a red base blamed the change" || ok "the change is not blamed on a red base"

echo "=== a failure line quoting its worktree path still compares equal ==="
run_one 29802 src.txt change2 "bash $TMP/gate.sh abs"
[ "$(attempt 29802)" = "parked red_base=true" ] && ok "absolute-path failures on both trees are the same red base" || bad "attempt: $(attempt 29802); log: $(cat "$LOG")"
grep -q 'AUTOCODER_GATE_RETEST_FILES="t_broken.test"' "$LOG" && ok "the worktree path is cut from the retest file" || bad "retest line: $(grep RETEST "$LOG")"

echo "=== a file that passes on the base is this change's ==="
run_one 29803 t_new.test bad "bash $TMP/gate.sh"
[ "$(attempt 29803)" = "gate-failed red_base=false" ] && ok "change's own failure is bounced" || bad "attempt: $(attempt 29803); log: $(cat "$LOG")"
grep -q "t_new.test: passes on origin/master (this change's)" "$LOG" && ok "per-file report: passes on the base" || bad "no per-file line: $(cat "$LOG")"
grep -q 'so this change broke it: `t_new.test`' "$TMP"/issues/*/29803.md && ok "the bounce reason names the file that passes on the base" || bad "reason: $(grep -n 'broke it' "$TMP"/issues/*/29803.md)"
grep -q "RED-BASE" "$LOG" && bad "a change's own failure printed a RED-BASE line" || ok "no RED-BASE line for the change's own failure"

echo "=== a red base, refused: the refusal names master, not the change ==="
AUTOCODER_MERGE_ON_RED_BASE=0 run_one 29804 src.txt change3 "bash $TMP/gate.sh"
case "$(attempt 29804)" in "gate-failed red_base=true"|"escalated red_base=true") ok "refused on the red base" ;; *) bad "attempt: $(attempt 29804); log: $(cat "$LOG")" ;; esac
grep -q "^merge-to-integration: RED-BASE -- origin/master" "$LOG" && ok "refused: the RED-BASE line is printed" || bad "refused: no RED-BASE line: $(cat "$LOG")"
grep -q "Red master, not this change: hold the branch, open or cite the issue for red master" "$LOG" && ok "refused: the reader is told to hold the branch and cite red master" || bad "refused: $(grep -n 'NOT pushing' "$LOG")"
grep -q "so this change broke it" "$LOG" && bad "refused: the change was blamed" || ok "refused: the change is not blamed"
grep -q 'red master in `t_broken.test`, not this change'"'"'s' "$TMP"/issues/*/29804.md && ok "refused: the issue comment names red master in the file" || bad "refused: issue text: $(cat "$TMP"/issues/*/29804.md)"

echo "=== a summary line whose wall time differs per run still compares equal (#7130, train 253) ==="
touch "$TMP/wall"
run_one 29806 src.txt change5 "bash $TMP/gate.sh"
rm -f "$TMP/wall"
[ "$(attempt 29806)" = "parked red_base=true" ] && ok "a red base beside a timed summary line is the base's" || bad "attempt: $(attempt 29806); log: $(grep -n 'broke it\|RED-BASE\|fail wall' "$LOG")"
[ "$(grep -c 'fail wall' "$LOG")" -ge 2 ] && ok "the timed summary line was in both runs" || bad "summary lines: $(grep -c 'fail wall' "$LOG")"
grep -q "so this change broke it" "$LOG" && bad "the wall time blamed the change" || ok "the wall time did not blame the change"

echo "=== a mix: the change's own failure beside a red-base one ==="
printf -- '---\nnumber: 29805\ntitle: T\npriority: P2\nlabels: [bug]\nstatus: open\n---\nBody.\n' > "$TMP/issues/open/29805.md"
python3 "$ISSUES_PY" claim 29805 >/dev/null
git checkout -q -b feature/i29805 master
echo change4 > src.txt; echo bad > t_new2.test; git add -A; git commit -q -m "fix #29805"; git push -q origin feature/i29805
MIXED=$(bash "$MTI" --feature feature/i29805 --issue 29805 --integration master --test-cmd "bash $TMP/gate.sh" --own-issue 2>&1); MRC=$?
git checkout -q master
[ "$MRC" -eq 2 ] && ok "mixed: exit 2" || bad "mixed: exit $MRC
$MIXED"
printf '%s' "$MIXED" | grep -q "t_broken.test: fails on origin/master too" && ok "mixed: the base's file says so" || bad "mixed: no base line: $MIXED"
printf '%s' "$MIXED" | grep -q "t_new2.test: passes on origin/master (this change's)" && ok "mixed: the change's file says so" || bad "mixed: no change line"
printf '%s' "$MIXED" | grep -q "red master, not this change's: t_broken.test" && ok "mixed: the base's file is listed apart" || bad "mixed: $MIXED"
printf '%s' "$MIXED" | grep -q "RED-BASE" && bad "mixed: a RED-BASE line although the change broke something" || ok "mixed: no RED-BASE line"
grep -q 'red master in `t_broken.test` besides' "$TMP"/issues/*/29805.md && ok "mixed: the reason names red master besides" || bad "mixed: issue text: $(cat "$TMP"/issues/*/29805.md)"

echo "=== a failure that does not reproduce on the same tree is FLAKY: nobody's, nothing lands ==="
# The gate fails t_flaky.test on a tree's first run and passes it when told the file list (the
# same-tree retest): the real shape of a timeout under load.
cat > "$TMP/gate-flaky.sh" <<'G'
if [ -n "${AUTOCODER_GATE_RETEST_FILES:-}" ]; then echo "selected: $AUTOCODER_GATE_RETEST_FILES"; echo "PASS t_flaky.test"; exit 0; fi
echo "selected: t_flaky.test"; echo "FAIL t_flaky.test"; exit 1
G
BEFORE_FLAKY=$(git rev-parse origin/master)
run_one 29807 t_flaky.test flake "bash $TMP/gate-flaky.sh"
grep -q "^merge-to-integration: FLAKY -- t_flaky.test failed on the integrated tree .* and passed on a second run of the same tree" "$LOG" && ok "flaky: the FLAKY line names the file" || bad "flaky: no FLAKY line: $(cat "$LOG")"
[ "$(git rev-parse origin/master)" = "$BEFORE_FLAKY" ] && ok "flaky: nothing landed" || bad "flaky: master moved"
grep -q "Gating origin/master" "$LOG" && bad "flaky: the base was gated although the failure did not reproduce" || ok "flaky: the base run was skipped"
[ "$(grep -c '^selected:' "$LOG")" -eq 2 ] && ok "flaky: exactly two runs, both on the integrated tree" || bad "flaky: runs: $(grep -c '^selected:' "$LOG")"
grep -q "so this change broke it" "$LOG" && bad "flaky: the change was blamed" || ok "flaky: the change is not blamed"
case "$(attempt 29807)" in escalated*|gate-failed*) ok "flaky: the attempt did not land ($(attempt 29807))" ;; *) bad "flaky: attempt: $(attempt 29807)" ;; esac
echo "=== AUTOCODER_GATE_FLAKY_RETEST=0 keeps the old order: straight to the base run ==="
AUTOCODER_GATE_FLAKY_RETEST=0 run_one 29808 t_flaky2.test flake "bash $TMP/gate-flaky.sh"
grep -q "FLAKY" "$LOG" && bad "switch off: a FLAKY line" || ok "switch off: no flaky retest"
grep -q "Gating origin/master" "$LOG" && ok "switch off: the base was gated" || bad "switch off: no base run: $(cat "$LOG")"

echo ""
echo "Tests: $FAIL failed, $PASS passed, $((PASS + FAIL)) total"
[ "$FAIL" -eq 0 ]
