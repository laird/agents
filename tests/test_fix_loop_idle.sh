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

# ── Test 4: starvation guard — top-priority candidate has an open blockedBy
#           edge; the gate must skip it and claim the next candidate instead
#           of reporting idle forever. ─────────────────────────────────────
rm -f "$MAIN"/.issues/*/[0-9]*.md
cat > "$MAIN/.issues/open/001.md" <<EOF
---
number: 1
title: Claimable lower-priority work
priority: P1
labels: [bug, P1]
status: open
---
Body.
EOF
cat > "$MAIN/.issues/open/002.md" <<EOF
---
number: 2
title: Top priority but blocked
priority: P0
labels: [bug, P0]
status: open
blockedBy: [3]
---
Body.
EOF
# Blocker: open, but carries a blocking label so it is not itself a candidate
# (and does not trigger the triage phase).
cat > "$MAIN/.issues/open/003.md" <<EOF
---
number: 3
title: The blocker
labels: [future]
status: open
---
Body.
EOF
rm -f "$WORK_JSON"
cd "$MAIN"
AUTOCODER_WORK_JSON="$WORK_JSON" bash "$SCRIPT_DIR/fix-loop-gate.sh" 2>"$TMP/gate4.err"
GATE_RC=$?
assert_eq "gate exit 0 when top candidate blocked but next is claimable" "0" "$GATE_RC"
if [ -f "$WORK_JSON" ] && grep -q '"issue":1' "$WORK_JSON" && grep -q '"priority":"P1"' "$WORK_JSON"; then
  echo "PASS: gate claimed the next candidate (#1, P1)"; PASS=$((PASS + 1))
else
  echo "FAIL: work plan missing or wrong: $(cat "$WORK_JSON" 2>/dev/null)"; FAIL=$((FAIL + 1))
fi
if [ -f "$MAIN/.issues/working/001.md" ] && [ -f "$MAIN/.issues/open/002.md" ]; then
  echo "PASS: #1 claimed to working/, blocked #2 left in open/"; PASS=$((PASS + 1))
else
  echo "FAIL: bucket state wrong after skip-and-claim"; FAIL=$((FAIL + 1))
fi
if grep -q "skipping #2: not claimable (rc=1)" "$TMP/gate4.err"; then
  echo "PASS: gate logged the skip of blocked #2"; PASS=$((PASS + 1))
else
  echo "FAIL: no skip log for blocked #2 — stderr: $(cat "$TMP/gate4.err")"; FAIL=$((FAIL + 1))
fi

# ── Test 5: every candidate blocked → idle (exit 1), no work plan ─────────
rm -f "$MAIN"/.issues/*/[0-9]*.md
cat > "$MAIN/.issues/open/001.md" <<EOF
---
number: 1
title: Blocked one
priority: P1
labels: [bug, P1]
status: open
blockedBy: [3]
---
Body.
EOF
cat > "$MAIN/.issues/open/002.md" <<EOF
---
number: 2
title: Blocked two
priority: P0
labels: [bug, P0]
status: open
blockedBy: [3]
---
Body.
EOF
cat > "$MAIN/.issues/open/003.md" <<EOF
---
number: 3
title: The blocker
labels: [future]
status: open
---
Body.
EOF
rm -f "$WORK_JSON"
cd "$MAIN"
AUTOCODER_WORK_JSON="$WORK_JSON" bash "$SCRIPT_DIR/fix-loop-gate.sh" 2>/dev/null
GATE_RC=$?
assert_eq "gate exit 1 (idle) when every candidate is blocked" "1" "$GATE_RC"
if [ ! -f "$WORK_JSON" ]; then
  echo "PASS: no work plan written when all candidates blocked"; PASS=$((PASS + 1))
else
  echo "FAIL: work plan written despite all candidates blocked"; FAIL=$((FAIL + 1))
fi
if [ -f "$MAIN/.issues/open/001.md" ] && [ -f "$MAIN/.issues/open/002.md" ]; then
  echo "PASS: blocked candidates left untouched in open/"; PASS=$((PASS + 1))
else
  echo "FAIL: a blocked candidate was moved out of open/"; FAIL=$((FAIL + 1))
fi

# ── Test 6: backend error during claim (rc=3) → propagated loudly, NOT
#           converted to idle, and backend stderr is not swallowed. ───────
STUB="$TMP/stub-backend.sh"
cat > "$STUB" <<'EOF'
#!/bin/bash
# Stub issue backend: list yields one FIX candidate; claim hits a backend
# error (exit 3) with a diagnostic on stderr.
case "$1" in
  list)
    echo '[{"number": 9, "title": "x", "labels": [{"name": "bug"}, {"name": "P0"}]}]'
    ;;
  claim)
    echo "stub backend: simulated backend error" >&2
    exit 3
    ;;
  *)
    exit 0
    ;;
esac
EOF
chmod +x "$STUB"
STUB_REL=$(python3 -c "import os.path; print(os.path.relpath('$STUB', '$SCRIPT_DIR'))")
MAIN2="$TMP/main2"
mkdir -p "$MAIN2"
cd "$MAIN2"
git init --quiet
git config user.email test@example.com
git config user.name "Test"
echo "test" > README.md
git add README.md
git commit --quiet -m "initial"
cat > "$MAIN2/.autocoder.json" <<EOF
{"issueSource": "stub", "issueBackend": "$STUB_REL"}
EOF
rm -f "$WORK_JSON"
AUTOCODER_WORK_JSON="$WORK_JSON" bash "$SCRIPT_DIR/fix-loop-gate.sh" 2>"$TMP/gate6.err"
GATE_RC=$?
assert_eq "gate propagates backend-error rc from claim" "3" "$GATE_RC"
if [ ! -f "$WORK_JSON" ]; then
  echo "PASS: no work plan written on backend error"; PASS=$((PASS + 1))
else
  echo "FAIL: work plan written despite backend error"; FAIL=$((FAIL + 1))
fi
if grep -q "backend error claiming #9 (rc=3)" "$TMP/gate6.err" && \
   grep -q "simulated backend error" "$TMP/gate6.err"; then
  echo "PASS: backend-error diagnostics reach stderr (not suppressed)"; PASS=$((PASS + 1))
else
  echo "FAIL: backend-error diagnostics missing — stderr: $(cat "$TMP/gate6.err")"; FAIL=$((FAIL + 1))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
