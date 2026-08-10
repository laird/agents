#!/bin/bash
# tests/test_skill_packaging.sh — guards that every repo skill is actually
# packaged into the Claude Code plugin that ships it.
#
# WHY THIS EXISTS:
#   The repo kept its skills in a root-level skills/ tree and packaged them for
#   Codex (codex-plugins/*/skills/) and Droid (.factory/skills/) — but never for
#   Claude Code. plugins/autocoder/ shipped commands, hooks and scripts and no
#   skills at all, and neither marketplace.json entry declared a `skills` key.
#
#   Claude Code loads plugin skills from <plugin-root>/skills/, so installing
#   the autocoder plugin delivered zero skills. Two consequences went unnoticed:
#     - the `improve` skill was unreachable for every Claude Code user;
#     - the command files tell agents to read `autocoder:references/model-config.md`,
#       a plugin-namespaced path that resolved nowhere.
#   Both looked fine in the repo, because the files existed — just not where the
#   packaging could reach them.
#
# The mirrors are byte-identical copies, not symlinks: plugin installation
# copies trees, and a symlink that survives git may not survive the install.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
cd "$ROOT" || exit 1

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# Which plugin ships which root skill. A new skills/<name>/ directory must be
# added here AND packaged, or the "every root skill is packaged" check fails.
declare -a SKILL_OWNER=(
  "autocoder:plugins/autocoder/skills"
  "improve:plugins/autocoder/skills"
  "modernize:plugins/modernize/skills"
)

owner_of() {
  local name="$1" entry
  for entry in "${SKILL_OWNER[@]}"; do
    [ "${entry%%:*}" = "$name" ] && { echo "${entry#*:}"; return 0; }
  done
  return 1
}

# ── Every root skill must be owned and packaged ───────────────────────────
for dir in skills/*/; do
  name="$(basename "$dir")"
  if ! target="$(owner_of "$name")"; then
    bad "skills/$name is not listed in SKILL_OWNER — it ships to no plugin"
    continue
  fi
  if [ -f "$target/$name/SKILL.md" ]; then
    ok "skills/$name packaged into $target/$name"
  else
    bad "skills/$name missing from $target/$name — Claude Code users cannot load it"
  fi
done

# ── Packaged copies must be byte-identical to the root tree ───────────────
for entry in "${SKILL_OWNER[@]}"; do
  name="${entry%%:*}"; target="${entry#*:}"
  [ -d "skills/$name" ] || { bad "$name: no root skills/$name to package from"; continue; }
  [ -d "$target/$name" ] || continue  # already reported above

  # Compare both directions so an extra file in the package is caught too.
  # .DS_Store is a macOS artifact that must never ship.
  if diff -r -x '.DS_Store' "skills/$name" "$target/$name" >/dev/null 2>&1; then
    ok "$name: packaged copy identical to skills/$name"
  else
    bad "$name: packaged copy diverged from skills/$name:
$(diff -r -x '.DS_Store' "skills/$name" "$target/$name" 2>&1 | head -5)"
  fi

  if find "$target/$name" -name '.DS_Store' | grep -q .; then
    bad "$name: .DS_Store packaged into $target/$name"
  else
    ok "$name: no .DS_Store in the packaged tree"
  fi
done

# ── A skill's declared name must match its directory ──────────────────────
# Claude Code namespaces a plugin skill as <plugin>:<dir>, but the frontmatter
# `name:` is what the model is told to invoke. When #112 renamed harden to
# improve, a stale frontmatter name would have silently kept the old handle.
for entry in "${SKILL_OWNER[@]}"; do
  name="${entry%%:*}"; target="${entry#*:}"
  f="$target/$name/SKILL.md"
  [ -f "$f" ] || continue
  declared=$(awk -F': *' '/^name:/ {print $2; exit}' "$f" | tr -d '[:space:]')
  if [ "$declared" = "$name" ]; then
    ok "$name: frontmatter name matches directory"
  else
    bad "$name: frontmatter declares name '$declared' but directory is '$name'"
  fi
done

# ── Paths the command files tell agents to read must exist in the package ──
# `autocoder:references/model-config.md` is a plugin-namespaced reference, so it
# resolves against the autocoder plugin's own skills tree, not the repo root.
while IFS= read -r ref; do
  rel="${ref#autocoder:}"
  if [ -f "plugins/autocoder/skills/autocoder/$rel" ]; then
    ok "command reference autocoder:$rel resolves in the packaged plugin"
  else
    bad "command reference autocoder:$rel does not resolve — expected plugins/autocoder/skills/autocoder/$rel"
  fi
done < <(grep -rhoE 'autocoder:references/[A-Za-z0-9_-]+\.md' plugins/autocoder/commands/ 2>/dev/null | sort -u)

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
