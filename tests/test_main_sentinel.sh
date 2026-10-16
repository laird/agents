#!/bin/bash
# tests/test_main_sentinel.sh — main-sentinel.sh gates the integration tip after merges,
# reuses worker verdicts, bisects over the tip refs the pipeline recorded, reverts exactly
# the culprit push, files the P0 against its issue, survives a crash between push and
# bookkeeping, closes parked issues on green, and reconciles hand-offs whose merge job died.
# Hermetic: bare origin + clone, file issue backend, a fake gate that fails iff a file named
# BROKEN exists in the tree, and a post-receive hook that counts every push origin receives.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SENTINEL="$ROOT/plugins/autocoder/scripts/main-sentinel.sh"
# shellcheck source=../plugins/autocoder/scripts/gate-cache-fns.sh
source "$ROOT/plugins/autocoder/scripts/gate-cache-fns.sh"
# shellcheck source=../plugins/autocoder/scripts/repo-id-fns.sh
source "$ROOT/plugins/autocoder/scripts/repo-id-fns.sh"

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
unset ISSUE_BACKEND

# fixture <name> [integration-branch]: fresh origin, clone on the branch, empty file issue
# backend, isolated cache/state/tmp dirs, push counter.
fixture() {
  local d="$TMP/$1"
  BR="${2:-main}"
  mkdir -p "$d/tmp" "$d/.issues/open" "$d/.issues/working" "$d/.issues/blocked" "$d/.issues/closed"
  echo 100 > "$d/.issues/.seq"
  git init -q --bare "$d/origin.git"
  git clone -q "$d/origin.git" "$d/repo" 2>/dev/null
  REPO="$d/repo"; ORIGIN="$d/origin.git"; ISSUES="$d/.issues"; RUNS="$d/runs"; PUSHES="$d/pushes"
  : > "$RUNS"; : > "$PUSHES"
  cat > "$ORIGIN/hooks/post-receive" <<EOF
#!/bin/sh
while read old new ref; do echo "\$ref \$new" >> "$PUSHES"; done
EOF
  chmod +x "$ORIGIN/hooks/post-receive"
  git -C "$REPO" config user.email t@example.com
  git -C "$REPO" config user.name T
  git -C "$REPO" checkout -q -b "$BR"
  echo base > "$REPO/README.md"
  git -C "$REPO" add -A && git -C "$REPO" commit -qm "base" && git -C "$REPO" push -q -u origin "$BR" 2>/dev/null
  TEST_CMD="echo run >> $RUNS; test ! -e BROKEN"
  export ISSUE_SOURCE=file ISSUE_DIR_PATH="$ISSUES" CLAUDE_CODE_SHIP_BRANCH="$BR"
  export AUTOCODER_GATE_CACHE_DIR="$d/gate-cache" AUTOCODER_SENTINEL_STATE_DIR="$d/state" AUTOCODER_TMP="$d/tmp"
  REPO_ID=$(autocoder_repo_id "$REPO")
}
sentinel() { bash "$SENTINEL" --repo "$REPO" --integration "$BR" --test-cmd "$TEST_CMD" "$@"; }
runs() { wc -l < "$RUNS"; }
pushes_to() { grep -c "^refs/heads/$1 " "$PUSHES"; }
origin_sha() { git -C "$ORIGIN" rev-parse -q --verify "$1" 2>/dev/null; }
tip_ref() { git -C "$ORIGIN" for-each-ref --format='%(refname)' "refs/autocoder/tips/$BR/$1-*" | head -1; }
state_file() { echo "$AUTOCODER_SENTINEL_STATE_DIR/${REPO_ID}-${BR}"; }
state_of() { sed -n "s/^$1=//p" "$(state_file)"; }
has_file() { git -C "$ORIGIN" cat-file -e "$1:$2" 2>/dev/null; }
issue_file() { ls "$ISSUES"/{open,working,blocked,closed}/"$(printf '%03d' "$1")".md 2>/dev/null | head -1; }
make_issue() {
  local n="$1" labels="${2:-P2}"
  cat > "$ISSUES/open/$(printf '%03d' "$n").md" <<EOF
---
number: $n
title: Issue $n
labels: [$labels]
status: open
---
Body $n.
EOF
}
# land <issue> <file> [<branch-from>]: what a worker's merge job does. Branch from a base
# (default: the current integration tip), commit, merge the integration tip in, push the
# feature tip as the new integration tip, then record it as a tip ref. Prints the landed sha.
land() {
  local issue="$1" file="$2" from="${3:-}" sha
  git -C "$REPO" fetch -q origin
  [ -n "$from" ] || from=$(git -C "$REPO" rev-parse "origin/$BR")
  git -C "$REPO" checkout -q --detach "$from"
  echo "$file" > "$REPO/$file"; git -C "$REPO" add -A; git -C "$REPO" commit -qm "$file (#$issue)"
  if [ "$from" != "$(git -C "$REPO" rev-parse "origin/$BR")" ]; then
    git -C "$REPO" merge -q --no-ff "origin/$BR" -m "Merge origin/$BR into feature/issue-$issue (pre-integration sync)" || return 1
  fi
  sha=$(git -C "$REPO" rev-parse HEAD)
  git -C "$REPO" push -q origin "HEAD:refs/heads/$BR" 2>/dev/null || return 1
  git -C "$REPO" push -q origin "$sha:refs/autocoder/tips/$BR/$sha-$issue" 2>/dev/null
  git -C "$REPO" checkout -q "$BR" 2>/dev/null; git -C "$REPO" reset -q --hard "origin/$BR"
  echo "$sha"
}
human_push() {  # a push nobody recorded
  git -C "$REPO" fetch -q origin; git -C "$REPO" checkout -q "$BR"; git -C "$REPO" reset -q --hard "origin/$BR"
  echo "$1" > "$REPO/$1"; git -C "$REPO" add -A; git -C "$REPO" commit -qm "$2"
  git -C "$REPO" push -q origin "$BR" 2>/dev/null
  git -C "$REPO" rev-parse HEAD
}

echo "── 1. green tick ──"
fixture green
OUT=$(sentinel); RC=$?
check "exit 0" '[ "$RC" -eq 0 ]'
check "gate ran once" '[ "$(runs)" -eq 1 ]'
check "origin/main-green == origin/main" '[ "$(origin_sha main-green)" = "$(origin_sha main)" ]'
check "state records last_green=tip" '[ "$(state_of last_green)" = "$(origin_sha main)" ]'
check "prints green" 'grep -q "✅ main green" <<< "$OUT"'
check "no sentinel worktree left behind" '[ "$(git -C "$REPO" worktree list | wc -l)" -eq 1 ] && [ -z "$(ls -A "$AUTOCODER_TMP/autocoder-sentinel-${REPO_ID}-main" 2>/dev/null)" ]'

echo "── 2. idle ──"
OUT=$(sentinel); RC=$?
check "exit 0" '[ "$RC" -eq 0 ]'
check "zero gate runs" '[ "$(runs)" -eq 1 ]'
check "prints idle" 'grep -q "idle" <<< "$OUT"'

echo "── 3. tip a worker already gated ──"
land 5 f2 >/dev/null
gate_cache_put "$(git -C "$REPO" rev-parse 'origin/main^{tree}')" "$TEST_CMD" pass
sentinel >/dev/null; RC=$?
check "exit 0" '[ "$RC" -eq 0 ]'
check "zero gate runs (worker verdict reused)" '[ "$(runs)" -eq 1 ]'
check "origin/main-green moved to the new tip" '[ "$(origin_sha main-green)" = "$(origin_sha main)" ]'

echo "── 4. culprit is an OLDER push than the newest: tips A < B < C, B broken, C innocent ──"
fixture older
sentinel >/dev/null
G0=$(origin_sha main)
make_issue 41; make_issue 42 awaiting-integration; make_issue 43
A=$(land 41 fa)
B=$(land 42 BROKEN "$G0")
C=$(land 43 fc "$A")
check "setup: C is the tip, B and A its ancestors, B's issue is parked" '[ "$(origin_sha main)" = "$C" ] && git -C "$REPO" merge-base --is-ancestor "$B" "$C" && grep -q awaiting-integration "$(issue_file 42)"'
MAIN_PUSHES=$(pushes_to main)
OUT=$(sentinel); RC=$?
check "exit 0 (repaired)" '[ "$RC" -eq 0 ]'
R=$(origin_sha main)
check "one push landed a revert on top of C" '[ "$(pushes_to main)" -eq $((MAIN_PUSHES + 1)) ] && [ "$(git -C "$ORIGIN" rev-parse "$R^")" = "$C" ]'
check "BROKEN is gone" '! has_file "$R" BROKEN'
check "A's and C's files survive" 'has_file "$R" fa && has_file "$R" fc'
check "culprit named is B, attributed to issue 42" 'grep -q "Culprit push ${B:0:7} (issue #42)" <<< "$OUT"'
check "revert message carries the trailers" 'git -C "$ORIGIN" log -1 --format=%B "$R" | grep -q "^Autocoder-Reverts: $B$" && git -C "$ORIGIN" log -1 --format=%B "$R" | grep -q "^Autocoder-Reverts-Issue: 42$"'
check "revert subject names the push and the issue" '[ "$(git -C "$ORIGIN" log -1 --format=%s "$R")" = "Revert autocoder push ${B:0:7} (issue #42)" ]'
P0=$(grep -l "Culprit push: \`$B\`" "$ISSUES"/open/*.md | head -1)
P0_NUM=$(sed -n 's/^number: //p' "$P0")
check "a P0 test-failure issue names B, issue 42 and the range" '[ -n "$P0" ] && grep -q "^labels: \[P0, test-failure\]" "$P0" && grep -q "(issue #42), range \`$A..$B\`" "$P0"'
check "P0 title is the revert shape" 'grep -q "^title: Reverted ${B:0:7} on main (issue #42)" "$P0"'
check "P0 body has the tip bisect log and the gate output" 'grep -q "first bad push: $B" "$P0" && grep -q "Gate output" "$P0"'
check "P0 comment names the revert sha and the re-land steps" 'grep -q "as \`$R\`" "$P0" && grep -q "git revert $R" "$P0"'
check "revert published as a tip ref under the P0 number" '[ "$(tip_ref "$R")" = "refs/autocoder/tips/main/$R-$P0_NUM" ]'
check "origin/main-green moved to the revert" '[ "$(origin_sha main-green)" = "$R" ]'
check "issue 42 told how to re-land and put back in the queue" 'grep -q "reverted as \`$R\`" "$(issue_file 42)" && ! grep -q "^labels:.*awaiting-integration" "$(issue_file 42)" && [ -f "$ISSUES/open/042.md" ]'
check "issues 41 and 43 untouched" '! grep -q "$R" "$(issue_file 41)" && ! grep -q "$R" "$(issue_file 43)"'
check "state: last_tested is the revert, no pending fields, red_issue clear" '[ "$(state_of last_tested)" = "$R" ] && [ -z "$(state_of pending_revert)" ] && [ -z "$(state_of red_issue)" ]'
check "prints the reverted line" 'grep -q "🔁 reverted push ${B:0:7} as ${R:0:7}; filed #${P0_NUM}" <<< "$OUT"'
check "the per-repair bisect cache is gone" '[ -z "$(ls -d "$(state_file)".bisect-cache.* 2>/dev/null)" ]'
OUT=$(sentinel); RC=$?
check "next tick is idle" '[ "$RC" -eq 0 ] && grep -q idle <<< "$OUT"'

echo "── 5. crash between the pending save and the bookkeeping ──"
# Rewind every bookkeeping artifact to what a tick that died right after its push leaves:
# the revert is on origin/main, the tip ref and green move are missing, the state still
# names the pending revert.
git -C "$ORIGIN" update-ref -d "refs/autocoder/tips/main/$R-$P0_NUM"
git -C "$REPO" update-ref -d "refs/autocoder/tips/main/$R-$P0_NUM"
git -C "$ORIGIN" update-ref refs/heads/main-green "$G0"
printf 'last_tested=%s\nlast_green=%s\nred_issue=%s\npending_revert=%s\npending_culprit=%s\npending_issue=42\npending_p0=%s\n' "$G0" "$G0" "$P0_NUM" "$R" "$B" "$P0_NUM" > "$(state_file)"
MAIN_PUSHES=$(pushes_to main); P0_COUNT=$(grep -l test-failure "$ISSUES"/open/*.md | wc -l); RUNS_BEFORE=$(runs)
OUT=$(sentinel); RC=$?
check "exit 0" '[ "$RC" -eq 0 ]'
check "prints that it is finishing an earlier tick's revert" 'grep -q "Finishing bookkeeping for revert ${R:0:7}" <<< "$OUT"'
check "no second push to main, no second P0, no gate run" '[ "$(pushes_to main)" -eq "$MAIN_PUSHES" ] && [ "$(grep -l test-failure "$ISSUES"/open/*.md | wc -l)" -eq "$P0_COUNT" ] && [ "$(runs)" -eq "$RUNS_BEFORE" ]'
check "tip ref re-published" '[ "$(tip_ref "$R")" = "refs/autocoder/tips/main/$R-$P0_NUM" ]'
check "green ref moved to the revert" '[ "$(origin_sha main-green)" = "$R" ]'
check "state cleared: pending empty, red_issue empty, last_tested = revert" '[ -z "$(state_of pending_revert)" ] && [ -z "$(state_of red_issue)" ] && [ "$(state_of last_tested)" = "$R" ]'
check "issue 42 not commented twice" '[ "$(grep -c "reverted as \`$R\`" "$(issue_file 42)")" -eq 1 ]'
printf 'last_tested=%s\nlast_green=%s\nred_issue=\npending_revert=%s\npending_culprit=%s\npending_issue=42\npending_p0=%s\n' "$R" "$R" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" "$B" "$P0_NUM" > "$(state_file)"
OUT=$(sentinel); RC=$?
check "a pending revert that never reached origin is dropped" '[ "$RC" -eq 0 ] && grep -q "Dropping unpushed pending revert" <<< "$OUT" && [ -z "$(state_of pending_revert)" ]'

echo "── 6. a human push (no tip ref) is the culprit ──"
fixture human
sentinel >/dev/null
G=$(origin_sha main)
H=$(human_push BROKEN "human breaks main")
OUT=$(sentinel); RC=$?
R=$(origin_sha main)
check "exit 0 (repaired)" '[ "$RC" -eq 0 ]'
check "synthetic tip: culprit is the human push, issue unknown" 'grep -q "Culprit push ${H:0:7} (issue an unrecorded push)" <<< "$OUT"'
check "BROKEN reverted on top of the human push" '[ "$(git -C "$ORIGIN" rev-parse "$R^")" = "$H" ] && ! has_file "$R" BROKEN'
P0=$(grep -l "Culprit push: \`$H\`" "$ISSUES"/open/*.md | head -1); P0_NUM=$(sed -n 's/^number: //p' "$P0")
check "P0 filed with the unknown issue, revert tip ref under the P0 number" '[ -n "$P0" ] && [ "$(tip_ref "$R")" = "refs/autocoder/tips/main/$R-$P0_NUM" ]'
check "origin/main-green moved to the revert" '[ "$(origin_sha main-green)" = "$R" ]'

echo "── 7. red with no green baseline; red P0 closed on the next green ──"
fixture nobase
echo broken > "$REPO/BROKEN"; git -C "$REPO" add -A; git -C "$REPO" commit -qm "broken from the start"
git -C "$REPO" push -q origin main 2>/dev/null
TIP=$(origin_sha main)
OUT=$(sentinel); RC=$?
check "exit 3" '[ "$RC" -eq 3 ]'
check "origin/main untouched, no green ref" '[ "$(origin_sha main)" = "$TIP" ] && [ -z "$(origin_sha main-green)" ]'
check "one P0 filed, body names the tip" '[ "$(grep -l test-failure "$ISSUES"/open/*.md | wc -l)" -eq 1 ] && grep -q "$TIP" "$ISSUES"/open/*.md'
RED=$(state_of red_issue)
check "state records red_issue" '[[ "$RED" =~ ^[0-9]+$ ]]'
OUT=$(sentinel); RC=$?
check "second tick on the same tip: exit 0, idle, nothing new filed" '[ "$RC" -eq 0 ] && [ "$(grep -l test-failure "$ISSUES"/open/*.md | wc -l)" -eq 1 ] && [ "$(runs)" -eq 1 ]'
human_push f5 "still broken" >/dev/null
sentinel >/dev/null; RC=$?
check "a new red tip comments on the open red issue instead of filing again" '[ "$RC" -eq 3 ] && [ "$(grep -l test-failure "$ISSUES"/open/*.md | wc -l)" -eq 1 ] && grep -q "Still red" "$(issue_file "$RED")"'
sed -i 's/^red_issue=.*/red_issue=/' "$(state_file)"
human_push f6 "still broken, state lost" >/dev/null
sentinel >/dev/null; RC=$?
check "with red_issue lost from state, the open P0 is found by title instead of duplicated" '[ "$RC" -eq 3 ] && [ "$(grep -l test-failure "$ISSUES"/open/*.md | wc -l)" -eq 1 ] && [ "$(state_of red_issue)" = "$RED" ]'
git -C "$REPO" rm -q BROKEN; git -C "$REPO" commit -qm "human fixes main"; git -C "$REPO" push -q origin main 2>/dev/null
FIXED=$(origin_sha main)
OUT=$(sentinel); RC=$?
check "green again: exit 0, green ref set" '[ "$RC" -eq 0 ] && [ "$(origin_sha main-green)" = "$FIXED" ]'
check "the red P0 is closed with the green sha" '[ -f "$ISSUES/closed/$(printf %03d "$RED").md" ] && grep -q "green again at \`$FIXED\`" "$ISSUES/closed/$(printf %03d "$RED").md"'
check "state: red_issue cleared" '[ -z "$(state_of red_issue)" ]'

echo "── 8. parked issues close on green ──"
fixture parked
sentinel >/dev/null
make_issue 50 awaiting-integration; make_issue 51 awaiting-integration; make_issue 52 awaiting-integration
S50=$(land 50 f50)
S51=$(land 51 BROKEN)
sentinel >/dev/null; RC=$?
R=$(origin_sha main)
check "setup: tick repaired by reverting 51's push" '[ "$RC" -eq 0 ] && ! has_file "$R" BROKEN'
check "#50 (push on the green tip, shipped): closed with the landed and green shas" '[ -f "$ISSUES/closed/050.md" ] && grep -q "Landed as \`$S50\`; \`main\` green at \`$R\`" "$ISSUES/closed/050.md"'
check "#51 (its push was reverted): not closed, re-queued with the re-land note" '[ -f "$ISSUES/open/051.md" ] && grep -q "git revert $R" "$ISSUES/open/051.md" && ! grep -q "awaiting-integration" "$ISSUES/open/051.md"'
check "#52 (no tip ref, pr-mode style): untouched" '[ -f "$ISSUES/open/052.md" ] && grep -q "^labels: \[awaiting-integration\]" "$ISSUES/open/052.md" && ! grep -q "Landed" "$ISSUES/open/052.md"'
make_issue 53 awaiting-integration
S53=$(land 53 f53)
CLAUDE_CODE_SHIP_BRANCH=release sentinel >/dev/null
check "#53 landed and green but not on the ship branch: stays parked" '[ -f "$ISSUES/open/053.md" ] && grep -q "^labels: \[awaiting-integration\]" "$ISSUES/open/053.md"'
git -C "$REPO" push -q origin "origin/main:refs/heads/release" 2>/dev/null
human_push f54 "unrelated" >/dev/null
CLAUDE_CODE_SHIP_BRANCH=release sentinel >/dev/null
check "#53 closes on the next green tick once the ship branch has it" '[ -f "$ISSUES/closed/053.md" ] && grep -q "Landed as \`$S53\`" "$ISSUES/closed/053.md"'

echo "── 9. hand-offs whose merge job died ──"
fixture handoff
sentinel >/dev/null
sh -c 'exit 0' & DEAD=$!; wait "$DEAD" 2>/dev/null
J() { echo "$AUTOCODER_TMP/autocoder-merge-${REPO_ID}-$1"; }
make_issue 7 merging; make_issue 8 merging; make_issue 9 merging; make_issue 10 merging
make_issue 11 awaiting-integration; make_issue 13 merging; make_issue 14 P2
S7=$(land 7 f7)
echo "$DEAD" > "$(J 7).pid"
echo "$DEAD" > "$(J 8).pid"; printf '#!/bin/bash\necho reran > %q\n' "$AUTOCODER_TMP/reran-8" > "$(J 8).run.sh"
echo "$DEAD" > "$(J 9).pid"
echo "$$"   > "$(J 10).pid"
echo "$DEAD" > "$AUTOCODER_TMP/autocoder-merge-11.pid"
echo "$DEAD" > "$(J 12).pid"; echo 0 > "$(J 12).exit"; : > "$(J 12).run.sh"; : > "$(J 12).log"; touch -d '2 days ago' "$(J 12).exit"
echo "$DEAD" > "$(J 13).pid"; printf '#!/bin/bash\n' > "$(J 13).run.sh"; : > "$(J 13).rerun"
echo "$DEAD" > "$(J 14).pid"
cp "$ISSUES/open/014.md" "$TMP/014.before"
OUT=$(sentinel); RC=$?
check "tick green" '[ "$RC" -eq 0 ]'
check "#7 (dead job, push recorded): closed once the tip went green" '[ -f "$ISSUES/closed/007.md" ] && grep -q "Landed as \`$S7\`" "$ISSUES/closed/007.md"'
sleep 1
check "#8 (dead job, run.sh present): re-run once, issue told, still merging" '[ -f "$AUTOCODER_TMP/reran-8" ] && [ -f "$(J 8).rerun" ] && grep -q "re-ran it once" "$ISSUES/open/008.md" && grep -q "^labels: \[merging\]" "$ISSUES/open/008.md"'
check "#9 (dead job, nothing to re-run): re-queued" '! grep -q "^labels:.*merging" "$ISSUES/open/009.md" && grep -q "re-queued" "$ISSUES/open/009.md" && [ ! -f "$(J 9).pid" ]'
check "#10 (live job): untouched" 'grep -q "^labels: \[merging\]" "$ISSUES/open/010.md" && [ -f "$(J 10).pid" ] && ! grep -q "merge job" "$ISSUES/open/010.md"'
check "#11 (old pidfile name, awaiting-integration): re-queued" '! grep -q "^labels:.*awaiting-integration" "$ISSUES/open/011.md" && grep -q "re-queued" "$ISSUES/open/011.md" && [ ! -f "$AUTOCODER_TMP/autocoder-merge-11.pid" ]'
check "#12 (finished two days ago): pid, exit, run.sh, log reaped" '[ ! -e "$(J 12).pid" ] && [ ! -e "$(J 12).exit" ] && [ ! -e "$(J 12).run.sh" ] && [ ! -e "$(J 12).log" ]'
check "#13 (died again after a re-run): re-queued, not re-run twice" '! grep -q "^labels:.*merging" "$ISSUES/open/013.md" && grep -q "re-queued" "$ISSUES/open/013.md"'
check "#14 (dead pidfile, not in flight): untouched" 'cmp -s "$ISSUES/open/014.md" "$TMP/014.before"'

echo "── 10. two concurrent ticks ──"
fixture lock
sentinel >/dev/null
RUNS_BEFORE=$(runs)
human_push f1 "new tip" >/dev/null
flock -n "$(state_file).lock" sleep 3 &
HOLDER=$!
sleep 0.3
OUT=$(sentinel); RC=$?
check "second tick exits 0 with the lock message and runs nothing" '[ "$RC" -eq 0 ] && grep -q "another tick is running" <<< "$OUT" && [ "$(runs)" -eq "$RUNS_BEFORE" ]'
wait "$HOLDER" 2>/dev/null
OUT=$(sentinel); RC=$?
check "after the lock is released the tick gates the new tip" '[ "$RC" -eq 0 ] && [ "$(runs)" -eq $((RUNS_BEFORE + 1)) ]'

echo "── 11. green ref default follows the integration branch ──"
fixture master master
sentinel >/dev/null; RC=$?
check "integration master: origin/master-green set, no main-green" '[ "$RC" -eq 0 ] && [ "$(origin_sha master-green)" = "$(origin_sha master)" ] && [ -z "$(origin_sha main-green)" ]'
human_push f1 "next" >/dev/null
AUTOCODER_GREEN_REF=proof sentinel >/dev/null
check "AUTOCODER_GREEN_REF overrides the default" '[ "$(origin_sha proof)" = "$(origin_sha master)" ]'
human_push f2 "next again" >/dev/null
AUTOCODER_GREEN_REF=proof sentinel --green-ref flag-wins >/dev/null
check "--green-ref overrides both" '[ "$(origin_sha flag-wins)" = "$(origin_sha master)" ] && [ "$(origin_sha proof)" != "$(origin_sha master)" ]'

echo "── 12. config errors ──"
sentinel --loop 2>&1 >/dev/null; RC=$?
check "a flag without a value exits 1" '[ "$RC" -eq 1 ]'
bash "$SENTINEL" --repo "$REPO" >/dev/null 2>&1; RC=$?
check "no resolvable test command exits 1" '[ "$RC" -eq 1 ]'

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
