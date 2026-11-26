#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255: never write the real event logs
# The SCRIPT_DIR resolver is copied into every autocoder command (Claude Code),
# workflow (Antigravity) and generated pi prompt. Each copy must pick a COMPLETE
# script tree, never a partial one (#142):
#   - the plugin cache holds both <ver>/scripts (full) and
#     <ver>/skills/autocoder/scripts (a subset that also contains issue-fns.sh
#     and fix-loop-gate.sh); `sort -V | tail -1` used to pick the subset;
#   - a project's .agent/scripts is the Antigravity tree and has no
#     fix-loop-gate.sh, so a Claude Code command that picks it dies with rc 127.
# This test runs every copy of the resolver against fake trees.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); }
fail() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# full <dir>: a complete tree. partial <dir>: a subset with the same sentinels.
full()    { mkdir -p "$1"; touch "$1/issue-fns.sh" "$1/fix-loop-gate.sh" "$1/merge-launch.sh"; }
partial() { mkdir -p "$1"; touch "$1/issue-fns.sh" "$1/fix-loop-gate.sh"; }
agent_tree() { mkdir -p "$1"; touch "$1/issue-fns.sh"; }   # Antigravity: no gate script

# Pull each resolver block (from `SCRIPT_DIR=$(` to its closing `)`) out of a file.
extract_blocks() {
  python3 - "$1" "$2" <<'PY'
import re, sys
text = open(sys.argv[1]).read().splitlines()
out_prefix = sys.argv[2]
n = 0
i = 0
while i < len(text):
    if re.match(r'^\s*SCRIPT_DIR=\$\($', text[i]):
        indent = len(text[i]) - len(text[i].lstrip())
        block = [text[i]]
        i += 1
        while i < len(text) and not re.match(r'^\s{%d}\)\s*$' % indent, text[i]):
            block.append(text[i]); i += 1
        block.append(text[i] if i < len(text) else ')')
        n += 1
        with open(f"{out_prefix}.{n}", "w") as f:
            f.write("\n".join(block) + '\necho "$SCRIPT_DIR"\n')
    i += 1
print(n)
PY
}

# run_block <block-file> <cwd> <home> -> resolved SCRIPT_DIR
run_block() { (cd "$2" && HOME="$3" bash "$1" 2>/dev/null); }

FILES=()
while IFS= read -r f; do FILES+=("$f"); done < <(
  cd "$ROOT" && grep -l '^\s*SCRIPT_DIR=\$($' \
    plugins/autocoder/commands/*.md .agent/workflows/*.md .pi/prompts/*.md 2>/dev/null | sort)
[ "${#FILES[@]}" -ge 30 ] || fail "expected 30+ files with a resolver, found ${#FILES[@]}"

for rel in "${FILES[@]}"; do
  case "$rel" in
    .agent/*) CACHE_ROOT=".agent"; PLATFORM=antigravity ;;
    *)        CACHE_ROOT=".claude"; PLATFORM=claude ;;
  esac
  key=$(echo "$rel" | tr '/.' '__')
  count=$(extract_blocks "$ROOT/$rel" "$WORK/$key")
  [ "$count" -ge 1 ] || { fail "$rel: no resolver block extracted"; continue; }

  for b in "$WORK/$key".*; do
    # ── Case 1: plugin cache fallback must skip skills/autocoder/scripts ──────
    H="$WORK/home-$key"; P="$WORK/proj-$key"; rm -rf "$H" "$P"; mkdir -p "$P"
    C="$H/$CACHE_ROOT/plugins/cache/mkt/autocoder"
    full    "$C/4.9.0/scripts"
    full    "$C/4.10.0/scripts"
    partial "$C/4.10.0/skills/autocoder/scripts"
    partial "$C/4.11.0/skills/autocoder/scripts"   # a version with only the subset
    mkdir -p "$C/4.12.0/scripts"                   # an empty scripts dir
    got=$(run_block "$b" "$P" "$H")
    want="$C/4.10.0/scripts"
    if [ "$got" = "$want" ]; then pass; else fail "$rel: cache fallback picked '${got#$H/}', want '${want#$H/}'"; fi

    # ── Case 3: two marketplaces — the newest <ver> wins, not the last path (#201)
    rm -rf "$H"
    full "$H/$CACHE_ROOT/plugins/cache/zzz-mkt/autocoder/4.9.0/scripts"
    full "$H/$CACHE_ROOT/plugins/cache/aaa-mkt/autocoder/4.12.0/scripts"
    got=$(run_block "$b" "$P" "$H")
    want="$H/$CACHE_ROOT/plugins/cache/aaa-mkt/autocoder/4.12.0/scripts"
    if [ "$got" = "$want" ]; then pass; else fail "$rel: two marketplaces picked '${got#$H/}', want '${want#$H/}'"; fi

    # ── Case 2: a project-local tree ──────────────────────────────────────────
    rm -rf "$P"; mkdir -p "$P"
    agent_tree "$P/.agent/scripts"
    full       "$P/plugins/autocoder/scripts"
    got=$(run_block "$b" "$P" "$H")
    if [ "$PLATFORM" = claude ]; then
      want="$P/plugins/autocoder/scripts"   # .agent/scripts lacks fix-loop-gate.sh
    else
      want="$P/.agent/scripts"              # Antigravity's own tree
    fi
    if [ "$got" = "$want" ]; then pass; else fail "$rel: local resolution picked '${got#$P/}', want '${want#$P/}'"; fi

    # ── Case 4: a generated pi prompt prefers the project's .pi/scripts (#201) ──
    case "$rel" in
      .pi/prompts/*)
        full "$P/.pi/scripts"
        got=$(run_block "$b" "$P" "$H")
        if [ "$got" = "$P/.pi/scripts" ]; then pass; else fail "$rel: pi prompt picked '${got#$P/}', want .pi/scripts"; fi ;;
    esac

    # ── Case 5: a Grok install is used only when the platform cache has none ──
    if grep -q '.grok/installed-plugins' "$b"; then
      rm -rf "$H" "$P"; mkdir -p "$P"
      partial "$H/.grok/installed-plugins/autocoder-aaaa1111/skills/autocoder/scripts"
      full    "$H/.grok/installed-plugins/autocoder-aaaa1111/scripts"
      full    "$H/.grok/installed-plugins/autocoder-bbbb2222/scripts"
      got=$(run_block "$b" "$P" "$H")
      want="$H/.grok/installed-plugins/autocoder-bbbb2222/scripts"
      if [ "$got" = "$want" ]; then pass; else fail "$rel: grok install picked '${got#$H/}', want '${want#$H/}'"; fi

      full "$H/$CACHE_ROOT/plugins/cache/mkt/autocoder/4.2.0/scripts"
      got=$(run_block "$b" "$P" "$H")
      want="$H/$CACHE_ROOT/plugins/cache/mkt/autocoder/4.2.0/scripts"
      if [ "$got" = "$want" ]; then pass; else fail "$rel: platform cache should beat a Grok install, picked '${got#$H/}'"; fi
    fi
  done
done

# ── install.md's CACHE_SCRIPTS follows the same rules (#201 item 1) ──────────
python3 - "$ROOT/plugins/autocoder/commands/install.md" "$WORK/cache_scripts.sh" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
m = re.search(r'^(\s*CACHE_SCRIPTS=\$\(find .*?\))\s*$', text, re.M | re.S)
open(sys.argv[2], "w").write((m.group(1) if m else "false") + '\necho "$CACHE_SCRIPTS"\n')
PY
H="$WORK/home-install"; rm -rf "$H"; C="$H/.claude/plugins/cache"
full    "$C/zzz-mkt/autocoder/4.9.0/scripts"
full    "$C/aaa-mkt/autocoder/4.12.0/scripts"
partial "$C/aaa-mkt/autocoder/4.12.0/skills/autocoder/scripts"
mkdir -p "$C/aaa-mkt/autocoder/4.13.0/scripts"
got=$(HOME="$H" bash "$WORK/cache_scripts.sh" 2>/dev/null)
if [ "$got" = "$C/aaa-mkt/autocoder/4.12.0/scripts" ]; then pass; else fail "install.md CACHE_SCRIPTS picked '${got#$H/}'"; fi

echo "$PASS passed / $FAIL failed / $((PASS+FAIL)) total"
[ "$FAIL" -eq 0 ]
