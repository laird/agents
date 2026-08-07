#!/bin/bash
# ado-smoke-test.sh — live end-to-end check of issues-ado.sh against a REAL
# Azure DevOps organization. Run where outbound HTTPS to dev.azure.com is
# allowed (your laptop, or a session whose egress policy permits it).
#
# Prereqs (export before running):
#   export ADO_ORG_URL="https://dev.azure.com/YOURORG"   # or ADO_ORG=YOURORG
#   export ADO_PROJECT="sandbox"                          # project name or id
#   export ADO_PAT="<PAT with Work Items (Read & Write) scope>"
# Optional (process-template dependent — see issues-ado.sh header):
#   export ADO_WORKITEM_TYPE="Issue"    # 'Issue' exists in the Basic process;
#                                       # use 'Task' for Agile/Scrum/CMMI
#   export ADO_CLOSED_STATE="Done"      # state 'close' writes (Basic: Done)
#
# Usage:
#   bash ado-smoke-test.sh             # creates a throwaway work item,
#                                      # exercises the full lifecycle, closes it.
#
# It talks ONLY to your project and closes the work item it creates.

set -u
BACKEND="${BACKEND:-plugins/autocoder/scripts/issues-ado.sh}"
[ -f "$BACKEND" ] || { echo "Cannot find $BACKEND — run from the repo root or set BACKEND=path"; exit 2; }

[ -n "${ADO_ORG_URL:-}" ] || [ -n "${ADO_ORG:-}" ] || { echo "Missing \$ADO_ORG_URL (or \$ADO_ORG) — see the header of this script."; exit 2; }
for v in ADO_PROJECT ADO_PAT; do
  [ -n "${!v:-}" ] || { echo "Missing \$$v — see the header of this script."; exit 2; }
done
ORG_URL="${ADO_ORG_URL:-https://dev.azure.com/${ADO_ORG}}"

PASS=0; FAIL=0
ok()   { echo "  ✅ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ❌ $1"; FAIL=$((FAIL+1)); }

echo "== 0. connectivity =="
if curl -sS -o /dev/null -w '%{http_code}' --max-time 20 \
     --user ":$ADO_PAT" \
     "${ORG_URL%/}/_apis/projects?api-version=7.1" | grep -q '^200$'; then
  ok "authenticated to $ORG_URL"
else
  bad "could not authenticate — check org URL / PAT scope / egress"; exit 1
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
assert isinstance(d["body"], str), type(d["body"]).__name__
print("  title:", d["title"]); print("  labels:", [l["name"] for l in d["labels"]])
' && ok "get round-trips (state OPEN, body is a string)" || bad "get failed"

echo "== 5. claim / release (working tag) =="
"$BACKEND" claim "$NUM"   && ok "claimed"   || bad "claim failed"
"$BACKEND" get "$NUM" | grep -q '"working"' && ok "working tag present" || bad "working tag missing after claim"
"$BACKEND" release "$NUM" && ok "released"  || bad "release failed"

echo "== 6. comment =="
"$BACKEND" comment "$NUM" --body "smoke: hello from ado-smoke-test.sh" && ok "commented" || bad "comment failed"

echo "== 7. update label =="
"$BACKEND" update "$NUM" --add-label P3 && ok "added tag P3" || bad "tag update failed"

echo "== 8. list shows the open item =="
"$BACKEND" list --state open --limit 50 | grep -q "\"number\": $NUM" \
  && ok "open list contains #$NUM" || bad "open list missing #$NUM"

echo "== 9. close =="
"$BACKEND" close "$NUM" --comment "smoke: closing throwaway work item" && ok "closed" || bad "close failed"
"$BACKEND" get "$NUM" | grep -q '"state": "CLOSED"' && ok "verified CLOSED" || bad "work item not CLOSED after close"

echo ""
echo "==== $PASS passed, $FAIL failed  (created work item #${NUM}; delete it from ADO if you like) ===="
[ "$FAIL" -eq 0 ]
