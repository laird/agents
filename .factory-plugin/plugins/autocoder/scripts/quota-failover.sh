#!/bin/bash
# quota-failover.sh — switch a swarm off an agent that has hit its usage limit.
#
# The manager model cannot do this for itself: when its own pane is blocked on
# the limit dialog, the monitor loop never runs. This script is the shell
# watchdog. The idle sentinel calls it every tick, and --ensure installs a
# cron entry so the switch still happens when the sentinel is not scheduled.
#
# It reads pane text (herdr pane read, tmux capture-pane, cmux read-screen).
# herdr's agent_status=blocked only catches the Claude dialog, not the
# "Usage limit reached" banner, so the text is the signal. GitHub API and
# GraphQL rate-limit lines are ignored.
#
# Preference (first usable wins): claude, codex, grok, gemini, droid, pi.
# AUTOCODER_AGENT_PREFERENCE (comma-separated) overrides .autocoder.json
# agentPreference, which overrides that default. An agent is skipped when it
# is not installed, fails a cheap auth probe, or is recorded exhausted until
# the reset time parsed from the pane (or 6h when the pane shows no time).
# After that time, an idle pane moves back to the preferred agent. A swarm
# that was started on another agent on purpose is left there until a recorded
# exhaustion actually expires.
#
# The switch is restart-worker.sh for a worker: same worktree, same branch,
# same working claim. The worktree's commits and uncommitted files stay. The
# new agent is sent /fix N (or
# /fix-loop) — /autocoder:… on Claude. The manager is restarted once per repo
# (tick lock + a hold file the sentinel honors) and sent
# /manager-resume --non-interactive, then /monitor-loop.
#
# Folder trust is only the existing grok --trust flag. Tool-permission
# prompts are not answered, and the limit dialog's "Add funds" choice is never
# selected. A consent dialog still showing is left for a person.
#
# Usage:
#   quota-failover.sh --once [--repo DIR] [--quiet]
#   quota-failover.sh --loop [--interval SEC] [--repo DIR]
#   quota-failover.sh --dry-run [--repo DIR]
#   quota-failover.sh --ensure [--repo DIR]
#
# Environment:
#   AUTOCODER_AGENT_PREFERENCE          comma-separated agent order
#   AUTOCODER_QUOTA_UNKNOWN_COOLDOWN_S  until-epoch when no reset time parses (21600)
#   QUOTA_SWITCH_COOLDOWN               seconds before the same pane switches again (120)
#   QUOTA_FAILOVER_STATE_DIR            state directory (default under XDG_STATE_HOME)
#   QUOTA_STATE_FILE                    exact state file (tests)
#   QUOTA_NOW_EPOCH                     clock override (tests)
#   QUOTA_FAILOVER_RESTART              restart-worker.sh path (tests)
#   AUTOCODER_QUOTA_AUTH_<AGENT>        bash -c auth probe override (tests)
#
# Exit: 0 after a tick (switches or not); 1 on bad usage or a missing repo.

set -u

SOURCE_PATH="${BASH_SOURCE[0]}"
while [ -L "$SOURCE_PATH" ]; do
  SOURCE_DIR="$(cd "$(dirname "$SOURCE_PATH")" && pwd)"
  SOURCE_PATH="$(readlink "$SOURCE_PATH")"
  [[ "$SOURCE_PATH" != /* ]] && SOURCE_PATH="$SOURCE_DIR/$SOURCE_PATH"
done
SCRIPT_DIR="$(cd "$(dirname "$SOURCE_PATH")" && pwd)"
SELF_PATH="$SCRIPT_DIR/$(basename "$SOURCE_PATH")"
AGENTS_REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." 2>/dev/null && pwd)" || AGENTS_REPO_ROOT="$SCRIPT_DIR"

# shellcheck source=repo-id-fns.sh
source "$SCRIPT_DIR/repo-id-fns.sh"
# shellcheck source=quota-failover-lib.sh
source "$SCRIPT_DIR/quota-failover-lib.sh"
# shellcheck source=mux-send-lib.sh
source "$SCRIPT_DIR/mux-send-lib.sh"
# shellcheck source=worker-launch-lib.sh
source "$SCRIPT_DIR/worker-launch-lib.sh"
# shellcheck source=swarm-manifest-lib.sh
source "$SCRIPT_DIR/swarm-manifest-lib.sh"

MODE=""
QUIET=false
INTERVAL=120
QUOTA_REPO=""
RESTART="${QUOTA_FAILOVER_RESTART:-$SCRIPT_DIR/restart-worker.sh}"
DRY=false

usage() { sed -n '2,/^set -u$/p' "$SELF_PATH" | sed '$d' | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --once|--loop|--dry-run|--ensure) MODE="${1#--}"; shift ;;
    --quiet) QUIET=true; shift ;;
    --interval) INTERVAL="${2:-}"; shift 2 ;;
    --repo) QUOTA_REPO="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "quota-failover: unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done
[ -n "$MODE" ] || { usage >&2; exit 1; }

if [ -z "$QUOTA_REPO" ]; then
  QUOTA_REPO=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
fi
QUOTA_REPO=$(cd "$QUOTA_REPO" 2>/dev/null && pwd) || {
  echo "quota-failover: repo not found: $QUOTA_REPO" >&2
  exit 1
}
export QUOTA_REPO
[ "$MODE" = "dry-run" ] && DRY=true

quota_log() {
  local line="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
  printf '%s\n' "$line"
  if [ "$DRY" != true ]; then
    mkdir -p "$QUOTA_REPO/.autocoder" 2>/dev/null || true
    printf '%s\n' "$line" >> "$QUOTA_REPO/.autocoder/quota-failover.log" 2>/dev/null || true
  fi
}

quota_notify() {
  local title="$1" body="$2"
  if [ "$DRY" = true ]; then
    quota_log "DRY-RUN would notify: $title — $body"
    return 0
  fi
  quota_log "NOTIFY $title — $body"
  command -v herdr >/dev/null 2>&1 || return 0
  run_with_timeout "$AUTOCODER_MUX_TIMEOUT_SECONDS" herdr notification show "$title" \
    --body "$body" --sound request >/dev/null 2>&1 || true
}

quota_comment_issue() {
  local number="$1" body="$2"
  [ -n "$number" ] || return 0
  if [ "$DRY" = true ]; then
    quota_log "DRY-RUN would comment issue=$number $body"
    return 0
  fi
  quota_log "COMMENT issue=$number $body"
  [ "${QUOTA_FAILOVER_COMMENT:-1}" = "0" ] && return 0
  [ -f "$QUOTA_REPO/.autocoder.json" ] || return 0
  (
    cd "$QUOTA_REPO" || exit 0
    # shellcheck source=issue-fns.sh
    source "$SCRIPT_DIR/issue-fns.sh"
    issue_comment "$number" --body "$body"
  ) || true
}

load_herdr_map() {
  HERDR_MAP=""
  command -v herdr >/dev/null 2>&1 || return 0
  local json
  json=$(run_with_timeout "$AUTOCODER_MUX_TIMEOUT_SECONDS" herdr agent list 2>/dev/null) || return 0
  HERDR_MAP=$(printf '%s' "$json" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for agent in (data.get("result") or {}).get("agents") or []:
    pane = agent.get("pane_id") or ""
    kind = (agent.get("agent") or agent.get("kind") or "").strip().lower()
    status = (agent.get("agent_status") or agent.get("status") or "").strip().lower()
    if pane:
        print("%s\t%s\t%s" % (pane, kind, status))
')
}

herdr_field() {
  printf '%s\n' "$HERDR_MAP" | awk -F '\t' -v p="$1" -v c="$2" '$1 == p { print $c; exit }'
}

list_targets() {
  python3 - "$QUOTA_REPO" <<'PY'
import glob, json, os, sys
root = sys.argv[1]
pattern = os.path.join(root, ".autocoder", "swarm", "*.json")
for path in sorted(glob.glob(pattern)):
    try:
        data = json.load(open(path, encoding="utf-8"))
    except Exception:
        continue
    mux = data.get("mux") or ""
    swarm_agent = (data.get("agent") or "").strip().lower()
    session = data.get("session") or os.path.splitext(os.path.basename(path))[0]
    project = data.get("projectRoot") or root
    name = data.get("projectName") or os.path.basename(str(project).rstrip("/")) or "repo"
    def target(obj):
        if mux == "herdr":
            return obj.get("herdrPane") or ""
        if mux == "tmux":
            return obj.get("tmuxTarget") or ""
        if mux == "cmux":
            return obj.get("cmuxWorkspace") or ""
        return ""
    mgr = data.get("manager") or {}
    mt = target(mgr) or ""
    if mt:
        # A pane may name its own agent. Panes in one swarm can differ.
        magent = (mgr.get("agent") or swarm_agent).strip().lower()
        print("\t".join(["manager", mux, str(mt), str(project), magent, "running", path, session, str(name)]))
    for worker in data.get("workers") or []:
        wt = worker.get("worktree") or ""
        state = (worker.get("state") or "").lower()
        tg = target(worker) or ""
        if not wt or not tg:
            continue
        wagent = (worker.get("agent") or swarm_agent).strip().lower()
        print("\t".join(["worker", mux, str(tg), str(wt), wagent, state, path, session, str(name)]))
PY
}

capture_pane() {
  capture_target "$1" "$2" 2>/dev/null || true
}

note_exhaustion() {
  local agent="$1" text="$2" parsed until reset_text
  if [ "$DRY" = true ]; then
    parsed=$(printf '%s' "$text" | quota_parse_reset || true)
    if [ -n "$parsed" ]; then
      until=${parsed%%$'\t'*}
      reset_text=${parsed#*$'\t'}
    else
      until=$(( $(quota_now) + ${AUTOCODER_QUOTA_UNKNOWN_COOLDOWN_S:-21600} ))
      reset_text=""
    fi
  else
    until=$(quota_record_exhaustion "$agent" "$text")
    reset_text=$(quota_state_get reset_text "$agent")
  fi
  QUOTA_SEEN_EXHAUSTED="${QUOTA_SEEN_EXHAUSTED:-} $agent"
  quota_log "RECORD $agent until=$until reset='${reset_text}'"
  LAST_UNTIL="$until"
  LAST_RESET="$reset_text"
}

# Resume text after resolve_worker_launch. Claude, Grok, and Gemini take the
# slash command for that issue. Codex with /goal resumes through the goal
# resolve_worker_launch built (it re-claims and lands through the merge gate).
worker_resume_prompt() {
  local agent="$1" issue="$2"
  case "$agent" in
    claude|grok|gemini) quota_worker_prompt "$agent" "$issue" ;;
    *) printf '%s' "$WORKER_CMD" ;;
  esac
}

# Manager resume after resolve_worker_launch. Claude and Grok (and Gemini)
# run manager-resume, then the monitor loop. Codex runs the /goal the launch
# lib built. Shell-loop managers are not handled here.
manager_resume_lines() {
  local agent="$1"
  case "$agent" in
    claude|grok|gemini) quota_manager_prompt_lines "$agent" ;;
    *) printf '%s\n' "$MANAGER_CMD" ;;
  esac
}

plan_worker_switch() {
  local wt="$1" mux="$2" agent="$3" issue="$4" prompt=""
  if resolve_worker_launch "$agent" "$AGENTS_REPO_ROOT" "$mux" >/dev/null; then
    if [ "$WORKER_COMMAND_MODE" = "agent-input" ]; then
      prompt=$(worker_resume_prompt "$agent" "$issue")
    fi
    [ -n "$AGENT_LAUNCH_CMD" ] && quota_log "LAUNCH $AGENT_LAUNCH_CMD"
  fi
  if [ -n "$prompt" ]; then
    quota_log "CMD $RESTART --worktree $wt --mux $mux --agent $agent --prompt '$prompt'"
  else
    quota_log "CMD $RESTART --worktree $wt --mux $mux --agent $agent"
    quota_log "RESUME shell-loop keeps the working claim"
  fi
  [ "$DRY" = true ] && return 0
  if [ -n "$prompt" ]; then
    "$RESTART" --worktree "$wt" --mux "$mux" --agent "$agent" --prompt "$prompt"
  else
    "$RESTART" --worktree "$wt" --mux "$mux" --agent "$agent"
  fi
}

update_manager_manifest() {
  local manifest="$1" mux="$2" pane="$3" session="$4"
  local mgr now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  mgr=$(python3 - "$manifest" "$mux" "$pane" "$session" "$now" <<'PY'
import json, sys
path, mux, pane, session, now = sys.argv[1:]
with open(path, encoding="utf-8") as fh:
    data = json.load(fh)
manager = data.get("manager") or {}
key = {"tmux": "tmuxTarget", "cmux": "cmuxWorkspace", "herdr": "herdrPane"}[mux]
manager[key] = pane
manager["pid"] = None
manager["pid_start_time"] = None
manager["agentLaunched"] = True
manager["spawned_at"] = now
manager["marker"] = "AUTOCODER_MANAGER=%s" % session
print(json.dumps(manager))
PY
) || return 1
  manifest_set_manager "$manifest" "$mgr"
}

# Replace the manager pane with `agent`. Caller has already resolved launch
# globals. Never creates a second manager if closing the old one failed.
launch_manager_pane() {
  local mux="$1" old_target="$2" root="$3" name="$4" session="$5" manifest="$6"
  local new="$old_target" hold="$root/.autocoder/quota-manager-hold"
  mkdir -p "$root/.autocoder"
  date +%s > "$hold"
  case "$mux" in
    herdr)
      run_with_timeout "$AUTOCODER_MUX_TIMEOUT_SECONDS" herdr workspace close "${old_target%%:*}" >/dev/null 2>&1 || {
        quota_log "FAIL manager: could not close herdr workspace ${old_target%%:*}"
        rm -f "$hold"
        return 1
      }
      sleep "${AUTOCODER_QUOTA_LAUNCH_SETTLE:-1}"
      new=$(run_with_timeout "$AUTOCODER_MUX_TIMEOUT_SECONDS" herdr workspace create --cwd "$root" \
        --label "manager-$name" --no-focus | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["root_pane"]["pane_id"])' 2>/dev/null) || new=""
      [ -n "$new" ] || { quota_log "FAIL manager: herdr workspace create returned no pane"; rm -f "$hold"; return 1; }
      send_herdr_command "$new" "export AUTOCODER_MANAGER=$(printf '%q' "$session") AUTOCODER_UNATTENDED=1" || true
      if [ -n "$MANAGER_LAUNCH_CMD" ]; then
        launch_herdr_agent "$(herdr_agent_name "manager-$name")" "$SWITCH_AGENT" "$new" "$MANAGER_LAUNCH_CMD" || true
      fi
      ;;
    tmux)
      run_with_timeout "$AUTOCODER_MUX_TIMEOUT_SECONDS" tmux respawn-pane -k -t "$old_target" || {
        quota_log "FAIL manager: tmux respawn failed"
        rm -f "$hold"
        return 1
      }
      sleep "${AUTOCODER_QUOTA_LAUNCH_SETTLE:-1}"
      send_tmux_command "$new" "cd $(printf '%q' "$root")" || true
      send_tmux_command "$new" "export AUTOCODER_MANAGER=$(printf '%q' "$session") AUTOCODER_UNATTENDED=1" || true
      if [ -n "$MANAGER_LAUNCH_CMD" ]; then
        send_tmux_command "$new" "$MANAGER_LAUNCH_CMD" || true
        sleep "${AUTOCODER_QUOTA_LAUNCH_SETTLE:-5}"
      fi
      ;;
    cmux)
      run_with_timeout "$AUTOCODER_MUX_TIMEOUT_SECONDS" cmux close-workspace --workspace "$old_target" >/dev/null 2>&1 || true
      local out
      out=$(run_with_timeout "$AUTOCODER_MUX_TIMEOUT_SECONDS" cmux new-workspace --cwd "$root") || out=""
      new=$(printf '%s\n' "$out" | grep -o 'workspace:[0-9]*' | head -1)
      [ -n "$new" ] || { quota_log "FAIL manager: cmux new-workspace returned no ref"; rm -f "$hold"; return 1; }
      run_with_timeout "$AUTOCODER_MUX_TIMEOUT_SECONDS" cmux rename-workspace --workspace "$new" "manager-$name" >/dev/null 2>&1 || true
      send_cmux_command "$new" "export AUTOCODER_MANAGER=$(printf '%q' "$session") AUTOCODER_UNATTENDED=1" || true
      if [ -n "$MANAGER_LAUNCH_CMD" ]; then
        send_cmux_command "$new" "$MANAGER_LAUNCH_CMD" || true
        sleep "${AUTOCODER_QUOTA_LAUNCH_SETTLE:-5}"
      fi
      ;;
    *)
      quota_log "FAIL manager: unknown mux $mux"
      rm -f "$hold"
      return 1
      ;;
  esac
  if [ "$MANAGER_COMMAND_MODE" = "shell" ]; then
    case "$mux" in
      herdr) send_herdr_command "$new" "$MANAGER_CMD" || true ;;
      tmux) send_tmux_command "$new" "$MANAGER_CMD" || true ;;
      cmux) send_cmux_command "$new" "$MANAGER_CMD" || true ;;
    esac
  else
    local line rc=0
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      send_agent_prompt "$mux" "$new" "$line" || rc=$?
      if [ "$rc" -eq 3 ]; then
        quota_log "WITHHELD manager prompt (consent dialog left for a person): $line"
        break
      fi
      rc=0
    done < <(manager_resume_lines "$SWITCH_AGENT")
  fi
  update_manager_manifest "$manifest" "$mux" "$new" "$session" || true
  mkdir -p "$root/.autocoder"
  : >> "$root/.autocoder/manager-heartbeat" || true
  printf '%s\n' "$new"
}

switch_manager() {
  local from="$1" to="$2" mux="$3" old="$4" root="$5" session="$6" manifest="$7" name="$8"
  SWITCH_AGENT="$to"
  if ! resolve_worker_launch "$to" "$AGENTS_REPO_ROOT" "$mux" >/dev/null; then
    quota_log "FAIL manager: could not resolve launch for $to"
    return 1
  fi
  quota_log "SWITCH manager from=$from to=$to mux=$mux"
  if [ "$MANAGER_COMMAND_MODE" = "shell" ]; then
    quota_log "SHELL $MANAGER_CMD"
  else
    [ -n "$MANAGER_LAUNCH_CMD" ] && quota_log "LAUNCH $MANAGER_LAUNCH_CMD"
    local line
    while IFS= read -r line; do
      [ -n "$line" ] && quota_log "PROMPT $line"
    done < <(manager_resume_lines "$to")
  fi
  [ "$DRY" = true ] && return 0
  launch_manager_pane "$mux" "$old" "$root" "$name" "$session" "$manifest" >/dev/null || return 1
  quota_state_set current manager "$to"
  quota_state_set switched manager "$(quota_now)"
  quota_notify "Quota failover: $from → $to" \
    "Manager usage limit reached. Restarted the one manager on $to. Branch and uncommitted files were left in place."
}

switch_worker() {
  local from="$1" to="$2" mux="$3" wt="$4" issue="$5" reset_text="$6"
  quota_log "SWITCH worker worktree=$wt from=$from to=$to mux=$mux issue=${issue:-none}"
  plan_worker_switch "$wt" "$mux" "$to" "$issue" || return 1
  [ "$DRY" = true ] && return 0
  quota_state_set current "$wt" "$to"
  quota_state_set switched "$wt" "$(quota_now)"
  local body
  body="Quota failover: $from hit its usage limit${reset_text:+ ($reset_text)}. Switched this worktree to $to and left the branch, uncommitted changes, and the working claim in place."
  quota_comment_issue "$issue" "$body"
  quota_notify "Quota failover: $from → $to" "$body"
}

tick() {
  local lock dir acted=0
  dir=$(dirname "$(quota_state_path)")
  mkdir -p "$dir"
  lock="$dir/tick.lock"
  exec 9>>"$lock"
  if ! flock -n 9; then
    [ "$QUIET" = true ] || quota_log "SKIP tick lock held"
    return 0
  fi
  QUOTA_SEEN_EXHAUSTED=""
  load_herdr_map
  local row role mux target place base state manifest session name kind key status text best issue
  while IFS=$'\t' read -r role mux target place base state manifest session name; do
    [ -n "${role:-}" ] || continue
    if [ "$role" = "worker" ] && [ "$state" = "paused" ]; then
      continue
    fi
    if [ "$role" = "manager" ]; then
      key="manager"
    else
      key="$place"
    fi
    kind=""
    status=""
    if [ "$mux" = "herdr" ]; then
      kind=$(herdr_field "$target" 2)
      status=$(herdr_field "$target" 3)
    fi
    [ -n "$kind" ] || kind=$(quota_state_get current "$key")
    [ -n "$kind" ] || kind="$base"
    quota_known_agent "$kind" || continue
    text=$(capture_pane "$mux" "$target")
    [ -n "$text" ] || continue
    LAST_RESET=""
    if printf '%s\n' "$text" | quota_pane_exhausted "$kind"; then
      note_exhaustion "$kind" "$text"
      if quota_in_cooldown "$key"; then
        quota_log "SKIP $role $key — switched within the last ${QUOTA_SWITCH_COOLDOWN:-120}s"
        continue
      fi
      if ! best=$(quota_best_usable); then
        if ! quota_in_cooldown "nocandidate-$key"; then
          quota_log "NO-CANDIDATE $role $key from=$kind (no other installed, authenticated agent)"
          [ "$DRY" = true ] || quota_state_set switched "nocandidate-$key" "$(quota_now)"
          quota_notify "Quota failover: no agent left" \
            "$kind is out of usage and no other installed, authenticated agent is available."
        fi
        continue
      fi
      acted=1
      if [ "$role" = "manager" ]; then
        switch_manager "$kind" "$best" "$mux" "$target" "$place" "$session" "$manifest" "$name" || true
      else
        issue=$(quota_issue_of_worktree "$place")
        switch_worker "$kind" "$best" "$mux" "$place" "$issue" "$LAST_RESET" || true
      fi
    elif quota_status_idle "$status"; then
      best=$(quota_best_usable || true)
      if quota_should_failback "$kind" "$best"; then
        if quota_in_cooldown "$key"; then
          quota_log "SKIP failback $role $key — switched within the last ${QUOTA_SWITCH_COOLDOWN:-120}s"
          continue
        fi
        acted=1
        quota_log "FAILBACK $role $key from=$kind to=$best (preferred agent reset elapsed)"
        if [ "$role" = "manager" ]; then
          switch_manager "$kind" "$best" "$mux" "$target" "$place" "$session" "$manifest" "$name" || true
        else
          issue=$(quota_issue_of_worktree "$place")
          switch_worker "$kind" "$best" "$mux" "$place" "$issue" "" || true
        fi
      fi
    fi
  done < <(list_targets)
  if [ "$acted" -eq 0 ] && [ "$QUIET" != true ]; then
    quota_log "OK no agent quota exhaustion"
  fi
  return 0
}

ensure_cron() {
  command -v crontab >/dev/null 2>&1 || {
    echo "quota-failover: crontab not available; run --loop instead" >&2
    return 1
  }
  local mark line dir
  mark="# autocoder-quota-failover:$QUOTA_REPO"
  if crontab -l 2>/dev/null | grep -qF "$mark"; then
    echo "✓ cron entry already installed"
    return 0
  fi
  dir=$(dirname "$(quota_state_path)")
  mkdir -p "$dir"
  line="*/2 * * * * PATH='$PATH' '$SELF_PATH' --once --repo $(printf '%q' "$QUOTA_REPO") >> $(printf '%q' "$dir/watchdog.log") 2>&1 $mark"
  ( crontab -l 2>/dev/null; echo "$line" ) | crontab - || {
    echo "quota-failover: crontab install failed" >&2
    return 1
  }
  echo "✓ installed cron entry (every 2 minutes); log: $dir/watchdog.log"
}

case "$MODE" in
  ensure) ensure_cron ;;
  dry-run|once) tick ;;
  loop)
    while true; do
      tick || true
      sleep "$INTERVAL"
    done
    ;;
esac
