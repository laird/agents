#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255: never write the real event logs
# tests/test_worktree_issue.sh: worktree-issue.sh maps each swarm worktree to the
# issue its branch names and the command its worker should get after a reboot
# (#274, part of #271). Private temp repo with its own .autocoder.json
# (issueSource: file), so nothing reaches the real tracker.

set -u
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/plugins/autocoder/scripts/worktree-issue.sh"
ISSUES_PY="$ROOT/plugins/autocoder/scripts/issues-file.py"

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
has()  { if printf '%s' "$3" | grep -qF -- "$2"; then pass "$1"; else fail "$1: '$2' not in: $3"; fi; }
hasnt(){ if printf '%s' "$3" | grep -qF -- "$2"; then fail "$1: unexpected '$2' in: $3"; else pass "$1"; fi; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
T=$(cd "$T" && pwd -P)
export ISSUE_SOURCE=file
unset AUTOCODER_AGENT

mkdir -p "$T/issues"/{open,working,blocked,closed}
for n in 1 2 3 6; do
  printf -- '---\nnumber: %s\ntitle: Issue %s\npriority: P2\nlabels: [bug]\nstatus: open\n---\nBody.\n' "$n" "$n" > "$T/issues/open/$(printf %03d "$n").md"
done
fi_() { ISSUE_DIR_PATH="$T/issues" python3 "$ISSUES_PY" "$@" >/dev/null; }
fi_ claim 1; fi_ claim 6; fi_ close 3

R="$T/proj"
git init -q "$R"
printf '{"issueSource":"file","issueDir":"%s"}\n' "$T/issues" > "$R/.autocoder.json"
git -C "$R" -c user.email=t@e -c user.name=T commit -q --allow-empty -m init
git -C "$R" worktree add -q -b feature/issue-1 "$R-wt-1"            # claimed
git -C "$R" worktree add -q -b feature/issue-2 "$R-wt-2"            # open, no claim
git -C "$R" worktree add -q -b enhancement/issue-3-auto "$R-wt-3"   # closed
git -C "$R" worktree add -q -b misc "$R-wt-4"                       # names no issue
git -C "$R" worktree add -q -b feature/issue-99 "$R-wt-5"           # backend has no such issue
git -C "$R" worktree add -q -b feature/issue-2b "$T/scratch"        # not <repo>-wt-*

OUT=$(bash "$SCRIPT" --project "$R-wt-2" 2>&1); RC=$?
[ "$RC" -eq 0 ] && pass "exits 0 (run from inside a worktree)" || fail "rc=$RC: $OUT"
TAB=$'\t'
has "claimed issue → /autocoder:fix 1" "$R-wt-1${TAB}feature/issue-1${TAB}1${TAB}claimed${TAB}/autocoder:fix 1" "$OUT"
has "open unclaimed issue still resumed → /autocoder:fix 2" "$R-wt-2${TAB}feature/issue-2${TAB}2${TAB}open${TAB}/autocoder:fix 2" "$OUT"
has "closed issue → fix-loop" "$R-wt-3${TAB}enhancement/issue-3-auto${TAB}3${TAB}closed${TAB}/autocoder:fix-loop" "$OUT"
has "branch naming no issue → fix-loop" "$R-wt-4${TAB}misc${TAB}-${TAB}none${TAB}/autocoder:fix-loop" "$OUT"
has "unanswerable issue still resumed" "$R-wt-5${TAB}feature/issue-99${TAB}99${TAB}unknown${TAB}/autocoder:fix 99" "$OUT"
hasnt "scratch worktree not listed" "$T/scratch" "$OUT"
hasnt "main checkout not listed" "$R${TAB}" "$OUT"

OUT=$(AUTOCODER_AGENT=gemini bash "$SCRIPT" --project "$R")
has "non-claude agent gets bare names" "${TAB}/fix 1" "$OUT"

OUT=$(bash "$SCRIPT" --project "$R" --orphan-claims)
has "claim with no worktree on its branch is an orphan" "6${TAB}-" "$OUT"
hasnt "claim whose worktree exists is not an orphan" "1${TAB}" "$OUT"

# Shared trackers: only this host's claims on a vanished worktree are orphans.
mj() { printf '{"comments":[%s]}' "$1"; }
cm() { printf '{"body":"🔒 claim %s 1700000000000 start=1 wt=%s"}' "$1" "$2"; }
mo() { printf '%s' "$1" | AUTOCODER_HOST_ID=hostA bash "$SCRIPT" --marker-orphan; }
OUT=$(mo "$(mj "$(cm hostA-123 "$T/gone-wt")")")
[ "$OUT" = "$T/gone-wt" ] && pass "this host, worktree gone → orphan" || fail "got '$OUT'"
OUT=$(mo "$(mj "$(cm hostA-123 "$R-wt-1")")")
[ -z "$OUT" ] && pass "this host, worktree still there → not an orphan" || fail "got '$OUT'"
OUT=$(mo "$(mj "$(cm hostB-123 "$T/gone-wt")")")
[ -z "$OUT" ] && pass "another host's claim → never an orphan" || fail "got '$OUT'"
OUT=$(mo "$(mj "$(cm hostA-1 "$T/gone-wt"),$(cm hostB-2 "$T/gone-wt")")")
[ -z "$OUT" ] && pass "newest marker decides (re-claimed elsewhere)" || fail "got '$OUT'"
OUT=$(mo "$(mj '{"body":"🔒 claim hostA-5 1700000000000"}')")
[ -z "$OUT" ] && pass "marker without wt= → not an orphan" || fail "got '$OUT'"
OUT=$(mo "$(mj "$(cm hostAB-5 "$T/gone-wt")")")
[ -z "$OUT" ] && pass "host name must match exactly" || fail "got '$OUT'"

OUT=$(mo "$(mj "$(cm hostB-1 "$T/live-elsewhere"),$(cm hostA-2 "$T/gone-wt")")")
[ -z "$OUT" ] && pass "race: earlier winner on another host, later loser here → not an orphan" || fail "got '$OUT'"
OUT=$(mo "$(mj "$(cm hostB-1 "$T/x"),{\"body\":\"🔓 **Releasing claim**\"},$(cm hostA-2 "$T/gone-wt")")")
[ "$OUT" = "$T/gone-wt" ] && pass "release then re-claim here: only claims since the 🔓 count" || fail "got '$OUT'"
OUT=$(mo "$(mj '{"body":"🔒 claim my-custom-id 1700000000000 wt=/nonexistent"}')")
[ -z "$OUT" ] && pass "AUTOCODER_WORKER_ID-style id is never this host's" || fail "got '$OUT'"

OUT=$(bash "$SCRIPT" --project /nonexistent 2>&1); RC=$?
[ "$RC" -eq 1 ] && pass "outside a checkout exits 1" || fail "rc=$RC"
OUT=$(bash "$SCRIPT" --bogus 2>&1); RC=$?
[ "$RC" -eq 1 ] && pass "unknown argument exits 1" || fail "rc=$RC"

echo ""
echo "$PASS passed / $FAIL failed / $((PASS + FAIL)) total"
[ "$FAIL" -eq 0 ]
