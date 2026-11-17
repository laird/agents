#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255: never write the real event logs
# tests/test_render_review_digest.sh — the reviewer-first body renderer (#196).
#
# A filled body renders and exits 0; an unfilled slot or the legacy
# "[Detailed explanation" placeholder exits 1; ordinary <...> / [...] text passes;
# Size is computed by the script, with parity mirrors counted on their own line;
# net growth asks for a justification; --size-only reports REVIEW FIT; Risk and
# How to revert are computed, and Verification must show a command and its
# result (#170).

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

# ── 8b. Headings inside a fence are content; CRLF is tolerated ───────────
filled
python3 - "$TMP/sections.md" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read().replace("- Mirrors are mechanical copies.\n",
    "- Mirrors are mechanical copies.\n```\n## Not verified / confidence\n## Intent\nfenced text\n```\nafter fence\n")
open(p, "w").write(s + "\n## Why net growth\nFixture data.\n")
PY
OUT=$(bash "$R" --issue 42 --base "$BASE" --sections "$TMP/sections.md" 2>/dev/null); RC=$?
[ "$RC" -eq 0 ] && ok "fenced headings: exits 0" || bad "fenced headings exited $RC"
WHERE=$(printf '%s\n' "$OUT" | awk '/^## Where to look$/{on=1;next} /^## Verification$/{on=0} on')
has "fenced headings stay inside Where to look" "$WHERE" "after fence"
# The real heading is the LAST one; the first is the fenced copy inside Where to look.
NV=$(printf '%s\n' "$OUT" | awk '/^## Not verified \/ confidence$/{buf="";on=1;next} /^## Size$/{on=0} on{buf=buf $0 "\n"} END{printf "%s", buf}')
lacks "fence content does not leak into Not verified" "$NV" "fenced text"
filled; printf '\n## Why net growth\nFixture data.\n' >> "$TMP/sections.md"
sed -i 's/$/\r/; s/^## Intent\r$/## Intent   \r/' "$TMP/sections.md"
OUT=$(bash "$R" --issue 42 --base "$BASE" --sections "$TMP/sections.md" 2>/dev/null); RC=$?
[ "$RC" -eq 0 ] && ok "CRLF + trailing-space headings: exits 0" || bad "CRLF sections exited $RC"
lacks "CRLF: no carriage returns in the body" "$OUT" $'\r'

# ── 10. Evidence: Risk, How to revert, a command in Verification (#170) ──
filled; printf '\n## Why net growth\nFixture data.\n' >> "$TMP/sections.md"
FIRST=$(git rev-list --reverse "$BASE"..HEAD | head -1); LAST=$(git rev-parse HEAD)
OUT=$(bash "$R" --issue 42 --base "$BASE" --sections "$TMP/sections.md" 2>"$TMP/err"); RC=$?
[ "$RC" -eq 0 ] && ok "evidence: filled body exits 0" || { bad "evidence: exited $RC"; cat "$TMP/err"; }
has "standard risk without risk.high" "$OUT" "**Risk**: standard"
has "close comment reverts the branch's commits" "$OUT" "git revert --no-edit ${FIRST:0:12}^..${LAST:0:12}"
OUT=$(bash "$R" --issue 42 --base "$BASE" --head "$FIRST" --sections "$TMP/sections.md" 2>/dev/null)
has "one commit: revert names it" "$OUT" "git revert --no-edit ${FIRST:0:12}\` (the one commit"
OUT=$(bash "$R" --issue 42 --base "$BASE" --sections "$TMP/sections.md" --pr 2>/dev/null)
has "PR body reverts the merge" "$OUT" "git revert -m 1 <merge commit>"
printf '\n## How to revert\nAlso restore the old config: `cp a b`.\n' >> "$TMP/sections.md"
OUT=$(bash "$R" --issue 42 --base "$BASE" --sections "$TMP/sections.md" 2>/dev/null)
REV=$(printf '%s\n' "$OUT" | awk '/^## How to revert$/{on=1;next} /^## /{on=0} on')
has "extra revert steps follow the computed line" "$REV" "Also restore the old config"
has "the computed line stays" "$REV" "git revert --no-edit"

# High risk: the tiers are read from the base.
g checkout -q master; printf '{"risk":{"high":["big.txt"]}}\n' > .autocoder.json; g add .autocoder.json; g commit -qm tiers
HB=$(git rev-parse HEAD); g checkout -q feature
OUT=$(bash "$R" --issue 42 --base "$HB" --sections "$TMP/sections.md" 2>/dev/null)
has "a risk.high path makes it high, naming the path" "$OUT" '**Risk**: high — touches `risk.high` paths in .autocoder.json (#165): `big.txt`.'
printf '{"risk":{"high":"nope"}}\n' > "$TMP/badcfg"; g checkout -q master; cp "$TMP/badcfg" .autocoder.json; g commit -qam badtiers
HB2=$(git rev-parse HEAD); g checkout -q feature
OUT=$(bash "$R" --issue 42 --base "$HB2" --sections "$TMP/sections.md" 2>/dev/null)
has "a malformed risk setting is unknown, not standard" "$OUT" "**Risk**: unknown"

# Verification needs a "$ command" and its output.
filled; printf '\n## Why net growth\nFixture data.\n' >> "$TMP/sections.md"
sed -i '/^\$ bash tests\/test_x.sh$/d' "$TMP/sections.md"
bash "$R" --issue 42 --base "$BASE" --sections "$TMP/sections.md" >/dev/null 2>"$TMP/err"; RC=$?
[ "$RC" -eq 1 ] && ok "Verification without a command exits 1" || bad "no command exited $RC"
grep -q 'starting with "\$ "' "$TMP/err" && ok "stderr says what Verification needs" || bad "stderr: $(cat "$TMP/err")"
printf '## Intent\nx\n\n## Where to look\nx\n\n## Verification\n$ bash tests/run.sh\n\n## Not verified / confidence\nx\n\n## Why net growth\nx\n' > "$TMP/noout.md"
bash "$R" --issue 42 --base "$BASE" --sections "$TMP/noout.md" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 1 ] && ok "a command with no result exits 1" || bad "command without output exited $RC"
printf '## Intent\nx\n\n## Where to look\nx\n\n## Verification\n```\n$ bash tests/run.sh\nTests: 0 failed\n```\n\n## Not verified / confidence\nx\n\n## Why net growth\nx\n' > "$TMP/fenced.md"
bash "$R" --issue 42 --base "$BASE" --sections "$TMP/fenced.md" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && ok "a fenced command and result pass" || bad "fenced evidence exited $RC"

# No diff of its own (a decomposed parent's rollup): no command needed, nothing to revert.
printf '## Intent\nx\n\n## Where to look\nx\n\n## Verification\nEvery sub-task is CLOSED.\n\n## Not verified / confidence\nx\n' > "$TMP/rollup.md"
OUT=$(bash "$R" --issue 42 --base HEAD --sections "$TMP/rollup.md" 2>"$TMP/err"); RC=$?
[ "$RC" -eq 0 ] && ok "empty diff: no command required" || { bad "rollup exited $RC"; cat "$TMP/err"; }
has "empty diff: risk none" "$OUT" "**Risk**: none"
has "empty diff: nothing to revert" "$OUT" "Nothing to revert here"

# ── 9. Bad arguments ─────────────────────────────────────────────────────
bash "$R" --issue 42 --base no-such-ref >/dev/null 2>&1; RC=$?
[ "$RC" -eq 2 ] && ok "unresolvable base exits 2" || bad "unresolvable base exited $RC"
bash "$R" --base "$BASE" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 2 ] && ok "missing --issue exits 2" || bad "missing --issue exited $RC"

echo ""
echo "Tests: $FAIL failed, $PASS passed, $((PASS + FAIL)) total"
[ "$FAIL" -eq 0 ]
