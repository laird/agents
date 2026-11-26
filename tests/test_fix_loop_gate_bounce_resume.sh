#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255: never write the real event logs
# tests/test_fix_loop_gate_bounce_resume.sh — pins #208: when a merge job bounces
# an issue back to the worktree that launched it (#207: `working` plus an
# `autocoder-bounce ... worktree=<path>` comment), that worktree's gate resumes it
# before claiming anything new. Another worktree's bounce, a bounce someone has
# since restarted, and an issue back under `merging` are not resumed.

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
ME=$(pwd -P)

export ISSUE_SOURCE=file
export ISSUE_DIR_PATH="$TMP/issues"   # outside the repo: never makes the tree dirty
WORK_JSON="$TMP/work.json"
STATE="$(git rev-parse --absolute-git-dir)/autocoder-worker-state"

backend() { bash -c "source '$SCRIPT_DIR/issue-fns.sh' && $*"; }
reset() {
  rm -rf "$ISSUE_DIR_PATH" "$WORK_JSON" "$STATE"
  mkdir -p "$ISSUE_DIR_PATH"/{open,working,blocked,closed}
  git checkout -q master
  git branch -D feature/issue-5 >/dev/null 2>&1 || true
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
# bounced <num> <owner-worktree>: the state #207's merge job leaves behind.
bounced() {
  add_issue "$1" "P2"
  backend issue_claim "$1" >/dev/null 2>&1
  backend issue_comment "$1" --body "'🤖 **Automated Fix Started**

**Branch**: \`feature/issue-$1\`'" >/dev/null 2>&1
  git branch -q "feature/issue-$1" master
  backend issue_comment "$1" --body "'🔁 **Auto-merge to \`master\` hit a merge conflict; returned to the owning worker.**

<!-- autocoder-bounce kind=conflict worktree=$2 sha=abc123 sig=0123abcd -->'" >/dev/null 2>&1
}
gate() { rm -f "$WORK_JSON"; AUTOCODER_WORK_JSON="$WORK_JSON" bash "$SCRIPT_DIR/fix-loop-gate.sh" 2>/dev/null; echo $?; }
plan() { jq -r "$1" "$WORK_JSON" 2>/dev/null; }

# ── 0. Fixture sanity: a claimed file-backend issue reads as `working` ──────
reset
bounced 5 "$ME"
backend issue_get 5 | jq -e '[.labels[].name] | index("working") != null' >/dev/null \
  && ok "fixture: bounced issue carries working" || bad "fixture: no working label on a claimed issue"

# ── 1. This worktree's bounce is resumed before new, higher-priority work ───
add_issue 6 "P0"
assert_eq "gate has work" "0" "$(gate)"
assert_eq "it resumes the bounced #5, not the new P0 #6" "5" "$(plan .issue)"
assert_eq "the plan is a resume" "true" "$(plan .resume)"
assert_eq "the worktree is switched to feature/issue-5" "feature/issue-5" "$(git branch --show-current)"
assert_eq "the claim is re-recorded for this worktree" "5" "$(cut -d' ' -f1 "$STATE" 2>/dev/null)"
[ -f "$ISSUE_DIR_PATH/open/006.md" ] && ok "#6 left unclaimed" || bad "#6 claimed over the bounce"
assert_eq "bounce-resume.sh check names the kind" "conflict" "$(bash "$SCRIPT_DIR/bounce-resume.sh" check 5 2>/dev/null)"

# ── 2. Another worktree's bounce is not ours ───────────────────────────────
reset
bounced 5 "/elsewhere/agents-wt-9"
add_issue 6 "P0"
gate >/dev/null
assert_eq "another worktree's bounce: new work is claimed" "6" "$(plan .issue)"
assert_eq "...and not as a resume" "null" "$(plan .resume)"

# ── 3. A bounce someone restarted since is theirs, not ours ────────────────
reset
bounced 5 "$ME"
backend issue_comment 5 --body "'🤖 **Automated Fix Started**

**Branch**: \`feature/issue-5\` (another worker took it over)'" >/dev/null 2>&1
add_issue 6 "P0"
gate >/dev/null
assert_eq "superseded bounce: new work is claimed" "6" "$(plan .issue)"

# ── 4. Relaunched (merging) is not a bounce to resume ───────────────────────
reset
bounced 5 "$ME"
backend issue_update 5 --add-label merging >/dev/null 2>&1
add_issue 6 "P0"
gate >/dev/null
assert_eq "merging: new work is claimed" "6" "$(plan .issue)"

# ── 5. The newest marker wins: a later bounce to someone else is not ours ──
reset
bounced 5 "$ME"
backend issue_comment 5 --body "'<!-- autocoder-bounce kind=gate worktree=/elsewhere/wt-3 sha=def sig=4567 -->'" >/dev/null 2>&1
bash "$SCRIPT_DIR/bounce-resume.sh" check 5 >/dev/null 2>&1; RC=$?
assert_eq "newest bounce names another worktree: check says no" "1" "$RC"

# ── 5b. No local feature/issue-N branch: not ours to find (cheap prefilter) ─
reset
bounced 5 "$ME"
git branch -D feature/issue-5 >/dev/null 2>&1
bash "$SCRIPT_DIR/bounce-resume.sh" find >/dev/null 2>&1; RC=$?
assert_eq "bounce without a local branch: find exits 1" "1" "$RC"

# ── 5c. A record kept through a backend hiccup is never overwritten ─────────
reset
bounced 5 "$ME"
echo "999 " > "$STATE"     # issue_get 999 fails: worker_resume_plan keeps the record
gate >/dev/null
assert_eq "kept record survives: not replaced by the bounce" "999" "$(cut -d' ' -f1 "$STATE" 2>/dev/null)"
[ "$(plan .issue)" = 5 ] && bad "bounce resumed over a kept record" || ok "bounce not resumed over a kept record"

# ── 6. No bounces at all: find says none ───────────────────────────────────
reset
add_issue 7 "P1"
bash "$SCRIPT_DIR/bounce-resume.sh" find >/dev/null 2>&1; RC=$?
assert_eq "no bounces: find exits 1" "1" "$RC"

# ── 7. A comment thread past ARG_MAX still resolves the bounce (#432) ─────
# One comment bigger than MAX_ARG_STRLEN (32 pages). Passing the issue as
# ISSUE_JSON made python die with "Argument list too long", and the gate
# claimed new work over the bounce. Written straight into the issue file:
# issue_comment's --body is itself one argv, and would hit the same limit.
reset
bounced 5 "$ME"
issue_bytes=$(( $(getconf PAGE_SIZE) * 32 + 4096 ))
python3 - "$ISSUE_DIR_PATH/working/005.md" "$issue_bytes" <<'PY'
import sys
path, n = sys.argv[1], int(sys.argv[2])
with open(path, "a", encoding="utf-8") as f:
    f.write("\n> **t** " + ("y" * n) + "\n")
PY
sz=$(wc -c < "$ISSUE_DIR_PATH/working/005.md")
# A missing or unpadded file would still resolve as a normal bounce, and the
# ARG_MAX assertions below would pass without ever exercising the limit.
[ "$sz" -gt "$issue_bytes" ] && ok "large thread: issue file exceeds ARG_MAX ($sz bytes)" \
  || bad "large thread: issue file was not padded ($sz bytes)"
ERR="$TMP/bounce-large.err"
OUT=$(bash "$SCRIPT_DIR/bounce-resume.sh" check 5 2>"$ERR"); RC=$?
assert_eq "large thread: check exits 0" "0" "$RC"
assert_eq "large thread: check names the kind" "conflict" "$OUT"
if grep -q "Argument list too long" "$ERR"; then
  bad "large thread: check still hit argument list too long"
else
  ok "large thread: check did not hit argument list too long"
fi
OUT=$(bash "$SCRIPT_DIR/bounce-resume.sh" find 2>"$ERR"); RC=$?
assert_eq "large thread: find exits 0" "0" "$RC"
assert_eq "large thread: find names #5" "5 conflict" "$OUT"
if grep -q "Argument list too long" "$ERR"; then
  bad "large thread: find still hit argument list too long"
else
  ok "large thread: find did not hit argument list too long"
fi

echo ""
echo "Tests: $FAIL failed, $PASS passed, $((PASS + FAIL)) total"
[ "$FAIL" -eq 0 ]
