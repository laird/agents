#!/bin/bash
# tests/test_gate_cache_fns.sh — gate results are keyed by <tree, command>, a pass is
# reused, a fail is reused only on request, and the key changes with the command.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../plugins/autocoder/scripts/gate-cache-fns.sh
source "$ROOT/plugins/autocoder/scripts/gate-cache-fns.sh"

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export AUTOCODER_GATE_CACHE_DIR="$TMP/cache"

git init -q "$TMP/repo"
cd "$TMP/repo" || exit 1
git config user.email t@example.com; git config user.name T
echo a > a; git add a; git commit -q -m a
TREE=$(git rev-parse 'HEAD^{tree}')

COUNTER="$TMP/runs"
CMD="echo run >> $COUNTER"

gate_cache_get "$TREE" "$CMD" >/dev/null && bad "empty cache reports a record" || ok "empty cache is a miss"

gate_cache_run . "$CMD" >/dev/null || bad "first run of a passing gate fails"
gate_cache_run . "$CMD" >/dev/null || bad "second run of a passing gate fails"
[ "$(wc -l < "$COUNTER")" -eq 1 ] && ok "a recorded pass is not re-run" || bad "pass was re-run: $(wc -l < "$COUNTER") runs"
[ "$(gate_cache_get "$TREE" "$CMD")" = pass ] && ok "get reports pass" || bad "get did not report pass"

FAILCMD="echo run >> $COUNTER.fail; false"
gate_cache_run . "$FAILCMD" >/dev/null && bad "failing gate reported pass"
gate_cache_run . "$FAILCMD" >/dev/null && bad "failing gate reported pass on retry"
[ "$(wc -l < "$COUNTER.fail")" -eq 2 ] && ok "a recorded fail is re-run by default" || bad "fail reuse default wrong: $(wc -l < "$COUNTER.fail")"
GATE_CACHE_REUSE_FAIL=1 gate_cache_run . "$FAILCMD" >/dev/null && bad "reused fail reported pass"
[ "$(wc -l < "$COUNTER.fail")" -eq 2 ] && ok "GATE_CACHE_REUSE_FAIL=1 skips the run" || bad "fail was re-run under reuse"

gate_cache_get "$TREE" "some other command" >/dev/null && bad "different command shares a record" || ok "key includes the command"

echo b > b; git add b; git commit -q -m b
gate_cache_get "$(git rev-parse 'HEAD^{tree}')" "$CMD" >/dev/null && bad "new tree shares a record" || ok "key includes the tree"

gate_cache_put "$TREE" "$CMD" fail
[ "$(gate_cache_get "$TREE" "$CMD")" = fail ] && ok "put overwrites atomically" || bad "put did not overwrite"
[ -z "$(ls -A "$TMP/cache" | grep '^\.tmp')" ] && ok "no temp files left behind" || bad "temp files left in cache dir"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
