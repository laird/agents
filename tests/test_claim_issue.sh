#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255: never write the real event logs
# claim-issue.sh (#289): /fix's claim, selection and branch setup, moved out of
# commands/fix.md. Runs against the file backend in a private temp repo with its
# own .autocoder.json and a local bare origin, so it never touches the real tracker.

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)/plugins/autocoder/scripts"
CLAIM="$SCRIPT_DIR/claim-issue.sh"

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want '$2', got '$3'"; fi; }
assert_file() { if [ -f "$2" ]; then ok "$1"; else bad "$1 — missing $2"; fi; }
assert_grep() { if grep -Fq -- "$3" "$2" 2>/dev/null; then ok "$1"; else bad "$1 — '$3' not in $2"; fi; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export TMPDIR="$TMP"

git init -q --bare -b master "$TMP/origin.git"
git clone -q "$TMP/origin.git" "$TMP/main" 2>/dev/null
MAIN="$TMP/main"
cd "$MAIN" || exit 1
git config user.email test@example.com
git config user.name Test
git checkout -q -b master
echo test > README.md
git add README.md && git commit -q -m initial && git push -q origin master
git remote set-head origin master >/dev/null 2>&1 || true

ISSUES="$TMP/issues"   # outside the checkout, so branch switches never move it
mkdir -p "$ISSUES/open" "$ISSUES/working" "$ISSUES/blocked" "$ISSUES/closed"
printf '{"issueSource": "file", "issueDir": "%s"}\n' "$ISSUES" > "$MAIN/.autocoder.json"
git add .autocoder.json && git commit -q -m config && git push -q origin master

issue() { # issue NUM PRIORITY "labels" "body"
  printf -- '---\nnumber: %s\ntitle: Issue %s\npriority: %s\nlabels: [%s]\nstatus: open\n---\n%b\n' \
    "$1" "$1" "$2" "$3" "$4" > "$ISSUES/open/$(printf '%03d' "$1").md"
}
issue 20 P2 "bug, P2" "Body 20."
issue 22 P1 "bug, P1, needs-design" "Body 22."
issue 23 P1 "bug, P1" "Body 23 with 'quotes' and \$dollars."
issue 30 P0 "bug, P0" "Depends on: #20"

run_claim() { # run_claim [args...]; sets RC, OUTPUT and sources the hand-back
  local env="$TMP/claim.env"
  rm -f "$env"
  OUTPUT=$(INTEGRATION_BRANCH=master bash "$CLAIM" --out "$env" "$@" 2>&1)
  RC=$?
  CLAIM_STATUS="" ISSUE_NUM="" ISSUE_TITLE="" ISSUE_BODY="" ISSUE_PRIORITY="" RESUMING="" FIX_BRANCH="" PARENT_BRANCH=""
  if [ -f "$env" ]; then source "$env"; else bad "hand-back file written ($*)"; fi
}

# ── 1. selection: highest priority claimable; skips blocked and dependency-waiting
run_claim
assert_eq "selection: exit 0" 0 "$RC"
assert_eq "selection: status claimed" claimed "$CLAIM_STATUS"
assert_eq "selection: picks P1 #23 over P2 #20, skipping needs-design #22 and waiting #30" 23 "$ISSUE_NUM"
assert_eq "selection: priority handed back" 1 "$ISSUE_PRIORITY"
assert_eq "selection: body with quotes survives the hand-back" "Body 23 with 'quotes' and \$dollars." "$ISSUE_BODY"
assert_eq "selection: on the fix branch" feature/issue-23 "$(git branch --show-current)"
assert_eq "selection: FIX_BRANCH handed back" feature/issue-23 "$FIX_BRANCH"
assert_eq "selection: branched from origin/master" "$(git rev-parse origin/master)" "$(git rev-parse HEAD)"
assert_file "selection: issue moved to working" "$ISSUES/working/023.md"
assert_grep "selection: work-started comment posted" "$ISSUES/working/023.md" "Automated Fix Started"
assert_grep "selection: comment names the branch" "$ISSUES/working/023.md" "feature/issue-23"

# ── 2. own-claim resume (#182): our pushed branch and start comment are not a rival's lock
git push -q origin feature/issue-23
run_claim 23
assert_eq "no worker state: own pushed branch still reads as a lock (exit 1)" 1 "$RC"
assert_grep "no worker state: remote-branch message" <(printf '%s' "$OUTPUT") "already exists — another agent owns this issue"
echo "23 $(date +%s)" > "$(git rev-parse --absolute-git-dir)/autocoder-worker-state"
run_claim 23
assert_eq "resume: exit 0" 0 "$RC"
assert_eq "resume: RESUMING=true" true "$RESUMING"
assert_eq "resume: still on the fix branch" feature/issue-23 "$(git branch --show-current)"
assert_file "resume: claim kept" "$ISSUES/working/023.md"
rm -f "$(git rev-parse --absolute-git-dir)/autocoder-worker-state"

# ── 3. specified issue whose dependency is open: refused before claiming
git checkout -q master
run_claim 30
assert_eq "dependency: exit 1" 1 "$RC"
assert_eq "dependency: status refused" refused "$CLAIM_STATUS"
assert_grep "dependency: says what it waits on" <(printf '%s' "$OUTPUT") "waits on"
assert_file "dependency: not claimed" "$ISSUES/open/030.md"
assert_eq "dependency: no branch created" "" "$(git branch --list feature/issue-30)"

# ── 4. specified issue with another agent's remote branch: refused, left open
git push -q origin "master:refs/heads/feature/issue-20"
run_claim 20
assert_eq "remote lock: exit 1" 1 "$RC"
assert_file "remote lock: left open" "$ISSUES/open/020.md"
assert_eq "remote lock: still on master" master "$(git branch --show-current)"

# ── 5. nothing claimable: idle, exit 0 (20 has a branch, 22 blocked, 30 waits on 20)
run_claim
assert_eq "idle: exit 0" 0 "$RC"
assert_eq "idle: status idle" idle "$CLAIM_STATUS"
assert_grep "idle: prints IDLE_NO_WORK_AVAILABLE" <(printf '%s' "$OUTPUT") "IDLE_NO_WORK_AVAILABLE"
assert_eq "idle: no issue handed back" "" "$ISSUE_NUM"

# ── 6. --base parent (Antigravity flow): branches from the current branch, records it
issue 40 P3 "bug, P3" "Body 40."
git checkout -q -b main-wt-1 master
echo wt > wt.txt && git add wt.txt && git commit -q -m wt && git push -q origin main-wt-1
run_claim --base parent 40
assert_eq "parent: exit 0" 0 "$RC"
assert_eq "parent: PARENT_BRANCH recorded" main-wt-1 "$PARENT_BRANCH"
assert_eq "parent: branched from the parent" "$(git rev-parse main-wt-1)" "$(git rev-parse HEAD)"

# ── 7. bad arguments
OUTPUT=$(bash "$CLAIM" 2>&1); RC=$?
assert_eq "no --out: exit 1" 1 "$RC"
OUTPUT=$(bash "$CLAIM" --out "$TMP/x.env" --base sideways 2>&1); RC=$?
assert_eq "bad --base: exit 1" 1 "$RC"
OUTPUT=$(timeout 10 bash "$CLAIM" --out 2>&1); RC=$?
assert_eq "--out with no value: exit 1, no hang" 1 "$RC"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
