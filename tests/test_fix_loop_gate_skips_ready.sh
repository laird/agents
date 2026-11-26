#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255: never write the real event logs
# tests/test_fix_loop_gate_skips_ready.sh — with a `train` section in the main
# worktree's .autocoder.json, fix-loop-gate.sh must not claim an issue carrying one
# of `train.readyLabels` (default `ready-for-review`): a worker posted READY and the
# train will land it. Before #405 the gate claimed it every tick and the claim was
# released again seconds later. Without a `train` section nothing changes.

PASS=0; FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)/plugins/autocoder/scripts"

assert_eq() {
  local label="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    echo "PASS: $label"; PASS=$((PASS + 1))
  else
    echo "FAIL: $label — want '$want', got '$got'"; FAIL=$((FAIL + 1))
  fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
REPO="$TMP/repo"
mkdir -p "$REPO"
cd "$REPO" || exit 1
git init --quiet
export AUTOCODER_RESUME_OWN_CLAIM=0
export ISSUE_SOURCE=file
export ISSUE_DIR_PATH="$REPO/.issues"
WORK_JSON="$TMP/work.json"
GATE_ERR="$TMP/gate.err"

reset_issues() {
  rm -rf "$ISSUE_DIR_PATH" "$WORK_JSON"
  mkdir -p "$ISSUE_DIR_PATH"/{open,working,blocked,closed}
}

# add_issue <num> <labels, comma-separated>
add_issue() {
  cat > "$ISSUE_DIR_PATH/open/$(printf '%03d' "$1").md" <<ISSUE
---
number: $1
title: Issue $1
labels: [$2]
status: open
---
Body.
ISSUE
}

run_gate() {
  AUTOCODER_WORK_JSON="$WORK_JSON" bash "$SCRIPT_DIR/fix-loop-gate.sh" 2>"$GATE_ERR" >/dev/null
  echo $?
}

work_plan() { cat "$WORK_JSON" 2>/dev/null; }
ready_count() { sed -n 's/.*ready (train): \([0-9]*\).*/\1/p' "$GATE_ERR"; }
still_open() { [ -f "$ISSUE_DIR_PATH/open/$(printf '%03d' "$1").md" ] && echo yes || echo no; }

# ── 1. readyLabels named: the ready P1 is skipped, the P2 claimed ─────────
printf '{"train": {"readyLabels": ["ready-for-review"]}}\n' > "$REPO/.autocoder.json"
reset_issues
add_issue 1 "bug, P1, ready-for-review"; add_issue 2 "bug, P2"
RC=$(run_gate)
assert_eq "named readyLabels: gate exits 0" "0" "$RC"
assert_eq "named readyLabels: the P2 without the label is claimed" '{"phase":"fix","issue":2,"priority":"P2"}' "$(work_plan)"
assert_eq "named readyLabels: the ready P1 stays open" "yes" "$(still_open 1)"
assert_eq "named readyLabels: the skip is counted" "1" "$(ready_count)"

# ── 2. A train section naming no readyLabels: the default applies ─────────
printf '{"train": {"size": 4}}\n' > "$REPO/.autocoder.json"
reset_issues
add_issue 1 "bug, P1, ready-for-review"; add_issue 2 "bug, P2"
run_gate >/dev/null
assert_eq "default readyLabels: the P2 is claimed" '{"phase":"fix","issue":2,"priority":"P2"}' "$(work_plan)"
assert_eq "default readyLabels: the ready P1 stays open" "yes" "$(still_open 1)"
assert_eq "default readyLabels: the skip is counted" "1" "$(ready_count)"

# ── 3. No train section: behaviour unchanged, the ready P1 is claimed ─────
printf '{"claims": {"avoid_overlap": "off"}}\n' > "$REPO/.autocoder.json"
reset_issues
add_issue 1 "bug, P1, ready-for-review"; add_issue 2 "bug, P2"
run_gate >/dev/null
assert_eq "no train: the ready P1 is claimed" '{"phase":"fix","issue":1,"priority":"P1"}' "$(work_plan)"
assert_eq "no train: no ready count" "" "$(ready_count)"
rm -f "$REPO/.autocoder.json"
reset_issues
add_issue 1 "bug, P1, ready-for-review"
run_gate >/dev/null
assert_eq "no config file: the ready P1 is claimed" '{"phase":"fix","issue":1,"priority":"P1"}' "$(work_plan)"

# ── 4. A custom label list blocks either label ────────────────────────────
printf '{"train": {"readyLabels": ["ready", "banked"]}}\n' > "$REPO/.autocoder.json"
reset_issues
add_issue 1 "bug, P1, ready"; add_issue 2 "bug, P1, banked"; add_issue 3 "bug, P2, ready-for-review"
run_gate >/dev/null
assert_eq "custom readyLabels: only the issue with neither label is claimed" '{"phase":"fix","issue":3,"priority":"P2"}' "$(work_plan)"
assert_eq "custom readyLabels: both ready issues stay open" "yes yes" "$(still_open 1) $(still_open 2)"
assert_eq "custom readyLabels: both skips are counted" "2" "$(ready_count)"

# ── 5. Only ready issues: the gate idles and claims nothing ───────────────
printf '{"train": {}}\n' > "$REPO/.autocoder.json"
reset_issues
add_issue 1 "bug, P0, ready-for-review"; add_issue 2 "bug, P1, ready-for-review"
RC=$(run_gate)
assert_eq "only ready issues: gate exits 1 (idle)" "1" "$RC"
assert_eq "only ready issues: no work plan" "" "$(work_plan)"
assert_eq "only ready issues: both stay open" "yes yes" "$(still_open 1) $(still_open 2)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
