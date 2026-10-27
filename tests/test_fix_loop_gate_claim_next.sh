#!/bin/bash
# tests/test_fix_loop_gate_claim_next.sh — fix-loop-gate.sh must try the next
# candidate when a sibling worker wins the claim race for the top one.
# Before this, the loser exited 1 ("no work") and slept a full tick while the
# queue still held claimable issues.

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
export ISSUE_SOURCE=file
export ISSUE_DIR_PATH="$REPO/.issues"
WORK_JSON="$TMP/work.json"

reset_issues() {
  rm -rf "$ISSUE_DIR_PATH" "$WORK_JSON"
  mkdir -p "$ISSUE_DIR_PATH"/{open,working,blocked,closed}
}

# add_issue <num> <labels, comma-separated>
add_issue() {
  local num="$1" labels="$2"
  cat > "$ISSUE_DIR_PATH/open/$(printf '%03d' "$num").md" <<EOF
---
number: $num
title: Issue $num
labels: [$labels]
status: open
---
Body.
EOF
}

# run_gate [scripts-dir] — prints the gate's exit code.
run_gate() {
  local dir="${1:-$SCRIPT_DIR}"
  AUTOCODER_WORK_JSON="$WORK_JSON" bash "$dir/fix-loop-gate.sh" 2>/dev/null
  echo $?
}

work_plan() { cat "$WORK_JSON" 2>/dev/null; }

# A copy of the scripts whose backend lets a "sibling" claim SIBLING_STEALS
# after the gate has snapshotted the queue but before its own claim lands.
# That is the real race: the gate saw the issue open, then lost the rename.
RACE_DIR="$TMP/race-scripts"
mkdir -p "$RACE_DIR"
cp "$SCRIPT_DIR"/{fix-loop-gate.sh,issue-fns.sh,issue-config.sh} "$RACE_DIR/"
cp "$SCRIPT_DIR/issues-file.py" "$RACE_DIR/issues-file-real.py"
cat > "$RACE_DIR/issues-file.py" <<'EOF'
#!/bin/bash
real="$(dirname "$0")/issues-file-real.py"
if [ "$1" = claim ] && [ "$2" = "${SIBLING_STEALS:-}" ]; then
  python3 "$real" claim "$2"
fi
exec python3 "$real" "$@"
EOF
chmod +x "$RACE_DIR/issues-file.py"

# ── 1. Sibling wins the race for #1 → gate claims #2 ──────────────────────
reset_issues
add_issue 1 "bug, P1"; add_issue 2 "bug, P1"; add_issue 3 "bug, P1"
RC=$(SIBLING_STEALS=1 run_gate "$RACE_DIR")
assert_eq "lost race: gate still exits 0" "0" "$RC"
assert_eq "lost race: work plan names the second issue" \
  '{"phase":"fix","issue":2,"priority":"P1"}' "$(work_plan)"
[ -f "$ISSUE_DIR_PATH/working/002.md" ] && [ -f "$ISSUE_DIR_PATH/open/003.md" ]
assert_eq "lost race: #2 claimed, #3 left open" "0" "$?"

# ── 1b. Every claim lost → exit 1, no work plan ───────────────────────────
reset_issues
add_issue 1 "bug, P1"
RC=$(SIBLING_STEALS=1 run_gate "$RACE_DIR")
assert_eq "all claims lost: gate exits 1" "1" "$RC"
assert_eq "all claims lost: no work plan" "" "$(work_plan)"

# ── 1c. AUTOCODER_CLAIM_MAX_TRIES caps the scan ───────────────────────────
reset_issues
add_issue 1 "bug, P1"; add_issue 2 "bug, P1"
RC=$(SIBLING_STEALS=1 AUTOCODER_CLAIM_MAX_TRIES=1 run_gate "$RACE_DIR")
assert_eq "max tries 1: gate gives up after the lost claim" "1" "$RC"
[ -f "$ISSUE_DIR_PATH/open/002.md" ]
assert_eq "max tries 1: #2 untouched" "0" "$?"

# ── 2. Two workers claim two different issues; a third finds nothing ──────
reset_issues
add_issue 1 "bug, P1"; add_issue 2 "bug, P1"
RC=$(run_gate); FIRST=$(work_plan); rm -f "$WORK_JSON"
assert_eq "worker A exits 0" "0" "$RC"
RC=$(run_gate); SECOND=$(work_plan); rm -f "$WORK_JSON"
assert_eq "worker B exits 0" "0" "$RC"
assert_eq "worker A claims #1" '{"phase":"fix","issue":1,"priority":"P1"}' "$FIRST"
assert_eq "worker B claims #2" '{"phase":"fix","issue":2,"priority":"P1"}' "$SECOND"
RC=$(run_gate)
assert_eq "worker C exits 1 on an exhausted queue" "1" "$RC"
assert_eq "worker C writes no work plan" "" "$(work_plan)"

# ── 3. Ordering: P0 bug > P1 bug > P1 enhancement ─────────────────────────
reset_issues
add_issue 1 "enhancement, P1"; add_issue 2 "bug, P1"; add_issue 3 "bug, P0"
run_gate >/dev/null
assert_eq "P0 bug claimed first" '{"phase":"fix","issue":3,"priority":"P0"}' "$(work_plan)"
run_gate >/dev/null
assert_eq "P1 bug before P1 enhancement" '{"phase":"fix","issue":2,"priority":"P1"}' "$(work_plan)"
run_gate >/dev/null
assert_eq "enhancement last" '{"phase":"enhance","issue":1}' "$(work_plan)"

# ── 4. Triage wins and claims nothing ─────────────────────────────────────
reset_issues
add_issue 1 "bug, P0"; add_issue 2 "bug"
RC=$(run_gate)
assert_eq "triage: gate exits 0" "0" "$RC"
assert_eq "triage: work plan lists the unprioritized issue" \
  '{"phase":"triage","issues":[2]}' "$(work_plan)"
assert_eq "triage: nothing claimed" "0" "$(ls "$ISSUE_DIR_PATH/working" | wc -l | tr -d ' ')"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
