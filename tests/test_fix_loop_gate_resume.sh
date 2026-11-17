#!/bin/bash
# tests/test_fix_loop_gate_resume.sh — pins #182: after compaction or a restart,
# fix-loop-gate.sh resumes the issue THIS worktree holds before claiming new work,
# and claims fresh work once that issue is no longer held.

PASS=0; FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)/plugins/autocoder/scripts"

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want '$2', got '$3'"; fi; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
REPO="$TMP/repo"
mkdir -p "$REPO" && cd "$REPO" || exit 1
git init -q
git config user.email t@example.com && git config user.name T
echo base > README.md && git add README.md && git commit -q -m base
git branch -M master

export ISSUE_SOURCE=file
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
assert_eq "the claim is recorded for this worktree" "5" "$(cat "$STATE" 2>/dev/null)"
add_issue 6 "P0"   # higher priority, arrives while #5 is in flight (e.g. across a compaction)
assert_eq "next tick still has work" "0" "$(gate)"
assert_eq "next tick resumes #5, not the new P0 #6" "5" "$(plan .issue)"
assert_eq "the resumed plan is marked resume" "true" "$(plan .resume)"
[ -f "$ISSUE_DIR_PATH/open/006.md" ] && ok "#6 was not claimed" || bad "#6 was claimed while #5 was held"

# ── 2. Once the held issue closes, the record clears and new work is claimed ─
backend issue_close 5
assert_eq "after #5 closes the tick claims new work" "0" "$(gate)"
assert_eq "...and it is #6" "6" "$(plan .issue)"
assert_eq "...not as a resume" "null" "$(plan .resume)"
assert_eq "the record now names #6" "6" "$(cat "$STATE" 2>/dev/null)"

# ── 3. A released claim is not resumed ──────────────────────────────────────
reset
add_issue 7 "P2"
gate >/dev/null
backend issue_release 7
add_issue 8 "P0"
gate >/dev/null
assert_eq "after #7 is released the tick claims by priority, not resume" "8" "$(plan .issue)"
assert_eq "...and it is not a resume" "null" "$(plan .resume)"

# ── 4. No record, but this worktree has feature/issue-N checked out ─────────
reset
add_issue 9 "P2"
backend issue_claim 9            # claimed earlier, e.g. by /fix 9 before the record existed
git checkout -q -b feature/issue-9
add_issue 10 "P0"
gate >/dev/null
assert_eq "a checked-out feature/issue-9 holding 'working' is resumed" "9" "$(plan .issue)"
assert_eq "...and recorded" "9" "$(cat "$STATE" 2>/dev/null)"

# ── 5. Resume switches a clean tree back to the issue's branch ──────────────
git checkout -q master
gate >/dev/null
assert_eq "resume from master still picks #9" "9" "$(plan .issue)"
assert_eq "the clean tree is switched to feature/issue-9" "feature/issue-9" "$(git branch --show-current)"

# ── 6. The switch is skipped on a dirty tree ─────────────────────────────────
git checkout -q master
echo wip > wip.txt
gate >/dev/null
assert_eq "a dirty tree stays on its branch" "master" "$(git branch --show-current)"
rm -f wip.txt

# ── 7. AUTOCODER_RESUME_OWN_CLAIM=0 turns resume off ────────────────────────
rm -f "$WORK_JSON"
AUTOCODER_RESUME_OWN_CLAIM=0 AUTOCODER_WORK_JSON="$WORK_JSON" bash "$SCRIPT_DIR/fix-loop-gate.sh" >/dev/null 2>&1
assert_eq "with resume disabled the gate claims new work" "10" "$(plan .issue)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
