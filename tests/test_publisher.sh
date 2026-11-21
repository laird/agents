#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"
# tests/test_publisher.sh — publisher.sh, the one writer of the integration branch: the host and ref
# leases, ff and merge landing, the documents/mechanical fast lane (with and without a batch in
# flight), a stale tip recorded as a rejection, and the health check. Every case runs against a
# fixture bare origin; nothing is pushed anywhere else.

PASS=0; FAIL=0
PUB="$(cd "$(dirname "$0")/.." && pwd)/plugins/autocoder/scripts/publisher.sh"
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want '$2', got '$3'"; fi; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"; [ -n "${HOLDER:-}" ] && kill "$HOLDER" 2>/dev/null' EXIT
export AUTOCODER_PUBLISH_STATE="$TMP/state" AUTOCODER_LANDING_TIMINGS="$TMP/timings.jsonl"
export AUTOCODER_LANDING_WAIT_SECONDS=20 AUTOCODER_FASTLANE_CHECK_CMD=true
export AUTOCODER_LANDING_LEASE_EMPTYCASE="$TMP/empty-case.lease"
unset AUTOCODER_REF_LEASE AUTOCODER_FASTLANE_PATHS AUTOCODER_DOCS_PATHS AUTOCODER_DOCS_CODE_PATHS AUTOCODER_PUBLISH_MODE
export GIT_AUTHOR_NAME=T GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=T GIT_COMMITTER_EMAIL=t@example.com

ORIGIN="$TMP/origin.git"; W="$TMP/w"
git init -q --bare "$ORIGIN"
git init -q "$W"; git -C "$W" remote add origin "$ORIGIN"
printf 'base\n' > "$W/README.md"; mkdir "$W/docs" "$W/src"; echo a > "$W/docs/a.md"; echo c > "$W/src/code.txt"
git -C "$W" add -A; git -C "$W" commit -q -m init; git -C "$W" branch -M master; git -C "$W" push -q origin master

pub() { bash "$PUB" "$@" --repo "$W" --branch master 2>"$TMP/err"; }
tip() { git --git-dir "$ORIGIN" rev-parse master; }
# mk <branch> <file> <content> [base]: a pushed branch with one commit off base (default origin/master); prints its sha
mk() {
  git -C "$W" fetch -q origin master
  git -C "$W" checkout -q -B "$1" "${4:-origin/master}"
  mkdir -p "$(dirname "$W/$2")"; printf '%s\n' "$3" > "$W/$2"
  git -C "$W" add -A; git -C "$W" commit -q -m "change $1"; git -C "$W" push -q -f origin "$1"
  git -C "$W" rev-parse HEAD
}
rows() { python3 - "$AUTOCODER_LANDING_TIMINGS" <<'PY'
import json, sys
try: lines = open(sys.argv[1]).read().splitlines()
except FileNotFoundError: lines = []
for l in lines:
    r = json.loads(l)
    if r["kind"] == "change": print("change", r["issue"], r["event"], r["cause"] or "-")
    else: print("batch", ",".join(map(str, r["members"])), r["verdict"], r["cause"] or "-", "rej=%s" % r["push_rejected"], "pub=%s" % ("set" if r["publish_s"] is not None else "none"))
PY
}
reset_rows() { : > "$AUTOCODER_LANDING_TIMINGS"; }

# ── ff publish ────────────────────────────────────────────────────────────────
S1=$(mk f1 src/one.txt one)
pub publish --sha "$S1" --issues 11 >"$TMP/out"; RC=$?
eq "ff: a fast-forward gated commit lands (rc)" 0 "$RC"
eq "ff: origin carries the commit" "$S1" "$(tip)"
grep -q '^publish-result landed=1 .*push_rejected=0' "$TMP/out" && ok "ff: result line reports landed and no rejection" || bad "ff result: $(cat "$TMP/out")"
eq "ff: a batch row and a landed row are recorded" "batch 11 green - rej=0 pub=set
change 11 landed -" "$(rows)"

# ── stale ─────────────────────────────────────────────────────────────────────
reset_rows
S2=$(mk f2 src/two.txt two "$S1")        # based on S1
S3=$(mk f3 src/three.txt three "$S1")    # a sibling of S2
pub publish --sha "$S2" --issues 12 >/dev/null
pub publish --sha "$S3" --issues 13 >/dev/null; RC=$?
eq "stale: a sibling that no longer fast-forwards is returned (rc 3)" 3 "$RC"
eq "stale: origin is untouched by the rejected publish" "$S2" "$(tip)"
grep -q '^stale: .*not a fast-forward' "$TMP/err" && ok "stale: the reason names the moved branch" || bad "stale reason: $(cat "$TMP/err")"
eq "stale: the rejection is recorded as a returned change and an aborted batch" "batch 12 green - rej=0 pub=set
change 12 landed -
change 13 returned stale-base
batch 13 aborted stale-base rej=0 pub=set" "$(rows)"

# ── merge mode: documents arrived, code arrived ──────────────────────────────
S4=$(mk f4 src/four.txt four "$S2")                       # gated on S2
D1=$(mk d1 docs/late.md late "$S2"); git -C "$W" push -q origin "$D1:refs/heads/master"   # documents land under the gate
out=$(pub publish --sha "$S4" --mode merge --issues 14); RC=$?
eq "merge: documents that arrived under the gate are merged and landed" 0 "$RC"
eq "merge: the published tree has both" "four late" "$(git --git-dir "$ORIGIN" show master:src/four.txt)$(printf ' '; git --git-dir "$ORIGIN" show master:docs/late.md)"
grep -q 'basis=docs-resync' <<<"$out" && ok "merge: basis recorded as docs-resync" || bad "basis: $out"
S5=$(mk f5 src/five.txt five "$(tip)")
C1=$(mk c1 src/other.txt other "$(tip)"); git -C "$W" push -q origin "$C1:refs/heads/master"
S6=$(mk f6 src/six.txt six "$S5")                         # gated before C1 landed
pub publish --sha "$S6" --mode merge --issues 15 >/dev/null; RC=$?
eq "merge: code that arrived untested forces a re-gate (rc 3)" 3 "$RC"
grep -q 'src/other.txt' "$TMP/err" && ok "merge: the message names the untested file" || bad "msg: $(cat "$TMP/err")"

# ── two publishers racing ────────────────────────────────────────────────────
reset_rows
B=$(tip)
RA=$(mk ra docs/ra.md ra "$B"); RB=$(mk rb docs/rb.md rb "$B")
( pub publish --sha "$RA" --mode merge --issues 21 >/dev/null; echo $? >"$TMP/ra.rc" ) &
( pub publish --sha "$RB" --mode merge --issues 22 >/dev/null; echo $? >"$TMP/rb.rc" ) &
wait
eq "race: both publishers land" "0 0" "$(cat "$TMP/ra.rc") $(cat "$TMP/rb.rc")"
git --git-dir "$ORIGIN" show master:docs/ra.md >/dev/null 2>&1 && git --git-dir "$ORIGIN" show master:docs/rb.md >/dev/null 2>&1 && ok "race: origin carries both changes" || bad "race: a change is missing"
eq "race: no push was rejected" "0" "$(rows | grep -c 'rej=[1-9]')"

# ── two hosts: the ref lease ─────────────────────────────────────────────────
export AUTOCODER_REF_LEASE=on
R1=$(mk h1 docs/h1.md h1 "$(tip)"); R2=$(mk h2 docs/h2.md h2 "$R1")
LEASEREF=refs/autocoder/landing-lease/master
( AUTOCODER_LANDING_LEASE="$TMP/hostA.lease" bash "$PUB" publish --sha "$R1" --repo "$W" --branch master >/dev/null 2>&1; echo $? >"$TMP/h1.rc" ) &
( AUTOCODER_LANDING_LEASE="$TMP/hostB.lease" bash "$PUB" publish --sha "$R2" --repo "$W" --branch master --mode merge >/dev/null 2>&1; echo $? >"$TMP/h2.rc" ) &
wait
eq "ref lease: two hosts with separate host leases both finish" "0" "$(cat "$TMP/h1.rc")"
[ "$(cat "$TMP/h2.rc")" = 0 ] || [ "$(cat "$TMP/h2.rc")" = 3 ] && ok "ref lease: the second publisher finished with a clean verdict" || bad "second rc $(cat "$TMP/h2.rc")"
eq "ref lease: released after the publish" "" "$(git --git-dir "$ORIGIN" for-each-ref "$LEASEREF")"
# A held, unexpired lease blocks; an expired one is taken over.
mklease() {  # <expires epoch>
  local c; c=$(printf 'holder=other:1\nexpires=%s\n' "$1" | git -C "$W" commit-tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904)
  git -C "$W" push -q -f origin "$c:$LEASEREF"
}
mklease $(( $(date +%s) + 600 ))
R3=$(mk h3 docs/h3.md h3 "$(tip)")
AUTOCODER_LANDING_WAIT_SECONDS=3 pub publish --sha "$R3" >/dev/null; RC=$?
eq "ref lease: a live lease held elsewhere is waited for, then refused (rc 5)" 5 "$RC"
mklease $(( $(date +%s) - 10 ))
pub publish --sha "$R3" >/dev/null; RC=$?
eq "ref lease: an expired lease is taken over (rc)" 0 "$RC"
grep -q 'expired' "$TMP/err" && ok "ref lease: the takeover is announced" || bad "takeover: $(cat "$TMP/err")"
eq "ref lease: gone after the takeover publish" "" "$(git --git-dir "$ORIGIN" for-each-ref "$LEASEREF")"
unset AUTOCODER_REF_LEASE

# ── fast lane, no batch in flight ────────────────────────────────────────────
reset_rows
FD=$(mk fd docs/fast.md fast "$(tip)")
out=$(pub enqueue --sha "$FD" --issue 31 --timeout 60); RC=$?
eq "fast lane: a documents change lands at once when no batch is in flight" 0 "$RC"
eq "fast lane: it is on origin" "fast" "$(git --git-dir "$ORIGIN" show master:docs/fast.md)"
grep -q "^landed $(tip)" <<<"$out" && ok "fast lane: the command reports the landed commit" || bad "enqueue out: $out"
eq "fast lane: ready, then landed in its own batch" "change 31 ready -
batch 31 green - rej=0 pub=set
change 31 landed -" "$(rows)"
CODE=$(mk fc src/nope.txt nope "$(tip)")
pub enqueue --sha "$CODE" --issue 32 --no-wait >/dev/null; RC=$?
eq "fast lane: a code change is not eligible (rc 6)" 6 "$RC"
grep -q 'src/nope.txt' "$TMP/err" && ok "fast lane: the refusal names the file" || bad "refusal: $(cat "$TMP/err")"
git -C "$W" checkout -q -B unpushed "$(tip)"; echo x > "$W/docs/u.md"; git -C "$W" add -A; git -C "$W" commit -q -m u
pub enqueue --sha unpushed --issue 33 --no-wait >/dev/null; RC=$?
eq "fast lane: an unpushed commit is refused (rc 6)" 6 "$RC"

# ── fast lane, batch in flight: rides with the next publish ─────────────────
sleep 300 & HOLDER=$!
pub batch-begin --pid "$HOLDER" --batch b1 >/dev/null
FD2=$(mk fd2 docs/ride.md ride "$(tip)")
pub enqueue --sha "$FD2" --issue 34 --no-wait >"$TMP/out"; RC=$?
eq "fast lane: with a batch in flight the entry waits (rc 0)" 0 "$RC"
grep -q '^pending' "$TMP/out" && ok "fast lane: reported pending" || bad "pending: $(cat "$TMP/out")"
git --git-dir "$ORIGIN" show master:docs/ride.md >/dev/null 2>&1 && bad "fast lane: landed under a batch in flight" || ok "fast lane: nothing pushed while the batch is in flight"
pub status | grep -q '#34 pending' && ok "status lists the pending entry" || bad "status: $(pub status)"
BATCHSHA=$(mk gb src/batch.txt batch "$(tip)")
pub publish --sha "$BATCHSHA" --batch b1 --issues 35 >"$TMP/out"; RC=$?
eq "ride: the gated batch lands" 0 "$RC"
eq "ride: the documents rode in the same push" "ride" "$(git --git-dir "$ORIGIN" show master:docs/ride.md)"
eq "ride: and the gated change is there too" "batch" "$(git --git-dir "$ORIGIN" show master:src/batch.txt)"
grep -q 'fastlane=1' "$TMP/out" && ok "ride: the result line counts one fast lane change" || bad "result: $(cat "$TMP/out")"
pub status | grep -q '#34 landed' && ok "ride: the entry is marked landed" || bad "entry state: $(pub status)"
eq "ride: a caller-supplied batch gets no second batch row from the publisher" "0" "$(rows | grep -c '^batch 35')"
pub batch-end >/dev/null 2>&1; RC=$?
eq "batch-end refuses while the batch pid is alive (rc 1)" 1 "$RC"
kill "$HOLDER"; wait "$HOLDER" 2>/dev/null; HOLDER=""
pub batch-end >/dev/null; eq "batch-end clears a finished batch" 0 "$?"

# ── fast lane failures ───────────────────────────────────────────────────────
reset_rows
X1=$(mk x1 docs/clash.md one "$(tip)"); X2=$(mk x2 docs/clash.md two "$(git -C "$W" rev-parse origin/master)")
pub enqueue --sha "$X1" --issue 41 --timeout 60 >/dev/null
pub enqueue --sha "$X2" --issue 42 --timeout 60 >/dev/null; RC=$?
eq "fast lane: a change that conflicts with what landed fails (rc 1)" 1 "$RC"
grep -q 'conflict' "$TMP/err" && ok "fast lane: the reason says conflict" || bad "reason: $(cat "$TMP/err")"
rows | grep -q '^change 42 returned conflict' && ok "fast lane: recorded as returned/conflict" || bad "rows: $(rows)"
BAD=$(mk bd docs/bad.md bad "$(tip)")
AUTOCODER_FASTLANE_CHECK_CMD=false pub enqueue --sha "$BAD" --issue 43 --timeout 60 >/dev/null; RC=$?
eq "fast lane: failing document checks keep the change off the branch (rc 1)" 1 "$RC"
git --git-dir "$ORIGIN" show master:docs/bad.md >/dev/null 2>&1 && bad "bad document landed" || ok "fast lane: nothing landed past a failed check"
# one bad entry costs only itself: enqueue under a batch, then drain with a check that rejects 'bad2' only
sleep 300 & HOLDER=$!; pub batch-begin --pid "$HOLDER" >/dev/null
G1=$(mk g1 docs/good1.md good1 "$(tip)"); G2=$(mk g2 docs/bad2.md bad2 "$(tip)")
pub enqueue --sha "$G1" --issue 44 --no-wait >/dev/null; pub enqueue --sha "$G2" --issue 45 --no-wait >/dev/null
kill "$HOLDER"; wait "$HOLDER" 2>/dev/null; HOLDER=""
AUTOCODER_FASTLANE_CHECK_CMD='test ! -e docs/bad2.md' pub drain >/dev/null; RC=$?
eq "drain: lands the good entry past the bad one" 0 "$RC"
git --git-dir "$ORIGIN" show master:docs/good1.md >/dev/null 2>&1 && ! git --git-dir "$ORIGIN" show master:docs/bad2.md >/dev/null 2>&1 && ok "drain: good1 landed, bad2 did not" || bad "drain landed the wrong set"
# an empty lane is the usual case at a train's batch end: drain says so and takes no lease (a held
# host lease would otherwise make it wait, then refuse with rc 5)
( exec 9>>"$AUTOCODER_LANDING_LEASE_EMPTYCASE"; flock 9; sleep 300 ) & HOLDER=$!
sleep 0.5
AUTOCODER_LANDING_LEASE="$AUTOCODER_LANDING_LEASE_EMPTYCASE" AUTOCODER_LANDING_WAIT_SECONDS=2 pub drain >"$TMP/out"; RC=$?
eq "drain: an empty lane is reported and takes no lease (rc 0 under a held lease)" 0 "$RC"
grep -q '^fast lane empty' "$TMP/out" && ok "drain: says the lane is empty" || bad "empty drain: $(cat "$TMP/out") $(cat "$TMP/err")"
kill "$HOLDER"; wait "$HOLDER" 2>/dev/null; HOLDER=""
pub status | grep -q '#45 failed .*document checks failed' && ok "drain: the bad entry is failed with its reason" || bad "status: $(pub status)"

pub batch-end >/dev/null; eq "batch-end clears the dead batch's marker" 0 "$?"

# ── mechanical paths ─────────────────────────────────────────────────────────
M1=$(mk m1 gen/registry.json '{}' "$(tip)")
pub enqueue --sha "$M1" --issue 46 --no-wait >/dev/null; RC=$?
eq "mechanical: a generated file is not eligible by default" 6 "$RC"
AUTOCODER_FASTLANE_PATHS='gen/*.json' pub enqueue --sha "$M1" --issue 46 --timeout 60 >/dev/null; RC=$?
eq "mechanical: AUTOCODER_FASTLANE_PATHS admits it and it lands" 0 "$RC"
# The project's code overrides win over the documents rule.
SK=$(mk sk docs/skill.md skill "$(tip)")
AUTOCODER_DOCS_CODE_PATHS='docs/skill.md' pub enqueue --sha "$SK" --issue 47 --no-wait >/dev/null; RC=$?
eq "overrides: AUTOCODER_DOCS_CODE_PATHS keeps a Markdown file off the lane" 6 "$RC"
AUTOCODER_DOCS_PATHS='*.json' pub enqueue --sha "$(mk wn wiki-nav.json '{}' "$(tip)")" --issue 48 --timeout 60 >/dev/null; RC=$?
eq "overrides: AUTOCODER_DOCS_PATHS admits a project's own document type" 0 "$RC"

# ── health ───────────────────────────────────────────────────────────────────
pub health >"$TMP/out"; RC=$?
eq "health: a quiet publisher is healthy" 0 "$RC"; [ "$RC" = 0 ] || cat "$TMP/out"
grep -q '^ok    fast lane empty' "$TMP/out" && ok "health: reports the empty fast lane" || bad "health: $(cat "$TMP/out")"
printf 'pid=999999\nbatch=dead\nstarted=1\n' > "$AUTOCODER_PUBLISH_STATE/inflight"
pub health >"$TMP/out"; RC=$?
eq "health: a batch marker naming a dead pid is a problem (rc 1)" 1 "$RC"
grep -q 'dead pid' "$TMP/out" && ok "health: names the remedy" || bad "health: $(cat "$TMP/out")"
rm -f "$AUTOCODER_PUBLISH_STATE/inflight"
printf 'issue=99\nsha=%s\nbranch=master\nstatus=pending\nenqueued_at=1\n' "$(tip)" > "$AUTOCODER_PUBLISH_STATE/fastlane/1-99-old.entry"
pub health >"$TMP/out"; RC=$?
eq "health: an old pending entry with no batch means the queue is down (rc 1)" 1 "$RC"
grep -q 'run .drain' "$TMP/out" && ok "health: points at the manual path" || bad "health: $(cat "$TMP/out")"
rm -f "$AUTOCODER_PUBLISH_STATE/fastlane/1-99-old.entry"
export AUTOCODER_REF_LEASE=on; mklease $(( $(date +%s) - 5 ))
pub health >"$TMP/out"; RC=$?
eq "health: an expired, unreleased ref lease is a problem (rc 1)" 1 "$RC"
pub lease-break >/dev/null; RC=$?
eq "lease-break removes an expired lease" 0 "$RC"
mklease $(( $(date +%s) + 600 ))
pub lease-break >/dev/null 2>&1; RC=$?
eq "lease-break refuses a live lease without --force (rc 1)" 1 "$RC"
pub lease-break --force >/dev/null; eq "lease-break --force removes it" "" "$(git --git-dir "$ORIGIN" for-each-ref "$LEASEREF")"
unset AUTOCODER_REF_LEASE

# ── usage ────────────────────────────────────────────────────────────────────
bash "$PUB" publish --repo "$W" >/dev/null 2>&1; eq "usage: publish without a branch is rc 2" 2 "$?"
bash "$PUB" publish --repo "$W" --branch master --sha nonsense >/dev/null 2>&1; eq "usage: an unknown sha is rc 2" 2 "$?"
bash "$PUB" nonsense >/dev/null 2>&1; eq "usage: an unknown command is rc 2" 2 "$?"

echo "Tests: $FAIL failed, $PASS passed, $((PASS + FAIL)) total"
[ "$FAIL" -eq 0 ]
