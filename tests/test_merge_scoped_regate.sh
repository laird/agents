#!/bin/bash
# tests/test_merge_scoped_regate.sh — merge-to-integration.sh runs the gate only when it
# has to, and judges a failure against the integration tip rather than in isolation:
#   - a rejected push whose re-sync is disjoint from this change is pushed with no second
#     gate run, and the success line names the gated and published trees separately;
#   - a re-sync that touches a file this change touched, or a global path, re-gates;
#   - a tree already recorded as passing in the gate cache is not run again;
#   - when the integrated tree fails and origin/<integration> alone passes, exit 2 and
#     nothing is pushed; when the base fails too the work lands, the issue is told, and
#     AUTOCODER_MERGE_ON_RED_BASE=0 restores exit 2;
#   - both relaxations apply only once origin/<integration>-green exists (a sentinel has
#     proven a green tip); without it every re-sync re-gates and a red base refuses;
#   - overlap ignores renames (a sibling renaming a file this change edits re-gates), a
#     wider manifest list counts as global, and so does any path the gate command runs;
#   - a red-base landing followed by a disjoint re-sync says the published tree is
#     neither gated tree.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$ROOT/plugins/autocoder/scripts"
MTI="$SCRIPT_DIR/merge-to-integration.sh"
ISSUE=19202

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export ISSUE_SOURCE=file
# Merge state and throwaway worktrees live under AUTOCODER_TMP, keyed by the repo id.
export AUTOCODER_TMP="$TMP/tmp"; mkdir -p "$AUTOCODER_TMP"
# shellcheck source=../plugins/autocoder/scripts/repo-id-fns.sh
source "$SCRIPT_DIR/repo-id-fns.sh"
base_worktree() { echo "$AUTOCODER_TMP/autocoder-merge-worktree-$(autocoder_repo_id "$TMP/worker")-${ISSUE}-base"; }
export ISSUE_DIR_PATH="$TMP/issues"
export AUTOCODER_GATE_CACHE_DIR="$TMP/gate-cache"
unset AUTOCODER_MERGE_ON_RED_BASE AUTOCODER_GATE_GLOBAL_PATHS AUTOCODER_SCOPED_REGATE AUTOCODER_GREEN_REF

# Fresh bare origin, worker checkout on feature/code (src/app.sh added, README line 1
# edited), sibling clone on master, empty gate-run log, and one open issue. origin gets a
# master-green ref (the sentinel's proof) unless $1 is "nogreen".
setup() {
  rm -rf "$TMP/origin.git" "$TMP/worker" "$TMP/sibling" "$TMP/gate-cache" "$TMP/gate-runs" "$TMP/raced" "$TMP/issues"
  mkdir -p "$TMP/issues/open" "$TMP/issues/working" "$TMP/issues/blocked" "$TMP/issues/closed"
  printf -- '---\nnumber: %s\ntitle: Scoped re-gate\npriority: P2\nlabels: [bug]\nstatus: open\n---\nBody.\n' "$ISSUE" > "$TMP/issues/open/${ISSUE}.md"
  git init --bare -q "$TMP/origin.git"
  git init -q "$TMP/worker"
  cd "$TMP/worker" || exit 1
  git config user.email t@example.com; git config user.name T
  git remote add origin "$TMP/origin.git"
  seq -f 'line %g' 1 10 > README.md
  mkdir -p scripts; echo true > scripts/helper.sh; echo 'module x' > go.mod
  git add -A; git commit -q -m init; git branch -M master; git push -q origin master
  [ "${1:-}" = nogreen ] || git push -q origin master:master-green
  git fetch -q origin
  git checkout -q -b feature/code master
  mkdir -p src; echo change > src/app.sh
  sed -i '1s/.*/line 1 (fixed)/' README.md
  git add -A; git commit -q -m "fix"
  git clone -q "$TMP/origin.git" "$TMP/sibling"
  git -C "$TMP/sibling" config user.email s@example.com; git -C "$TMP/sibling" config user.name S
}

origin_master() { git --git-dir="$TMP/origin.git" rev-parse master; }
gate_runs()     { if [ -f "$TMP/gate-runs" ]; then wc -l < "$TMP/gate-runs"; else echo 0; fi; }
issue_body()    { cat "$TMP"/issues/*/"${ISSUE}.md"; }

# The gate records the tree it ran on. On its first run it also lets the sibling land
# $1 on master, so the worker's first push is rejected and it must re-sync.
# $2 (default true) is the gate's verdict. The sibling's action runs from a file outside
# the tree so that no path it edits appears in the gate command's own text.
racing_gate() {
  printf '%s\n' "$1" > "$TMP/sib-action.sh"
  printf '%s\n' 'echo "$(git rev-parse HEAD^{tree})" >> '"$TMP"'/gate-runs' \
    'if [ ! -f '"$TMP"'/raced ]; then touch '"$TMP"'/raced' \
    "  (cd $TMP/sibling && bash $TMP/sib-action.sh && git add -A && git commit -q -m sib && git push -q origin master)" \
    'fi' "${2:-true}"
}

# ── (a0) AUTOCODER_SCOPED_REGATE=0: a disjoint re-sync is re-gated anyway ───
setup
OUT=$(AUTOCODER_SCOPED_REGATE=0 bash "$MTI" --feature feature/code --issue $ISSUE --integration master --test-cmd "$(racing_gate 'echo s > sibling.txt')" 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok "(a0) strict mode merges" || bad "(a0) rc=$RC: $OUT"
[ "$(gate_runs)" -eq 2 ] && ok "(a0) strict mode re-gated the disjoint re-sync" || bad "(a0) gate ran $(gate_runs) time(s); want 2"
echo "$OUT" | grep -q "verified: tests passed on the published tree" && ok "(a0) strict mode publishes a verified tree" || bad "(a0) success line wrong: $OUT"

# ── (a0') no green ref yet: strict whatever the env says ────────────────────
setup nogreen
OUT=$(AUTOCODER_SCOPED_REGATE=1 AUTOCODER_MERGE_ON_RED_BASE=1 bash "$MTI" --feature feature/code --issue $ISSUE --integration master --test-cmd "$(racing_gate 'echo s > sibling.txt')" 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok "(a0') merges without a green ref" || bad "(a0') rc=$RC: $OUT"
[ "$(gate_runs)" -eq 2 ] && ok "(a0') without a green ref a disjoint re-sync is re-gated" || bad "(a0') gate ran $(gate_runs) time(s); want 2"
echo "$OUT" | grep -q "No origin/master-green yet" && echo "$OUT" | grep -q "strict mode" && ok "(a0') log names the strict mode once" || bad "(a0') mode not logged: $OUT"
echo "$OUT" | grep -q "verified: tests passed on the published tree" && ok "(a0') strict mode publishes a verified tree" || bad "(a0') success line wrong: $OUT"

setup
OUT=$(AUTOCODER_GREEN_REF=proof bash "$MTI" --feature feature/code --issue $ISSUE --integration master --test-cmd "$(racing_gate 'echo s > sibling.txt')" 2>&1); RC=$?
[ "$(gate_runs)" -eq 2 ] && echo "$OUT" | grep -q "No origin/proof yet" && ok "(a0') AUTOCODER_GREEN_REF names the ref that must exist" || bad "(a0') green-ref override ignored ($(gate_runs) runs): $OUT"

# ── (a) disjoint re-sync: one gate run, pushed, not called verified ─────────
setup
OUT=$(bash "$MTI" --feature feature/code --issue $ISSUE --integration master --test-cmd "$(racing_gate 'echo s > sibling.txt')" 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok "(a) disjoint re-sync merges" || bad "(a) rc=$RC: $OUT"
echo "$OUT" | grep -q "origin/master-green exists" && ok "(a) log names the relaxed mode" || bad "(a) mode not logged: $OUT"
[ "$(gate_runs)" -eq 1 ] && ok "(a) gate ran exactly once" || bad "(a) gate ran $(gate_runs) time(s); want 1"
echo "$OUT" | grep -q "Disjoint re-sync (1 incoming files, none overlap this change)" && ok "(a) log explains the skipped re-gate" || bad "(a) no disjoint log line: $OUT"
echo "$OUT" | grep -q "disjoint re-sync; gated tree" && ok "(a) success line names gated and published trees" || bad "(a) success line wrong: $OUT"
echo "$OUT" | grep -q "verified" && bad "(a) a tree the gate never ran on was called verified" || ok "(a) never says verified"
git --git-dir="$TMP/origin.git" cat-file -e master:src/app.sh 2>/dev/null && git --git-dir="$TMP/origin.git" cat-file -e master:sibling.txt 2>/dev/null \
  && ok "(a) master has both the fix and the sibling's work" || bad "(a) master is missing the fix or the sibling's work"

# ── (b) overlapping re-sync (sibling edits a feature file): two gate runs ──
setup
OUT=$(bash "$MTI" --feature feature/code --issue $ISSUE --integration master --test-cmd "$(racing_gate 'sed -i "10s/.*/line 10 (sibling)/" README.md')" 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok "(b) overlapping re-sync merges" || bad "(b) rc=$RC: $OUT"
[ "$(gate_runs)" -eq 2 ] && ok "(b) gate re-ran on the merged tree" || bad "(b) gate ran $(gate_runs) time(s); want 2"
echo "$OUT" | grep -q "README.md (a file this change touched)" && ok "(b) log names the overlapping file" || bad "(b) overlap not logged: $OUT"
[ "$(tail -1 "$TMP/gate-runs")" = "$(git --git-dir="$TMP/origin.git" rev-parse 'master^{tree}')" ] && ok "(b) published tree is the last gated tree" || bad "(b) published tree was not the gated tree"
echo "$OUT" | grep -q "verified: tests passed on the published tree" && ok "(b) success line says verified" || bad "(b) success line wrong: $OUT"

# ── (c) sibling edits a global path: re-gate even though the fix never touched it ─
setup
OUT=$(bash "$MTI" --feature feature/code --issue $ISSUE --integration master --test-cmd "$(racing_gate 'echo "{}" > package.json')" 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok "(c) global-path re-sync merges" || bad "(c) rc=$RC: $OUT"
[ "$(gate_runs)" -eq 2 ] && ok "(c) gate re-ran after a global path changed" || bad "(c) gate ran $(gate_runs) time(s); want 2"
echo "$OUT" | grep -q "package.json (a global path)" && ok "(c) log names the global path" || bad "(c) global path not logged: $OUT"

setup
OUT=$(bash "$MTI" --feature feature/code --issue $ISSUE --integration master --test-cmd "$(racing_gate 'mkdir -p .github/workflows && echo on: push > .github/workflows/ci.yml')" 2>&1); RC=$?
[ "$(gate_runs)" -eq 2 ] && ok "(c) a nested .github/ path counts as global" || bad "(c) .github/workflows/ci.yml did not re-gate ($(gate_runs) runs): $OUT"

setup
OUT=$(AUTOCODER_GATE_GLOBAL_PATHS="Makefile" bash "$MTI" --feature feature/code --issue $ISSUE --integration master --test-cmd "$(racing_gate 'echo "{}" > package.json')" 2>&1); RC=$?
[ "$(gate_runs)" -eq 1 ] && ok "(c) AUTOCODER_GATE_GLOBAL_PATHS replaces the default list" || bad "(c) override ignored ($(gate_runs) runs): $OUT"

setup
OUT=$(bash "$MTI" --feature feature/code --issue $ISSUE --integration master --test-cmd "$(racing_gate 'echo "require y" >> go.mod')" 2>&1); RC=$?
[ "$(gate_runs)" -eq 2 ] && echo "$OUT" | grep -q "go.mod (a global path)" && ok "(c) go.mod is global by default" || bad "(c) go.mod did not re-gate ($(gate_runs) runs): $OUT"

setup
OUT=$(bash "$MTI" --feature feature/code --issue $ISSUE --integration master --test-cmd "$(racing_gate 'mkdir -p proj && echo "<Project/>" > proj/App.csproj')" 2>&1); RC=$?
[ "$(gate_runs)" -eq 2 ] && echo "$OUT" | grep -q "proj/App.csproj (a global path)" && ok "(c) a nested *.csproj is global by default" || bad "(c) *.csproj did not re-gate ($(gate_runs) runs): $OUT"

# ── (c') a path the gate command runs is global even when nobody listed it ──
setup
OUT=$(bash "$MTI" --feature feature/code --issue $ISSUE --integration master --test-cmd "$(racing_gate 'echo "echo patched" >> scripts/helper.sh') && bash scripts/helper.sh" 2>&1); RC=$?
[ "$RC" -eq 0 ] && [ "$(gate_runs)" -eq 2 ] && ok "(c') a sibling editing a file the gate runs re-gates" || bad "(c') rc=$RC runs=$(gate_runs): $OUT"
echo "$OUT" | grep -q "scripts/helper.sh (a path the gate command runs)" && ok "(c') log names the gate-command path" || bad "(c') reason not logged: $OUT"

setup
OUT=$(bash "$MTI" --feature feature/code --issue $ISSUE --integration master --test-cmd "$(racing_gate 'echo "echo patched" >> scripts/helper.sh') && true" 2>&1); RC=$?
[ "$(gate_runs)" -eq 1 ] && ok "(c') the same edit is disjoint when the gate does not run that file" || bad "(c') re-gated without reason ($(gate_runs) runs): $OUT"

# ── (c'') a sibling renaming a file this change edits is an overlap, not a new path ──
setup
OUT=$(bash "$MTI" --feature feature/code --issue $ISSUE --integration master --test-cmd "$(racing_gate 'git mv README.md README.rst')" 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok "(c'') rename re-sync merges" || bad "(c'') rc=$RC: $OUT"
[ "$(gate_runs)" -eq 2 ] && echo "$OUT" | grep -q "README.md (a file this change touched)" && ok "(c'') the renamed source file re-gates (--no-renames)" || bad "(c'') rename read as disjoint ($(gate_runs) runs): $OUT"

# ── (d) a tree already recorded as passing is not re-run ────────────────────
setup
GATE='echo "$(git rev-parse HEAD^{tree})" >> '"$TMP"'/gate-runs'
# shellcheck source=../plugins/autocoder/scripts/gate-cache-fns.sh
source "$SCRIPT_DIR/gate-cache-fns.sh"
gate_cache_put "$(git rev-parse 'feature/code^{tree}')" "$GATE" pass
OUT=$(bash "$MTI" --feature feature/code --issue $ISSUE --integration master --test-cmd "$GATE" 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok "(d) cached tree merges" || bad "(d) rc=$RC: $OUT"
[ "$(gate_runs)" -eq 0 ] && ok "(d) gate did not run for a tree already recorded as passing" || bad "(d) gate ran $(gate_runs) time(s); want 0"
echo "$OUT" | grep -q "pass recorded for tree" && ok "(d) log says the record was reused" || bad "(d) no cache-hit line: $OUT"

# ── (e) integrated tree fails, base passes: this change broke it ────────────
setup
BEFORE=$(origin_master)
GATE='echo "$(git rev-parse HEAD^{tree})" >> '"$TMP"'/gate-runs; [ ! -f src/app.sh ]'
OUT=$(bash "$MTI" --feature feature/code --issue $ISSUE --integration master --test-cmd "$GATE" 2>&1); RC=$?
[ "$RC" -eq 2 ] && ok "(e) exit 2 when only the integrated tree fails" || bad "(e) rc=$RC: $OUT"
[ "$(origin_master)" = "$BEFORE" ] && ok "(e) nothing pushed" || bad "(e) master moved"
[ "$(gate_runs)" -eq 2 ] && ok "(e) gate ran on the integrated tree and on the base" || bad "(e) gate ran $(gate_runs) time(s); want 2"
[ "$(tail -1 "$TMP/gate-runs")" = "$(git rev-parse 'origin/master^{tree}')" ] && ok "(e) second run gated origin/master alone" || bad "(e) second run was not the base tree"
echo "$OUT" | grep -q "passes alone, so this change broke it" && ok "(e) verdict blames this change" || bad "(e) verdict wrong: $OUT"
[ -d "$(base_worktree)" ] && bad "(e) base worktree left behind" || ok "(e) base worktree cleaned up"

# ── (f) integrated tree fails, base fails: red main, push anyway ────────────
setup
GATE='echo "$(git rev-parse HEAD^{tree})" >> '"$TMP"'/gate-runs; false'
OUT=$(bash "$MTI" --feature feature/code --issue $ISSUE --integration master --test-cmd "$GATE" 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok "(f) exit 0 on a red base" || bad "(f) rc=$RC: $OUT"
git --git-dir="$TMP/origin.git" cat-file -e master:src/app.sh 2>/dev/null && ok "(f) fix landed on master" || bad "(f) fix did not land"
echo "$OUT" | grep -q "merged into 'master' on a red base" && ok "(f) distinct success line" || bad "(f) success line wrong: $OUT"
echo "$OUT" | grep -q "verified" && bad "(f) red-base push was called verified" || ok "(f) never says verified"
issue_body | grep -q "Merged onto a red" && ok "(f) issue comment says the base was red" || bad "(f) no issue comment: $(issue_body)"
BASE_TREE=$(git rev-parse 'origin/master~1^{tree}' 2>/dev/null || git rev-parse "$BEFORE^{tree}")
issue_body | grep -q "$BASE_TREE" && ok "(f) issue comment carries the base tree id" || bad "(f) base tree id missing from comment"
[ -d "$(base_worktree)" ] && bad "(f) base worktree left behind" || ok "(f) base worktree cleaned up"

# ── (f') red base, then a disjoint re-sync: the published tree is neither gated tree ──
setup
OUT=$(bash "$MTI" --feature feature/code --issue $ISSUE --integration master --test-cmd "$(racing_gate 'echo s > sibling.txt' false)" 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok "(f') exit 0 on a red base followed by a disjoint re-sync" || bad "(f') rc=$RC: $OUT"
[ "$(gate_runs)" -eq 2 ] && ok "(f') gate ran on the integrated tree and the base only" || bad "(f') gate ran $(gate_runs) time(s); want 2"
echo "$OUT" | grep -q "on a red base followed by a disjoint re-sync" && echo "$OUT" | grep -q "is neither gated tree" && ok "(f') success line says the published tree is neither gated tree" || bad "(f') success line wrong: $OUT"
issue_body | grep -q "then re-synced" && issue_body | grep -q "neither tree the gate ran on" && ok "(f') issue comment says so too" || bad "(f') issue comment: $(issue_body)"
git --git-dir="$TMP/origin.git" cat-file -e master:sibling.txt 2>/dev/null && git --git-dir="$TMP/origin.git" cat-file -e master:src/app.sh 2>/dev/null && ok "(f') master has both the fix and the sibling's work" || bad "(f') master is missing work"

# ── (g) AUTOCODER_MERGE_ON_RED_BASE=0 restores exit 2 ──────────────────────
setup
BEFORE=$(origin_master)
OUT=$(AUTOCODER_MERGE_ON_RED_BASE=0 bash "$MTI" --feature feature/code --issue $ISSUE --integration master --test-cmd "$GATE" 2>&1); RC=$?
[ "$RC" -eq 2 ] && ok "(g) exit 2 with merge-on-red-base off" || bad "(g) rc=$RC: $OUT"
[ "$(origin_master)" = "$BEFORE" ] && ok "(g) nothing pushed" || bad "(g) master moved"
echo "$OUT" | grep -q "AUTOCODER_MERGE_ON_RED_BASE=0" && ok "(g) refusal names the switch" || bad "(g) refusal wrong: $OUT"

# ── (g') no green ref: a red base refuses even with the switch on ───────────
setup nogreen
BEFORE=$(origin_master)
OUT=$(AUTOCODER_MERGE_ON_RED_BASE=1 bash "$MTI" --feature feature/code --issue $ISSUE --integration master --test-cmd "$GATE" 2>&1); RC=$?
[ "$RC" -eq 2 ] && ok "(g') exit 2 on a red base without a green ref" || bad "(g') rc=$RC: $OUT"
[ "$(origin_master)" = "$BEFORE" ] && ok "(g') nothing pushed" || bad "(g') master moved"
echo "$OUT" | grep -q "no sentinel has proven a green master yet" && ok "(g') refusal says why" || bad "(g') refusal wrong: $OUT"

TOTAL=$((PASS + FAIL))
echo "$PASS passed / $FAIL failed / $TOTAL total"
[ "$FAIL" -eq 0 ]
