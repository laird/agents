#!/bin/bash
# tests/test_autocoder_ctl_issues.sh — autocoder-ctl's issue decisions (#245):
# approve, reject, request-changes and file, each through the dispatcher.
#
# Every verb runs against the file backend in a private temp repo with its own
# .autocoder.json, never the real tracker. Each call must print exactly one JSON
# result object and exit 0 ok / 1 failed / 2 usage, and every write names the actor.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$ROOT/plugins/autocoder/scripts"
CTL="$SCRIPTS/autocoder-ctl.sh"
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
unset ISSUE_SOURCE ISSUE_BACKEND ISSUE_DIR
# Events (#247) go to a private log, never the user's real state dir (#254).
export AUTOCODER_ISSUE_EVENTS="$TMP/issue-events.jsonl"
export AUTOCODER_CTL_ACTOR=dashboard-ui

# run <expected-rc> <expected-ok> <name> -- <cmd...>: one result object, the right
# exit code and ok, action set. Leaves the object in $OUT.
run() {
  local want_rc="$1" want_ok="$2" name="$3"; shift 4
  OUT=$("$@" 2>"$TMP/stderr"); local rc=$?
  if [ "$rc" -ne "$want_rc" ]; then bad "$name: exit $rc, want $want_rc (out: $OUT)"; return 1; fi
  if [ "$(printf '%s\n' "$OUT" | wc -l)" -ne 1 ] \
     || ! printf '%s' "$OUT" | jq -e --argjson ok "$want_ok" \
          'type == "object" and (keys == ["action","detail","ok","target"]) and .ok == $ok' >/dev/null 2>&1; then
    bad "$name: not one result object with ok=$want_ok: $OUT"; return 1
  fi
  ok "$name"
}

git init -q "$TMP/repo"; cd "$TMP/repo" || exit 1
git config user.email t@example.com; git config user.name T
printf '{"issueSource": "file"}\n' > .autocoder.json
echo a > a; git add -A; git commit -qm base
IF() { ( source "$SCRIPTS/issue-fns.sh" >/dev/null 2>&1; "$@" ); }
labels_of() { IF issue_get "$1" | jq -r '[.labels[] | (.name? // .)] | join(",")'; }
state_of()  { IF issue_get "$1" | jq -r '.state | ascii_downcase'; }
# The file backend appends comments to the body; other backends list them.
text_of()   { IF issue_get "$1" | jq -r '[.body, (.comments[]?.body)] | join("\n")'; }
new_issue() { IF issue_create --title "$1" --body "b" "${@:2}" | jq -r .number; }

# ── Usage errors: exit 2, and nothing touches the tracker ─────────────────────
run 2 false "approve with no issue"                 -- "$CTL" approve
run 2 false "approve with two issues"               -- "$CTL" approve 1 2
run 2 false "approve with a non-number"             -- "$CTL" approve abc
run 2 false "reject with no issue"                  -- "$CTL" reject
run 2 false "reject with too many arguments"        -- "$CTL" reject 1 a b
run 2 false "reject with a non-number"              -- "$CTL" reject -3
run 2 false "request-changes with no text"          -- "$CTL" request-changes 1
run 2 false "request-changes with blank text"       -- "$CTL" request-changes 1 "   "
run 2 false "request-changes with a non-number"     -- "$CTL" request-changes x "text"
run 2 false "file with no title"                    -- "$CTL" file --body b
run 2 false "file with a blank title"               -- "$CTL" file --title " "
run 2 false "file --label with no value"            -- "$CTL" file --title t --label
run 2 false "file with an unknown argument"         -- "$CTL" file --title t --assignee me
[ "$(jq -r .action <<<"$OUT")" = file ] && ok "the action is the verb" || bad "action: $OUT"
[ ! -e .issues/.seq ] || [ "$(cat .issues/.seq)" = "" ] && ok "usage errors created no issue" || bad "seq: $(cat .issues/.seq)"

# ── file ──────────────────────────────────────────────────────────────────────
run 0 true "file creates an issue" -- "$CTL" file --title "Add a dark mode" --body "Please." --label enhancement --label P3
F=$(jq -r .target <<<"$OUT")
jq -e --arg n "$F" '.target == $n and .detail.number == ($n | tonumber) and .detail.title == "Add a dark mode"
  and .detail.labels == ["enhancement","P3"] and .detail.actor == "dashboard-ui"' <<<"$OUT" >/dev/null \
  && ok "file reports the new number, title, labels and actor" || bad "file detail: $OUT"
[ "$(labels_of "$F")" = "enhancement,P3" ] && ok "the labels are on the issue" || bad "labels: $(labels_of "$F")"
text_of "$F" | grep -q '^Please\.$' && text_of "$F" | grep -q 'Filed by dashboard-ui via autocoder-ctl' \
  && ok "the body keeps the text and names the actor" || bad "body: $(text_of "$F")"
run 0 true "file with only a title" -- "$CTL" file --title "Bare"
jq -e '.detail.labels == []' <<<"$OUT" >/dev/null && ok "no labels is an empty list" || bad "bare: $OUT"
B=$(jq -r .target <<<"$OUT")
[ "$(IF issue_get "$B" | jq -r .body)" = "Filed by dashboard-ui via autocoder-ctl" ] \
  && ok "an empty body is just the actor line" || bad "bare body: $(text_of "$B")"

# ── approve ───────────────────────────────────────────────────────────────────
P=$(new_issue "Proposal: cache" --label enhancement --label proposal)
run 0 true "approve a proposal" -- "$CTL" approve "$P"
jq -e --arg n "$P" '.target == $n and .detail.approved and .detail.commented and .detail.actor == "dashboard-ui"' \
  <<<"$OUT" >/dev/null && ok "approve reports issue and actor" || bad "approve detail: $OUT"
[ "$(labels_of "$P")" = "enhancement" ] && ok "proposal is removed, other labels stay" || bad "labels: $(labels_of "$P")"
text_of "$P" | grep -q 'approved\*\* by dashboard-ui' && ok "the comment names the actor" || bad "approve comment: $(text_of "$P")"
[ "$(state_of "$P")" = open ] && ok "an approved proposal stays open" || bad "state: $(state_of "$P")"
run 1 false "approving it again fails: no longer a proposal" -- "$CTL" approve "$P"
run 1 false "approve a missing issue" -- "$CTL" approve 999

# ── request-changes ───────────────────────────────────────────────────────────
Q=$(new_issue "Proposal: queue" --label proposal)
run 0 true "request changes on a proposal" -- env -u AUTOCODER_CTL_ACTOR USER=someone "$CTL" request-changes "$Q" "Split it in two."
jq -e --arg n "$Q" '.target == $n and .detail.commented and .detail.proposal and .detail.actor == "someone"' \
  <<<"$OUT" >/dev/null && ok "request-changes reports the actor from \$USER" || bad "rc detail: $OUT"
labels_of "$Q" | grep -qx proposal && ok "proposal stays for /refine-proposal" || bad "labels: $(labels_of "$Q")"
text_of "$Q" | grep -q 'Changes requested\*\* by someone' && text_of "$Q" | grep -q 'Split it in two\.' \
  && ok "the comment names the actor and carries the text" || bad "rc comment: $(text_of "$Q")"
text_of "$Q" | grep -q "refine-proposal $Q" && ok "a proposal gets the /refine-proposal hint" || bad "hint: $(text_of "$Q")"
run 0 true "request changes on a non-proposal" -- "$CTL" request-changes "$F" "More detail."
jq -e '.detail.proposal == false' <<<"$OUT" >/dev/null && ok "detail says it is not a proposal" || bad "non-proposal: $OUT"
text_of "$F" | grep -q refine-proposal && bad "a non-proposal got the /refine-proposal hint" || ok "a non-proposal gets no /refine-proposal hint"
run 1 false "request changes on a missing issue" -- "$CTL" request-changes 999 "x"

# ── reject ────────────────────────────────────────────────────────────────────
run 0 true "reject with a reason" -- "$CTL" reject "$Q" "Out of scope"
jq -e --arg n "$Q" '.target == $n and .detail.closed and .detail.reason == "Out of scope" and .detail.actor == "dashboard-ui"' \
  <<<"$OUT" >/dev/null && ok "reject reports issue, actor and reason" || bad "reject detail: $OUT"
[ "$(state_of "$Q")" = closed ] && ok "the rejected issue is closed" || bad "state: $(state_of "$Q")"
text_of "$Q" | grep -q 'Rejected\*\* by dashboard-ui' && text_of "$Q" | grep -q 'Reason\*\*: Out of scope' \
  && ok "the close comment names the actor and the reason" || bad "reject comment: $(text_of "$Q")"
run 1 false "rejecting a closed issue fails"         -- "$CTL" reject "$Q"
run 1 false "approving a closed issue fails"         -- "$CTL" approve "$Q"
run 1 false "requesting changes on a closed issue"   -- "$CTL" request-changes "$Q" "x"
R=$(new_issue "Another")
run 0 true "reject without a reason" -- "$CTL" reject "$R"
jq -e '.detail.reason == null' <<<"$OUT" >/dev/null && ok "no reason is null" || bad "no reason: $OUT"
run 1 false "reject a missing issue" -- "$CTL" reject 999

# ── A backend failure is exit 1, not a crash ──────────────────────────────────
printf '{"issueSource": "nosuch"}\n' > .autocoder.json
run 1 false "file with a broken backend fails cleanly" -- "$CTL" file --title t

# #254: the verbs above logged their ctl events to the private log set at the top.
if jq -e -s 'any(.[]; .event == "ctl")' "$TMP/issue-events.jsonl" >/dev/null 2>&1; then
  ok "ctl events went to the private log, not the real state dir"
else
  bad "no ctl event in \$TMP/issue-events.jsonl: AUTOCODER_ISSUE_EVENTS is not reaching autocoder-ctl"
fi

echo ""
echo "Tests: $FAIL failed, $PASS passed, $((PASS + FAIL)) total"
[ "$FAIL" -eq 0 ]
