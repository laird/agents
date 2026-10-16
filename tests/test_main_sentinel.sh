#!/bin/bash
# tests/test_main_sentinel.sh — main-sentinel.sh gates the integration tip after merges,
# reuses worker verdicts, bisects and reverts a red tip, files the P0, and re-queues issues
# whose detached merge job died. Hermetic: bare origin + clone, file issue backend, a fake
# gate that fails iff a file named BROKEN exists in the tree.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SENTINEL="$ROOT/plugins/autocoder/scripts/main-sentinel.sh"
# shellcheck source=../plugins/autocoder/scripts/gate-cache-fns.sh
source "$ROOT/plugins/autocoder/scripts/gate-cache-fns.sh"

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
unset ISSUE_BACKEND

# Fresh origin, clone on main, empty file issue backend, isolated cache/state/tmp dirs.
fixture() {
  local d="$TMP/$1"
  mkdir -p "$d/tmp" "$d/.issues/open" "$d/.issues/working" "$d/.issues/blocked" "$d/.issues/closed"
  echo 100 > "$d/.issues/.seq"
  git init -q --bare "$d/origin.git"
  git clone -q "$d/origin.git" "$d/repo" 2>/dev/null
  REPO="$d/repo"; ORIGIN="$d/origin.git"; ISSUES="$d/.issues"; RUNS="$d/runs"
  git -C "$REPO" config user.email t@example.com
  git -C "$REPO" config user.name T
  git -C "$REPO" checkout -q -b main
  echo base > "$REPO/README.md"
  git -C "$REPO" add -A && git -C "$REPO" commit -qm "base" && git -C "$REPO" push -q -u origin main 2>/dev/null
  : > "$RUNS"
  TEST_CMD="echo run >> $RUNS; test ! -e BROKEN"
  export ISSUE_SOURCE=file ISSUE_DIR_PATH="$ISSUES"
  export AUTOCODER_GATE_CACHE_DIR="$d/gate-cache" AUTOCODER_SENTINEL_STATE_DIR="$d/state" AUTOCODER_TMP="$d/tmp"
}
sentinel() { bash "$SENTINEL" --repo "$REPO" --test-cmd "$TEST_CMD" "$@"; }
runs() { wc -l < "$RUNS"; }
origin_sha() { git -C "$ORIGIN" rev-parse -q --verify "refs/heads/$1" 2>/dev/null; }
commit_on_main() { echo "$1" > "$REPO/$1"; git -C "$REPO" add -A; git -C "$REPO" commit -qm "$2"; }
state_file() { ls "$AUTOCODER_SENTINEL_STATE_DIR"/*-main 2>/dev/null | head -1; }

echo "── 1. green tip ──"
fixture green
OUT=$(sentinel); RC=$?
check "exit 0" '[ "$RC" -eq 0 ]'
check "gate ran once" '[ "$(runs)" -eq 1 ]'
check "origin/main-green == origin/main" '[ "$(origin_sha main-green)" = "$(origin_sha main)" ]'
check "state records last_green=tip" 'grep -q "^last_green=$(origin_sha main)$" "$(state_file)"'
check "prints green" 'grep -q "✅ main green" <<< "$OUT"'

echo "── 2. same tip again ──"
OUT=$(sentinel); RC=$?
check "exit 0" '[ "$RC" -eq 0 ]'
check "zero gate runs" '[ "$(runs)" -eq 1 ]'
check "prints idle" 'grep -q "idle" <<< "$OUT"'

echo "── 3. tip a worker already gated ──"
commit_on_main f2 "add f2"
git -C "$REPO" push -q origin main 2>/dev/null
gate_cache_put "$(git -C "$REPO" rev-parse 'HEAD^{tree}')" "$TEST_CMD" pass
sentinel >/dev/null; RC=$?
check "exit 0" '[ "$RC" -eq 0 ]'
check "zero gate runs (worker verdict reused)" '[ "$(runs)" -eq 1 ]'
check "origin/main-green moved to the new tip" '[ "$(origin_sha main-green)" = "$(origin_sha main)" ]'

echo "── 4. red tip with a green baseline ──"
cat > "$ISSUES/open/042.md" <<'EOF'
---
number: 42
title: Feature that breaks things
labels: [P2]
status: open
---
Original body.
EOF
commit_on_main f3 "add f3"
git -C "$REPO" checkout -q -b feature/issue-42
echo broken > "$REPO/BROKEN"; git -C "$REPO" add -A; git -C "$REPO" commit -qm "break the build"
git -C "$REPO" checkout -q main
git -C "$REPO" merge -q --no-ff feature/issue-42 -m "Merge issue #42 (feature/issue-42) into main"
CULPRIT=$(git -C "$REPO" rev-parse HEAD)
commit_on_main f4 "add f4"
TIP_D=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" push -q origin main 2>/dev/null
OUT=$(sentinel); RC=$?
check "exit 0 (repaired)" '[ "$RC" -eq 0 ]'
git -C "$REPO" fetch -q origin
NEW_TIP=$(origin_sha main)
check "a revert landed on origin/main" '[ "$NEW_TIP" != "$TIP_D" ] && [ "$(git -C "$REPO" rev-parse "$NEW_TIP^")" = "$TIP_D" ]'
check "origin/main no longer contains BROKEN" '! git -C "$REPO" cat-file -e "$NEW_TIP:BROKEN" 2>/dev/null'
check "the revert keeps the later good commit" 'git -C "$REPO" cat-file -e "$NEW_TIP:f4" 2>/dev/null'
check "revert message names the merge culprit" 'git -C "$REPO" log -1 --format=%B "$NEW_TIP" | grep -q "$CULPRIT"'
check "origin/main-green moved to the revert" '[ "$(origin_sha main-green)" = "$NEW_TIP" ]'
P0=$(grep -l "$CULPRIT" "$ISSUES"/open/*.md | grep -v 042.md | head -1)
check "a P0 test-failure issue names the culprit sha" '[ -n "$P0" ] && grep -q "^labels: \[P0, test-failure\]" "$P0"'
check "P0 title says reverted" 'grep -q "^title: Regression gate red on main: reverted ${CULPRIT:0:7}" "$P0"'
check "P0 body carries the bisect log and gate output" 'grep -q "first bad commit" "$P0" && grep -q "Gate output" "$P0"'
check "P0 references the originating issue" 'grep -q "Originating issue: #42" "$P0"'
check "originating issue #42 got a comment" 'grep -q "Regression" "$ISSUES/open/042.md"'
check "prints the reverted line" 'grep -q "🔁 reverted ${CULPRIT:0:7}" <<< "$OUT"'
check "state: last_tested is the pushed revert" 'grep -q "^last_tested=$NEW_TIP$" "$(state_file)" && grep -q "^red_issue=$" "$(state_file)"'
OUT=$(sentinel); RC=$?
check "next tick is idle" '[ "$RC" -eq 0 ] && grep -q idle <<< "$OUT"'

echo "── 4b. culprit is a worker's sync merge (feature is parent 1, main is parent 2) ──"
# The swarm pushes the feature tip as the new main tip, so main's history runs through
# "Merge origin/main into feature/…" merges whose FIRST parent is the feature. The break
# here exists only in the combination, so bisect names that sync merge. The revert must
# remove the feature's contribution and keep the sibling's.
fixture syncmerge
TEST_CMD="echo run >> $RUNS; ! { [ -e sibling ] && [ -e feature ]; }"
sentinel >/dev/null
BASE=$(git -C "$REPO" rev-parse HEAD)
commit_on_main sibling "sibling worker lands (#7)"
git -C "$REPO" push -q origin main 2>/dev/null
sentinel >/dev/null
GREEN_SHA=$(origin_sha main)
git -C "$REPO" checkout -q -b feature/issue-43 "$BASE"
commit_on_main feature "feature work (#43)"
git -C "$REPO" merge -q --no-ff origin/main -m "Merge origin/main into feature/issue-43 (pre-integration sync)"
SYNC=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" push -q origin HEAD:main 2>/dev/null
OUT=$(sentinel); RC=$?
check "exit 0 (repaired)" '[ "$RC" -eq 0 ]'
git -C "$REPO" fetch -q origin
NEW_TIP=$(origin_sha main)
check "bisect named the sync merge" 'grep -q "Culprit ${SYNC:0:7}" <<< "$OUT"'
check "the sibling's landed file survives the revert" 'git -C "$REPO" cat-file -e "$NEW_TIP:sibling" 2>/dev/null'
check "the feature's file is gone" '! git -C "$REPO" cat-file -e "$NEW_TIP:feature" 2>/dev/null'
check "revert parent is the red tip" '[ "$(git -C "$REPO" rev-parse "$NEW_TIP^")" = "$SYNC" ]'
check "origin/main-green moved to the revert" '[ "$(origin_sha main-green)" = "$NEW_TIP" ]'
git -C "$REPO" checkout -q main; git -C "$REPO" reset -q --hard "$NEW_TIP"

echo "── 4c. sync-merge culprit, feature branched after the last green, sibling landed in between ──"
# The common production shape: the sentinel last saw G; a sibling pushed S (its worker
# recorded S's tree as a gate pass); the feature branched after G and synced with S. Both
# parents contain G, and the merge subject is deliberately NOT one our scripts write, so
# only the shared gate-cache record tells the mainline (S) from the feature.
fixture latebranch
TEST_CMD="echo run >> $RUNS; ! { [ -e sibling ] && [ -e feature ]; }"
sentinel >/dev/null
G=$(origin_sha main)
commit_on_main sibling "sibling worker lands (#7)"
git -C "$REPO" push -q origin main 2>/dev/null
gate_cache_put "$(git -C "$REPO" rev-parse 'HEAD^{tree}')" "$TEST_CMD" pass
git -C "$REPO" checkout -q -b feature/issue-44 "$G"
commit_on_main feature "feature work (#44)"
git -C "$REPO" merge -q --no-ff origin/main -m "sync"
SYNC=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" push -q origin HEAD:main 2>/dev/null
OUT=$(sentinel); RC=$?
check "exit 0 (repaired)" '[ "$RC" -eq 0 ]'
git -C "$REPO" fetch -q origin
NEW_TIP=$(origin_sha main)
check "bisect named the sync merge" 'grep -q "Culprit ${SYNC:0:7}" <<< "$OUT"'
check "the sibling's landed file survives the revert" 'git -C "$REPO" cat-file -e "$NEW_TIP:sibling" 2>/dev/null'
check "the feature's file is gone" '! git -C "$REPO" cat-file -e "$NEW_TIP:feature" 2>/dev/null'
git -C "$REPO" checkout -q main; git -C "$REPO" reset -q --hard "$NEW_TIP"

echo "── 5. red tip with no green baseline ──"
fixture nobase
echo broken > "$REPO/BROKEN"; git -C "$REPO" add -A; git -C "$REPO" commit -qm "broken from the start"
git -C "$REPO" push -q origin main 2>/dev/null
TIP=$(origin_sha main)
OUT=$(sentinel); RC=$?
check "exit 3" '[ "$RC" -eq 3 ]'
check "origin/main untouched" '[ "$(origin_sha main)" = "$TIP" ]'
check "no green ref" '[ -z "$(origin_sha main-green)" ]'
check "one P0 filed" '[ "$(grep -l "test-failure" "$ISSUES"/open/*.md | wc -l)" -eq 1 ]'
check "P0 body names the tip" 'grep -q "$TIP" "$ISSUES"/open/*.md'
check "state records red_issue" 'grep -q "^red_issue=[0-9]\+$" "$(state_file)"'
OUT=$(sentinel); RC=$?
check "second tick on the same tip: exit 0, nothing new filed" '[ "$RC" -eq 0 ] && [ "$(grep -l "test-failure" "$ISSUES"/open/*.md | wc -l)" -eq 1 ]'
check "second tick ran no gate" '[ "$(runs)" -eq 1 ]'
RED=$(sed -n 's/^red_issue=//p' "$(state_file)")
commit_on_main f5 "still broken"
git -C "$REPO" push -q origin main 2>/dev/null
sentinel >/dev/null; RC=$?
check "a new red tip comments on the open red issue instead of filing again" '[ "$RC" -eq 3 ] && [ "$(grep -l "test-failure" "$ISSUES"/open/*.md | wc -l)" -eq 1 ] && grep -q "Still red" "$ISSUES/open/$(printf "%03d" "$RED").md"'

echo "── 6. stale merge hand-offs ──"
fixture handoff
sh -c 'exit 0' & DEAD=$!; wait "$DEAD" 2>/dev/null
for n in 7 8 9 10; do
  cat > "$ISSUES/open/0$(printf %02d "$n").md" <<EOF
---
number: $n
title: Issue $n
labels: [$([ "$n" -eq 8 ] && echo P2 || echo awaiting-integration)]
status: open
---
Body $n.
EOF
done
cp "$ISSUES/open/008.md" "$TMP/008.before"
echo "$DEAD" > "$AUTOCODER_TMP/autocoder-merge-7.pid"
echo "$DEAD" > "$AUTOCODER_TMP/autocoder-merge-8.pid"
echo "$$"   > "$AUTOCODER_TMP/autocoder-merge-9.pid"
echo "$DEAD" > "$AUTOCODER_TMP/autocoder-merge-10.pid"; echo 0 > "$AUTOCODER_TMP/autocoder-merge-10.exit"
echo "$DEAD" > "$AUTOCODER_TMP/autocoder-merge-11.pid"; echo 0 > "$AUTOCODER_TMP/autocoder-merge-11.exit"; : > "$AUTOCODER_TMP/autocoder-merge-11.run.sh"
touch -d '2 days ago' "$AUTOCODER_TMP/autocoder-merge-11.exit"
sentinel >/dev/null; RC=$?
check "#11 (finished a day ago): pid, exit and run.sh reaped" '[ ! -e "$AUTOCODER_TMP/autocoder-merge-11.pid" ] && [ ! -e "$AUTOCODER_TMP/autocoder-merge-11.exit" ] && [ ! -e "$AUTOCODER_TMP/autocoder-merge-11.run.sh" ]'
check "tick still green" '[ "$RC" -eq 0 ]'
check "#7 (dead job, labelled): label removed" '! grep -q "^labels:.*awaiting-integration" "$ISSUES/open/007.md"'
check "#7: comment added" 'grep -q "merge job" "$ISSUES/open/007.md"'
check "#7: pidfile gone" '[ ! -f "$AUTOCODER_TMP/autocoder-merge-7.pid" ]'
check "#8 (dead job, unlabelled): issue untouched" 'cmp -s "$ISSUES/open/008.md" "$TMP/008.before"'
check "#8: pidfile gone" '[ ! -f "$AUTOCODER_TMP/autocoder-merge-8.pid" ]'
check "#9 (live job): untouched" 'grep -q "^labels: \[awaiting-integration\]" "$ISSUES/open/009.md" && [ -f "$AUTOCODER_TMP/autocoder-merge-9.pid" ]'
check "#10 (finished job): untouched" 'grep -q "^labels: \[awaiting-integration\]" "$ISSUES/open/010.md" && [ -f "$AUTOCODER_TMP/autocoder-merge-10.pid" ]'

echo "── 7. config errors ──"
sentinel --loop 2>&1 >/dev/null; RC=$?
check "a flag without a value exits 1" '[ "$RC" -eq 1 ]'
bash "$SENTINEL" --repo "$REPO" >/dev/null 2>&1; RC=$?
check "no resolvable test command exits 1" '[ "$RC" -eq 1 ]'

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
