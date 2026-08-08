#!/bin/bash
# worker-launch-lib.sh — shared worker launch configuration.
#
# Sourced by launcher/lifecycle scripts so per-agent launch and loop commands
# live in exactly ONE place. Do not duplicate the Codex /goal string or the
# fix-loop wiring; change it here and callers stay in sync.
#
# Usage:
#   source "$(dirname "$0")/worker-launch-lib.sh"
#   resolve_worker_launch "$AGENT" "$AGENTS_REPO_ROOT"
#   # -> sets globals AGENT_LAUNCH_CMD and WORKER_CMD
#
# AGENT_LAUNCH_CMD: command that starts the agent REPL (may be empty for droid).
# WORKER_CMD:       command sent to the agent to begin the continuous fix loop.
# WORKER_LAUNCH_MODE:  interactive|shell
# WORKER_COMMAND_MODE: agent-input|shell
# MANAGER_LAUNCH_CMD:  command that starts the manager agent REPL, or empty.
# MANAGER_CMD:         command that starts manager monitoring.
# MANAGER_LAUNCH_MODE: interactive|shell

# Directory this lib was sourced from. Scripts that ship alongside it (e.g.
# claude-worker-loop.sh) MUST be resolved from here, not from repo_root: callers
# derive repo_root as SCRIPT_DIR/../../.., which is only correct for a repo
# checkout. Installed plugins live at cache/plugin-marketplace/autocoder/<ver>/scripts,
# where that walk lands on the cache root and produces a path real in neither
# layout — killing the worker but never relaunching it (issue #94).
WORKER_LAUNCH_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

resolve_worker_launch() {
  local agent="$1"
  local repo_root="$2"

  AGENT_LAUNCH_CMD=""
  WORKER_CMD=""
  WORKER_LAUNCH_MODE="shell"
  WORKER_COMMAND_MODE="shell"
  MANAGER_LAUNCH_CMD=""
  MANAGER_CMD=""
  MANAGER_LAUNCH_MODE="shell"

  case "$agent" in
    claude)
      # Workers: shell loop that restarts Claude per issue (fresh context per fix).
      # Each worker is visible as its own tmux pane running claude-worker-loop.sh.
      # Manager: interactive Claude session using the smarter opus model for coordination.
      WORKER_MODEL="${WORKER_MODEL:-claude-sonnet-5}"
      MANAGER_MODEL="${MANAGER_MODEL:-claude-opus-5}"
      AGENT_LAUNCH_CMD=""
      local worker_loop="$WORKER_LAUNCH_LIB_DIR/claude-worker-loop.sh"
      if [ ! -f "$worker_loop" ]; then
        echo "❌ claude-worker-loop.sh not found next to worker-launch-lib.sh ($worker_loop)" >&2
        return 1
      fi
      WORKER_CMD="bash '$worker_loop'"
      WORKER_LAUNCH_MODE="shell"
      WORKER_COMMAND_MODE="shell"
      MANAGER_LAUNCH_CMD="claude --dangerously-skip-permissions --model $MANAGER_MODEL"
      MANAGER_CMD="/autocoder:monitor-loop"
      MANAGER_LAUNCH_MODE="interactive"
      ;;
    gemini)
      # Workers: interactive Gemini session running /fix-loop (matches .agent/workflows/).
      # Manager: interactive Gemini session for coordination (monitor-loop).
      AGENT_LAUNCH_CMD="gemini --sandbox=false"
      WORKER_CMD="/fix-loop"
      WORKER_LAUNCH_MODE="interactive"
      WORKER_COMMAND_MODE="agent-input"
      MANAGER_LAUNCH_CMD="gemini --sandbox=false"
      MANAGER_CMD="/monitor-loop"
      MANAGER_LAUNCH_MODE="interactive"
      ;;
    codex)
      local probe_script="$repo_root/scripts/probe-codex-goals.sh"
      if [ -f "$probe_script" ] && bash "$probe_script" 2>/dev/null; then
        AGENT_LAUNCH_CMD="codex"
        WORKER_CMD="/goal Work the issue queue repeatedly. For each issue N, before editing files, run: bash '$repo_root/plugins/autocoder/scripts/start-issue-work.sh' N. This helper is mandatory because it claims the issue, switches to feature/issue-N, and posts the Implementation Started marker peers use to validate the lock. If it fails, do not work that issue; choose another claimable issue. Then fix the issue, test, commit, push the current HEAD, close or PR according to repo rules, remove the working label only when the issue is handed off or complete, and repeat until the queue is empty or you are paused."
        WORKER_LAUNCH_MODE="interactive"
        WORKER_COMMAND_MODE="agent-input"
        MANAGER_LAUNCH_CMD="$AGENT_LAUNCH_CMD"
        MANAGER_CMD="/goal Monitor and coordinate workers: check worker status, unblock stuck agents, merge completed PRs, triage new issues, and repeat indefinitely."
        MANAGER_LAUNCH_MODE="interactive"
      else
        WORKER_CMD="bash '$repo_root/scripts/codex-fix-loop.sh'"
        WORKER_LAUNCH_MODE="shell"
        WORKER_COMMAND_MODE="shell"
        MANAGER_CMD="bash '$repo_root/scripts/codex-manage-workers-loop.sh'"
        MANAGER_LAUNCH_MODE="shell"
      fi
      ;;
    droid)
      AGENT_LAUNCH_CMD=""
      WORKER_CMD="bash '$repo_root/scripts/droid-fix-loop.sh'"
      WORKER_LAUNCH_MODE="shell"
      WORKER_COMMAND_MODE="shell"
      MANAGER_LAUNCH_CMD=""
      MANAGER_CMD="bash '$repo_root/scripts/droid-manage-workers-loop.sh'"
      MANAGER_LAUNCH_MODE="shell"
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
