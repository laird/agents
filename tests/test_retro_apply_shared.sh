#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255: never write the real event logs
# tests/test_retro_apply_shared.sh — /retro-apply ships in both plugins from one source (#150).
#
# plugins/modernize/commands/retro-apply.md is the source; the packager copies it
# byte-for-byte to plugins/autocoder/commands/retro-apply.md and its --check fails on
# drift. The protocol handles either plugin's IMPROVEMENTS.md, its script mentions do
# not leak into autocoder's script package, and every platform's docs point to it.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/plugins/modernize/commands/retro-apply.md"
COPY="$ROOT/plugins/autocoder/commands/retro-apply.md"
PACKAGER="$ROOT/scripts/package-plugin-scripts.py"
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# ── One source, one byte-identical copy ──────────────────────────────────────
[ -f "$SRC" ] && [ -f "$COPY" ] || { bad "missing $SRC or $COPY"; echo "Results: $PASS passed, $FAIL failed"; exit 1; }
cmp -s "$SRC" "$COPY" && ok "the autocoder copy is byte-identical to the modernize source" \
  || bad "plugins/autocoder/commands/retro-apply.md differs from the modernize source: $(diff "$SRC" "$COPY" | head -4)"
grep -qF 'plugins/autocoder/commands/retro-apply.md": "plugins/modernize/commands/retro-apply.md"' "$PACKAGER" \
  && ok "the packager's SHARED_COMMANDS names the pair" || bad "SHARED_COMMANDS does not map the autocoder copy to the modernize source"
head -8 "$SRC" | grep -qF 'tests/test_retro_apply_shared.sh' && ok "the source says it is shared and where the copy goes" \
  || bad "the source's header does not mark it as shared"

# The packager's --check sees drift in a scratch copy of the tree, and sync repairs it.
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/t"
( cd "$ROOT" && git ls-files -z --cached --others --exclude-standard ) | ( cd "$ROOT" && xargs -0 cp --parents -t "$TMP/t" 2>/dev/null )
printf '\nlocal edit\n' >> "$TMP/t/plugins/autocoder/commands/retro-apply.md"
OUT=$(python3 "$TMP/t/scripts/package-plugin-scripts.py" --check 2>&1); RC=$?
[ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -qF 'STALE    plugins/autocoder/commands/retro-apply.md' \
  && ok "--check fails and names the stale copy after an edit to it" || bad "--check missed the edited copy (rc $RC): $(printf '%s' "$OUT" | tail -3)"
python3 "$TMP/t/scripts/package-plugin-scripts.py" >/dev/null 2>&1
cmp -s "$TMP/t/plugins/modernize/commands/retro-apply.md" "$TMP/t/plugins/autocoder/commands/retro-apply.md" \
  && ok "a sync puts the source back over the edited copy" || bad "sync did not restore the copy"
rm "$TMP/t/plugins/autocoder/commands/retro-apply.md"
OUT=$(python3 "$TMP/t/scripts/package-plugin-scripts.py" --check 2>&1); RC=$?
[ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -qF 'MISSING  plugins/autocoder/commands/retro-apply.md' \
  && ok "--check fails when the copy is missing" || bad "--check missed the missing copy (rc $RC)"

# A shared copy's script mentions do not seed autocoder's package (they are examples
# of scripts to write, and a plugin copy would shadow the root scripts/ source).
for s in analyze-dependencies.sh enforce-coverage.sh; do
  grep -qF "$s" "$COPY" || { bad "the shared protocol no longer mentions $s; update this check"; continue; }
  [ ! -e "$ROOT/plugins/autocoder/scripts/$s" ] && ok "$s, named only in the shared copy, is not shipped in plugins/autocoder/scripts" \
    || bad "plugins/autocoder/scripts/$s exists; the shared copy's mention leaked into the package"
done

# ── The protocol handles both plugins' IMPROVEMENTS.md ───────────────────────
grep -qF '# Autocoder Process Improvement Recommendations' "$SRC" && grep -qF 'plugins/autocoder/commands/' "$SRC" \
  && ok "retro-apply tells an autocoder retrospective apart and names autocoder's protocols" || bad "retro-apply has no autocoder target"
grep -qF '# Autocoder Process Improvement Recommendations' "$ROOT/plugins/autocoder/commands/retro.md" \
  && ok "autocoder /retro still writes the title retro-apply keys on" || bad "autocoder /retro's IMPROVEMENTS.md title changed; retro-apply's detection is stale"
# Run the detection block against both kinds of IMPROVEMENTS.md.
BLOCK="$TMP/detect.sh"
awk '/^# Whose protocols this IMPROVEMENTS.md targets\./ {g=1} g && /^```$/ {exit} g' "$SRC" > "$BLOCK"
mkdir -p "$TMP/a" "$TMP/m"
printf '# Autocoder Process Improvement Recommendations\n\n## Recommendations\n' > "$TMP/a/IMPROVEMENTS.md"
printf '# Modernization Retrospective: Improvements\n\n## Recommendations\n' > "$TMP/m/IMPROVEMENTS.md"
[ "$(cd "$TMP/a" && bash "$BLOCK")" = "autocoder: plugins/autocoder/commands/ and plugins/autocoder/scripts/" ] \
  && ok "the detection block picks autocoder for an autocoder IMPROVEMENTS.md" || bad "autocoder IMPROVEMENTS.md detected as: $(cd "$TMP/a" && bash "$BLOCK")"
[ "$(cd "$TMP/m" && bash "$BLOCK")" = "modernize: plugins/modernize/commands/ and plugins/modernize/agents/" ] \
  && ok "the detection block picks modernize otherwise" || bad "modernize IMPROVEMENTS.md detected as: $(cd "$TMP/m" && bash "$BLOCK")"

# ── Antigravity, docs and every platform's command mapping ───────────────────
grep -qF 'Autocoder Process Improvement' "$ROOT/.agent/workflows/retro-apply.md" \
  && ok ".agent/workflows/retro-apply.md covers the autocoder retrospective too" || bad "the Antigravity workflow is still modernize-only"
for f in plugins/autocoder/commands/retro.md .agent/workflows/retro.md \
         plugins/autocoder/commands/autocoder-help.md .agent/workflows/autocoder-help.md \
         plugins/autocoder/README.md docs/maintaining.md \
         skills/autocoder/references/command-mapping.md \
         plugins/autocoder/skills/autocoder/references/command-mapping.md \
         codex-plugins/autocoder/skills/autocoder/references/command-mapping.md \
         .factory/skills/autocoder/references/command-mapping.md \
         .pi/skills/autocoder-references/command-mapping.md; do
  grep -qF '/retro-apply' "$ROOT/$f" && ok "$f mentions /retro-apply" || bad "$f does not mention /retro-apply"
done
awk '/^## \[Unreleased\]/ {on=1; next} on && /^## \[/ {exit} on' "$ROOT/plugins/autocoder/CHANGELOG.md" | grep -qF '#150' \
  && ok "CHANGELOG [Unreleased] notes #150" || bad "CHANGELOG [Unreleased] has no #150 entry"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
