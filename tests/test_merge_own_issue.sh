#!/bin/bash
# tests/test_merge_own_issue.sh — with --own-issue the detached merge job owns the issue's
# terminal transition (open → working → awaiting-integration → closed | needs-clarification),
# so the worker that launched it hands off instead of polling:
#   - on success it closes the issue with the --summary-file contents and retires
#     `awaiting-integration`;
#   - when verify-shipped.sh says the commit is not on the ship branch it leaves the issue
#     open under `awaiting-integration` with the "not yet shipped" comment;
#   - on a gate failure it swaps `awaiting-integration` for `needs-clarification` and quotes
#     the gate output;
#   - every transition converges: a second run on a closed issue is a no-op, and a feature
#     commit already on the integration branch is closed without being merged again;
#   - without --own-issue the issue is untouched, so direct callers keep today's behaviour;
#   - merge-launch.sh passes --summary-file and --own-issue through to the generated run.sh.
# File backend throughout (ISSUE_SOURCE=file, ISSUE_DIR_PATH), ship branch pinned by env.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$ROOT/plugins/autocoder/scripts"
MTI="$SCRIPT_DIR/merge-to-integration.sh"
ISSUES_PY="$SCRIPT_DIR/issues-file.py"
ISSUE=19203

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"; rm -f /tmp/autocoder-merge-${ISSUE}.*; rm -rf /tmp/autocoder-merge-worktree-${ISSUE}*' EXIT
export ISSUE_SOURCE=file
export ISSUE_DIR_PATH="$TMP/issues"
export AUTOCODER_GATE_CACHE_DIR="$TMP/gate-cache"
export CLAUDE_CODE_SHIP_BRANCH=master
unset AUTOCODER_MERGE_ON_RED_BASE

# Bare origin, worker on feature/code, and one issue taken through the worker's own
# transitions with the real backend verbs: claim (open → working), then the hand-off
# swap to awaiting-integration that fix.md performs right after merge-launch.sh.
setup() {
  rm -rf "$TMP/origin.git" "$TMP/worker" "$TMP/gate-cache" "$TMP/issues"
  mkdir -p "$TMP/issues/open" "$TMP/issues/working" "$TMP/issues/blocked" "$TMP/issues/closed"
  printf -- '---\nnumber: %s\ntitle: Own the issue\npriority: P2\nlabels: [bug]\nstatus: open\n---\nBody.\n' "$ISSUE" > "$TMP/issues/open/${ISSUE}.md"
  python3 "$ISSUES_PY" claim "$ISSUE"
  python3 "$ISSUES_PY" update "$ISSUE" --add-label awaiting-integration
  python3 "$ISSUES_PY" update "$ISSUE" --remove-label working
  git init --bare -q "$TMP/origin.git"
  git init -q "$TMP/worker"
  cd "$TMP/worker" || exit 1
  git config user.email t@example.com; git config user.name T
  git remote add origin "$TMP/origin.git"
  echo base > README.md
  git add -A; git commit -q -m init; git branch -M master; git push -q origin master
  git fetch -q origin
  git checkout -q -b feature/code master
  mkdir -p src; echo change > src/app.sh
  git add -A; git commit -q -m "fix"
  printf 'Replaced the broken thing.\n\nSUMMARY-MARKER-%s\n' "$ISSUE" > "$TMP/summary.md"
}

issue_file()   { ls "$TMP"/issues/*/"${ISSUE}.md" 2>/dev/null | head -1; }
issue_bucket() { basename "$(dirname "$(issue_file)")"; }
issue_labels() { python3 "$ISSUES_PY" get "$ISSUE" | python3 -c 'import json,sys; print(" ".join(l["name"] for l in json.load(sys.stdin)["labels"]))'; }
issue_state()  { python3 "$ISSUES_PY" get "$ISSUE" | python3 -c 'import json,sys; print(json.load(sys.stdin)["state"])'; }
issue_body()   { cat "$(issue_file)"; }
origin_master() { git --git-dir="$TMP/origin.git" rev-parse master; }

# ── 1. success: closed with the summary, awaiting-integration retired ───────
setup
[ "$(issue_bucket)" = working ] && echo "$(issue_labels)" | grep -q awaiting-integration && ok "fixture: issue handed off under awaiting-integration" || bad "fixture wrong: bucket=$(issue_bucket) labels=$(issue_labels)"
OUT=$(bash "$MTI" --feature feature/code --issue $ISSUE --integration master --test-cmd true --summary-file "$TMP/summary.md" --own-issue 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok "own-issue merge exits 0" || bad "rc=$RC: $OUT"
[ "$(issue_state)" = CLOSED ] && [ "$(issue_bucket)" = closed ] && ok "issue closed" || bad "issue not closed: state=$(issue_state) bucket=$(issue_bucket)"
issue_body | grep -q "Issue Resolved" && issue_body | grep -q "SUMMARY-MARKER-${ISSUE}" && ok "resolution comment carries the summary file" || bad "summary missing from close comment: $(issue_body)"
issue_body | grep -q '`feature/code` (merged and deleted)' && ok "resolution comment names the branch" || bad "branch line missing"
echo "$(issue_labels)" | grep -q awaiting-integration && bad "awaiting-integration still set after close" || ok "awaiting-integration retired"
echo "$OUT" | grep -q "Issue #${ISSUE} closed" && ok "log reports the close" || bad "log missing close line: $OUT"

# ── 2. a second run on the closed issue is a no-op ──────────────────────────
MASTER_BEFORE=$(origin_master)
OUT=$(bash "$MTI" --feature feature/code --issue $ISSUE --integration master --test-cmd true --summary-file "$TMP/summary.md" --own-issue 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok "rerun on a closed issue exits 0" || bad "rerun rc=$RC: $OUT"
echo "$OUT" | grep -q "already closed" && ok "rerun says the issue is already closed" || bad "rerun did not short-circuit: $OUT"
[ "$(origin_master)" = "$MASTER_BEFORE" ] && ok "rerun pushed nothing" || bad "rerun moved master"
[ "$(issue_body | grep -c "Issue Resolved")" -eq 1 ] && ok "rerun added no second resolution comment" || bad "duplicate resolution comment: $(issue_body)"

# ── 3. gate failure: needs-clarification with the gate output ───────────────
setup
BEFORE=$(origin_master)
OUT=$(bash "$MTI" --feature feature/code --issue $ISSUE --integration master --test-cmd 'echo GATE-SAYS-BOOM; test ! -f src/app.sh' --summary-file "$TMP/summary.md" --own-issue 2>&1); RC=$?
[ "$RC" -eq 2 ] && ok "gate failure exits 2" || bad "rc=$RC: $OUT"
[ "$(origin_master)" = "$BEFORE" ] && ok "nothing pushed" || bad "master moved"
echo "$(issue_labels)" | grep -q needs-clarification && ok "issue labelled needs-clarification" || bad "labels: $(issue_labels)"
echo "$(issue_labels)" | grep -q awaiting-integration && bad "awaiting-integration not retired on failure" || ok "awaiting-integration retired on failure"
[ "$(issue_state)" = OPEN ] && ok "issue stays open" || bad "issue state $(issue_state)"
issue_body | grep -q "Auto-merge to \`master\` failed" && ok "failure comment posted" || bad "no failure comment: $(issue_body)"
issue_body | grep -q "GATE-SAYS-BOOM" && ok "failure comment quotes the gate output" || bad "gate output missing from comment: $(issue_body)"
issue_body | grep -q "this change broke it" && ok "failure comment carries the verdict" || bad "verdict missing from comment"

# ── 4. without --own-issue the issue is untouched ───────────────────────────
setup
bash "$MTI" --feature feature/code --issue $ISSUE --integration master --test-cmd 'test ! -f src/app.sh' >/dev/null 2>&1; RC=$?
[ "$RC" -eq 2 ] && ok "plain gate failure still exits 2" || bad "plain rc=$RC"
[ "$(issue_labels)" = "bug awaiting-integration" ] && ok "plain run leaves the labels alone" || bad "plain run changed labels: $(issue_labels)"
issue_body | grep -q "Auto-merge" && bad "plain run commented on the issue" || ok "plain run posted no comment"

setup
bash "$MTI" --feature feature/code --issue $ISSUE --integration master --test-cmd true >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && [ "$(issue_state)" = OPEN ] && ok "plain success leaves the issue open for the caller" || bad "plain success rc=$RC state=$(issue_state)"

# ── 5. already landed: a rerun closes without merging again ─────────────────
MASTER_BEFORE=$(origin_master)
OUT=$(bash "$MTI" --feature feature/code --issue $ISSUE --integration master --test-cmd 'echo ran >> '"$TMP"'/late-gate; true' --summary-file "$TMP/summary.md" --own-issue 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok "rerun after a landed push exits 0" || bad "rc=$RC: $OUT"
echo "$OUT" | grep -q "already on origin/master" && ok "rerun sees the commit is already landed" || bad "rerun merged again: $OUT"
[ "$(origin_master)" = "$MASTER_BEFORE" ] && ok "rerun added no commit to master" || bad "rerun moved master"
[ ! -f "$TMP/late-gate" ] && ok "rerun ran no gate" || bad "rerun ran the gate"
[ "$(issue_state)" = CLOSED ] && issue_body | grep -q "SUMMARY-MARKER-${ISSUE}" && ok "rerun closed the issue with the summary" || bad "rerun did not close: state=$(issue_state)"

# ── 6. landed on a feature line, not on the ship branch: parked, not closed ─
# The swarm integrates into `integration`; the ship branch is master (issue #35).
setup
git push -q origin master:integration
OUT=$(bash "$MTI" --feature feature/code --issue $ISSUE --integration integration --test-cmd true --summary-file "$TMP/summary.md" --own-issue 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok "unshipped merge still exits 0" || bad "rc=$RC: $OUT"
git --git-dir="$TMP/origin.git" cat-file -e integration:src/app.sh 2>/dev/null && ok "fix landed on integration" || bad "fix did not land on integration"
[ "$(issue_state)" = OPEN ] && ok "issue left open when not on the ship branch" || bad "issue closed though not shipped: $OUT"
echo "$(issue_labels)" | grep -q awaiting-integration && ok "issue stays under awaiting-integration" || bad "labels: $(issue_labels)"
issue_body | grep -q "not yet shipped" && issue_body | grep -q 'must merge to `master`' && ok "not-yet-shipped comment names the ship branch" || bad "ship-gate comment missing: $(issue_body)"

# ── 7. merge-launch.sh passes the new options through ───────────────────────
mkdir -p "$TMP/fakebin"
cp "$SCRIPT_DIR/merge-launch.sh" "$SCRIPT_DIR/test-cmd-fns.sh" "$TMP/fakebin/"
printf '#!/bin/bash\nexit 0\n' > "$TMP/fakebin/merge-to-integration.sh"; chmod +x "$TMP/fakebin/merge-to-integration.sh"
bash "$TMP/fakebin/merge-launch.sh" --feature feature/code --issue $ISSUE --integration master --test-cmd true --summary-file "$TMP/my summary.md" --own-issue >/dev/null 2>&1
RUN="/tmp/autocoder-merge-${ISSUE}.run.sh"
grep -q -- "--summary-file $TMP/my\\\\ summary.md" "$RUN" && ok "run.sh carries --summary-file, quoted" || bad "run.sh lacks --summary-file: $(cat "$RUN" 2>/dev/null)"
grep -q -- "--own-issue" "$RUN" && ok "run.sh carries --own-issue" || bad "run.sh lacks --own-issue: $(cat "$RUN" 2>/dev/null)"
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -f "/tmp/autocoder-merge-${ISSUE}.exit" ] && break; sleep 0.3; done
rm -f /tmp/autocoder-merge-${ISSUE}.*
bash "$TMP/fakebin/merge-launch.sh" --feature feature/code --issue $ISSUE --integration master --test-cmd true >/dev/null 2>&1
grep -q -- "--own-issue\|--summary-file" "$RUN" && bad "run.sh carries options the caller did not pass" || ok "run.sh omits the options when not passed"
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -f "/tmp/autocoder-merge-${ISSUE}.exit" ] && break; sleep 0.3; done

TOTAL=$((PASS + FAIL))
echo "$PASS passed / $FAIL failed / $TOTAL total"
[ "$FAIL" -eq 0 ]
