#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255: never write the real event logs
# tests/test_gate_hermetic.sh — opt-in hermetic merge gate (#223). With gate.hermetic in
# the tree's committed .autocoder.json the test command runs under env -i: declared PATH
# dirs + /usr/bin:/bin, a fresh temporary HOME, LANG=C.UTF-8 and only the declared
# variables. The gate cache keys verdicts by mode, so a host pass never satisfies a
# hermetic gate. Off by default.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../plugins/autocoder/scripts/gate-cache-fns.sh
source "$ROOT/plugins/autocoder/scripts/gate-cache-fns.sh"
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export AUTOCODER_GATE_CACHE_DIR="$TMP/cache"
export TMPDIR="$TMP/tmpdir"; mkdir -p "$TMPDIR"

# A fake "host": its HOME holds a config file the test secretly needs, and a host-only tool.
export HOME="$TMP/hosthome"; mkdir -p "$HOME/.config" "$TMP/hosttools" "$TMP/toolchain"
echo secret > "$HOME/.config/x"
printf '#!/bin/sh\necho host-tool\n' > "$TMP/hosttools/hosttool"; chmod +x "$TMP/hosttools/hosttool"
printf '#!/bin/sh\necho declared-tool\n' > "$TMP/toolchain/declaredtool"; chmod +x "$TMP/toolchain/declaredtool"
export PATH="$TMP/hosttools:$TMP/toolchain:$PATH"
export DECLARED_VAR=yes UNDECLARED_VAR=leak

git init -q "$TMP/repo"; cd "$TMP/repo" || exit 1
git config user.email t@example.com; git config user.name T
echo a > a; git add a; git commit -q -m base

READS_HOME='test -f "$HOME/.config/x"'
gate_cache_run . "$READS_HOME" >/dev/null 2>&1 && ok "default mode: a test reading \$HOME/.config/x passes" \
  || bad "default mode should run in the host environment"
gate_cache_run . "$READS_HOME" 2>&1 | grep -q '^gate-cache: pass recorded' && ok "default mode: the host pass is cached" \
  || bad "host pass not cached"

# An UNCOMMITTED hermetic config does not switch the mode on: it is a property of the tree.
printf '{"gate": {"hermetic": true}}\n' > .autocoder.json
[ -z "$(gate_env_config HEAD .)" ] && ok "uncommitted .autocoder.json: still host mode" || bad "working-tree config changed the mode"

# Commit the hermetic config. Declare one toolchain dir (with ~) and one variable.
ln -s "$TMP/toolchain" "$HOME/tc"
printf '{"gate": {"hermetic": true, "path": ["~/tc"], "env": ["DECLARED_VAR"]}}\n' > .autocoder.json
git add .autocoder.json; git commit -q -m hermetic
TREE=$(git rev-parse 'HEAD^{tree}')

# A host pass recorded for THIS tree (as an older, non-hermetic gate would have) must not count.
f="$AUTOCODER_GATE_CACHE_DIR/$TREE-$(printf '%s' "$READS_HOME" | git hash-object --stdin | cut -c1-12)"
printf 'pass %s\n' "$(date +%s)" > "$f"   # the host-mode key, written directly
OUT=$(gate_cache_run . "$READS_HOME" 2>&1); RC=$?
[ "$RC" -ne 0 ] && ok "hermetic: the \$HOME-reading test fails (a host-mode pass on the same tree was not reused)" \
  || bad "hermetic gate passed: $OUT"
echo "$OUT" | grep -q 'gate-env: hermetic' && ok "the gate log names the hermetic mode" || bad "mode not logged: $OUT"
[ "$(gate_cache_get "$TREE" "$READS_HOME")" = fail ] && ok "the hermetic verdict is recorded under its own key" || bad "hermetic verdict missing"
[ -z "$(ls -A "$TMPDIR")" ] && ok "the temporary HOME is removed" || bad "temp HOME left behind: $(ls -A "$TMPDIR")"

PROBE='printf "%s|%s|%s|%s|%s\n" "$(declaredtool 2>&1)" "$(command -v hosttool || echo none)" "${DECLARED_VAR:-unset}" "${UNDECLARED_VAR:-unset}" "$LANG" > '"$TMP/probe"
gate_cache_run . "$PROBE" >/dev/null 2>&1
IFS='|' read -r dt ht dv uv lang < "$TMP/probe"
[ "$dt" = declared-tool ] && ok "a declared path dir (~-relative) reaches the test" || bad "declared tool: '$dt'"
[ "$ht" = none ] && ok "an undeclared host tool does not" || bad "host tool visible: '$ht'"
[ "$dv" = yes ] && ok "a declared env var reaches the test" || bad "declared var: '$dv'"
[ "$uv" = unset ] && ok "an undeclared env var does not" || bad "undeclared var leaked: '$uv'"
[ "$lang" = C.UTF-8 ] && ok "LANG is C.UTF-8" || bad "LANG: '$lang'"

# A declared name cannot replace the hermetic HOME.
printf '{"gate": {"hermetic": true, "env": ["HOME"]}}\n' > .autocoder.json; git commit -qam "declare HOME"
gate_cache_run . 'test "$HOME" != '"'$HOME'" >/dev/null 2>&1 && ok "a declared HOME does not override the temporary one" \
  || bad "declared HOME overrode the hermetic HOME"

# Back to host mode: the config change alone flips the key, and the host test passes again.
git rm -q .autocoder.json; git commit -qm "host again"
gate_cache_run . "$READS_HOME" >/dev/null 2>&1 && ok "removing the config restores host mode" || bad "host mode not restored"

# No env list (empty array under set -u) still runs; python3 missing fails the gate, not host mode.
printf '{"gate": {"hermetic": true}}\n' > .autocoder.json; git add .autocoder.json; git commit -qm "bare hermetic"
(set -u; gate_cache_run . 'test -z "${DECLARED_VAR:-}"') >/dev/null 2>&1 && ok "hermetic with no env list runs under set -u" \
  || bad "hermetic with no env list failed"
git commit -qm "new tree" --allow-empty; echo b > b; git add b; git commit -qm b
mkdir -p "$TMP/nopy"; printf '#!/bin/sh\nexit 127\n' > "$TMP/nopy/python3"; chmod +x "$TMP/nopy/python3"
# Even with a host-mode pass already on record for this tree (an older version wrote it).
NT=$(git rev-parse 'HEAD^{tree}')
printf 'pass %s\n' "$(date +%s)" > "$AUTOCODER_GATE_CACHE_DIR/$NT-$(printf true | git hash-object --stdin | cut -c1-12)"
OUT=$(PATH="$TMP/nopy:$PATH" gate_cache_run . 'true' 2>&1) && bad "gate ran with an unreadable config: $OUT" \
  || ok "an unreadable gate config fails the gate instead of falling back to host mode"
ls "$AUTOCODER_GATE_CACHE_DIR" | grep -q envunreadable && bad "a record was written for an unreadable config" \
  || ok "nothing is recorded while the config is unreadable"
# #327: a red-base retest adds a suffix after -envunreadable; it must still record nothing.
OUT=$(AUTOCODER_GATE_RETEST_FILES="t_a.test" PATH="$TMP/nopy:$PATH" gate_cache_run . 'true' 2>&1) \
  && bad "a retest gate ran with an unreadable config: $OUT" || ok "a retest gate with an unreadable config fails too"
ls "$AUTOCODER_GATE_CACHE_DIR" | grep -q envunreadable && bad "a retest record was written for an unreadable config" \
  || ok "nothing is recorded for a retest while the config is unreadable"
git rm -q .autocoder.json; git commit -qm "host again 2"

# A reader whose repository lacks the tree (another clone sharing the cache) still finds
# the host-mode record, as before #223.
gate_cache_run . "$READS_HOME" >/dev/null 2>&1; H=$(git rev-parse 'HEAD^{tree}'); git init -q "$TMP/other"
[ "$(cd "$TMP/other" && gate_cache_get "$H" "$READS_HOME")" = pass ] && ok "an unknown tree uses the host key (cross-clone reuse kept)" \
  || bad "cross-clone host record not found"

# #298: the red-base retest's file list crosses a hermetic gate though it is not declared.
cd "$TMP/repo" || exit 1
printf '{"gate": {"hermetic": true}}\n' > .autocoder.json; git add .autocoder.json; git commit -qm "hermetic for retest"
OUT=$(AUTOCODER_GATE_RETEST_FILES="t_a.test t_b.test" gate_env_run . 'echo "retest=$AUTOCODER_GATE_RETEST_FILES"' 2>/dev/null)
echo "$OUT" | grep -q '^gate-env: hermetic' && echo "$OUT" | grep -qx 'retest=t_a.test t_b.test' && ok "hermetic: AUTOCODER_GATE_RETEST_FILES crosses" || bad "retest files did not cross the hermetic env"

echo ""
echo "Tests: $FAIL failed, $PASS passed, $((PASS + FAIL)) total"
[ "$FAIL" -eq 0 ]
