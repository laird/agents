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

echo "=== a failure line quoting its worktree path still compares equal ==="
run_one 29802 src.txt change2 "bash $TMP/gate.sh abs"
[ "$(attempt 29802)" = "parked red_base=true" ] && ok "absolute-path failures on both trees are the same red base" || bad "attempt: $(attempt 29802); log: $(cat "$LOG")"
grep -q 'AUTOCODER_GATE_RETEST_FILES="t_broken.test"' "$LOG" && ok "the worktree path is cut from the retest file" || bad "retest line: $(grep RETEST "$LOG")"

echo "=== a file that passes on the base is this change's ==="
run_one 29803 t_new.test bad "bash $TMP/gate.sh"
[ "$(attempt 29803)" = "gate-failed red_base=false" ] && ok "change's own failure is bounced" || bad "attempt: $(attempt 29803); log: $(cat "$LOG")"
grep -q "t_new.test: passes on origin/master (this change's)" "$LOG" && ok "per-file report: passes on the base" || bad "no per-file line: $(cat "$LOG")"

echo ""
echo "Tests: $FAIL failed, $PASS passed, $((PASS + FAIL)) total"
[ "$FAIL" -eq 0 ]
