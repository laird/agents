#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # never write the real event logs
# tests/test_merge_train_any_labels.sh — the queue's `anyLabels` scope ("at least one of").
#
# `readyLabels` is "all of": the READY state every item carries. When several hosts or teams
# feed one tracker, each tags its READYs with its own label and a queue takes the union it is
# configured for: `train.anyLabels`. An item carrying none of them is not this queue's; with no
# `anyLabels` nothing is scoped and every READY is an item, as before. Driven through
# merge-train.py over the file issue backend.

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
config() {  # <anyLabels JSON array or empty>: the queue config
  if [ -n "$1" ]; then printf '{ "issueSource": "file", "issueDir": "%s", "train": { "anyLabels": %s } }\n' "$ISSUES" "$1"
  else printf '{ "issueSource": "file", "issueDir": "%s", "train": { } }\n' "$ISSUES"; fi > "$W/.autocoder.json"
}
# ready <title> <branch> <label>...: a pushed branch and an open issue labelled ready-for-review (+ the
# labels given) whose newest comment is a READY naming the branch; prints the issue number.
ready() {
  local title="$1" branch="$2"; shift 2
  git -C "$W" checkout -q -B "$branch" origin/master
  printf '%s\n' "$branch" > "$W/$title.txt"; git -C "$W" add -A; git -C "$W" commit -q -m "$branch"; git -C "$W" push -q -f origin "$branch"
  local args=() lb n
  for lb in ready-for-review "$@"; do args+=(--label "$lb"); done
  n=$(python3 "$SCRIPTS/issues-file.py" create --title "$title" --body "spec" "${args[@]}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["number"])')
  python3 "$SCRIPTS/issues-file.py" comment "$n" --body "READY \`$branch\` @ $(git -C "$W" rev-parse --short HEAD)" >/dev/null
  echo "$n"
}
queue() { python3 "$SCRIPTS/merge-train.py" --repo "$W" queue 2>&1; }

config ''
MAC=$(ready mac feature/mac host:mac)
LINUX=$(ready linux feature/linux host:linux-a)
PLAIN=$(ready plain feature/plain)

# ── 1. no anyLabels: no scope, every READY is an item ──────────────────────────────────────
q=$(queue)
has "unscoped: the host:mac READY is an item" $'\t'"$MAC"$'\tfeature/mac\t' "$q"
has "unscoped: the host:linux-a READY is an item" $'\t'"$LINUX"$'\tfeature/linux\t' "$q"
has "unscoped: the READY with no host label is an item" $'\t'"$PLAIN"$'\tfeature/plain\t' "$q"

# ── 2. anyLabels names two hosts: their READYs are items, the unlabelled one is not ─────────
config '["host:linux-a", "host:mac"]'
q=$(queue)
has "two hosts: the host:mac READY is an item" $'\t'"$MAC"$'\tfeature/mac\t' "$q"
has "two hosts: the host:linux-a READY is an item" $'\t'"$LINUX"$'\tfeature/linux\t' "$q"
hasnt "two hosts: the READY carrying none of them is not this queue's" $'\t'"$PLAIN"$'\t' "$q"

# ── 3. anyLabels names one host: only its READY ──────────────────────────────────────────────
config '["host:mac"]'
q=$(queue)
has "one host: its READY is an item" $'\t'"$MAC"$'\tfeature/mac\t' "$q"
hasnt "one host: the other host's READY is not" $'\t'"$LINUX"$'\t' "$q"
hasnt "one host: the unlabelled READY is not" $'\t'"$PLAIN"$'\t' "$q"
has "one host: the status line counts one" 'merge-train: 1 ready' "$(python3 "$SCRIPTS/merge-train.py" --repo "$W" queue --status-line 2>&1)"

# ── 4. readyLabels stays "all of" beside it ─────────────────────────────────────────────────
printf '{ "issueSource": "file", "issueDir": "%s", "train": { "readyLabels": ["ready-for-review", "host:mac"], "anyLabels": ["host:mac", "host:linux-a"] } }\n' "$ISSUES" > "$W/.autocoder.json"
q=$(queue)
has "all-of and any-of: the item carrying every ready label and one scope label" $'\t'"$MAC"$'\tfeature/mac\t' "$q"
hasnt "all-of and any-of: a scope label alone does not make an item" $'\t'"$LINUX"$'\t' "$q"

echo; echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
