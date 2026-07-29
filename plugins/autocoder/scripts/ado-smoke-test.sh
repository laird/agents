#!/bin/bash
# ado-smoke-test.sh — live end-to-end check of issues-ado.sh against a REAL
# Azure DevOps organization. Run this where outbound HTTPS to dev.azure.com is
# allowed (your laptop, or a session whose egress policy permits Azure DevOps).
#
# Prereqs (export before running):
#   export ADO_ORG_URL="https://dev.azure.com/YOURORG"
#   export ADO_PROJECT="YourProject"
#   export ADO_PAT="<personal access token with Work Items read/write>"
#   # Optional, if your process is not Agile/CMMI (which use "Closed"):
#   #   export ADO_CLOSED_STATE="Done"     # Basic / Scrum
#   #   export ADO_WORKITEM_TYPE="Issue"   # default is Task
#
# Usage:
#   bash ado-smoke-test.sh             # creates a throwaway work item, exercises
#                                      # the full 9-verb lifecycle, then closes it.
#
# It talks ONLY to your project and closes the work item it creates.

set -u
BACKEND="${BACKEND:-plugins/autocoder/scripts/issues-ado.sh}"
[ -f "$BACKEND" ] || { echo "Cannot find $BACKEND — run from the repo root or set BACKEND=path"; exit 2; }

for v in ADO_ORG_URL ADO_PROJECT ADO_PAT; do
  [ -n "${!v:-}" ] || { echo "Missing \$$v — see the header of this script."; exit 2; }
done

PASS=0; FAIL=0
ok()   { echo "  ✅ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ❌ $1"; FAIL=$((FAIL+1)); }

echo "== 0. connectivity =="
# _apis/projects/<project> is a cheap authenticated GET; PAT auth uses empty user.
if curl -sS -o /dev/null -w '%{http_code}' --max-time 20 \
     --user ":$ADO_PAT" \
     "${ADO_ORG_URL%/}/_apis/projects/${ADO_PROJECT}?api-version=7.0" | grep -q '^200$'; then
  ok "authenticated to $ADO_ORG_URL (project $ADO_PROJECT)"
else
  bad "could not authenticate — check org URL / project / PAT scope / egress"; exit 1
fi

echo "== 1. any-claimable (exit 0=work, 1=none) =="
"$BACKEND" any-claimable; echo "  exit=$?"

echo "== 2. list --state open (first 5) =="
"$BACKEND" list --state open --limit 5 | python3 -m json.tool | head -30

echo "== 3. create a throwaway work item =="
NUM=$("$BACKEND" create --title "[smoke] ado backend $(date -u +%FT%TZ)" \
        --body "Automated smoke test — safe to delete." --label smoke-test \
      | python3 -c 'import json,sys; print(json.load(sys.stdin)["number"])')
[ -n "$NUM" ] && ok "created work item #${NUM}" || { bad "create returned no number"; exit 1; }

echo "== 4. get it back =="
"$BACKEND" get "$NUM" | python3 -c '
import json,sys; d=json.load(sys.stdin)
assert d["state"]=="OPEN", d["state"]
print("  title:", d["title"]); print("  tags:", [l["name"] for l in d["labels"]])
' && ok "get round-trips" || bad "get failed"

echo "== 5. claim / release (working tag) =="
"$BACKEND" claim "$NUM"   && ok "claimed"   || bad "claim failed"
"$BACKEND" get "$NUM" | grep -q '"working"' && ok "working tag present" || bad "working tag missing after claim"
"$BACKEND" release "$NUM" && ok "released"  || bad "release failed"

echo "== 6. comment =="
"$BACKEND" comment "$NUM" --body "smoke: hello from ado-smoke-test.sh" && ok "commented" || bad "comment failed"

echo "== 7. update tag =="
"$BACKEND" update "$NUM" --add-label P3 && ok "added tag P3" || bad "tag update failed"

echo "== 8. close (transition to a done state: ${ADO_CLOSED_STATE:-Closed}) =="
"$BACKEND" close "$NUM" --comment "smoke: closing throwaway work item" && ok "closed" || bad "close failed"
"$BACKEND" get "$NUM" | grep -q '"state": "CLOSED"' && ok "verified CLOSED" || bad "work item not CLOSED after close"

echo ""
echo "==== $PASS passed, $FAIL failed  (created #${NUM}; it is now Closed — delete from Azure DevOps if you like) ===="
[ "$FAIL" -eq 0 ]
