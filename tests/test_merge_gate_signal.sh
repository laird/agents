#!/bin/bash
# tests/test_merge_gate_signal.sh — a gate that dies from a signal (the OOM killer taking
# an ancestor of the test run) reached no verdict, so merge-to-integration.sh must not
# report it as a test failure:
#   - exit 3, not the test-failure exit 2, and nothing pushed;
#   - no gate-cache record for the killed tree (a retry must re-run it);
#   - the log names the signal;
#   - under --own-issue the escalation comment says killed-by-signal, not "broke it";
#   - a kill during the base-alone gate is reported the same way.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$ROOT/plugins/autocoder/scripts"
MTI="$SCRIPT_DIR/merge-to-integration.sh"
ISSUES_PY="$SCRIPT_DIR/issues-file.py"
ISSUE=19377

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export ISSUE_SOURCE=file
export AUTOCODER_TMP="$TMP/tmp"; mkdir -p "$AUTOCODER_TMP"
export ISSUE_DIR_PATH="$TMP/issues"
export AUTOCODER_GATE_CACHE_DIR="$TMP/gate-cache"
export CLAUDE_CODE_SHIP_BRANCH=master
unset AUTOCODER_MERGE_ON_RED_BASE AUTOCODER_SCOPED_REGATE

setup() {
  rm -rf "$TMP/origin.git" "$TMP/worker" "$TMP/gate-cache" "$TMP/issues"
  mkdir -p "$TMP/issues/open" "$TMP/issues/working" "$TMP/issues/blocked" "$TMP/issues/closed"
  printf -- '---\nnumber: %s\ntitle: Signal\npriority: P2\nlabels: [bug]\nstatus: open\n---\nBody.\n' "$ISSUE" > "$TMP/issues/open/${ISSUE}.md"
  python3 "$ISSUES_PY" claim "$ISSUE"
  git init --bare -q "$TMP/origin.git"
  git init -q "$TMP/worker"
  cd "$TMP/worker" || exit 1
  git config user.email t@example.com; git config user.name T
  git remote add origin "$TMP/origin.git"
  echo base > README.md
  git add -A; git commit -q -m init; git branch -M master; git push -q origin master
  git fetch -q origin
  git checkout -q -b feature/code master
  mkdir -p src; echo change > src/app.sh
  git add -A; git commit -q -m "fix"
}

issue_file()    { ls "$TMP"/issues/*/"${ISSUE}.md" 2>/dev/null | head -1; }
issue_bucket()  { basename "$(dirname "$(issue_file)")"; }
origin_master() { git --git-dir="$TMP/origin.git" rev-parse master; }
records()       { find "$AUTOCODER_GATE_CACHE_DIR" -maxdepth 1 -type f ! -name '.tmp.*' 2>/dev/null; }
run_mti()       { bash "$MTI" --feature feature/code --issue $ISSUE --integration master --test-cmd "$1" "${@:2}" 2>&1; }

# ── 1. the integrated-tree gate is SIGKILLed, under --own-issue ──
setup
BEFORE=$(origin_master)
OUT=$(run_mti 'echo GATE-STARTED; kill -KILL $$' --own-issue); RC=$?
[ "$RC" -eq 3 ] && ok "killed gate exits 3" || bad "rc=$RC: $OUT"
[ "$(origin_master)" = "$BEFORE" ] && ok "nothing pushed" || bad "master moved"
[ -z "$(records)" ] && ok "no gate-cache record for the killed tree" || bad "killed gate was recorded: $(records | xargs cat)"
echo "$OUT" | grep -q "killed by signal 9 (likely OOM), not a test failure" && ok "log names the signal" || bad "log lacks the signal line: $OUT"
echo "$OUT" | grep -q "Tests fail on the integrated tree" && bad "a kill was reported as a test failure: $OUT" || ok "no test-failure line"
echo "$OUT" | grep -q "Gating origin/master" && bad "base gate ran after a kill: $OUT" || ok "base-alone gate skipped after a kill"
[ "$(issue_bucket)" = blocked ] && ok "issue escalated (blocked/)" || bad "bucket=$(issue_bucket)"
grep -q "killed by signal 9 (likely OOM), not a test failure" "$(issue_file)" && ok "issue comment says killed by signal" || bad "comment lacks the signal: $(cat "$(issue_file)")"
grep -q "this change broke it" "$(issue_file)" && bad "comment blames the change" || ok "comment does not blame the change"

# ── 2. the retry re-runs the gate (nothing cached) and a pass lands ──
OUT=$(run_mti 'echo RERAN' ); RC=$?
[ "$RC" -eq 0 ] && echo "$OUT" | grep -q RERAN && ok "retry re-runs the gate and lands" || bad "retry rc=$RC: $OUT"

# ── 3. the integrated tree fails, then the base-alone gate is SIGKILLed ──
setup
BEFORE=$(origin_master)
OUT=$(run_mti 'if [ -f src/app.sh ]; then exit 1; fi; kill -KILL $$'); RC=$?
[ "$RC" -eq 3 ] && ok "killed base gate exits 3" || bad "rc=$RC: $OUT"
[ "$(origin_master)" = "$BEFORE" ] && ok "nothing pushed after a killed base gate" || bad "master moved"
echo "$OUT" | grep -q "gate on origin/master alone .* killed by signal 9" && ok "log names the base gate and the signal" || bad "log lacks base kill line: $OUT"
[ "$(records | wc -l)" -eq 1 ] && [ "$(records | xargs awk 'NR==1{print $1}')" = fail ] && ok "only the integrated tree's real failure is recorded" || bad "records: $(records | xargs cat)"
[ "$(issue_bucket)" = working ] && ok "without --own-issue the issue is untouched" || bad "bucket=$(issue_bucket)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
