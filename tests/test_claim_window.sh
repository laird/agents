#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255: never write the real event logs
# claim-window.sh and claim-issue.sh's GitHub race check (#309). An abandoned run's
# start comment, or the marker of a worker that lost a race, must not refuse an
# issue forever once a release or a block has ended that claim (#144). A rival's
# live claim must still refuse it.
#
# The end-to-end part drives claim-issue.sh against a fake GitHub backend in a
# private temp repo; nothing reaches the real tracker (a fake `gh` fails loudly).

set -uo pipefail

PASS=0
FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$ROOT/plugins/autocoder/scripts"
WIN="$SCRIPT_DIR/claim-window.sh"

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want '$2', got '$3'"; fi; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export TMPDIR="$TMP"

# issue_json "<createdAt>|<body>" ...  → an issue JSON with those comments
issue_json() {
  python3 - "$@" <<'PY'
import json, sys
cs = []
for a in sys.argv[1:]:
    t, _, b = a.partition("|")
    c = {"body": b}
    if t:
        c["createdAt"] = t
    cs.append(c)
print(json.dumps({"number": 144, "state": "OPEN", "labels": [{"name": "P2"}], "comments": cs}))
PY
}
win() { issue_json "${@:2}" | bash "$WIN" $1; }

START='🤖 **Automated Fix Started**

**Branch**: `feature/issue-144`'
MARK='🔒 [autocoder-claim] Starting fix for issue #144 — lock established'
REL='🔓 **Releasing claim**'

# ── 1. the window starts after the last release or block
assert_eq "no comments" "0 0" "$(win "")"
assert_eq "old start comment, no ender: still counts (live claim)" "0 1" \
  "$(win "" "2026-11-17T02:26:57Z|$START")"
assert_eq "old start comment ended by a 🎨 block: not counted (#144)" "0 0" \
  "$(win "" "2026-11-17T02:26:57Z|$START" "2026-11-17T02:27:53Z|🎨 **Blocked — Needs Design**")"
assert_eq "old start comment ended by a 🚫 block: not counted" "0 0" \
  "$(win "" "2026-11-17T02:26:57Z|$START" "2026-11-17T02:27:53Z|🚫 **Blocked - Requires Human Input**")"
assert_eq "old start comment ended by a 🔓 release: not counted" "0 0" \
  "$(win "" "2026-11-17T02:26:57Z|$START" "2026-11-17T03:00:00Z|$REL")"
assert_eq "a start comment after the release counts" "0 1" \
  "$(win "" "2026-11-17T02:26:57Z|$START" "2026-11-17T03:00:00Z|$REL" "2026-11-17T04:00:00Z|$START")"
assert_eq "markers before a release are not counted" "1 0" \
  "$(win "" "2026-11-22T00:12:32Z|$MARK" "2026-11-22T00:13:49Z|$REL" "2026-11-22T00:20:39Z|$MARK")"
assert_eq "a marker is not a start comment" "1 0" "$(win "" "2026-11-22T00:20:39Z|$MARK")"

# ── 2. --own anchors the window on this run's marker
assert_eq "two markers seconds apart: a race" "2 0" \
  "$(win "--own id=B" "2026-11-22T00:20:39Z|$MARK (id=A)" "2026-11-22T00:20:40Z|$MARK (id=B)")"
assert_eq "a rival marker after ours counts" "2 0" \
  "$(win "--own id=A" "2026-11-22T00:20:39Z|$MARK (id=A)" "2026-11-22T00:20:41Z|$MARK (id=B)")"
assert_eq "a release posted after our marker does not hide the rival's marker" "2 0" \
  "$(win "--own id=B" "2026-11-22T00:20:39Z|$MARK (id=A)" "2026-11-22T00:20:40Z|$MARK (id=B)" "2026-11-22T00:20:44Z|$REL")"
assert_eq "a backed-off marker 10 minutes before ours is stale" "1 0" \
  "$(win "--own id=B" "2026-11-22T00:10:00Z|$MARK (id=A)" "2026-11-22T00:20:00Z|$MARK (id=B)")"
assert_eq "--race-window widens the window" "2 0" \
  "$(win "--own id=B --race-window 900" "2026-11-22T00:10:00Z|$MARK (id=A)" "2026-11-22T00:20:00Z|$MARK (id=B)")"
assert_eq "a stale marker that went on to start still refuses via its start comment" "1 1" \
  "$(win "--own id=B" "2026-11-22T00:10:00Z|$MARK (id=A)" "2026-11-22T00:10:09Z|$START" "2026-11-22T00:20:00Z|$MARK (id=B)")"
assert_eq "a marker with no timestamp always counts" "2 0" \
  "$(win "--own id=B" "|$MARK (id=A)" "2026-11-22T00:20:00Z|$MARK (id=B)")"
assert_eq "fractional-second timestamps parse" "1 0" \
  "$(win "--own id=B" "2026-11-22T00:10:00.123Z|$MARK (id=A)" "2026-11-22T00:20:00.456Z|$MARK (id=B)")"
assert_eq "own marker missing: every marker in the window counts" "2 0" \
  "$(win "--own id=Z" "2026-11-22T00:10:00Z|$MARK (id=A)" "2026-11-22T00:20:00Z|$MARK (id=B)")"

# ── 3. --branch and bad input
assert_eq "--branch keeps start comments naming the branch" "0 1" \
  "$(win "--branch feature/issue-144" "|$START")"
assert_eq "--branch drops start comments for another branch" "0 0" \
  "$(win "--branch feature/issue-9" "|$START")"
assert_eq "unparseable input: 0 0" "0 0" "$(echo 'not json' | bash "$WIN")"
bash "$WIN" --bogus </dev/null >/dev/null 2>&1; assert_eq "unknown argument: exit 2" 2 "$?"
bash "$WIN" --race-window abc </dev/null >/dev/null 2>&1; assert_eq "non-numeric --race-window: exit 2" 2 "$?"

# ── 4. claim-issue.sh end to end on a fake GitHub backend
FAKE="$TMP/scripts"
cp -R "$SCRIPT_DIR" "$FAKE"
cat > "$FAKE/issues-gh.sh" <<'GH'
#!/bin/bash
# Stateful fake: one issue in $FAKE_JSON; comments get a server timestamp.
verb="$1"; shift
echo "$verb $*" >> "$FAKE_LOG"
case "$verb" in
  get) cat "$FAKE_JSON" ;;
  comment)
    body=""; while [ $# -gt 0 ]; do [ "$1" = --body ] && body="$2"; shift; done
    python3 - "$FAKE_JSON" "$body" <<'PY'
import json, sys, datetime
p, b = sys.argv[1], sys.argv[2]
d = json.load(open(p))
d["comments"].append({"body": b, "createdAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")})
json.dump(d, open(p, "w"))
PY
    ;;
  claim|update)
    python3 - "$FAKE_JSON" "$verb" "$@" <<'PY'
import json, sys
p, verb, args = sys.argv[1], sys.argv[2], sys.argv[3:]
d = json.load(open(p))
names = [l["name"] for l in d["labels"]]
if verb == "claim":
    names.append("working")
for i, a in enumerate(args):
    if a == "--add-label": names.append(args[i + 1])
    if a == "--remove-label": names = [n for n in names if n != args[i + 1]]
d["labels"] = [{"name": n} for n in dict.fromkeys(names)]
json.dump(d, open(p, "w"))
PY
    ;;
  *) exit 0 ;;
esac
GH
chmod +x "$FAKE/issues-gh.sh"
mkdir -p "$TMP/bin"
printf '#!/bin/sh\necho "fake gh: refusing $*" >&2\nexit 1\n' > "$TMP/bin/gh"
printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/sleep"
chmod +x "$TMP/bin/gh" "$TMP/bin/sleep"
export FAKE_LOG="$TMP/gh.log" FAKE_JSON="$TMP/issue.json" AUTOCODER_IGNORE_DEPENDENCIES=1

git init -q --bare -b master "$TMP/origin.git"
git clone -q "$TMP/origin.git" "$TMP/repo" 2>/dev/null
cd "$TMP/repo" || exit 1
git config user.email test@example.com
git config user.name Test
git checkout -q -b master
echo '{"issueSource": "github"}' > .autocoder.json
git add .autocoder.json && git commit -q -m init && git push -q origin master

run_claim() {
  git checkout -q master
  git branch -q -D feature/issue-144 2>/dev/null || true
  : > "$FAKE_LOG"
  OUTPUT=$(PATH="$TMP/bin:$PATH" INTEGRATION_BRANCH=master bash "$FAKE/claim-issue.sh" --out "$TMP/claim.env" 144 2>&1)
  RC=$?
}
labels() { jq -r '[.labels[].name] | join(" ")' "$FAKE_JSON"; }

# 4a. #144's shape: an abandoned start comment ended by a block, then two markers
#     from refused runs ended by releases. The claim now succeeds.
issue_json "2026-11-17T02:26:57Z|$START" "2026-11-17T02:27:53Z|🎨 **Blocked — Needs Design**" \
  "2026-11-22T00:12:32Z|$MARK" "2026-11-22T00:13:49Z|$REL" \
  "2026-11-22T00:20:39Z|$MARK" "2026-11-22T00:21:00Z|$MARK" "2026-11-22T00:21:34Z|$REL" > "$FAKE_JSON"
run_claim
assert_eq "e2e #144 shape: claimed (exit 0)" 0 "$RC"
assert_eq "e2e #144 shape: on the fix branch" feature/issue-144 "$(git branch --show-current)"
assert_eq "e2e #144 shape: holds working" "P2 working" "$(labels)"
jq -r '.comments[-2].body' "$FAKE_JSON" | grep -q 'lock established (claim-id=' \
  && ok "e2e: marker carries this run's claim id" || bad "e2e: marker has no claim id: $(jq -r '.comments[-2].body' "$FAKE_JSON")"
jq -r '.comments[-1].body' "$FAKE_JSON" | grep -q 'Automated Fix Started' \
  && ok "e2e: start comment posted" || bad "e2e: no start comment"

# 4b. A rival's live claim (its start comment, no release since): refused.
issue_json "2026-11-17T02:26:57Z|$START" > "$FAKE_JSON"
run_claim
assert_eq "e2e live rival: refused (exit 1)" 1 "$RC"
printf '%s' "$OUTPUT" | grep -q 'started: 1 since the last release' \
  && ok "e2e live rival: says why" || bad "e2e live rival: message: $OUTPUT"
assert_eq "e2e live rival: still on master" master "$(git branch --show-current)"

# 4c. A rival marker posted moments ago: a race, refused.
issue_json "$(date -u +%Y-%m-%dT%H:%M:%SZ)|$MARK (claim-id=rival)" > "$FAKE_JSON"
run_claim
assert_eq "e2e fresh rival marker: refused (exit 1)" 1 "$RC"

# 4d. The pre-claimed handoff (the gate holds `working`): an ended start comment
#     on the branch no longer reads as another agent's lock.
issue_json "2026-11-17T02:26:57Z|$START" "2026-11-17T02:27:53Z|🎨 **Blocked — Needs Design**" \
  "2026-11-22T00:30:00Z|🔒 claim example-host 1795307845997 wt=/x" > "$FAKE_JSON"
jq '.labels += [{"name": "working"}]' "$FAKE_JSON" > "$FAKE_JSON.t" && mv "$FAKE_JSON.t" "$FAKE_JSON"
run_claim
assert_eq "e2e handoff with an ended start comment: claimed" 0 "$RC"
# That claim recorded #144 for this worktree (worker-state-fns.sh): a run from here would now RESUME it,
# and its start comment would be its own. The live-rival case is a worktree with NO record of #144.
rm -f "$(git rev-parse --absolute-git-dir)/autocoder-worker-state"
issue_json "2026-11-17T02:26:57Z|$START" > "$FAKE_JSON"
jq '.labels += [{"name": "working"}]' "$FAKE_JSON" > "$FAKE_JSON.t" && mv "$FAKE_JSON.t" "$FAKE_JSON"
run_claim
assert_eq "e2e handoff with a live start comment: refused" 1 "$RC"
printf '%s' "$OUTPUT" | grep -q 'already has a start marker' \
  && ok "e2e handoff live: start-marker message" || bad "e2e handoff live: message: $OUTPUT"

grep -q '^fake gh' "$FAKE_LOG" 2>/dev/null && bad "real gh was invoked" || ok "no real gh call"

echo ""
echo "Tests: $FAIL failed, $PASS passed, $((PASS + FAIL)) total"
[ "$FAIL" -eq 0 ]
