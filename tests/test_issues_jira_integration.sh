#!/bin/bash
# tests/test_issues_jira_integration.sh — end-to-end test of issues-jira.sh
# against a STATEFUL in-process fake of the Jira REST API
# (tests/fixtures/fake_jira.py): v2 issue lifecycle plus the v3
# /rest/api/3/search/jql search endpoint (v2 search returns HTTP 410 there,
# as on real Jira Cloud since CHANGE-2046).
#
# This complements tests/test_issues_jira.sh (which stubs curl and asserts the
# *shape* of outgoing requests): here real curl talks real HTTP to a fake that
# maintains state and evaluates JQL, so the full lifecycle round-trips —
# create → get → claim/release → comment → update → close — and the state
# filters (open/blocked/working/closed) are checked against an actual query
# evaluator, including the label-less "labels is EMPTY" guard that a stateless
# mock cannot exercise.
#
# Hermetic: binds an ephemeral loopback port, needs no network, and tears the
# server down on exit. Skips cleanly (exit 0) if curl or python3 is missing.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
BACKEND="$REPO_ROOT/plugins/autocoder/scripts/issues-jira.sh"
FAKE="$HERE/fixtures/fake_jira.py"

if ! command -v curl >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP: curl and python3 are required for the Jira integration test"
  exit 0
fi
[ -f "$BACKEND" ] || { echo "FAIL: backend not found at $BACKEND"; exit 1; }
[ -f "$FAKE" ]    || { echo "FAIL: fake server not found at $FAKE"; exit 1; }

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
no()  { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 — want '$2' got '$3'"; fi; }

TMP=$(mktemp -d)
LOG="$TMP/server.log"
SERVER_PID=""
cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

# ── start the fake on an ephemeral port ─────────────────────────────────────
# FAKE_JIRA_PAGE_CAP=2 makes the fake serve at most 2 issues per search page,
# so any list of the 5 seeded issues must follow the nextPageToken chain —
# exercising the backend's v3 pagination loop, not just its first request.
export FAKE_JIRA_PAGE_CAP=2
python3 "$FAKE" 0 >"$LOG" 2>&1 &
SERVER_PID=$!
PORT=""
for _ in $(seq 1 50); do
  PORT=$(sed -n 's/^LISTENING \([0-9]*\)$/\1/p' "$LOG" 2>/dev/null | head -1)
  [ -n "$PORT" ] && break
  # bail early if the server died on startup
  kill -0 "$SERVER_PID" 2>/dev/null || break
  sleep 0.1
done
if [ -z "$PORT" ]; then
  echo "FAIL: fake server did not report a port"; cat "$LOG"; exit 1
fi

export JIRA_BASE_URL="http://127.0.0.1:${PORT}"
export JIRA_PROJECT="ENG"
export JIRA_EMAIL="fake@local"
export JIRA_API_TOKEN="ignored"

nums() { python3 -c 'import json,sys; print(",".join(str(d["number"]) for d in sorted(json.load(sys.stdin), key=lambda x:x["number"])))'; }
field() { python3 -c "import json,sys; print(json.load(sys.stdin)$1)"; }

# ── state filtering against the real evaluator ──────────────────────────────
# Seeded: 1=unlabeled, 2=P1, 3=needs-design, 4=working, 5=done.
eq "list --state open includes unlabeled (labels-is-EMPTY guard) + P1"  "1,2" "$("$BACKEND" list --state open    | nums)"
eq "list --state blocked selects only the needs-design issue"           "3"   "$("$BACKEND" list --state blocked | nums)"
eq "list --state working selects only the claimed issue"                "4"   "$("$BACKEND" list --state working | nums)"
eq "list --state closed selects only the done issue"                    "5"   "$("$BACKEND" list --state closed  | nums)"
eq "list --state all paginates via nextPageToken (page cap 2)"          "1,2,3,4,5" "$("$BACKEND" list --state all | nums)"
eq "list --limit stops the pagination loop and truncates"               "1,2,3" "$("$BACKEND" list --state all --limit 3 | nums)"
"$BACKEND" any-claimable; eq "any-claimable exits 0 when work exists" "0" "$?"

# ── full lifecycle round-trip ───────────────────────────────────────────────
NUM=$("$BACKEND" create --title "lifecycle probe" --body "the body" --label smoke | field '["number"]')
eq "create returns the new issue number (6)" "6" "$NUM"

eq "get round-trips the title"       "lifecycle probe" "$("$BACKEND" get "$NUM" | field '["title"]')"
eq "get round-trips the body"        "the body"        "$("$BACKEND" get "$NUM" | field '["body"]')"
eq "new issue is OPEN"               "OPEN"            "$("$BACKEND" get "$NUM" | field '["state"]')"
eq "create applied the label"        "smoke"          "$("$BACKEND" get "$NUM" | field '["labels"][0]["name"]')"

"$BACKEND" claim "$NUM" >/dev/null
HAS_WORKING=$("$BACKEND" get "$NUM" | python3 -c 'import json,sys; print("working" in [l["name"] for l in json.load(sys.stdin)["labels"]])')
eq "claim adds the working label" "True" "$HAS_WORKING"

"$BACKEND" release "$NUM" >/dev/null
HAS_WORKING=$("$BACKEND" get "$NUM" | python3 -c 'import json,sys; print("working" in [l["name"] for l in json.load(sys.stdin)["labels"]])')
eq "release removes the working label" "False" "$HAS_WORKING"

"$BACKEND" comment "$NUM" --body "hello there" >/dev/null
HAS_COMMENT=$("$BACKEND" get "$NUM" | python3 -c 'import json,sys; print(any(c["body"]=="hello there" for c in json.load(sys.stdin)["comments"]))')
eq "comment is persisted and returned by get" "True" "$HAS_COMMENT"

"$BACKEND" update "$NUM" --add-label P3 >/dev/null
HAS_P3=$("$BACKEND" get "$NUM" | python3 -c 'import json,sys; print("P3" in [l["name"] for l in json.load(sys.stdin)["labels"]])')
eq "update --add-label adds P3" "True" "$HAS_P3"

"$BACKEND" close "$NUM" --comment "closing" >/dev/null
eq "close transitions the issue to CLOSED" "CLOSED" "$("$BACKEND" get "$NUM" | field '["state"]')"

# ── ADF flattening: v3 search descriptions come back as ADF documents ───────
# The fake (like real Jira Cloud) returns `description` as an ADF doc object
# from /rest/api/3/search/jql; list must flatten it to the plain string
# consumers have always received (paragraphs joined by newlines).
ADF_NUM=$("$BACKEND" create --title "adf probe" --body $'para one\npara two' --label adf-probe | field '["number"]')
ADF_BODY=$("$BACKEND" list --state open --label adf-probe | field '[0]["body"]')
eq "list flattens a multi-paragraph ADF description to plain text" $'para one\npara two' "$ADF_BODY"
ADF_IS_STR=$("$BACKEND" list --state open --label adf-probe | python3 -c 'import json,sys; print(isinstance(json.load(sys.stdin)[0]["body"], str))')
eq "list body is a plain string, not an ADF object" "True" "$ADF_IS_STR"

# ── not-found is a clean negative (exit 1), not a backend error (exit 3) ─────
"$BACKEND" get 999 >/dev/null 2>&1; eq "get on a missing issue exits 1" "1" "$?"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
