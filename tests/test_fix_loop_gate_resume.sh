#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255: never write the real event logs
# tests/test_fix_loop_gate_resume.sh — pins #182: after compaction or a restart,
# fix-loop-gate.sh resumes the issue THIS worktree holds before claiming new work,
# and claims fresh work once that issue is no longer held.

PASS=0; FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)/plugins/autocoder/scripts"

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want '$2', got '$3'"; fi; }

TMP=$(mktemp -d)
trap 'git -C "$TMP/repo" worktree prune 2>/dev/null; rm -rf "$TMP"' EXIT
REPO="$TMP/repo"
mkdir -p "$REPO" && cd "$REPO" || exit 1
git init -q
git config user.email t@example.com && git config user.name T
echo base > README.md && git add README.md && git commit -q -m base
git branch -M master

export ISSUE_SOURCE=file
unset CLAUDE_CODE_SESSION_ID   # cases opt in explicitly; never inherit the runner's
# Outside the repo, so the issue files never make the worktree look dirty.
export ISSUE_DIR_PATH="$TMP/issues"
WORK_JSON="$TMP/work.json"
STATE="$(git rev-parse --absolute-git-dir)/autocoder-worker-state"

reset() {
  rm -rf "$ISSUE_DIR_PATH" "$WORK_JSON" "$STATE"
  mkdir -p "$ISSUE_DIR_PATH"/{open,working,blocked,closed}
  git checkout -q master
}
add_issue() {  # add_issue <num> <labels>
  cat > "$ISSUE_DIR_PATH/open/$(printf '%03d' "$1").md" <<MD
---
number: $1
title: Issue $1
labels: [$2]
status: open
---
Body.
MD
}
gate() { rm -f "$WORK_JSON"; AUTOCODER_WORK_JSON="$WORK_JSON" bash "$SCRIPT_DIR/fix-loop-gate.sh" 2>/dev/null; echo $?; }
plan() { jq -r "$1" "$WORK_JSON" 2>/dev/null; }
backend() { bash -c "source '$SCRIPT_DIR/issue-fns.sh' && $*" >/dev/null 2>&1; }

# ── 1. A claimed issue is recorded, then resumed instead of new work ────────
reset
add_issue 5 "P1"
assert_eq "first tick claims #5" "0" "$(gate)"
assert_eq "first tick plans #5" "5" "$(plan .issue)"
assert_eq "the claim is recorded for this worktree" "5" "$(cut -d' ' -f1 "$STATE" 2>/dev/null)"
add_issue 6 "P0"   # higher priority, arrives while #5 is in flight (e.g. across a compaction)
assert_eq "next tick still has work" "0" "$(gate)"
assert_eq "next tick resumes #5, not the new P0 #6 (no branch yet: compacted before /fix)" "5" "$(plan .issue)"
assert_eq "the resumed plan is marked resume" "true" "$(plan .resume)"
[ -f "$ISSUE_DIR_PATH/open/006.md" ] && ok "#6 was not claimed" || bad "#6 was claimed while #5 was held"

# ── 2. Once the held issue closes, the record clears and new work is claimed ─
backend issue_close 5
assert_eq "after #5 closes the tick claims new work" "0" "$(gate)"
assert_eq "...and it is #6" "6" "$(plan .issue)"
assert_eq "...not as a resume" "null" "$(plan .resume)"
assert_eq "the record now names #6" "6" "$(cut -d' ' -f1 "$STATE" 2>/dev/null)"

# ── 3. A released claim is not resumed ──────────────────────────────────────
reset
add_issue 7 "P2"
gate >/dev/null
backend issue_release 7
add_issue 8 "P0"
gate >/dev/null
assert_eq "after #7 is released the tick claims by priority, not resume" "8" "$(plan .issue)"
assert_eq "...and it is not a resume" "null" "$(plan .resume)"

# ── 4. A checked-out branch alone is NOT a claim: it cannot show who owns it now ─
reset
add_issue 9 "P2"
backend issue_claim 9            # e.g. released by us, then re-claimed by another worker
git checkout -q -b feature/issue-9
add_issue 10 "P0"
gate >/dev/null
assert_eq "a stale feature/issue-9 with no record is not resumed" "10" "$(plan .issue)"
git checkout -q master

# ── 5. Resume switches a clean tree back to the issue's branch ──────────────
reset
add_issue 11 "P2"
gate >/dev/null                  # claims and records #11
git branch -q feature/issue-11   # the branch /fix created for it
add_issue 12 "P0"
gate >/dev/null
assert_eq "resume from master picks the recorded #11" "11" "$(plan .issue)"
assert_eq "the clean tree is switched to feature/issue-11" "feature/issue-11" "$(git branch --show-current)"

# ── 6. A dirty tree on another branch: not resumed this tick, record kept ───
git checkout -q master
echo wip >> README.md            # a tracked edit; untracked files do not count as dirty
assert_eq "dirty tree: the tick idles rather than claim over held #11" "1" "$(gate)"
[ -f "$ISSUE_DIR_PATH/open/012.md" ] && ok "dirty tree: #12 was not claimed" || bad "dirty tree: #12 was claimed over held #11"
assert_eq "dirty tree: the record is kept for a later tick" "11" "$(cut -d' ' -f1 "$STATE" 2>/dev/null)"
git checkout -q -- README.md
gate >/dev/null
assert_eq "once clean, #11 resumes" "11" "$(plan .issue)"

# ── 7. Branch checked out in a sibling worktree: drop the record, no livelock ─
reset
add_issue 13 "P2"
gate >/dev/null
git branch -q feature/issue-13
git worktree add -q "$TMP/sibling" feature/issue-13
add_issue 14 "P0"
gate >/dev/null
assert_eq "branch held by a sibling worktree: the tick claims new work" "14" "$(plan .issue)"
assert_eq "...and the record now names #14" "14" "$(cut -d' ' -f1 "$STATE" 2>/dev/null)"
git worktree remove --force "$TMP/sibling"

# ── 8. Ownership: a newer claim comment than ours means someone else holds it ─
# shellcheck source=../plugins/autocoder/scripts/worker-state-fns.sh
source "$SCRIPT_DIR/worker-state-fns.sh"
# We won a race at 1000; a loser posted at 1500, inside the 120 s window. Still ours.
RACE='{"state":"OPEN","labels":[{"name":"working"}],"comments":[{"body":"🔒 claim hostA-1 1000"},{"body":"🔒 claim hostB-2 1500"}]}'
_worker_still_ours "$RACE" 1000 && ok "a race loser's later comment does not take the claim from the winner" \
  || bad "the race winner disowned its own claim"
# Released, then re-claimed by another worker ten minutes later. No longer ours.
RECLAIM='{"state":"OPEN","labels":[{"name":"working"}],"comments":[{"body":"🔒 claim hostA-1 1000"},{"body":"🔒 claim hostB-2 601000"}]}'
_worker_still_ours "$RECLAIM" 1000 && bad "an older claim was treated as ours after a re-claim" \
  || ok "a re-claim after the race window is not ours"
_worker_still_ours "$RECLAIM" 601000 && ok "the re-claimer's own record is ours" || bad "re-claimer's record rejected"
# #202 markers carry owner fields after the epoch; a re-claim in that format counts too.
RECLAIM202='{"state":"OPEN","labels":[{"name":"working"}],"comments":[{"body":"🔒 claim hostA-1 1000 start=900 wt=/src/a"},{"body":"🔒 claim hostB-2 601000 start=600 wt=/src/agents wt-2"}]}'
_worker_still_ours "$RECLAIM202" 1000 && bad "a new-format (#202) re-claim was invisible to the resume check" \
  || ok "a new-format (#202) re-claim after the race window is not ours"
_worker_still_ours "$RECLAIM202" 601000 && ok "a new-format re-claimer's own record is ours" \
  || bad "new-format re-claimer's record rejected"
_worker_still_ours '{"state":"OPEN","labels":[{"name":"working"}],"comments":[]}' "" \
  && ok "file backend (no claim comments, none recorded) is ours" || bad "file-backend record rejected"
_worker_still_ours '{"state":"CLOSED","labels":[{"name":"working"}],"comments":[]}' "" \
  && bad "a closed issue was treated as held" || ok "a closed issue is not held"

# ── 10. In-flight (#130): a /loop tick in the SAME session must not re-dispatch ─
reset
add_issue 20 "P2"
CLAUDE_CODE_SESSION_ID=sess-A gate >/dev/null          # session A claims #20
git branch -q feature/issue-20
add_issue 21 "P0"
CLAUDE_CODE_SESSION_ID=sess-A gate >/dev/null          # next tick, same session, still on master
assert_eq "same session: the plan is #20" "20" "$(plan .issue)"
assert_eq "same session: marked in_flight" "true" "$(plan .in_flight)"
assert_eq "same session: the checkout is left alone" "master" "$(git branch --show-current)"
[ -f "$ISSUE_DIR_PATH/open/021.md" ] && ok "same session: #21 was not claimed" || bad "same session: #21 was claimed mid-issue"
echo wip >> README.md
CLAUDE_CODE_SESSION_ID=sess-A gate >/dev/null
assert_eq "same session, dirty tree: still reported in_flight (not idled)" "true" "$(plan .in_flight)"
git checkout -q -- README.md

CLAUDE_CODE_SESSION_ID=sess-B gate >/dev/null          # a restart: new session
assert_eq "new session: resumes #20" "20" "$(plan .issue)"
assert_eq "new session: not in_flight, so /fix is dispatched" "false" "$(plan .in_flight)"
assert_eq "new session: switched to feature/issue-20" "feature/issue-20" "$(git branch --show-current)"
CLAUDE_CODE_SESSION_ID=sess-B gate >/dev/null
assert_eq "the resuming session now owns it: its next tick is in_flight" "true" "$(plan .in_flight)"
(unset CLAUDE_CODE_SESSION_ID; gate >/dev/null)        # shell-loop: no session
assert_eq "outside a session: never in_flight" "false" "$(plan .in_flight)"
git checkout -q master

# Shell-loop mode: a session id inherited by the wrapper must never mark in_flight.
CLAUDE_CODE_SESSION_ID=sess-B AUTOCODER_NEXT_FIX_FILE="$TMP/handoff" gate >/dev/null
assert_eq "shell-loop mode ignores an inherited session id" "false" "$(plan .in_flight)"
assert_eq "...and records none" "-" "$(cut -d' ' -f3 "$STATE" 2>/dev/null)"
# Shell-loop mode on a FRESH claim (fix-loop-gate.sh's own recording, not a resume).
reset
add_issue 30 "P1"
CLAUDE_CODE_SESSION_ID=sess-B AUTOCODER_NEXT_FIX_FILE="$TMP/handoff" gate >/dev/null
assert_eq "shell-loop fresh claim: #30 claimed" "30" "$(plan .issue)"
assert_eq "shell-loop fresh claim: no session recorded" "-" "$(cut -d' ' -f3 "$STATE" 2>/dev/null)"
CLAUDE_CODE_SESSION_ID=sess-B gate >/dev/null
assert_eq "...so a later tick with that inherited id is not in_flight" "false" "$(plan .in_flight)"
add_issue 20 "P2"; backend issue_claim 20
git branch -q -f feature/issue-20 master 2>/dev/null || true
# A two-field record written before session ids existed still resumes.
git checkout -q master
printf '20 %s\n' "$(cut -d' ' -f2 "$STATE")" > "$STATE"
CLAUDE_CODE_SESSION_ID=sess-C gate >/dev/null
assert_eq "an old two-field record resumes #20" "20" "$(plan .issue)"
assert_eq "...as a new session, not in_flight" "false" "$(plan .in_flight)"
git checkout -q master

GATE_MD="$SCRIPT_DIR/../commands/gate.md"
grep -q '"in_flight": true' "$GATE_MD" && grep -q 'Never invoke' "$GATE_MD" \
  && grep -q 'If none is running' "$GATE_MD" \
  && ok "gate.md documents the in_flight rule (no re-dispatch; a pick-up branch)" \
  || bad "gate.md does not document the in_flight rule"

# ── 9. AUTOCODER_RESUME_OWN_CLAIM=0 turns resume off ────────────────────────
reset
add_issue 15 "P2"
gate >/dev/null
add_issue 16 "P0"
rm -f "$WORK_JSON"
AUTOCODER_RESUME_OWN_CLAIM=0 AUTOCODER_WORK_JSON="$WORK_JSON" bash "$SCRIPT_DIR/fix-loop-gate.sh" >/dev/null 2>&1
assert_eq "with resume disabled the gate claims new work" "16" "$(plan .issue)"

# ── 8. A failed resume read does not claim over the held record (#362) ─────
reset
add_issue 17 "P0"
echo "999 1 -" > "$STATE"
assert_eq "hiccup: gate claims nothing" "1" "$(gate)"
assert_eq "hiccup: the record is kept" "999" "$(cut -d' ' -f1 "$STATE" 2>/dev/null)"
assert_eq "hiccup: no work plan" "" "$(plan .issue)"
[ -f "$ISSUE_DIR_PATH/open/017.md" ] && ok "hiccup: #17 left open" || bad "hiccup: #17 was claimed"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
