#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255: never write the real event logs
# tests/test_fix_loop_gate_branch_lock.sh — fix-loop-gate.sh must not claim an
# issue whose feature/issue-N branch is live on origin (#210).
#
# /fix treats a pushed branch as the strongest lock, because it survives a dropped
# `working` label. The gate filtered on labels alone, so a second worker claimed
# #140 while its owner was resuming it, and #153 while its owner was mid-fix.

PASS=0; FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)/plugins/autocoder/scripts"

assert_eq() {
  if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS + 1))
  else echo "FAIL: $1 — want '$2', got '$3'"; FAIL=$((FAIL + 1)); fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
g() { git -c user.email=t@example.com -c user.name=T "$@"; }

git init -q --bare -b master "$TMP/origin.git"
g clone -q "$TMP/origin.git" "$TMP/repo" 2>/dev/null
cd "$TMP/repo" || exit 1
echo base > f; g add f; g commit -qm base; g push -q origin HEAD:master

export ISSUE_SOURCE=file
export ISSUE_DIR_PATH="$TMP/issues"
WORK_JSON="$TMP/work.json"

reset_issues() {
  rm -rf "$ISSUE_DIR_PATH" "$WORK_JSON"
  mkdir -p "$ISSUE_DIR_PATH"/{open,working,blocked,closed}
}
add_issue() {  # add_issue <num> <labels>
  cat > "$ISSUE_DIR_PATH/open/$(printf '%03d' "$1").md" <<EOF
---
number: $1
title: Issue $1
labels: [$2]
status: open
---
Body.
EOF
}
run_gate() { AUTOCODER_WORK_JSON="$WORK_JSON" bash "$SCRIPT_DIR/fix-loop-gate.sh" 2>/dev/null; echo $?; }
plan() { cat "$WORK_JSON" 2>/dev/null; }
push_branch() { g push -q origin "HEAD:refs/heads/$1"; }
drop_branch() { g push -q origin ":refs/heads/$1"; }

# ── 1. Top issue has a live branch and no `working` label → skipped ─────────
reset_issues
add_issue 1 "bug, P0"; add_issue 2 "bug, P1"
push_branch feature/issue-1
assert_eq "live branch: gate still finds work" 0 "$(run_gate)"
assert_eq "live branch: the branch-locked P0 is skipped for the P1" \
  '{"phase":"fix","issue":2,"priority":"P1"}' "$(plan)"
[ -f "$ISSUE_DIR_PATH/open/001.md" ] && assert_eq "live branch: #1 left unclaimed" ok ok \
  || assert_eq "live branch: #1 left unclaimed" ok "claimed"

# ── 2. Every candidate branch-locked → idle, nothing claimed ────────────────
reset_issues
add_issue 1 "bug, P0"
assert_eq "all branch-locked: idle exit" 1 "$(run_gate)"
assert_eq "all branch-locked: #1 still open" yes "$([ -f "$ISSUE_DIR_PATH/open/001.md" ] && echo yes)"

# ── 3. Other prefixes count too (fix/, enhancement/…-auto) ──────────────────
drop_branch feature/issue-1
push_branch enhancement/issue-1-auto
reset_issues
add_issue 1 "enhancement, P2"
assert_eq "enhancement/issue-N-auto also locks (nothing else to claim → idle)" 1 "$(run_gate)"
drop_branch enhancement/issue-1-auto

# ── 4. escalated/review-N is deliberately NOT a lock (fix.md) ───────────────
push_branch escalated/review-1
reset_issues
add_issue 1 "bug, P0"
run_gate >/dev/null
assert_eq "escalated/review-N does not lock" \
  '{"phase":"fix","issue":1,"priority":"P0"}' "$(plan)"
drop_branch escalated/review-1

# ── 5. origin unreachable → fail open, claim as before ──────────────────────
push_branch feature/issue-1
g remote set-url origin "$TMP/nowhere.git"
reset_issues
add_issue 1 "bug, P0"
run_gate >/dev/null
assert_eq "unreachable origin fails open" \
  '{"phase":"fix","issue":1,"priority":"P0"}' "$(plan)"
g remote set-url origin "$TMP/origin.git"

# ── 6. Unprioritized issues are still triaged even with a branch ────────────
reset_issues
add_issue 1 "bug"
run_gate >/dev/null
assert_eq "triage ignores branch locks" '{"phase":"triage","issues":[1]}' "$(plan)"

echo ""
echo "Tests: $FAIL failed, $PASS passed, $((PASS + FAIL)) total"
[ "$FAIL" -eq 0 ]
