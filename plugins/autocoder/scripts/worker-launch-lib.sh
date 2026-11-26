#!/bin/bash
# worker-launch-lib.sh — shared worker launch configuration.
#
# Sourced by launcher/lifecycle scripts so per-agent launch and loop commands
# live in exactly ONE place. Do not duplicate the Codex /goal string or the
# fix-loop wiring; change it here and callers stay in sync.
#
# Usage:
#   source "$(dirname "$0")/worker-launch-lib.sh"
#   resolve_worker_launch "$AGENT" "$AGENTS_REPO_ROOT" ["$MUX"]
#   # -> sets globals AGENT_LAUNCH_CMD and WORKER_CMD
#
# The optional third argument is the multiplexer in use. herdr is the only
# value that changes the result: its UI lists a pane as a named, interactive
# agent only when a real agent TUI occupies it, so claude workers switch from
# the headless `claude -p` shell loop to an interactive session there.
#
# AGENT_LAUNCH_CMD: command that starts the agent REPL (may be empty for droid).
# WORKER_CMD:       command sent to the agent to begin the continuous fix loop.
# WORKER_LAUNCH_MODE:  interactive|shell
# WORKER_COMMAND_MODE: agent-input|shell
# MANAGER_LAUNCH_CMD:  command that starts the manager agent REPL, or empty.
# MANAGER_CMD:         command that starts manager monitoring.
# MANAGER_LAUNCH_MODE: interactive|shell
# MANAGER_COMMAND_MODE: argv|agent-input|shell -- how MANAGER_CMD reaches the
#                      manager. `argv` appends it to MANAGER_LAUNCH_CMD instead of
#                      typing it into the TUI after launch; see start-parallel-agents.sh.

# Directory this lib was sourced from. Scripts that ship alongside it (e.g.
# claude-worker-loop.sh) MUST be resolved from here, not from repo_root: callers
# derive repo_root as SCRIPT_DIR/../../.., which is only correct for a repo
# checkout. Installed plugins live at cache/plugin-marketplace/autocoder/<ver>/scripts,
# where that walk lands on the cache root and produces a path real in neither
# layout — killing the worker but never relaunching it (issue #94).
WORKER_LAUNCH_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve a packaged script, preferring the directory this lib ships in.
#
# The per-runtime loop drivers (codex-fix-loop.sh, droid-fix-loop.sh, ...) used
# to be addressed as "$repo_root/scripts/<name>" unconditionally. That is the
# repo layout, not the installed one: a plugin installs to
# cache/plugin-marketplace/autocoder/<ver>/scripts with no top-level scripts/
# beside it, so every Codex and Droid launch pointed at a file that was not
# there -- the same class of break as issue #94, which fixed only
# claude-worker-loop.sh. The repo path stays as a fallback so a checkout that
# has not been re-packaged still works.
_wll_script() {
  local name="$1" repo_root="$2"
  if [ -f "$WORKER_LAUNCH_LIB_DIR/$name" ]; then
    printf '%s/%s' "$WORKER_LAUNCH_LIB_DIR" "$name"
  else
    printf '%s/scripts/%s' "$repo_root" "$name"
  fi
}

# Install the ctx/mem/model/worktree/branch status line into the user's Claude
# settings, so every pane reports its own health and the manager can read
# context pressure straight off a capture-pane instead of guessing.
#
# Deliberately advisory: a missing jq or an unwritable settings file must not
# stop a swarm from launching. Resolved from WORKER_LAUNCH_LIB_DIR for the same
# reason claude-worker-loop.sh is (see the note above) -- the repo_root walk is
# wrong under an installed plugin.
ensure_statusline() {
  local installer="$WORKER_LAUNCH_LIB_DIR/install-statusline.sh"
  [ -f "$installer" ] || return 0
  bash "$installer" "$@" || true
}

# Worker identity marker (#216): the export line a launcher sends into a
# worker pane BEFORE the agent starts, so the worker process carries
# AUTOCODER_WORKER=<session>:<N> in its environment, the way the manager carries
# AUTOCODER_MANAGER=<session>. Tools (swarm-register.sh, the sentinel) can then
# recognise a worker by evidence instead of by pane name or cwd. A worker
# started by hand has no marker and registers itself instead.
#   worker_marker_export <session> <worker number>
worker_marker_export() {
  local session="$1" number="$2"
  if [ -z "$session" ] || ! [[ "$number" =~ ^[0-9]+$ ]]; then
    echo "worker_marker_export: need <session> <number>, got '$session' '$number'" >&2
    return 1
  fi
  printf 'export AUTOCODER_WORKER=%q\n' "$session:$number"
}

# claude_launch_argv <role>: set CLAUDE_LAUNCH_ARGV to the flags a claude launch
# gets (#283). A swarm pane must not sit on a tool-permission prompt, so the
# default mode is bypassPermissions (Claude's skip-permissions mode). That is
# --permission-mode, not --dangerously-skip-permissions: the latter opens a
# consent dialog whose default is "No, exit", and an unattended pane stalls
# there. Set AUTOCODER_CLAUDE_PERMISSION_MODE to another mode name to override,
# or to empty to pass no permission flag.
#   AUTOCODER_CLAUDE_PERMISSION_MODE  e.g. auto | acceptEdits | bypassPermissions
#   AUTOCODER_WORKER_MODEL / WORKER_MODEL    worker --model (none by default)
#   AUTOCODER_MANAGER_MODEL / MANAGER_MODEL  manager --model (none by default)
# A headless worker (`claude -p`) cannot answer a permission prompt. The same
# default mode is exported into its pane, so its tools are not left at a prompt.
# Values must be plain words (letters, digits, . _ - and [ ] for e.g. opus[1m]);
# anything else is refused with a warning.
claude_launch_argv() {
  local role="$1" model mode
  CLAUDE_LAUNCH_ARGV=()
  case "$role" in
    manager) model="${AUTOCODER_MANAGER_MODEL:-${MANAGER_MODEL:-}}" ;;
    *)       model="${AUTOCODER_WORKER_MODEL:-${WORKER_MODEL:-}}" ;;
  esac
  # Unset means the swarm default. An empty value means "pass no mode".
  if [ -z "${AUTOCODER_CLAUDE_PERMISSION_MODE+x}" ]; then
    mode="bypassPermissions"
  else
    mode="${AUTOCODER_CLAUDE_PERMISSION_MODE}"
  fi
  if [ -n "$mode" ]; then
    case "$mode" in
      *[!A-Za-z]*) echo "worker-launch-lib: ignoring AUTOCODER_CLAUDE_PERMISSION_MODE='$mode' (expected a mode name such as auto)" >&2 ;;
      *) CLAUDE_LAUNCH_ARGV+=(--permission-mode "$mode") ;;
    esac
  fi
  if [ -n "$model" ]; then
    case "$model" in
      *[!A-Za-z0-9._\[\]-]*) echo "worker-launch-lib: ignoring model '$model' (unexpected characters)" >&2 ;;
      *) CLAUDE_LAUNCH_ARGV+=(--model "$model") ;;
    esac
  fi
}

# claude_launch_args <role>: the same flags as one string for a command typed into
# a pane's shell, each word %q-quoted (so opus[1m] is not a glob under zsh).
claude_launch_args() {
  local a out=""
  claude_launch_argv "$1"
  for a in ${CLAUDE_LAUNCH_ARGV[@]+"${CLAUDE_LAUNCH_ARGV[@]}"}; do
    out="${out:+$out }$(printf '%q' "$a")"
  done
  printf '%s' "$out"
}

# claude_env_exports: `export` lines carrying the launch configuration into a new
# pane, one per variable that is set. A tmux/cmux/herdr pane's shell does not
# inherit the caller's environment (an already-running tmux server keeps its own),
# so without these the worker loop there would never see the opt-in.
claude_env_exports() {
  local v
  for v in AUTOCODER_CLAUDE_PERMISSION_MODE AUTOCODER_WORKER_MODEL AUTOCODER_MANAGER_MODEL WORKER_MODEL MANAGER_MODEL; do
    [ -n "${!v:-}" ] && printf 'export %s=%q\n' "$v" "${!v}"
  done
  return 0
}

resolve_worker_launch() {
  local agent="$1"
  local repo_root="$2"
  local mux="${3:-}"

  AGENT_LAUNCH_CMD=""
  WORKER_CMD=""
  WORKER_LAUNCH_MODE="shell"
  WORKER_COMMAND_MODE="shell"
  MANAGER_LAUNCH_CMD=""
  MANAGER_CMD=""
  MANAGER_LAUNCH_MODE="shell"
  MANAGER_COMMAND_MODE="shell"

  case "$agent" in
    claude)
      # Workers: shell loop that restarts Claude per issue (fresh context per fix).
      # Each worker is visible as its own tmux pane running claude-worker-loop.sh.
      # Manager: interactive Claude session. Model and permission mode come from the
      # user's own settings unless configured (claude_launch_args, #283).
      local worker_args manager_args
      worker_args=$(claude_launch_args worker)
      manager_args=$(claude_launch_args manager)
      AGENT_LAUNCH_CMD=""
      local worker_loop="$WORKER_LAUNCH_LIB_DIR/claude-worker-loop.sh"
      if [ ! -f "$worker_loop" ]; then
        echo "❌ claude-worker-loop.sh not found next to worker-launch-lib.sh ($worker_loop)" >&2
        return 1
      fi
      WORKER_CMD="bash '$worker_loop'"
      WORKER_LAUNCH_MODE="shell"
      WORKER_COMMAND_MODE="shell"
      MANAGER_LAUNCH_CMD="claude${manager_args:+ $manager_args}"
      MANAGER_CMD="/autocoder:monitor-loop"
      MANAGER_LAUNCH_MODE="interactive"
      MANAGER_COMMAND_MODE="argv"
      if [ "$mux" = "herdr" ]; then
        # herdr's agent list only shows panes occupied by an interactive agent
        # it can detect; a `claude -p` shell loop is invisible there and cannot
        # be clicked on or interacted with. Under herdr, workers therefore run
        # an interactive claude driven by /autocoder:fix-loop (the same shape
        # the gemini path uses), and the manager takes its prompt through
        # `herdr agent prompt` instead of an argv-appended one.
        AGENT_LAUNCH_CMD="claude${worker_args:+ $worker_args}"
        WORKER_CMD="/autocoder:fix-loop"
        WORKER_LAUNCH_MODE="interactive"
        WORKER_COMMAND_MODE="agent-input"
        MANAGER_COMMAND_MODE="agent-input"
      fi
      ;;
    gemini)
      # Workers: interactive Gemini session running /fix-loop (matches .agent/workflows/).
      # Manager: interactive Gemini session for coordination (monitor-loop).
      # -y is Gemini's auto-approve (the same flag the headless wrapper passes),
      # so a swarm pane does not stop on a tool confirmation.
      AGENT_LAUNCH_CMD="gemini --sandbox=false -y"
      WORKER_CMD="/fix-loop"
      WORKER_LAUNCH_MODE="interactive"
      WORKER_COMMAND_MODE="agent-input"
      MANAGER_LAUNCH_CMD="gemini --sandbox=false -y"
      MANAGER_CMD="/monitor-loop"
      MANAGER_LAUNCH_MODE="interactive"
      MANAGER_COMMAND_MODE="agent-input"
      ;;
    codex)
      local probe_script="$(_wll_script probe-codex-goals.sh "$repo_root")"
      if [ -f "$probe_script" ] && bash "$probe_script" 2>/dev/null; then
        # Current codex rejects --full-auto ("unexpected argument"). Approval-never
        # is --ask-for-approval never, which is the same idea: do not stop for a
        # tool-approval prompt. The shell-loop fallback sets the same flag on
        # `codex exec` (CODEX_FLAGS_DEFAULT in codex-autocoder.sh).
        # workspace-write can write the worktree cwd but not a linked worktree's
        # git dir, so git commit cannot create index.lock. --add-dir makes the
        # common git dir writable (index, objects, and worktree metadata).
        AGENT_LAUNCH_CMD="codex --ask-for-approval never --add-dir /home/laird/src/agents/.git"
        WORKER_CMD="/goal Work the issue queue repeatedly. For each issue N, before editing files, run: bash '$repo_root/plugins/autocoder/scripts/start-issue-work.sh' N. This helper is mandatory because it claims the issue, switches to feature/issue-N, and posts the Implementation Started marker peers use to validate the lock. If it fails, do not work that issue; choose another claimable issue. Then fix the issue, run the repo tests, commit, and land with merge-to-integration.sh so the gate merges onto the integration branch. Do not open a pull request. Remove the working label only when the issue is handed off or complete, and repeat until the queue is empty or you are paused."
        WORKER_LAUNCH_MODE="interactive"
        WORKER_COMMAND_MODE="agent-input"
        MANAGER_LAUNCH_CMD="$AGENT_LAUNCH_CMD"
        MANAGER_CMD="/goal Monitor and coordinate workers: check worker status, unblock stuck agents, and confirm finished work has passed the test gate and merged to the integration branch. Do not open a pull request. Triage new issues, and repeat indefinitely."
        MANAGER_LAUNCH_MODE="interactive"
        MANAGER_COMMAND_MODE="agent-input"
      else
        WORKER_CMD="bash '$(_wll_script codex-fix-loop.sh "$repo_root")'"
        WORKER_LAUNCH_MODE="shell"
        WORKER_COMMAND_MODE="shell"
        MANAGER_CMD="bash '$(_wll_script codex-manage-workers-loop.sh "$repo_root")'"
        MANAGER_LAUNCH_MODE="shell"
      fi
      ;;
    pi)
      # Pi has no permission prompts and a first-class non-interactive mode, so
      # both roles run as shell loops: nothing is typed into a TUI, so there is
      # no readiness race and no consent dialog for a stray Enter to answer.
      WORKER_CMD="bash '$(_wll_script pi-fix-loop.sh "$repo_root")'"
      WORKER_LAUNCH_MODE="shell"
      WORKER_COMMAND_MODE="shell"
      MANAGER_CMD="bash '$(_wll_script pi-manage-workers-loop.sh "$repo_root")'"
      MANAGER_LAUNCH_MODE="shell"
      MANAGER_COMMAND_MODE="shell"
      ;;
    droid)
      AGENT_LAUNCH_CMD=""
      WORKER_CMD="bash '$(_wll_script droid-fix-loop.sh "$repo_root")'"
      WORKER_LAUNCH_MODE="shell"
      WORKER_COMMAND_MODE="shell"
      MANAGER_LAUNCH_CMD=""
      MANAGER_CMD="bash '$(_wll_script droid-manage-workers-loop.sh "$repo_root")'"
      MANAGER_LAUNCH_MODE="shell"
      ;;
    grok)
      # Interactive Grok TUI, same shape as Gemini: herdr registers it with
      # `herdr agent start --kind grok`, then the slash command is typed in.
      # `grok inspect` lists this plugin's commands as bare names (/fix,
      # /fix-loop, /monitor-loop, /manager-resume), not /autocoder:….
      #
      # Folder trust is `--trust` (docs.x.ai hooks: the decision is stored in
      # ~/.grok/trusted_folders.toml). Tool permissions are `--always-approve`,
      # so a swarm pane does not sit on an approval prompt. That is the flag,
      # not a keystroke into a dialog, and not `--yolo`. A usage-limit dialog
      # is never answered here; quota-failover.sh restarts the pane instead of
      # choosing "Add funds".
      AGENT_LAUNCH_CMD="grok --trust --always-approve"
      WORKER_CMD="/fix-loop"
      WORKER_LAUNCH_MODE="interactive"
      WORKER_COMMAND_MODE="agent-input"
      MANAGER_LAUNCH_CMD="grok --trust --always-approve"
      MANAGER_CMD="/monitor-loop"
      MANAGER_LAUNCH_MODE="interactive"
      MANAGER_COMMAND_MODE="agent-input"
      ;;
    *)
      echo "❌ Unknown agent: $agent" >&2
      return 1
      ;;
  esac
}

resolve_manager_readiness_mode() {
  MANAGER_READINESS_MODE="shell"
}
