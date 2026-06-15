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
assert_eq "$WORKER_LAUNCH_MODE" "interactive" "Claude launches interactively"
assert_eq "$WORKER_COMMAND_MODE" "agent-input" "Claude receives agent input"
assert_eq "$MANAGER_LAUNCH_MODE" "interactive" "Claude manager launches interactively"

resolve_worker_launch gemini "$REPO"
assert_eq "$WORKER_CMD" "/fix-loop" "Gemini worker command"
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
