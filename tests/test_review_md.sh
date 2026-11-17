#!/bin/bash
# tests/test_review_md.sh — REVIEW.md scaffolding and wiring (#169), and that the
# slimmed CLAUDE.md still carries the config sections /fix parses.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCAFFOLD="$ROOT/plugins/autocoder/scripts/scaffold-review-md.sh"
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want '$2', got '$3'"; fi; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ── scaffold-review-md.sh ───────────────────────────────────────────────────
git init -q "$TMP/repo"; mkdir -p "$TMP/repo/sub"
OUT=$(bash "$SCAFFOLD" "$TMP/repo/sub" 2>&1); RC=$?
eq "writes a starter: exit 0" "0" "$RC"
[ -f "$TMP/repo/REVIEW.md" ] && ok "written at the repo root, not the subdir" || bad "no REVIEW.md at root: $OUT"
for want in "at most 3" "path:line" "Start the summary with a count" "Nothing to fix" "## Skip" "## What failure looks like here"; do
  grep -qF "$want" "$TMP/repo/REVIEW.md" && ok "starter covers: $want" || bad "starter lacks: $want"
done
echo "custom rules" > "$TMP/repo/REVIEW.md"
OUT=$(bash "$SCAFFOLD" "$TMP/repo" 2>&1); RC=$?
eq "existing REVIEW.md: exit 0" "0" "$RC"
eq "existing REVIEW.md is never overwritten" "custom rules" "$(cat "$TMP/repo/REVIEW.md")"
mkdir -p "$TMP/plain"
bash "$SCAFFOLD" "$TMP/plain" >/dev/null 2>&1; eq "not a git checkout: exit 1" "1" "$?"

# ── wiring ──────────────────────────────────────────────────────────────────
for f in plugins/autocoder/commands/fix.md .agent/workflows/fix.md; do
  grep -q 'If the repo has a `REVIEW.md` at its root, give it to every' "$ROOT/$f" \
    && ok "$f: reviewers get REVIEW.md" || bad "$f: review gate does not load REVIEW.md"
  grep -q 'A finding that keeps coming back across issues is a missing rule' "$ROOT/$f" \
    && ok "$f: recurring findings become rules" || bad "$f: no recurring-finding rule"
done
for f in plugins/autocoder/commands/install.md .agent/workflows/install.md; do
  grep -q 'scaffold-review-md.sh' "$ROOT/$f" && ok "$f: offers the REVIEW.md scaffold" || bad "$f: no REVIEW.md step"
done
[ -f "$ROOT/.agent/scripts/scaffold-review-md.sh" ] && ok "scaffold mirrored to .agent/scripts" || bad "not mirrored to .agent/scripts"
[ -f "$ROOT/REVIEW.md" ] && ok "this repo has its own REVIEW.md" || bad "repo REVIEW.md missing"

# ── CLAUDE.md: short, and the /fix-parsed sections survive ──────────────────
C="$ROOT/CLAUDE.md"
LINES=$(wc -l < "$C")
[ "$LINES" -le 200 ] && ok "CLAUDE.md is short ($LINES lines)" || bad "CLAUDE.md is $LINES lines (cap 200)"
TEST_COMMAND=$(sed -n "/### Regression Test Suite/,/^###/{/^\`\`\`bash$/n;p;}" "$C" | grep -v "^#" | grep -v "^\`\`\`" | grep -v "^$" | head -1)
eq "Regression Test Suite still parses" "bash tests/run-shell-suite.sh" "$TEST_COMMAND"
MERGE_MODE=$(sed -n "/### Merge Mode/,/^###/{/^\`\`\`$/n;p;}" "$C" | grep -v "^#" | grep -v "^\`\`\`" | grep -v "^$" | head -1)
eq "Merge Mode still parses" "merge" "$MERGE_MODE"
INTEGRATION=$(sed -n "/### Integration Branch/,/^###/{/^\`\`\`$/n;p;}" "$C" | grep -v "^#" | grep -v "^\`\`\`" | grep -v "^$" | head -1)
eq "Integration Branch still parses" "master" "$INTEGRATION"
grep -q '5 slash commands\|6 specialized agents\|32/32 projects' "$C" && bad "CLAUDE.md still has the stale overview" || ok "stale overview gone"
for ref in docs/maintaining.md docs/issue-backends.md docs/STRUCTURE.md; do
  [ -f "$ROOT/$ref" ] && ok "linked doc exists: $ref" || bad "CLAUDE.md links a missing doc: $ref"
done

echo ""
echo "Tests: $FAIL failed, $PASS passed, $((PASS + FAIL)) total"
[ "$FAIL" -eq 0 ]
