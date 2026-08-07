#!/bin/bash
# tests/test_issues_jira.sh — guards the Jira backend's JQL, request shaping,
# output schema, and exit codes.
#
# The most important invariant, mirroring the GitHub `no:label` bug (#57): the
# claimable/open JQL must still return issues that carry NO labels. Jira's
# `labels not in (...)` silently drops label-less issues, so the query has to
# OR in `labels is EMPTY`. If that clause regresses, the autocoder loop idles
# forever on a project whose issues are simply unlabeled.
#
# curl is stubbed so no network access is required and the emitted request
# payloads can be asserted.

set -u
PASS=0; FAIL=0
BACKEND="plugins/autocoder/scripts/issues-jira.sh"

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then pass "$label"
  else fail "$label — '$needle' not found in: $haystack"; fi
}
assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then fail "$label — '$needle' unexpectedly present"
  else pass "$label"; fi
}
assert_eq() {
  local label="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then pass "$label"; else fail "$label — want '$want' got '$got'"; fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

# ── Stub curl ────────────────────────────────────────────────────────────────
# Records "METHOD<TAB>URL<TAB>DATA" for every call to $CURL_CAPTURE, then emits
# a canned body followed by "\n<http_code>" (the backend requests the code via
# -w '\n%{http_code}').
cat > "$TMP/bin/curl" <<'STUB'
#!/bin/bash
method="GET"; data=""; prev=""
for a in "$@"; do
  case "$prev" in
    -X)     method="$a" ;;
    --data) data="$a" ;;
  esac
  prev="$a"
done
url="${@: -1}"   # the URL is the final argument
printf '%s\t%s\t%s\n' "$method" "$url" "$data" >> "$CURL_CAPTURE"

emit() { printf '%s\n%s' "$1" "$2"; }  # body, code

case "$url" in
  */rest/api/3/search/jql)
    # New contract: {issues:[...]} only — no total, no startAt. Absence of a
    # nextPageToken means this is the last (only) page.
    emit '{"issues":[
      {"key":"ENG-7","fields":{"summary":"first","description":"body one","labels":["P1"],"status":{"statusCategory":{"key":"indeterminate"}}}},
      {"key":"ENG-8","fields":{"summary":"second","description":"","labels":[],"status":{"statusCategory":{"key":"done"}}}}
    ]}' 200 ;;
  */rest/api/2/search)
    # Removed by Atlassian (CHANGE-2046). Any request landing here must fail
    # loudly so a regression back to the old endpoint cannot pass.
    emit '{"errorMessages":["The requested API has been removed. Please migrate to /rest/api/3/search/jql."],"errors":{}}' 410 ;;
  */rest/api/2/issue/ENG-404*)
    emit '{"errorMessages":["Issue does not exist"]}' 404 ;;
  */rest/api/2/issue/*/transitions)
    if [ "$method" = "GET" ]; then
      emit '{"transitions":[{"id":"31","to":{"statusCategory":{"key":"done"}}},{"id":"11","to":{"statusCategory":{"key":"new"}}}]}' 200
    else
      emit '' 204
    fi ;;
  */rest/api/2/issue/*/comment)
    emit '{"id":"10001"}' 201 ;;
  */rest/api/2/issue/*/assignee)
    emit '' 204 ;;
  */rest/api/2/issue/ENG-7*)
    emit '{"key":"ENG-7","fields":{"summary":"first","description":"the body","labels":["P1","working"],"status":{"statusCategory":{"key":"indeterminate"}},"comment":{"comments":[{"body":"a comment"}]}}}' 200 ;;
  */rest/api/2/issue)
    emit '{"key":"ENG-42"}' 201 ;;      # create (POST to the collection)
  */rest/api/2/issue/*)
    emit '' 204 ;;                        # PUT label edit
  *)
    emit '{}' 200 ;;
esac
STUB
chmod +x "$TMP/bin/curl"

run() {
  # run <verb> [args...]  → sets $OUT / $RC, fresh capture per call.
  export CURL_CAPTURE="$TMP/capture.txt"
  : > "$CURL_CAPTURE"
  OUT=$(PATH="$TMP/bin:$PATH" \
    JIRA_BASE_URL="https://acme.atlassian.net" JIRA_PROJECT="ENG" \
    JIRA_EMAIL="you@acme.com" JIRA_API_TOKEN="secret" \
    "$BACKEND" "$@" 2>/dev/null)
  RC=$?
}
last_data() { tail -1 "$CURL_CAPTURE" | cut -f3; }
# Decode the .jql field from the last (or a matching) request payload, so
# assertions read the human JQL rather than JSON-escaped \" noise.
jql_of() { python3 -c 'import json,sys; print(json.loads(sys.stdin.read() or "{}").get("jql",""))'; }
last_jql() { last_data | jql_of; }

# ── list --state open: the label-less guard ─────────────────────────────────
run list --state open
JQL=$(last_jql)
assert_contains "open JQL includes labels-is-EMPTY guard" 'labels is EMPTY' "$JQL"
assert_contains "open JQL excludes blocking labels via not in" 'labels not in' "$JQL"
for l in working needs-design needs-clarification needs-feedback needs-approval too-complex future proposal awaiting-integration; do
  assert_contains "open JQL lists blocking label $l" "\"$l\"" "$JQL"
done
assert_contains "open JQL scopes to project" 'project = "ENG"' "$JQL"
assert_contains "open JQL excludes done work" 'statusCategory != Done' "$JQL"

# ── search request shape: v3 endpoint, explicit fields, token pagination ────
SEARCH_URL=$(tail -1 "$CURL_CAPTURE" | cut -f2)
assert_contains "list posts to /rest/api/3/search/jql (v2 search is removed)" '/rest/api/3/search/jql' "$SEARCH_URL"
SEARCH_DATA=$(last_data)
for f in summary description labels status; do
  assert_contains "list requests field $f explicitly" "\"$f\"" "$SEARCH_DATA"
done
assert_not_contains "list payload has no startAt (token pagination)" 'startAt' "$SEARCH_DATA"

# ── list output is reshaped to the gh schema ────────────────────────────────
NUM7=$(printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["number"])')
assert_eq "list maps key suffix to integer number" "7" "$NUM7"
STATE8=$(printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[1]["state"])')
assert_eq "list maps statusCategory done → CLOSED" "CLOSED" "$STATE8"
STATE7=$(printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["state"])')
assert_eq "list maps non-done → OPEN" "OPEN" "$STATE7"
LABEL7=$(printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["labels"][0]["name"])')
assert_eq "list maps labels to [{name}]" "P1" "$LABEL7"

# ── list --state blocked: positive selection, no awaiting-integration ───────
run list --state blocked
JQL=$(last_jql)
assert_contains "blocked JQL selects needs-design" 'needs-design' "$JQL"
assert_not_contains "blocked JQL excludes awaiting-integration" 'awaiting-integration' "$JQL"
assert_not_contains "blocked JQL excludes working" 'labels = "working"' "$JQL"

# ── any-claimable reuses the open JQL and reports work via exit code ─────────
run any-claimable
assert_eq "any-claimable exits 0 when total>0" "0" "$RC"
assert_contains "any-claimable uses the open JQL guard" 'labels is EMPTY' "$(last_jql)"

# ── get: shape + not-found ──────────────────────────────────────────────────
run get 7
BODY=$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["body"])')
assert_eq "get returns plain-text body" "the body" "$BODY"
CMT=$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["comments"][0]["body"])')
assert_eq "get maps comments" "a comment" "$CMT"

run get 404
assert_eq "get on missing issue exits 1 (clean negative)" "1" "$RC"

# ── get accepts a full key too ──────────────────────────────────────────────
run get ENG-7
assert_eq "get accepts full PROJ-N key" "0" "$RC"

# ── create returns {number} ─────────────────────────────────────────────────
run create --title "New thing" --body "details" --label P2
NUM=$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["number"])')
assert_eq "create returns numeric key suffix" "42" "$NUM"
CREATE_PAYLOAD=$(awk -F'\t' '$2 ~ /\/rest\/api\/2\/issue$/ {print $3}' "$CURL_CAPTURE" | tail -1)
assert_contains "create sends project key" '"key": "ENG"' "$CREATE_PAYLOAD"
assert_contains "create sends label" '"P2"' "$CREATE_PAYLOAD"

# ── claim / release toggle the working label ────────────────────────────────
run claim 7
assert_contains "claim adds working label" '"add": "working"' "$(last_data)"
run release 7
assert_contains "release removes working label" '"remove": "working"' "$(last_data)"

# ── update --status closed transitions to a Done category ───────────────────
run update 7 --status closed
POST_T=$(awk -F'\t' '$1=="POST" && $2 ~ /\/transitions$/ {print $3}' "$CURL_CAPTURE" | tail -1)
assert_contains "close transitions to the Done-category transition id 31" '"id":"31"' "$POST_T"

# ── comment posts the body ──────────────────────────────────────────────────
run comment 7 --body "hello there"
assert_contains "comment sends body" 'hello there' "$(last_data)"

# ── usage + config errors ───────────────────────────────────────────────────
OUT=$(PATH="$TMP/bin:$PATH" "$BACKEND" bogus-verb 2>/dev/null); RC=$?
assert_eq "unknown verb exits 2" "2" "$RC"

# Missing config (run from a non-repo temp dir with no env) → exit 3.
ABS_BACKEND="$(pwd)/$BACKEND"
OUT=$(cd "$TMP" && PATH="$TMP/bin:$PATH" JIRA_BASE_URL="" JIRA_PROJECT="" JIRA_EMAIL="" JIRA_API_TOKEN="" JIRA_AUTH_HEADER="" \
  "$ABS_BACKEND" list 2>/dev/null); RC=$?
assert_eq "missing config exits 3" "3" "$RC"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
