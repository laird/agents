#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"
# tests/test_enqueue.sh — enqueue.sh, banking a finished branch from a host that does not gate: the
# preflight rows (fetch, rebase, merge-tree, build, tests, push), the READY comment with the block
# and the labels, a rebase conflict that posts nothing, the project preflight command in place of
# the generic rows, a dirty tree, --block-only, and the merge queue taking the READY as a
# first-class `preflight` item. Everything runs against a fixture bare origin and the file issue
# backend; nothing reaches a real tracker or remote.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$ROOT/plugins/autocoder/scripts"
ENQ="$SCRIPTS/enqueue.sh"
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want '$2', got '$3'"; fi; }
has() { if grep -qE -- "$2" <<<"$3"; then ok "$1"; else bad "$1 — '$2' not in: $(printf '%s' "$3" | tail -25)"; fi; }
hasnt() { if grep -qE -- "$2" <<<"$3"; then bad "$1 — '$2' unexpectedly in: $(printf '%s' "$3" | tail -25)"; else ok "$1"; fi; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
unset ISSUE_SOURCE ISSUE_BACKEND ISSUE_DIR_PATH AUTOCODER_ENQUEUE_PREFLIGHT_CMD AUTOCODER_ENQUEUE_BUILD_CMD AUTOCODER_ENQUEUE_TEST_CMD AUTOCODER_ENQUEUE_TEST_PATTERN
export AUTOCODER_LANDING_TIMINGS="$TMP/timings.jsonl" XDG_STATE_HOME="$TMP/state" AUTOCODER_TRAIN_SCRATCH="$TMP/scratch" ISSUE_DIR_PATH="$TMP/issues"
export GIT_AUTHOR_NAME=T GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=T GIT_COMMITTER_EMAIL=t@example.com
export LOG="$TMP/cmds.log"

ORIGIN="$TMP/origin.git"; W="$TMP/w"; ISSUES="$TMP/issues"
git init -q --bare "$ORIGIN"
git init -q -b master "$W"; git -C "$W" remote add origin "$ORIGIN"
mkdir -p "$W/src" "$W/tests" "$W/docs"
printf 'base\n' > "$W/README.md"; echo c > "$W/src/code.txt"; echo t > "$W/tests/code.test.txt"; echo d > "$W/docs/a.md"
git -C "$W" add -A; git -C "$W" commit -q -m init; git -C "$W" push -q origin master; git -C "$W" fetch -q origin
git -C "$W" update-ref refs/remotes/origin/HEAD refs/remotes/origin/master
echo ".autocoder.json" > "$W/.git/info/exclude"
cat > "$W/.autocoder.json" <<JSON
{ "issueSource": "file", "issueDir": "$ISSUES",
  "train": { "branchOwnership": "any", "enqueue": {
    "buildCmd": "echo build base=\$AUTOCODER_ENQUEUE_BASE changed=\$(grep -c . \"\$AUTOCODER_ENQUEUE_CHANGED_FILE\") >> \$LOG",
    "testCmd": "echo tests {files} >> \$LOG" } } }
JSON

issue() { python3 "$SCRIPTS/issues-file.py" create --title "$1" --body "spec" --label working --label P1 | python3 -c 'import json,sys; print(json.load(sys.stdin)["number"])'; }
labels() { python3 "$SCRIPTS/issues-file.py" get "$1" | python3 -c 'import json,sys; print(",".join(sorted(l["name"] for l in json.load(sys.stdin)["labels"])))'; }
body() { python3 "$SCRIPTS/issues-file.py" get "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin)["body"])'; }
otip() { git --git-dir "$ORIGIN" rev-parse --verify --quiet "$1" 2>/dev/null || echo none; }
# mk <branch> <file> <content>: a pushed branch with one commit off origin/master, checked out
mk() {
  git -C "$W" fetch -q origin
  git -C "$W" checkout -q -B "$1" origin/master
  mkdir -p "$(dirname "$W/$2")"; printf '%s\n' "$3" > "$W/$2"
  git -C "$W" add -A; git -C "$W" commit -q -m "change $1"; git -C "$W" push -q -f origin "$1"
}
# master_moves <file> <content>: a commit on origin/master the branch does not have
master_moves() {
  local d="$TMP/other"; rm -rf "$d"; git clone -q "$ORIGIN" "$d"
  mkdir -p "$(dirname "$d/$1")"; printf '%s\n' "$2" > "$d/$1"
  git -C "$d" add -A; git -C "$d" commit -q -m "master: $1"; git -C "$d" push -q origin HEAD:master
}
enq() { (cd "$W" && bash "$ENQ" "$@" 2>&1); }
cd "$W" || exit 1

# ── 1. the happy path: behind master, rebased, built, tested over the changed test file, pushed, READY ──
I1=$(issue one)
mk feature/one src/code.txt one; echo t1 > "$W/tests/code.test.txt"; git -C "$W" commit -qam "test one"; git -C "$W" push -q -f origin feature/one
OLD1=$(git -C "$W" rev-parse HEAD)
master_moves docs/late.md late
: > "$LOG"
out=$(enq --issue "$I1" --add-label host:x --note "flag: none"); RC=$?
eq "happy: exit 0" 0 "$RC"
has "happy: the block passes" '^=== preflight \(enqueue\.sh\): PASS === tree [0-9a-f]+ on origin/master [0-9a-f]{10} === host ' "$out"
has "happy: rebase row says it rebased" '^PASS rebase +[0-9]+s +rebased 2 commit\(s\) onto origin/master .*was 1 behind' "$out"
has "happy: merge-tree row counts the changed files" '^PASS merge-tree .*clean against origin/master .*2 file\(s\) changed' "$out"
has "happy: build row" '^PASS build .*build command passed' "$out"
has "happy: tests row names the changed test file only" '^PASS tests .*tests passed over the changed test file\(s\): tests/code.test.txt$' "$out"
has "happy: push row" '^PASS push .*origin/feature/one at' "$out"
has "happy: the closing line says the batch gate is the test" '^=== preflight: PASS -- not gated on this host; the batch gate is the test ===' "$out"
NEW1=$(git -C "$W" rev-parse HEAD)
[ "$NEW1" != "$OLD1" ] && ok "happy: HEAD moved (rebased)" || bad "happy: HEAD did not move"
eq "happy: origin/feature/one is the rebased tip" "$NEW1" "$(otip refs/heads/feature/one)"
eq "happy: the rebased tip sits on the moved master" "$(otip refs/heads/master)" "$(git -C "$W" rev-parse HEAD~2)"
MASTER1=$(otip refs/heads/master)
eq "happy: the build command saw the base sha and the changed-file list" "build base=$MASTER1 changed=2
tests tests/code.test.txt" "$(cat "$LOG")"
eq "happy: labels: ready-for-review and the extra label added, working removed" "P1,host:x,ready-for-review" "$(labels "$I1")"
B1=$(body "$I1")
has "happy: the READY names the branch in backticks with the tip" "READY \`feature/one\` @ $(git -C "$W" rev-parse --short HEAD) \(enqueued from a host that does not gate" "$B1"
has "happy: the READY carries the block" '=== preflight \(enqueue\.sh\): PASS ===' "$B1"
has "happy: the READY carries the note" '^flag: none$' "$B1"
has "happy: a ready landing-timings row" '"issue": *'"$I1"'.*"event": *"ready"|"event": *"ready".*"issue": *'"$I1" "$(cat "$AUTOCODER_LANDING_TIMINGS" 2>/dev/null)"
has "happy: the summary line" "^enqueued #$I1: READY .* labels \+ready-for-review \+host:x -working; the batch gate is the test" "$out"

# ── 2. the queue takes it as a first-class preflight item and plans it ──────────────────────
q=$(python3 "$SCRIPTS/merge-train.py" --repo "$W" queue --status-line 2>&1)
has "queue: the status line counts the preflight READY" "merge-train: 1 ready \| next #$I1 feature/one @ .*\| 1 preflight" "$q"
has "queue: the row is launchable with basis preflight and the note" $'^1\tqueue\t'"$I1"$'\tfeature/one\t[0-9a-f]+\t2\t[^\t]*\tpreflight READY \(enqueued from a host that does not gate\): the batch gate is its first full test\tpreflight$' "$q"
p=$(python3 "$SCRIPTS/merge-train.py" --repo "$W" plan 2>&1)
has "queue: the planner trains it" $'^train\t'"$I1"$'\tfeature/one\t' "$p"

# ── 3. a rebase conflict fails at rebase, aborts cleanly, pushes and posts nothing ──────────
I2=$(issue two)
mk feature/two README.md two
OLD2=$(git -C "$W" rev-parse HEAD)
master_moves README.md master-two
out=$(enq --issue "$I2"); RC=$?
eq "conflict: exit 1" 1 "$RC"
has "conflict: the rebase row names the file" '^FAIL rebase .*CONFLICTS in README.md' "$out"
has "conflict: the later rows are SKIP" '^SKIP push .*not run: rebase failed first' "$out"
has "conflict: the closing line" '=== preflight: FAIL at rebase -- fix it on this host and run again; nothing was posted ===' "$out"
eq "conflict: HEAD is back at the original tip" "$OLD2" "$(git -C "$W" rev-parse HEAD)"
eq "conflict: no rebase in progress, tree clean" "" "$(git -C "$W" status --porcelain; ls "$W/.git/rebase-merge" 2>/dev/null)"
eq "conflict: origin/feature/two untouched" "$OLD2" "$(otip refs/heads/feature/two)"
eq "conflict: labels untouched" "P1,working" "$(labels "$I2")"
hasnt "conflict: no READY posted" 'READY' "$(body "$I2")"

# ── 4. a project preflight command replaces the generic rows; its failure posts nothing ──────
I3=$(issue three)
mk feature/three src/three.txt three
out=$(enq --issue "$I3" --preflight-cmd 'echo project says no; exit 7'); RC=$?
eq "project preflight: a failing command exits 1" 1 "$RC"
has "project preflight: the row is FAIL with the command's exit" '^FAIL preflight .*exit 7: project preflight FAILED \(exit 7\)' "$out"
hasnt "project preflight: no generic build row" '^(PASS|SKIP|FAIL) build ' "$out"
eq "project preflight: labels untouched" "P1,working" "$(labels "$I3")"
out=$(enq --issue "$I3" --preflight-cmd 'echo "=== project preflight: PASS === $AUTOCODER_ENQUEUE_INTEGRATION"'); RC=$?
eq "project preflight: a passing command enqueues" 0 "$RC"
has "project preflight: the row is PASS" '^PASS preflight .*project preflight passed' "$out"
B3=$(body "$I3")
has "project preflight: the comment carries the project's own lines" '=== project preflight: PASS === master' "$B3"
eq "project preflight: labels moved" "P1,ready-for-review" "$(labels "$I3")"

# ── 4b. the host preflight budget (--budget): a slot row, held across the project preflight, a hotfix first ──
export AUTOCODER_PREFLIGHT_DIR="$TMP/budget" AUTOCODER_PREFLIGHT_SLOTS=1 AUTOCODER_PREFLIGHT_POLL_S=0.1 \
       AUTOCODER_PREFLIGHT_LOAD_FACTOR=off AUTOCODER_PREFLIGHT_WAIT_MAX_S=30 AUTOCODER_PREFLIGHT_ADMISSION_GAP_S=0 \
       AUTOCODER_HOST_EXCLUSIVE_POLL_S=0.1
I3B=$(issue three-b)
mk feature/three-b src/three-b.txt three-b
out=$(enq --issue "$I3B" --budget --host-exclusive types --preflight-cmd 'bash "$AUTOCODER_SCRIPTS_DIR/preflight-budget.sh" status; echo "role=$AUTOCODER_HOST_EXCLUSIVE_ROLE"; cat "$AUTOCODER_PREFLIGHT_DIR/exclusive/types.lock.holder"'); RC=$?
eq "budget: enqueues" 0 "$RC"
has "budget: a budget row names the slot" '^PASS budget +[0-9]+s +slot 1/1 after [0-9]+s in line; 1 slot\(s\) \(AUTOCODER_PREFLIGHT_SLOTS' "$out"
has "budget: the project preflight ran holding the slot" '^held: 1$' "$out"
has "budget: the slot's holder is this enqueue" 'slot 0: pid=[0-9]+ .*priority=ordinary branch=feature/three-b what=enqueue #'"$I3B" "$out"
has "budget: the project preflight sees the preflight role" '^role=preflight$' "$out"
has "budget: --host-exclusive runs it under the named lock, role preflight" '^pid=[0-9]+ token=[^ ]+ role=preflight since=.* what=enqueue #'"$I3B"' feature/three-b$' "$out"
has "budget: the preflight row says so" "under the host-exclusive lock types, role preflight" "$out"
eq "budget: the budget row comes before the preflight row" "budget preflight" "$(printf '%s\n' "$out" | grep -oE '^PASS (budget|preflight)' | awk '{print $2}' | paste -sd ' ')"
st=$(bash "$SCRIPTS/preflight-budget.sh" status 2>&1)
has "budget: the slot is released after" '^held: 0$' "$st"
# a hotfix branch ranks first; --priority says so too; a bad priority is usage
mk hotfix/77 src/hf.txt hf
out=$(enq --issue "$I3B" --budget --block-only); RC=$?
eq "budget: a hotfix branch enqueues" 0 "$RC"
has "budget: a hotfix branch takes the hotfix line" 'preflight budget: hotfix preflight: it takes the next free slot ahead of every ordinary waiter' "$out"
out=$(enq --issue "$I3B" --budget --priority bogus --block-only 2>&1); RC=$?
eq "budget: a bad --priority is usage (2)" 2 "$RC"
out=$(enq --issue "$I3B" --host-exclusive 'no good' --block-only 2>&1); RC=$?
eq "budget: a bad --host-exclusive name is usage (2)" 2 "$RC"
# the budget is opt-in: without it there is no budget row and nothing is held
git -C "$W" checkout -q feature/three-b
out=$(enq --issue "$I3B" --block-only --preflight-cmd 'true'); RC=$?
hasnt "budget: off by default (no row)" '^(PASS|FAIL|SKIP) budget ' "$out"
# a slot that never comes fails the budget row, runs no preflight and posts nothing
bash "$SCRIPTS/preflight-budget.sh" run --what other -- sleep 2 2>/dev/null &
sleep 0.3
out=$(AUTOCODER_PREFLIGHT_WAIT_MAX_S=1 enq --issue "$I3B" --budget --preflight-cmd 'echo MUST-NOT-RUN'); RC=$?
eq "budget: no slot fails the enqueue (1)" 1 "$RC"
has "budget: the row says no slot came and names the holder" '^FAIL budget .*no preflight slot' "$out"
has "budget: the refusal named the holder" 'holders: slot 0: pid=[0-9]+ .*what=other' "$out"
hasnt "budget: the preflight never ran" 'MUST-NOT-RUN' "$out"
has "budget: the preflight row is SKIP" '^SKIP preflight .*not run: budget failed first' "$out"
wait
unset AUTOCODER_PREFLIGHT_SLOTS

# ── 5. a dirty tree is refused before anything runs ─────────────────────────────────────────
I4=$(issue four)
mk feature/four src/four.txt four
echo dirty >> "$W/src/four.txt"
out=$(enq --issue "$I4"); RC=$?
eq "dirty: exit 1" 1 "$RC"
has "dirty: the rebase row says so" '^FAIL rebase .*uncommitted changes' "$out"
git -C "$W" checkout -q -- src/four.txt

# ── 6. --block-only prints the block, pushes nothing, posts nothing; no test file changed is a SKIP ──
T4=$(otip refs/heads/feature/four)
out=$(enq --issue "$I4" --block-only); RC=$?
eq "block-only: exit 0" 0 "$RC"
has "block-only: tests row is a named SKIP" '^SKIP tests .*no test file changed .*the batch gate is the test' "$out"
has "block-only: push row says skipped" '^PASS push .*push skipped \(--block-only\)' "$out"
hasnt "block-only: no comment printed" 'READY `' "$out"
eq "block-only: origin untouched" "$T4" "$(otip refs/heads/feature/four)"
eq "block-only: labels untouched" "P1,working" "$(labels "$I4")"

# ── 7. --no-post prints the comment instead of posting it ───────────────────────────────────
out=$(enq --issue "$I4" --no-post --note "flag: retired"); RC=$?
eq "no-post: exit 0" 0 "$RC"
has "no-post: the comment is printed" 'READY comment \(not posted, --no-post\)' "$out"
has "no-post: with the note" '^flag: retired$' "$out"
eq "no-post: labels untouched" "P1,working" "$(labels "$I4")"

# ── 8. usage ────────────────────────────────────────────────────────────────────────────────
out=$(enq); RC=$?
eq "usage: --issue is required (exit 2)" 2 "$RC"
out=$(enq --issue 1 --branch master); RC=$?
eq "usage: the integration branch is refused (exit 2)" 2 "$RC"

echo; echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
