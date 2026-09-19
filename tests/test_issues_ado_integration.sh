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

# ── server lifecycle helper ─────────────────────────────────────────────────
# start_fake [VAR=val ...] — (re)start the fake with the given environment on
# a fresh ephemeral port and point ADO_ORG_URL at it. Later sections restart
# with dependency seeds and failure toggles.
start_fake() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null && wait "$SERVER_PID" 2>/dev/null
  : > "$LOG"
  env "$@" python3 "$FAKE" 0 >"$LOG" 2>&1 &
  SERVER_PID=$!
  PORT=""
  for _ in $(seq 1 50); do
    PORT=$(sed -n 's/^LISTENING \([0-9]*\)$/\1/p' "$LOG" 2>/dev/null | head -1)
    [ -n "$PORT" ] && break
    kill -0 "$SERVER_PID" 2>/dev/null || break
    sleep 0.1
  done
  if [ -z "$PORT" ]; then
    echo "FAIL: fake server did not report a port"; cat "$LOG"; exit 1
  fi
  export ADO_ORG_URL="http://127.0.0.1:${PORT}"
}

start_fake
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

# ── dependency edges: full lifecycle on the deps seed ────────────────────────
# Seeds: 1 = busy blocker (working tag, OPEN), 2 = blocked by 1, 3 = free.
start_fake FAKE_ADO_SEED_MODE=deps

DEPS2=$("$BACKEND" deps 2)
eq "deps: blocked item reports its blocker with state" \
  '{"blockedBy": [{"number": 1, "state": "open"}], "blocks": []}' "$DEPS2"
DEPS1=$("$BACKEND" deps 1)
eq "deps: blocker reports the blocks direction" \
  '{"blockedBy": [], "blocks": [2]}' "$DEPS1"

"$BACKEND" claim 2 >/dev/null 2>&1; eq "claim of a blocked item is refused (exit 1)" "1" "$?"
"$BACKEND" any-claimable;           eq "any-claimable skips the blocked first candidate, finds the free one" "0" "$?"

"$BACKEND" block 2 --on 1 >/dev/null 2>&1; eq "idempotent re-add exits 0 (no 400 from ADO's duplicate check)" "0" "$?"
NEDGES=$("$BACKEND" deps 2 | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["blockedBy"]))')
eq "idempotent re-add stored no second edge" "1" "$NEDGES"
"$BACKEND" block 2 --on 2 >/dev/null 2>&1; eq "self-edge exits 1" "1" "$?"
"$BACKEND" block 1 --on 2 >/dev/null 2>&1; eq "direct two-node cycle exits 1" "1" "$?"

"$BACKEND" block 3 --on 1 >/dev/null 2>&1;   eq "block on a fresh pair exits 0" "0" "$?"
"$BACKEND" unblock 3 --on 1 >/dev/null 2>&1; eq "unblock removes the edge (exit 0)" "0" "$?"
"$BACKEND" unblock 3 --on 1 >/dev/null 2>&1; eq "unblock of an absent edge exits 1" "1" "$?"

"$BACKEND" close 1 >/dev/null 2>&1
"$BACKEND" claim 2 >/dev/null 2>&1; eq "claim succeeds once the blocker is closed" "0" "$?"

# ── unblock removes the CORRECT relation when several exist ─────────────────
# 2 is blocked by both 1 (seeded) and 3 (added); removing the 1-edge must
# leave the 3-edge intact — a wrong /relations/<idx> would delete the other.
start_fake FAKE_ADO_SEED_MODE=deps
"$BACKEND" block 2 --on 3 >/dev/null 2>&1
"$BACKEND" unblock 2 --on 1 >/dev/null 2>&1; eq "unblock one of two edges exits 0" "0" "$?"
LEFT=$("$BACKEND" deps 2 | python3 -c 'import json,sys; print(",".join(str(b["number"]) for b in json.load(sys.stdin)["blockedBy"]))')
eq "the untouched edge survives (still blocked by 3, not 1)" "3" "$LEFT"
BLOCKS3=$("$BACKEND" deps 3 | field '["blocks"]')
eq "the surviving edge still renders from the blocker side" "[2]" "$BLOCKS3"

# ── tag edits and relation edits don't clobber each other ───────────────────
"$BACKEND" update 2 --add-label P9 >/dev/null 2>&1
LEFT=$("$BACKEND" deps 2 | python3 -c 'import json,sys; print(",".join(str(b["number"]) for b in json.load(sys.stdin)["blockedBy"]))')
eq "a tag edit after a relation edit leaves the relation intact" "3" "$LEFT"
HASP9=$("$BACKEND" get 2 | python3 -c 'import json,sys; print("P9" in [l["name"] for l in json.load(sys.stdin)["labels"]])')
eq "and the tag itself sticks" "True" "$HASP9"

# ── dangling blocker counts as satisfied (R4) ────────────────────────────────
start_fake FAKE_ADO_SEED_MODE=deps FAKE_ADO_404_ON_ITEM=1
STATE=$("$BACKEND" deps 2 | python3 -c 'import json,sys; print(json.load(sys.stdin)["blockedBy"][0]["state"])')
eq "vanished blocker reports state missing" "missing" "$STATE"
"$BACKEND" claim 2 >/dev/null 2>&1; eq "dangling blocker does not block the claim" "0" "$?"

# ── resolution failure is exit 3, never a clean negative ────────────────────
start_fake FAKE_ADO_SEED_MODE=deps FAKE_ADO_500_ON_ITEM=1
"$BACKEND" claim 2 >/dev/null 2>&1;        eq "blocker-resolution HTTP 500 makes claim exit 3" "3" "$?"
"$BACKEND" any-claimable >/dev/null 2>&1;  eq "blocker-resolution HTTP 500 makes any-claimable exit 3" "3" "$?"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
