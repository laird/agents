#!/usr/bin/env bash
#
# ctl-swarm.sh — autocoder-ctl's swarm lifecycle verbs: start, add-worker,
# remove-worker and stop-swarm (#246).
#
# Sourced by autocoder-ctl.sh, never run on its own. Each verb reports through
# ctl_ok / ctl_fail / ctl_usage; stdout belongs to the dispatcher. Each verb wraps the
# script that already does the work, run with no terminal (stdin from /dev/null, its
# output to stderr), and reports what changed in the swarm manifest
# (.autocoder/swarm/<session>.json in the main worktree).
#
#   start <repo> [--workers N] [--agent A] [--mux M] [--route self|manager] [--paused]
#         [--no-plugin-install] [--prompt-wait S]
#       Install the autocoder plugin for the agent if it is missing, then
#       start-parallel-agents.sh in <repo>, without attaching.
#   add-worker [count] [--repo R] [--session S] [--prompt-wait S]
#       add-worker.sh with the swarm's own agent and multiplexer, without attaching.
#   remove-worker <N> [<N>...] [--repo R] [--session S] [--remove-worktree]
#       remove-worker.sh for those worker numbers.
#   stop-swarm [--repo R] [--mux M]
#       stop-parallel-agents.sh for the repo.
#
# start and add-worker then read the new panes and report any trust or consent
# prompt the agent is waiting on, in detail.prompts. They never answer one: that is
# the user's decision, and the UI shows it to them.

_ctls_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Prompts an agent shows before it will work. Trust is checked first: Claude's trust
# dialog also offers "No, exit".
AUTOCODER_CTL_TRUST_PATTERN="${AUTOCODER_CTL_TRUST_PATTERN:-[Dd]o you trust (the files|the contents|the authors|this folder|this directory|this workspace)|[Tt]rust (this|the) (folder|directory|workspace)\?}"
AUTOCODER_CTL_CONSENT_PATTERN="${AUTOCODER_CTL_CONSENT_PATTERN:-Bypass Permissions mode|bypass permissions mode|Yes, I accept|No, exit}"
AUTOCODER_CTL_PROMPT_WAIT="${AUTOCODER_CTL_PROMPT_WAIT:-8}"
AUTOCODER_CTL_PLUGIN_REF="${AUTOCODER_CTL_PLUGIN_REF:-autocoder@plugin-marketplace}"

# ── Helpers ───────────────────────────────────────────────────────────────────

_ctls_libs() {
  # shellcheck source=issue-source-lib.sh
  source "${_ctls_DIR}/issue-source-lib.sh"
  # shellcheck source=swarm-manifest-lib.sh
  source "${_ctls_DIR}/swarm-manifest-lib.sh"
  # shellcheck source=mux-send-lib.sh
  source "${_ctls_DIR}/mux-send-lib.sh"
}

_ctls_is_session() { case "$1" in */*|.*|"") return 1 ;; esac; return 0; }

# The repo to act on: --repo, else $AUTOCODER_CTL_PROJECT_ROOT, else the main
# worktree of the current directory. Sets _S_ROOT; reports and returns 1 on failure.
_ctls_root() {  # <repo-or-empty>
  local r="${1:-${AUTOCODER_CTL_PROJECT_ROOT:-}}"
  [ -n "$r" ] || r=$(resolve_main_worktree)
  [ -d "$r" ] || { ctl_fail "$r" "no such directory: $r"; return 1; }
  # A linked worktree's swarm lives in its main worktree.
  local main
  main=$(git -C "$r" worktree list --porcelain 2>/dev/null | awk '/^worktree / {print substr($0, 10); exit}')
  [ -n "$main" ] && [ -d "$main" ] && r="$main"
  _S_ROOT=$(cd "$r" && pwd -P)
}

# Pick the swarm to act on. Sets _S_MANIFEST, _S_SESSION, _S_AGENT, _S_MUX.
_ctls_pick() {  # <session-or-empty>
  local m
  if [ -n "$1" ]; then
    m=$(manifest_path_for_session "$_S_ROOT" "$1")
    [ -f "$m" ] || { ctl_fail "$_S_ROOT" "no swarm manifest for session '$1'"; return 1; }
  else
    local all=()
    shopt -s nullglob; all=("$_S_ROOT/$SWARM_STATE_DIR"/*.json); shopt -u nullglob
    case "${#all[@]}" in
      0) ctl_fail "$_S_ROOT" "no swarm is running in $_S_ROOT (no manifest); start one first"; return 1 ;;
      1) m="${all[0]}" ;;
      *) ctl_fail "$_S_ROOT" "more than one swarm in $_S_ROOT ($(for x in "${all[@]}"; do basename "$x" .json; done | paste -sd, -)); pass --session"; return 1 ;;
    esac
  fi
  jq -e 'type == "object"' "$m" >/dev/null 2>&1 || { ctl_fail "$_S_ROOT" "the manifest $m is unreadable"; return 1; }
  _S_MANIFEST="$m"
  _S_SESSION=$(basename "$m" .json)
  _S_AGENT=$(jq -r '.agent // ""' "$m")
  _S_MUX=$(jq -r '.mux // ""' "$m")
}

# Run a wrapped script in <dir> with no terminal. Its output goes to stderr; sets
# _S_RC and _S_LAST (its last non-blank line, for the result).
_ctls_run() {  # <dir> <cmd> [args...]
  local dir="$1" log; shift
  log=$(mktemp "${TMPDIR:-/tmp}/autocoder-ctl-swarm.XXXXXX") || { _S_RC=1; _S_LAST="cannot create a temp file"; return; }
  # The wrapped launchers hold their first prompt back from an agent showing a
  # dialog that matches AUTOCODER_CONSENT_PATTERN (send_agent_prompt in
  # mux-send-lib.sh, #253). Widen it with this file's own patterns, so a prompt
  # these verbs would report is one the launcher never answered.
  (cd "$dir" && source "${_ctls_DIR}/mux-send-lib.sh" \
     && export AUTOCODER_CONSENT_PATTERN="$AUTOCODER_CONSENT_PATTERN|$AUTOCODER_CTL_TRUST_PATTERN|$AUTOCODER_CTL_CONSENT_PATTERN" \
     && "$@") </dev/null >"$log" 2>&1; _S_RC=$?
  cat "$log" >&2
  _S_LAST=$(grep -v '^[[:space:]]*$' "$log" | tail -n 1 | sed 's/\x1b\[[0-9;]*m//g')
  _S_OUT=$(sed 's/\x1b\[[0-9;]*m//g' "$log")
  rm -f "$log"
}

# Workers in a manifest, one JSON object per line: number, state, pane.
_ctls_workers() {  # <manifest>
  jq -c '(.mux // "") as $mux | .workers[]? | select(type == "object")
    | {number, state: (.state // ""),
       pane: ({tmux: .tmuxTarget, cmux: .cmuxWorkspace, herdr: .herdrPane}[$mux] // null)}' "$1" 2>/dev/null
}

_ctls_capture() {  # <mux> <pane>
  # The pane comes from a manifest in the repo; refuse anything that could be read
  # as an option, or that holds control characters. (A session may contain a space:
  # it is named after the repo directory.)
  case "$2" in ""|-*|*[[:cntrl:]]*) return 1 ;; esac
  case "$1" in
    tmux)  run_with_timeout "$AUTOCODER_MUX_TIMEOUT_SECONDS" tmux capture-pane -p -t "$2" 2>/dev/null ;;
    cmux)  run_with_timeout "$AUTOCODER_MUX_TIMEOUT_SECONDS" cmux read-screen --workspace "$2" 2>/dev/null ;;
    herdr) run_with_timeout "$AUTOCODER_MUX_TIMEOUT_SECONDS" herdr pane read "$2" 2>/dev/null ;;
    *)     return 1 ;;
  esac
}

# Scan panes for a pending trust or consent prompt. Input lines: "<role>\x1f<worker>\x1f<pane>".
# Prints a JSON array of {role, worker, pane, kind, text}. Reads only; never types.
_ctls_prompts() {  # <mux> <wait-seconds>
  local mux="$1" wait="$2" role worker pane screen kind line out=()
  local rows; rows=$(cat)
  [ -n "$rows" ] || { echo '[]'; return; }
  [ "$wait" -gt 0 ] && sleep "$wait"
  while IFS=$'\x1f' read -r role worker pane; do
    [ -n "$pane" ] || continue
    screen=$(_ctls_capture "$mux" "$pane") || continue
    kind="" line=""
    if line=$(printf '%s\n' "$screen" | grep -Em1 "$AUTOCODER_CTL_TRUST_PATTERN"); then kind=trust
    elif line=$(printf '%s\n' "$screen" | grep -Em1 "$AUTOCODER_CTL_CONSENT_PATTERN"); then kind=consent
    else continue; fi
    line=$(printf '%s' "$line" | sed -E 's/^[[:space:]│|>❯]+//; s/[[:space:]│|]+$//')
    out+=("$(jq -cn --arg role "$role" --arg worker "$worker" --arg pane "$pane" --arg kind "$kind" --arg text "${line:0:200}" \
      '{role: $role, worker: ($worker | tonumber? // null), pane: $pane, kind: $kind, text: $text}')")
  done <<<"$rows"
  printf '%s\n' "${out[@]+"${out[@]}"}" | jq -cs 'map(select(. != null))'
}

# ── Plugin install (start) ────────────────────────────────────────────────────
# Prints {agent, status, ...}; returns 1 when an install was needed and failed.
# status: present | installed | failed | skipped.
_ctls_plugin() {  # <agent> <repo>
  local agent="$1" repo="$2" listing out rc
  case "$agent" in
    claude|droid) ;;
    gemini) jq -cn --arg a "$agent" '{agent: $a, status: "skipped", reason: "gemini loads the workflows from the repo; nothing to install"}'; return 0 ;;
    codex)  jq -cn --arg a "$agent" '{agent: $a, status: "skipped", reason: "codex skills are installed by scripts/install-codex.sh, not per swarm"}'; return 0 ;;
    grok)   jq -cn --arg a "$agent" '{agent: $a, status: "skipped", reason: "grok installs this repo'\''s Claude marketplace (grok plugin install autocoder --trust); see docs/GROK.md"}'; return 0 ;;
    *)      jq -cn --arg a "$agent" '{agent: $a, status: "skipped", reason: ("no plugin install for " + $a)}'; return 0 ;;
  esac
  if ! command -v "$agent" >/dev/null 2>&1; then
    jq -cn --arg a "$agent" '{agent: $a, status: "failed", reason: ($a + " is not on PATH")}'; return 1
  fi
  # From the repo, so a project-scoped install counts.
  listing=$(cd "$repo" && "$agent" plugin list </dev/null 2>&1) || listing=""
  if printf '%s\n' "$listing" | grep -Eq "(^|[^A-Za-z0-9_.-])$(printf '%s' "$AUTOCODER_CTL_PLUGIN_REF" | sed 's/[.[\*^$()+?{|]/\\&/g')([^A-Za-z0-9_.-]|$)"; then
    jq -cn --arg a "$agent" --arg ref "$AUTOCODER_CTL_PLUGIN_REF" '{agent: $a, status: "present", plugin: $ref}'; return 0
  fi
  out=$(cd "$repo" && "$agent" plugin install "$AUTOCODER_CTL_PLUGIN_REF" </dev/null 2>&1); rc=$?
  printf '%s\n' "$out" >&2
  out=$(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | tail -n 1)
  if [ "$rc" -ne 0 ]; then
    jq -cn --arg a "$agent" --arg ref "$AUTOCODER_CTL_PLUGIN_REF" --argjson rc "$rc" --arg out "$out" \
      '{agent: $a, status: "failed", plugin: $ref, exit: $rc, output: $out}'; return 1
  fi
  jq -cn --arg a "$agent" --arg ref "$AUTOCODER_CTL_PLUGIN_REF" --arg out "$out" \
    '{agent: $a, status: "installed", plugin: $ref, output: $out}'
}

_ctls_nonneg() { [[ "$1" =~ ^[0-9]+$ ]]; }
_ctls_pos()    { [[ "$1" =~ ^[1-9][0-9]*$ ]]; }

# ── start ─────────────────────────────────────────────────────────────────────
ctl_verb_start() {
  local repo="" workers="" agent="" mux="" route="" paused=false plugin=true wait="$AUTOCODER_CTL_PROMPT_WAIT"
  local usage="usage: start <repo> [--workers N] [--agent claude|codex|gemini|droid|pi|grok] [--mux tmux|cmux|herdr] [--route self|manager] [--paused] [--no-plugin-install] [--prompt-wait S]"
  while [ $# -gt 0 ]; do
    case "$1" in
      --workers|--agent|--mux|--route|--prompt-wait)
        [ $# -ge 2 ] || { ctl_usage "start: $1 needs a value"; return; }
        case "$1" in
          --workers)     workers="$2" ;;
          --agent)       agent="$2" ;;
          --mux)         mux="$2" ;;
          --route)       route="$2" ;;
          --prompt-wait) wait="$2" ;;
        esac
        shift 2 ;;
      --paused)            paused=true; shift ;;
      --no-plugin-install) plugin=false; shift ;;
      -*) ctl_usage "start: unknown option '$1'"; return ;;
      *)  [ -z "$repo" ] || { ctl_usage "$usage"; return; }
          repo="$1"; shift ;;
    esac
  done
  [ -n "$repo" ] || { ctl_usage "$usage"; return; }
  [ -z "$workers" ] || _ctls_pos "$workers" || { ctl_usage "start: --workers must be a positive integer, not '$workers'"; return; }
  case "$agent" in ""|claude|codex|gemini|droid|pi|grok) ;; *) ctl_usage "start: unknown agent '$agent'"; return ;; esac
  case "$mux" in ""|tmux|cmux|herdr) ;; *) ctl_usage "start: unknown multiplexer '$mux'"; return ;; esac
  case "$route" in ""|self|manager) ;; *) ctl_usage "start: --route is self or manager, not '$route'"; return ;; esac
  _ctls_nonneg "$wait" || { ctl_usage "start: --prompt-wait must be a whole number of seconds"; return; }

  _ctls_libs
  [ -d "$repo" ] || { ctl_fail "$repo" "no such directory: $repo"; return; }
  repo=$(cd "$repo" && pwd -P)
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || { ctl_fail "$repo" "$repo is not a git repository"; return; }

  # Settle the agent here, in start-parallel-agents.sh's order, so the plugin install
  # and the swarm use the same one.
  if [ -z "$agent" ]; then
    local a
    for a in claude gemini codex droid pi grok; do command -v "$a" >/dev/null 2>&1 && { agent="$a"; break; }; done
    [ -n "$agent" ] || { ctl_fail "$repo" "no agent CLI found on PATH (claude, gemini, codex, droid, pi, grok)"; return; }
  fi

  local plugin_json='{"status": "skipped", "reason": "--no-plugin-install"}'
  if $plugin; then
    if ! plugin_json=$(_ctls_plugin "$agent" "$repo"); then
      ctl_fail "$repo" "$(jq -cn --arg repo "$repo" --argjson p "$plugin_json" \
        '{repo: $repo, started: false, plugin: $p, reason: "the autocoder plugin is not installed and could not be"}')" --json
      return
    fi
  fi

  # start-parallel-agents.sh names the session <agent>-<repo dir>, and every launch
  # writes a new taskListId. A manifest that is merely newer proves nothing: workers
  # and the sentinel rewrite manifests while a swarm runs.
  local swarm_dir="$repo/$SWARM_STATE_DIR" marker expect before_id=""
  expect=$(manifest_path_for_session "$repo" "${agent}-$(basename "$repo")")
  [ -f "$expect" ] && before_id=$(jq -r '.taskListId // ""' "$expect" 2>/dev/null)
  mkdir -p "$swarm_dir" 2>/dev/null
  marker=$(mktemp "${TMPDIR:-/tmp}/autocoder-ctl-start.XXXXXX") || { ctl_fail "$repo" "cannot create a temp file"; return; }

  local cmd="${AUTOCODER_CTL_START_CMD:-${_ctls_DIR}/start-parallel-agents.sh}"
  local args=(--agent "$agent" --no-attach)
  [ -n "$workers" ] && args=("$workers" "${args[@]}")
  [ -n "$mux" ] && args+=(--mux "$mux")
  [ -n "$route" ] && args+=(--route "$route")
  $paused && args+=(--paused)
  _ctls_run "$repo" "$cmd" "${args[@]}"

  local m="" after_id
  if [ -f "$expect" ] && [ "$expect" -nt "$marker" ]; then
    after_id=$(jq -r '.taskListId // ""' "$expect" 2>/dev/null)
    { [ -z "$before_id" ] || [ "$after_id" != "$before_id" ]; } && m="$expect"
  fi
  rm -f "$marker"

  if [ "$_S_RC" -ne 0 ] || [ -z "$m" ]; then
    local why="start-parallel-agents.sh failed (exit $_S_RC)"
    if [ "$_S_RC" -eq 0 ]; then
      why="no swarm was started: start-parallel-agents.sh wrote no manifest"
      printf '%s\n' "$_S_OUT" | grep -q 'already exists' && why="a swarm session for this repo is already running; use add-worker, or stop-swarm first"
    fi
    ctl_fail "$repo" "$(jq -cn --arg repo "$repo" --arg why "$why" --argjson rc "$_S_RC" --arg out "$_S_LAST" --argjson p "$plugin_json" \
      '{repo: $repo, started: false, reason: $why, exit: $rc, output: $out, plugin: $p}')" --json
    return
  fi

  _S_ROOT="$repo"
  _ctls_pick "$(basename "$m" .json)" || return
  local prompts
  prompts=$( {
      jq -r '.manager // {} | ({tmux: .tmuxTarget, cmux: .cmuxWorkspace, herdr: .herdrPane}[$mux] // empty) | "manager\u001f\u001f" + .' \
        --arg mux "$_S_MUX" "$_S_MANIFEST" 2>/dev/null
      _ctls_workers "$_S_MANIFEST" | jq -r 'select(.pane != null) | "worker\u001f\(.number)\u001f\(.pane)"'
    } | _ctls_prompts "$_S_MUX" "$wait")

  ctl_ok "$repo" "$(jq -cn --arg repo "$repo" --arg session "$_S_SESSION" --arg manifest "$_S_MANIFEST" \
    --arg agent "$_S_AGENT" --arg mux "$_S_MUX" --argjson p "$plugin_json" --argjson prompts "$prompts" \
    --arg out "$_S_LAST" --slurpfile mf "$_S_MANIFEST" \
    '{repo: $repo, started: true, session: $session, manifest: $manifest, agent: $agent, mux: $mux,
      state: ($mf[0].state // null), workers: [$mf[0].workers[]?.number],
      plugin: $p, prompts: $prompts, prompts_pending: ($prompts | length > 0), output: $out}')" --json
}

# ── add-worker ────────────────────────────────────────────────────────────────
ctl_verb_add_worker() {
  local count="" repo="" session="" wait="$AUTOCODER_CTL_PROMPT_WAIT"
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo|--session|--prompt-wait)
        [ $# -ge 2 ] || { ctl_usage "add-worker: $1 needs a value"; return; }
        case "$1" in --repo) repo="$2" ;; --session) session="$2" ;; --prompt-wait) wait="$2" ;; esac
        shift 2 ;;
      -*) ctl_usage "add-worker: unknown option '$1'"; return ;;
      *)  [ -z "$count" ] || { ctl_usage "usage: add-worker [count] [--repo <path>] [--session <name>] [--prompt-wait S]"; return; }
          count="$1"; shift ;;
    esac
  done
  [ -z "$count" ] || _ctls_pos "$count" || { ctl_usage "add-worker: count must be a positive integer, not '$count'"; return; }
  [ -z "$session" ] || _ctls_is_session "$session" || { ctl_usage "add-worker: '$session' is not a session name"; return; }
  _ctls_nonneg "$wait" || { ctl_usage "add-worker: --prompt-wait must be a whole number of seconds"; return; }

  _ctls_libs
  _ctls_root "$repo" || return
  _ctls_pick "$session" || return

  local before after
  before=$(_ctls_workers "$_S_MANIFEST" | jq -cs .)
  local cmd="${AUTOCODER_CTL_ADD_WORKER_CMD:-${_ctls_DIR}/add-worker.sh}"
  local args=(--no-attach)
  [ -n "$count" ] && args=("$count" "${args[@]}")
  [ -n "$_S_AGENT" ] && args+=(--agent "$_S_AGENT")
  [ -n "$_S_MUX" ] && args+=(--mux "$_S_MUX")
  _ctls_run "$_S_ROOT" "$cmd" "${args[@]}"
  after=$(_ctls_workers "$_S_MANIFEST" | jq -cs .)

  # Added: numbers new to the manifest. Started: paused workers it woke instead.
  local changes
  changes=$(jq -cn --argjson b "$before" --argjson a "$after" '
    ($b | map({key: (.number | tostring), value: .state}) | from_entries) as $old
    | {added: [$a[] | select($old[.number | tostring] == null) | .number],
       started: [$a[] | select($old[.number | tostring] == "paused" and .state != "paused") | .number]}')

  if [ "$_S_RC" -ne 0 ]; then
    ctl_fail "$_S_ROOT" "$(jq -cn --arg session "$_S_SESSION" --argjson rc "$_S_RC" --arg out "$_S_LAST" --argjson c "$changes" \
      '{session: $session, exit: $rc, output: $out} + $c')" --json
    return
  fi

  local prompts
  prompts=$(jq -r --argjson c "$changes" '.[] | select(.pane != null)
      | select(.number as $n | ($c.added + $c.started) | index($n))
      | "worker\u001f\(.number)\u001f\(.pane)"' <<<"$after" | _ctls_prompts "$_S_MUX" "$wait")
  ctl_ok "$_S_ROOT" "$(jq -cn --arg session "$_S_SESSION" --arg agent "$_S_AGENT" --arg mux "$_S_MUX" \
    --argjson c "$changes" --argjson prompts "$prompts" --arg out "$_S_LAST" \
    '{session: $session, agent: $agent, mux: $mux} + $c
     + {prompts: $prompts, prompts_pending: ($prompts | length > 0), output: $out}')" --json
}

# ── remove-worker ─────────────────────────────────────────────────────────────
ctl_verb_remove_worker() {
  local repo="" session="" rmwt=false nums=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo|--session)
        [ $# -ge 2 ] || { ctl_usage "remove-worker: $1 needs a value"; return; }
        case "$1" in --repo) repo="$2" ;; --session) session="$2" ;; esac
        shift 2 ;;
      --remove-worktree) rmwt=true; shift ;;
      -*) ctl_usage "remove-worker: unknown option '$1'"; return ;;
      *)  _ctls_pos "$1" || { ctl_usage "remove-worker: '$1' is not a worker number"; return; }
          nums+=("$1"); shift ;;
    esac
  done
  [ "${#nums[@]}" -gt 0 ] || { ctl_usage "usage: remove-worker <N> [<N>...] [--repo <path>] [--session <name>] [--remove-worktree]"; return; }
  [ -z "$session" ] || _ctls_is_session "$session" || { ctl_usage "remove-worker: '$session' is not a session name"; return; }

  _ctls_libs
  _ctls_root "$repo" || return
  _ctls_pick "$session" || return

  local had
  had=$(_ctls_workers "$_S_MANIFEST" | jq -cs 'map(.number)')
  local cmd="${AUTOCODER_CTL_REMOVE_WORKER_CMD:-${_ctls_DIR}/remove-worker.sh}"
  local args=("${nums[@]}" --session "$_S_SESSION")
  $rmwt && args+=(--remove-worktree)
  _ctls_run "$_S_ROOT" "$cmd" "${args[@]}"

  local left req
  left=$(_ctls_workers "$_S_MANIFEST" | jq -cs 'map(.number)')
  req=$(printf '%s\n' "${nums[@]}" | jq -cs 'map(tonumber)')
  local detail
  detail=$(jq -cn --arg session "$_S_SESSION" --argjson req "$req" --argjson had "$had" --argjson left "$left" \
    --argjson rmwt "$rmwt" --argjson rc "$_S_RC" --arg out "$_S_LAST" \
    '{session: $session, requested: $req,
      removed: [$req[] | select(. as $n | ($had | index($n)) and ($left | index($n) | not))],
      remaining: $left, worktrees_removed: $rmwt, exit: $rc, output: $out}')
  if [ "$_S_RC" -ne 0 ]; then ctl_fail "$_S_ROOT" "$detail" --json; return; fi
  ctl_ok "$_S_ROOT" "$detail" --json
}

# ── stop-swarm ────────────────────────────────────────────────────────────────
ctl_verb_stop_swarm() {
  local repo="" mux=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo|--mux)
        [ $# -ge 2 ] || { ctl_usage "stop-swarm: $1 needs a value"; return; }
        case "$1" in --repo) repo="$2" ;; --mux) mux="$2" ;; esac
        shift 2 ;;
      *) ctl_usage "usage: stop-swarm [--repo <path>] [--mux tmux|cmux|herdr]"; return ;;
    esac
  done
  case "$mux" in ""|tmux|cmux|herdr) ;; *) ctl_usage "stop-swarm: unknown multiplexer '$mux'"; return ;; esac

  _ctls_libs
  _ctls_root "$repo" || return
  # stop-parallel-agents.sh names sessions after the directory it runs in, so run it
  # from the main worktree. Without --mux, use the manifests' multiplexer when they agree.
  if [ -z "$mux" ]; then
    local muxes
    shopt -s nullglob
    muxes=$(for f in "$_S_ROOT/$SWARM_STATE_DIR"/*.json; do jq -r '.mux // empty' "$f" 2>/dev/null; done | sort -u)
    shopt -u nullglob
    [ "$(printf '%s' "$muxes" | grep -c .)" -eq 1 ] && mux="$muxes"
  fi

  local cmd="${AUTOCODER_CTL_STOP_SWARM_CMD:-${_ctls_DIR}/stop-parallel-agents.sh}"
  local args=()
  [ -n "$mux" ] && args+=(--mux "$mux")
  _ctls_run "$_S_ROOT" "$cmd" "${args[@]+"${args[@]}"}"

  local stopped=true
  printf '%s\n' "$_S_OUT" | grep -q 'No parallel agent \(sessions\|workspaces\) found' && stopped=false

  # stop-parallel-agents.sh only knows the claude- and gemini- tmux sessions. Close
  # any other tmux session a manifest names (codex-, droid-, pi-) that is still up.
  # Only when tmux is the multiplexer being stopped: --mux herdr leaves tmux alone.
  local killed=() left=() f sess
  if { [ -z "$mux" ] || [ "$mux" = tmux ]; } && command -v tmux >/dev/null 2>&1; then
    shopt -s nullglob
    for f in "$_S_ROOT/$SWARM_STATE_DIR"/*.json; do
      [ "$(jq -r '.mux // ""' "$f" 2>/dev/null)" = tmux ] || continue
      sess=$(basename "$f" .json)
      run_with_timeout "$AUTOCODER_MUX_TIMEOUT_SECONDS" tmux has-session -t "=$sess" 2>/dev/null || continue
      if run_with_timeout "$AUTOCODER_MUX_TIMEOUT_SECONDS" tmux kill-session -t "=$sess" 2>/dev/null; then
        killed+=("$sess"); stopped=true
      else
        left+=("$sess")
      fi
    done
    shopt -u nullglob
  fi
  local detail
  detail=$(jq -cn --arg repo "$_S_ROOT" --arg mux "$mux" --argjson stopped "$stopped" --argjson rc "$_S_RC" --arg out "$_S_LAST" \
    --argjson killed "$(printf '%s\n' "${killed[@]+"${killed[@]}"}" | jq -R . | jq -cs 'map(select(. != ""))')" \
    --argjson left "$(printf '%s\n' "${left[@]+"${left[@]}"}" | jq -R . | jq -cs 'map(select(. != ""))')" \
    '{repo: $repo, mux: (if $mux == "" then null else $mux end), stopped: $stopped,
      sessions_closed: $killed, sessions_still_running: $left, exit: $rc, output: $out}')
  if [ "$_S_RC" -ne 0 ] || [ "${#left[@]}" -gt 0 ]; then ctl_fail "$_S_ROOT" "$detail" --json; return; fi
  ctl_ok "$_S_ROOT" "$detail" --json
}
