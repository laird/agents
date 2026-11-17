#!/bin/bash
# tests/test_merge_rebase_ff.sh — the merge job lands by rebase + fast-forward (#221):
#   - a branch behind master by unrelated commits lands as a fast-forward: linear history,
#     no merge commit, the feature's commits replayed in order on the old tip;
#   - a lost push race re-syncs by rebasing again: still linear, no "push retry" commit;
#   - the close comment names the rebased landed commit and the reviewed pre-rebase HEAD;
#   - the feature branch on origin is deleted with a lease on the pre-rebase SHA, and kept
#     when it moved during the job;
#   - a branch whose changes are already on master under other SHAs lands nothing;
#   - a rebase conflict bounces to the worker with the files listed (#207).
# File backend and a local bare origin, as in tests/test_merge_bounce.sh.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$ROOT/plugins/autocoder/scripts"
MTI="$SCRIPT_DIR/merge-to-integration.sh"
ISSUES_PY="$SCRIPT_DIR/issues-file.py"
ISSUE=22101

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export AUTOCODER_SPOT_CHECK_RATE=0
export ISSUE_SOURCE=file
export AUTOCODER_TMP="$TMP/tmp"; mkdir -p "$AUTOCODER_TMP"
export ISSUE_DIR_PATH="$TMP/issues"
export AUTOCODER_GATE_CACHE_DIR="$TMP/gate-cache"
export CLAUDE_CODE_SHIP_BRANCH=master
unset AUTOCODER_MERGE_ON_RED_BASE AUTOCODER_SCOPED_REGATE

O() { git --git-dir="$TMP/origin.git" "$@"; }

# origin with master; worker on feature/code (two commits) pushed to origin; master then
# moves on by an unrelated sibling commit, so the feature is behind.
setup() {
  rm -rf "$TMP/origin.git" "$TMP/worker" "$TMP/sibling" "$TMP/gate-cache" "$TMP/issues"
  mkdir -p "$TMP/issues/open" "$TMP/issues/working" "$TMP/issues/blocked" "$TMP/issues/closed"
  printf -- '---\nnumber: %s\ntitle: Rebase\npriority: P2\nlabels: [bug]\nstatus: open\n---\nBody.\n' "$ISSUE" > "$TMP/issues/open/${ISSUE}.md"
  python3 "$ISSUES_PY" claim "$ISSUE" >/dev/null
  git init --bare -q "$TMP/origin.git"
  git init -q "$TMP/worker"
  cd "$TMP/worker" || exit 1
  git config user.email t@example.com; git config user.name T
  git remote add origin "$TMP/origin.git"
  echo base > README.md; mkdir -p src; echo base > src/a.sh
  git add -A; git commit -q -m init; git branch -M master; git push -q origin master
  git checkout -q -b feature/code master
  echo one > src/a.sh; git commit -qam "feature one"
  echo two > src/b.sh; git add -A; git commit -qm "feature two"
  git push -q origin feature/code
  git clone -q "$TMP/origin.git" "$TMP/sibling"
  git -C "$TMP/sibling" config user.email s@example.com; git -C "$TMP/sibling" config user.name S
  sibling_lands other.txt
}
sibling_lands() {  # sibling pushes an unrelated (or given) file change to master
  (cd "$TMP/sibling" && git pull -q origin master && echo "sib $RANDOM" > "$1" && git add -A && git commit -q -m "sibling $1" && git push -q origin master)
}
issue_file()   { ls "$TMP"/issues/*/"${ISSUE}.md" 2>/dev/null | head -1; }
issue_bucket() { basename "$(dirname "$(issue_file)")"; }
issue_labels() { python3 "$ISSUES_PY" get "$ISSUE" | python3 -c 'import json,sys; print(" ".join(sorted(l["name"] for l in json.load(sys.stdin)["labels"])))'; }
run_own() { bash "$MTI" --feature feature/code --issue $ISSUE --integration master --test-cmd "$1" --own-issue 2>&1; }

# ── 1. behind by unrelated work: lands as a fast-forward of the rebased series ──
setup
OLD_TIP=$(O rev-parse master)
FEATURE_SHA=$(git rev-parse feature/code)
OUT=$(run_own true); RC=$?
[ "$RC" -eq 0 ] && ok "lands (rc 0)" || bad "rc=$RC: $OUT"
[ -z "$(O rev-list --merges master)" ] && ok "no merge commit on master" || bad "merge commits: $(O log --merges --oneline master)"
[ "$(O log --format=%s master | head -3 | tr '\n' '|')" = "feature two|feature one|sibling other.txt|" ] \
  && ok "the feature's commits sit, in order, directly on the old tip" || bad "history: $(O log --format=%s master)"
[ "$(O rev-parse master~2)" = "$OLD_TIP" ] && ok "the landed series' base is the tip the job saw" || bad "base $(O rev-parse master~2) != $OLD_TIP"
LANDED=$(O rev-parse master)
[ "$LANDED" != "$FEATURE_SHA" ] && ok "the landed commit is the rebased tip, not the feature SHA" || bad "landed == feature sha"
O rev-parse -q --verify "refs/autocoder/tips/master/${LANDED}-${ISSUE}" >/dev/null && ok "the tip ref names the rebased commit" || bad "tip ref missing: $(O for-each-ref refs/autocoder)"
[ "$(issue_bucket)" = closed ] && ok "issue closed" || bad "issue $(issue_bucket) $(issue_labels)"
grep -q "Landed by rebase" "$(issue_file)" && grep -q "$FEATURE_SHA" "$(issue_file)" && grep -q "$LANDED" "$(issue_file)" \
  && ok "close comment says landed by rebase and names both commits" || bad "close comment: $(cat "$(issue_file)")"
O rev-parse -q --verify refs/heads/feature/code >/dev/null && bad "feature branch still on origin" || ok "feature branch deleted (lease on the pre-rebase SHA)"
echo "$OUT" | grep -q "Rebased feature/code" && ok "log names the rebase" || bad "no rebase line: $OUT"

# ── 2. lost push race: re-sync by rebase, still linear, no push-retry commit ──
setup
# The gate lets the sibling land once, so the first push is rejected.
RACE="if [ ! -e $TMP/raced ]; then touch $TMP/raced; (cd $TMP/sibling && git pull -q origin master && echo r > race.txt && git add -A && git commit -q -m 'sibling race' && git push -q origin master); fi; true"
rm -f "$TMP/raced"
OUT=$(run_own "$RACE"); RC=$?
[ "$RC" -eq 0 ] && ok "race: lands" || bad "race rc=$RC: $OUT"
echo "$OUT" | grep -q "rejected" && ok "race: the first push really was rejected" || bad "race: no rejection, so nothing was tested: $OUT"
[ -z "$(O rev-list --merges master)" ] && ok "race: no merge commit on master" || bad "race: merge commits $(O log --merges --oneline master)"
O log --format=%s master | grep -q "push retry" && bad "race: a push-retry commit landed" || ok "race: no push-retry commit"
[ "$(O log --format=%s master | head -3 | tr '\n' '|')" = "feature two|feature one|sibling race|" ] \
  && ok "race: the series was rebased onto the racing tip" || bad "race history: $(O log --format=%s master)"
[ "$(issue_bucket)" = closed ] && ok "race: issue closed" || bad "race issue $(issue_bucket) $(issue_labels)"

# ── 3. feature branch moved during the job: kept ────────────────────────────
setup
MOVE="(cd $TMP/worker && echo three > src/c.sh && git add -A && git commit -q -m 'feature three' && git push -q origin feature/code); true"
OUT=$(run_own "$MOVE"); RC=$?
[ "$RC" -eq 0 ] || bad "moved: rc=$RC: $OUT"
O rev-parse -q --verify refs/heads/feature/code >/dev/null && ok "a feature branch that moved is not deleted" || bad "moved branch deleted"

# ── 4. changes already on master under other SHAs: nothing lands ────────────
setup
(cd "$TMP/sibling" && git pull -q origin master && git fetch -q origin feature/code && git cherry-pick origin/master..origin/feature/code >/dev/null && git push -q origin master)
BEFORE=$(O rev-parse master)
OUT=$(run_own true); RC=$?
[ "$RC" -eq 0 ] && ok "already-picked: rc 0" || bad "already-picked rc=$RC: $OUT"
[ "$(O rev-parse master)" = "$BEFORE" ] && ok "already-picked: master did not move" || bad "already-picked: master moved"
echo "$OUT" | grep -q "left nothing to land" && ok "already-picked: says nothing was left" || bad "already-picked log: $OUT"
echo "$OUT" | grep -q "Gating the integrated tree" && bad "already-picked: gated anyway" || ok "already-picked: not gated"
[ "$(issue_bucket)" = closed ] && ok "already-picked: issue closed" || bad "already-picked issue $(issue_bucket) $(issue_labels)"

# ── 5. rebase conflict: bounced with the files, no rebase left behind ───────
setup
sibling_lands src/a.sh
BEFORE=$(O rev-parse master)
OUT=$(run_own true); RC=$?
[ "$RC" -eq 1 ] && ok "conflict: rc 1" || bad "conflict rc=$RC: $OUT"
[ "$(O rev-parse master)" = "$BEFORE" ] && ok "conflict: nothing pushed" || bad "conflict: master moved"
[ "$(issue_labels)" = "bug working" ] && ok "conflict: back to working" || bad "conflict labels: $(issue_labels)"
grep -q '^- `src/a.sh`$' "$(issue_file)" && grep -q "kind=conflict" "$(issue_file)" && ok "conflict: file listed and kind=conflict marker" || bad "conflict comment: $(cat "$(issue_file)")"
echo "$OUT" | grep -q "Aborted the rebase" && ok "conflict: the rebase was aborted" || bad "conflict log: $OUT"

echo ""
echo "$PASS passed / $FAIL failed / $((PASS + FAIL)) total"
[ "$FAIL" -eq 0 ]
