#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255: never write the real event logs
# tests/test_merge_queue.sh — merge jobs on one host land one at a time (#189).
#
# Two workers (two clones of one origin) finish at the same moment and each starts
# merge-to-integration.sh. Without the queue both fetch the same tip, gate in parallel,
# and the second push is rejected and re-synced. With it, the second job waits, syncs
# onto the first one's landing, and pushes once: no rejected push, and its log says it
# queued. The same pair with AUTOCODER_MERGE_QUEUE=0 does race,
# which proves the first run measured the queue. Gate slots are set to 2 throughout so the
# gate-slot semaphore cannot serialise the jobs by itself.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$ROOT/plugins/autocoder/scripts"
MTI="$SCRIPT_DIR/merge-to-integration.sh"

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export ISSUE_SOURCE=file
export AUTOCODER_TMP="$TMP/tmp"; mkdir -p "$AUTOCODER_TMP"
export AUTOCODER_GATE_CACHE_DIR="$TMP/gate-cache"
export AUTOCODER_MAX_GATES=2

# setup: origin + clones w1 (feature/a) and w2 (feature/b) touching different files.
setup() {
  rm -rf "$TMP/origin.git" "$TMP/seed" "$TMP/w1" "$TMP/w2" "$TMP"/*.start "$TMP"/*.end "$TMP/gate-cache"
  git init --bare -q "$TMP/origin.git"
  git init -q "$TMP/seed"
  git -C "$TMP/seed" config user.email t@example.com; git -C "$TMP/seed" config user.name T
  echo base > "$TMP/seed/README.md"
  git -C "$TMP/seed" add -A; git -C "$TMP/seed" commit -q -m init; git -C "$TMP/seed" branch -M master
  git -C "$TMP/seed" push -q "$TMP/origin.git" master
  local w f
  for w in w1:a w2:b; do
    f="${w#*:}"; w="${w%%:*}"
    git clone -q "$TMP/origin.git" "$TMP/$w"
    git -C "$TMP/$w" config user.email t@example.com; git -C "$TMP/$w" config user.name T
    git -C "$TMP/$w" checkout -q -b "feature/$f"
    echo "$f" > "$TMP/$w/$f.txt"; git -C "$TMP/$w" add -A; git -C "$TMP/$w" commit -q -m "add $f"
  done
}
# The gate records start/end and whether it inherited the queue's fd 8.
gate() { printf 'date +%%s.%%N > %q; [ -e /proc/$$/fd/8 ] && echo leaked > %q; sleep 2; date +%%s.%%N > %q' \
  "$TMP/$1.start" "$TMP/$1.fd8" "$TMP/$1.end"; }
run_pair() {
  (cd "$TMP/w1" && bash "$MTI" --feature feature/a --issue 301 --integration master --test-cmd "$(gate w1)" > "$TMP/w1.log" 2>&1) &
  (cd "$TMP/w2" && bash "$MTI" --feature feature/b --issue 302 --integration master --test-cmd "$(gate w2)" > "$TMP/w2.log" 2>&1) &
  wait
}

# ── queued (default): one after the other, no race ──────────────────────────
setup; run_pair
for w in w1 w2; do grep -q "merged into 'master'" "$TMP/$w.log" && ok "$w merged" || bad "$w did not merge: $(cat "$TMP/$w.log")"; done
git -C "$TMP/origin.git" show master:a.txt >/dev/null 2>&1 && git -C "$TMP/origin.git" show master:b.txt >/dev/null 2>&1 \
  && ok "both changes are on origin/master" || bad "origin/master is missing a change"
grep -q "rejected" "$TMP/w1.log" "$TMP/w2.log" && bad "a push was rejected: $(grep -h rejected "$TMP"/w*.log)" || ok "no push was rejected"
[ -z "$(git -C "$TMP/origin.git" rev-list --merges master)" ] && ok "master stays linear (no merge commits)" || bad "merge commits on master: $(git -C "$TMP/origin.git" log --merges --oneline master)"
grep -q "⏳ Queued: issue #30[12]" "$TMP/w1.log" "$TMP/w2.log" && ok "the waiting job logged whom it queued behind" || bad "no queued line naming the holder: $(grep -h "Queued\|turn" "$TMP"/w*.log)"
grep -q "Our turn to land on 'master'" "$TMP/w1.log" "$TMP/w2.log" && ok "the waiting job logged its turn" || bad "no turn line"
if [ "$(cat "$TMP/w1.start")" \< "$(cat "$TMP/w2.start")" ]; then FIRST_END=$(cat "$TMP/w1.end"); SECOND_START=$(cat "$TMP/w2.start")
else FIRST_END=$(cat "$TMP/w2.end"); SECOND_START=$(cat "$TMP/w1.start"); fi
python3 -c "import sys; sys.exit(0 if float('$SECOND_START') >= float('$FIRST_END') else 1)" \
  && ok "the second gate started after the first ended" || bad "the gates overlapped despite the queue"
ls "$TMP"/*.fd8 >/dev/null 2>&1 && bad "a gate inherited the queue lock's fd 8" || ok "gates do not inherit the queue lock"
ls "$AUTOCODER_TMP"/autocoder-land-*.holder >/dev/null 2>&1 && bad "a holder file outlived its job" || ok "holder file removed on release"

# ── queue off: the same pair races, so the run above measured the queue ─────
setup; AUTOCODER_MERGE_QUEUE=0 run_pair
for w in w1 w2; do grep -q "merged into 'master'" "$TMP/$w.log" && ok "queue off: $w merged" || bad "queue off: $w did not merge: $(cat "$TMP/$w.log")"; done
grep -q "rejected" "$TMP/w1.log" "$TMP/w2.log" && ok "queue off: the pair raced (a push was rejected and re-synced)" || bad "queue off: no race, so the queued run proved nothing"
grep -q "Landing queue off" "$TMP/w1.log" && ok "queue off is logged" || bad "queue off not logged"

# ── a stuck holder: the job gives up waiting and lands unqueued ─────────────
setup
source "$SCRIPT_DIR/repo-id-fns.sh"; source "$SCRIPT_DIR/merge-queue-fns.sh"
KEY=$(merge_queue_key "$TMP/w1" master)
echo "issue #999 (pid 1, since 00:00:00)" > "$AUTOCODER_TMP/autocoder-land-${KEY}.holder"
flock "$AUTOCODER_TMP/autocoder-land-${KEY}.lock" sleep 8 &
HOLDER=$!; sleep 0.3
(cd "$TMP/w1" && AUTOCODER_MERGE_QUEUE_WAIT=1 bash "$MTI" --feature feature/a --issue 301 --integration master --test-cmd "true" > "$TMP/w1.log" 2>&1)
grep -q "⏳ Queued: issue #999" "$TMP/w1.log" && ok "a stuck holder is named in the log" || bad "holder not named: $(cat "$TMP/w1.log")"
grep -q "Still queued after 1s" "$TMP/w1.log" && grep -q "merged into 'master'" "$TMP/w1.log" \
  && ok "after the wait cap the job lands unqueued" || bad "wait cap did not fall through: $(cat "$TMP/w1.log")"
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null

# ── the key: shared by clones of one origin, separate per branch ────────────
K1=$(merge_queue_key "$TMP/w1" master); K2=$(merge_queue_key "$TMP/w2" master); K3=$(merge_queue_key "$TMP/w1" develop)
[ "$K1" = "$K2" ] && ok "two clones of one origin share a queue" || bad "clones got different keys ($K1, $K2)"
[ "$K1" != "$K3" ] && ok "another integration branch gets its own queue" || bad "branches share a key"
git -C "$TMP/w2" remote set-url origin "$TMP/origin.git/"
[ "$(merge_queue_key "$TMP/w2" master)" = "$K1" ] && ok "a trailing slash on the URL does not split the queue" || bad "trailing slash changed the key"
git init -q "$TMP/noremote"
[ -n "$(merge_queue_key "$TMP/noremote" master)" ] && ok "a checkout without origin still gets a key" || bad "no key without origin"

# ── release is idempotent, and a released lock is free at once ──────────────
( merge_queue_acquire "$TMP/w1" master 1 >/dev/null; merge_queue_release; merge_queue_release
  flock -n "$AUTOCODER_TMP/autocoder-land-${K1}.lock" true ) \
  && ok "release frees the lock and can be called twice" || bad "lock still held after release"

# ── the job never holds the lock itself, so nothing it spawns can inherit it ─
( merge_queue_acquire "$TMP/w1" master 5 >/dev/null
  LEAK=$(ls -l /proc/$BASHPID/fd 2>/dev/null | grep -c "autocoder-land-${K1}.lock")
  merge_queue_release; [ "$LEAK" = "0" ] ) \
  && ok "the acquiring shell has no descriptor on the lock" || bad "the job itself holds the lock fd (children would inherit it)"

# ── a job killed with SIGKILL gives up its place within a couple of seconds ─
( merge_queue_acquire "$TMP/w1" master 6 >/dev/null; sleep 30 ) &
VICTIM=$!; sleep 1
flock -n "$AUTOCODER_TMP/autocoder-land-${K1}.lock" true && bad "lock was not held by the live job" || ok "the live job holds its place"
kill -9 "$VICTIM"; wait "$VICTIM" 2>/dev/null
flock -w 4 "$AUTOCODER_TMP/autocoder-land-${K1}.lock" true && ok "a SIGKILLed job's place is released" || bad "a dead job kept the queue blocked"
ls "$AUTOCODER_TMP"/autocoder-land-"${K1}".?????? "$AUTOCODER_TMP/autocoder-land-${K1}.holder" >/dev/null 2>&1 \
  && bad "a SIGKILLed job left its scratch dir or holder file" || ok "a SIGKILLed job's leftovers are tidied by its holder"

# ── a symlink planted at the holder path is replaced, never written through ─
echo precious > "$TMP/victim"
ln -sf "$TMP/victim" "$AUTOCODER_TMP/autocoder-land-${K1}.holder"
( merge_queue_acquire "$TMP/w1" master 7 >/dev/null; merge_queue_release )
[ "$(cat "$TMP/victim")" = "precious" ] && ok "a planted holder symlink is not followed" || bad "holder write followed a symlink: $(cat "$TMP/victim")"

# ── a hostile holder file cannot inject control sequences into the log ──────
printf 'evil\033[2Jline\nsecond line\n' > "$AUTOCODER_TMP/autocoder-land-${K1}.holder"
flock "$AUTOCODER_TMP/autocoder-land-${K1}.lock" sleep 3 &
H2=$!; sleep 0.3
OUT=$(AUTOCODER_MERGE_QUEUE_WAIT=1 merge_queue_acquire "$TMP/w1" master 8)
kill "$H2" 2>/dev/null; wait "$H2" 2>/dev/null
printf '%s' "$OUT" | grep -q $'\033' && bad "escape sequence from the holder file reached the log" || ok "holder text is sanitised"
printf '%s' "$OUT" | grep -q "second line" && bad "multi-line holder text reached the log" || ok "holder text is one line"

TOTAL=$((PASS + FAIL))
echo "$PASS passed / $FAIL failed / $TOTAL total"
[ "$FAIL" -eq 0 ]
