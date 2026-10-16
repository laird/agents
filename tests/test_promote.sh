#!/bin/bash
# tests/test_promote.sh — promote.sh moves an environment branch only to a commit that
# carries proof of a full-regression pass (the sentinel's green tip, the previous
# environment's tip, or a recorded tree pass), runs the environment's own test first,
# refuses rollbacks without --allow-rollback, and the sentinel auto-promotes auto:true
# environments after a green tick. Hermetic: the test_main_sentinel.sh fixture plus an
# .autocoder.json with staging → uat → prod; the regression gate fails iff BROKEN exists,
# prod's own test fails iff E2E_BROKEN exists, and origin counts every push it receives.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROMOTE="$ROOT/plugins/autocoder/scripts/promote.sh"
SENTINEL="$ROOT/plugins/autocoder/scripts/main-sentinel.sh"

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
unset ISSUE_BACKEND

# fixture <name> [staging-auto:true|false]
fixture() {
  local d="$TMP/$1" auto="${2:-false}"
  mkdir -p "$d/tmp" "$d/.issues/open" "$d/.issues/working" "$d/.issues/blocked" "$d/.issues/closed"
  echo 100 > "$d/.issues/.seq"
  git init -q --bare "$d/origin.git"
  git clone -q "$d/origin.git" "$d/repo" 2>/dev/null
  REPO="$d/repo"; ORIGIN="$d/origin.git"; ISSUES="$d/.issues"; RUNS="$d/runs"; E2E_RUNS="$d/e2e-runs"; PUSHES="$d/pushes"
  : > "$RUNS"; : > "$E2E_RUNS"; : > "$PUSHES"
  cat > "$ORIGIN/hooks/post-receive" <<EOF
#!/bin/sh
while read old new ref; do echo "\$ref \$new" >> "$PUSHES"; done
EOF
  chmod +x "$ORIGIN/hooks/post-receive"
  git -C "$REPO" config user.email t@example.com
  git -C "$REPO" config user.name T
  git -C "$REPO" checkout -q -b main
  echo base > "$REPO/README.md"
  cat > "$REPO/.autocoder.json" <<EOF
{
  "environments": [
    {"name": "staging", "ref": "env/staging", "requires": "green", "auto": $auto},
    {"name": "uat",     "ref": "env/uat",     "requires": "staging"},
    {"name": "prod",    "ref": "env/prod",    "requires": "uat", "test": "echo e2e >> $E2E_RUNS; test ! -e E2E_BROKEN"}
  ]
}
EOF
  git -C "$REPO" add -A && git -C "$REPO" commit -qm "base" && git -C "$REPO" push -q -u origin main 2>/dev/null
  TEST_CMD="echo run >> $RUNS; test ! -e BROKEN"
  export ISSUE_SOURCE=file ISSUE_DIR_PATH="$ISSUES"
  export AUTOCODER_GATE_CACHE_DIR="$d/gate-cache" AUTOCODER_SENTINEL_STATE_DIR="$d/state" AUTOCODER_TMP="$d/tmp"
}
sentinel() { bash "$SENTINEL" --repo "$REPO" --test-cmd "$TEST_CMD" "$@"; }
promote()  { bash "$PROMOTE"  --repo "$REPO" --test-cmd "$TEST_CMD" "$@"; }
e2e_runs() { wc -l < "$E2E_RUNS"; }
pushes_to() { grep -c "^refs/heads/$1 " "$PUSHES"; }
origin_sha() { git -C "$ORIGIN" rev-parse -q --verify "refs/heads/$1" 2>/dev/null; }
commit_on_main() { echo "$1" > "$REPO/$1"; git -C "$REPO" add -A; git -C "$REPO" commit -qm "$2"; git -C "$REPO" push -q origin main 2>/dev/null; }

echo "── 1. no green ref yet ──"
fixture pipeline
OUT=$(promote --to staging); RC=$?
check "exit 2" '[ "$RC" -eq 2 ]'
check "env/staging absent" '[ -z "$(origin_sha env/staging)" ]'
check "reason names the missing green ref" 'grep -q "main-green does not exist" <<< "$OUT"'

echo "── 2. first green tick, then promote staging ──"
sentinel >/dev/null
BASE=$(origin_sha main)
check "sentinel recorded main-green" '[ "$(origin_sha main-green)" = "$BASE" ]'
OUT=$(promote --to staging); RC=$?
check "exit 0" '[ "$RC" -eq 0 ]'
check "env/staging == origin/main-green" '[ "$(origin_sha env/staging)" = "$BASE" ]'
check "prints ✅ staging → sha" 'grep -q "✅ staging → ${BASE:0:7}" <<< "$OUT"'
check "exactly one push to env/staging" '[ "$(pushes_to env/staging)" -eq 1 ]'
check "HISTORY.md got a line" 'grep -q "Promoted staging to ${BASE:0:7}" "$REPO/docs/HISTORY.md"'
OUT=$(promote --to staging); RC=$?
check "second call: exit 0, says already there" '[ "$RC" -eq 0 ] && grep -q "already at ${BASE:0:7}" <<< "$OUT"'
check "second call pushed nothing" '[ "$(pushes_to env/staging)" -eq 1 ]'

echo "── 3. a main tip the sentinel has not gated is not proof ──"
commit_on_main f2 "add f2"
UNGATED=$(origin_sha main)
OUT=$(promote --to staging --commit origin/main); RC=$?
check "staging --commit origin/main: exit 2" '[ "$RC" -eq 2 ]'
check "env/staging unmoved" '[ "$(origin_sha env/staging)" = "$BASE" ]'
check "reason names the missing proof" 'grep -q "no recorded full-regression pass" <<< "$OUT"'
OUT=$(promote --to uat --commit origin/main); RC=$?
check "uat --commit origin/main: exit 2" '[ "$RC" -eq 2 ]'
check "env/uat absent" '[ -z "$(origin_sha env/uat)" ]'
OUT=$(promote --to uat); RC=$?
check "uat with the default commit (staging tip): exit 0" '[ "$RC" -eq 0 ]'
check "env/uat == env/staging" '[ "$(origin_sha env/uat)" = "$BASE" ]'
check "proof line says tip of origin/env/staging" 'grep -q "tip of origin/env/staging" <<< "$OUT"'

echo "── 4. prod runs its own test on the candidate tree ──"
echo broken > "$REPO/E2E_BROKEN"
commit_on_main f3 "add f3 with E2E_BROKEN"
X=$(origin_sha main)
sentinel >/dev/null
promote --to staging >/dev/null; promote --to uat >/dev/null
check "setup: env/uat is at the E2E_BROKEN commit" '[ "$(origin_sha env/uat)" = "$X" ]'
OUT=$(promote --to prod); RC=$?
check "prod refused: exit 2" '[ "$RC" -eq 2 ]'
check "env/prod absent" '[ -z "$(origin_sha env/prod)" ]'
check "the e2e test ran once" '[ "$(e2e_runs)" -eq 1 ]'
check "reason names the failing test" 'grep -q "E2E_BROKEN.*failed on ${X:0:7}" <<< "$OUT"'
check "no throwaway worktree left behind" '[ "$(git -C "$REPO" worktree list | wc -l)" -eq 2 ]'
git -C "$REPO" rm -q E2E_BROKEN
commit_on_main f4 "fix e2e"
Y=$(origin_sha main)
sentinel >/dev/null
promote --to staging >/dev/null; promote --to uat >/dev/null
OUT=$(promote --to prod --dry-run); RC=$?
check "dry-run: exit 0, runs the test, moves nothing" '[ "$RC" -eq 0 ] && [ "$(e2e_runs)" -eq 2 ] && [ -z "$(origin_sha env/prod)" ] && grep -q "dry-run: would move prod" <<< "$OUT"'
OUT=$(promote --to prod); RC=$?
check "prod promoted: exit 0" '[ "$RC" -eq 0 ]'
check "env/prod == Y" '[ "$(origin_sha env/prod)" = "$Y" ]'
check "same tree: the test did not run again" '[ "$(e2e_runs)" -eq 2 ]'
OUT=$(promote --to prod); RC=$?
check "repeat: already there, no run, no push" '[ "$RC" -eq 0 ] && [ "$(e2e_runs)" -eq 2 ] && [ "$(pushes_to env/prod)" -eq 1 ]'

echo "── 5. a red main tip is never promotable ──"
echo broken > "$REPO/BROKEN"
commit_on_main f5 "break the build"
RED=$(origin_sha main)
sentinel >/dev/null
OUT=$(promote --to staging --commit "$RED"); RC=$?
check "exit 2" '[ "$RC" -eq 2 ]'
check "env/staging stays at Y" '[ "$(origin_sha env/staging)" = "$Y" ]'
OUT=$(promote --to staging); RC=$?
check "default commit (the sentinel's revert) promotes" '[ "$RC" -eq 0 ] && [ "$(origin_sha env/staging)" = "$(origin_sha main-green)" ] && [ "$(origin_sha env/staging)" != "$RED" ]'
GREEN_NOW=$(origin_sha main-green)

echo "── 6. rollback needs --allow-rollback ──"
OUT=$(promote --to staging --commit "$X"); RC=$?
check "older green commit without the flag: exit 2" '[ "$RC" -eq 2 ]'
check "env/staging unmoved" '[ "$(origin_sha env/staging)" = "$GREEN_NOW" ]'
check "reason says not a fast-forward" 'grep -q "not a fast-forward" <<< "$OUT"'
OUT=$(promote --to staging --commit "$X" --allow-rollback); RC=$?
check "with the flag: exit 0" '[ "$RC" -eq 0 ]'
check "env/staging == X" '[ "$(origin_sha env/staging)" = "$X" ]'
check "prints rolled back" 'grep -q "🔄 staging rolled back → ${X:0:7}" <<< "$OUT"'
check "proof was the recorded tree pass" 'grep -q "recorded full-regression pass" <<< "$OUT"'

echo "── 8. --list and --dry-run ──"
BEFORE=$(wc -l < "$PUSHES")
OUT=$(promote --list); RC=$?
check "--list exits 0" '[ "$RC" -eq 0 ]'
check "names all three environments with their tips" 'grep -q "^staging .*${X:0:7}" <<< "$OUT" && grep -q "^uat .*${Y:0:7}" <<< "$OUT" && grep -q "^prod .*${Y:0:7}" <<< "$OUT"'
check "staging shows the green tip as promotable" 'grep "^staging" <<< "$OUT" | grep -q "${GREEN_NOW:0:7}"'
check "uat shows staging's tip as a rollback" 'grep "^uat" <<< "$OUT" | grep -q "${X:0:7} (needs --allow-rollback)"'
check "prod names its extra test" 'grep "^prod" <<< "$OUT" | grep -q "after .echo e2e"'
OUT=$(promote --to staging --dry-run); RC=$?
check "--dry-run exits 0 and prints the decision" '[ "$RC" -eq 0 ] && grep -q "dry-run: would move staging" <<< "$OUT"'
check "nothing was pushed" '[ "$(wc -l < "$PUSHES")" -eq "$BEFORE" ] && [ "$(origin_sha env/staging)" = "$X" ]'

echo "── 7. auto:true follows the sentinel ──"
fixture auto true
OUT=$(sentinel); RC=$?
check "green tick exits 0" '[ "$RC" -eq 0 ]'
check "env/staging moved by itself" '[ "$(origin_sha env/staging)" = "$(origin_sha main-green)" ]'
check "env/uat did not" '[ -z "$(origin_sha env/uat)" ]'
check "tick output carries the promotion line" 'grep -q "✅ staging → " <<< "$OUT"'
OUT=$(sentinel); RC=$?
check "idle tick: no promotion attempt" '[ "$RC" -eq 0 ] && [ "$(pushes_to env/staging)" -eq 1 ]'
echo broken > "$REPO/BROKEN"
commit_on_main f6 "break the build"
RED=$(origin_sha main)
OUT=$(sentinel); RC=$?
check "repaired tick exits 0" '[ "$RC" -eq 0 ]'
check "env/staging followed the revert, not the red tip" '[ "$(origin_sha env/staging)" = "$(origin_sha main-green)" ] && [ "$(origin_sha env/staging)" != "$RED" ]'

echo "── 9. config errors ──"
OUT=$(promote --to qa 2>&1); RC=$?
check "unknown environment: exit 2" '[ "$RC" -eq 2 ] && grep -q "unknown environment" <<< "$OUT"'
cp "$REPO/.autocoder.json" "$TMP/cfg.bak"
cat > "$REPO/.autocoder.json" <<'EOF'
{"environments": [{"name": "uat", "requires": "staging"}, {"name": "staging", "requires": "green"}]}
EOF
OUT=$(promote --to uat 2>&1); RC=$?
check "requires a later environment: exit 1" '[ "$RC" -eq 1 ] && grep -q "listed before it" <<< "$OUT"'
echo '{}' > "$REPO/.autocoder.json"
OUT=$(promote --to staging 2>&1); RC=$?
check "no environments: exit 1" '[ "$RC" -eq 1 ]'
OUT=$(promote --auto 2>&1); RC=$?
check "--auto with no environments: exit 0, silent" '[ "$RC" -eq 0 ] && [ -z "$OUT" ]'
cp "$TMP/cfg.bak" "$REPO/.autocoder.json"
promote --to 2>/dev/null; RC=$?
check "a flag without a value exits 1" '[ "$RC" -eq 1 ]'

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
