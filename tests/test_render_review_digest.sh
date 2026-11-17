#!/bin/bash
# tests/test_render_review_digest.sh — the reviewer-first body renderer (#196).
#
# A filled body renders and exits 0; an unfilled slot or the legacy
# "[Detailed explanation" placeholder exits 1; ordinary <...> / [...] text passes;
# Size is computed by the script, with parity mirrors counted on their own line;
# net growth asks for a justification; --size-only reports REVIEW FIT.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
R="$ROOT/plugins/autocoder/scripts/render-review-digest.sh"

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
has()   { if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1 — missing: $3"; fi; }
lacks() { if printf '%s' "$2" | grep -qF -- "$3"; then bad "$1 — unexpected: $3"; else ok "$1"; fi; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
g() { git -c user.email=t@example.com -c user.name=T "$@"; }

cd "$TMP" || exit 1
git init -q -b master repo; cd repo || exit 1
printf 'a\nb\n' > app.sh; g add .; g commit -qm base
BASE=$(git rev-parse HEAD)
g checkout -q -b feature
printf 'a\nB\nc\n' > app.sh                                     # +2/-1 in source
mkdir -p .agent/scripts plugins/autocoder/skills/x codex-plugins/autocoder
printf 'a\nB\nc\n' > .agent/scripts/app.sh                      # mirrors: +3 each
printf 'a\nB\nc\n' > plugins/autocoder/skills/x/app.sh
printf 'a\nB\nc\n' > codex-plugins/autocoder/app.sh
g add -A; g commit -qm change

filled() {
  cat > "$TMP/sections.md" <<'EOF'
## Intent
Stop the gate from double-claiming issues whose branch is live.

## Where to look
- app.sh:2 — the changed condition.
- Mirrors are mechanical copies.

## Verification
$ bash tests/test_x.sh
Tests: 0 failed, 9 passed, 9 total
Returned Vec<T> for <sha>; see [the doc](https://example.com) and `cmd > out`.

## Not verified / confidence
Not run against Jira. Confidence: high.
EOF
}

# ── 1. A filled body renders, exit 0 ──────────────────────────────────────
filled
OUT=$(bash "$R" --issue 42 --base "$BASE" --sections "$TMP/sections.md" 2>"$TMP/err"); RC=$?
[ "$RC" -eq 0 ] && ok "filled body exits 0" || { bad "filled body exited $RC"; cat "$TMP/err"; }
has  "intent rendered" "$OUT" "Stop the gate from double-claiming"
has  "generic <...>, [link](url) and redirection survive" "$OUT" 'Vec<T> for <sha>; see [the doc](https://example.com) and `cmd > out`'
lacks "close comment has no 'Closes #'" "$OUT" "Closes #42"
lacks "no FILL slot left" "$OUT" "{{FILL:"

# ── 2. Size is computed, mirrors separated ───────────────────────────────
has "size counts only source" "$OUT" "+2/−1 across 1 files"
has "mirrors on their own line" "$OUT" "Parity mirrors, not counted above: +9/−0 across 3 files"

# ── 3. --pr prefixes Closes #N ───────────────────────────────────────────
OUT=$(bash "$R" --issue 42 --base "$BASE" --sections "$TMP/sections.md" --pr 2>/dev/null)
[ "$(printf '%s\n' "$OUT" | head -1)" = "Closes #42" ] && ok "--pr starts with Closes #42" || bad "--pr first line: $(printf '%s\n' "$OUT" | head -1)"

# ── 4. A missing section fails with a FILL slot ──────────────────────────
grep -v '^Not run against Jira' "$TMP/sections.md" | sed '/^## Not verified/d' > "$TMP/partial.md"
OUT=$(bash "$R" --issue 42 --base "$BASE" --sections "$TMP/partial.md" 2>"$TMP/err"); RC=$?
[ "$RC" -eq 1 ] && ok "missing section exits 1" || bad "missing section exited $RC"
has "missing section rendered as FILL" "$OUT" "{{FILL: what was not exercised"
grep -q "unfilled slots" "$TMP/err" && ok "stderr names the problem" || bad "no stderr explanation"

# ── 5. No sections at all fails ──────────────────────────────────────────
bash "$R" --issue 42 --base "$BASE" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 1 ] && ok "no sections exits 1" || bad "no sections exited $RC"

# ── 6. A FILL slot or legacy placeholder typed into a section fails ───────
filled; sed -i 's/^Not run against Jira. Confidence: high./{{FILL: later}}/' "$TMP/sections.md"
bash "$R" --issue 42 --base "$BASE" --sections "$TMP/sections.md" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 1 ] && ok "FILL inside a section exits 1" || bad "FILL inside a section exited $RC"
filled; sed -i 's/^Stop the gate.*/[Detailed explanation of fix]/' "$TMP/sections.md"
bash "$R" --issue 42 --base "$BASE" --sections "$TMP/sections.md" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 1 ] && ok "legacy [Detailed explanation exits 1" || bad "legacy placeholder exited $RC"

# ── 7. Net growth asks for a justification ───────────────────────────────
seq 1 300 > big.txt; g add big.txt; g commit -qm big
filled
OUT=$(bash "$R" --issue 42 --base "$BASE" --sections "$TMP/sections.md" 2>/dev/null); RC=$?
[ "$RC" -eq 1 ] && ok "net growth without a reason exits 1" || bad "net growth without a reason exited $RC"
has "net growth slot rendered" "$OUT" "Why net growth: {{FILL:"
printf '\n## Why net growth\nNew fixture data the tests read.\n' >> "$TMP/sections.md"
OUT=$(bash "$R" --issue 42 --base "$BASE" --sections "$TMP/sections.md" 2>/dev/null); RC=$?
[ "$RC" -eq 0 ] && ok "net growth with a reason exits 0" || bad "net growth with a reason exited $RC"
has "net growth reason rendered" "$OUT" "Why net growth: New fixture data the tests read."

# ── 8. --size-only and REVIEW FIT thresholds ─────────────────────────────
S=$(bash "$R" --size-only --base "$BASE")
check_size() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want '$2', got '$3'"; fi; }
check_size "size-only line, within the default limits" "changed=303 files=2 mirror_changed=9 mirror_files=3 over=no" "$S"
S=$(AUTOCODER_REVIEW_MAX_LINES=100 bash "$R" --size-only --base "$BASE")
check_size "env threshold makes it over" "over=yes" "${S##* }"
printf '{"review":"always","reviewFit":{"maxChangedLines":1000,"maxFiles":1}}\n' > .autocoder.json
S=$(bash "$R" --size-only --base "$BASE")
check_size ".autocoder.json reviewFit.maxFiles applies" "over=yes" "${S##* }"
rm .autocoder.json
OUT=$(AUTOCODER_REVIEW_MAX_LINES=100 bash "$R" --issue 42 --base "$BASE" --sections "$TMP/sections.md" 2>/dev/null)
has "over-limit body says so" "$OUT" "over the review-fit limit of 100 lines"

# ── 9. Bad arguments ─────────────────────────────────────────────────────
bash "$R" --issue 42 --base no-such-ref >/dev/null 2>&1; RC=$?
[ "$RC" -eq 2 ] && ok "unresolvable base exits 2" || bad "unresolvable base exited $RC"
bash "$R" --base "$BASE" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 2 ] && ok "missing --issue exits 2" || bad "missing --issue exited $RC"

echo ""
echo "Tests: $FAIL failed, $PASS passed, $((PASS + FAIL)) total"
[ "$FAIL" -eq 0 ]
