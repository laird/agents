#!/bin/bash
# worker-launch-lib.sh — shared worker launch configuration.
#
# Sourced by add-worker.sh and restart-worker.sh so the per-agent launch
# command + worker command live in exactly ONE place. Do not duplicate the
# Codex /goal string or the fix-loop wiring; change it here and both callers
# stay in sync.
#
# Usage:
#   source "$(dirname "$0")/worker-launch-lib.sh"
#   resolve_worker_launch "$AGENT" "$AGENTS_REPO_ROOT"
#   # -> sets globals AGENT_LAUNCH_CMD and WORKER_CMD
#
# AGENT_LAUNCH_CMD: command that starts the agent REPL (may be empty for droid).
# WORKER_CMD:       command sent to the agent to begin the continuous fix loop.

resolve_worker_launch() {
  local agent="$1"
  local repo_root="$2"

  case "$agent" in
    claude)
      AGENT_LAUNCH_CMD="claude --dangerously-skip-permissions"
      WORKER_CMD="/autocoder:fix-loop"
      ;;
    gemini)
      AGENT_LAUNCH_CMD="gemini --sandbox=false"
      WORKER_CMD="/fix-loop"
      ;;
    codex)
      AGENT_LAUNCH_CMD="codex"
      local probe_script="$repo_root/scripts/probe-codex-goals.sh"
      if [ -f "$probe_script" ] && bash "$probe_script" 2>/dev/null; then
        WORKER_CMD="/goal Work the issue queue repeatedly. For each issue N, before editing files, run: bash '$repo_root/plugins/autocoder/scripts/start-issue-work.sh' N. This helper is mandatory because it claims the issue, switches to feature/issue-N, and posts the Implementation Started marker peers use to validate the lock. If it fails, do not work that issue; choose another claimable issue. Then fix the issue, test, commit, push the current HEAD, close or PR according to repo rules, remove the working label only when the issue is handed off or complete, and repeat until the queue is empty or you are paused."
      else
        WORKER_CMD="bash '$repo_root/scripts/codex-fix-loop.sh'"
      fi
      ;;
    droid)
      AGENT_LAUNCH_CMD=""
      WORKER_CMD="bash '$repo_root/scripts/droid-fix-loop.sh'"
      ;;
    *)
      echo "❌ Unknown agent: $agent" >&2
      return 1
      ;;
  esac
}
