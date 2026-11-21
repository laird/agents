#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255: never write the real event logs
# fix-config.sh (#293): /fix's configuration and setup, moved out of
# commands/fix.md. Every value the inline block set must still be set after the
# caller sources the hand-back, and the markers the agent acts on must still be
# printed. Runs in a private temp repo with its own .autocoder.json, with `gh`
# and `claude` stubbed on PATH, so it never touches the real tracker.

set -uo pipefail

PASS=0
FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$ROOT/plugins/autocoder/scripts/fix-config.sh"

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want '$2', got '$3'"; fi; }
assert_has() { if printf '%s' "$2" | grep -Fq -- "$3"; then ok "$1"; else bad "$1 — '$3' not in output"; fi; }
assert_lacks() { if printf '%s' "$2" | grep -Fq -- "$3"; then bad "$1 — '$3' found"; else ok "$1"; fi; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export TMPDIR="$TMP"

# ── stubs: gh records its calls; claude lists the plugins in $FAKE_PLUGINS ──────
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'STUB'
#!/bin/bash
echo "gh $*" >> "$GH_LOG"
case "$1 $2" in
  "repo view") echo "owner-a" ;;
  "api user")  echo "${FAKE_GH_USER:-owner-a}" ;;
  "label list") printf 'P0\nP1\nworking\n' ;;
  "label create"|"auth switch") ;;
  *) echo "[]" ;;
esac
STUB
cat > "$TMP/bin/claude" <<'STUB'
#!/bin/bash
[ "$1 $2" = "plugins list" ] && printf '%s\n' ${FAKE_PLUGINS:-}
STUB
chmod +x "$TMP/bin/gh" "$TMP/bin/claude"
export PATH="$TMP/bin:$PATH" GH_LOG="$TMP/gh.log"
unset MANAGER_MODEL WORKER_MODEL FAST_MODEL MANAGER_MODEL_PRECONFIG WORKER_MODEL_PRECONFIG INTEGRATION_BRANCH

git init -q --bare -b trunk "$TMP/origin.git"
git clone -q "$TMP/origin.git" "$TMP/repo" 2>/dev/null
REPO="$TMP/repo"
cd "$REPO" || exit 1
git config user.email test@example.com
git config user.name Test
git checkout -q -b trunk
echo test > README.md
git add README.md && git commit -q -m initial && git push -q origin trunk
git remote set-head origin trunk >/dev/null 2>&1 || true

ISSUES="$TMP/issues"
mkdir -p "$ISSUES/open" "$ISSUES/working" "$ISSUES/blocked" "$ISSUES/closed"
file_backend() { printf '{"issueSource": "file", "issueDir": "%s"%s}\n' "$ISSUES" "${1:-}" > .autocoder.json; }

run_config() { # run_config [args...]; sets RC, OUTPUT and sources the hand-back
  local env="$TMP/config.env"
  rm -f "$env" "$GH_LOG"
  # Overrides arrive in CFG_ENV ("NAME=value ..."), not as a prefix on this call:
  # a prefix scopes the variable to the function, and the `source` below would
  # then write into that scope and be lost when the function returns.
  # shellcheck disable=SC2086
  OUTPUT=$(env ${CFG_ENV:-} bash "$CONFIG" --out "$env" "$@" 2>&1)
  RC=$?
  TEST_COMMAND="" BUILD_COMMAND="" MERGE_MODE="" INTEGRATION_BRANCH="" MANAGER_MODEL="" WORKER_MODEL=""
  FAST_MODEL="" SUPERPOWERS_AVAILABLE="" QUINT_AVAILABLE="" UNPRIORITIZED="" UNPRIORITIZED_COUNT=""
  if [ -f "$env" ]; then source "$env"; else bad "hand-back file written ($*)"; fi
}

# ── 1. a configured CLAUDE.md: every value the inline block set comes back ──────
cat > CLAUDE.md <<'MD'
# Project

## Automated Testing & Issue Management

### Regression Test Suite
```bash
make check
```

### Build Verification
```bash
make build
```

### Merge Mode
```
pr
```

### Integration Branch
```
develop
```
MD
file_backend ', "managerModel": "big", "workerModel": "mid", "fastModel": "small"'
printf -- '---\nnumber: 7\ntitle: Needs a priority\nlabels: [bug]\nstatus: open\n---\nUntriaged body.\n' > "$ISSUES/open/007.md"
printf -- '---\nnumber: 8\ntitle: Has one\nlabels: [bug, P2]\nstatus: open\n---\nBody.\n' > "$ISSUES/open/008.md"
FAKE_PLUGINS="superpowers" run_config
assert_eq "configured: exit 0" 0 "$RC"
assert_eq "configured: TEST_COMMAND" "make check" "$TEST_COMMAND"
assert_eq "configured: BUILD_COMMAND" "make build" "$BUILD_COMMAND"
assert_eq "configured: MERGE_MODE" "pr" "$MERGE_MODE"
assert_eq "configured: INTEGRATION_BRANCH" "develop" "$INTEGRATION_BRANCH"
assert_eq "configured: MANAGER_MODEL from .autocoder.json" "big" "$MANAGER_MODEL"
assert_eq "configured: WORKER_MODEL from .autocoder.json" "mid" "$WORKER_MODEL"
assert_eq "configured: FAST_MODEL from .autocoder.json" "small" "$FAST_MODEL"
assert_eq "configured: SUPERPOWERS_AVAILABLE" "true" "$SUPERPOWERS_AVAILABLE"
assert_eq "configured: QUINT_AVAILABLE" "false" "$QUINT_AVAILABLE"
assert_lacks "configured: no first-run model prompt" "$OUTPUT" "ACTION_REQUIRED"
assert_lacks "configured: merge mode is configured" "$OUTPUT" "MERGE_MODE_NOT_CONFIGURED=true"
assert_has "configured: unprioritized marker" "$OUTPUT" "UNPRIORITIZED_ISSUES_FOUND=true"
assert_has "configured: unprioritized data names #7" "$OUTPUT" "7|Needs a priority|"
assert_eq "configured: UNPRIORITIZED_COUNT" "1" "$UNPRIORITIZED_COUNT"
assert_lacks "configured: file backend makes no gh label calls" "$(cat "$GH_LOG" 2>/dev/null)" "gh label"
rm -f "$ISSUES/open/007.md"

# ── 2. env overrides beat .autocoder.json; quint detected ──────────────────────
CFG_ENV="MANAGER_MODEL=env-big FAST_MODEL=env-small" FAKE_PLUGINS="quint" run_config
assert_eq "env: MANAGER_MODEL override" "env-big" "$MANAGER_MODEL"
assert_eq "env: WORKER_MODEL still from json" "mid" "$WORKER_MODEL"
assert_eq "env: FAST_MODEL override" "env-small" "$FAST_MODEL"
assert_eq "env: QUINT_AVAILABLE" "true" "$QUINT_AVAILABLE"
assert_eq "env: SUPERPOWERS_AVAILABLE" "false" "$SUPERPOWERS_AVAILABLE"
assert_has "env: all prioritized" "$OUTPUT" "All open issues have priority labels assigned"
assert_eq "env: UNPRIORITIZED empty" "" "$UNPRIORITIZED"

# ── 3. no autocoder section: scaffold appended, defaults, first-run prompt ─────
printf '# Project\n' > CLAUDE.md
file_backend
run_config
assert_has "scaffold: announced" "$OUTPUT" "Adding autocoder configuration section to CLAUDE.md"
assert_eq "scaffold: section appended once" "1" "$(grep -c '^## Automated Testing & Issue Management' CLAUDE.md)"
assert_eq "scaffold: integration branch is origin's default" "trunk" \
  "$(sed -n '/### Integration Branch/,/^###/{/^```$/n;p;}' CLAUDE.md | grep -v '^#' | grep -v '^```' | grep -v '^$' | head -1)"
assert_eq "scaffold: TEST_COMMAND default" "npm test" "$TEST_COMMAND"
assert_eq "scaffold: BUILD_COMMAND default" "npm run build" "$BUILD_COMMAND"
assert_eq "scaffold: MERGE_MODE" "merge" "$MERGE_MODE"
assert_eq "scaffold: INTEGRATION_BRANCH" "trunk" "$INTEGRATION_BRANCH"
assert_eq "defaults: MANAGER_MODEL" "opus" "$MANAGER_MODEL"
assert_eq "defaults: WORKER_MODEL" "sonnet" "$WORKER_MODEL"
assert_eq "defaults: FAST_MODEL" "haiku" "$FAST_MODEL"
assert_has "first run: ACTION_REQUIRED marker" "$OUTPUT" "ACTION_REQUIRED: Ask the user now using AskUserQuestion:"
assert_has "first run: model line printed" "$OUTPUT" "✅ Models: manager=opus  worker=sonnet  fast=haiku"
run_config
assert_eq "scaffold: a second run does not append again" "1" "$(grep -c '^## Automated Testing & Issue Management' CLAUDE.md)"

# ── 4. no Merge Mode section → marker; no CLAUDE.md → defaults ─────────────────
printf '## Automated Testing & Issue Management\n\n### Regression Test Suite\n```bash\nrun-tests\n```\n' > CLAUDE.md
run_config
assert_has "merge mode missing: marker printed" "$OUTPUT" "MERGE_MODE_NOT_CONFIGURED=true"
assert_eq "merge mode missing: MERGE_MODE empty" "" "$MERGE_MODE"
assert_eq "merge mode missing: TEST_COMMAND still read" "run-tests" "$TEST_COMMAND"
rm -f CLAUDE.md
run_config
assert_has "no CLAUDE.md: says so" "$OUTPUT" "No CLAUDE.md found in project, using defaults"
assert_eq "no CLAUDE.md: MERGE_MODE default" "merge" "$MERGE_MODE"
assert_eq "no CLAUDE.md: INTEGRATION_BRANCH from origin" "trunk" "$INTEGRATION_BRANCH"
[ -f CLAUDE.md ] && bad "no CLAUDE.md: none created" || ok "no CLAUDE.md: none created"

# ── 5. GitHub backend: identity switch and label reconciliation ────────────────
printf '{"issueSource": "github", "managerModel": "m"}\n' > .autocoder.json
FAKE_GH_USER=someone-else run_config
assert_has "github: switches to the repo owner" "$(cat "$GH_LOG")" "gh auth switch --user owner-a"
assert_has "github: creates a missing label" "$(cat "$GH_LOG")" "gh label create needs-design"
assert_has "github: creates merging" "$(cat "$GH_LOG")" "gh label create merging"
assert_has "github: creates spot-check" "$(cat "$GH_LOG")" "gh label create spot-check"
assert_lacks "github: leaves an existing label alone" "$(cat "$GH_LOG")" "gh label create working"
run_config
assert_lacks "github: no switch when already the owner" "$(cat "$GH_LOG")" "gh auth switch"

# ── 6. --platform gemini: GEMINI.md, pro/flash, no integration branch ──────────
file_backend
printf '# Gemini\n' > GEMINI.md
CFG_ENV="INTEGRATION_BRANCH=from-env" run_config --platform gemini
assert_eq "gemini: exit 0" 0 "$RC"
assert_has "gemini: scaffold goes to GEMINI.md" "$OUTPUT" "Adding autocoder configuration section to GEMINI.md"
assert_eq "gemini: scaffold has no Integration Branch section" "0" "$(grep -c '### Integration Branch' GEMINI.md)"
assert_eq "gemini: INTEGRATION_BRANCH left as given" "from-env" "$INTEGRATION_BRANCH"
assert_eq "gemini: MANAGER_MODEL default" "pro" "$MANAGER_MODEL"
assert_eq "gemini: WORKER_MODEL default" "flash" "$WORKER_MODEL"
assert_eq "gemini: FAST_MODEL default" "flash" "$FAST_MODEL"
assert_has "gemini: generic ask" "$OUTPUT" "ACTION_REQUIRED: Ask the user now:"
assert_lacks "gemini: no AskUserQuestion" "$OUTPUT" "AskUserQuestion"
printf '{"issueSource": "github", "managerModel": "m"}\n' > .autocoder.json
run_config --platform gemini
assert_lacks "gemini: no merging label (no merge job there)" "$(cat "$GH_LOG")" "gh label create merging"
assert_has "gemini: spot-check label still reconciled" "$(cat "$GH_LOG")" "gh label create spot-check"

# ── 7. usage errors ────────────────────────────────────────────────────────────
bash "$CONFIG" >/dev/null 2>&1; assert_eq "usage: --out required" 1 "$?"
bash "$CONFIG" --out "$TMP/x" --platform vim >/dev/null 2>&1; assert_eq "usage: bad platform" 1 "$?"

# ── 8. the mirrors call it the same way ───────────────────────────────────────
for f in plugins/autocoder/commands/fix.md .pi/prompts/fix.md; do
  grep -q '"${SCRIPT_DIR}/fix-config.sh" --out "$FIX_CONFIG_ENV"' "$ROOT/$f" \
    && ok "$f calls fix-config.sh" || bad "$f does not call fix-config.sh"
done
grep -q '"${SCRIPT_DIR}/fix-config.sh" --platform gemini --out "$FIX_CONFIG_ENV"' "$ROOT/.agent/workflows/fix.md" \
  && ok ".agent/workflows/fix.md calls fix-config.sh --platform gemini" || bad ".agent/workflows/fix.md does not call fix-config.sh --platform gemini"
for f in plugins/autocoder/commands/fix.md .agent/workflows/fix.md .pi/prompts/fix.md; do
  grep -q '^export MANAGER_MODEL WORKER_MODEL FAST_MODEL$' "$ROOT/$f" \
    && ok "$f exports the model tiers after sourcing" || bad "$f does not export the model tiers"
  grep -q 'claude plugins list' "$ROOT/$f" \
    && bad "$f still carries the inline setup block" || ok "$f no longer carries the inline setup block"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
