#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255: never write the real event logs
# tests/test_dispatch_issue.sh — a manager's dispatch as an override of a worker's own
# pick (dispatch-fns.sh, dispatch-issue.sh, fix-loop-gate.sh step 0b). File backend in a
# private temp repo with two linked worktrees: the target worker and a sibling.
PASS=0; FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)/plugins/autocoder/scripts"
DISPATCH="$SCRIPT_DIR/dispatch-issue.sh"
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want '$2', got '$3'"; fi; }
assert_has() { if printf '%s' "$3" | grep -qF -- "$2"; then ok "$1"; else bad "$1 — '$2' not in: $3"; fi; }

TMP=$(mktemp -d)
trap 'git -C "$TMP/proj" worktree prune 2>/dev/null; rm -rf "$TMP"' EXIT
export ISSUE_SOURCE=file
export ISSUE_DIR_PATH="$TMP/issues"
unset CLAUDE_CODE_SESSION_ID AUTOCODER_NEXT_FIX_FILE
export AUTOCODER_MANAGER=mgr
R="$TMP/proj"
git init -q -b master "$R"
git -C "$R" config user.email t@example.com && git -C "$R" config user.name T
printf '{"issueSource":"file","issueDir":"%s"}\n' "$ISSUE_DIR_PATH" > "$R/.autocoder.json"
git -C "$R" add .autocoder.json && git -C "$R" commit -q -m init
git -C "$R" worktree add -q "$R-wt-1" -b master-wt-1
git -C "$R" worktree add -q "$R-wt-2" -b master-wt-2
DIR="$R/.autocoder/dispatch"

reset() {
  rm -rf "$ISSUE_DIR_PATH" "$DIR" "$TMP"/work-*.json
  mkdir -p "$ISSUE_DIR_PATH"/{open,working,blocked,closed}
  rm -f "$(git -C "$R-wt-1" rev-parse --absolute-git-dir)/autocoder-worker-state" "$(git -C "$R-wt-2" rev-parse --absolute-git-dir)/autocoder-worker-state"
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
gate() {  # gate <worktree> → exit code; plan in $TMP/work-<wt>.json
  local wt="$1"
  rm -f "$TMP/work-$wt.json"
  (cd "$R-wt-$wt" && AUTOCODER_WORK_JSON="$TMP/work-$wt.json" bash "$SCRIPT_DIR/fix-loop-gate.sh" 2>"$TMP/gate-$wt.err"); echo $?
}
plan() { jq -r "$2" "$TMP/work-$1.json" 2>/dev/null; }
backend() { bash -c "source '$SCRIPT_DIR/issue-fns.sh' && $*" >/dev/null 2>&1; }

# ── 1. The dispatch beats the priority pick on the target and keeps the sibling off ──
reset
add_issue 1 "P0"
add_issue 2 "P3"
OUT=$(cd "$R" && bash "$DISPATCH" 2 --worktree "$R-wt-1" --note "needs your context" 2>&1); RC=$?
assert_eq "dispatch exits 0" 0 "$RC"
assert_has "dispatch says where it went" "dispatched #2 to proj-wt-1" "$OUT"
[ -f "$DIR/proj-wt-1" ] && ok "dispatch file written under the main worktree" || bad "no dispatch file at $DIR/proj-wt-1"
assert_eq "the sibling's tick skips the dispatched issue and takes the P0" 0 "$(gate 2)"
assert_eq "...sibling claimed #1" 1 "$(plan 2 .issue)"
assert_eq "the target's tick takes the dispatched P3 ahead of its own pick" 0 "$(gate 1)"
assert_eq "...target claimed #2" 2 "$(plan 1 .issue)"
assert_eq "...marked dispatched" true "$(plan 1 .dispatched)"
assert_eq "...priority from the labels" P3 "$(plan 1 .priority)"
[ -f "$DIR/proj-wt-1" ] && bad "dispatch file not removed after the take" || ok "dispatch file removed after the take"
assert_has "the gate said whose dispatch it took" "taking dispatched #2 (by mgr@" "$(cat "$TMP/gate-1.err")"
[ -f "$ISSUE_DIR_PATH/working/002.md" ] && ok "#2 is working" || bad "#2 not claimed"
assert_eq "the claim is recorded for the worktree" "2" "$(cut -d' ' -f1 "$(git -C "$R-wt-1" rev-parse --absolute-git-dir)/autocoder-worker-state")"

# ── 2. A dispatch beats triage, and the next tick triages as before ────────────────
reset
add_issue 3 ""        # unprioritized: a triage tick
add_issue 4 "P2"
(cd "$R" && bash "$DISPATCH" 4 --worktree proj-wt-1 >/dev/null 2>&1)
assert_eq "dispatch tick exits 0 although triage is due" 0 "$(gate 1)"
assert_eq "...and it is the dispatched issue, not triage" fix "$(plan 1 .phase)"
assert_eq "...#4" 4 "$(plan 1 .issue)"
backend issue_close 4
assert_eq "the next tick triages" 0 "$(gate 1)"
assert_eq "...phase triage" triage "$(plan 1 .phase)"

# ── 3. A dispatch beats an otherwise idle tick; a stale one is dropped ────────────
reset
add_issue 5 "P1"
(cd "$R" && bash "$DISPATCH" 5 --worktree proj-wt-1 >/dev/null 2>&1)
backend issue_claim 5   # someone else took it meanwhile: the dispatch is dropped, nothing else is claimable
assert_eq "a dispatched issue now working on someone else's branch: tick idles" 1 "$(gate 1)"
assert_has "...and says why" "someone else's claim" "$(cat "$TMP/gate-1.err")"
[ -f "$DIR/proj-wt-1" ] && bad "dropped dispatch still on disk" || ok "dropped dispatch removed"
reset
add_issue 6 "P1"
(cd "$R" && bash "$DISPATCH" 6 --worktree proj-wt-1 >/dev/null 2>&1)
assert_eq "a stale dispatch is dropped and the tick picks by priority" 0 "$(AUTOCODER_DISPATCH_TTL_S=0 bash -c "sleep 1; cd '$R-wt-1' && AUTOCODER_WORK_JSON='$TMP/work-1.json' bash '$SCRIPT_DIR/fix-loop-gate.sh' 2>'$TMP/gate-1.err'; echo \$?")"
assert_has "...saying so" "stale or unreadable" "$(cat "$TMP/gate-1.err")"
assert_eq "...nothing dispatched in the plan" null "$(plan 1 .dispatched)"
reset
add_issue 7 "P1"
(cd "$R" && bash "$DISPATCH" 7 --worktree proj-wt-2 >/dev/null 2>&1)
assert_eq "the sibling keeps off a fresh dispatch even when nothing else is claimable" 1 "$(gate 1)"
assert_eq "...but takes it once the dispatch is stale" 0 "$(AUTOCODER_DISPATCH_TTL_S=0 bash -c "sleep 1; cd '$R-wt-1' && AUTOCODER_WORK_JSON='$TMP/work-1.json' bash '$SCRIPT_DIR/fix-loop-gate.sh' 2>/dev/null; echo \$?")"

# ── 4. A dispatch of the worktree's own held claim is a resume (the reboot path) ──
reset
add_issue 8 "P2"
(cd "$R-wt-1" && git checkout -q -b feature/issue-8 && git commit -q --allow-empty -m "work" && git checkout -q master-wt-1)
backend issue_claim 8   # claimed earlier by this worktree, say by a typed /fix that left no record
OUT=$(cd "$R" && bash "$DISPATCH" 8 --worktree proj-wt-1 2>&1); RC=$?
assert_eq "a working issue whose branch the target holds is refused without --force (the target is not on that branch)" 1 "$RC"
(cd "$R-wt-1" && git checkout -q feature/issue-8)
OUT=$(cd "$R" && bash "$DISPATCH" 8 --worktree proj-wt-1 2>&1); RC=$?
assert_eq "...and accepted once the target is on its branch" 0 "$RC"
assert_eq "the target's tick resumes it" 0 "$(gate 1)"
assert_eq "...as a resume" true "$(plan 1 .resume)"
assert_eq "...marked dispatched" true "$(plan 1 .dispatched)"
assert_eq "...on #8" 8 "$(plan 1 .issue)"
(cd "$R-wt-1" && git checkout -q master-wt-1)

# ── 5. The command's own refusals, list and clear ────────────────────────────────
reset
add_issue 9 "P2, needs-design"
add_issue 10 "P2"
OUT=$(cd "$R" && bash "$DISPATCH" 9 --worktree proj-wt-1 2>&1); RC=$?
assert_eq "a blocked issue is refused" 1 "$RC"
assert_has "...naming the label" "needs-design" "$OUT"
OUT=$(cd "$R" && bash "$DISPATCH" 10 --worktree nowhere-wt-9 2>&1); RC=$?
assert_eq "an unknown worktree is refused" 1 "$RC"
OUT=$(cd "$R" && bash "$DISPATCH" 10 --worktree nowhere-wt-9 --force 2>&1); RC=$?
assert_eq "...unless forced" 0 "$RC"
OUT=$(cd "$R" && bash "$DISPATCH" 10 --worktree proj-wt-1 2>&1)
OUT=$(cd "$R" && bash "$DISPATCH" --list 2>&1)
assert_has "list shows the fresh dispatch" "proj-wt-1	fresh	10" "$OUT"
OUT=$(cd "$R" && bash "$DISPATCH" --clear proj-wt-1 2>&1)
assert_has "clear says what it cleared" "cleared the dispatch for proj-wt-1 (#10)" "$OUT"
OUT=$(cd "$R" && bash "$DISPATCH" 2>&1); RC=$?
assert_eq "no issue and no mode is a usage error" 2 "$RC"
backend issue_close 10
OUT=$(cd "$R" && bash "$DISPATCH" 10 --worktree proj-wt-1 2>&1); RC=$?
assert_eq "a closed issue is refused" 1 "$RC"
assert_has "...saying so" "not open" "$OUT"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
