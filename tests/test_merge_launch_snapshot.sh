#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255: never write the real event logs
# tests/test_merge_launch_snapshot.sh — pins #212: the detached merge job runs a
# frozen snapshot of the scripts, so editing (or a branch switch rewriting) the
# worker's own copy mid-run cannot corrupt the job.
#
# THE BUG: merge-launch.sh ran merge-to-integration.sh by its path inside the
# worker's checkout. Bash reads a running script incrementally; the worker moves on
# to its next branch and edits files while the job gates for 8-30 minutes, so an
# in-place change resumed the job at a byte offset into the new text ("line 550:
# hip.: command not found") and sent it down a wrong exit path.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap 'git -C "$TMP/worker" worktree prune 2>/dev/null; rm -rf "$TMP"' EXIT
export AUTOCODER_TMP="$TMP/tmp"; mkdir -p "$AUTOCODER_TMP"
export AUTOCODER_GATE_CACHE_DIR="$TMP/gate-cache"
export ISSUE_SOURCE=file   # issue-fns.sh needs a backend; this fixture touches no issues

# The worker's "checkout" of the scripts: a copy we are free to vandalise.
SCRIPTS="$TMP/scripts"
mkdir -p "$SCRIPTS"
find "$ROOT/plugins/autocoder/scripts" -maxdepth 1 -type f -exec cp -p {} "$SCRIPTS"/ \;

git init --bare -q "$TMP/origin.git"
git init -q "$TMP/worker"
cd "$TMP/worker" || exit 1
git config user.email t@example.com && git config user.name T
git remote add origin "$TMP/origin.git"
echo base > README.md && git add README.md && git commit -q -m base
git branch -M master && git push -q origin master
git checkout -q -b feature/issue-21
echo fix > fix.txt && git add fix.txt && git commit -q -m "fix #21"
FIX_SHA=$(git rev-parse HEAD)
git push -q origin feature/issue-21

STATE_GLOB="$AUTOCODER_TMP/autocoder-merge-*-21"
# A gate slow enough that the vandalism below lands while the job is mid-run.
bash "$SCRIPTS/merge-launch.sh" --feature feature/issue-21 --issue 21 \
  --integration master --test-cmd "sleep 4 && test -f fix.txt" >/dev/null 2>&1 \
  && ok "merge-launch.sh launched" || bad "merge-launch.sh failed to launch"

RUN=$(ls $STATE_GLOB.run.sh 2>/dev/null | head -1)
SNAP=$(ls -d $STATE_GLOB.scripts.* 2>/dev/null | head -1)
[ -n "$SNAP" ] && [ -x "$SNAP/merge-to-integration.sh" ] && ok "a script snapshot exists for the job" \
  || bad "no script snapshot was made"
[ "$(stat -c %a "$SNAP" 2>/dev/null)" = "700" ] && ok "the snapshot dir is private (0700)" \
  || bad "snapshot dir mode is $(stat -c %a "$SNAP" 2>/dev/null)"
grep -q -- "$SNAP/merge-to-integration.sh" "$RUN" 2>/dev/null && ok "the job runs the snapshot, not the live copy" \
  || bad "run.sh does not point at the snapshot: $(grep -o '[^ ]*merge-to-integration.sh' "$RUN" 2>/dev/null)"

# Mid-run, rewrite the live script IN PLACE (same inode, as an editor does). Every
# line is an exit, so a job reading this file resumes into "exit 97" at any offset.
sleep 1
yes 'exit 97' | head -n 5000 > "$SCRIPTS/merge-to-integration.sh"
printf '#!/bin/bash\nexit 97\n' > "$SCRIPTS/issue-fns.sh"

EXIT_FILE=""
for _ in $(seq 1 120); do
  EXIT_FILE=$(ls $STATE_GLOB.exit 2>/dev/null | head -1)
  [ -n "$EXIT_FILE" ] && break
  sleep 1
done
[ -n "$EXIT_FILE" ] || bad "the job did not finish within 120s"
RC=$(cat "$EXIT_FILE" 2>/dev/null)
[ "$RC" = "0" ] && ok "the job completed normally (exit 0) despite the mid-run rewrite" \
  || bad "the job exited ${RC:-?}: $(tail -5 $STATE_GLOB.log 2>/dev/null)"
git fetch -q origin
git merge-base --is-ancestor "$FIX_SHA" origin/master && ok "the fix landed on master" \
  || bad "the fix did not land on master"
sleep 1
[ ! -e "$SNAP" ] && ok "the snapshot is removed when the job finishes" || bad "the snapshot was left behind"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
