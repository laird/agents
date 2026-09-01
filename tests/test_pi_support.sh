#!/bin/bash
# tests/test_pi_support.sh — guards the Pi platform's two silent-failure traps.
#
# Both were found by running pi 0.84.4 and reading the user message off
# `--mode json`, and neither produces an error, a non-zero exit, or any visible
# symptom — just an agent that was asked the wrong thing:
#
#   1. WITHOUT `-a`, project-local resources are IGNORED in non-interactive
#      mode. `pi -p "/fix"` then sends the literal four characters "/fix" as
#      the prompt instead of expanding the template.
#
#   2. A prompt template that never mentions `$@` DROPS its arguments.
#      `/fix 42` expands to the protocol alone, so a worker told to work issue
#      42 silently picks its own issue instead.

set -u
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
cd "$ROOT" || exit 1

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_contains() {
  local label="$1" needle="$2" hay="$3"
  if printf '%s' "$hay" | grep -qF -- "$needle"; then pass "$label"
  else fail "$label — '$needle' not in: $hay"; fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

# ── Stub pi so the exact argv each driver builds can be asserted ────────────
cat > "$TMP/bin/pi" <<'STUB'
#!/bin/bash
printf '%s\n' "$@" > "$PI_ARGV_CAPTURE"
STUB
chmod +x "$TMP/bin/pi"

run_driver() {  # run_driver <args...> -> ARGV (newline separated)
  export PI_ARGV_CAPTURE="$TMP/argv.txt"
  : > "$PI_ARGV_CAPTURE"
  PATH="$TMP/bin:$PATH" bash scripts/pi-autocoder.sh "$@" >/dev/null 2>&1
  cat "$PI_ARGV_CAPTURE"
}

# ── Trap 1: -a on every invocation ─────────────────────────────────────────
ARGV=$(run_driver fix)
assert_contains "fix passes -a (without it the template is silently ignored)" "-a" "$ARGV"
assert_contains "fix runs non-interactively" "-p" "$ARGV"
assert_contains "fix invokes the slash command" "/fix" "$ARGV"

ARGV=$(run_driver fix 42)
assert_contains "fix forwards the issue number" "/fix 42" "$ARGV"

ARGV=$(run_driver monitor-workers)
assert_contains "monitor-workers passes -a" "-a" "$ARGV"
assert_contains "monitor-workers invokes its slash command" "/monitor-workers" "$ARGV"

# Every driver, not just the ones sampled above: a new one that forgets -a is
# the whole failure mode.
for script in scripts/pi-*.sh; do
  case "$script" in *pi-autocoder.sh) ;; *) continue ;; esac
  if grep -qE '"\$PI_BIN"[^\n]*-a' "$script" || grep -q '\-p -a' "$script"; then
    pass "$(basename "$script") builds its command with -a"
  else
    fail "$(basename "$script") invokes pi without -a"
  fi
done

# ── Trap 2: an argument-taking prompt template must consume $@ ─────────────
for prompt in .pi/prompts/*.md; do
  name="$(basename "$prompt" .md)"
  if grep -q '^argument-hint:' "$prompt"; then
    if grep -q '\$@' "$prompt"; then
      pass "/$name declares arguments and consumes \$@"
    else
      fail "/$name declares argument-hint but never uses \$@ — its arguments are dropped"
    fi
  fi
done

# ── The packaged prompt bodies are the real command protocols ──────────────
if grep -q "Generated from plugins/autocoder/commands/fix.md" .pi/prompts/fix.md; then
  pass "/fix is generated from the autocoder command, not hand-copied"
else
  fail "/fix is not generated from plugins/autocoder/commands/fix.md"
fi

# ── Launch wiring ──────────────────────────────────────────────────────────
# shellcheck source=/dev/null
source plugins/autocoder/scripts/worker-launch-lib.sh
resolve_worker_launch pi "$ROOT"
[ "$WORKER_LAUNCH_MODE" = "shell" ] && pass "pi workers launch as a shell loop" \
  || fail "pi worker launch mode is '$WORKER_LAUNCH_MODE', want shell"
[ "$MANAGER_LAUNCH_MODE" = "shell" ] && pass "pi manager launches as a shell loop" \
  || fail "pi manager launch mode is '$MANAGER_LAUNCH_MODE', want shell"
assert_contains "pi worker runs its fix loop" "pi-fix-loop.sh" "$WORKER_CMD"
assert_contains "pi manager runs its monitor loop" "pi-manage-workers-loop.sh" "$MANAGER_CMD"

# agents-tui waits on these banner lines to decide the manager pane started.
assert_contains "manager loop prints the banner agents-tui waits for" \
  "== Pi Worker Monitor ==" "$(cat scripts/pi-manage-workers-loop.sh)"

echo ""
echo "$PASS passed / $FAIL failed / $((PASS + FAIL)) total"
[ "$FAIL" -eq 0 ]
