#!/bin/bash
# idle-sentinel.sh — zero-spend monitoring between work waves.
#
# Spec: docs/specs/2026-09-16-idle-sentinel-design.md (§1 the sentinel, §2 wake,
# and the sentinel-side halves of §3 quiescence handoff and §4 mux support).
# The spec is the authority; CDR/R2 citations below refer to its findings.
#
# When the swarm is quiescent this script replaces the LLM manager: it polls
# for work every AUTOCODER_SENTINEL_INTERVAL at zero token cost and spawns a
# real manager only when the mechanical wake predicate fires. It never manages
# work itself; anything requiring judgment is grounds to wake the manager.
#
# Modes:
#   --once      run a single tick (the cron/systemd entry point)
#   --loop      run ticks forever, sleeping the interval between them
#   --ensure    idempotent scheduler install/check: inspects crontab, systemd
#               user timers, and running --loop processes; installs a cron
#               entry (preferred) or starts a loop only when NOTHING is
#               scheduled yet; records the scheduler mode in the state file
#   --dry-run   evaluate the predicate read-only and print, for the detected
#               (or AUTOCODER_MUX-forced) multiplexer, the exact spawn
#               commands a wake WOULD run. No side effects: no lock, no
#               state/log writes, no kills, no spawns.
#   --help      usage
#
# Ownership invariants (CDR #2, #5; R2-F1/F4/F6/F7):
#   - The swarm manifest (.autocoder/swarm/<session>.json, via
#     swarm-manifest-lib.sh and its lock) is the single source of truth for
#     "who is the manager". sentinel-state.json is bookkeeping ONLY.
#   - Manager identity = manifest pid + pid_start_time, corroborated by the
#     AUTOCODER_MANAGER=<session> marker in the process environment.
#   - ONLY the sentinel clears a manifest manager entry, and only after
#     verifying the recorded identity is dead (pid gone or start-time
#     mismatch), under the manifest lock.
#   - The whole tick body runs under a non-blocking lock on
#     .autocoder/sentinel.tick.lock; a contended tick SKIPs (logged, counted
#     toward the error tolerance) instead of queueing.
#
# STANDING-CONDITIONS FENCE (read from MANAGER-STATE.md; written by
# /autocoder:manager-handoff — a later unit makes the handoff emit it; the
# format is fixed HERE so both sides agree):
#
#   ```sentinel-standing
#   SENTINEL-STANDING: <issue-number> <updatedAt-iso> <free text reason>
#   SENTINEL-STANDING: 2020 2026-09-14T21:33:12Z cross-repo PR 65, human-gated
#   ```
#
#   One line per condition inside a ```sentinel-standing fenced code block.
#   <updatedAt-iso> is the issue's updatedAt AT DECLARATION TIME (R2-F9): the
#   sentinel drops a condition when the live `gh issue view <n> --json
#   updatedAt` differs, and expires ALL conditions at each duty wake (the next
#   handoff must re-declare them). Standing conditions are subtracted from
#   wake predicates 2 (awaiting-integration) and 3 (stale working claims).
#
# STATE FILE (.autocoder/sentinel-state.json — sentinel-local bookkeeping,
# never pane/process ownership):
#   {
#     "version": 1,
#     "scheduler_mode": "cron" | "systemd" | "loop" | "none",
#     "last_tick_at": "<iso8601>",
#     "last_tick_result": "quiescent"|"wake:<reason>"|"observe"|"error"|
#                         "backoff:<reason>"|"wake-failed:<reason>",
#     "consecutive_errors": <int>,      // errored ticks + contended SKIPs
#     "last_duty_wake_at": "<iso8601>",
#     "last_wake": {"reason": "...", "issues_hash": "...", "at": "<iso>"},
#     "dedup":   {"<reason>": {"hash": "<sha256>", "count": <int>}},
#     "backoff": {"<reason>": {"until_epoch": <int>, "seconds": <int>}},
#     "consent_dialog_at": "<iso8601>"  // last bootstrap-config failure
#   }
#
# Configuration (defaults per the spec's table; durations accept 900, 15m, 6h):
#   AUTOCODER_SENTINEL_INTERVAL          15m   poll cadence
#   AUTOCODER_SENTINEL_DUTY_INTERVAL     6h    scheduled duty wake
#   AUTOCODER_SENTINEL_ERROR_TOLERANCE   2     consecutive errored ticks before escalation
#   AUTOCODER_SENTINEL_DEDUP_N           3     identical wakes before backoff
#   AUTOCODER_SENTINEL_BACKOFF_BASE      30m   first backoff step
#   AUTOCODER_SENTINEL_BACKOFF_CAP       12h   backoff ceiling
#   AUTOCODER_SENTINEL_STALL_THRESHOLD   2h    working-claim staleness bar
#   AUTOCODER_SENTINEL_WAKE_TIMEOUT      10m   hard ceiling on one wake attempt
#   AUTOCODER_SENTINEL_ACTIVITY_TIMEOUT  60    seconds to see manager activity
#   AUTOCODER_SENTINEL_GIT_LOCK_AGE      10m   minimum age before sweeping .git/*.lock
#   AUTOCODER_GH_USER                    unset pin gh credentials per tick
#   AUTOCODER_MUX / AUTOCODER_AGENT      unset force mux / agent framework
#   AUTOCODER_SESSION                    unset force swarm session name
#   .autocoder/sentinel-env                    sourced each run (cron PATH etc.)
#   .autocoder/sentinel-hooks.sh               sentinel_extra_wake_conditions,
#                                              sentinel_health_probe, sentinel_notify
#   .autocoder/wake                            manual/external force-wake file

set -o pipefail

SOURCE_PATH="${BASH_SOURCE[0]}"
while [ -L "$SOURCE_PATH" ]; do
  SOURCE_DIR="$(cd "$(dirname "$SOURCE_PATH")" && pwd)"
  SOURCE_PATH="$(readlink "$SOURCE_PATH")"
  [[ "$SOURCE_PATH" != /* ]] && SOURCE_PATH="$SOURCE_DIR/$SOURCE_PATH"
done
SCRIPT_DIR="$(cd "$(dirname "$SOURCE_PATH")" && pwd)"
SELF_PATH="$SCRIPT_DIR/$(basename "$SOURCE_PATH")"
AGENTS_REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# shellcheck source=swarm-manifest-lib.sh
source "$SCRIPT_DIR/swarm-manifest-lib.sh"
# shellcheck source=mux-send-lib.sh
source "$SCRIPT_DIR/mux-send-lib.sh"

# The sentinel must never carry the manager identity marker itself (it may
# inherit one when a manager runs `idle-sentinel.sh --ensure`). unset scrubs
# the CHILDREN it spawns; its own /proc environ still shows the inherited
# value, which is why every marker scan below also skips idle-sentinel
# processes by cmdline.
unset AUTOCODER_MANAGER

# ── argument parsing ────────────────────────────────────────────────────────

MODE=""
DRY_RUN=false
PROJECT_ROOT_ARG=""

usage() {
  cat <<'EOF'
Usage: idle-sentinel.sh [--once | --loop | --ensure | --dry-run] [options]

Zero-spend swarm monitoring between work waves. Polls the issue backend and
process state on a timer and spawns a real LLM manager only when the wake
predicate fires. See docs/specs/2026-09-16-idle-sentinel-design.md.

Modes (exactly one; --dry-run may stand alone or modify --once):
  --once        run a single tick (cron/systemd entry point)
  --loop        run ticks forever (only when no cron/systemd schedule exists)
  --ensure      idempotent scheduler install/check (never double-installs)
  --dry-run     evaluate read-only; print the spawn commands a wake would run
  --help        this text

Options:
  --project DIR   project root (default: current directory)

Wake predicate (first true wins, spec order):
  1. claimable open issues        5. project health hook red
  2. awaiting-integration minus   6. duty wake (every 6h)
     standing conditions          7. .autocoder/wake file
  3. stale working claims         8. sentinel_extra_wake_conditions hook
  4. gate/deploy in flight

Key environment (see script header for the full table):
  AUTOCODER_SENTINEL_INTERVAL=15m   AUTOCODER_SENTINEL_DUTY_INTERVAL=6h
  AUTOCODER_SENTINEL_ERROR_TOLERANCE=2   AUTOCODER_GH_USER=<login>
  AUTOCODER_MUX=tmux|cmux|herdr   AUTOCODER_AGENT=claude|...
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --once)    MODE="once"; shift ;;
    --loop)    MODE="loop"; shift ;;
    --ensure)  MODE="ensure"; shift ;;
    --dry-run) DRY_RUN=true; [ -z "$MODE" ] && MODE="once"; shift ;;
    --project) PROJECT_ROOT_ARG="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "❌ Unknown argument: $1" >&2
      echo "   Use --help for usage information" >&2
      exit 1
      ;;
  esac
done

if [ -z "$MODE" ]; then
  usage
  exit 1
fi

PROJECT_ROOT="${PROJECT_ROOT_ARG:-$(pwd)}"
PROJECT_ROOT="$(cd "$PROJECT_ROOT" 2>/dev/null && pwd)" || {
  echo "❌ Project root not found: ${PROJECT_ROOT_ARG:-$(pwd)}" >&2
  exit 1
}
cd "$PROJECT_ROOT" || exit 1
PROJECT_NAME="$(basename "$PROJECT_ROOT")"

AC_DIR="$PROJECT_ROOT/.autocoder"
STATE_FILE="$AC_DIR/sentinel-state.json"
LOG_FILE="$AC_DIR/sentinel.log"
LOCK_FILE="$AC_DIR/sentinel.tick.lock"
SKIP_FILE="$AC_DIR/sentinel.skips"
WAKE_FILE="$AC_DIR/wake"
HEARTBEAT_FILE="$AC_DIR/manager-heartbeat"
HEALTH_ALERT_FILE="$AC_DIR/health-alert"
QUIESCENT_FILE="$AC_DIR/quiescent-iterations"
ENV_FILE="$AC_DIR/sentinel-env"
HOOKS_FILE="$AC_DIR/sentinel-hooks.sh"
MANAGER_STATE_MD="$PROJECT_ROOT/MANAGER-STATE.md"

# Cron ticks run with a minimal environment; the env file restores PATH
# (gh/tmux/cmux/herdr) and AUTOCODER_* configuration (CDR #7).
if [ -f "$ENV_FILE" ]; then
  # shellcheck source=/dev/null
  source "$ENV_FILE"
fi

# Project hooks: sentinel_extra_wake_conditions (exit 0 = wake),
# sentinel_health_probe (exit 0 = green), sentinel_notify <message>.
if [ -f "$HOOKS_FILE" ]; then
  # shellcheck source=/dev/null
  source "$HOOKS_FILE"
fi

# ── configuration ───────────────────────────────────────────────────────────

# parse_duration 900 | 15m | 6h | 2d → seconds
parse_duration() {
  local v="$1"
  case "$v" in
    *d) echo $(( ${v%d} * 86400 )) ;;
    *h) echo $(( ${v%h} * 3600 )) ;;
    *m) echo $(( ${v%m} * 60 )) ;;
    *s) echo $(( ${v%s} )) ;;
    ''|*[!0-9]*) echo "❌ Bad duration: '$v'" >&2; return 1 ;;
    *) echo "$v" ;;
  esac
}

INTERVAL_S=$(parse_duration "${AUTOCODER_SENTINEL_INTERVAL:-15m}") || exit 1
DUTY_INTERVAL_S=$(parse_duration "${AUTOCODER_SENTINEL_DUTY_INTERVAL:-6h}") || exit 1
ERROR_TOLERANCE="${AUTOCODER_SENTINEL_ERROR_TOLERANCE:-2}"
DEDUP_N="${AUTOCODER_SENTINEL_DEDUP_N:-3}"
BACKOFF_BASE_S=$(parse_duration "${AUTOCODER_SENTINEL_BACKOFF_BASE:-30m}") || exit 1
BACKOFF_CAP_S=$(parse_duration "${AUTOCODER_SENTINEL_BACKOFF_CAP:-12h}") || exit 1
STALL_THRESHOLD_S=$(parse_duration "${AUTOCODER_SENTINEL_STALL_THRESHOLD:-2h}") || exit 1
WAKE_TIMEOUT_S=$(parse_duration "${AUTOCODER_SENTINEL_WAKE_TIMEOUT:-10m}") || exit 1
ACTIVITY_TIMEOUT_S=$(parse_duration "${AUTOCODER_SENTINEL_ACTIVITY_TIMEOUT:-60}") || exit 1
GIT_LOCK_AGE_S=$(parse_duration "${AUTOCODER_SENTINEL_GIT_LOCK_AGE:-10m}") || exit 1

AGENT_NAME="${AUTOCODER_AGENT:-claude}"

# ── session / manifest resolution ───────────────────────────────────────────

# Session default matches start-parallel-agents.sh (${AGENT}-${PROJECT_NAME}).
# If that manifest does not exist but exactly ONE swarm manifest does, adopt
# it (session name = file name, agent from its "agent" field) — an installed
# sentinel must see a hand-launched swarm whatever the operator called it.
resolve_session() {
  SESSION_NAME="${AUTOCODER_SESSION:-}"
  if [ -z "$SESSION_NAME" ]; then
    SESSION_NAME="${AGENT_NAME}-${PROJECT_NAME}"
    if [ ! -f "$(manifest_path_for_session "$PROJECT_ROOT" "$SESSION_NAME")" ]; then
      local candidates=()
      local f
      for f in "$PROJECT_ROOT/$SWARM_STATE_DIR"/*.json; do
        [ -f "$f" ] && candidates+=("$f")
      done
      if [ "${#candidates[@]}" -eq 1 ]; then
        SESSION_NAME="$(basename "${candidates[0]}" .json)"
        local mf_agent
        mf_agent=$(manifest_get "${candidates[0]}" 'm.get("agent")' 2>/dev/null)
        [ -n "$mf_agent" ] && [ -z "${AUTOCODER_AGENT:-}" ] && AGENT_NAME="$mf_agent"
      fi
    fi
  fi
  MANIFEST_PATH="$(manifest_path_for_session "$PROJECT_ROOT" "$SESSION_NAME")"
  MANAGER_MARKER="AUTOCODER_MANAGER=$SESSION_NAME"
}
resolve_session

# ── small utilities ─────────────────────────────────────────────────────────

now_iso() { now_utc_iso; }
now_epoch() { date +%s; }

file_mtime() {
  local f="$1"
  stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null
}

log_event() {
  # Immediate event line (kills, notifies, wake progress). The per-tick
  # summary is a separate single line written by finish_tick.
  [ "$DRY_RUN" = true ] && { echo "DRY-RUN log: $*"; return 0; }
  mkdir -p "$AC_DIR"
  printf '%s %s\n' "$(now_iso)" "$*" >> "$LOG_FILE"
}

notify() {
  local msg="$1"
  log_event "NOTIFY $msg"
  if declare -F sentinel_notify >/dev/null 2>&1; then
    sentinel_notify "$msg" || true
  fi
}

truncate_log_if_large() {
  [ -f "$LOG_FILE" ] || return 0
  local size
  size=$(wc -c < "$LOG_FILE" 2>/dev/null) || return 0
  if [ "${size:-0}" -gt 1048576 ]; then
    local tmp="$LOG_FILE.tmp.$$"
    tail -n 500 "$LOG_FILE" > "$tmp" && mv "$tmp" "$LOG_FILE"
  fi
}

# ── state file helpers (bookkeeping only, never ownership) ─────────────────

state_get() {
  # state_get <dotted.path> — empty output when missing.
  python3 - "$STATE_FILE" "$1" <<'PY' 2>/dev/null
import json, sys
path, key = sys.argv[1], sys.argv[2]
try:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    sys.exit(0)
cur = data
for part in key.split("."):
    if not isinstance(cur, dict) or part not in cur:
        sys.exit(0)
    cur = cur[part]
if cur is None:
    sys.exit(0)
print(cur)
PY
}

state_merge() {
  # state_merge '<json object>' — deep-merges into the state file, atomically.
  [ "$DRY_RUN" = true ] && return 0
  mkdir -p "$AC_DIR"
  python3 - "$STATE_FILE" "$1" <<'PY'
import json, os, sys, tempfile
path, patch_json = sys.argv[1], sys.argv[2]
patch = json.loads(patch_json)
try:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    data = {"version": 1}
def merge(dst, src):
    for k, v in src.items():
        if isinstance(v, dict) and isinstance(dst.get(k), dict):
            merge(dst[k], v)
        else:
            dst[k] = v
merge(data, patch)
directory = os.path.dirname(path) or "."
fd, tmp = tempfile.mkstemp(prefix=".sentinel-state.", suffix=".json", dir=directory)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    os.replace(tmp, path)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)
PY
}

sha256_of() {
  printf '%s' "$1" | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'
}

# ── issue backend probes ────────────────────────────────────────────────────
# Every probe runs the backend in a SUBSHELL so issue-config.sh's
# non-interactive `exit 1` (no configured backend) cannot kill the sentinel;
# it surfaces as a probe error instead — and a probe error is NEVER
# quiescence (CDR #7).

probe_backend() {
  ( cd "$PROJECT_ROOT" && source "$SCRIPT_DIR/issue-fns.sh" >/dev/null 2>&1 && "$@" )
}

issue_source_resolved() {
  probe_backend sh -c 'printf %s "$ISSUE_SOURCE"' 2>/dev/null
}

json_issue_numbers() {
  # stdin: backend list JSON → space-separated OPEN issue numbers.
  python3 -c '
import json, sys
try:
    issues = json.load(sys.stdin)
except Exception:
    sys.exit(3)
nums = [str(i["number"]) for i in issues
        if str(i.get("state", "OPEN")).upper() != "CLOSED"]
print(" ".join(nums))
' 2>/dev/null
}

# Each probe prints its payload and returns 0 (clean) or 1 (probe error).
probe_claimable() {
  local out
  out=$(probe_backend issue_list --state open --limit 50 2>/dev/null) || return 1
  printf '%s' "$out" | json_issue_numbers || return 1
}

probe_awaiting() {
  local out
  out=$(probe_backend issue_list --state all --label awaiting-integration --limit 100 2>/dev/null) || return 1
  printf '%s' "$out" | json_issue_numbers || return 1
}

probe_working() {
  local out
  out=$(probe_backend issue_list --state working --limit 100 2>/dev/null) || return 1
  printf '%s' "$out" | json_issue_numbers || return 1
}

# Live updatedAt for one issue (github backend only; other backends print
# nothing — condition validation and staleness degrade gracefully there).
issue_updated_at() {
  local n="$1"
  [ "$ISSUE_SOURCE_KIND" = "github" ] || return 0
  gh issue view "$n" --json updatedAt --jq .updatedAt 2>/dev/null
}

iso_to_epoch() {
  python3 -c '
import sys
from datetime import datetime
try:
    print(int(datetime.fromisoformat(sys.argv[1].replace("Z", "+00:00")).timestamp()))
except Exception:
    sys.exit(1)
' "$1" 2>/dev/null
}

# Any branch mentioning issue N with a commit newer than the cutoff?
recent_branch_activity() {
  local n="$1" cutoff="$2"
  git -C "$PROJECT_ROOT" for-each-ref --format='%(refname:short) %(committerdate:unix)' \
      refs/heads refs/remotes 2>/dev/null |
    awk -v n="$n" -v cutoff="$cutoff" '
      $1 ~ ("(^|[^0-9])" n "([^0-9]|$)") && $2 >= cutoff { found = 1 }
      END { exit found ? 0 : 1 }'
}

# ── standing conditions (fence format documented in the header) ────────────

read_standing() {
  # prints one "number updatedAt" pair per line
  [ -f "$MANAGER_STATE_MD" ] || return 0
  awk '/^```sentinel-standing[[:space:]]*$/ { f = 1; next }
       f && /^```/ { f = 0 }
       f' "$MANAGER_STATE_MD" |
    sed -n 's/^SENTINEL-STANDING:[[:space:]]*//p' |
    awk 'NF >= 2 { print $1, $2 }'
}

remove_standing_lines() {
  # remove_standing_lines all | <number>...
  [ -f "$MANAGER_STATE_MD" ] || return 0
  [ "$DRY_RUN" = true ] && return 0
  python3 - "$MANAGER_STATE_MD" "$@" <<'PY'
import re, sys
path = sys.argv[1]
targets = sys.argv[2:]
drop_all = targets == ["all"]
with open(path, encoding="utf-8") as f:
    lines = f.readlines()
out, in_fence = [], False
for line in lines:
    if re.match(r"^```sentinel-standing\s*$", line):
        in_fence = True
        out.append(line)
        continue
    if in_fence and line.startswith("```"):
        in_fence = False
        out.append(line)
        continue
    if in_fence:
        m = re.match(r"^SENTINEL-STANDING:\s*(\S+)", line)
        if m and (drop_all or m.group(1) in targets):
            continue
    out.append(line)
with open(path, "w", encoding="utf-8") as f:
    f.writelines(out)
PY
}

# Validate each standing condition against the live tracker (R2-F9): drop it
# when updatedAt changed. Populates STANDING_NUMBERS with the survivors.
STANDING_NUMBERS=""
validate_standing() {
  STANDING_NUMBERS=""
  local line n rec live
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    n="${line%% *}"
    rec="${line#* }"
    live=$(issue_updated_at "$n")
    if [ -n "$live" ] && [ "$live" != "$rec" ]; then
      log_event "STANDING drop #$n (updatedAt $rec -> $live)"
      remove_standing_lines "$n"
      continue
    fi
    STANDING_NUMBERS="$STANDING_NUMBERS $n"
  done < <(read_standing)
  STANDING_NUMBERS="${STANDING_NUMBERS# }"
}

subtract_standing() {
  # subtract_standing "<numbers...>" → numbers not standing
  local out="" n s skip
  for n in $1; do
    skip=false
    for s in $STANDING_NUMBERS; do
      [ "$n" = "$s" ] && { skip=true; break; }
    done
    [ "$skip" = false ] && out="$out $n"
  done
  printf '%s' "${out# }"
}

# ── process identity helpers ────────────────────────────────────────────────

pid_cwd() {
  local pid="$1"
  if [ -d /proc/self ]; then
    readlink "/proc/$pid/cwd" 2>/dev/null
  else
    lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1
  fi
}

pid_cwd_in_root() {
  local cwd
  cwd=$(pid_cwd "$1") || return 1
  [ -n "$cwd" ] || return 1
  case "$cwd" in
    "$PROJECT_ROOT"|"$PROJECT_ROOT"/*) return 0 ;;
    *) return 1 ;;
  esac
}

pid_is_sentinel() {
  # A sentinel spawned from a manager pane inherits the marker in its /proc
  # environ (unset cannot rewrite it), so marker scans must skip our own kind.
  local pid="$1" cmdline=""
  if [ -d /proc/self ]; then
    # stderr redirected BEFORE the input redirection so a process vanishing
    # mid-scan stays silent (same trap as manager_pid_by_marker's environ read).
    cmdline=$(tr '\0' ' ' 2>/dev/null < "/proc/$pid/cmdline")
  else
    cmdline=$(ps -o command= -p "$pid" 2>/dev/null)
  fi
  case "$cmdline" in *idle-sentinel*) return 0 ;; *) return 1 ;; esac
}

# ALL live pids carrying our session's manager marker (manager_pid_by_marker
# from the manifest lib stops at the first; the orphan sweep needs every one).
marker_pids_all() {
  local marker="$MANAGER_MARKER"
  if [ -d /proc/self ]; then
    local dir pid
    for dir in /proc/[0-9]*; do
      pid="${dir#/proc/}"
      [ "$pid" = "$$" ] && continue
      [ "$pid" = "$PPID" ] && continue
      [ -r "$dir/environ" ] || continue
      if tr '\0' '\n' 2>/dev/null < "$dir/environ" | grep -Fxq "$marker"; then
        pid_is_sentinel "$pid" && continue
        printf '%s\n' "$pid"
      fi
    done
    return 0
  fi
  local snapshot
  snapshot=$(ps -axwwE -o pid= -o command= 2>/dev/null) || return 0
  printf '%s\n' "$snapshot" | awk -v marker="$marker" -v self="$$" -v parent="$PPID" '
    {
      i = index($0, marker)
      if (i && $1 != self && $1 != parent) {
        c = substr($0, i + length(marker), 1)
        if (c == "" || c == " ") print $1
      }
    }' | while IFS= read -r pid; do
      pid_is_sentinel "$pid" && continue
      printf '%s\n' "$pid"
    done
}

# Marker corroboration for one pid. Only our own processes' environ is
# readable; when it is not (or /proc is absent and ps -E hides other users),
# the pid+start-time manifest match stands alone — documented best-effort.
pid_has_marker() {
  local pid="$1"
  if [ -d /proc/self ]; then
    if [ -r "/proc/$pid/environ" ]; then
      tr '\0' '\n' 2>/dev/null < "/proc/$pid/environ" | grep -Fxq "$MANAGER_MARKER"
      return $?
    fi
    return 0  # unreadable environ: cannot disprove; start-time match governs
  fi
  local out
  out=$(ps -wwE -o command= -p "$pid" 2>/dev/null) || return 0
  case "$out" in *"$MANAGER_MARKER"*) return 0 ;; *) return 1 ;; esac
}

kill_pid_verified() {
  # kill_pid_verified <pid> <expected-start-time> — identity-checked kill.
  local pid="$1" expected="$2" cur
  cur=$(process_start_time "$pid") || return 0  # already gone
  if [ -n "$expected" ] && [ "$cur" != "$expected" ]; then
    log_event "KILL refused: pid $pid start-time mismatch (recycled pid)"
    return 1
  fi
  if [ "$DRY_RUN" = true ]; then
    echo "DRY-RUN would kill: pid $pid"
    return 0
  fi
  kill "$pid" 2>/dev/null
  local tries=5
  while [ "$tries" -gt 0 ] && kill -0 "$pid" 2>/dev/null; do
    sleep 1
    tries=$((tries - 1))
  done
  kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
  return 0
}

# ── manifest manager entry: verify / refresh / clear ────────────────────────

MANAGER_PID=""
MANAGER_PID_START=""

clear_manifest_manager() {
  # ONLY the sentinel does this, and only for a verified-dead identity
  # (R2-F6). manifest_set_manager takes its own lock.
  [ -f "$MANIFEST_PATH" ] || return 0
  if [ "$DRY_RUN" = true ]; then
    echo "DRY-RUN would clear manifest manager entry: $MANIFEST_PATH"
    return 0
  fi
  manifest_set_manager "$MANIFEST_PATH" 'null'
  log_event "MANIFEST cleared manager entry ($1)"
}

refresh_manifest_manager_identity() {
  local pid="$1" start="$2"
  [ "$DRY_RUN" = true ] && return 0
  [ -f "$MANIFEST_PATH" ] || return 0
  local json
  json=$(python3 - "$MANIFEST_PATH" "$pid" "$start" "$MANAGER_MARKER" "$(now_iso)" <<'PY'
import json, sys
path, pid, start, marker, now = sys.argv[1:]
with open(path, encoding="utf-8") as f:
    data = json.load(f)
m = data.get("manager") or {}
m.update({"pid": int(pid), "pid_start_time": start, "marker": marker,
          "agentLaunched": True})
m.setdefault("spawned_at", now)
print(json.dumps(m))
PY
) || return 1
  manifest_set_manager "$MANIFEST_PATH" "$json"
  log_event "MANIFEST refreshed manager identity pid=$pid"
}

# Is a verified live manager present? Sets MANAGER_PID/MANAGER_PID_START.
# Dead identities are cleared here — dead pid or start-time mismatch → clear
# under the manifest lock and return 1 (wake-spawning mode).
manager_alive() {
  MANAGER_PID=""
  MANAGER_PID_START=""
  [ -f "$MANIFEST_PATH" ] || return 1
  local pid start cur
  pid=$(manifest_manager_field "$MANIFEST_PATH" pid)
  start=$(manifest_manager_field "$MANIFEST_PATH" pid_start_time)
  if [ -n "$pid" ]; then
    if cur=$(process_start_time "$pid") && { [ -z "$start" ] || [ "$cur" = "$start" ]; }; then
      if pid_has_marker "$pid"; then
        MANAGER_PID="$pid"
        MANAGER_PID_START="$cur"
        return 0
      fi
      # Alive pid, matching start time, but provably NOT carrying our marker:
      # a recycled pid that happens to match is astronomically unlikely, a
      # foreign process is not. Treat as dead identity.
      clear_manifest_manager "pid $pid alive but marker absent"
      return 1
    fi
    clear_manifest_manager "pid $pid dead or start-time mismatch"
    return 1
  fi
  # Manifest has a manager entry with a null pid (async launch): probe by
  # marker and refresh — the launcher records null rather than guessing.
  local probed
  if probed=$(manager_pid_by_marker "$SESSION_NAME") && pid_cwd_in_root "$probed"; then
    if cur=$(process_start_time "$probed"); then
      refresh_manifest_manager_identity "$probed" "$cur"
      MANAGER_PID="$probed"
      MANAGER_PID_START="$cur"
      return 0
    fi
  fi
  return 1
}

# Orphan sweep (R2-F6): marker-bearing, cwd-verified processes that do not
# match the manifest identity are zombie managers from failed exits — kill.
orphan_sweep() {
  local pid
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    [ "$pid" = "$MANAGER_PID" ] && continue
    pid_cwd_in_root "$pid" || continue
    if [ "$DRY_RUN" = true ]; then
      echo "DRY-RUN would kill orphan marker process: pid $pid"
      continue
    fi
    log_event "ORPHAN killing marker-bearing pid $pid (not the manifest manager)"
    kill_pid_verified "$pid" ""
  done < <(marker_pids_all)
}

# ── in-flight process checks (wake predicate 4; also gates heartbeat kill) ──
# Self-match-proof BRACKETED patterns + /proc cwd verification inside this
# checkout (CDR #10). Unscoped -f patterns self-match through bash -c
# wrappers and match other tenants on a shared host.

INFLIGHT_PATTERNS=('merge-to-integratio[n].sh' 'upgrade-deplo[y]')

inflight_detected() {
  local pat pid
  for pat in "${INFLIGHT_PATTERNS[@]}"; do
    for pid in $(pgrep -f "$pat" 2>/dev/null); do
      [ "$pid" = "$$" ] && continue
      pid_cwd_in_root "$pid" && return 0
    done
  done
  return 1
}

# ── tick-level tool self-check (CDR #7) ─────────────────────────────────────

self_check_tools() {
  local missing="" t
  for t in python3 awk pgrep date; do
    command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
  done
  if [ "$ISSUE_SOURCE_KIND" = "github" ] && ! command -v gh >/dev/null 2>&1; then
    missing="$missing gh"
  fi
  if [ -n "$missing" ]; then
    TICK_ERROR_DETAIL="missing tools:$missing"
    return 1
  fi
  return 0
}

pin_gh_token() {
  # Shared-host defence: a co-tenant flipping the active gh account must not
  # blind the sentinel. Pin the token for this tick when configured.
  [ -n "${AUTOCODER_GH_USER:-}" ] || return 0
  command -v gh >/dev/null 2>&1 || { TICK_ERROR_DETAIL="AUTOCODER_GH_USER set but gh missing"; return 1; }
  local tok
  if tok=$(gh auth token --user "$AUTOCODER_GH_USER" 2>/dev/null) && [ -n "$tok" ]; then
    export GH_TOKEN="$tok"
    return 0
  fi
  TICK_ERROR_DETAIL="gh auth token --user $AUTOCODER_GH_USER failed"
  return 1
}

# ── wake predicate ──────────────────────────────────────────────────────────
# Sets: WAKE_REASON (empty = quiescent), WAKE_DETAIL, WAKE_ISSUES,
#       PROBE_ERRORS (count), PREDICATE_SUMMARY.

evaluate_predicate() {
  WAKE_REASON=""
  WAKE_DETAIL=""
  WAKE_ISSUES=""
  PROBE_ERRORS=0
  PREDICATE_SUMMARY=""

  validate_standing

  # 1. claimable work
  local claimable="" p1=ok
  if claimable=$(probe_claimable); then
    if [ -n "$claimable" ]; then
      WAKE_REASON="claimable"
      WAKE_DETAIL="claimable open issues: $claimable"
      WAKE_ISSUES="$claimable"
    fi
  else
    p1=err; PROBE_ERRORS=$((PROBE_ERRORS + 1))
  fi
  PREDICATE_SUMMARY="claimable=${claimable:-0}${p1/#ok/}"
  [ "$p1" = err ] && PREDICATE_SUMMARY="claimable=ERR"

  # 2. un-merged banked work (awaiting-integration minus standing conditions)
  local awaiting="" banked="" p2=ok
  if awaiting=$(probe_awaiting); then
    banked=$(subtract_standing "$awaiting")
    if [ -z "$WAKE_REASON" ] && [ -n "$banked" ]; then
      WAKE_REASON="banked"
      WAKE_DETAIL="awaiting-integration issues: $banked"
      WAKE_ISSUES="$banked"
    fi
  else
    p2=err; PROBE_ERRORS=$((PROBE_ERRORS + 1))
  fi
  PREDICATE_SUMMARY="$PREDICATE_SUMMARY banked=$([ "$p2" = err ] && echo ERR || echo "${banked:-0}")"

  # 3. stale working claims (minus standing conditions)
  local working="" stale="" p3=ok n upd upd_epoch cutoff
  cutoff=$(( $(now_epoch) - STALL_THRESHOLD_S ))
  if working=$(probe_working); then
    for n in $(subtract_standing "$working"); do
      upd=$(issue_updated_at "$n")
      [ -n "$upd" ] || continue  # backend can't say → not provably stale
      upd_epoch=$(iso_to_epoch "$upd") || continue
      if [ "$upd_epoch" -lt "$cutoff" ] && ! recent_branch_activity "$n" "$cutoff"; then
        stale="$stale $n"
      fi
    done
    stale="${stale# }"
    if [ -z "$WAKE_REASON" ] && [ -n "$stale" ]; then
      WAKE_REASON="stale-claim"
      WAKE_DETAIL="stale working claims: $stale"
      WAKE_ISSUES="$stale"
    fi
  else
    p3=err; PROBE_ERRORS=$((PROBE_ERRORS + 1))
  fi
  PREDICATE_SUMMARY="$PREDICATE_SUMMARY stale=$([ "$p3" = err ] && echo ERR || echo "${stale:-0}")"

  # 4. in-flight gate/deploy
  local inflight=no
  if inflight_detected; then
    inflight=yes
    if [ -z "$WAKE_REASON" ]; then
      WAKE_REASON="in-flight"
      WAKE_DETAIL="merge gate or deploy running in this checkout"
    fi
  fi
  PREDICATE_SUMMARY="$PREDICATE_SUMMARY inflight=$inflight"

  # 5. project health hook (green-path checks are free; only red wakes)
  local health=n/a
  if declare -F sentinel_health_probe >/dev/null 2>&1; then
    if ( sentinel_health_probe ) >/dev/null 2>&1; then
      health=green
    else
      health=red
      if [ -z "$WAKE_REASON" ]; then
        WAKE_REASON="health"
        WAKE_DETAIL="sentinel_health_probe red"
      fi
    fi
  fi
  PREDICATE_SUMMARY="$PREDICATE_SUMMARY health=$health"

  # 6. scheduled duty wake (CDR #3a)
  local duty=no last_duty last_duty_epoch
  last_duty=$(state_get last_duty_wake_at)
  if [ -z "$last_duty" ]; then
    # First tick ever: start the duty clock now instead of waking immediately.
    state_merge "{\"last_duty_wake_at\": \"$(now_iso)\"}"
  else
    last_duty_epoch=$(iso_to_epoch "$last_duty")
    if [ -n "$last_duty_epoch" ] && [ $(( $(now_epoch) - last_duty_epoch )) -ge "$DUTY_INTERVAL_S" ]; then
      duty=due
      if [ -z "$WAKE_REASON" ]; then
        WAKE_REASON="duty"
        WAKE_DETAIL="duty wake (review-blocked triage, housekeeping)"
      fi
    fi
  fi
  PREDICATE_SUMMARY="$PREDICATE_SUMMARY duty=$duty"

  # 7. operator wake file
  local wakefile=no
  if [ -e "$WAKE_FILE" ]; then
    wakefile=yes
    if [ -z "$WAKE_REASON" ]; then
      WAKE_REASON="wake-file"
      WAKE_DETAIL=".autocoder/wake present"
    fi
  fi
  PREDICATE_SUMMARY="$PREDICATE_SUMMARY wakefile=$wakefile"

  # 8. project hook extra conditions
  if declare -F sentinel_extra_wake_conditions >/dev/null 2>&1; then
    if ( sentinel_extra_wake_conditions ) >/dev/null 2>&1; then
      if [ -z "$WAKE_REASON" ]; then
        WAKE_REASON="hook"
        WAKE_DETAIL="sentinel_extra_wake_conditions fired"
      fi
      PREDICATE_SUMMARY="$PREDICATE_SUMMARY hook=wake"
    fi
  fi

  PREDICATE_SUMMARY="$PREDICATE_SUMMARY errors=$PROBE_ERRORS"
}

# ── wake-reason dedup + backoff (CDR #3b) ───────────────────────────────────
# Returns 0 = go, 1 = suppressed. On suppression sets SUPPRESS_KIND.

dedup_gate() {
  local reason="$1" hash="$2"
  SUPPRESS_KIND=""
  local prev_hash prev_count b_until now
  prev_hash=$(state_get "dedup.$reason.hash")
  prev_count=$(state_get "dedup.$reason.count")
  prev_count="${prev_count:-0}"
  b_until=$(state_get "backoff.$reason.until_epoch")
  now=$(now_epoch)

  if [ "$hash" != "$prev_hash" ]; then
    # Observable state change: clear any backoff for this reason.
    state_merge "{\"dedup\": {\"$reason\": {\"hash\": \"$hash\", \"count\": 0}}, \"backoff\": {\"$reason\": {\"until_epoch\": 0, \"seconds\": 0}}}"
    return 0
  fi
  if [ -n "$b_until" ] && [ "$b_until" -gt "$now" ] 2>/dev/null; then
    SUPPRESS_KIND="backoff(until $(date -d "@$b_until" 2>/dev/null || echo "$b_until"))"
    return 1
  fi
  if [ "$prev_count" -ge "$DEDUP_N" ]; then
    local prev_s new_s
    prev_s=$(state_get "backoff.$reason.seconds")
    prev_s="${prev_s:-0}"
    if [ "$prev_s" -le 0 ] 2>/dev/null; then
      new_s="$BACKOFF_BASE_S"
    else
      new_s=$(( prev_s * 2 ))
      [ "$new_s" -gt "$BACKOFF_CAP_S" ] && new_s="$BACKOFF_CAP_S"
    fi
    state_merge "{\"backoff\": {\"$reason\": {\"until_epoch\": $(( now + new_s )), \"seconds\": $new_s}}}"
    notify "idle-sentinel: wake reason '$reason' fired $prev_count times with no state change — backing off ${new_s}s"
    SUPPRESS_KIND="backoff-entered(${new_s}s)"
    return 1
  fi
  return 0
}

record_wake() {
  local reason="$1" hash="$2" count
  count=$(state_get "dedup.$reason.count")
  count=$(( ${count:-0} + 1 ))
  state_merge "{\"dedup\": {\"$reason\": {\"hash\": \"$hash\", \"count\": $count}}, \"last_wake\": {\"reason\": \"$reason\", \"issues_hash\": \"$hash\", \"at\": \"$(now_iso)\"}}"
}

# ── mux plumbing ────────────────────────────────────────────────────────────

detect_mux() {
  if [ -n "${AUTOCODER_MUX:-}" ]; then
    echo "$AUTOCODER_MUX"
    return 0
  fi
  local mf_mux=""
  [ -f "$MANIFEST_PATH" ] && mf_mux=$(manifest_get "$MANIFEST_PATH" 'm.get("mux")' 2>/dev/null)
  if [ -n "$mf_mux" ] && [ "$mf_mux" != "None" ]; then
    echo "$mf_mux"
    return 0
  fi
  if cmux_is_running; then echo cmux; return 0; fi
  if herdr_is_running; then echo herdr; return 0; fi
  if command -v tmux >/dev/null 2>&1; then echo tmux; return 0; fi
  return 1
}

capture_target() {
  local mux="$1" target="$2"
  case "$mux" in
    tmux)  run_with_timeout "$AUTOCODER_MUX_TIMEOUT_SECONDS" tmux capture-pane -p -t "$target" 2>/dev/null ;;
    cmux)  run_with_timeout "$AUTOCODER_MUX_TIMEOUT_SECONDS" cmux read-screen --workspace "$target" 2>/dev/null ;;
    herdr) run_with_timeout "$AUTOCODER_MUX_TIMEOUT_SECONDS" herdr pane read "$target" 2>/dev/null ;;
  esac
}

send_shell_line() {
  local mux="$1" target="$2" text="$3"
  case "$mux" in
    tmux)  send_tmux_command "$target" "$text" ;;
    cmux)  send_cmux_command "$target" "$text" ;;
    herdr) send_herdr_command "$target" "$text" ;;
  esac
}

manifest_target_for_mux() {
  local mux="$1"
  [ -f "$MANIFEST_PATH" ] || return 0
  case "$mux" in
    tmux)  manifest_manager_field "$MANIFEST_PATH" tmuxTarget ;;
    cmux)  manifest_manager_field "$MANIFEST_PATH" cmuxWorkspace ;;
    herdr) manifest_manager_field "$MANIFEST_PATH" herdrPane ;;
  esac
}

validate_target() {
  local mux="$1" target="$2"
  [ -n "$target" ] || return 1
  case "$mux" in
    tmux)  validate_tmux_target "$target" 2>/dev/null ;;
    cmux)  validate_cmux_target "$target" 2>/dev/null ;;
    herdr) validate_herdr_target "$target" 2>/dev/null ;;
  esac
}

# ── wake: spawn a real manager (§2) ─────────────────────────────────────────

CONSENT_DIALOG_PATTERN='No, exit|Bypass Permissions|bypass permissions'

build_wake_prompt() {
  local reason="$1" detail="$2"
  # Single argv prompt sequencing both commands (R2-F2 / CDR #9): a fresh
  # `claude --dangerously-skip-permissions <prompt>` — never --resume, never
  # post-spawn send-keys that the consent dialog would eat.
  printf 'Run /autocoder:manager-resume --non-interactive and let it complete. Then run /autocoder:monitor-loop. You were woken by the idle sentinel (reason: %s%s).' \
    "$reason" "${detail:+ — $detail}"
}

# Resolve the manager launch command via the shared lib (single source of
# truth for per-agent commands). Sets MANAGER_LAUNCH_CMD / MANAGER_CMD /
# MANAGER_COMMAND_MODE.
resolve_manager_launch() {
  # shellcheck source=worker-launch-lib.sh
  source "$SCRIPT_DIR/worker-launch-lib.sh"
  resolve_worker_launch "$AGENT_NAME" "$AGENTS_REPO_ROOT" "$MUX" >/dev/null || return 1
  # Sentinel wakes are UNATTENDED: for claude, force argv mode on every mux
  # (R2-F2). worker-launch-lib switches herdr to agent-input for UI reasons
  # (clickable agent list), but text sent after spawn can be eaten by the
  # --dangerously-skip-permissions consent dialog — the exact failure argv
  # mode exists to prevent, and here nobody is watching the pane.
  if [ "$AGENT_NAME" = "claude" ] && [ -n "$MANAGER_LAUNCH_CMD" ]; then
    MANAGER_COMMAND_MODE="argv"
  fi
}

# Ensure a manifest exists so manifest_set_manager has something to update.
# Normal path: start-parallel-agents.sh --manager-only wrote it. Fallback
# (pre-existing session, no manifest): write a minimal one.
ensure_manifest_exists() {
  local tmux_target="$1" cmux_ws="$2" herdr_pane="$3"
  [ -f "$MANIFEST_PATH" ] && return 0
  local src
  src=$(issue_source_resolved)
  local mgr_json
  mgr_json=$(manifest_manager_json shell false shell "$SWARM_STATE_DIR/${SESSION_NAME}.ready.txt" \
    "$tmux_target" "$cmux_ws" "$herdr_pane" "" "" "$MANAGER_MARKER")
  write_swarm_manifest "$MANIFEST_PATH" "$SESSION_NAME" "$PROJECT_ROOT" "$PROJECT_NAME" "$AGENT_NAME" "$MUX" \
    "${src:-github}" "sentinel" "" "${ISSUE_DIR_PATH:-}" "sentinel-$(date +%Y%m%d-%H%M%S)" \
    "$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)" "[]" "$mgr_json" paused
}

# Locate-or-create the manager pane/workspace. Sets WAKE_TARGET and
# WAKE_TARGET_KIND (tmux|cmux|herdr). In dry-run, prints the commands instead.
prepare_manager_target() {
  WAKE_TARGET=""
  local recorded
  recorded=$(manifest_target_for_mux "$MUX")
  if validate_target "$MUX" "$recorded"; then
    WAKE_TARGET="$recorded"
    return 0
  fi

  case "$MUX" in
    tmux)
      if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
        # Session alive but manager pane gone: add a manager window ourselves
        # (going through --manager-only would no-op on an existing session).
        if [ "$DRY_RUN" = true ]; then
          echo "  tmux new-window -t '$SESSION_NAME' -n manager -P -F '#{window_id}'"
          WAKE_TARGET="<new-tmux-pane>"
          return 0
        fi
        local win
        win=$(tmux new-window -t "$SESSION_NAME" -n manager -P -F '#{window_id}') || return 1
        WAKE_TARGET=$(tmux display-message -p -t "$win" '#{pane_id}') || return 1
        send_tmux_command "$WAKE_TARGET" "cd '$PROJECT_ROOT'"
        return 0
      fi
      # No session at all (host reboot): bootstrap via --manager-only (CDR #4)
      # — manifest with a manager entry only, zero workers, no auto-dispatch.
      if [ "$DRY_RUN" = true ]; then
        echo "  (cd '$PROJECT_ROOT' && '$SCRIPT_DIR/start-parallel-agents.sh' --manager-only --mux tmux --agent '$AGENT_NAME')"
        WAKE_TARGET="<bootstrap-tmux-pane>"
        return 0
      fi
      (cd "$PROJECT_ROOT" && "$SCRIPT_DIR/start-parallel-agents.sh" --manager-only --mux tmux --agent "$AGENT_NAME") || return 1
      WAKE_TARGET=$(manifest_target_for_mux tmux)
      validate_target tmux "$WAKE_TARGET"
      return $?
      ;;
    cmux|herdr)
      # Workspace muxes have no session concept. If a manifest exists, create
      # only the manager workspace (preserving worker entries); bootstrap via
      # --manager-only only when there is no manifest at all.
      if [ ! -f "$MANIFEST_PATH" ]; then
        if [ "$DRY_RUN" = true ]; then
          echo "  (cd '$PROJECT_ROOT' && '$SCRIPT_DIR/start-parallel-agents.sh' --manager-only --mux $MUX --agent '$AGENT_NAME')"
          WAKE_TARGET="<bootstrap-$MUX-workspace>"
          return 0
        fi
        (cd "$PROJECT_ROOT" && "$SCRIPT_DIR/start-parallel-agents.sh" --manager-only --mux "$MUX" --agent "$AGENT_NAME") || return 1
        WAKE_TARGET=$(manifest_target_for_mux "$MUX")
        validate_target "$MUX" "$WAKE_TARGET"
        return $?
      fi
      if [ "$DRY_RUN" = true ]; then
        if [ "$MUX" = cmux ]; then
          echo "  cmux new-workspace --cwd '$PROJECT_ROOT'   # then rename manager-$PROJECT_NAME"
        else
          echo "  herdr workspace create --cwd '$PROJECT_ROOT' --label 'manager-$PROJECT_NAME' --no-focus"
        fi
        WAKE_TARGET="<new-$MUX-workspace>"
        return 0
      fi
      if [ "$MUX" = cmux ]; then
        local out
        out=$(cmux new-workspace --cwd "$PROJECT_ROOT") || return 1
        WAKE_TARGET=$(echo "$out" | grep -o 'workspace:[0-9]*')
        [ -n "$WAKE_TARGET" ] || return 1
        cmux rename-workspace --workspace "$WAKE_TARGET" "manager-${PROJECT_NAME}" >/dev/null 2>&1 || true
      else
        WAKE_TARGET=$(herdr workspace create --cwd "$PROJECT_ROOT" --label "manager-${PROJECT_NAME}" --no-focus |
          python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["root_pane"]["pane_id"])' 2>/dev/null)
        [ -n "$WAKE_TARGET" ] || return 1
      fi
      return 0
      ;;
  esac
  return 1
}

# Verify the freshly-spawned manager actually started working (R2-F2):
# marker pid within the activity window, then a consent-dialog check.
# Returns: 0 started, 1 no activity, 2 consent dialog visible.
verify_manager_started() {
  local target="$1" pid cap
  if ! pid=$(wait_for_manager_pid "$SESSION_NAME" "$ACTIVITY_TIMEOUT_S"); then
    # No marker process: either nothing launched or it died instantly. A
    # visible consent dialog is still worth distinguishing.
    cap=$(capture_target "$MUX" "$target")
    if printf '%s' "$cap" | grep -Eq "$CONSENT_DIALOG_PATTERN"; then
      return 2
    fi
    return 1
  fi
  SPAWNED_PID="$pid"
  SPAWNED_PID_START=$(process_start_time "$pid") || SPAWNED_PID_START=""
  sleep 3
  cap=$(capture_target "$MUX" "$target")
  if printf '%s' "$cap" | grep -Eq "$CONSENT_DIALOG_PATTERN"; then
    return 2
  fi
  return 0
}

record_spawn_in_manifest() {
  local pid="$1" start="$2"
  local tmux_t="" cmux_w="" herdr_p=""
  case "$MUX" in
    tmux)  tmux_t="$WAKE_TARGET" ;;
    cmux)  cmux_w="$WAKE_TARGET" ;;
    herdr) herdr_p="$WAKE_TARGET" ;;
  esac
  local json
  json=$(manifest_manager_json interactive true shell "$SWARM_STATE_DIR/${SESSION_NAME}.ready.txt" \
    "$tmux_t" "$cmux_w" "$herdr_p" "$pid" "$start" "$MANAGER_MARKER")
  manifest_set_manager "$MANIFEST_PATH" "$json"
}

# The dispatch itself: env exports then the argv-mode launch. Factored out so
# the wake path can retry it once (§2.4) and --dry-run can print it.
dispatch_manager() {
  local prompt="$1"
  local launch_line
  if [ "$MANAGER_COMMAND_MODE" = "argv" ] && [ -n "$MANAGER_LAUNCH_CMD" ]; then
    launch_line="$MANAGER_LAUNCH_CMD $(printf '%q' "$prompt")"
  elif [ -n "$MANAGER_LAUNCH_CMD" ]; then
    # Non-argv interactive agents (gemini/codex): launch, settle, then type
    # the prompt. Claude never takes this path (argv is the dialog-safe one).
    launch_line="$MANAGER_LAUNCH_CMD"
  else
    # Shell-mode managers (pi/droid): the manager command IS a shell command.
    launch_line="$MANAGER_CMD"
  fi

  if [ "$DRY_RUN" = true ]; then
    echo "  # sent to the manager pane/workspace ($MUX -> $WAKE_TARGET):"
    echo "  export $MANAGER_MARKER AUTOCODER_UNATTENDED=1"
    echo "  $launch_line"
    if [ "$MANAGER_COMMAND_MODE" != "argv" ] && [ -n "$MANAGER_LAUNCH_CMD" ]; then
      echo "  # then, after the TUI settles:"
      echo "  <send prompt> $prompt"
    fi
    return 0
  fi

  # Spawn env (R2-F5): identity marker + unattended policy, exported in the
  # pane shell BEFORE the agent launches so /proc environ carries both.
  send_shell_line "$MUX" "$WAKE_TARGET" "export $MANAGER_MARKER AUTOCODER_UNATTENDED=1" || return 1
  send_shell_line "$MUX" "$WAKE_TARGET" "$launch_line" || return 1
  if [ "$MANAGER_COMMAND_MODE" != "argv" ] && [ -n "$MANAGER_LAUNCH_CMD" ] && [ -n "$MANAGER_CMD" ]; then
    sleep 5
    case "$MUX" in
      tmux)  send_tmux_text_enter "$WAKE_TARGET" "$MANAGER_CMD" ;;
      cmux)  send_cmux_command "$WAKE_TARGET" "$MANAGER_CMD" ;;
      herdr) prompt_herdr_agent "$WAKE_TARGET" "$MANAGER_CMD" || send_herdr_command "$WAKE_TARGET" "$MANAGER_CMD" ;;
    esac
  fi
  return 0
}

do_wake() {
  local reason="$1" detail="$2"
  local wake_started="$SECONDS"
  SPAWNED_PID=""
  SPAWNED_PID_START=""

  MUX=$(detect_mux) || {
    notify "idle-sentinel: wake ($reason) failed — no multiplexer available"
    TICK_RESULT="wake-failed:$reason"
    return 1
  }
  resolve_manager_launch || {
    notify "idle-sentinel: wake ($reason) failed — cannot resolve $AGENT_NAME launch command"
    TICK_RESULT="wake-failed:$reason"
    return 1
  }
  local prompt
  prompt=$(build_wake_prompt "$reason" "$detail")

  if [ "$DRY_RUN" = true ]; then
    echo ""
    echo "DRY-RUN wake plan (mux=$MUX, session=$SESSION_NAME, reason=$reason):"
    prepare_manager_target || { echo "  (no way to create a manager pane)"; return 1; }
    dispatch_manager "$prompt"
    echo "  # then: record pid+start-time+marker in $MANIFEST_PATH (manifest_set_manager),"
    echo "  # verify activity within ${ACTIVITY_TIMEOUT_S}s (consent dialog = bootstrap failure),"
    echo "  # whole wake capped at ${WAKE_TIMEOUT_S}s."
    TICK_RESULT="wake:$reason(dry-run)"
    return 0
  fi

  prepare_manager_target || {
    notify "idle-sentinel: wake ($reason) failed — could not create/locate manager pane on $MUX"
    TICK_RESULT="wake-failed:$reason"
    return 1
  }
  ensure_manifest_exists \
    "$([ "$MUX" = tmux ] && echo "$WAKE_TARGET")" \
    "$([ "$MUX" = cmux ] && echo "$WAKE_TARGET")" \
    "$([ "$MUX" = herdr ] && echo "$WAKE_TARGET")"

  # R2-F8: a surviving counter would let the woken manager step down after a
  # single iteration.
  : > "$QUIESCENT_FILE"

  log_event "WAKE dispatching manager (reason=$reason mux=$MUX target=$WAKE_TARGET)"
  local attempt rc=1
  for attempt in 1 2; do
    if [ $((SECONDS - wake_started)) -ge "$WAKE_TIMEOUT_S" ]; then
      log_event "WAKE ceiling (${WAKE_TIMEOUT_S}s) reached before attempt $attempt"
      break
    fi
    dispatch_manager "$prompt" || { log_event "WAKE dispatch attempt $attempt failed to send"; continue; }
    verify_manager_started "$WAKE_TARGET"
    rc=$?
    if [ "$rc" -eq 0 ]; then
      record_spawn_in_manifest "$SPAWNED_PID" "$SPAWNED_PID_START"
      record_wake "$reason" "$WAKE_HASH"
      log_event "WAKE manager started (pid=$SPAWNED_PID reason=$reason attempt=$attempt)"
      # Consume the operator wake file only once the wake actually succeeded.
      [ "$reason" = "wake-file" ] && rm -f "$WAKE_FILE"
      if [ "$reason" = "duty" ]; then
        state_merge "{\"last_duty_wake_at\": \"$(now_iso)\"}"
        # All standing conditions expire at each duty wake (R2-F9); the next
        # handoff must re-declare the ones that still hold.
        remove_standing_lines all
      fi
      TICK_RESULT="wake:$reason"
      return 0
    fi
    if [ "$rc" -eq 2 ]; then
      # Consent dialog visible: bootstrap-configuration failure. Do NOT
      # retry (retrying re-answers the dialog) and do NOT kill — a human can
      # still accept it. Back off this reason so we don't flap (R2-F2).
      state_merge "{\"consent_dialog_at\": \"$(now_iso)\", \"backoff\": {\"$reason\": {\"until_epoch\": $(( $(now_epoch) + BACKOFF_CAP_S )), \"seconds\": $BACKOFF_CAP_S}}}"
      notify "idle-sentinel: consent dialog detected on manager spawn — bootstrap configuration failure; accept the dialog manually or fix the launch config"
      TICK_RESULT="wake-failed:consent-dialog"
      return 1
    fi
    log_event "WAKE attempt $attempt: no manager activity within ${ACTIVITY_TIMEOUT_S}s"
  done

  # Failed for good: kill only what WE spawned (marker+pid verified), clear
  # the manifest entry, notify, keep polling (CDR #1). A failed wake must
  # never leave a zombie pane that blocks all future wakes.
  local pid
  if pid=$(manager_pid_by_marker "$SESSION_NAME") && pid_cwd_in_root "$pid"; then
    kill_pid_verified "$pid" "$(process_start_time "$pid" 2>/dev/null)"
    log_event "WAKE killed own failed spawn pid=$pid"
  fi
  clear_manifest_manager "failed wake cleanup"
  notify "idle-sentinel: wake ($reason) FAILED after retry — killed own spawn, resuming polling"
  TICK_RESULT="wake-failed:$reason"
  return 1
}

# ── observe mode (CDR #11; R2-F3) ───────────────────────────────────────────
# A verified manager is alive: never wake-spawn. Health red → alert file +
# notify. Wedged manager (stale heartbeat AND no in-flight gate/deploy AND
# static pane) → kill, sweep git locks, respawn.

observe_health() {
  declare -F sentinel_health_probe >/dev/null 2>&1 || return 0
  local out
  if out=$( (sentinel_health_probe) 2>&1 ); then
    return 0
  fi
  if [ "$DRY_RUN" = true ]; then
    echo "DRY-RUN would write health-alert (probe red)"
    return 0
  fi
  local fresh=false
  [ -f "$HEALTH_ALERT_FILE" ] || fresh=true
  {
    echo "at: $(now_iso)"
    echo "probe: sentinel_health_probe (red)"
    echo "output:"
    printf '%s\n' "$out"
  } > "$HEALTH_ALERT_FILE"
  # health-alert's READER is monitor-workers (R2-F10): it reads, acts, and
  # deletes. Notify only when the alert is new, not every tick it persists.
  [ "$fresh" = true ] && notify "idle-sentinel: health probe RED while manager alive — wrote .autocoder/health-alert"
  return 0
}

manager_pane_static() {
  # Two captures across a settle window; identical output = static. When no
  # pane target is known, fall back to CPU-time delta on the pid.
  local target
  target=$(manifest_target_for_mux "$MUX_OBS" 2>/dev/null)
  if validate_target "$MUX_OBS" "$target" 2>/dev/null; then
    local c1 c2
    c1=$(capture_target "$MUX_OBS" "$target")
    sleep 8
    c2=$(capture_target "$MUX_OBS" "$target")
    [ "$c1" = "$c2" ]
    return $?
  fi
  local t1 t2
  if [ -r "/proc/$MANAGER_PID/stat" ]; then
    t1=$(awk '{ sub(/.*\) /, ""); print $12 + $13 }' "/proc/$MANAGER_PID/stat" 2>/dev/null)
    sleep 8
    t2=$(awk '{ sub(/.*\) /, ""); print $12 + $13 }' "/proc/$MANAGER_PID/stat" 2>/dev/null)
  else
    t1=$(ps -o time= -p "$MANAGER_PID" 2>/dev/null)
    sleep 8
    t2=$(ps -o time= -p "$MANAGER_PID" 2>/dev/null)
  fi
  [ -n "$t1" ] && [ "$t1" = "$t2" ]
}

sweep_git_locks() {
  # A kill mid-git-operation leaves locks the respawned manager trips over.
  # Age-verified: only locks older than GIT_LOCK_AGE_S go.
  local git_dir="$PROJECT_ROOT/.git"
  [ -d "$git_dir" ] || return 0
  local mins=$(( GIT_LOCK_AGE_S / 60 ))
  [ "$mins" -lt 1 ] && mins=1
  if [ "$DRY_RUN" = true ]; then
    find "$git_dir" -maxdepth 1 -name '*.lock' -mmin "+$mins" 2>/dev/null |
      sed 's/^/DRY-RUN would remove stale git lock: /'
    return 0
  fi
  local f
  while IFS= read -r f; do
    rm -f "$f" && log_event "SWEPT stale git lock $f"
  done < <(find "$git_dir" -maxdepth 1 -name '*.lock' -mmin "+$mins" 2>/dev/null)
}

observe_tick() {
  TICK_RESULT="observe"
  observe_health

  # Heartbeat monitor. Baseline: heartbeat file mtime, else the manifest's
  # spawned_at (a just-woken manager has not written one yet).
  local hb_epoch="" spawned
  if [ -f "$HEARTBEAT_FILE" ]; then
    hb_epoch=$(file_mtime "$HEARTBEAT_FILE")
  else
    spawned=$(manifest_manager_field "$MANIFEST_PATH" spawned_at)
    [ -n "$spawned" ] && hb_epoch=$(iso_to_epoch "$spawned")
  fi
  [ -n "$hb_epoch" ] || return 0

  local age=$(( $(now_epoch) - hb_epoch ))
  local threshold=$(( 3 * INTERVAL_S ))
  [ "$age" -gt "$threshold" ] || return 0

  # Stale heartbeat alone is POSSIBLY wedged. Kill only when ALL hold: no
  # gate/deploy from this checkout (one iteration legitimately blocks >45min
  # inside a merge gate) AND the pane/process is static across two captures.
  if inflight_detected; then
    log_event "HEARTBEAT stale (${age}s) but gate/deploy in flight — not touching the manager"
    return 0
  fi
  MUX_OBS=$(detect_mux) || MUX_OBS=""
  if ! manager_pane_static; then
    log_event "HEARTBEAT stale (${age}s) but manager shows activity — leaving it alone"
    return 0
  fi

  if [ "$DRY_RUN" = true ]; then
    echo "DRY-RUN would kill wedged manager pid=$MANAGER_PID and respawn"
    return 0
  fi
  notify "idle-sentinel: manager heartbeat ${age}s stale, no in-flight work, pane static — killing pid $MANAGER_PID and respawning"
  kill_pid_verified "$MANAGER_PID" "$MANAGER_PID_START"
  clear_manifest_manager "wedged manager killed"
  sweep_git_locks
  MANAGER_PID=""
  MANAGER_PID_START=""
  WAKE_HASH=$(sha256_of "heartbeat-respawn:")
  do_wake "heartbeat-respawn" "previous manager wedged (heartbeat ${age}s stale)"
}

# ── the tick ────────────────────────────────────────────────────────────────

TICK_RESULT=""
TICK_ERROR_DETAIL=""

run_tick() {
  TICK_RESULT=""
  TICK_ERROR_DETAIL=""
  PREDICATE_SUMMARY=""
  truncate_log_if_large

  ISSUE_SOURCE_KIND=$(issue_source_resolved)

  # Contended-lock SKIPs since the last completed tick count toward the error
  # tolerance (a permanently held lock must not read as green).
  local skips=0 consec
  if [ -f "$SKIP_FILE" ] && [ "$DRY_RUN" != true ]; then
    skips=$(wc -l < "$SKIP_FILE" 2>/dev/null || echo 0)
    rm -f "$SKIP_FILE"
  fi
  consec=$(state_get consecutive_errors)
  consec=$(( ${consec:-0} + skips ))

  local tick_errors=0
  self_check_tools || tick_errors=$((tick_errors + 1))
  pin_gh_token || tick_errors=$((tick_errors + 1))

  if manager_alive; then
    orphan_sweep
    observe_tick
    # A verified live manager means the system is not blind: error streak ends.
    state_merge "{\"consecutive_errors\": 0, \"last_tick_at\": \"$(now_iso)\", \"last_tick_result\": \"$TICK_RESULT\"}"
    log_event "TICK result=$TICK_RESULT mode=observe manager_pid=${MANAGER_PID:-?}"
    return 0
  fi
  orphan_sweep

  if [ "$tick_errors" -eq 0 ]; then
    evaluate_predicate
    tick_errors=$((tick_errors + PROBE_ERRORS))
  else
    PREDICATE_SUMMARY="skipped ($TICK_ERROR_DETAIL)"
    WAKE_REASON=""
    WAKE_ISSUES=""
  fi

  if [ -n "$WAKE_REASON" ]; then
    WAKE_HASH=$(sha256_of "$WAKE_REASON:$(echo $WAKE_ISSUES | tr ' ' ',')")
    if dedup_gate "$WAKE_REASON" "$WAKE_HASH"; then
      do_wake "$WAKE_REASON" "$WAKE_DETAIL"
    else
      TICK_RESULT="backoff:$WAKE_REASON"
      log_event "BACKOFF suppressed wake reason=$WAKE_REASON $SUPPRESS_KIND"
    fi
    # Work (or an attempt at it) was found: the error streak is over.
    consec=0
  elif [ "$tick_errors" -gt 0 ]; then
    consec=$((consec + 1))
    TICK_RESULT="error"
    log_event "TICK probe errors=$tick_errors detail='${TICK_ERROR_DETAIL:-backend}' consecutive=$consec"
    if [ "$consec" -ge "$ERROR_TOLERANCE" ]; then
      # Probe errors are NEVER quiescence (CDR #7): wake the manager — it can
      # diagnose — and fire the notify hook.
      notify "idle-sentinel: $consec consecutive errored ticks — escalation wake"
      WAKE_HASH=$(sha256_of "error-escalation:")
      if dedup_gate "error-escalation" "$WAKE_HASH"; then
        do_wake "error-escalation" "$consec consecutive errored sentinel ticks (${TICK_ERROR_DETAIL:-probe failures})"
        [ "$TICK_RESULT" = "wake:error-escalation" ] && consec=0
      else
        TICK_RESULT="backoff:error-escalation"
      fi
    fi
  else
    TICK_RESULT="quiescent"
    consec=0
  fi

  state_merge "{\"consecutive_errors\": $consec, \"last_tick_at\": \"$(now_iso)\", \"last_tick_result\": \"$TICK_RESULT\"}"
  log_event "TICK result=$TICK_RESULT predicate=[$PREDICATE_SUMMARY]"
}

# Whole tick body under a NON-BLOCKING lock (R2-F7): a contended tick SKIPs —
# logged and counted — rather than queueing behind a hung wake forever while
# cron reports green.
run_locked_tick() {
  if [ "$DRY_RUN" = true ]; then
    # Read-only evaluation: no lock, no writes.
    run_tick
    return $?
  fi
  mkdir -p "$AC_DIR"
  local locked=false
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK_FILE"
    if flock -n 9; then
      locked=true
    fi
  else
    # darwin has no flock(1): mkdir is the portable atomic fallback. Steal
    # only when the holder is provably dead and the lock is old.
    local lock_dir="$LOCK_FILE.d"
    if mkdir "$lock_dir" 2>/dev/null; then
      echo "$$" > "$lock_dir/pid"
      trap 'rm -rf "$LOCK_FILE.d"' EXIT
      locked=true
    else
      local holder age
      holder=$(cat "$lock_dir/pid" 2>/dev/null)
      age=$(( $(now_epoch) - $(file_mtime "$lock_dir" 2>/dev/null || now_epoch) ))
      if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null && [ "$age" -gt $(( 2 * WAKE_TIMEOUT_S )) ]; then
        rm -rf "$lock_dir"
        if mkdir "$lock_dir" 2>/dev/null; then
          echo "$$" > "$lock_dir/pid"
          trap 'rm -rf "$LOCK_FILE.d"' EXIT
          locked=true
        fi
      fi
    fi
  fi
  if [ "$locked" != true ]; then
    printf '%s TICK result=skip (tick lock contended)\n' "$(now_iso)" >> "$LOG_FILE"
    echo 1 >> "$SKIP_FILE"
    return 0
  fi
  run_tick
}

# ── --ensure: idempotent scheduler install/check (CDR #2) ───────────────────

CRON_MARK="# autocoder-idle-sentinel:$PROJECT_ROOT"

detect_scheduler() {
  # Prints cron|systemd|loop|none. Never installs anything.
  if command -v crontab >/dev/null 2>&1 && crontab -l 2>/dev/null | grep -Fq "$CRON_MARK"; then
    echo cron
    return 0
  fi
  if command -v systemctl >/dev/null 2>&1 &&
     systemctl --user list-timers --all 2>/dev/null | grep -Eq 'autocoder-(idle-)?sentinel'; then
    echo systemd
    return 0
  fi
  local pid cmdline
  for pid in $(pgrep -f 'idle-sentine[l]' 2>/dev/null); do
    [ "$pid" = "$$" ] && continue
    if [ -d /proc/self ]; then
      cmdline=$(tr '\0' ' ' 2>/dev/null < "/proc/$pid/cmdline")
    else
      cmdline=$(ps -o command= -p "$pid" 2>/dev/null)
    fi
    case "$cmdline" in
      *--loop*)
        if pid_cwd_in_root "$pid" || [[ "$cmdline" == *"$PROJECT_ROOT"* ]]; then
          echo loop
          return 0
        fi
        ;;
    esac
  done
  echo none
}

cmd_ensure() {
  mkdir -p "$AC_DIR"
  local existing
  existing=$(detect_scheduler)
  if [ "$existing" != none ]; then
    echo "✅ Sentinel already scheduled via $existing — nothing to install"
    state_merge "{\"scheduler_mode\": \"$existing\"}"
    return 0
  fi

  if command -v crontab >/dev/null 2>&1; then
    local mins=$(( INTERVAL_S / 60 ))
    [ "$mins" -lt 1 ] && mins=1
    local sched
    if [ "$mins" -ge 60 ]; then
      sched="0 */$(( mins / 60 )) * * *"
    else
      sched="*/$mins * * * *"
    fi
    local line="$sched cd '$PROJECT_ROOT' && '$SELF_PATH' --once >> '$AC_DIR/sentinel.cron.log' 2>&1 $CRON_MARK"
    if [ "$DRY_RUN" = true ]; then
      echo "DRY-RUN would install crontab entry:"
      echo "  $line"
      return 0
    fi
    ( crontab -l 2>/dev/null; echo "$line" ) | crontab - || {
      echo "❌ crontab install failed" >&2
      return 1
    }
    state_merge "{\"scheduler_mode\": \"cron\"}"
    log_event "ENSURE installed cron entry ($sched)"
    echo "✅ Installed cron entry: $line"
    return 0
  fi

  # No crontab available: fall back to a detached loop (recorded, so a later
  # --ensure will find it and not double-install).
  if [ "$DRY_RUN" = true ]; then
    echo "DRY-RUN would start: nohup '$SELF_PATH' --loop --project '$PROJECT_ROOT' &"
    return 0
  fi
  nohup "$SELF_PATH" --loop --project "$PROJECT_ROOT" >> "$AC_DIR/sentinel.cron.log" 2>&1 &
  disown
  state_merge "{\"scheduler_mode\": \"loop\"}"
  log_event "ENSURE started detached --loop (pid $!)"
  echo "✅ No cron available — started a detached --loop (pid $!)"
}

# ── main ────────────────────────────────────────────────────────────────────

case "$MODE" in
  ensure)
    cmd_ensure
    ;;
  once)
    [ "$DRY_RUN" != true ] && state_merge "{\"version\": 1}"
    run_locked_tick
    ;;
  loop)
    existing=$(detect_scheduler)
    if [ "$existing" = cron ] || [ "$existing" = systemd ]; then
      echo "❌ Refusing --loop: sentinel already scheduled via $existing (never both)" >&2
      exit 1
    fi
    state_merge "{\"scheduler_mode\": \"loop\"}"
    log_event "LOOP started (interval ${INTERVAL_S}s, pid $$)"
    while :; do
      run_locked_tick
      sleep "$INTERVAL_S"
    done
    ;;
esac
