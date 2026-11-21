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

# Send prompt text to an interactive agent TUI, then submit it.
#
# The Enter MUST be a separate send-keys call. Passing it as a trailing key in
# the same call -- `send-keys "$text" Enter` -- reliably leaves the text sitting
# UNSUBMITTED in the agent's input box: the TUI receives the whole burst as one
# paste and treats the trailing newline as part of the pasted content rather
# than as submit. The pane then looks like it received the message (a
# capture-pane grep for your marker succeeds) while the agent never saw it, so
# the dispatch silently does nothing and the worker is later misread as idle or
# disobedient. send_cmux_command has always done this correctly; tmux did not.
#
# The delay between the two calls is what lets the TUI settle out of paste
# mode. Zero works sometimes, which is worse than never working.
AUTOCODER_MUX_SUBMIT_DELAY="${AUTOCODER_MUX_SUBMIT_DELAY:-0.4}"

send_tmux_text_enter() {
  local target="$1"
  local text="$2"
  run_with_timeout "$AUTOCODER_MUX_TIMEOUT_SECONDS" tmux send-keys -t "$target" "$text" || return 1
  sleep "$AUTOCODER_MUX_SUBMIT_DELAY"
  run_with_timeout "$AUTOCODER_MUX_TIMEOUT_SECONDS" tmux send-keys -t "$target" Enter
}

validate_tmux_target() {
  local target="$1"
  run_with_timeout "$AUTOCODER_MUX_TIMEOUT_SECONDS" tmux display-message -p -t "$target" '#{pane_id}' >/dev/null
}

# Is a herdr server actually RUNNING, not merely installed?
#
# Same trap as cmux: the `herdr` binary stays on $PATH once installed and says
# nothing about whether a server is up, so presence must never decide
# auto-detect on its own. `herdr workspace list` is a cheap read-only socket
# call that exits non-zero (server_not_running) when no server is listening.
AUTOCODER_HERDR_PROBE_SECONDS="${AUTOCODER_HERDR_PROBE_SECONDS:-5}"

herdr_is_running() {
  command -v herdr &> /dev/null || return 1
  run_with_timeout "$AUTOCODER_HERDR_PROBE_SECONDS" herdr workspace list >/dev/null 2>&1
}

# Targets are herdr pane IDs (e.g. "w1:p1") — the root pane of the worker's
# workspace. The enter is a separate send-keys call with a settle delay for
# the same reason send_tmux_text_enter's is (see above): one burst reads as a
# paste and the trailing newline never submits.
send_herdr_command() {
  local pane="$1"
  local text="$2"
  run_with_timeout "$AUTOCODER_MUX_TIMEOUT_SECONDS" herdr pane send-text "$pane" "$text" >/dev/null || return 1
  sleep "$AUTOCODER_MUX_SUBMIT_DELAY"
  run_with_timeout "$AUTOCODER_MUX_TIMEOUT_SECONDS" herdr pane send-keys "$pane" enter >/dev/null
}

validate_herdr_target() {
  local pane="$1"
  run_with_timeout "$AUTOCODER_MUX_TIMEOUT_SECONDS" herdr pane get "$pane" >/dev/null 2>&1
}

# herdr distinguishes LAYOUT (workspaces/tabs/panes) from AGENTS: only a pane
# whose occupant was registered via `herdr agent start <name>` gets its own
# named, clickable entry in herdr's agent list. Typing a launch command into a
# pane produces an anonymous terminal instead, so a swarm of one manager and N
# workers must issue N+1 `agent start` calls to appear as N+1 agents.

# Agent names must match [a-z][a-z0-9_-]{0,31} and be unique among live agents.
herdr_agent_name() {
  local name
  name=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9_-]/-/g' -e 's/^[^a-z]*//')
  [ -z "$name" ] && name="agent"
  printf '%.32s' "$name"
}

# `herdr agent start` blocks until the agent is detected and ready for input
# (herdr's own default is 30s), so the wrapper timeout must sit ABOVE that or
# every slow-but-successful start would be misreported as a failure.
AUTOCODER_HERDR_START_TIMEOUT_SECONDS="${AUTOCODER_HERDR_START_TIMEOUT_SECONDS:-45}"

# start_herdr_agent NAME KIND PANE [agent-args...] — start an interactive
# agent in an existing shell pane and register it under NAME. On failure,
# HERDR_START_ERROR holds the herdr error code ("timeout", "agent_pane_busy",
# a name-conflict code, ...) so callers can pick the right recovery.
start_herdr_agent() {
  local name="$1" kind="$2" pane="$3"
  shift 3
  local err
  HERDR_START_ERROR=""
  # No `--` without arguments after it (#283: a plain `claude` has none).
  local -a extra=()
  [ $# -gt 0 ] && extra=(-- "$@")
  if err=$(run_with_timeout "$AUTOCODER_HERDR_START_TIMEOUT_SECONDS" \
      herdr agent start "$name" --kind "$kind" --pane "$pane" ${extra[@]+"${extra[@]}"} 2>&1 >/dev/null); then
    return 0
  fi
  HERDR_START_ERROR=$(printf '%s' "$err" | python3 -c '
import json, sys
try:
    print(json.loads(sys.stdin.read().strip().splitlines()[-1])["error"]["code"])
except Exception:
    pass' 2>/dev/null)
  return 1
}

# How long launch_herdr_agent keeps polling for a slow-starting agent after
# `agent start` itself timed out (tries × delay seconds).
AUTOCODER_HERDR_OCCUPANCY_TRIES="${AUTOCODER_HERDR_OCCUPANCY_TRIES:-10}"
AUTOCODER_HERDR_OCCUPANCY_DELAY="${AUTOCODER_HERDR_OCCUPANCY_DELAY:-3}"

# launch_herdr_agent NAME KIND PANE LAUNCH_CMD — register the interactive
# agent for a swarm pane, handling the failure shapes seen in production:
#
#   1. Slow startup: `agent start` times out but the agent IS still coming up
#      in the pane (seen live: a worker resumed a stale scheduled task the
#      moment it booted). Typing the launch command now would inject it into
#      the agent's INPUT BOX, so poll for occupancy and claim the name with
#      `agent rename` instead.
#   2. Name conflict: a stale agent from a previous swarm still holds the
#      name; the pane is a free shell, so retry once under a pane-derived name.
#   3. Pane genuinely empty after all that: type the launch command into the
#      shell as the last resort (works, but stays anonymous in the UI).
launch_herdr_agent() {
  local name="$1" kind="$2" pane="$3" launch_cmd="$4"
  local -a argv
  read -r -a argv <<< "$launch_cmd"
  # The launch command was built for a shell (claude_launch_args %q-quotes, #283),
  # but here it is split without one: drop the quoting backslashes. Launch words
  # are validated plain words, so a literal backslash never belongs in them.
  argv=("${argv[@]//\\/}")

  if start_herdr_agent "$name" "$kind" "$pane" "${argv[@]:1}"; then
    echo "   ✓ Registered herdr agent '$name'"
    return 0
  fi

  if [ "$HERDR_START_ERROR" = "timeout" ] || [ -z "$HERDR_START_ERROR" ]; then
    local tries="$AUTOCODER_HERDR_OCCUPANCY_TRIES"
    while [ "$tries" -gt 0 ]; do
      if run_with_timeout "$AUTOCODER_MUX_TIMEOUT_SECONDS" herdr agent get "$pane" >/dev/null 2>&1; then
        run_with_timeout "$AUTOCODER_MUX_TIMEOUT_SECONDS" herdr agent rename "$pane" "$name" >/dev/null 2>&1 || true
        echo "   ✓ Agent came up after a slow start; named '$name'"
        return 0
      fi
      tries=$((tries - 1))
      sleep "$AUTOCODER_HERDR_OCCUPANCY_DELAY"
    done
  else
    local alt
    alt=$(herdr_agent_name "$(printf '%.24s' "$name")-${pane//:/}")
    if start_herdr_agent "$alt" "$kind" "$pane" "${argv[@]:1}"; then
      echo "   ✓ Registered herdr agent '$alt'"
      return 0
    fi
  fi

  echo "   ⚠️  herdr agent start failed; typing launch command into the pane"
  send_herdr_command "$pane" "$launch_cmd"
  sleep 5
  return 0
}

# Submit a prompt through herdr's agent surface (target: agent name or the
# pane ID hosting it). Unlike send_herdr_command this honors bracketed paste
# and submits text+enter as one ordered write, so no settle-delay heuristics.
prompt_herdr_agent() {
  local target="$1"
  local text="$2"
  run_with_timeout "$AUTOCODER_MUX_TIMEOUT_SECONDS" herdr agent prompt "$target" "$text" >/dev/null
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

# Read what a pane shows. tmux targets are pane IDs, cmux targets workspace
# refs, herdr targets pane IDs.
capture_target() {
  local mux="$1" target="$2"
  case "$mux" in
    tmux)  run_with_timeout "$AUTOCODER_MUX_TIMEOUT_SECONDS" tmux capture-pane -p -t "$target" 2>/dev/null ;;
    cmux)  run_with_timeout "$AUTOCODER_MUX_TIMEOUT_SECONDS" cmux read-screen --workspace "$target" 2>/dev/null ;;
    herdr) run_with_timeout "$AUTOCODER_MUX_TIMEOUT_SECONDS" herdr pane read "$target" 2>/dev/null ;;
  esac
}

# Consent and folder-trust dialogs an agent can show when it starts: claude's
# --dangerously-skip-permissions consent ("No, exit" is the default) and its
# "trust this folder" check, gemini's "Do you trust this folder?", codex's
# "Do you trust the contents of this directory?". A launcher that types the
# first prompt and Enter a fixed time after starting the agent answers such a
# dialog with its default instead of submitting the prompt (#253). Override
# with an extended regex when an agent words its dialog differently.
#
# Case matters: a claude started with --dangerously-skip-permissions shows
# "bypass permissions on" in its footer for as long as it runs, so only the
# dialog's capitalised "Bypass Permissions" may match, never the lowercase
# words. The prompt typed after the first check is on screen for the second
# one, so no prompt a launcher sends may match this pattern either
# (tests/test_agent_prompt_consent.sh checks every agent's prompts).
AUTOCODER_CONSENT_PATTERN="${AUTOCODER_CONSENT_PATTERN:-No, exit|Bypass Permissions|[Dd]o you trust|one you trust|[Tt]rust (this |the |parent )?folder|work in this folder}"

# An open dialog is the last thing drawn on the pane, and its choices ("No,
# exit", "Trust folder", "work in this folder", or an older codex's question
# just above its "Yes, continue / No, quit") sit in its bottom lines. So
# only the last non-blank lines are checked: dialog words higher up, in a shell
# banner, scrollback or a transcript that quotes a dialog, are not a dialog
# (#260; the idle sentinel's check does the same, #258).
AUTOCODER_CONSENT_TAIL_LINES="${AUTOCODER_CONSENT_TAIL_LINES:-12}"

# 0 when the pane shows a consent or trust dialog. A pane that cannot be read
# counts as showing none: the send that follows reports that failure itself.
consent_dialog_showing() {
  local mux="$1" target="$2" bottom
  bottom=$(capture_target "$mux" "$target" | grep -v '^[[:space:]]*$' \
    | tail -n "$AUTOCODER_CONSENT_TAIL_LINES")
  grep -Eq "$AUTOCODER_CONSENT_PATTERN" <<< "$bottom"
}

# Type the first prompt into an agent that was just launched, unless the agent
# is showing a consent or trust dialog. The pane is checked before the text is
# typed and again before Enter, so a dialog that draws while the text is being
# typed still gets no Enter. Returns 0 sent, 1 the send failed, 3 a dialog is
# showing (nothing submitted; the dialog is left for a person to answer).
#   send_agent_prompt <tmux|cmux|herdr> <target> <text>
send_agent_prompt() {
  local mux="$1" target="$2" text="$3"
  if consent_dialog_showing "$mux" "$target"; then
    _agent_prompt_withheld "$target" "$text"
    return 3
  fi
  case "$mux" in
    tmux)
      run_with_timeout "$AUTOCODER_MUX_TIMEOUT_SECONDS" tmux send-keys -t "$target" "$text" || return 1
      sleep "$AUTOCODER_MUX_SUBMIT_DELAY"
      if consent_dialog_showing tmux "$target"; then
        _agent_prompt_withheld "$target" "$text"
        return 3
      fi
      run_with_timeout "$AUTOCODER_MUX_TIMEOUT_SECONDS" tmux send-keys -t "$target" Enter || return 1
      ;;
    cmux)
      run_with_timeout "$AUTOCODER_MUX_TIMEOUT_SECONDS" cmux send --workspace "$target" "$text" >/dev/null || return 1
      sleep "$AUTOCODER_MUX_SUBMIT_DELAY"
      if consent_dialog_showing cmux "$target"; then
        _agent_prompt_withheld "$target" "$text"
        return 3
      fi
      run_with_timeout "$AUTOCODER_MUX_TIMEOUT_SECONDS" cmux send-key --workspace "$target" enter >/dev/null || return 1
      ;;
    herdr)
      # `herdr agent prompt` writes text and Enter as one; the check above is
      # the last chance to hold it back. Its typed fallback is checked again,
      # since time has passed while the agent surface was tried.
      if ! prompt_herdr_agent "$target" "$text"; then
        if consent_dialog_showing herdr "$target"; then
          _agent_prompt_withheld "$target" "$text"
          return 3
        fi
        send_herdr_command "$target" "$text" || return 1
      fi
      ;;
    *)
      echo "send_agent_prompt: unknown multiplexer '$mux'" >&2
      return 1
      ;;
  esac
  return 0
}

_agent_prompt_withheld() {
  echo "⚠️  $1 is showing a consent or trust dialog; not answering it. Answer it in that pane, then send: $2" >&2
}
