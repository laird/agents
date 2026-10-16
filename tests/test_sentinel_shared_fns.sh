#!/bin/bash
# tests/test_sentinel_shared_fns.sh — the helpers main-sentinel.sh and merge-to-integration.sh
# share: one repo id per clone across its worktrees, the re-gate rule with its global-path
# list, seeding a throwaway worktree with node_modules, and gate-cache pruning.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$ROOT/plugins/autocoder/scripts"
# shellcheck source=../plugins/autocoder/scripts/repo-id-fns.sh
source "$S/repo-id-fns.sh"
# shellcheck source=../plugins/autocoder/scripts/worktree-deps-fns.sh
source "$S/worktree-deps-fns.sh"
# shellcheck source=../plugins/autocoder/scripts/gate-cache-fns.sh
source "$S/gate-cache-fns.sh"

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "── repo id ──"
git init -q "$TMP/alpha"; git -C "$TMP/alpha" config user.email t@x; git -C "$TMP/alpha" config user.name T
git -C "$TMP/alpha" commit -q --allow-empty -m base
git -C "$TMP/alpha" worktree add -q "$TMP/alpha-wt-1" -b wt1 >/dev/null 2>&1
git init -q "$TMP/other/alpha"
ID=$(autocoder_repo_id "$TMP/alpha")
check "shape is <dir>-<8 hex>" '[[ "$ID" =~ ^alpha-[0-9a-f]{8}$ ]]'
check "a linked worktree gets the same id as its main checkout" '[ "$(autocoder_repo_id "$TMP/alpha-wt-1")" = "$ID" ]'
check "computed from inside the repo with no argument" '[ "$(cd "$TMP/alpha-wt-1" && autocoder_repo_id)" = "$ID" ]'
check "another clone with the same directory name differs" '[ "$(autocoder_repo_id "$TMP/other/alpha")" != "$ID" ]'
check "not a repo: falls back to the directory itself, stable, distinct from the repo" '[ -n "$(autocoder_repo_id "$TMP")" ] && [ "$(autocoder_repo_id "$TMP")" = "$(autocoder_repo_id "$TMP")" ] && [ "$(autocoder_repo_id "$TMP")" != "$ID" ]'

echo "── regate_needed ──"
R="$TMP/regate"; git init -q "$R"; git -C "$R" config user.email t@x; git -C "$R" config user.name T
mkdir -p "$R/src" "$R/.github/workflows"
echo a > "$R/src/a.js"; echo b > "$R/src/b.js"; echo ci > "$R/.github/workflows/ci.yml"; echo '{}' > "$R/package.json"
git -C "$R" add -A; git -C "$R" commit -qm base; OLD=$(git -C "$R" rev-parse HEAD)
echo b2 > "$R/src/b.js"; git -C "$R" commit -qam "touch b"; B_ONLY=$(git -C "$R" rev-parse HEAD)
echo ci2 > "$R/.github/workflows/ci.yml"; git -C "$R" commit -qam "touch ci"; CI_TOO=$(git -C "$R" rev-parse HEAD)
echo '{"x":1}' > "$R/package.json"; git -C "$R" commit -qam "touch manifest"; MANIFEST=$(git -C "$R" rev-parse HEAD)
echo "src/a.js" > "$TMP/files-a"
echo "src/b.js" > "$TMP/files-b"
# shellcheck source=../plugins/autocoder/scripts/regate-fns.sh
source "$S/regate-fns.sh"
check "disjoint incoming file: no re-gate" '! regate_needed "$TMP/files-a" "$OLD" "$B_ONLY" "$R" >/dev/null'
OUT=$(regate_needed "$TMP/files-b" "$OLD" "$B_ONLY" "$R"); RC=$?
check "incoming file the change touched: re-gate, names the file" '[ "$RC" -eq 0 ] && [ "$OUT" = "src/b.js (a file this change touched)" ]'
OUT=$(regate_needed "$TMP/files-a" "$B_ONLY" "$CI_TOO" "$R"); RC=$?
check ".github/* is global by default" '[ "$RC" -eq 0 ] && grep -q "ci.yml (a global path)" <<< "$OUT"'
OUT=$(regate_needed "$TMP/files-a" "$CI_TOO" "$MANIFEST" "$R"); RC=$?
check "package.json is global by default" '[ "$RC" -eq 0 ] && grep -q "package.json (a global path)" <<< "$OUT"'
check "an empty file set means every incoming file counts" 'regate_needed "" "$OLD" "$B_ONLY" "$R" | grep -q "every incoming file"'
check "the default list is exported for other scripts" 'grep -q "CLAUDE.md" <<< "$REGATE_GLOBAL_PATHS_DEFAULT"'
OUT=$(AUTOCODER_GATE_GLOBAL_PATHS="src/b.js" bash -c "source '$S/regate-fns.sh'; regate_needed '$TMP/files-a' '$OLD' '$B_ONLY' '$R'; regate_needed '$TMP/files-a' '$B_ONLY' '$CI_TOO' '$R' || echo no-regate")
check "AUTOCODER_GATE_GLOBAL_PATHS replaces the default list" 'grep -q "src/b.js (a global path)" <<< "$OUT" && grep -q "^no-regate$" <<< "$OUT"'

echo "── seed_worktree_deps ──"
SRC="$TMP/src-repo"; mkdir -p "$SRC/node_modules/pkg" "$SRC/sub/node_modules/pkg2" "$SRC/node_modules/pkg/node_modules/nested" "$SRC/software-factory/packages/core/dist"
echo m > "$SRC/node_modules/pkg/index.js"; echo m2 > "$SRC/sub/node_modules/pkg2/index.js"; echo d > "$SRC/software-factory/packages/core/dist/out.js"
DST="$TMP/dst-wt"; mkdir -p "$DST"
seed_worktree_deps "$SRC" "$DST"
check "top-level node_modules seeded" '[ -f "$DST/node_modules/pkg/index.js" ]'
check "nested package node_modules seeded" '[ -f "$DST/sub/node_modules/pkg2/index.js" ]'
check "dist is a real copy, not a hardlink" '[ -f "$DST/software-factory/packages/core/dist/out.js" ] && [ "$(stat -c %i "$DST/software-factory/packages/core/dist/out.js")" != "$(stat -c %i "$SRC/software-factory/packages/core/dist/out.js")" ]'
echo late > "$SRC/node_modules/pkg/late.js"
seed_worktree_deps "$SRC" "$DST"
check "a second seed leaves an existing destination alone" '[ ! -e "$DST/node_modules/pkg/late.js" ]'

echo "── gate_cache_prune ──"
export AUTOCODER_GATE_CACHE_DIR="$TMP/cache"
gate_cache_put aaaa "cmd" pass; gate_cache_put bbbb "cmd" fail
touch -d '40 days ago' "$(gate_cache_dir)/$(_gate_cache_key bbbb cmd)"
gate_cache_prune
check "an old record is deleted" '! gate_cache_get bbbb cmd >/dev/null'
check "a fresh record survives" '[ "$(gate_cache_get aaaa cmd)" = pass ]'
touch -d '10 days ago' "$(gate_cache_dir)/$(_gate_cache_key aaaa cmd)"
gate_cache_prune 7
check "a custom age applies" '! gate_cache_get aaaa cmd >/dev/null'

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
