#!/bin/bash
# tests/test_issues_ado.sh — guards the Azure DevOps backend's WIQL, JSON-patch
# request shaping, output schema, and exit codes. curl is stubbed so no network
# is needed and outgoing payloads can be asserted.
#
# Key invariant: WIQL's `[System.Tags] NOT CONTAINS 'x'` already matches
# tag-less work items, so the claimable query must NOT add an exclusion that
# would drop untagged items (the ADO analogue of GitHub's no:label / Jira's
# empty-labels traps). The integration test proves the runtime behaviour; here
# we assert the query shape.

set -u
PASS=0; FAIL=0
BACKEND="plugins/autocoder/scripts/issues-ado.sh"

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
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 — want '$2' got '$3'"; fi; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

# ── Stub curl ────────────────────────────────────────────────────────────────
# Records "METHOD<TAB>URL<TAB>DATA" per call; emits a canned body + "\n<code>".
cat > "$TMP/bin/curl" <<'STUB'
#!/bin/bash
method="GET"; data=""; prev=""
for a in "$@"; do
  case "$prev" in -X) method="$a" ;; --data) data="$a" ;; esac
  prev="$a"
done
url="${@: -1}"
printf '%s\t%s\t%s\n' "$method" "$url" "$data" >> "$CURL_CAPTURE"
emit() { printf '%s\n%s' "$1" "$2"; }
case "$url" in
  */_apis/wit/wiql*)          emit '{"workItems":[{"id":7},{"id":8}]}' 200 ;;
  */_apis/wit/workitemsbatch*) emit '{"value":[
      {"id":7,"fields":{"System.Title":"first","System.Description":"body one","System.Tags":"P1","System.State":"Active"}},
      {"id":8,"fields":{"System.Title":"second","System.Description":"","System.Tags":"","System.State":"Closed"}}
    ]}' 200 ;;
  */_apis/wit/workItems/404/comments*) emit '{"comments":[]}' 200 ;;
  */_apis/wit/workItems/*/comments*)   emit '{"comments":[{"text":"a comment"}]}' 200 ;;
  */_apis/wit/workitems/404*)          emit '{"message":"does not exist"}' 404 ;;
  */_apis/wit/workitems/%24*)          emit '{"id":42}' 200 ;;   # create ($Task url-escaped)
  */_apis/wit/workitems/*)             # GET single / PATCH
    if [ "$method" = "GET" ]; then
      emit '{"id":7,"fields":{"System.Title":"first","System.Description":"the body","System.Tags":"P1; working","System.State":"Active"}}' 200
    else
      emit '{"id":7,"fields":{"System.Tags":"P1"}}' 200
    fi ;;
  *) emit '{}' 200 ;;
esac
STUB
chmod +x "$TMP/bin/curl"

run() {
  export CURL_CAPTURE="$TMP/capture.txt"; : > "$CURL_CAPTURE"
  OUT=$(PATH="$TMP/bin:$PATH" \
    ADO_ORG_URL="https://dev.azure.com/acme" ADO_PROJECT="Web" ADO_PAT="secret" \
    "$BACKEND" "$@" 2>/dev/null)
  RC=$?
}
wiql_of() { python3 -c 'import json,sys; print(json.loads(sys.stdin.read() or "{}").get("query",""))'; }
last_data() { tail -1 "$CURL_CAPTURE" | cut -f3; }
data_for_method() { awk -F'\t' -v m="$1" '$1==m {print $3}' "$CURL_CAPTURE" | tail -1; }

# ── list --state open: WIQL shape (tag-less items stay in via NOT CONTAINS) ──
run list --state open
WIQL=$(awk -F'\t' '$2 ~ /\/wiql/ {print $3}' "$CURL_CAPTURE" | tail -1 | wiql_of)
assert_contains "open WIQL excludes done states"        "System.State] NOT IN ('Closed', 'Done', 'Resolved', 'Removed', 'Completed')" "$WIQL"
for t in working needs-design needs-approval awaiting-integration; do
  assert_contains "open WIQL excludes blocking tag $t" "[System.Tags] NOT CONTAINS '$t'" "$WIQL"
done
assert_not_contains "open WIQL does not restrict to non-empty tags (no CONTAINS-only gate)" "[System.Tags] CONTAINS ''" "$WIQL"

# reshape from workitemsbatch
NUM7=$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["number"])')
assert_eq "list maps work item id to number" "7" "$NUM7"
STATE8=$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)[1]["state"])')
assert_eq "list maps done state → CLOSED" "CLOSED" "$STATE8"
STATE7=$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["state"])')
assert_eq "list maps active state → OPEN" "OPEN" "$STATE7"
LABEL7=$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["labels"][0]["name"])')
assert_eq "list maps tags → labels [{name}]" "P1" "$LABEL7"

# ── blocked WIQL: positive tag selection, no awaiting-integration/working ───
run list --state blocked
WIQL=$(awk -F'\t' '$2 ~ /\/wiql/ {print $3}' "$CURL_CAPTURE" | tail -1 | wiql_of)
assert_contains "blocked WIQL selects needs-design"          "[System.Tags] CONTAINS 'needs-design'" "$WIQL"
assert_not_contains "blocked WIQL excludes awaiting-integration" "awaiting-integration" "$WIQL"
assert_not_contains "blocked WIQL excludes working"          "CONTAINS 'working'" "$WIQL"

# ── any-claimable uses the open WIQL and reports via exit code ──────────────
run any-claimable
assert_eq "any-claimable exits 0 when work items exist" "0" "$RC"

# ── get: shape + not-found ──────────────────────────────────────────────────
run get 7
BODY=$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["body"])')
assert_eq "get returns the description as body" "the body" "$BODY"
CMT=$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["comments"][0]["body"])')
assert_eq "get maps comments (text→body)" "a comment" "$CMT"
TAGS=$(printf '%s' "$OUT" | python3 -c 'import json,sys; print([l["name"] for l in json.load(sys.stdin)["labels"]])')
assert_eq "get splits '; '-joined tags" "['P1', 'working']" "$TAGS"

run get 404
assert_eq "get on a missing work item exits 1" "1" "$RC"

# ── create sends a JSON-patch to the \$Task url and returns {number} ────────
run create --title "New thing" --body "details" --label P2
NUM=$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["number"])')
assert_eq "create returns the new work item id" "42" "$NUM"
CREATE_URL=$(awk -F'\t' '$1=="POST" && $2 ~ /workitems\/%24/ {print $2}' "$CURL_CAPTURE" | tail -1)
assert_contains "create posts to the url-escaped \$Task type" "workitems/%24Task" "$CREATE_URL"
CREATE_BODY=$(awk -F'\t' '$1=="POST" && $2 ~ /workitems\/%24/ {print $3}' "$CURL_CAPTURE" | tail -1)
assert_contains "create sets System.Title via json-patch" '"path": "/fields/System.Title"' "$CREATE_BODY"
assert_contains "create sets System.Tags"                 '"path": "/fields/System.Tags"' "$CREATE_BODY"

# ── claim / release edit System.Tags (read-modify-write PATCH) ──────────────
run claim 7
PATCH=$(data_for_method PATCH)
assert_contains "claim PATCHes System.Tags" '"path": "/fields/System.Tags"' "$PATCH"
assert_contains "claim adds working to the tag string" "working" "$PATCH"

# ── close sets System.State to a done state ─────────────────────────────────
run close 7 --comment "done here"
PATCH=$(data_for_method PATCH)
assert_contains "close PATCHes System.State" '"path": "/fields/System.State"' "$PATCH"
assert_contains "close writes the Closed state" '"value": "Closed"' "$PATCH"

# ── usage + config errors ───────────────────────────────────────────────────
OUT=$(PATH="$TMP/bin:$PATH" "$BACKEND" bogus 2>/dev/null); RC=$?
assert_eq "unknown verb exits 2" "2" "$RC"
ABS="$(pwd)/$BACKEND"
OUT=$(cd "$TMP" && PATH="$TMP/bin:$PATH" ADO_ORG_URL="" ADO_ORG="" ADO_PROJECT="" ADO_PAT="" "$ABS" list 2>/dev/null); RC=$?
assert_eq "missing config exits 3" "3" "$RC"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
