#!/bin/bash
# tests/test_fix_loop_idle.sh — verify Goal #2: zero-cost idle preflight.
# When .issues/open/ is empty, fix-loop-gate.sh should exit 1 (idle) and
# NOT write a work-plan file, so the outer loop never invokes /fix.

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
trap "rm -rf $TMP" EXIT
MAIN="$TMP/main"
mkdir -p "$MAIN"
cd "$MAIN"
git init --quiet
git config user.email test@example.com
git config user.name "Test"
echo "test" > README.md
git add README.md
git commit --quiet -m "initial"

mkdir -p "$MAIN/.issues/open" "$MAIN/.issues/working" "$MAIN/.issues/blocked" "$MAIN/.issues/closed"
cat > "$MAIN/.autocoder.json" <<EOF
{"issueSource": "file", "issueDir": "$MAIN/.issues"}
EOF

# ── Test 1: any-claimable exits 1 on empty open/ (no python spawn cost test
#           — we just verify the exit code, since that's what the gate uses) ─
cd "$MAIN"
bash -c "source $SCRIPT_DIR/issue-fns.sh && issue_any_claimable" 2>/dev/null
RC=$?
assert_eq "any-claimable exit code on empty open/" "1" "$RC"

# ── Test 2: fix-loop-gate.sh exits 1 on empty open/ ──────────────────────
WORK_JSON="$TMP/work.json"
rm -f "$WORK_JSON"
AUTOCODER_WORK_JSON="$WORK_JSON" bash "$SCRIPT_DIR/fix-loop-gate.sh" 2>/dev/null
GATE_RC=$?
assert_eq "fix-loop-gate exit code on empty open/" "1" "$GATE_RC"
if [ ! -f "$WORK_JSON" ]; then
  echo "PASS: gate did NOT write work-plan JSON (no LLM dispatch)"; PASS=$((PASS + 1))
else
  echo "FAIL: gate wrote work-plan JSON despite empty queue"; FAIL=$((FAIL + 1))
fi

# ── Test 3: with claimable work, gate exits 0 and writes work plan ───────
cat > "$MAIN/.issues/open/001.md" <<EOF
---
number: 1
title: Real work
priority: P1
labels: [bug, P1]
status: open
---
Body.
EOF
rm -f "$WORK_JSON"
AUTOCODER_WORK_JSON="$WORK_JSON" bash "$SCRIPT_DIR/fix-loop-gate.sh" 2>/dev/null
GATE_RC=$?
assert_eq "fix-loop-gate exit code when work exists" "0" "$GATE_RC"
if [ -f "$WORK_JSON" ]; then
  echo "PASS: gate wrote work-plan JSON when work exists"; PASS=$((PASS + 1))
  # Confirm the issue moved to working/ (claim succeeded)
  if [ -f "$MAIN/.issues/working/001.md" ]; then
    echo "PASS: gate claimed the issue (working/001.md exists)"; PASS=$((PASS + 1))
  else
    echo "FAIL: gate did not claim — issue not in working/"; FAIL=$((FAIL + 1))
  fi
else
  echo "FAIL: gate didn't write work-plan JSON"; FAIL=$((FAIL + 1))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
