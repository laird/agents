#!/bin/bash
# jira-smoke-test.sh — live end-to-end check of issues-jira.sh against a REAL
# Jira instance. Run this where outbound HTTPS to *.atlassian.net is allowed
# (your laptop, or a session whose egress policy permits Atlassian).
#
# Prereqs (export before running):
#   export JIRA_BASE_URL="https://YOURSITE.atlassian.net"
#   export JIRA_PROJECT="ENG"                 # your project key
#   export JIRA_EMAIL="you@example.com"
#   export JIRA_API_TOKEN="<token from id.atlassian.com/manage-profile/security/api-tokens>"
#
# Usage:
#   bash jira-smoke-test.sh            # creates a throwaway issue, exercises the
#                                      # full 9-verb lifecycle, then closes it.
#
# It talks ONLY to your project and cleans up the issue it creates.

set -u
BACKEND="${BACKEND:-plugins/autocoder/scripts/issues-jira.sh}"
[ -f "$BACKEND" ] || { echo "Cannot find $BACKEND — run from the repo root or set BACKEND=path"; exit 2; }

for v in JIRA_BASE_URL JIRA_PROJECT JIRA_EMAIL JIRA_API_TOKEN; do
  [ -n "${!v:-}" ] || { echo "Missing \$$v — see the header of this script."; exit 2; }
done

PASS=0; FAIL=0
ok()   { echo "  ✅ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ❌ $1"; FAIL=$((FAIL+1)); }

echo "== 0. connectivity =="
if curl -sS -o /dev/null -w '%{http_code}' --max-time 20 \
     --user "$JIRA_EMAIL:$JIRA_API_TOKEN" \
     "${JIRA_BASE_URL%/}/rest/api/2/myself" | grep -q '^200$'; then
  ok "authenticated to $JIRA_BASE_URL"
else
  bad "could not authenticate — check base URL / email / token / egress"; exit 1
fi

echo "== 1. any-claimable (exit 0=work, 1=none) =="
"$BACKEND" any-claimable; echo "  exit=$?"

echo "== 2. list --state open (first 5) =="
"$BACKEND" list --state open --limit 5 | python3 -m json.tool | head -30

echo "== 3. create a throwaway issue =="
NUM=$("$BACKEND" create --title "[smoke] jira backend $(date -u +%FT%TZ)" \
        --body "Automated smoke test — safe to delete." --label smoke-test \
      | python3 -c 'import json,sys; print(json.load(sys.stdin)["number"])')
[ -n "$NUM" ] && ok "created ${JIRA_PROJECT}-${NUM}" || { bad "create returned no number"; exit 1; }

echo "== 4. get it back =="
"$BACKEND" get "$NUM" | python3 -c '
import json,sys; d=json.load(sys.stdin)
assert d["state"]=="OPEN", d["state"]
print("  title:", d["title"]); print("  labels:", [l["name"] for l in d["labels"]])
' && ok "get round-trips" || bad "get failed"

echo "== 5. claim / release (working label) =="
"$BACKEND" claim "$NUM"   && ok "claimed"   || bad "claim failed"
"$BACKEND" get "$NUM" | grep -q '"working"' && ok "working label present" || bad "working label missing after claim"
"$BACKEND" release "$NUM" && ok "released"  || bad "release failed"

echo "== 6. comment =="
"$BACKEND" comment "$NUM" --body "smoke: hello from jira-smoke-test.sh" && ok "commented" || bad "comment failed"

echo "== 7. update label + assignee (assignee is best-effort) =="
"$BACKEND" update "$NUM" --add-label P3 && ok "added label P3" || bad "label update failed"

echo "== 8. close (transition to Done) =="
"$BACKEND" close "$NUM" --comment "smoke: closing throwaway issue" && ok "closed" || bad "close failed"
"$BACKEND" get "$NUM" | grep -q '"state": "CLOSED"' && ok "verified CLOSED" || bad "issue not CLOSED after close"

echo ""
echo "==== $PASS passed, $FAIL failed  (created ${JIRA_PROJECT}-${NUM}; delete it from Jira if you like) ===="
[ "$FAIL" -eq 0 ]
