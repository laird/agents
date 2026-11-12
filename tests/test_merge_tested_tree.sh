#!/bin/bash
# tests/test_merge_tested_tree.sh — the tree merge-to-integration.sh publishes under the
# `tested` basis is the tree the gate command LEFT, and nothing else is ever pushed as it:
#   - a gate command that commits inside its worktree before its test stages (a
#     regenerated file, a baseline ratchet) lands verified: the published tree is the one
#     the command left, the log names the commit, and no internal error follows the push;
#   - under --own-issue such a landing closes the issue instead of parking it;
#   - the gate cache records the left tree as passing too, so a re-run on that exact tree
#     is a hit;
#   - a tree that changes between the gate and the push (anything that moved HEAD behind
#     the gate's back) is re-gated BEFORE the push, never published and reported after it.
#
# WHY: the tested tree used to be read before the gate command ran. Every gate command
# that committed early, as its contract allowed, then passed, pushed, and only afterwards
# reported "published tree X is not the tree the tests passed on (Y)": a verified landing
# turned into a parked issue (and, for a train, a landing its finisher read as red) on
# every pass whose baseline rows shrank.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$ROOT/plugins/autocoder/scripts"
MTI="$SCRIPT_DIR/merge-to-integration.sh"
ISSUES_PY="$SCRIPT_DIR/issues-file.py"
ISSUE=19204

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export ISSUE_SOURCE=file
export AUTOCODER_TMP="$TMP/tmp"; mkdir -p "$AUTOCODER_TMP"
export ISSUE_DIR_PATH="$TMP/issues"
export AUTOCODER_GATE_CACHE_DIR="$TMP/gate-cache"
export CLAUDE_CODE_SHIP_BRANCH=master
unset AUTOCODER_MERGE_ON_RED_BASE AUTOCODER_SCOPED_REGATE AUTOCODER_GREEN_REF
# shellcheck source=../plugins/autocoder/scripts/gate-cache-fns.sh
source "$SCRIPT_DIR/gate-cache-fns.sh"

# Bare origin with a green ref, worker on feature/code, one issue claimed by the worker.
setup() {
  rm -rf "$TMP/origin.git" "$TMP/worker" "$TMP/gate-cache" "$TMP/issues" "$TMP/gate-runs" "$TMP/hooks" "$TMP/hook-fired"
  mkdir -p "$TMP/issues/open" "$TMP/issues/working" "$TMP/issues/blocked" "$TMP/issues/closed"
  printf -- '---\nnumber: %s\ntitle: Tested tree\npriority: P2\nlabels: [bug]\nstatus: open\n---\nBody.\n' "$ISSUE" > "$TMP/issues/open/${ISSUE}.md"
  python3 "$ISSUES_PY" claim "$ISSUE" >/dev/null
  git init --bare -q "$TMP/origin.git"
  git init -q "$TMP/worker"
  cd "$TMP/worker" || exit 1
  git config user.email t@example.com; git config user.name T
  git remote add origin "$TMP/origin.git"
  echo base > README.md; printf 'src/old.sh 3\n' > baseline.txt
  git add -A; git commit -q -m init; git branch -M master; git push -q origin master master:master-green
  git fetch -q origin
  git checkout -q -b feature/code master
  mkdir -p src; echo change > src/app.sh
  git add -A; git commit -q -m "fix"
  printf 'Replaced the broken thing.\n' > "$TMP/summary.md"
}

origin_master_tree() { git --git-dir="$TMP/origin.git" rev-parse 'master^{tree}'; }
gate_runs()         { if [ -f "$TMP/gate-runs" ]; then wc -l < "$TMP/gate-runs"; else echo 0; fi; }
issue_bucket()      { basename "$(dirname "$(ls "$TMP"/issues/*/"${ISSUE}.md" | head -1)")"; }
run()               { bash "$MTI" --feature feature/code --issue $ISSUE --integration master --test-cmd "$1" "${@:2}" 2>&1; }

# A gate that records the tree it started on, then (like a baseline ratchet or a
# regenerated file) commits inside the worktree BEFORE its "test stage", and passes.
RECORD='echo "$(git rev-parse HEAD^{tree})" >> '"$TMP"'/gate-runs'
RATCHET_GATE="$RECORD"'; printf "src/old.sh 2\n" > baseline.txt && git add baseline.txt && git commit -q -m "ratchet baseline (mechanical)" && true'

# ── (a) a gate command that commits early lands verified on the tree it left ──
setup
OUT=$(run "$RATCHET_GATE"); RC=$?
[ "$RC" -eq 0 ] && ok "(a) merge exits 0" || bad "(a) rc=$RC: $OUT"
echo "$OUT" | grep -q "Internal error" && bad "(a) an internal error followed the push: $OUT" || ok "(a) no internal error after the push"
STARTED=$(head -1 "$TMP/gate-runs"); LEFT=$(origin_master_tree)
[ "$STARTED" != "$LEFT" ] && ok "(a) the command moved the tree (precondition)" || bad "(a) the ratchet commit did not change the tree"
echo "$OUT" | grep -q "verified: tests passed on the published tree ${LEFT:0:8}" && ok "(a) success line names the published (left) tree as tested" || bad "(a) success line wrong: $OUT"
echo "$OUT" | grep -q "The gate command committed inside its worktree (tree ${STARTED:0:8} -> ${LEFT:0:8}: .* ratchet baseline (mechanical))" && ok "(a) log names the in-command commit and both trees" || bad "(a) in-command commit not logged: $OUT"
[ "$(git --git-dir="$TMP/origin.git" show master:baseline.txt)" = "src/old.sh 2" ] && ok "(a) the ratcheted file is what master carries" || bad "(a) master does not carry the ratchet"
[ "$(gate_cache_get "$LEFT" "$RATCHET_GATE")" = pass ] && ok "(a) gate cache records the left tree as passing" || bad "(a) no cache record for the left tree"
[ "$(gate_cache_get "$STARTED" "$RATCHET_GATE")" = pass ] && ok "(a) gate cache still records the started tree" || bad "(a) started tree lost its record"
echo "$OUT" | grep -q "gate-cache: the command left tree ${LEFT:0:8} (started on ${STARTED:0:8}); pass recorded for it too" && ok "(a) cache log says both were recorded" || bad "(a) cache log missing: $OUT"

# ── (b) under --own-issue the same landing closes the issue ─────────────────
setup
OUT=$(run "$RATCHET_GATE" --summary-file "$TMP/summary.md" --own-issue); RC=$?
[ "$RC" -eq 0 ] && ok "(b) own-issue merge exits 0" || bad "(b) rc=$RC: $OUT"
[ "$(issue_bucket)" = closed ] && ok "(b) issue closed, not parked" || bad "(b) issue in $(issue_bucket): $OUT"
echo "$OUT" | grep -q "awaiting-integration" && bad "(b) issue was parked: $OUT" || ok "(b) never parked"

# ── (c) a tree that moves between the gate and the push is re-gated before the push ──
# A pre-push hook stands in for anything that moves HEAD behind the gate's back: on the
# first push it commits a file in the worktree and rejects the push; the script re-syncs
# (nothing new on origin), comes back to push, and must notice the tree is no longer the
# tested one BEFORE pushing it.
setup
mkdir -p "$TMP/hooks"
cat > "$TMP/hooks/pre-push" <<HOOK
#!/bin/bash
if [ ! -f "$TMP/hook-fired" ]; then
  touch "$TMP/hook-fired"
  echo moved > moved.txt && git add moved.txt && git -c user.email=h@example.com -c user.name=H commit -q -m "moved behind the gate's back"
  exit 1
fi
exit 0
HOOK
chmod +x "$TMP/hooks/pre-push"
git -C "$TMP/worker" config core.hooksPath "$TMP/hooks"
OUT=$(run "$RECORD"); RC=$?
git -C "$TMP/worker" config --unset core.hooksPath
[ "$RC" -eq 0 ] && ok "(c) merge exits 0" || bad "(c) rc=$RC: $OUT"
[ "$(gate_runs)" -eq 2 ] && ok "(c) the moved tree was gated again" || bad "(c) gate ran $(gate_runs) time(s); want 2: $OUT"
echo "$OUT" | grep -q "is not the tested tree .*; not pushing an untested tree. Re-gating it." && ok "(c) log says the push was refused and the tree re-gated" || bad "(c) refusal not logged: $OUT"
[ "$(tail -1 "$TMP/gate-runs")" = "$(origin_master_tree)" ] && ok "(c) the published tree is the last gated tree" || bad "(c) published tree is not the last gated tree"
echo "$OUT" | grep -q "verified: tests passed on the published tree" && ok "(c) success line says verified" || bad "(c) success line wrong: $OUT"
echo "$OUT" | grep -q "Internal error" && bad "(c) an internal error followed the push: $OUT" || ok "(c) no internal error after the push"
git --git-dir="$TMP/origin.git" cat-file -e master:moved.txt 2>/dev/null && ok "(c) master carries the moved file, gated" || bad "(c) master lacks the moved file"

TOTAL=$((PASS + FAIL))
echo "$PASS passed / $FAIL failed / $TOTAL total"
[ "$FAIL" -eq 0 ]
