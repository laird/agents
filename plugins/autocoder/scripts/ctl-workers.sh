#!/usr/bin/env bash
#
# ctl-workers.sh — autocoder-ctl's worker verbs: nudge, stop and restart (#244).
#
# Sourced by autocoder-ctl.sh, never run on its own. Each verb reports through
# ctl_ok / ctl_fail / ctl_usage; stdout belongs to the dispatcher.
#
# A worker is named by its worktree. The verb finds it in the swarm manifests
# (.autocoder/swarm/<session>.json in the main worktree), which say which
# multiplexer hosts it and which pane or workspace it runs in.
#
#   nudge <worktree> [text] [--session <name>]
#       Type <text> into the worker and submit it, with the submit that works for its
#       multiplexer (mux-send-lib.sh). The default text tells the worker to carry on
#       with its loop. Refuses a paused worker and a pane that has moved to another
#       directory.
#   stop <worktree> [--session <name>]
#       Kill the worker's agent, after checking that its pane's working directory is
#       that worktree. The worktree, branch, claim and manifest entry stay as they are,
#       so restart and remove-worker.sh work on it afterwards.
#   restart <worktree> [--session <name>]
#       restart-worker.sh for that worktree, with the manifest's mux and agent: the
#       agent is relaunched in the same worktree and resumes its issue.

_ctlw_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

AUTOCODER_CTL_NUDGE_TEXT="${AUTOCODER_CTL_NUDGE_TEXT:-Resume the autocoder fix loop: carry on with the issue you have claimed, or take the next claimable issue if you have none.}"

# Parse "<worktree> [extra] [--session <name>]". Sets _W_WORKTREE, _W_EXTRA, _W_SESSION.
# Returns 1 after reporting a usage error. <max_extra> is 0 or 1.
_ctlw_args() {  # <verb> <max_extra> <usage> -- args...
  local verb="$1" max_extra="$2" usage="$3"; shift 4
  _W_WORKTREE="" _W_EXTRA="" _W_HAS_EXTRA=false _W_SESSION=""
  local npos=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --session) [ $# -ge 2 ] || { ctl_usage "$verb: --session needs a value"; return 1; }
                 _W_SESSION="$2"; shift 2
                 case "$_W_SESSION" in */*|.*|"") ctl_usage "$verb: '$_W_SESSION' is not a session name"; return 1 ;; esac ;;
      --)        shift; break ;;
      -*)        ctl_usage "$verb: unknown option '$1'"; return 1 ;;
      *)         npos=$((npos + 1))
                 case "$npos" in
                   1) _W_WORKTREE="$1" ;;
                   2) [ "$max_extra" -ge 1 ] || { ctl_usage "$usage"; return 1; }; _W_EXTRA="$1" _W_HAS_EXTRA=true ;;
                   *) ctl_usage "$usage"; return 1 ;;
                 esac
                 shift ;;
    esac
  done
  # Anything after "--" is the text (nudge only), so text may start with a dash.
  if [ $# -gt 0 ]; then
    [ "$max_extra" -ge 1 ] && [ "$npos" -eq 1 ] && [ $# -eq 1 ] || { ctl_usage "$usage"; return 1; }
    _W_EXTRA="$1" _W_HAS_EXTRA=true; npos=2
  fi
  [ -n "$_W_WORKTREE" ] || { ctl_usage "$usage"; return 1; }
  return 0
}

# Find the worker whose manifest worktree is <worktree>. On success sets
# _W_ROOT, _W_MANIFEST, _W_SESSION, _W_NUMBER, _W_MUX, _W_AGENT, _W_PANE, _W_STATE,
# _W_COMMAND_MODE and _W_WORKTREE (normalised). On failure reports and returns 1.
_ctlw_find() {
  # shellcheck source=issue-source-lib.sh
  source "${_ctlw_DIR}/issue-source-lib.sh"
  # shellcheck source=swarm-manifest-lib.sh
  source "${_ctlw_DIR}/swarm-manifest-lib.sh"
  _W_ROOT="${AUTOCODER_CTL_PROJECT_ROOT:-$(resolve_main_worktree)}"

  local want="$_W_WORKTREE"
  [ -d "$want" ] || { ctl_fail "$want" "no such worktree: $want"; return 1; }
  want=$(cd "$want" && pwd -P)

  local manifests=() m
  if [ -n "$_W_SESSION" ]; then
    m=$(manifest_path_for_session "$_W_ROOT" "$_W_SESSION")
    [ -f "$m" ] || { ctl_fail "$want" "no swarm manifest for session '$_W_SESSION'"; return 1; }
    manifests=("$m")
  else
    shopt -s nullglob
    manifests=("$_W_ROOT/$SWARM_STATE_DIR"/*.json)
    shopt -u nullglob
  fi

  # One row per worker whose worktree resolves to the same directory: python does
  # the resolving, so a manifest that recorded the path through a symlink still matches.
  local rows
  rows=$(python3 - "$want" "${manifests[@]}" <<'PY'
import json, os, sys
want, paths = sys.argv[1], sys.argv[2:]
for path in paths:
    try:
        with open(path, encoding="utf-8") as f:
            m = json.load(f)
        workers = m.get("workers") or []
    except Exception:
        print(f"autocoder-ctl: skipping unreadable manifest {path}", file=sys.stderr)
        continue
    mux = m.get("mux") or ""
    for w in workers:
        if not isinstance(w, dict) or not w.get("worktree"):
            continue
        if os.path.realpath(w["worktree"]) != want:
            continue
        pane = {"tmux": w.get("tmuxTarget"), "cmux": w.get("cmuxWorkspace"),
                "herdr": w.get("herdrPane")}.get(mux) or ""
        print("\x1f".join([path, str(w.get("number", "")), mux, m.get("agent") or "",
                           pane, w.get("state") or "", w.get("commandMode") or ""]))
PY
)
  local count
  count=$(printf '%s' "$rows" | grep -c . || true)
  if [ "$count" -eq 0 ]; then
    ctl_fail "$want" "no swarm worker runs in $want${_W_SESSION:+ (session $_W_SESSION)}"; return 1
  fi
  if [ "$count" -gt 1 ]; then
    ctl_fail "$want" "$want is a worker in more than one swarm; pass --session"; return 1
  fi
  IFS=$'\x1f' read -r _W_MANIFEST _W_NUMBER _W_MUX _W_AGENT _W_PANE _W_STATE _W_COMMAND_MODE <<<"$rows"
  _W_SESSION=$(basename "$_W_MANIFEST" .json)
  _W_WORKTREE="$want"
  return 0
}

# The working directory of the worker's pane, as its multiplexer reports it.
# Prints the directory (or several candidates, one per line); returns 2 when the
# multiplexer cannot report one, 1 when the pane cannot be read.
_ctlw_pane_cwds() {
  case "$_W_MUX" in
    tmux)
      run_with_timeout "$AUTOCODER_MUX_TIMEOUT_SECONDS" \
        tmux display-message -p -t "$_W_PANE" '#{pane_current_path}' 2>/dev/null || return 1 ;;
    herdr)
      local out
      out=$(run_with_timeout "$AUTOCODER_MUX_TIMEOUT_SECONDS" herdr pane get "$_W_PANE" 2>/dev/null) || return 1
      # foreground_cwd is the agent's own directory; cwd is the pane's shell.
      printf '%s' "$out" | jq -r '.result.pane | (.foreground_cwd // empty), (.cwd // empty)' 2>/dev/null ;;
    *) return 2 ;;
  esac
}

# 0: the pane's directory is the worktree. 1: it is somewhere else, or the pane is
# gone (_W_CWD says what was seen). 2: this multiplexer cannot tell us.
_ctlw_verify_cwd() {
  _W_CWD=""
  local cwds rc dir real
  cwds=$(_ctlw_pane_cwds); rc=$?
  [ "$rc" -eq 2 ] && return 2
  if [ "$rc" -ne 0 ] || [ -z "$cwds" ]; then _W_CWD="(pane not found)"; return 1; fi
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    real=$(cd "$dir" 2>/dev/null && pwd -P) || real="$dir"
    [ "$real" = "$_W_WORKTREE" ] && { _W_CWD="$dir"; return 0; }
    [ -n "$_W_CWD" ] || _W_CWD="$dir"
  done <<<"$cwds"
  return 1
}

_ctlw_detail() {  # <extra-json-object>
  jq -cn --arg worktree "$_W_WORKTREE" --arg session "$_W_SESSION" --arg number "$_W_NUMBER" \
    --arg mux "$_W_MUX" --arg pane "$_W_PANE" --argjson extra "$1" \
    '{worktree: $worktree, session: $session, worker: ($number | tonumber? // null), mux: $mux,
      pane: (if $pane == "" then null else $pane end)} + $extra'
}

_ctlw_setup() {  # after _ctlw_args: finds the worker and loads mux-send-lib
  _ctlw_find || return 1
  # shellcheck source=mux-send-lib.sh
  source "${_ctlw_DIR}/mux-send-lib.sh"
  [ -n "$_W_PANE" ] || { ctl_fail "$_W_WORKTREE" "the manifest records no ${_W_MUX:-multiplexer} pane for worker $_W_NUMBER"; return 1; }
  return 0
}

ctl_verb_nudge() {
  _ctlw_args nudge 1 "usage: nudge <worktree> [text] [--session <name>]" -- "$@" || return
  local text="$AUTOCODER_CTL_NUDGE_TEXT"
  $_W_HAS_EXTRA && text="$_W_EXTRA"
  [ -n "$text" ] || { ctl_usage "nudge: the text is empty"; return; }
  _ctlw_setup || return

  if [ "$_W_STATE" = "paused" ]; then
    ctl_fail "$_W_WORKTREE" "worker $_W_NUMBER is paused; resume the swarm rather than nudging one worker"; return
  fi
  # Pane targets like "session:1.2" are positions, and shift when a pane closes, so
  # check that the pane is still the worker before typing into it.
  _ctlw_verify_cwd
  if [ $? -eq 1 ]; then
    ctl_fail "$_W_WORKTREE" "pane $_W_PANE is in $_W_CWD, not $_W_WORKTREE; not sending"; return
  fi

  local via rc
  case "$_W_MUX" in
    tmux)  via="tmux send-keys, then Enter"
           send_tmux_text_enter "$_W_PANE" "$text"; rc=$? ;;
    cmux)  via="cmux send, then send-key enter"
           send_cmux_command "$_W_PANE" "$text"; rc=$? ;;
    herdr) if [ "$_W_COMMAND_MODE" = "agent-input" ]; then
             # herdr's agent prompt submits text and enter as one ordered write.
             via="herdr agent prompt"
             prompt_herdr_agent "$_W_PANE" "$text"; rc=$?
             if [ "$rc" -ne 0 ]; then
               via="herdr pane send-text, then send-keys enter"
               send_herdr_command "$_W_PANE" "$text"; rc=$?
             fi
           else
             via="herdr pane send-text, then send-keys enter"
             send_herdr_command "$_W_PANE" "$text"; rc=$?
           fi ;;
    *)     ctl_fail "$_W_WORKTREE" "unknown multiplexer '$_W_MUX' in the manifest"; return ;;
  esac
  if [ "$rc" -ne 0 ]; then
    ctl_fail "$_W_WORKTREE" "$(_ctlw_detail "$(jq -cn --arg via "$via" --argjson rc "$rc" '{sent: false, via: $via, exit: $rc}')")" --json
    return
  fi
  ctl_ok "$_W_WORKTREE" "$(_ctlw_detail "$(jq -cn --arg via "$via" --arg text "$text" '{sent: true, via: $via, text: $text}')")" --json
}

ctl_verb_stop() {
  _ctlw_args stop 0 "usage: stop <worktree> [--session <name>]" -- "$@" || return
  _ctlw_setup || return
  _ctlw_verify_cwd
  case $? in
    0) ;;
    1) ctl_fail "$_W_WORKTREE" "pane $_W_PANE is in $_W_CWD, not $_W_WORKTREE; refusing to stop it"; return ;;
    *) ctl_fail "$_W_WORKTREE" "cannot read the working directory of a $_W_MUX pane, so cannot check it is this worker; refusing to stop it"; return ;;
  esac

  local left rc
  case "$_W_MUX" in
    tmux)
      # Kill the agent and leave a shell in the same pane and directory, so restart
      # (which finds the pane by its directory) and remove-worker.sh still work.
      left="shell"
      run_with_timeout "$AUTOCODER_MUX_TIMEOUT_SECONDS" \
        tmux respawn-pane -k -t "$_W_PANE" -c "$_W_WORKTREE"; rc=$? ;;
    herdr)
      # herdr cannot respawn a pane. Closing it is what remove-worker.sh does to the
      # workspace; restart opens a fresh one in the worktree.
      left="closed"
      run_with_timeout "$AUTOCODER_MUX_TIMEOUT_SECONDS" herdr pane close "$_W_PANE" >/dev/null; rc=$? ;;
  esac
  if [ "$rc" -ne 0 ]; then
    ctl_fail "$_W_WORKTREE" "could not stop pane $_W_PANE ($_W_MUX exit $rc)"; return
  fi
  ctl_ok "$_W_WORKTREE" "$(_ctlw_detail "$(jq -cn --arg cwd "$_W_CWD" --arg left "$left" \
    '{stopped: true, cwd: $cwd, pane_left: $left, worktree_kept: true, claim_kept: true}')")" --json
}

ctl_verb_restart() {
  _ctlw_args restart 0 "usage: restart <worktree> [--session <name>]" -- "$@" || return
  _ctlw_find || return

  local cmd="${AUTOCODER_CTL_RESTART_CMD:-${_ctlw_DIR}/restart-worker.sh}"
  local args=(--worktree "$_W_WORKTREE")
  [ -n "$_W_MUX" ] && args+=(--mux "$_W_MUX")
  [ -n "$_W_AGENT" ] && args+=(--agent "$_W_AGENT")

  local log rc last
  log=$(mktemp "${TMPDIR:-/tmp}/autocoder-ctl-restart.XXXXXX") || { ctl_fail "$_W_WORKTREE" "cannot create a temp file"; return; }
  # From inside the worktree: restart-worker.sh finds the project from its own cwd.
  (cd "$_W_WORKTREE" && "$cmd" "${args[@]}") >"$log" 2>&1; rc=$?
  cat "$log" >&2
  last=$(grep -v '^[[:space:]]*$' "$log" | tail -n 1)
  rm -f "$log"
  if [ "$rc" -ne 0 ]; then
    ctl_fail "$_W_WORKTREE" "$(_ctlw_detail "$(jq -cn --argjson rc "$rc" --arg out "$last" '{restarted: false, exit: $rc, output: $out}')")" --json
    return
  fi
  ctl_ok "$_W_WORKTREE" "$(_ctlw_detail "$(jq -cn --arg out "$last" --arg agent "$_W_AGENT" \
    '{restarted: true, agent: (if $agent == "" then null else $agent end), output: $out}')")" --json
}
