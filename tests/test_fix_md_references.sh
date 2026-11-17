#!/bin/bash
# tests/test_fix_md_references.sh — every reference pointer in a command file
# resolves on its platform (#240).
#
# /fix moved prose a worker rarely needs into reference files and left a pointer
# where each section used to be. A pointer to a file that does not ship is a
# section the worker can no longer read, and nothing else would notice:
#   Claude Code  `autocoder:references/<f>.md` -> skills/autocoder/references/ and its
#                plugin copy (plugins/autocoder/skills/autocoder/references/)
#   Codex, Droid the same files under codex-plugins/ and .factory/skills/
#   Antigravity  `.agent/shared/<f>.md`, a repo path
#   Pi           `.pi/skills/autocoder-references/<f>.md` (rewritten by packaging)

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
cd "$ROOT" || exit 1
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

refs_in() {  # refs_in <prefix-regex> <files...>: the <f>.md names pointed to
  local pre="$1"; shift
  grep -ohE "${pre}[A-Za-z0-9_-]+\.md" "$@" 2>/dev/null | sed -E "s|^${pre}||" | sort -u
}

n=0
for f in $(refs_in 'autocoder:references/' plugins/autocoder/commands/*.md); do
  n=$((n + 1))
  for d in skills/autocoder/references plugins/autocoder/skills/autocoder/references; do
    [ -f "$d/$f" ] && ok "autocoder:references/$f ships in $d" || bad "autocoder:references/$f missing from $d"
  done
done
[ "$n" -gt 0 ] && ok "Claude command files point to $n reference file(s)" || bad "no autocoder:references/ pointers found"

# The moved /fix sections ship to Codex and Droid as well, unchanged.
for src in skills/autocoder/references/fix-*.md; do
  b="${src##*/}"
  for d in codex-plugins/autocoder/skills/autocoder/references .factory/skills/autocoder/references; do
    cmp -s "$src" "$d/$b" && ok "$b identical in $d" || bad "$b missing or stale in $d"
  done
done

n=0
for f in $(refs_in '\.agent/shared/' .agent/workflows/*.md); do
  n=$((n + 1))
  [ -f ".agent/shared/$f" ] && ok ".agent/shared/$f exists" || bad ".agent/shared/$f is pointed to but missing"
done
[ "$n" -gt 0 ] && ok "Antigravity workflows point to $n shared file(s)" || bad "no .agent/shared/ pointers found"
grep -q 'autocoder:references/' .agent/workflows/fix.md \
  && bad ".agent/workflows/fix.md still uses the Claude-only autocoder:references/ path" \
  || ok ".agent/workflows/fix.md uses only repo paths"

n=0
for f in $(refs_in '\.pi/skills/autocoder-references/' .pi/prompts/*.md); do
  n=$((n + 1))
  [ -f ".pi/skills/autocoder-references/$f" ] && ok "pi: $f ships" || bad "pi: .pi/skills/autocoder-references/$f missing"
done
[ "$n" -gt 0 ] && ok "pi prompts point to $n reference file(s)" || bad "no pi reference pointers found"
grep -q 'autocoder:references/' .pi/prompts/*.md \
  && bad "a pi prompt still uses the Claude-only autocoder:references/ path" \
  || ok "pi prompts use only repo paths"

echo
echo "Tests: $FAIL failed, $PASS passed, $((PASS + FAIL)) total"
[ "$FAIL" -eq 0 ]
