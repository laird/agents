#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255: never write the real event logs
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)/plugins/autocoder/scripts"
source "$SCRIPT_DIR/worker-launch-lib.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

REPO="$TMP/repo"
mkdir -p "$REPO/plugins/autocoder/scripts" "$REPO/scripts" "$TMP/bin"
touch "$REPO/plugins/autocoder/scripts/codex-fix-loop.sh"
touch "$REPO/plugins/autocoder/scripts/codex-manage-workers-loop.sh"
touch "$REPO/plugins/autocoder/scripts/droid-fix-loop.sh"
touch "$REPO/plugins/autocoder/scripts/droid-manage-workers-loop.sh"

assert_eq() {
  local actual="$1"
  local expected="$2"
  local message="$3"
  if [ "$actual" != "$expected" ]; then
    echo "FAIL: $message: expected '$expected', got '$actual'" >&2
    exit 1
  fi
}

resolve_worker_launch claude "$REPO"
# Claude workers run a SHELL LOOP, not an interactive session: 3124b99 made each
# issue get a fresh Claude process so its context window starts clean. The manager
# stays interactive because it coordinates across issues.
assert_eq "$WORKER_LAUNCH_MODE" "shell" "Claude workers launch via the shell loop"
assert_eq "$WORKER_COMMAND_MODE" "shell" "Claude workers take shell commands"
assert_eq "$MANAGER_LAUNCH_MODE" "interactive" "Claude manager launches interactively"
# Assert the intent, not just the mode strings — the loop script is what gives
# each issue a fresh context, and the tiers are what keep workers off opus.
case "$WORKER_CMD" in
  *claude-worker-loop.sh*) ;;
  *) echo "FAIL: Claude worker should run claude-worker-loop.sh, got '$WORKER_CMD'" >&2; exit 1 ;;
esac
# Swarm claude defaults to --permission-mode bypassPermissions so a pane does
# not sit on a tool prompt. That is not --dangerously-skip-permissions, which
# opens the "No, exit" consent dialog (#283). No hard-coded model.
_launch() {  # _launch <env...>: MANAGER|AGENT launch commands for claude under herdr
  env -u WORKER_MODEL -u MANAGER_MODEL -u AUTOCODER_WORKER_MODEL -u AUTOCODER_MANAGER_MODEL \
    -u AUTOCODER_CLAUDE_PERMISSION_MODE "$@" bash -c \
    'source "$1"; resolve_worker_launch claude "$2" herdr; printf "%s|%s" "$MANAGER_LAUNCH_CMD" "$AGENT_LAUNCH_CMD"' \
    _ "$LIB_PATH_283" "$TMP" 2>/dev/null
}
LIB_PATH_283="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/plugins/autocoder/scripts/worker-launch-lib.sh"
assert_eq "$(_launch)" "claude --permission-mode bypassPermissions|claude --permission-mode bypassPermissions" \
  "Claude launches in bypassPermissions by default"
case "$(_launch)" in *dangerously*|*--model*) echo "FAIL: default claude launch forces a consent flag or a model" >&2; exit 1 ;; esac
assert_eq "$(_launch AUTOCODER_CLAUDE_PERMISSION_MODE=auto)" "claude --permission-mode auto|claude --permission-mode auto" \
  "AUTOCODER_CLAUDE_PERMISSION_MODE=auto -> --permission-mode auto"
assert_eq "$(_launch AUTOCODER_WORKER_MODEL=claude-sonnet-5-5 AUTOCODER_MANAGER_MODEL=claude-opus-5-5)" \
  "claude --permission-mode bypassPermissions --model claude-opus-5-5|claude --permission-mode bypassPermissions --model claude-sonnet-5-5" \
  "AUTOCODER_*_MODEL set the model per role"
assert_eq "$(_launch WORKER_MODEL=w MANAGER_MODEL=m)" \
  "claude --permission-mode bypassPermissions --model m|claude --permission-mode bypassPermissions --model w" \
  "legacy WORKER_MODEL / MANAGER_MODEL still honoured"
assert_eq "$(_launch 'AUTOCODER_CLAUDE_PERMISSION_MODE=auto; rm -rf x')" "claude|claude" "a permission mode that is not a plain word is refused"

# The worker-loop path must resolve to a file that EXISTS, not just to a
# plausible-looking string. Installed plugins live at
# cache/plugin-marketplace/autocoder/<version>/scripts, so a repo_root derived as
# SCRIPT_DIR/../../.. lands on the cache root; appending plugins/autocoder/scripts
# yields a hybrid path that is real in neither layout (issue #94). The loop script
# always ships beside this lib, so resolve it from the lib's own directory.
BOGUS_ROOT="$TMP/not-a-repo-checkout"
mkdir -p "$BOGUS_ROOT"
resolve_worker_launch claude "$BOGUS_ROOT"
WORKER_LOOP_PATH="${WORKER_CMD#bash \'}"
WORKER_LOOP_PATH="${WORKER_LOOP_PATH%\'}"
if [ ! -f "$WORKER_LOOP_PATH" ]; then
  echo "FAIL: Claude worker loop path does not exist: '$WORKER_LOOP_PATH'" >&2
  exit 1
fi
case "$WORKER_LOOP_PATH" in
  "$BOGUS_ROOT"*)
    echo "FAIL: worker loop path was derived from repo_root instead of the lib dir: '$WORKER_LOOP_PATH'" >&2
    exit 1 ;;
esac
# Restore the normal-layout resolution for any later assertions.
resolve_worker_launch claude "$REPO"

resolve_worker_launch gemini "$REPO"
assert_eq "$WORKER_CMD" "/fix-loop" "Gemini worker command"
assert_eq "$MANAGER_CMD" "/monitor-loop" "Gemini manager command"
assert_eq "$AGENT_LAUNCH_CMD" "gemini --sandbox=false -y" "Gemini worker auto-approves tool calls"
assert_eq "$MANAGER_LAUNCH_CMD" "gemini --sandbox=false -y" "Gemini manager auto-approves tool calls"

# "No goal support" must be simulated through the real signal -- what `codex
# features list` reports -- not by hiding probe-codex-goals.sh from the repo
# tree. The probe now ships beside this lib and is found there, which is the
# whole point: under an installed plugin there is no repo tree to hide it in.
# Distinct fake versions keep the probe's /tmp/codex-goals-probe-<version>
# cache from carrying a verdict between the two cases (or from the developer's
# real codex).
cat > "$TMP/bin/codex" <<'SH'
#!/bin/sh
case "$1" in
  --version) echo "codex-cli 0.0.0-test-nogoals" ;;
  features)  echo "goals    false" ;;
esac
exit 0
SH
chmod +x "$TMP/bin/codex"
rm -f /tmp/codex-goals-probe-codex-cli-0.0.0-test-nogoals

PATH="$TMP/bin:$PATH" resolve_worker_launch codex "$REPO"
assert_eq "$WORKER_LAUNCH_MODE" "shell" "Codex without goal support uses shell fallback"
assert_eq "$WORKER_COMMAND_MODE" "shell" "Codex shell fallback command mode"
assert_eq "$MANAGER_LAUNCH_MODE" "shell" "Codex shell fallback manager mode"

cat > "$TMP/bin/codex" <<'SH'
#!/bin/sh
case "$1" in
  --version) echo "codex-cli 0.0.0-test-goals" ;;
  features)  echo "goals    true" ;;
esac
exit 0
SH
chmod +x "$TMP/bin/codex"
rm -f /tmp/codex-goals-probe-codex-cli-0.0.0-test-goals
PATH="$TMP/bin:$PATH" resolve_worker_launch codex "$REPO"
assert_eq "$WORKER_LAUNCH_MODE" "interactive" "Codex with goal support launches interactively"
assert_eq "$WORKER_COMMAND_MODE" "agent-input" "Codex with goal support receives agent input"
assert_eq "$AGENT_LAUNCH_CMD" "codex --ask-for-approval never" "Codex launch asks for approval never"
case "$WORKER_CMD$MANAGER_CMD" in
  *'gh pr create'*|*'close or PR'*) echo "FAIL: Codex goal tells the swarm to open a PR" >&2; exit 1 ;;
esac
case "$WORKER_CMD" in
  *'Do not open a pull request.'*) ;;
  *) echo "FAIL: Codex worker goal does not forbid a pull request" >&2; exit 1 ;;
esac

resolve_worker_launch droid "$REPO"
assert_eq "$WORKER_LAUNCH_MODE" "shell" "Droid uses shell fallback"
assert_eq "$WORKER_COMMAND_MODE" "shell" "Droid command mode"
assert_eq "$MANAGER_LAUNCH_MODE" "shell" "Droid manager launch mode"

# Grok is an interactive TUI with bare slash commands. Folder trust is --trust.
# Tool permissions are --always-approve. --yolo is not the flag we pass.
resolve_worker_launch grok "$REPO" herdr
assert_eq "$AGENT_LAUNCH_CMD" "grok --trust --always-approve" "Grok worker launch auto-approves"
assert_eq "$MANAGER_LAUNCH_CMD" "grok --trust --always-approve" "Grok manager launch auto-approves"
assert_eq "$WORKER_CMD" "/fix-loop" "Grok worker command is bare /fix-loop"
assert_eq "$MANAGER_CMD" "/monitor-loop" "Grok manager command is bare /monitor-loop"
assert_eq "$WORKER_LAUNCH_MODE" "interactive" "Grok workers are an interactive TUI"
assert_eq "$WORKER_COMMAND_MODE" "agent-input" "Grok workers take a typed slash command"
assert_eq "$MANAGER_LAUNCH_MODE" "interactive" "Grok manager is an interactive TUI"
assert_eq "$MANAGER_COMMAND_MODE" "agent-input" "Grok manager takes a typed slash command"
case "$AGENT_LAUNCH_CMD$MANAGER_LAUNCH_CMD" in
  *--yolo*|*dangerously-skip-permissions*)
    echo "FAIL: Grok launch uses a flag other than --always-approve" >&2
    exit 1 ;;
esac
resolve_worker_launch grok "$REPO" tmux
assert_eq "$WORKER_CMD" "/fix-loop" "Grok tmux worker command stays /fix-loop"

echo "ok worker-launch-lib"
