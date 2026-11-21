#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255: never write the real event logs
# tests/test_claude_launch_flags.sh: an unattended worker spawn (the reboot
# recovery path, #271/#274: restart-worker.sh --worktree under herdr) launches
# claude with no forced --dangerously-skip-permissions and no hard-coded model
# (#283), so no bypass-permissions consent dialog waits for an absent human.
# Fake herdr records every call; nothing touches a real multiplexer.

set -u
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS="$ROOT/plugins/autocoder/scripts"
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
T=$(cd "$T" && pwd -P)
mkdir -p "$T/bin"
cat > "$T/bin/herdr" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$HERDR_LOG"
case "$1 $2" in
  "workspace list")   echo '{"result":{"workspaces":[]}}' ;;
  "workspace create") echo '{"result":{"root_pane":{"pane_id":"w9:p1"}}}' ;;
  "agent start")      echo '{"result":{"agent":{"pane_id":"w9:p1"}}}' ;;
  "pane read")        echo "❯ " ;;
  *) exit 0 ;;
esac
EOF
printf '#!/bin/bash\nexit 1\n' > "$T/bin/tmux"; cp "$T/bin/tmux" "$T/bin/cmux"
chmod +x "$T/bin/"*

git init -q "$T/proj"
git -C "$T/proj" -c user.email=t@e -c user.name=T commit -q --allow-empty -m init
git -C "$T/proj" worktree add -q -b wt-1 "$T/proj-wt-1"

spawn() {  # spawn [VAR=val...]: restart the worker in proj-wt-1, return the herdr calls
  : > "$T/herdr.log"
  (cd "$T/proj-wt-1" && env -u WORKER_MODEL -u MANAGER_MODEL -u AUTOCODER_WORKER_MODEL \
     -u AUTOCODER_MANAGER_MODEL -u AUTOCODER_CLAUDE_PERMISSION_MODE -u HERDR_PANE_ID \
     PATH="$T/bin:$PATH" HERDR_LOG="$T/herdr.log" AUTOCODER_MUX_SUBMIT_DELAY=0 \
     AUTOCODER_HERDR_PROBE_SECONDS=2 AUTOCODER_MUX_TIMEOUT_SECONDS=3 AUTOCODER_AGENT_READY_TIMEOUT=1 "$@" \
     bash "$SCRIPTS/restart-worker.sh" --worktree "$T/proj-wt-1" --mux herdr --agent claude >/dev/null 2>&1)
  grep '^agent start' "$T/herdr.log"
}

START=$(spawn)
[ -n "$START" ] && pass "reboot-recovery spawn registers a claude agent under herdr" || fail "no 'agent start': $(cat "$T/herdr.log")"
case "$START" in
  *dangerously*) fail "spawn forces --dangerously-skip-permissions: $START" ;;
  *) pass "spawn has no --dangerously-skip-permissions (no consent dialog)" ;;
esac
case "$START" in
  *--model*) fail "spawn hard-codes a model: $START" ;;
  *) pass "spawn passes no model: the user's Claude Code default applies" ;;
esac
case "$START" in
  *"--kind claude --pane w9:p1") pass "spawn launches plain claude (no args, no bare --)" ;;
  *) fail "unexpected launch: $START" ;;
esac

START=$(spawn AUTOCODER_CLAUDE_PERMISSION_MODE=auto AUTOCODER_WORKER_MODEL=claude-sonnet-5-5)
case "$START" in
  *"-- --permission-mode auto --model claude-sonnet-5-5") pass "opt-in permission mode and model are passed through" ;;
  *) fail "opt-in flags not passed: $START" ;;
esac

# The opt-in reaches a new pane: its shell does not inherit our environment.
LIB="$SCRIPTS/worker-launch-lib.sh"
EXP=$(env -u WORKER_MODEL -u MANAGER_MODEL -u AUTOCODER_MANAGER_MODEL AUTOCODER_CLAUDE_PERMISSION_MODE=auto \
  AUTOCODER_WORKER_MODEL='claude-opus-5-5[1m]' bash -c "source '$LIB'; claude_env_exports")
case "$EXP" in
  *"export AUTOCODER_CLAUDE_PERMISSION_MODE=auto"*"export AUTOCODER_WORKER_MODEL="*) pass "claude_env_exports carries the opt-in into panes" ;;
  *) fail "claude_env_exports: $EXP" ;;
esac
[ "$(env -u WORKER_MODEL -u MANAGER_MODEL -u AUTOCODER_WORKER_MODEL -u AUTOCODER_MANAGER_MODEL -u AUTOCODER_CLAUDE_PERMISSION_MODE bash -c "source '$LIB'; claude_env_exports")" = "" ] \
  && pass "claude_env_exports prints nothing when nothing is configured" || fail "claude_env_exports not empty by default"
ARGS=$(AUTOCODER_WORKER_MODEL='claude-opus-5-5[1m]' bash -c "source '$LIB'; claude_launch_args worker")
mkdir -p "$T/globdir" && touch "$T/globdir/claude-opus-5-51"
OUT=$(cd "$T/globdir" && bash -c "set -- $ARGS; printf '%s|' \"\$@\"")
[ "$OUT" = "--model|claude-opus-5-5[1m]|" ] && pass "a model with [ ] stays one literal word in a pane shell" || fail "glob/quoting: '$ARGS' -> '$OUT'"

# The headless worker loop (tmux/cmux) builds its claude -p call the same way.
mkdir -p "$T/loopbin"
cat > "$T/loopbin/claude" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$CLAUDE_LOG"
exit 0
EOF
chmod +x "$T/loopbin/claude"
loop_args() {
  : > "$T/claude.log"
  (cd "$T/proj-wt-1" && env -u WORKER_MODEL -u AUTOCODER_WORKER_MODEL -u AUTOCODER_CLAUDE_PERMISSION_MODE \
     PATH="$T/loopbin:$PATH" CLAUDE_LOG="$T/claude.log" AUTOCODER_STREAM=0 AUTOCODER_LOG_DIR="$T/logs" "$@" \
     timeout 5 bash "$SCRIPTS/claude-worker-loop.sh" --sleep 0 >/dev/null 2>&1)
  head -1 "$T/claude.log"
}
BANNER=$(cd "$T/proj-wt-1" && env -u WORKER_MODEL -u AUTOCODER_WORKER_MODEL -u AUTOCODER_CLAUDE_PERMISSION_MODE \
  PATH="$T/loopbin:$PATH" CLAUDE_LOG=/dev/null AUTOCODER_STREAM=0 AUTOCODER_LOG_DIR="$T/logs" \
  timeout 5 bash "$SCRIPTS/claude-worker-loop.sh" --sleep 0 2>&1 | head -12)
case "$BANNER" in *"Headless sessions cannot answer permission prompts"*) pass "worker loop warns when no permission mode is set" ;; *) fail "no headless warning: $BANNER" ;; esac
ARGS=$(loop_args)
case "$ARGS" in
  "-p "*) case "$ARGS" in *dangerously*|*--model*) fail "worker loop forces flags: $ARGS" ;; *) pass "worker loop runs claude -p with no forced flags" ;; esac ;;
  *) fail "worker loop did not run claude -p: '$ARGS'" ;;
esac
ARGS=$(loop_args AUTOCODER_CLAUDE_PERMISSION_MODE=acceptEdits WORKER_MODEL=claude-haiku-5-5)
case "$ARGS" in
  "-p --permission-mode acceptEdits --model claude-haiku-5-5 "*) pass "worker loop passes opt-in flags" ;;
  *) fail "worker loop opt-in flags: '$ARGS'" ;;
esac

echo ""
echo "$PASS passed / $FAIL failed / $((PASS + FAIL)) total"
[ "$FAIL" -eq 0 ]
