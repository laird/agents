#!/bin/bash
# tests/test_herdr_support.sh — pins the herdr multiplexer contract.
#
# herdr is the third supported multiplexer after tmux and cmux. The traps this
# guards are the same ones the cmux tests exist for, because herdr shares both
# failure shapes:
#
#   1. The `herdr` binary stays on $PATH whether or not a herdr server is
#      running, so auto-detect must gate on a LIVENESS probe, never on bare
#      `command -v herdr` (the cmux issue #18 regression, third platform).
#
#   2. Prompt submission must be pane send-text followed by a SEPARATE
#      send-keys enter with a settle delay — the one-call form leaves text
#      sitting unsubmitted in an agent TUI's input box (see
#      test_mux_send_enter.sh for the full pathology).

set -u
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_contains() {
  local label="$1" needle="$2" hay="$3"
  if printf '%s' "$hay" | grep -qF -- "$needle"; then pass "$label"
  else fail "$label — '$needle' not in output"; fi
}

LIB="$ROOT/plugins/autocoder/scripts/mux-send-lib.sh"
MANIFEST_LIB="$ROOT/plugins/autocoder/scripts/swarm-manifest-lib.sh"

PLUGIN_SCRIPTS=(
  "$ROOT/plugins/autocoder/scripts/start-parallel-agents.sh"
  "$ROOT/plugins/autocoder/scripts/add-worker.sh"
  "$ROOT/plugins/autocoder/scripts/join-parallel-agents.sh"
)

STUB_DIR=$(mktemp -d)
trap 'rm -rf "$STUB_DIR"' EXIT

# Stub `herdr` that behaves per $HERDR_STUB_MODE and records every argv line.
make_herdr_stub() {
  cat > "$STUB_DIR/herdr" <<'STUB'
#!/bin/bash
[ -n "${HERDR_ARGV_CAPTURE:-}" ] && printf '%s\n' "$*" >> "$HERDR_ARGV_CAPTURE"
case "${HERDR_STUB_MODE:-running}" in
  running) exit 0 ;;
  dead)    echo '{"error":{"code":"server_not_running"}}'; exit 1 ;;
  hang)    sleep 60; exit 0 ;;
esac
exit 0
STUB
  chmod +x "$STUB_DIR/herdr"
}
make_herdr_stub

# ── 1. The lib defines the herdr helpers ─────────────────────────────────────
for fn in herdr_is_running send_herdr_command validate_herdr_target; do
  if grep -q "${fn}()" "$LIB"; then pass "mux-send-lib.sh defines $fn"
  else fail "mux-send-lib.sh does not define $fn"; fi
done

# ── 2. Liveness probe semantics (installed ≠ running) ────────────────────────
# 2a. herdr not installed at all -> probe fails without erroring out
if PATH="/usr/bin:/bin:/usr/sbin:/sbin" bash -c "source '$LIB'; herdr_is_running" 2>/dev/null; then
  fail "probe should fail when herdr is not installed"
else
  pass "probe fails when herdr is not installed"
fi

# 2b. herdr installed AND server running -> probe succeeds
if HERDR_STUB_MODE=running PATH="$STUB_DIR:$PATH" bash -c "source '$LIB'; herdr_is_running"; then
  pass "probe succeeds when the herdr server is running"
else
  fail "probe should succeed when the herdr server is running"
fi

# 2c. herdr installed but server NOT running -> probe fails
if HERDR_STUB_MODE=dead PATH="$STUB_DIR:$PATH" bash -c "source '$LIB'; herdr_is_running" 2>/dev/null; then
  fail "probe should fail when herdr is installed but no server is running"
else
  pass "probe fails when herdr is installed but no server is running"
fi

# 2d. wedged herdr -> probe times out instead of hanging fleet startup
START=$(date +%s)
if HERDR_STUB_MODE=hang AUTOCODER_HERDR_PROBE_SECONDS=2 PATH="$STUB_DIR:$PATH" \
   bash -c "source '$LIB'; herdr_is_running" 2>/dev/null; then
  fail "probe should fail when herdr hangs"
else
  pass "probe fails when herdr hangs"
fi
ELAPSED=$(( $(date +%s) - START ))
if [ "$ELAPSED" -lt 20 ]; then pass "probe honors its timeout (${ELAPSED}s)"
else fail "probe did not honor its timeout (took ${ELAPSED}s)"; fi

# ── 3. send_herdr_command submits with a SEPARATE enter ──────────────────────
CAPTURE="$STUB_DIR/argv.txt"
: > "$CAPTURE"
HERDR_STUB_MODE=running HERDR_ARGV_CAPTURE="$CAPTURE" PATH="$STUB_DIR:$PATH" \
  AUTOCODER_MUX_SUBMIT_DELAY=0.1 \
  bash -c "source '$LIB'; send_herdr_command 'w1:p1' 'echo hello'" \
  || fail "send_herdr_command exited non-zero against a healthy stub"
assert_contains "send_herdr_command sends the text via pane send-text" \
  "pane send-text w1:p1 echo hello" "$(cat "$CAPTURE")"
assert_contains "send_herdr_command submits with a standalone enter key" \
  "pane send-keys w1:p1 enter" "$(cat "$CAPTURE")"
if [ "$(wc -l < "$CAPTURE" | tr -d ' ')" = "2" ]; then
  pass "send_herdr_command makes exactly two herdr calls (text, then enter)"
else
  fail "send_herdr_command made $(wc -l < "$CAPTURE" | tr -d ' ') herdr calls, want 2"
fi
body=$(awk '/^send_herdr_command\(\)/,/^}/' "$LIB")
if printf '%s' "$body" | grep -q 'sleep'; then
  pass "send_herdr_command sleeps between text and enter"
else
  fail "send_herdr_command has no settle delay between text and enter"
fi

# ── 4. validate_herdr_target checks the pane over the socket API ─────────────
: > "$CAPTURE"
HERDR_STUB_MODE=running HERDR_ARGV_CAPTURE="$CAPTURE" PATH="$STUB_DIR:$PATH" \
  bash -c "source '$LIB'; validate_herdr_target 'w1:p1'" \
  || fail "validate_herdr_target exited non-zero against a healthy stub"
assert_contains "validate_herdr_target reads the pane" "pane get w1:p1" "$(cat "$CAPTURE")"

# ── 5. Auto-detect gates MUX="herdr" on the liveness probe ───────────────────
# Same invariant as the cmux test: selecting herdr from bare presence is the
# regression; `MUX="herdr"` may only be reached through a herdr_is_running
# guard.
for s in "${PLUGIN_SCRIPTS[@]}"; do
  name=$(basename "$s")
  grep -q 'herdr_is_running' "$s" || fail "$name: auto-detect does not use herdr_is_running"
  python3 - "$s" "$name" <<'PY' || fail "$(basename "$s"): unguarded MUX=\"herdr\""
import re, sys
path, name = sys.argv[1], sys.argv[2]
lines = open(path).read().splitlines()
for i, line in enumerate(lines):
    if re.search(r'MUX="herdr"', line):
        guard = None
        for j in range(i, max(-1, i - 4), -1):
            if re.search(r'\b(if|elif)\b', lines[j]):
                guard = lines[j]
                break
        if guard is None or 'herdr_is_running' not in guard:
            print(f"FAIL: {name}: MUX=\"herdr\" set at line {i+1} without a "
                  f"herdr_is_running guard (guard was: {guard!r})", file=sys.stderr)
            sys.exit(1)
sys.exit(0)
PY
  pass "$name: MUX=\"herdr\" only reachable through herdr_is_running"
done

# Running inside a herdr pane (HERDR_ENV=1) prefers herdr over cmux.
if grep -q 'HERDR_ENV' "$ROOT/plugins/autocoder/scripts/start-parallel-agents.sh"; then
  pass "start-parallel-agents.sh prefers herdr when running inside a herdr pane"
else
  fail "start-parallel-agents.sh ignores HERDR_ENV (inside-herdr runs would pick cmux/tmux)"
fi

# ── 6. Explicit --mux herdr is honored and validated ─────────────────────────
HELP_OUT=$("$ROOT/plugins/autocoder/scripts/start-parallel-agents.sh" --help 2>&1 || true)
assert_contains "start-parallel-agents.sh --help offers herdr" "tmux|cmux|herdr" "$HELP_OUT"
sed -n '/Validate multiplexer choice/,/^esac$/p' \
    "$ROOT/plugins/autocoder/scripts/start-parallel-agents.sh" | grep -q 'herdr' \
  && pass "start-parallel-agents.sh validates an explicit --mux herdr" \
  || fail "start-parallel-agents.sh does not accept --mux herdr in validation"

# ── 7. Manifest records the herdr pane target ────────────────────────────────
# shellcheck source=/dev/null
source "$MANIFEST_LIB"
WORKER_JSON=$(manifest_worker_json 1 /tmp/wt-1 shell shell false "" "" paused "w1:p1")
if printf '%s' "$WORKER_JSON" | python3 -c '
import json, sys
d = json.load(sys.stdin)
sys.exit(0 if d.get("herdrPane") == "w1:p1" else 1)
'; then
  pass "manifest_worker_json records herdrPane"
else
  fail "manifest_worker_json does not record herdrPane (got: $WORKER_JSON)"
fi

MANAGER_JSON=$(manifest_manager_json shell false shell ready.txt "" "" "w9:p1")
if printf '%s' "$MANAGER_JSON" | python3 -c '
import json, sys
d = json.load(sys.stdin)
sys.exit(0 if d.get("herdrPane") == "w9:p1" else 1)
'; then
  pass "manifest_manager_json records herdrPane"
else
  fail "manifest_manager_json does not record herdrPane (got: $MANAGER_JSON)"
fi

# ── 8. Every mux-branching lifecycle script has a herdr branch ───────────────
# These scripts dispatch on the manifest/CLI mux value; a missing branch means
# a herdr swarm fails at that lifecycle step with "Unknown mux".
for rel in start-parallel-agents.sh start-workers.sh add-worker.sh \
           restart-worker.sh remove-worker.sh stop-parallel-agents.sh \
           join-parallel-agents.sh; do
  s="$ROOT/plugins/autocoder/scripts/$rel"
  if grep -q '"herdr"' "$s"; then pass "$rel dispatches on herdr"
  else fail "$rel has no herdr branch"; fi
done

# ── 9. Workers surface as NAMED herdr agents, not anonymous terminals ────────
# herdr's agent list only shows panes registered via `herdr agent start`, so a
# manager + N workers must produce N+1 named entries the user can click on.
# Typing the launch command into the pane is only the fallback.

# 9a. The lib defines the agent-surface helpers
for fn in herdr_agent_name start_herdr_agent prompt_herdr_agent; do
  if grep -q "${fn}()" "$LIB"; then pass "mux-send-lib.sh defines $fn"
  else fail "mux-send-lib.sh does not define $fn"; fi
done

# 9b. herdr_agent_name produces a valid name: [a-z][a-z0-9_-]{0,31}
NAME_OUT=$(bash -c "source '$LIB'; herdr_agent_name 'wt1-My.Repo Name'")
[ "$NAME_OUT" = "wt1-my-repo-name" ] \
  && pass "herdr_agent_name lowercases and replaces invalid chars" \
  || fail "herdr_agent_name gave '$NAME_OUT', want 'wt1-my-repo-name'"
NAME_OUT=$(bash -c "source '$LIB'; herdr_agent_name '123---'")
case "$NAME_OUT" in
  [a-z]*) pass "herdr_agent_name forces a leading letter ('$NAME_OUT')" ;;
  *)      fail "herdr_agent_name produced invalid leading char: '$NAME_OUT'" ;;
esac
NAME_OUT=$(bash -c "source '$LIB'; herdr_agent_name 'w$(printf 'x%.0s' $(seq 1 60))'")
[ "${#NAME_OUT}" -le 32 ] \
  && pass "herdr_agent_name truncates to 32 chars" \
  || fail "herdr_agent_name returned ${#NAME_OUT} chars"

# 9c. start_herdr_agent registers through `herdr agent start ... --kind ... --pane ... --`
: > "$CAPTURE"
HERDR_STUB_MODE=running HERDR_ARGV_CAPTURE="$CAPTURE" PATH="$STUB_DIR:$PATH" \
  bash -c "source '$LIB'; start_herdr_agent wt1-proj claude w1:p1 --dangerously-skip-permissions --model claude-sonnet-5" \
  || fail "start_herdr_agent exited non-zero against a healthy stub"
assert_contains "start_herdr_agent registers a NAMED agent in the pane" \
  "agent start wt1-proj --kind claude --pane w1:p1 -- --dangerously-skip-permissions --model claude-sonnet-5" \
  "$(cat "$CAPTURE")"

# 9d. prompt_herdr_agent submits through the agent surface (one ordered write)
: > "$CAPTURE"
HERDR_STUB_MODE=running HERDR_ARGV_CAPTURE="$CAPTURE" PATH="$STUB_DIR:$PATH" \
  bash -c "source '$LIB'; prompt_herdr_agent w1:p1 '/autocoder:fix-loop'" \
  || fail "prompt_herdr_agent exited non-zero against a healthy stub"
assert_contains "prompt_herdr_agent uses herdr agent prompt" \
  "agent prompt w1:p1 /autocoder:fix-loop" "$(cat "$CAPTURE")"

# 9e. The launcher/lifecycle scripts register agents instead of only typing
for rel in start-parallel-agents.sh add-worker.sh restart-worker.sh; do
  s="$ROOT/plugins/autocoder/scripts/$rel"
  grep -q 'start_herdr_agent' "$s" \
    && pass "$rel registers workers via start_herdr_agent" \
    || fail "$rel never calls start_herdr_agent (workers stay anonymous)"
done
for rel in start-parallel-agents.sh start-workers.sh add-worker.sh restart-worker.sh; do
  s="$ROOT/plugins/autocoder/scripts/$rel"
  grep -q 'prompt_herdr_agent' "$s" \
    && pass "$rel prompts through the agent surface" \
    || fail "$rel never calls prompt_herdr_agent"
done

# ── 10. Under herdr, claude workers are interactive (fix-loop), not claude -p ─
# The headless `claude -p` worker loop is undetectable by herdr, so the mux
# argument must flip claude to an interactive launch there — and must NOT
# change the tmux/cmux resolution.
WLL="$ROOT/plugins/autocoder/scripts/worker-launch-lib.sh"
HERDR_RESOLVE=$(bash -c "source '$WLL'; resolve_worker_launch claude '$ROOT' herdr >/dev/null 2>&1; \
  printf '%s|%s|%s|%s|%s' \"\$WORKER_LAUNCH_MODE\" \"\$WORKER_COMMAND_MODE\" \"\$WORKER_CMD\" \"\$AGENT_LAUNCH_CMD\" \"\$MANAGER_COMMAND_MODE\"")
case "$HERDR_RESOLVE" in
  "interactive|agent-input|/autocoder:fix-loop|claude "*"|agent-input")
    pass "claude+herdr resolves to an interactive fix-loop worker" ;;
  *)
    fail "claude+herdr resolved to '$HERDR_RESOLVE'" ;;
esac
TMUX_RESOLVE=$(bash -c "source '$WLL'; resolve_worker_launch claude '$ROOT' tmux >/dev/null 2>&1; \
  printf '%s|%s' \"\$WORKER_LAUNCH_MODE\" \"\$WORKER_COMMAND_MODE\"")
[ "$TMUX_RESOLVE" = "shell|shell" ] \
  && pass "claude+tmux keeps the shell worker loop (fresh context per issue)" \
  || fail "claude+tmux resolution changed to '$TMUX_RESOLVE'"

# 10b. Every resolve_worker_launch caller passes the mux through
for rel in start-parallel-agents.sh start-workers.sh add-worker.sh restart-worker.sh; do
  s="$ROOT/plugins/autocoder/scripts/$rel"
  grep -Eq 'resolve_worker_launch .*"\$(MUX|MANIFEST_MUX)"' "$s" \
    && pass "$rel passes the mux to resolve_worker_launch" \
    || fail "$rel calls resolve_worker_launch without the mux"
done

# ── 11. The scripts stay syntactically valid ─────────────────────────────────
for s in "$LIB" "$MANIFEST_LIB" "${PLUGIN_SCRIPTS[@]}" \
         "$ROOT/plugins/autocoder/scripts/start-workers.sh" \
         "$ROOT/plugins/autocoder/scripts/restart-worker.sh" \
         "$ROOT/plugins/autocoder/scripts/remove-worker.sh" \
         "$ROOT/plugins/autocoder/scripts/stop-parallel-agents.sh"; do
  bash -n "$s" && pass "$(basename "$s") parses" || fail "syntax error in $s"
done

echo ""
echo "$PASS passed / $FAIL failed / $((PASS + FAIL)) total"
[ "$FAIL" -eq 0 ]
