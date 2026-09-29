#!/bin/bash
# tests/test_merge_retry_regate.sh — pins that merge-to-integration.sh never
# pushes a tree its --test-cmd has not run on.
#
# THE BUG: when the push was rejected because a sibling landed during the gate,
# the retry loop merged the new integration tip in and pushed again WITHOUT
# re-running --test-cmd. The pushed tree (this fix + the sibling) had never been
# tested. In athena2 two branches each lowered the same lint-baseline counter
# by one; the re-sync merged cleanly into a counter lowered once, and master
# went red for every gate after it (athena2 #3389, #3391).
#
# THIS TEST drives the real script against a real bare origin. The --test-cmd
# itself lands a sibling commit on origin during its FIRST run, so the first
# push is guaranteed to be rejected and the retry path is guaranteed to run.
#   Case 1: the sibling breaks the combined tree. The script must re-run the
#           tests, see the failure, exit 2, and leave origin without the fix.
#   Case 2 (control): the sibling is harmless. The script must re-run the
#           tests, pass, push, and land both commits.
# Break proof: delete the re-sync re-test block and case 1 exits 0 with the
# fix on origin.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/plugins/autocoder/scripts/merge-to-integration.sh"

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

export ISSUE_SOURCE=file

TMP=$(mktemp -d)
cleanup() {
  rm -rf "$TMP" /tmp/autocoder-merge-worktree-19201 /tmp/autocoder-merge-worktree-19202
}
trap cleanup EXIT

# setup <dir> <sibling-file>: bare origin, a worker with a feature branch, and a
# sibling clone holding one unpushed commit on master.
setup() {
  local d="$1" sibling_file="$2"
  git init --bare -q "$d/origin.git"
  git init -q "$d/worker"
  (
    cd "$d/worker" || exit 1
    git config user.email t@example.com; git config user.name T
    git remote add origin "$d/origin.git"
    echo base > README.md; git add README.md; git commit -q -m base
    git branch -M master; git push -q origin master
    git checkout -q -b feature/issue-X
    echo fix > fix.txt; git add fix.txt; git commit -q -m "fix X"
  )
  git clone -q "$d/origin.git" "$d/sibling"
  (
    cd "$d/sibling" || exit 1
    git config user.email s@example.com; git config user.name S
    echo sibling > "$sibling_file"; git add "$sibling_file"; git commit -q -m "sibling lands during the gate"
  )
}

# The test command: count runs; on the first run, land the sibling on origin so
# the script's push is rejected; fail whenever the tree contains breaks.txt.
test_cmd() {
  local d="$1"
  echo "n=\$(( \$(cat $d/count 2>/dev/null || echo 0) + 1 )); echo \$n > $d/count; \
if [ \$n = 1 ]; then git -C $d/sibling push -q origin master; fi; \
! test -f breaks.txt"
}

# ── Case 1: the sibling breaks the combined tree ────────────────────────────
D1="$TMP/case1"; mkdir -p "$D1"
setup "$D1" breaks.txt
( cd "$D1/worker" && bash "$SCRIPT" --feature feature/issue-X --issue 19201 \
    --integration master --test-cmd "$(test_cmd "$D1")" ) > "$D1/log" 2>&1
RC=$?
[ "$RC" -eq 2 ] && ok "case 1: exit 2 when the re-synced tree fails its tests" \
  || bad "case 1: expected exit 2, got $RC — log:
$(tail -20 "$D1/log")"
[ "$(cat "$D1/count" 2>/dev/null)" = "2" ] && ok "case 1: --test-cmd ran twice (initial + after re-sync)" \
  || bad "case 1: --test-cmd ran $(cat "$D1/count" 2>/dev/null || echo 0) time(s), want 2"
git -C "$D1/worker" fetch -q origin master
if git -C "$D1/worker" cat-file -e origin/master:fix.txt 2>/dev/null; then
  bad "case 1: origin/master contains the fix — an untested combined tree was pushed"
else
  ok "case 1: origin/master does not contain the fix"
fi
git -C "$D1/worker" cat-file -e origin/master:breaks.txt 2>/dev/null \
  && ok "case 1: the sibling's commit is intact on origin/master" \
  || bad "case 1: the sibling's commit is missing from origin/master"

# ── Case 2 (control): the sibling is harmless ───────────────────────────────
D2="$TMP/case2"; mkdir -p "$D2"
setup "$D2" harmless.txt
( cd "$D2/worker" && bash "$SCRIPT" --feature feature/issue-X --issue 19202 \
    --integration master --test-cmd "$(test_cmd "$D2")" ) > "$D2/log" 2>&1
RC=$?
[ "$RC" -eq 0 ] && ok "case 2: exit 0 when the re-synced tree passes" \
  || bad "case 2: expected exit 0, got $RC — log:
$(tail -20 "$D2/log")"
[ "$(cat "$D2/count" 2>/dev/null)" = "2" ] && ok "case 2: --test-cmd ran twice (initial + after re-sync)" \
  || bad "case 2: --test-cmd ran $(cat "$D2/count" 2>/dev/null || echo 0) time(s), want 2"
git -C "$D2/worker" fetch -q origin master
git -C "$D2/worker" cat-file -e origin/master:fix.txt 2>/dev/null \
  && ok "case 2: origin/master contains the fix" || bad "case 2: origin/master is missing the fix"
git -C "$D2/worker" cat-file -e origin/master:harmless.txt 2>/dev/null \
  && ok "case 2: origin/master still contains the sibling's commit" || bad "case 2: the sibling's commit was lost"

# ── api-push.py never force-updates the target ref ──────────────────────────
python3 - "$ROOT/plugins/autocoder/scripts/api-push.py" <<'PY' && ok "api-push: ref update is fast-forward only" || bad "api-push: ref update may force (drops sibling commits)"
import sys
src = open(sys.argv[1]).read()
sys.exit(1 if '"force": True' in src or '"force": False' not in src else 0)
PY

TOTAL=$((PASS + FAIL))
echo "$PASS passed / $FAIL failed / $TOTAL total"
[ "$FAIL" -eq 0 ]
