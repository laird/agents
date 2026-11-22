#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # never write the real event logs
# tests/test_merge_train_named_tip.sh — the queue follows a branch's current tip against the sha its READY named.
#
# A READY names a branch and, when the worker or enqueue.sh wrote it, the tip it banked (`READY `b` @ sha`).
# The queue always classifies the branch's CURRENT remote tip. With `readyTip: named` (the default) a tip
# other than the named sha is taken when it carries the same patches (a rebase onto the moved integration
# branch, a merge of it into the branch: a fast-forward) and the row says so; a tip that carries other
# work is `tip-moved`, not READY until a READY names it. A READY naming no sha, or `readyTip: current`,
# takes whatever tip the branch has. Driven through merge-train.py over the file issue backend.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$ROOT/plugins/autocoder/scripts"
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
has() { if grep -qE -- "$2" <<<"$3"; then ok "$1"; else bad "$1 — '$2' not in: $(printf '%s' "$3" | tail -25)"; fi; }
hasnt() { if grep -qE -- "$2" <<<"$3"; then bad "$1 — '$2' unexpectedly in: $(printf '%s' "$3" | tail -25)"; else ok "$1"; fi; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
unset ISSUE_SOURCE ISSUE_BACKEND ISSUE_DIR_PATH
export XDG_STATE_HOME="$TMP/state" AUTOCODER_TRAIN_SCRATCH="$TMP/scratch" ISSUE_DIR_PATH="$TMP/issues" AUTOCODER_LANDING_TIMINGS="$TMP/timings.jsonl"
export GIT_AUTHOR_NAME=T GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=T GIT_COMMITTER_EMAIL=t@example.com

ORIGIN="$TMP/origin.git"; W="$TMP/w"; ISSUES="$TMP/issues"
git init -q --bare "$ORIGIN"
git init -q -b master "$W"; git -C "$W" remote add origin "$ORIGIN"
printf 'base\n' > "$W/README.md"
git -C "$W" add -A; git -C "$W" commit -q -m init; git -C "$W" push -q origin master; git -C "$W" fetch -q origin
git -C "$W" update-ref refs/remotes/origin/HEAD refs/remotes/origin/master
echo ".autocoder.json" > "$W/.git/info/exclude"
config() {  # <train JSON object body or empty>
  printf '{ "issueSource": "file", "issueDir": "%s", "train": { "branchOwnership": "any"%s } }\n' "$ISSUES" "${1:+, $1}" > "$W/.autocoder.json"
}
tip() { git -C "$W" rev-parse --short=10 "origin/$1"; }
# branch <name> <file>: a pushed branch cut from origin/master adding <file>
branch() {
  git -C "$W" checkout -q -B "$1" origin/master
  printf '%s\n' "$1" > "$W/$2"; git -C "$W" add -A; git -C "$W" commit -q -m "$1"; git -C "$W" push -q -f origin "$1"
  git -C "$W" checkout -q master; git -C "$W" fetch -q origin
}
# ready <title> <branch> [sha-text]: an open ready-for-review issue whose READY names the branch and its tip
ready() {
  local n
  n=$(python3 "$SCRIPTS/issues-file.py" create --title "$1" --body "spec" --label ready-for-review | python3 -c 'import json,sys; print(json.load(sys.stdin)["number"])')
  python3 "$SCRIPTS/issues-file.py" comment "$n" --body "READY \`$2\` @ ${3:-$(tip "$2")} (prebank PASS)" >/dev/null
  echo "$n"
}
land_sibling() {  # master moves: a commit on README.md
  git -C "$W" checkout -q -B master origin/master
  printf 'sibling %s\n' "$1" > "$W/README.md"; git -C "$W" commit -q -am "sibling $1"; git -C "$W" push -q origin master; git -C "$W" fetch -q origin
}
rebase_push() { git -C "$W" checkout -q -B "$1" "origin/$1"; git -C "$W" rebase -q origin/master; git -C "$W" push -q -f origin "$1"; git -C "$W" checkout -q master; git -C "$W" fetch -q origin; }
merge_master_push() { git -C "$W" checkout -q -B "$1" "origin/$1"; git -C "$W" merge -q --no-ff -m "merge master" origin/master; git -C "$W" push -q origin "$1"; git -C "$W" checkout -q master; git -C "$W" fetch -q origin; }
commit_push() { git -C "$W" checkout -q -B "$1" "origin/$1"; printf 'more\n' >> "$W/$2"; git -C "$W" commit -q -am "more on $1"; git -C "$W" push -q origin "$1"; git -C "$W" checkout -q master; git -C "$W" fetch -q origin; }
queue() { python3 "$SCRIPTS/merge-train.py" --repo "$W" queue 2>&1; }
plan()  { python3 "$SCRIPTS/merge-train.py" --repo "$W" plan 2>/dev/null; }
row()   { grep -E $'\t'"$1"$'\t' <<<"$2"; }

config ''
branch feature/same same.txt;   SAME=$(ready same feature/same)
branch feature/rb rb.txt;       RB=$(ready rb feature/rb);     RB_OLD=$(tip feature/rb)
branch feature/ff ff.txt;       FF=$(ready ff feature/ff);     FF_OLD=$(tip feature/ff)
branch feature/new new.txt;     NEW=$(ready new feature/new);  NEW_OLD=$(tip feature/new)
branch feature/plain plain.txt; PLAIN=$(ready plain feature/plain "")
python3 "$SCRIPTS/issues-file.py" comment "$PLAIN" --body "READY on \`feature/plain\` (no sha)" >/dev/null

# ── 1. the tip the READY named: classified as before, nothing to say ────────────────────
q=$(queue)
has "same: queue, no note" "^[0-9]+"$'\tqueue\t'"$SAME"$'\tfeature/same\t'"$(tip feature/same)"$'\t[0-9]+\t[^\t]*\t-\t' "$q"

# ── 2. master moves; a rebase of the same patches is followed, and the row says why ─────
land_sibling 1
rebase_push feature/rb
RB_NEW=$(tip feature/rb)
[ "$RB_NEW" != "$RB_OLD" ] && ok "setup: the rebase moved the tip" || bad "setup: the rebase did not move the tip"
q=$(queue)
has "rebase: the row classifies the NEW tip as queue" $'\tqueue\t'"$RB"$'\tfeature/rb\t'"$RB_NEW"$'\t' "$q"
has "rebase: the note names the READY's sha, the tip taken and why" "READY named \`$RB_OLD\`, taking the rebased tip \`$RB_NEW\`: same patches" "$(row "$RB" "$q")"
has "rebase: the planner trains the new tip" $'^train\t'"$RB"$'\tfeature/rb\t'"$RB_NEW"$'\t' "$(plan)"

# ── 3. a fast-forward (the integration branch merged in) is followed too ────────────────
merge_master_push feature/ff
FF_NEW=$(tip feature/ff)
q=$(queue)
has "fast-forward: queue at the new tip" $'\tqueue\t'"$FF"$'\tfeature/ff\t'"$FF_NEW"$'\t' "$q"
has "fast-forward: the note says fast-forwarded" "READY named \`$FF_OLD\`, taking the fast-forwarded tip \`$FF_NEW\`: same patches" "$(row "$FF" "$q")"

# ── 4. a new commit is other work: tip-moved until a READY names it ─────────────────────
commit_push feature/new new.txt
NEW_NEW=$(tip feature/new)
q=$(queue)
has "new commit: tip-moved at the new tip" $'\ttip-moved\t'"$NEW"$'\tfeature/new\t'"$NEW_NEW"$'\t' "$q"
has "new commit: the note says what differs and what to do" "the tip \`$NEW_NEW\` carries work the READY at \`$NEW_OLD\` did not name \(the patches differ\); re-post READY at this tip" "$(row "$NEW" "$q")"
has "new commit: the planner skips it" $'^skip\t'"$NEW"$'\tfeature/new\t' "$(plan)"
has "new commit: the status line counts it" '1 tip-moved' "$(python3 "$SCRIPTS/merge-train.py" --repo "$W" queue --status-line 2>&1)"
python3 "$SCRIPTS/issues-file.py" comment "$NEW" --body "READY \`feature/new\` @ $NEW_NEW (prebank PASS on the new tip)" >/dev/null
q=$(queue)
has "new commit, re-posted: queue, no note" $'\tqueue\t'"$NEW"$'\tfeature/new\t'"$NEW_NEW"$'\t[0-9]+\t[^\t]*\t-\t' "$q"

# ── 5. no sha in the READY: whatever tip the branch has (the rule before readyTip) ──────
commit_push feature/plain plain.txt
q=$(queue)
has "no sha: queue at the current tip, no note" $'\tqueue\t'"$PLAIN"$'\tfeature/plain\t'"$(tip feature/plain)"$'\t[0-9]+\t[^\t]*\t-\t' "$q"

# ── 6. the train's own comment is never a READY, even when it quotes the tip and says READY ──
config '"swarm": "[swarm] train"'
branch feature/own own.txt; OWN=$(ready own feature/own); OWN_OLD=$(tip feature/own)
commit_push feature/own own.txt
python3 "$SCRIPTS/issues-file.py" comment "$OWN" --body "[swarm] train: not trained, \`tip-moved\`: \`feature/own\` @ \`$(tip feature/own)\`: re-post READY at this tip" >/dev/null
q=$(queue)
has "own comment: still tip-moved against the worker's READY" $'\ttip-moved\t'"$OWN"$'\tfeature/own\t'"$(tip feature/own)"$'\t' "$q"

# ── 7. readyTip: current takes any tip; an unknown value refuses to load ─────────────────
config '"readyTip": "current"'
q=$(queue)
has "current: the moved tip is queue" $'\tqueue\t'"$OWN"$'\tfeature/own\t'"$(tip feature/own)"$'\t[0-9]+\t[^\t]*\t-\t' "$q"
config '"readyTip": "latest"'
out=$(queue); rc=$?
[ "$rc" -ne 0 ] && ok "unknown readyTip: the queue refuses (exit $rc)" || bad "unknown readyTip: the queue ran: $out"
has "unknown readyTip: the refusal names the key, the values and the file" "train\.readyTip in .*\.autocoder\.json must be one of \['named', 'current'\]; got 'latest'" "$out"

echo; echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
