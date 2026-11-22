#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255: never write the real event logs
# tests/test_review_blocked_server.sh — the blocked-issue review server (#311, part of #308).
#
# Starts review-blocked-server.py on a free loopback port in a private temp repo
# on the file backend and drives it with curl: the token guard, GET /api/issues
# (block reason, cached analysis, stale flag), and POST /api/decision for each
# action, single and batch.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$ROOT/plugins/autocoder/scripts"
SERVER="$SCRIPTS/review-blocked-server.py"
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — expected '$3', got '$2'"; fi; }

TMP=$(mktemp -d)
SERVER_PID=""
cleanup() { [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null; wait 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT
unset ISSUE_SOURCE ISSUE_BACKEND ISSUE_DIR AUTOCODER_BLOCKED_CACHE_DIR
export AUTOCODER_ISSUE_EVENTS="$TMP/issue-events.jsonl"

git init -q "$TMP/repo"; cd "$TMP/repo" || exit 1
git config user.email t@example.com; git config user.name T
printf '{"issueSource": "file"}\n' > .autocoder.json
echo a > a; git add -A; git commit -qm base

IF() { ( source "$SCRIPTS/issue-fns.sh" >/dev/null 2>&1; "$@" ); }
new_issue() { IF issue_create --title "$1" --body "$2" | jq -r .number; }
labels_of() { IF issue_get "$1" | jq -r '[.labels[] | (.name? // .)] | sort | join(",")'; }
state_of()  { IF issue_get "$1" | jq -r '.state | ascii_downcase'; }
text_of()   { IF issue_get "$1" | jq -r '[.body, (.comments[]?.body)] | join("\n")'; }

A=$(new_issue "Pick a storage backend" "which one?")
B=$(new_issue "Rewrite the parser" "too big")
C=$(new_issue "Add a dark mode" "later")
D=$(new_issue "Unrelated open issue" "claimable")
IF issue_update "$A" --add-label needs-design >/dev/null 2>&1; IF issue_update "$A" --add-label P2 >/dev/null 2>&1
IF issue_comment "$A" --body "🎨 **Blocked — Needs Design**: two storage options, no winner" >/dev/null 2>&1
IF issue_update "$B" --add-label too-complex >/dev/null 2>&1
IF issue_update "$C" --add-label future >/dev/null 2>&1

python3 "$SERVER" > "$TMP/server.out" 2> "$TMP/server.err" &
SERVER_PID=$!
URL=""
for _ in $(seq 1 50); do
  URL=$(sed -n 's/^review-blocked-server: //p' "$TMP/server.out" | head -1)
  [ -n "$URL" ] && break
  sleep 0.1
done
[ -n "$URL" ] || { bad "the server printed no startup URL: $(cat "$TMP/server.err")"; echo "Tests: $FAIL failed, $PASS passed"; exit 1; }
BASE=${URL%%/\?*}; TOKEN=${URL##*token=}

case "$BASE" in http://127.0.0.1:[0-9]*) ok "the startup URL is on 127.0.0.1" ;; *) bad "startup URL $URL" ;; esac
PORT=${BASE##*:}
if command -v ss >/dev/null 2>&1; then
  LISTEN=$(ss -Hltn "sport = :$PORT" | awk '{print $4}')
  eq "the server listens on loopback only" "$LISTEN" "127.0.0.1:$PORT"
fi
[ "${#TOKEN}" -ge 20 ] && ok "the token is long and random" || bad "token '$TOKEN'"

code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
api()  { curl -s -H "X-Review-Token: $TOKEN" "$@"; }
post() { curl -s -w '\n%{http_code}' -H "X-Review-Token: $TOKEN" -H 'Content-Type: application/json' \
           -X POST --data "$1" "$BASE/api/decision"; }

# ── Token guard ───────────────────────────────────────────────────────────────
eq "GET /api/issues without the token is 403" "$(code "$BASE/api/issues")" 403
eq "GET /api/issues with a wrong token is 403" "$(code -H 'X-Review-Token: nope' "$BASE/api/issues")" 403
eq "POST /api/decision without the token is 403" \
  "$(code -X POST --data '{"issue":1,"action":"skip"}' "$BASE/api/decision")" 403
eq "an unknown /api path without the token is 403, not 404" "$(code "$BASE/api/whatever")" 403
eq "the token works as a query parameter" "$(code "$BASE/api/issues?token=$TOKEN")" 200
eq "GET / serves a page without the token" "$(code "$BASE/")" 200
curl -s "$BASE/" | grep -q "Review blocked issues" && ok "GET / falls back to the placeholder page" \
  || bad "GET / body: $(curl -s "$BASE/")"

# ── GET /api/issues ───────────────────────────────────────────────────────────
OUT=$(api "$BASE/api/issues")
eq "lists the blocked issues only, P2 first" "$(printf '%s' "$OUT" | jq -c '[.issues[].number]')" "[$A,$B,$C]"
eq "the block reason is the comment that explains it" \
  "$(printf '%s' "$OUT" | jq -r --argjson n "$A" '.issues[] | select(.number == $n) | .blockReason')" \
  "🎨 **Blocked — Needs Design**: two storage options, no winner"
eq "an issue without an explaining comment has blockReason null" \
  "$(printf '%s' "$OUT" | jq -r --argjson n "$B" '.issues[] | select(.number == $n) | .blockReason')" null
eq "nothing cached: analysis null, stale null" \
  "$(printf '%s' "$OUT" | jq -c --argjson n "$A" '.issues[] | select(.number == $n) | [.analysis, .stale]')" "[null,null]"
KEY_A=$(printf '%s' "$OUT" | jq -r --argjson n "$A" '.issues[] | select(.number == $n) | .analysisKey')
case "$KEY_A" in sha256:*) ok "the file backend's analysisKey is a content hash" ;; *) bad "analysisKey '$KEY_A'" ;; esac
# --key N (#312): /review-blocked --prepare stores analyses under this key.
eq "--key prints the same analysisKey as GET /api/issues" "$(python3 "$SERVER" --key "$A")" "$KEY_A"
python3 "$SERVER" --key 99999 >/dev/null 2>"$TMP/key.err"; KEY_RC=$?
eq "--key on a missing issue exits 1" "$KEY_RC" 1
python3 "$SERVER" --key 0 >/dev/null 2>&1; eq "--key 0 is refused as not an issue number" "$?" 2
grep -q "cannot read issue #99999" "$TMP/key.err" && ok "--key names the issue it could not read" \
  || bad "--key stderr: $(cat "$TMP/key.err")"

cat > "$TMP/analysis.json" <<'JSON'
{"summary": "Pick a storage backend",
 "options": [{"title": "SQLite", "pros": ["one file"], "cons": ["locking"], "effort": "small"},
             {"title": "JSON files", "pros": ["no dependency"], "cons": ["no queries"], "effort": "tiny"}],
 "recommended": 1}
JSON
python3 "$SCRIPTS/blocked-analysis-cache.py" put "$A" --updated-at "$KEY_A" --file "$TMP/analysis.json" >/dev/null
python3 "$SCRIPTS/blocked-analysis-cache.py" put "$B" --updated-at "sha256:old" --file "$TMP/analysis.json" >/dev/null
OUT=$(api "$BASE/api/issues")
eq "a fresh cached analysis is returned with stale false" \
  "$(printf '%s' "$OUT" | jq -c --argjson n "$A" '.issues[] | select(.number == $n) | [.analysis.recommended, .stale]')" "[1,false]"
eq "an analysis cached for an older key is stale, analysis null" \
  "$(printf '%s' "$OUT" | jq -c --argjson n "$B" '.issues[] | select(.number == $n) | [.analysis, .stale]')" "[null,true]"
IF issue_comment "$A" --body "the human answered: either is fine" >/dev/null 2>&1
OUT=$(api "$BASE/api/issues")
eq "a new comment changes the key, so the cached analysis reads stale" \
  "$(printf '%s' "$OUT" | jq -c --argjson n "$A" '.issues[] | select(.number == $n) | [.analysis, .stale]')" "[null,true]"

# ── POST /api/decision: validation ────────────────────────────────────────────
last() { tail -1; }
body() { sed '$d'; }
R=$(post '{"issue":"x","action":"skip"}'); eq "a non-numeric issue is 400" "$(printf '%s' "$R" | last)" 400
R=$(post '{"issue":1,"action":"merge"}');  eq "an unknown action is 400" "$(printf '%s' "$R" | last)" 400
R=$(post "{\"issue\":$A,\"action\":\"approve\",\"label\":\"P2\",\"approach\":\"x\"}")
eq "approve with a non-blocking label is 400" "$(printf '%s' "$R" | last)" 400
R=$(post "{\"issue\":$A,\"action\":\"reject\",\"reason\":\"  \"}"); eq "reject with a blank reason is 400" "$(printf '%s' "$R" | last)" 400
R=$(post 'not json'); eq "a body that is not JSON is 400" "$(printf '%s' "$R" | last)" 400
R=$(post '{"issue":"²","action":"skip"}'); eq "a non-ASCII digit issue is 400, not a dropped connection" "$(printf '%s' "$R" | last)" 400
R=$(post '[]'); eq "an empty batch is 400" "$(printf '%s' "$R" | last)" 400
eq "nothing was changed by refused decisions" "$(labels_of "$A")" "P2,needs-design"

# ── POST /api/decision: actions ───────────────────────────────────────────────
R=$(post "{\"issue\":$D,\"action\":\"skip\"}")
eq "skip is 200 and ok" "$(printf '%s' "$R" | body | jq -c '[.ok, .detail]')" '[true,"skipped"]'

R=$(post "{\"issue\":$A,\"action\":\"ask\",\"question\":\"Is SQLite acceptable; \$(touch $TMP/pwned)?\"}")
eq "ask is 200 and ok" "$(printf '%s' "$R" | last)" 200
text_of "$A" | grep -q "Question from human review" && ok "ask comments on the issue" || bad "no question comment"
eq "ask keeps the blocking label" "$(labels_of "$A")" "P2,needs-design"
[ -e "$TMP/pwned" ] && bad "the question text reached a shell" || ok "the question text never reaches a shell"

R=$(post "{\"issue\":$A,\"action\":\"approve\",\"label\":\"needs-design\",\"approach\":\"Use JSON files\"}")
eq "approve is 200 and ok" "$(printf '%s' "$R" | body | jq -r .ok)" true
eq "approve removes the blocking label" "$(labels_of "$A")" "P2"
text_of "$A" | grep -q "Decision\*\*: Use JSON files" && ok "approve posts the approach" || bad "no approval comment"

R=$(post "{\"issue\":$C,\"action\":\"reject\",\"reason\":\"not now\"}")
eq "reject is 200 and ok" "$(printf '%s' "$R" | last)" 200
eq "reject closes the issue" "$(state_of "$C")" closed

R=$(post '{"issue":99999,"action":"reject","reason":"gone"}')
eq "a decision whose script fails is 500" "$(printf '%s' "$R" | last)" 500
eq "  and reports ok false" "$(printf '%s' "$R" | body | jq -r .ok)" false

# ── Batch ─────────────────────────────────────────────────────────────────────
R=$(post "[{\"issue\":$B,\"action\":\"approve\",\"label\":\"too-complex\",\"approach\":\"split it\"},
           {\"issue\":99999,\"action\":\"reject\",\"reason\":\"gone\"},
           {\"issue\":$D,\"action\":\"bogus\"},
           {\"issue\":$D,\"action\":\"skip\"}]")
eq "a batch answers 200" "$(printf '%s' "$R" | last)" 200
eq "a batch reports each decision in order" \
  "$(printf '%s' "$R" | body | jq -c '[.results[] | [.issue, .ok]]')" "[[$B,true],[99999,false],[$D,false],[$D,true]]"
eq "a batch with a failure is not ok overall" "$(printf '%s' "$R" | body | jq -r .ok)" false
eq "a failure in a batch does not stop the later decisions" "$(labels_of "$B")" ""

grep -qF "$TOKEN" "$TMP/server.err" && bad "the request log holds the token" || ok "the request log never holds the token"
grep -q "GET /api/issues -> 200" "$TMP/server.err" && ok "the request log names method, path and status" \
  || bad "request log: $(head -3 "$TMP/server.err")"

OUT=$(api "$BASE/api/issues")
eq "after the decisions no blocked issue is left" "$(printf '%s' "$OUT" | jq -c '[.issues[].number]')" "[]"

echo ""
echo "Tests: $FAIL failed, $PASS passed, $((PASS + FAIL)) total"
[ "$FAIL" -eq 0 ]
