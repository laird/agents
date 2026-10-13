#!/bin/bash
# tests/test_merge_requires_test_cmd.sh — merge-to-integration.sh must never push
# an untested tree to the integration branch:
#   - with no --test-cmd it resolves the command from AGENTS.md / CLAUDE.md
#     ('### Regression Test Suite'); if none resolves it refuses BEFORE any
#     fetch/merge/push and leaves the integration branch unmoved;
#   - a documents-only change is the one exemption;
#   - a rejected push whose re-sync brings in new work re-runs the tests before
#     pushing again;
#   - merge-launch.sh refuses to launch when no command resolves.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$ROOT/plugins/autocoder/scripts"
MTI="$SCRIPT_DIR/merge-to-integration.sh"
ISSUE=19201

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"; rm -f /tmp/autocoder-merge-${ISSUE}.*; rm -rf /tmp/autocoder-merge-worktree-${ISSUE}' EXIT
export ISSUE_SOURCE=file

# Fresh bare origin + worker checkout. $1 = doctrine file contents for CLAUDE.md
# on master ("" for none).
setup() {
  rm -rf "$TMP/origin.git" "$TMP/worker" "$TMP/sibling"
  git init --bare -q "$TMP/origin.git"
  git init -q "$TMP/worker"
  cd "$TMP/worker" || exit 1
  git config user.email t@example.com; git config user.name T
  git remote add origin "$TMP/origin.git"
  echo base > README.md
  [ -n "$1" ] && printf '%s\n' "$1" > CLAUDE.md
  git add -A; git commit -q -m init; git branch -M master; git push -q origin master
  git fetch -q origin
}

branch_with() {  # $1 branch, $2 file
  git checkout -q -b "$1" master
  mkdir -p "$(dirname "$2")"; echo change > "$2"
  git add -A; git commit -q -m "change $2"
}

origin_master() { git --git-dir="$TMP/origin.git" rev-parse master; }

DOCTRINE='# Project

### Regression Test Suite
```bash
# comment lines are skipped
echo ran >> '"$TMP"'/gate-runs
```

### Unit Tests Only
```bash
false
```'

# ── 1. No --test-cmd, no doctrine, code diff → refused, master unmoved ──────
setup ""
branch_with feature/code src/app.sh
BEFORE=$(origin_master)
OUT=$(bash "$MTI" --feature feature/code --issue $ISSUE --integration master 2>&1); RC=$?
[ "$RC" -ne 0 ] && ok "no test command on a code diff exits non-zero" || bad "no test command on a code diff exited 0: $OUT"
[ "$(origin_master)" = "$BEFORE" ] && ok "integration branch unmoved after refusal" || bad "integration branch moved despite refusal"
echo "$OUT" | grep -q "Nothing was fetched" && ok "refusal names the missing command" || bad "refusal message missing: $OUT"
echo "$OUT" | grep -q "verified" && bad "refusal path printed 'verified'" || ok "refusal path never claims 'verified'"
[ -d "/tmp/autocoder-merge-worktree-${ISSUE}" ] && bad "refusal created the merge worktree" || ok "refusal happened before the merge worktree was created"

# ── 2. No --test-cmd, no doctrine, docs-only diff → allowed ─────────────────
setup ""
branch_with feature/docs docs/guide.md
OUT=$(bash "$MTI" --feature feature/docs --issue $ISSUE --integration master 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok "documents-only diff merges without a test command" || bad "documents-only diff refused (rc=$RC): $OUT"
git --git-dir="$TMP/origin.git" cat-file -e master:docs/guide.md 2>/dev/null && ok "documents-only change landed" || bad "documents-only change did not land"
echo "$OUT" | grep -q "no tests run" && ok "docs-only success says no tests ran" || bad "docs-only success message wrong: $OUT"

# ── 3. No --test-cmd, doctrine present → command resolved and run ───────────
setup "$DOCTRINE"
rm -f "$TMP/gate-runs"
branch_with feature/code src/app.sh
OUT=$(bash "$MTI" --feature feature/code --issue $ISSUE --integration master 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok "doctrine-resolved gate passes and merges" || bad "doctrine-resolved merge failed (rc=$RC): $OUT"
[ "$(wc -l < "$TMP/gate-runs" 2>/dev/null)" = "1" ] && ok "Regression Test Suite command ran exactly once" || bad "gate run count wrong: $(cat "$TMP/gate-runs" 2>/dev/null)"
echo "$OUT" | grep -q "tests passed" && ok "success message reports the tests passed" || bad "success message wrong: $OUT"

# ── 4. Doctrine command fails → exit 2, master unmoved ──────────────────────
setup '### Regression Test Suite
```bash
false
```'
branch_with feature/code src/app.sh
BEFORE=$(origin_master)
bash "$MTI" --feature feature/code --issue $ISSUE --integration master >/dev/null 2>&1; RC=$?
[ "$RC" -eq 2 ] && ok "failing doctrine gate exits 2" || bad "failing doctrine gate exit=$RC"
[ "$(origin_master)" = "$BEFORE" ] && ok "failing gate leaves integration branch unmoved" || bad "failing gate moved the integration branch"

# ── 5. Rejected push → re-sync → tests re-run before the next push ──────────
setup ""
git clone -q "$TMP/origin.git" "$TMP/sibling"
git -C "$TMP/sibling" config user.email s@example.com; git -C "$TMP/sibling" config user.name S
cd "$TMP/worker" || exit 1
branch_with feature/code src/app.sh
rm -f "$TMP/gate-runs" "$TMP/raced"
# First gate run: a sibling lands on master meanwhile, so our push is rejected.
GATE='echo "$(git rev-parse HEAD^{tree})" >> '"$TMP"'/gate-runs
if [ ! -f '"$TMP"'/raced ]; then touch '"$TMP"'/raced
  (cd '"$TMP"'/sibling && echo s > sibling.txt && git add sibling.txt && git commit -q -m sib && git push -q origin master)
fi'
OUT=$(bash "$MTI" --feature feature/code --issue $ISSUE --integration master --test-cmd "$GATE" 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok "rejected push recovered" || bad "retry path failed (rc=$RC): $OUT"
RUNS=$(wc -l < "$TMP/gate-runs" 2>/dev/null || echo 0)
[ "$RUNS" -eq 2 ] && ok "gate re-ran after the re-sync (2 runs)" || bad "gate ran $RUNS time(s); want 2"
PUBLISHED_TREE=$(git --git-dir="$TMP/origin.git" rev-parse 'master^{tree}')
[ "$(tail -1 "$TMP/gate-runs")" = "$PUBLISHED_TREE" ] && ok "the published tree is the one the last gate run tested" || bad "published tree was not the tested tree"

# ── 6. merge-launch.sh refuses to launch with no resolvable command ─────────
setup ""
branch_with feature/code src/app.sh
OUT=$(bash "$SCRIPT_DIR/merge-launch.sh" --feature feature/code --issue $ISSUE --integration master 2>&1); RC=$?
[ "$RC" -ne 0 ] && ok "merge-launch.sh refuses with no test command" || bad "merge-launch.sh launched with no test command: $OUT"
[ -f "/tmp/autocoder-merge-${ISSUE}.pid" ] || [ -f "/tmp/autocoder-merge-${ISSUE}.run.sh" ] \
  && bad "merge-launch.sh left launch state behind" || ok "merge-launch.sh started nothing"

TOTAL=$((PASS + FAIL))
echo "$PASS passed / $FAIL failed / $TOTAL total"
[ "$FAIL" -eq 0 ]
