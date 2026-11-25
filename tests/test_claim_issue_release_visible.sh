#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255: never write the real event logs
# claim-issue.sh releases visibly when it refuses an issue over a stale start comment (#402).
#
# A work-started comment with no 🔓, 🚫 or 🎨 after it counts in every later claim window
# (claim-window.sh rule 1). When claim-issue.sh refused on that count it dropped the
# `working` label and posted nothing, so nothing ever ended the window: every later
# claimant refused for the same reason and the issue bounced between the fix-loop gate and
# the worker until a person stepped in. The refusal now posts the 🔓 release comment in the
# same step, and the next claim starts from a clean window. A genuine race (a second live
# claim marker) is unchanged: it refuses without a 🔓.
#
# Drives claim-issue.sh against a fake GitHub backend in a private temp repo, as
# test_claim_window.sh does; nothing reaches the real tracker (a fake `gh` fails loudly).

set -uo pipefail

PASS=0
FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$ROOT/plugins/autocoder/scripts"

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want '$2', got '$3'"; fi; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export TMPDIR="$TMP"

# issue_json "<createdAt>|<body>" ...  → issue #144, labelled P2, with those comments
issue_json() {
  python3 - "$@" <<'PY'
import json, sys
cs = []
for a in sys.argv[1:]:
    t, _, b = a.partition("|")
    cs.append({"body": b, "createdAt": t} if t else {"body": b})
print(json.dumps({"number": 144, "title": "Issue 144", "body": "", "state": "OPEN",
                  "labels": [{"name": "P2"}], "comments": cs}))
PY
}

START='🤖 **Automated Fix Started**

**Branch**: `feature/issue-144`'
MARK='🔒 [autocoder-claim] Starting fix for issue #144 — lock established'

# ── the fake backend: one stateful issue in $FAKE_JSON; comments get a server timestamp
FAKE="$TMP/scripts"
cp -R "$SCRIPT_DIR" "$FAKE"
cat > "$FAKE/issues-gh.sh" <<'GH'
#!/bin/bash
verb="$1"; shift
echo "$verb $*" >> "$FAKE_LOG"
case "$verb" in
  get) cat "$FAKE_JSON" ;;
  list) jq -c '[.]' "$FAKE_JSON" ;;
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
  claim|release|update)
    python3 - "$FAKE_JSON" "$verb" "$@" <<'PY'
import json, sys
p, verb, args = sys.argv[1], sys.argv[2], sys.argv[3:]
d = json.load(open(p))
names = [l["name"] for l in d["labels"]]
if verb == "claim":
    names.append("working")
if verb == "release":
    names = [n for n in names if n != "working"]
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
cp "$FAKE/issues-gh.sh" "$FAKE/issues-jira.sh"   # the same fake behind a non-GitHub backend name
# What claim-issue.sh read from the window, one line per call.
mv "$FAKE/claim-window.sh" "$FAKE/claim-window-real.sh"
cat > "$FAKE/claim-window.sh" <<'CW'
#!/bin/bash
out=$(bash "$(dirname "$0")/claim-window-real.sh" "$@")
echo "$out" >> "$WINDOW_LOG"
echo "$out"
CW
chmod +x "$FAKE/claim-window.sh"
mkdir -p "$TMP/bin"
printf '#!/bin/sh\necho "$*" >> "$GH_CALLS"\nexit 1\n' > "$TMP/bin/gh"
printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/sleep"
chmod +x "$TMP/bin/gh" "$TMP/bin/sleep"
export GH_CALLS="$TMP/gh-calls" FAKE_LOG="$TMP/gh.log" FAKE_JSON="$TMP/issue.json" WINDOW_LOG="$TMP/window.log" AUTOCODER_IGNORE_DEPENDENCIES=1

git init -q --bare -b master "$TMP/origin.git"
git clone -q "$TMP/origin.git" "$TMP/repo" 2>/dev/null
cd "$TMP/repo" || exit 1
git config user.email test@example.com
git config user.name Test
git checkout -q -b master
echo '{"issueSource": "github"}' > .autocoder.json
git add .autocoder.json && git commit -q -m init && git push -q origin master

run_claim() { # run_claim [ISSUE_NUMBER]
  git checkout -q master
  git branch -q -D feature/issue-144 2>/dev/null || true
  rm -f "$(git rev-parse --absolute-git-dir)/autocoder-worker-state"
  : > "$FAKE_LOG"; : > "$WINDOW_LOG"
  OUTPUT=$(PATH="$TMP/bin:$PATH" INTEGRATION_BRANCH=master bash "$FAKE/claim-issue.sh" --out "$TMP/claim.env" "$@" 2>&1)
  RC=$?
}
status() { echo "$RC $(sed -n 's/^CLAIM_STATUS=//p' "$TMP/claim.env")"; }
labels() { jq -r '[.labels[].name] | join(" ")' "$FAKE_JSON"; }
last_comment() { jq -r '.comments[-1].body' "$FAKE_JSON"; }
count_releases() { jq '[.comments[].body | select(startswith("🔓"))] | length' "$FAKE_JSON"; }
stale_start() { issue_json "2026-11-17T02:26:57Z|$START" > "$FAKE_JSON"; }

# ── 1. a named issue (/fix 144) whose only claim evidence is a stale start comment
stale_start
run_claim 144
assert_eq "stale start, first run: refused (exit 1)" 1 "$RC"
case "$(last_comment)" in
  "🔓 **Releasing claim**"*) ok "stale start, first run: the comments end with a 🔓 release" ;;
  *) bad "stale start, first run: last comment is not a release: $(last_comment)" ;;
esac
last_comment | grep -q 'earlier run has no release after it' \
  && ok "stale start, first run: the release says why" || bad "stale start, first run: no reason in: $(last_comment)"
last_comment | grep -q '^\*\*Worker\*\*: `claim-id=' \
  && ok "stale start, first run: the release names this run's claim" || bad "stale start, first run: no worker in: $(last_comment)"
assert_eq "stale start, first run: working removed" "P2" "$(labels)"
run_claim 144
assert_eq "stale start, second run: claimed" "0 claimed" "$(status)"
assert_eq "stale start, second run: the window held only its own marker" "1 0" "$(tail -n 1 "$WINDOW_LOG")"
assert_eq "stale start, second run: holds working" "P2 working" "$(labels)"
assert_eq "stale start, second run: on the fix branch" feature/issue-144 "$(git branch --show-current)"

# ── 2. the same issue picked from the queue (/fix with no number)
stale_start
run_claim
assert_eq "queue pick, first run: refused, nothing else to claim (idle)" "0 idle" "$(status)"
case "$(last_comment)" in
  "🔓 **Releasing claim**"*) ok "queue pick, first run: the comments end with a 🔓 release" ;;
  *) bad "queue pick, first run: last comment is not a release: $(last_comment)" ;;
esac
assert_eq "queue pick, first run: working removed" "P2" "$(labels)"
run_claim
assert_eq "queue pick, second run: claimed" "0 claimed" "$(status)"
assert_eq "queue pick, second run: the window held only its own marker" "1 0" "$(tail -n 1 "$WINDOW_LOG")"

# ── 3. a genuine race still refuses without a 🔓 (behaviour pinned, not changed)
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
issue_json "$NOW|$MARK (claim-id=rival)" > "$FAKE_JSON"
run_claim 144
assert_eq "live rival marker: refused (exit 1)" 1 "$RC"
assert_eq "live rival marker: no 🔓 posted" 0 "$(count_releases)"
assert_eq "live rival marker: the window read two markers" "2 0" "$(tail -n 1 "$WINDOW_LOG")"
issue_json "2026-11-17T02:26:57Z|$START" "$NOW|$MARK (claim-id=rival)" > "$FAKE_JSON"
run_claim 144
assert_eq "live rival marker and a stale start: refused (exit 1)" 1 "$RC"
assert_eq "live rival marker and a stale start: no 🔓 posted" 0 "$(count_releases)"
issue_json "$NOW|$MARK (claim-id=rival)" > "$FAKE_JSON"
run_claim
assert_eq "queue pick, live rival marker: no 🔓 posted" 0 "$(count_releases)"

# ── 4. a non-GitHub backend's orphaned start comment: released visibly too
echo '{"issueSource": "jira"}' > .autocoder.json
stale_start
run_claim 144
assert_eq "non-GitHub stale start: refused (exit 1)" 1 "$RC"
case "$(last_comment)" in
  "🔓 **Releasing claim**"*) ok "non-GitHub stale start: the comments end with a 🔓 release" ;;
  *) bad "non-GitHub stale start: last comment is not a release: $(last_comment)" ;;
esac
assert_eq "non-GitHub stale start: working removed" "P2" "$(labels)"
echo '{"issueSource": "github"}' > .autocoder.json

[ -s "$GH_CALLS" ] && bad "real gh was invoked: $(cat "$GH_CALLS")" || ok "no real gh call"

echo ""
echo "Tests: $FAIL failed, $PASS passed, $((PASS + FAIL)) total"
[ "$FAIL" -eq 0 ]
