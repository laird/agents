#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255: never write the real event logs
# tests/test_merge_own_issue.sh — with --own-issue the detached merge job owns the issue
# from its first act to its last, through the backend's lifecycle verbs:
#   - first act: `working` → `merging` (handoff), before anything that can fail;
#   - gate passed on the published tree and the commit is on the ship branch: closed with
#     the --summary-file contents, every lock label gone;
#   - landed on any other basis (disjoint re-sync, red base) or not on the ship branch:
#     parked under `awaiting-integration`, never closed; the sentinel closes it later;
#   - gate failure or conflict before anything was pushed: bounced back to the worker
#     (`merging` → `working`, #207; repeats and other failures: tests/test_merge_bounce.sh);
#   - every transition converges: a second run on a closed issue is a no-op that retires a
#     stale `merging`, a parked issue stays parked, and a feature commit already on the
#     integration branch is closed without being merged again;
#   - a landed commit is published as refs/autocoder/tips/<integration>/<sha>-<issue>;
#   - without --own-issue the issue is untouched, so direct callers keep today's behaviour;
#   - merge-launch.sh passes --summary-file and --own-issue through to the generated run.sh.
# File backend throughout, with the bucket asserted (`ls issues/*/NNN.md`) because the
# bucket, not the label, is what makes an issue claimable or visible.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$ROOT/plugins/autocoder/scripts"
MTI="$SCRIPT_DIR/merge-to-integration.sh"
ISSUES_PY="$SCRIPT_DIR/issues-file.py"
ISSUE=19203

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# #197 samples merge-mode work for a spot check (rate 0.10 by default), which adds a
# `spot-check` label at random and breaks exact-label assertions (#225). Pin it off;
# the spot-check tests set their own rates.
export AUTOCODER_SPOT_CHECK_RATE=0
export ISSUE_SOURCE=file
# Merge state and throwaway worktrees live under AUTOCODER_TMP, keyed by the repo id.
export AUTOCODER_TMP="$TMP/tmp"; mkdir -p "$AUTOCODER_TMP"
# shellcheck source=../plugins/autocoder/scripts/repo-id-fns.sh
source "$SCRIPT_DIR/repo-id-fns.sh"
export ISSUE_DIR_PATH="$TMP/issues"
export AUTOCODER_GATE_CACHE_DIR="$TMP/gate-cache"
export CLAUDE_CODE_SHIP_BRANCH=master
unset AUTOCODER_MERGE_ON_RED_BASE AUTOCODER_SCOPED_REGATE

# Bare origin with a green ref (a sentinel has proven a tip, so the scoped re-gate and
# merge-on-red-base relaxations apply), worker on feature/code, sibling clone, and one
# issue claimed by the worker (open → working). The job does every later transition.
setup() {
  rm -rf "$TMP/origin.git" "$TMP/worker" "$TMP/sibling" "$TMP/gate-cache" "$TMP/issues" "$TMP/raced" "$TMP/gate-runs"
  mkdir -p "$TMP/issues/open" "$TMP/issues/working" "$TMP/issues/blocked" "$TMP/issues/closed"
  printf -- '---\nnumber: %s\ntitle: Own the issue\npriority: P2\nlabels: [bug]\nstatus: open\n---\nBody.\n' "$ISSUE" > "$TMP/issues/open/${ISSUE}.md"
  python3 "$ISSUES_PY" claim "$ISSUE"
  git init --bare -q "$TMP/origin.git"
  git init -q "$TMP/worker"
  cd "$TMP/worker" || exit 1
  git config user.email t@example.com; git config user.name T
  git remote add origin "$TMP/origin.git"
  echo base > README.md
  git add -A; git commit -q -m init; git branch -M master; git push -q origin master master:master-green
  git fetch -q origin
  git checkout -q -b feature/code master
  mkdir -p src; echo change > src/app.sh
  git add -A; git commit -q -m "fix"
  git clone -q "$TMP/origin.git" "$TMP/sibling"
  git -C "$TMP/sibling" config user.email s@example.com; git -C "$TMP/sibling" config user.name S
  printf 'Replaced the broken thing.\n\nSUMMARY-MARKER-%s\n' "$ISSUE" > "$TMP/summary.md"
}

issue_file()   { ls "$TMP"/issues/*/"${ISSUE}.md" 2>/dev/null | head -1; }
issue_bucket() { basename "$(dirname "$(issue_file)")"; }
issue_labels() { python3 "$ISSUES_PY" get "$ISSUE" | python3 -c 'import json,sys; print(" ".join(sorted(l["name"] for l in json.load(sys.stdin)["labels"])))'; }
issue_state()  { python3 "$ISSUES_PY" get "$ISSUE" | python3 -c 'import json,sys; print(json.load(sys.stdin)["state"])'; }
issue_body()   { cat "$(issue_file)"; }
origin_master() { git --git-dir="$TMP/origin.git" rev-parse master; }
tips()          { git --git-dir="$TMP/origin.git" for-each-ref --format='%(refname)' refs/autocoder/tips/; }
run_own()       { bash "$MTI" --feature feature/code --issue $ISSUE --integration "${INTEGRATION:-master}" --test-cmd "$1" --summary-file "$TMP/summary.md" --own-issue 2>&1; }
# A gate that lets the sibling land $1 on master during its first run, so the worker's
# first push is rejected and it must re-sync.
racing_gate() {
  printf '%s\n' 'echo "$(git rev-parse HEAD^{tree})" >> '"$TMP"'/gate-runs' \
    'if [ ! -f '"$TMP"'/raced ]; then touch '"$TMP"'/raced' \
    "  (cd $TMP/sibling && $1 && git add -A && git commit -q -m sib && git push -q origin master)" \
    'fi' "${2:-true}"
}

# ── 1. success: handoff first, then closed with the summary, no lock label left ──
setup
[ "$(issue_bucket)" = working ] && [ "$(issue_labels)" = "bug working" ] && ok "fixture: issue claimed by the worker" || bad "fixture wrong: bucket=$(issue_bucket) labels=$(issue_labels)"
OUT=$(run_own true); RC=$?
[ "$RC" -eq 0 ] && ok "own-issue merge exits 0" || bad "rc=$RC: $OUT"
echo "$OUT" | grep -q "handed off: working → merging" && ok "the job performs the hand-off itself" || bad "no hand-off line: $OUT"
[ "$(issue_state)" = CLOSED ] && [ "$(issue_bucket)" = closed ] && ok "issue closed (closed/ bucket)" || bad "issue not closed: state=$(issue_state) bucket=$(issue_bucket)"
[ "$(issue_labels)" = "bug" ] && ok "every lock label retired on close" || bad "labels after close: $(issue_labels)"
issue_body | grep -q "Issue Resolved" && issue_body | grep -q "SUMMARY-MARKER-${ISSUE}" && ok "resolution comment carries the summary file" || bad "summary missing from close comment: $(issue_body)"
issue_body | grep -q '`feature/code` (merged and deleted)' && ok "resolution comment names the branch" || bad "branch line missing"
echo "$OUT" | grep -q "Issue #${ISSUE} closed" && ok "log reports the close" || bad "log missing close line: $OUT"
LANDED=$(origin_master)
tips | grep -q "^refs/autocoder/tips/master/${LANDED}-${ISSUE}$" && ok "landed commit published as refs/autocoder/tips/master/<sha>-<issue>" || bad "tip ref missing: $(tips)"
echo "$OUT" | grep -q "Published ${LANDED:0:8} as refs/autocoder/tips/master/" && ok "log names the tip ref" || bad "log lacks the tip line: $OUT"

# ── 2. a second run on the closed issue is a no-op that retires a stale merging ──
python3 "$ISSUES_PY" update "$ISSUE" --add-label merging
MASTER_BEFORE=$(origin_master)
OUT=$(run_own true); RC=$?
[ "$RC" -eq 0 ] && ok "rerun on a closed issue exits 0" || bad "rerun rc=$RC: $OUT"
echo "$OUT" | grep -q "already closed" && ok "rerun says the issue is already closed" || bad "rerun did not short-circuit: $OUT"
[ "$(origin_master)" = "$MASTER_BEFORE" ] && ok "rerun pushed nothing" || bad "rerun moved master"
[ "$(issue_labels)" = "bug" ] && [ "$(issue_bucket)" = closed ] && ok "rerun retired the stale merging label and left the issue closed" || bad "rerun state: $(issue_bucket) $(issue_labels)"
[ "$(issue_body | grep -c "Issue Resolved")" -eq 1 ] && ok "rerun added no second resolution comment" || bad "duplicate resolution comment: $(issue_body)"

# ── 3. gate failure: bounced back to the worker (#207), with the gate output ──
setup
BEFORE=$(origin_master)
OUT=$(run_own 'echo GATE-SAYS-BOOM; test ! -f src/app.sh'); RC=$?
[ "$RC" -eq 2 ] && ok "gate failure exits 2" || bad "rc=$RC: $OUT"
[ "$(origin_master)" = "$BEFORE" ] && ok "nothing pushed" || bad "master moved"
[ "$(issue_bucket)" = working ] && [ "$(issue_labels)" = "bug working" ] && ok "issue bounced: working/ bucket, working label, merging retired" || bad "bounce state: bucket=$(issue_bucket) labels=$(issue_labels)"
[ "$(issue_state)" = OPEN ] && ok "issue stays open" || bad "issue state $(issue_state)"
issue_body | grep -q "failed the gate on the integrated tree; returned to the owning worker" && ok "bounce comment posted" || bad "no bounce comment: $(issue_body)"
issue_body | grep -q "GATE-SAYS-BOOM" && ok "failure comment quotes the gate output" || bad "gate output missing from comment: $(issue_body)"
issue_body | grep -q "this change broke it" && ok "failure comment carries the verdict" || bad "verdict missing from comment"
[ -z "$(tips)" ] && ok "no tip ref published for a refused merge" || bad "tip ref published without a landing: $(tips)"

# ── 4. without --own-issue the issue is untouched ───────────────────────────
setup
bash "$MTI" --feature feature/code --issue $ISSUE --integration master --test-cmd 'test ! -f src/app.sh' >/dev/null 2>&1; RC=$?
[ "$RC" -eq 2 ] && ok "plain gate failure still exits 2" || bad "plain rc=$RC"
[ "$(issue_bucket)" = working ] && [ "$(issue_labels)" = "bug working" ] && ok "plain run leaves bucket and labels alone" || bad "plain run changed state: $(issue_bucket) $(issue_labels)"
issue_body | grep -q "Auto-merge" && bad "plain run commented on the issue" || ok "plain run posted no comment"

setup
bash "$MTI" --feature feature/code --issue $ISSUE --integration master --test-cmd true >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && [ "$(issue_state)" = OPEN ] && [ "$(issue_labels)" = "bug working" ] && ok "plain success leaves the issue open and claimed for the caller" || bad "plain success rc=$RC state=$(issue_state) labels=$(issue_labels)"
tips | grep -q -- "-${ISSUE}$" && ok "plain success still publishes the tip ref" || bad "plain success published no tip: $(tips)"

# ── 5. already landed: a rerun closes without merging again ─────────────────
MASTER_BEFORE=$(origin_master)
OUT=$(run_own 'echo ran >> '"$TMP"'/late-gate; true'); RC=$?
[ "$RC" -eq 0 ] && ok "rerun after a landed push exits 0" || bad "rc=$RC: $OUT"
echo "$OUT" | grep -q "already on origin/master" && ok "rerun sees the commit is already landed" || bad "rerun merged again: $OUT"
[ "$(origin_master)" = "$MASTER_BEFORE" ] && ok "rerun added no commit to master" || bad "rerun moved master"
[ ! -f "$TMP/late-gate" ] && ok "rerun ran no gate" || bad "rerun ran the gate"
[ "$(issue_state)" = CLOSED ] && issue_body | grep -q "SUMMARY-MARKER-${ISSUE}" && ok "rerun closed the issue with the summary" || bad "rerun did not close: state=$(issue_state)"

# ── 6. landed on a feature line, not on the ship branch: parked, not closed ─
# The swarm integrates into `integration`; the ship branch is master (issue #35).
setup
git push -q origin master:integration master:integration-green
OUT=$(INTEGRATION=integration run_own true); RC=$?
[ "$RC" -eq 0 ] && ok "unshipped merge still exits 0" || bad "rc=$RC: $OUT"
git --git-dir="$TMP/origin.git" cat-file -e integration:src/app.sh 2>/dev/null && ok "fix landed on integration" || bad "fix did not land on integration"
[ "$(issue_state)" = OPEN ] && ok "issue left open when not on the ship branch" || bad "issue closed though not shipped: $OUT"
[ "$(issue_bucket)" = working ] && [ "$(issue_labels)" = "awaiting-integration bug" ] && ok "parked: working/ bucket, awaiting-integration, merging retired" || bad "park state: $(issue_bucket) $(issue_labels)"
issue_body | grep -q "not yet shipped" && issue_body | grep -q 'must merge to `master`' && ok "not-yet-shipped comment names the ship branch" || bad "ship-gate comment missing: $(issue_body)"

# ── 7. red base + --own-issue: parked with both tree ids, never closed ──────
setup
OUT=$(run_own 'echo "$(git rev-parse HEAD^{tree})" >> '"$TMP"'/gate-runs; false'); RC=$?
[ "$RC" -eq 0 ] && ok "red-base merge exits 0" || bad "rc=$RC: $OUT"
git --git-dir="$TMP/origin.git" cat-file -e master:src/app.sh 2>/dev/null && ok "red-base: fix landed on master" || bad "red-base: fix did not land"
[ "$(issue_state)" = OPEN ] && [ "$(issue_bucket)" = working ] && [ "$(issue_labels)" = "awaiting-integration bug" ] && ok "red-base: parked under awaiting-integration, not closed" || bad "red-base state: $(issue_state) $(issue_bucket) $(issue_labels)"
issue_body | grep -q "Issue Resolved" && bad "red-base landing closed the issue as Resolved" || ok "red-base: no 'Issue Resolved' comment"
LANDED=$(origin_master)
issue_body | grep -q "Landed on \`master\` as \`${LANDED}\`" && ok "park comment names the landed sha" || bad "park comment lacks the landed sha: $(issue_body)"
issue_body | grep -q "Merged onto a red" && issue_body | grep -q "$(sed -n 1p "$TMP/gate-runs")" && issue_body | grep -q "$(sed -n 2p "$TMP/gate-runs")" && ok "park comment carries both gated tree ids" || bad "park comment lacks a tree id: $(issue_body)"
issue_body | grep -q "SUMMARY-MARKER-${ISSUE}" && ok "park comment carries the summary" || bad "park comment lacks the summary"
echo "$OUT" | grep -q "parked under awaiting-integration (red-base)" && ok "log says parked, with the basis" || bad "log lacks the park line: $OUT"
tips | grep -q "^refs/autocoder/tips/master/${LANDED}-${ISSUE}$" && ok "red-base landing still publishes its tip ref" || bad "tip ref missing after red-base: $(tips)"

# a rerun on the parked issue leaves it parked (the sentinel owns it now)
MASTER_BEFORE=$(origin_master)
OUT=$(run_own true); RC=$?
[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "leaving it to the sentinel" && ok "rerun on a parked issue defers to the sentinel" || bad "rerun on parked: rc=$RC $OUT"
[ "$(issue_state)" = OPEN ] && [ "$(issue_labels)" = "awaiting-integration bug" ] && [ "$(origin_master)" = "$MASTER_BEFORE" ] && ok "rerun on a parked issue changed nothing" || bad "rerun on parked: $(issue_state) $(issue_labels)"

# ── 8. disjoint re-sync + --own-issue: parked, not closed ───────────────────
setup
OUT=$(run_own "$(racing_gate 'echo s > sibling.txt')"); RC=$?
[ "$RC" -eq 0 ] && ok "disjoint merge exits 0" || bad "rc=$RC: $OUT"
echo "$OUT" | grep -q "disjoint re-sync; gated tree" && ok "disjoint: success line names both trees" || bad "disjoint success line wrong: $OUT"
[ "$(issue_state)" = OPEN ] && [ "$(issue_bucket)" = working ] && [ "$(issue_labels)" = "awaiting-integration bug" ] && ok "disjoint: parked under awaiting-integration, not closed" || bad "disjoint state: $(issue_state) $(issue_bucket) $(issue_labels)"
issue_body | grep -q "which no gate has run on" && ok "disjoint: park comment explains the untested published tree" || bad "disjoint park comment: $(issue_body)"
echo "$OUT" | grep -q "parked under awaiting-integration (disjoint)" && ok "disjoint: log says parked" || bad "disjoint log: $OUT"

# ── 8b. documents-only re-sync + --own-issue: closed, like tested ───────────
setup
OUT=$(run_own "$(racing_gate 'mkdir -p docs && echo spec > docs/design.md')"); RC=$?
[ "$RC" -eq 0 ] && ok "docs-resync merge exits 0" || bad "docs-resync rc=$RC: $OUT"
echo "$OUT" | grep -q "a documents-only re-sync (1 document files) then published tree" && ok "docs-resync: success line names the document count" || bad "docs-resync success line wrong: $OUT"
[ "$(issue_state)" = CLOSED ] && [ "$(issue_bucket)" = closed ] && [ "$(issue_labels)" = "bug" ] && ok "docs-resync: issue closed (documents are not an input to the test stages)" || bad "docs-resync state: $(issue_state) $(issue_bucket) $(issue_labels)"
issue_body | grep -q "Issue Resolved" && ok "docs-resync: resolution comment posted" || bad "docs-resync comment: $(issue_body)"

# ── 8c. closed mid-run (a "Fix #N" closing keyword, #211): labels retired, summary posted ──
# The gate closes the issue and puts the lock labels back, as GitHub does when the pushed
# commit's title closes it while the job still holds `merging`.
setup
CLOSER="python3 $ISSUES_PY close $ISSUE && sed -i 's/^labels: .*/labels: [bug, merging, working, awaiting-integration]/' $TMP/issues/closed/${ISSUE}.md"
OUT=$(run_own "$CLOSER"); RC=$?
[ "$RC" -eq 0 ] && ok "closed mid-run: exits 0" || bad "closed mid-run rc=$RC: $OUT"
echo "$OUT" | grep -q "already closed; posted the landing summary anyway" && ok "closed mid-run: log reports the landing on a closed issue" || bad "closed mid-run: no landing line: $OUT"
[ "$(issue_state)" = CLOSED ] && [ "$(issue_bucket)" = closed ] && ok "closed mid-run: issue stays closed" || bad "closed mid-run reopened: state=$(issue_state) bucket=$(issue_bucket)"
[ "$(issue_labels)" = "bug" ] && ok "closed mid-run: merging, working and awaiting-integration retired" || bad "closed mid-run labels: $(issue_labels)"
[ "$(issue_body | grep -c "already closed, probably by a closing keyword")" -eq 1 ] && issue_body | grep -q "SUMMARY-MARKER-${ISSUE}" && ok "closed mid-run: summary posted once" || bad "closed mid-run summary: $(issue_body)"
python3 "$ISSUES_PY" update "$ISSUE" --add-label merging
OUT=$(run_own true)
[ "$(issue_body | grep -c "already closed, probably by a closing keyword")" -eq 1 ] && [ "$(issue_labels)" = "bug" ] && ok "closed mid-run: rerun posts no second summary" || bad "rerun after mid-run close: $(issue_labels) $(issue_body)"

# ── 9. conflict: bounced under --own-issue (#207), untouched without ────────
setup
(cd "$TMP/sibling" && mkdir -p src && echo sibling > src/app.sh && git add -A && git commit -q -m clash && git push -q origin master)
BEFORE=$(origin_master)
OUT=$(run_own true); RC=$?
[ "$RC" -eq 1 ] && ok "conflict exits 1" || bad "conflict rc=$RC: $OUT"
[ "$(origin_master)" = "$BEFORE" ] && ok "conflict pushed nothing" || bad "conflict moved master"
[ "$(issue_bucket)" = working ] && [ "$(issue_labels)" = "bug working" ] && ok "conflict: bounced to working/ with working" || bad "conflict state: $(issue_bucket) $(issue_labels)"
issue_body | grep -q "hit a merge conflict" && ok "conflict comment posted" || bad "conflict comment missing: $(issue_body)"

setup
(cd "$TMP/sibling" && mkdir -p src && echo sibling > src/app.sh && git add -A && git commit -q -m clash && git push -q origin master)
bash "$MTI" --feature feature/code --issue $ISSUE --integration master --test-cmd true >/dev/null 2>&1; RC=$?
[ "$RC" -eq 1 ] && [ "$(issue_bucket)" = working ] && [ "$(issue_labels)" = "bug working" ] && ok "plain conflict leaves the issue to the caller" || bad "plain conflict: rc=$RC $(issue_bucket) $(issue_labels)"

# ── 10. merge-launch.sh passes the new options through, state keyed by repo id ──
mkdir -p "$TMP/fakebin"
cp "$SCRIPT_DIR/merge-launch.sh" "$SCRIPT_DIR/test-cmd-fns.sh" "$SCRIPT_DIR/repo-id-fns.sh" \
   "$SCRIPT_DIR/feature-ref-fns.sh" "$SCRIPT_DIR/git-net-fns.sh" "$SCRIPT_DIR/merge-archive-fns.sh" "$TMP/fakebin/"
printf '#!/bin/bash\nexit 0\n' > "$TMP/fakebin/merge-to-integration.sh"; chmod +x "$TMP/fakebin/merge-to-integration.sh"
STATE="$AUTOCODER_TMP/autocoder-merge-$(autocoder_repo_id "$TMP/worker")-${ISSUE}"
RUN="${STATE}.run.sh"
bash "$TMP/fakebin/merge-launch.sh" --feature feature/code --issue $ISSUE --integration master --test-cmd true --summary-file "$TMP/my summary.md" --own-issue >/dev/null 2>&1
[ -f "$RUN" ] && ok "launch state is keyed by repo id under AUTOCODER_TMP" || bad "no run.sh at $RUN: $(ls "$AUTOCODER_TMP")"
grep -q -- "--summary-file $TMP/my\\\\ summary.md" "$RUN" && ok "run.sh carries --summary-file, quoted" || bad "run.sh lacks --summary-file: $(cat "$RUN" 2>/dev/null)"
grep -q -- "--own-issue" "$RUN" && ok "run.sh carries --own-issue" || bad "run.sh lacks --own-issue: $(cat "$RUN" 2>/dev/null)"
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -f "${STATE}.exit" ] && break; sleep 0.3; done
rm -f "${STATE}".*
bash "$TMP/fakebin/merge-launch.sh" --feature feature/code --issue $ISSUE --integration master --test-cmd true >/dev/null 2>&1
grep -q -- "--own-issue\|--summary-file" "$RUN" && bad "run.sh carries options the caller did not pass" || ok "run.sh omits the options when not passed"
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -f "${STATE}.exit" ] && break; sleep 0.3; done

TOTAL=$((PASS + FAIL))
echo "$PASS passed / $FAIL failed / $TOTAL total"
[ "$FAIL" -eq 0 ]
