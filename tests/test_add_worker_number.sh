#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255: never write the real event logs
# tests/test_add_worker_number.sh — add-worker numbers a new worker after the ones the
# swarm already has (#233). Under --no-worktrees it used to answer 1 every time, so the
# new worker's manifest entry, wt1-<project> label and AUTOCODER_WORKER marker collided
# with worker 1's.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$ROOT/plugins/autocoder/scripts"
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want '$2', got '$3'"; fi; }

# shellcheck source=../plugins/autocoder/scripts/swarm-manifest-lib.sh
source "$S/swarm-manifest-lib.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
P="$TMP/proj"; mkdir -p "$P"
M="$TMP/m.json"
manifest() { python3 -c 'import json,sys; json.dump({"workers":[{"number":int(n)} for n in sys.argv[2:]]}, open(sys.argv[1],"w"))' "$M" "$@"; }

# ── --no-worktrees ──────────────────────────────────────────────────────────
eq "no manifest, no worktrees: 1 (nothing to consult)" "1" "$(next_worker_number "" "$P" false)"
manifest 1
eq "no-worktrees: worker 1 exists -> 2" "2" "$(next_worker_number "$M" "$P" false)"
manifest 1 2 3
eq "no-worktrees: 1..3 exist -> 4" "4" "$(next_worker_number "$M" "$P" false)"
manifest 1 3
eq "no-worktrees: fills the gap (2)" "2" "$(next_worker_number "$M" "$P" false)"
manifest
eq "empty manifest -> 1" "1" "$(next_worker_number "$M" "$P" false)"
mkdir -p "$P-wt-1"
eq "no-worktrees ignores -wt-N dirs" "1" "$(next_worker_number "$M" "$P" false)"

# ── worktrees ───────────────────────────────────────────────────────────────
rm -rf "$P-wt-1"
eq "worktrees, nothing yet -> 1" "1" "$(next_worker_number "" "$P" true)"
mkdir -p "$P-wt-1" "$P-wt-2"
eq "worktrees: skips existing -wt-1, -wt-2 -> 3" "3" "$(next_worker_number "" "$P" true)"
manifest 1 3
eq "worktrees: skips manifest numbers too (3 taken) -> 4" "4" "$(next_worker_number "$M" "$P" true)"
rm -rf "$P-wt-1" "$P-wt-2"; manifest 1
eq "worktrees: worker 1 is the main checkout (no -wt-1) -> 2" "2" "$(next_worker_number "$M" "$P" true)"

# ── robustness ──────────────────────────────────────────────────────────────
echo '{"workers":[{"number":"x"},{"number":1}]}' > "$M"
eq "non-numeric entries are ignored" "2" "$(next_worker_number "$M" "$P" false)"
echo 'not json' > "$M"
eq "unreadable manifest -> treated as empty" "1" "$(next_worker_number "$M" "$P" false)"

# ── add-worker.sh uses it ───────────────────────────────────────────────────
grep -q 'WORKER_NUM=$(next_worker_number ' "$S/add-worker.sh" && ok "add-worker.sh takes its number from next_worker_number" \
  || bad "add-worker.sh does not use next_worker_number"
grep -q '^WORKER_NUM=1$' "$S/add-worker.sh" && bad "add-worker.sh still hardcodes WORKER_NUM=1" || ok "no hardcoded WORKER_NUM=1"

echo ""
echo "Tests: $FAIL failed, $PASS passed, $((PASS + FAIL)) total"
[ "$FAIL" -eq 0 ]
