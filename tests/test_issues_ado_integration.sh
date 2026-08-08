#!/bin/bash
# tests/test_issues_ado_integration.sh — end-to-end test of issues-ado.sh
# against a STATEFUL in-process fake of the Azure DevOps WIT API
# (tests/fixtures/fake_ado.py).
#
# Complements tests/test_issues_ado.sh (which stubs curl and asserts request
# shape): here real curl talks real HTTP to a fake that maintains work-item
# state and evaluates WIQL, so the full lifecycle round-trips — create → get →
# claim/release → comment → update → close — and the state filters are checked
# against an actual query evaluator, including the untagged item that must stay
# claimable (ADO's `NOT CONTAINS` analogue of the empty-labels trap).
#
# Hermetic: ephemeral loopback port, no network, server torn down on exit.
# Skips cleanly (exit 0) if curl or python3 is missing.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
BACKEND="$REPO_ROOT/plugins/autocoder/scripts/issues-ado.sh"
FAKE="$HERE/fixtures/fake_ado.py"

if ! command -v curl >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP: curl and python3 are required for the Azure DevOps integration test"
  exit 0
fi
[ -f "$BACKEND" ] || { echo "FAIL: backend not found at $BACKEND"; exit 1; }
[ -f "$FAKE" ]    || { echo "FAIL: fake server not found at $FAKE"; exit 1; }

PASS=0; FAIL=0
ok() { echo "PASS: $1"; PASS=$((PASS + 1)); }
no() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 — want '$2' got '$3'"; fi; }

TMP=$(mktemp -d); LOG="$TMP/server.log"; SERVER_PID=""
cleanup() { [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

python3 "$FAKE" 0 >"$LOG" 2>&1 &
SERVER_PID=$!
PORT=""
for _ in $(seq 1 50); do
  PORT=$(sed -n 's/^LISTENING \([0-9]*\)$/\1/p' "$LOG" 2>/dev/null | head -1)
  [ -n "$PORT" ] && break
  kill -0 "$SERVER_PID" 2>/dev/null || break
  sleep 0.1
done
[ -n "$PORT" ] || { echo "FAIL: fake server did not report a port"; cat "$LOG"; exit 1; }

export ADO_ORG_URL="http://127.0.0.1:${PORT}"
export ADO_PROJECT="Web"
export ADO_PAT="ignored"

nums()  { python3 -c 'import json,sys; print(",".join(str(d["number"]) for d in sorted(json.load(sys.stdin), key=lambda x:x["number"])))'; }
field() { python3 -c "import json,sys; print(json.load(sys.stdin)$1)"; }

# ── state filtering against the real WIQL evaluator ─────────────────────────
# Seeded: 1=untagged, 2=P1, 3=needs-design, 4=working, 5=Closed.
eq "list --state open includes untagged (NOT CONTAINS keeps it) + P1" "1,2" "$("$BACKEND" list --state open    | nums)"
eq "list --state blocked selects only needs-design"                   "3"   "$("$BACKEND" list --state blocked | nums)"
eq "list --state working selects only the claimed item"               "4"   "$("$BACKEND" list --state working | nums)"
eq "list --state closed selects only the done item"                   "5"   "$("$BACKEND" list --state closed  | nums)"
eq "list --state all returns everything"                              "1,2,3,4,5" "$("$BACKEND" list --state all | nums)"
"$BACKEND" any-claimable; eq "any-claimable exits 0 when work exists" "0" "$?"

# ── full lifecycle round-trip ───────────────────────────────────────────────
NUM=$("$BACKEND" create --title "lifecycle probe" --body "the body" --label smoke | field '["number"]')
eq "create returns the new work item id (6)" "6" "$NUM"

eq "get round-trips the title"        "lifecycle probe" "$("$BACKEND" get "$NUM" | field '["title"]')"
eq "get round-trips the body"         "the body"        "$("$BACKEND" get "$NUM" | field '["body"]')"
eq "new work item is OPEN"            "OPEN"            "$("$BACKEND" get "$NUM" | field '["state"]')"
eq "create applied the tag"           "smoke"          "$("$BACKEND" get "$NUM" | field '["labels"][0]["name"]')"

"$BACKEND" claim "$NUM" >/dev/null
HAS=$("$BACKEND" get "$NUM" | python3 -c 'import json,sys; print("working" in [l["name"] for l in json.load(sys.stdin)["labels"]])')
eq "claim adds the working tag" "True" "$HAS"

"$BACKEND" release "$NUM" >/dev/null
HAS=$("$BACKEND" get "$NUM" | python3 -c 'import json,sys; print("working" in [l["name"] for l in json.load(sys.stdin)["labels"]])')
eq "release removes the working tag" "False" "$HAS"
# the pre-existing 'smoke' tag must survive the read-modify-write
KEPT=$("$BACKEND" get "$NUM" | python3 -c 'import json,sys; print("smoke" in [l["name"] for l in json.load(sys.stdin)["labels"]])')
eq "tag edits preserve other tags" "True" "$KEPT"

"$BACKEND" comment "$NUM" --body "hello there" >/dev/null
HASC=$("$BACKEND" get "$NUM" | python3 -c 'import json,sys; print(any(c["body"]=="hello there" for c in json.load(sys.stdin)["comments"]))')
eq "comment is persisted and returned by get" "True" "$HASC"

"$BACKEND" update "$NUM" --add-label P3 >/dev/null
HASP=$("$BACKEND" get "$NUM" | python3 -c 'import json,sys; print("P3" in [l["name"] for l in json.load(sys.stdin)["labels"]])')
eq "update --add-label adds P3" "True" "$HASP"

"$BACKEND" close "$NUM" --comment "closing" >/dev/null
eq "close moves the item to a done state (CLOSED)" "CLOSED" "$("$BACKEND" get "$NUM" | field '["state"]')"

"$BACKEND" get 999 >/dev/null 2>&1; eq "get on a missing work item exits 1" "1" "$?"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
