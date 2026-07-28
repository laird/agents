#!/bin/bash
# Timeout-wrapped tmux/cmux send helpers.

AUTOCODER_MUX_TIMEOUT_SECONDS="${AUTOCODER_MUX_TIMEOUT_SECONDS:-15}"

# Startup liveness probes should be quicker than in-flight sends.
AUTOCODER_CMUX_PROBE_SECONDS="${AUTOCODER_CMUX_PROBE_SECONDS:-5}"

run_with_timeout() {
  local seconds="$1"
  shift
  python3 - "$seconds" "$@" <<'PY'
import subprocess
import sys

seconds = float(sys.argv[1])
cmd = sys.argv[2:]
try:
    completed = subprocess.run(cmd, timeout=seconds)
except subprocess.TimeoutExpired:
    sys.exit(124)
sys.exit(completed.returncode)
PY
}

# Is cmux actually RUNNING, not merely installed?
#
# cmux ships as a cask, so `command -v cmux` stays true forever once installed
# and says nothing about whether the app/daemon is up. Presence must therefore
# never decide auto-detect on its own — it is only a precondition for probing.
# `cmux tree --all` is the same cheap read-only call /autocoder:monitor-workers
# uses for discovery. The probe is timeout-guarded (macOS has no timeout(1), so
# this reuses run_with_timeout) so a wedged cmux cannot hang fleet startup.
cmux_is_running() {
  command -v cmux &> /dev/null || return 1
  run_with_timeout "$AUTOCODER_CMUX_PROBE_SECONDS" cmux tree --all >/dev/null 2>&1
}

send_tmux_command() {
  local target="$1"
  local text="$2"
  run_with_timeout "$AUTOCODER_MUX_TIMEOUT_SECONDS" tmux send-keys -t "$target" "$text" C-m
}

send_tmux_text_enter() {
  local target="$1"
  local text="$2"
  run_with_timeout "$AUTOCODER_MUX_TIMEOUT_SECONDS" tmux send-keys -t "$target" "$text" Enter
}

validate_tmux_target() {
  local target="$1"
  run_with_timeout "$AUTOCODER_MUX_TIMEOUT_SECONDS" tmux display-message -p -t "$target" '#{pane_id}' >/dev/null
}

send_cmux_command() {
  local workspace="$1"
  local text="$2"
  run_with_timeout "$AUTOCODER_MUX_TIMEOUT_SECONDS" cmux send --workspace "$workspace" "$text" >/dev/null &&
    run_with_timeout "$AUTOCODER_MUX_TIMEOUT_SECONDS" cmux send-key --workspace "$workspace" enter >/dev/null
}

validate_cmux_target() {
  local workspace="$1"
  run_with_timeout "$AUTOCODER_MUX_TIMEOUT_SECONDS" cmux read-screen --workspace "$workspace" >/dev/null
}
