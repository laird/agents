#!/bin/bash
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
assert_eq "${WORKER_MODEL}" "claude-sonnet-5" "Claude worker defaults to the sonnet tier"
assert_eq "${MANAGER_MODEL}" "claude-opus-5" "Claude manager defaults to the opus tier"

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
# Like Claude, Gemini workers run a SHELL LOOP: gemini-fix-loop.sh restarts the
# gemini process per issue so each fix starts with a fresh context. The manager
# stays interactive because it coordinates across issues (monitor-loop).
case "$WORKER_CMD" in
  *gemini-fix-loop.sh*) ;;
  *) echo "FAIL: Gemini worker should run gemini-fix-loop.sh, got '$WORKER_CMD'" >&2; exit 1 ;;
esac
assert_eq "$WORKER_LAUNCH_MODE" "shell" "Gemini workers launch via the shell loop"
assert_eq "$WORKER_COMMAND_MODE" "shell" "Gemini workers take shell commands"
assert_eq "$MANAGER_LAUNCH_MODE" "interactive" "Gemini manager launches interactively"
assert_eq "$MANAGER_CMD" "/monitor-loop" "Gemini manager command"

PATH="$TMP/bin:$PATH" resolve_worker_launch codex "$REPO"
assert_eq "$WORKER_LAUNCH_MODE" "shell" "Codex without goal support uses shell fallback"
assert_eq "$WORKER_COMMAND_MODE" "shell" "Codex shell fallback command mode"
assert_eq "$MANAGER_LAUNCH_MODE" "shell" "Codex shell fallback manager mode"

cat > "$TMP/bin/codex" <<'SH'
#!/bin/sh
exit 0
SH
chmod +x "$TMP/bin/codex"
cat > "$REPO/scripts/probe-codex-goals.sh" <<'SH'
#!/bin/sh
exit 0
SH
chmod +x "$REPO/scripts/probe-codex-goals.sh"
PATH="$TMP/bin:$PATH" resolve_worker_launch codex "$REPO"
assert_eq "$WORKER_LAUNCH_MODE" "interactive" "Codex with goal support launches interactively"
assert_eq "$WORKER_COMMAND_MODE" "agent-input" "Codex with goal support receives agent input"
assert_eq "$AGENT_LAUNCH_CMD" "codex" "Codex launch command"

resolve_worker_launch droid "$REPO"
assert_eq "$WORKER_LAUNCH_MODE" "shell" "Droid uses shell fallback"
assert_eq "$WORKER_COMMAND_MODE" "shell" "Droid command mode"
assert_eq "$MANAGER_LAUNCH_MODE" "shell" "Droid manager launch mode"

echo "ok worker-launch-lib"
