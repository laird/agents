#!/bin/bash
# tests/test_issues_file_deps.sh — dependency-edge verbs on the file backend.
#
# Covers issues-file.py deps/block/unblock: edge storage in frontmatter
# (blockedBy), idempotent block, self-edge and two-node-cycle rejection,
# unblock of an absent edge, dangling-edge reporting ("missing"), blocker
# state derived from the bucket, and the KTD1 regression — comment/update
# rewrites must not drop the blockedBy key from frontmatter.
#
# Harness shape mirrors tests/test_issue_fns.sh: a throwaway git repo with
# its own .autocoder.json pointing at a temp .issues/ directory, and a
# poisoned `gh` on PATH so any accidental route to the GitHub backend fails
# loudly instead of mutating the real tracker (see bug #47 in that file).

PASS=0; FAIL=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../plugins/autocoder/scripts" && pwd)"

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

assert_eq() {
  local label="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then pass "$label"; else fail "$label — want '$want', got '$got'"; fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -q "$needle"; then pass "$label"; else fail "$label — '$needle' not in output"; fi
}

# assert_json <label> <json> <python-expr over parsed dict d>
assert_json() {
  local label="$1" json="$2" expr="$3"
  if echo "$json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
sys.exit(0 if ($expr) else 1)
" 2>/dev/null; then
    pass "$label"
  else
    fail "$label — expr '$expr' false for: $(echo "$json" | tr -d '\n')"
  fi
}

# ── Set up a bucket-layout file backend inside its own git repo ────────────
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
ISSUES_DIR="$TMP/.issues"
mkdir -p "$ISSUES_DIR/open" "$ISSUES_DIR/working" "$ISSUES_DIR/blocked" "$ISSUES_DIR/closed"

git -C "$TMP" init -q
cat > "$TMP/.autocoder.json" <<EOF
{
  "issueSource": "file",
  "issueDir": "$ISSUES_DIR"
}
EOF

# Poison `gh` so any accidental GitHub call fails loudly (bug #47 guard).
mkdir -p "$TMP/bin"
GH_TRIPWIRE="$TMP/gh-was-called"
cat > "$TMP/bin/gh" <<EOF
#!/bin/bash
echo "REAL gh INVOKED FROM TEST: \$*" >> "$GH_TRIPWIRE"
echo "test_issues_file_deps.sh must never shell out to gh" >&2
exit 97
EOF
chmod +x "$TMP/bin/gh"

run_backend() {
  (cd "$TMP" && PATH="$TMP/bin:$PATH" ISSUE_DIR_PATH="$ISSUES_DIR" \
     python3 "$SCRIPT_DIR/issues-file.py" "$@")
}

# Seed issues 1..4 through the backend's own create verb.
run_backend create --title "Blocker one" --body "b1" > /dev/null
run_backend create --title "Blocked two" --body "b2" > /dev/null
run_backend create --title "Dangling three" --body "b3" > /dev/null
run_backend create --title "Doomed four" --body "b4" > /dev/null

# ── Scenario 1: block then deps in both directions ─────────────────────────
run_backend block 2 --on 1 2>/dev/null
assert_eq "block 2 --on 1 exits 0" "0" "$?"
OUT=$(run_backend deps 2)
assert_json "deps 2 shows blocker 1 open" "$OUT" \
  'd["blockedBy"] == [{"number": 1, "state": "open"}]'
OUT=$(run_backend deps 1)
assert_json "deps 1 shows blocks: [2]" "$OUT" 'd["blocks"] == [2]'

# ── Scenario 2: block is idempotent ────────────────────────────────────────
run_backend block 2 --on 1 2>/dev/null
assert_eq "re-running block 2 --on 1 exits 0" "0" "$?"
OUT=$(run_backend deps 2)
assert_json "edge stored once after re-add" "$OUT" 'len(d["blockedBy"]) == 1'

# ── Scenario 3: self-edge and two-node cycle rejected ──────────────────────
run_backend block 2 --on 2 2>/dev/null
assert_eq "self-edge block 2 --on 2 exits 1" "1" "$?"
run_backend block 1 --on 2 2>/dev/null
assert_eq "two-node cycle block 1 --on 2 exits 1" "1" "$?"
OUT=$(run_backend deps 1)
assert_json "cycle rejection left issue 1 unblocked" "$OUT" 'd["blockedBy"] == []'

# ── Scenario 6 (KTD1 regression): comment + update preserve edges ──────────
run_backend comment 2 --body "x" 2>/dev/null
run_backend update 2 --add-label foo 2>/dev/null
OUT=$(run_backend deps 2)
assert_json "blockedBy survives comment + update rewrites" "$OUT" \
  'd["blockedBy"] == [{"number": 1, "state": "open"}]'
assert_contains "raw frontmatter still carries blockedBy" "blockedBy: \[1\]" \
  "$(cat "$ISSUES_DIR"/*/002.md)"

# ── Scenario 8: blocker moved to closed/ reports state closed ──────────────
run_backend close 1 2>/dev/null
OUT=$(run_backend deps 2)
assert_json "closed blocker reports state closed" "$OUT" \
  'd["blockedBy"] == [{"number": 1, "state": "closed"}]'

# ── Scenario 4: unblock removes the edge; repeat exits 1 ───────────────────
run_backend unblock 2 --on 1 2>/dev/null
assert_eq "unblock 2 --on 1 exits 0" "0" "$?"
OUT=$(run_backend deps 2)
assert_json "unblock removed the edge" "$OUT" 'd["blockedBy"] == []'
OUT=$(run_backend deps 1)
assert_json "reverse direction cleared too" "$OUT" 'd["blocks"] == []'
run_backend unblock 2 --on 1 2>/dev/null
assert_eq "repeated unblock of absent edge exits 1" "1" "$?"

# ── Scenario 5: dangling edge reports state missing ────────────────────────
run_backend block 3 --on 4 2>/dev/null
rm "$ISSUES_DIR/open/004.md"
OUT=$(run_backend deps 3)
assert_json "deleted blocker reports state missing" "$OUT" \
  'd["blockedBy"] == [{"number": 4, "state": "missing"}]'

# ── Scenario 7: nonexistent issues exit 1 ──────────────────────────────────
run_backend deps 999 2>/dev/null
assert_eq "deps 999 exits 1" "1" "$?"
run_backend block 999 --on 1 2>/dev/null
assert_eq "block 999 --on 1 exits 1" "1" "$?"
run_backend block 3 --on 999 2>/dev/null
assert_eq "block 3 --on 999 (missing blocker) exits 1" "1" "$?"

# ═══ U2: claimability honors blockers ══════════════════════════════════════
# State entering this section: open/ = {002 (label foo, no edges), 003
# (blockedBy [4], dangling — 004 was deleted above)}, closed/ = {001}.

# ── U2 Scenario 1: claim refused while blocker is open ─────────────────────
run_backend create --title "Blocker five" --body "b5" > /dev/null   # -> 5
run_backend create --title "Blocked six" --body "b6" > /dev/null    # -> 6
run_backend block 6 --on 5 2>/dev/null
ERR=$(run_backend claim 6 2>&1 >/dev/null)
assert_eq "claim of issue with open blocker exits 1" "1" "$?"
if [ -f "$ISSUES_DIR/open/006.md" ]; then
  pass "refused claim left the file in open/"
else
  fail "refused claim left the file in open/ — 006.md moved"
fi
assert_contains "refusal names the open blocker" "#5" "$ERR"

# ── U2 Scenario 2: closing the blocker makes the claim succeed ─────────────
run_backend close 5 2>/dev/null
run_backend claim 6 2>/dev/null
assert_eq "claim succeeds after blocker closed" "0" "$?"
if [ -f "$ISSUES_DIR/working/006.md" ]; then
  pass "successful claim moved the file to working/"
else
  fail "successful claim moved the file to working/ — 006.md not there"
fi

# ── U2 Scenario 3: blocker in working/ (claimed elsewhere) still blocks ────
run_backend create --title "Blocker seven" --body "b7" > /dev/null  # -> 7
run_backend create --title "Blocked eight" --body "b8" > /dev/null  # -> 8
run_backend block 8 --on 7 2>/dev/null
run_backend claim 7 2>/dev/null   # 7 -> working/
run_backend claim 8 2>/dev/null
assert_eq "blocker in working/ still blocks the claim" "1" "$?"

# ── U2 Scenario 4: dangling blocker does not block (R4) ────────────────────
# Issue 3 is blockedBy [4] and 004.md was deleted earlier.
run_backend claim 3 2>/dev/null
assert_eq "dangling blocker does not block the claim" "0" "$?"

# ── U2 Scenario 5: any-claimable skips issues with open blockers ───────────
# open/ = {002 (claimable), 008 (blocked by 7 in working/)}.
run_backend any-claimable 2>/dev/null
assert_eq "any-claimable exits 0 while an unblocked issue remains" "0" "$?"
run_backend claim 2 2>/dev/null  # clear the queue; only blocked 008 left
run_backend any-claimable 2>/dev/null
assert_eq "any-claimable exits 1 when the only open issue is blocked" "1" "$?"
run_backend close 7 2>/dev/null
run_backend any-claimable 2>/dev/null
assert_eq "any-claimable exits 0 once the blocker closes" "0" "$?"

# ── U2 Scenario 6: mutual cycle containment ────────────────────────────────
run_backend claim 8 2>/dev/null  # 8 is unblocked now; empty the open queue
run_backend create --title "Cycle nine" --body "c9" > /dev/null     # -> 9
run_backend create --title "Cycle ten" --body "c10" > /dev/null     # -> 10
# The block verb rejects two-node cycles, so seed the mutual edge directly —
# simulating a hand-edited or legacy tracker state.
cat > "$ISSUES_DIR/open/009.md" <<'EOF'
---
number: 9
title: Cycle nine
labels: []
status: open
blockedBy: [10]
---
c9
EOF
cat > "$ISSUES_DIR/open/010.md" <<'EOF'
---
number: 10
title: Cycle ten
labels: []
status: open
blockedBy: [9]
---
c10
EOF
run_backend any-claimable 2>/dev/null
assert_eq "mutual cycle: any-claimable exits 1" "1" "$?"
run_backend claim 9 2>/dev/null
assert_eq "mutual cycle: claim of either side exits 1" "1" "$?"

# ── U2 Scenario 7: requiredLabel gate regression ───────────────────────────
# The blocker gate must not bypass the approval gate: issue 11 has NO
# blockers (all satisfied) yet must still be refused without the label.
run_backend create --title "Unlabeled eleven" --body "b11" > /dev/null  # -> 11
(cd "$TMP" && PATH="$TMP/bin:$PATH" ISSUE_DIR_PATH="$ISSUES_DIR" \
   AUTOCODER_REQUIRED_LABEL=approved \
   python3 "$SCRIPT_DIR/issues-file.py" claim 11) 2>/dev/null
assert_eq "requiredLabel still refuses an unlabeled claim (no blockers)" "1" "$?"
if [ -f "$ISSUES_DIR/open/011.md" ]; then
  pass "label-refused claim left the file in open/"
else
  fail "label-refused claim left the file in open/ — 011.md moved"
fi
(cd "$TMP" && PATH="$TMP/bin:$PATH" ISSUE_DIR_PATH="$ISSUES_DIR" \
   AUTOCODER_REQUIRED_LABEL=approved \
   python3 "$SCRIPT_DIR/issues-file.py" any-claimable) 2>/dev/null
assert_eq "any-claimable honors requiredLabel alongside edges" "1" "$?"

# ── U2 Scenario 8: unreadable issue file is a backend failure (exit 3) ─────
if [ "$(id -u)" -ne 0 ]; then
  chmod 000 "$ISSUES_DIR/open/011.md"
  run_backend claim 11 2>/dev/null
  assert_eq "unreadable issue file during claim exits 3" "3" "$?"
  run_backend any-claimable 2>/dev/null
  assert_eq "unreadable candidate makes any-claimable exit 3" "3" "$?"
  chmod 644 "$ISSUES_DIR/open/011.md"
else
  echo "SKIP: exit-3 unreadable-file tests (running as root, chmod 000 ineffective)"
fi

# ═══ U3: issue-fns.sh dispatches the dependency verbs ══════════════════════
# Source the dispatcher with cwd inside the temp repo so issue-config.sh
# resolves the temp .autocoder.json (mirrors tests/test_issue_fns.sh).
run_ifns() {
  (cd "$TMP" && PATH="$TMP/bin:$PATH" \
     bash -c "source '$SCRIPT_DIR/issue-fns.sh'; $1") 2>/dev/null
}

run_backend create --title "Dispatch blocker" --body "d12" > /dev/null   # -> 12
run_backend create --title "Dispatch blocked" --body "d13" > /dev/null   # -> 13
run_ifns "issue_block 13 --on 12"
assert_eq "dispatcher issue_block exits 0" "0" "$?"
OUT=$(run_ifns "issue_deps 13")
assert_json "dispatcher issue_deps sees the edge" "$OUT" \
  'd["blockedBy"] == [{"number": 12, "state": "open"}]'
run_ifns "issue_unblock 13 --on 12"
assert_eq "dispatcher issue_unblock exits 0" "0" "$?"
OUT=$(run_ifns "issue_deps 13")
assert_json "dispatcher issue_unblock removed the edge" "$OUT" \
  'd["blockedBy"] == []'

# ── Guard: no invocation ever shelled out to gh ────────────────────────────
if [ -f "$GH_TRIPWIRE" ]; then
  fail "test shelled out to real gh — $(wc -l < "$GH_TRIPWIRE") call(s)"
  sed 's/^/       /' "$GH_TRIPWIRE"
else
  pass "no call reached the real gh CLI"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
