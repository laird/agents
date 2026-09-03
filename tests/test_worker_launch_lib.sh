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
# Claude workers run an INTERACTIVE session, like gemini and codex. The previous
# headless shell loop (claude-worker-loop.sh, `claude -p` per issue) got a fresh
# context per issue from the process boundary, but it renders no TUI -- and every
# supervision signal the manager has is a TUI artifact: monitor-workers Step 4c
# reads `ctx NN%` off the status line, and worker-idle.sh proves BUSY from
# `(Nm Ns·` / `↓ N tokens` / `esc to interrupt`, none of which a headless pane can
# emit (32 false IDLE reports, zero true positives). Fresh context per issue is now
# preserved by instruction: /autocoder:fix mandates /compact before every issue.
assert_eq "$WORKER_LAUNCH_MODE" "interactive" "Claude workers launch interactively"
assert_eq "$WORKER_COMMAND_MODE" "agent-input" "Claude workers take agent input"
assert_eq "$MANAGER_LAUNCH_MODE" "interactive" "Claude manager launches interactively"
# Assert the intent, not just the mode strings — the fix-loop is what makes the
# worker self-claim, and the tiers are what keep workers off opus.
assert_eq "$WORKER_CMD" "/autocoder:fix-loop" "Claude worker runs the fix loop"
assert_eq "${WORKER_MODEL}" "claude-sonnet-5" "Claude worker defaults to the sonnet tier"
assert_eq "${MANAGER_MODEL}" "claude-opus-5" "Claude manager defaults to the opus tier"
case "$AGENT_LAUNCH_CMD" in
  claude\ *--model\ claude-sonnet-5) ;;
  *) echo "FAIL: Claude worker launch command should start claude on the worker tier, got '$AGENT_LAUNCH_CMD'" >&2; exit 1 ;;
esac

# The issue-#94 check that used to live here — "the claude worker loop path must
# resolve to a file that EXISTS under an installed plugin, not to a repo_root
# path real in neither layout" — no longer has a subject: the claude branch
# resolves no loop driver at all now. It is NOT dropped coverage. The invariant
# moved to where it belongs, tests/test_script_packaging.sh, which asserts both
# that each platform package ships its own driver beside worker-launch-lib.sh and
# that the lib never addresses a driver as "$repo_root/scripts/<name>". Asserting
# it here would need a driver the claude package deliberately does not carry.

resolve_worker_launch gemini "$REPO"
assert_eq "$WORKER_CMD" "/fix-loop" "Gemini worker command"
assert_eq "$MANAGER_CMD" "/monitor-loop" "Gemini manager command"

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
assert_eq "$AGENT_LAUNCH_CMD" "codex" "Codex launch command"

resolve_worker_launch droid "$REPO"
assert_eq "$WORKER_LAUNCH_MODE" "shell" "Droid uses shell fallback"
assert_eq "$WORKER_COMMAND_MODE" "shell" "Droid command mode"
assert_eq "$MANAGER_LAUNCH_MODE" "shell" "Droid manager launch mode"

echo "ok worker-launch-lib"
