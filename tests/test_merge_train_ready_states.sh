#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # never write the real event logs
# tests/test_merge_train_ready_states.sh — the queue's `readyStates`: the tracker states a READY is listed under.
#
# A tracker's `open` is its CLAIMABLE queue, which leaves out a claimed (`working`) issue. A project
# whose convention keeps the claim label on an issue from the claim until its landing closes it posts
# every worker READY while the issue is held, so with the default `["open"]` none of them is an item.
# `train.readyStates` names the states the queue lists (one `issue_list --state` call each); an issue
# under two states is one item, and a value the tracker does not know refuses to load. Driven through
# merge-train.py over the file issue backend, whose `claim` moves an issue into working/.

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
config() {  # <readyStates JSON array or empty>: the queue config
  if [ -n "$1" ]; then printf '{ "issueSource": "file", "issueDir": "%s", "train": { "branchOwnership": "any", "readyStates": %s } }\n' "$ISSUES" "$1"
  else printf '{ "issueSource": "file", "issueDir": "%s", "train": { "branchOwnership": "any" } }\n' "$ISSUES"; fi > "$W/.autocoder.json"
}
# ready <title> <branch>: a pushed branch and an open issue labelled ready-for-review whose newest
# comment is a READY naming the branch; prints the issue number.
ready() {
  local title="$1" branch="$2" n
  git -C "$W" checkout -q -B "$branch" origin/master
  printf '%s\n' "$branch" > "$W/$title.txt"; git -C "$W" add -A; git -C "$W" commit -q -m "$branch"; git -C "$W" push -q -f origin "$branch"
  n=$(python3 "$SCRIPTS/issues-file.py" create --title "$title" --body "spec" --label ready-for-review | python3 -c 'import json,sys; print(json.load(sys.stdin)["number"])')
  python3 "$SCRIPTS/issues-file.py" comment "$n" --body "READY \`$branch\` @ $(git -C "$W" rev-parse --short HEAD)" >/dev/null
  echo "$n"
}
queue() { python3 "$SCRIPTS/merge-train.py" --repo "$W" queue 2>&1; }

config ''
FREE=$(ready free feature/free)
HELD=$(ready held feature/held)
python3 "$SCRIPTS/issues-file.py" claim "$HELD" >/dev/null     # the claim convention: working/ until it lands
[ -f "$ISSUES/working/$(printf '%03d' "$HELD").md" ] && ok "setup: the held issue is in working/" || bad "setup: claim did not move #$HELD into working/ ($(ls "$ISSUES"/*/ 2>&1 | tr '\n' ' '))"

# ── 1. default ["open"]: the claimable queue only, so the held READY is not an item ───────
q=$(queue)
has "default: the open READY is an item" $'\t'"$FREE"$'\tfeature/free\t' "$q"
hasnt "default: the READY of a working issue is not (the tracker's open is its claimable queue)" $'\t'"$HELD"$'\t' "$q"
has "default: the status line counts one" 'merge-train: 1 ready' "$(python3 "$SCRIPTS/merge-train.py" --repo "$W" queue --status-line 2>&1)"

# ── 2. ["open", "working"]: a claimed issue can still be ready ──────────────────────────────
config '["open", "working"]'
q=$(queue)
has "open+working: the open READY is an item" $'\t'"$FREE"$'\tfeature/free\t' "$q"
has "open+working: the READY of a working issue is an item" $'\t'"$HELD"$'\tfeature/held\t' "$q"
has "open+working: the status line counts both" 'merge-train: 2 ready' "$(python3 "$SCRIPTS/merge-train.py" --repo "$W" queue --status-line 2>&1)"

# ── 3. ["working"] alone: only the held one ───────────────────────────────────────────────
config '["working"]'
q=$(queue)
hasnt "working only: the open READY is not an item" $'\t'"$FREE"$'\t' "$q"
has "working only: the held READY is" $'\t'"$HELD"$'\tfeature/held\t' "$q"

# ── 4. "all" lists every bucket; a closed issue is still no item, and no item is counted twice ──
config '["all", "open"]'
CLOSED=$(ready closed feature/closed)
python3 "$SCRIPTS/issues-file.py" close "$CLOSED" >/dev/null
q=$(queue)
has "all: the open READY is an item, once" "^[^\n]*"$'\t'"$FREE"$'\tfeature/free\t' "$q"
[ "$(grep -cE $'\t'"$FREE"$'\t' <<<"$q")" = "1" ] && ok "all+open: an issue listed under two states is one item" || bad "all+open: #$FREE listed $(grep -cE $'\t'"$FREE"$'\t' <<<"$q") times: $q"
has "all: the held READY is an item" $'\t'"$HELD"$'\tfeature/held\t' "$q"
hasnt "all: a closed issue is no item" $'\t'"$CLOSED"$'\t' "$q"

# ── 5. a state the tracker does not know refuses to load, naming the file ─────────────────
config '["open", "wroking"]'
out=$(queue); rc=$?
[ "$rc" -ne 0 ] && ok "unknown state: the queue refuses (exit $rc)" || bad "unknown state: the queue ran (exit 0): $out"
has "unknown state: the refusal names the key, the value and the file" 'train\.readyStates in .*\.autocoder\.json .*wroking' "$out"
config '[]'
q=$(queue)
has "empty list: the default, the open READY is an item" $'\t'"$FREE"$'\tfeature/free\t' "$q"
hasnt "empty list: the default, the held READY is not" $'\t'"$HELD"$'\t' "$q"

echo; echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
