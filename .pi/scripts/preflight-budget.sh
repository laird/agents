#!/usr/bin/env bash
# preflight-budget.sh — host-wide admission for preflights, and one host-exclusive stage at a time.
#
# Source it for the functions, or run it as a command:
#
#   preflight-budget.sh run [--priority hotfix|ordinary] [--branch B] [--what TEXT] -- CMD [ARG...]
#       take a preflight slot (waiting in line for one), run CMD holding it, release it; CMD's exit
#   preflight-budget.sh exclusive --name NAME [--role gate|preflight] [--waited-file F] -- CMD [ARG...]
#       take the host-exclusive lock NAME, run CMD holding it, release it; CMD's exit
#   preflight-budget.sh status
#       the slots and who holds them, the waiters in order, the host-exclusive locks held or wanted
#
# WHY. A worker runs a preflight (enqueue.sh --preflight-cmd, or a repository's own bank script)
# before it posts READY. Several workers on one host each run one, beside the gate, and nothing
# bounded them: the wait for room was a race with no order and no priority (a red integration
# branch's hotfix preflight waited behind two ordinary preflights that started after it, with every
# train held), and the bound that did exist counted memory only, so three whole-tree typechecks
# (two preflights and the batch's gate) saturated the cores and the gate's own timed out. This file
# is that bound, generic: slots sized from the gate's memory cap and the host's memory, a waiter
# line ordered by priority then arrival, admission on CPU load as well as memory, and one lock per
# host-exclusive stage that the gate takes ahead of any preflight.
#
# THE BUDGET
#   slots    = AUTOCODER_PREFLIGHT_SLOTS, else floor((MemTotal - reserve - running gates x gate cap) / slot),
#              never under 1 (a host too small for the arithmetic still runs one preflight at a time)
#   reserve  = AUTOCODER_PREFLIGHT_RESERVE_GIB (default 4): memory the host keeps for everything else
#   gate cap = AUTOCODER_PREFLIGHT_GATE_CAP_MIB, else (MemTotal - reserve) / AUTOCODER_PREFLIGHT_GATE_CEILING
#              (default 3), never under AUTOCODER_PREFLIGHT_GATE_CAP_FLOOR_MIB (default 4096): what one
#              gate may hold, the cap a project's gate launcher sets
#   slot     = AUTOCODER_PREFLIGHT_SLOT_MIB, else the gate cap: a preflight runs the gate's stages, so it
#              needs what a gate needs
#   gates    = the output of AUTOCODER_PREFLIGHT_GATES_CMD (a command printing how many gates run now),
#              else 0
# The arithmetic is recomputed at every poll: a waiter that arrived beside running gates widens to
# the slots the host has once they end.
#
# THE LINE. A waiter takes a TICKET `+<rank>-<arrival ns>-<pid>.ticket` under <dir>/queue, and only
# the oldest live ticket tries the slots, so a later preflight never passes an earlier one. Rank 0 is
# a hotfix (`--priority hotfix`, AUTOCODER_PREFLIGHT_PRIORITY=hotfix, or a `hotfix/*` branch), rank 1
# everything else: the name sort puts every hotfix ahead of every ordinary waiter and keeps arrival
# order within a rank. A ticket or a slot is never claimed by `mkdir`'s exit status (uutils coreutils
# can grant it to two racers): tickets are `set -o noclobber` redirections, slots are `flock`, held on
# an open descriptor the kernel releases the instant the holder dies. A dead holder (pid gone, or the
# pid recycled: its start time differs) is swept by whoever finds it.
#
# ADMISSION ON CPU. No preflight starts while the host's 1-minute load average is over the core
# count x AUTOCODER_PREFLIGHT_LOAD_FACTOR (default 1.0; `off` disables the rule), and no second one
# within AUTOCODER_PREFLIGHT_ADMISSION_GAP_S (default 60) of the last admission, because the 1-minute
# load lags an admission. The wait line says why ("load 41.2 over 16 cores x 1.0"). A hotfix obeys the
# rule and is first when the load clears. Seams: AUTOCODER_LOADAVG_FILE (default /proc/loadavg),
# AUTOCODER_HOST_CORES (default nproc), AUTOCODER_PREFLIGHT_MEMINFO_FILE (default /proc/meminfo).
#
# THE WAIT. A poll every AUTOCODER_PREFLIGHT_POLL_S (default 15) seconds, bounded by
# AUTOCODER_PREFLIGHT_WAIT_MAX_S (default 7200, generous on purpose: a wait is never an SLA); past the
# bound the run fails loudly naming the holders and the reason, and runs nothing.
#
# HOST-EXCLUSIVE STAGES. `host_exclusive_lock NAME ROLE` takes <dir>/exclusive/NAME.lock. The GATE's
# run (role gate) writes a `.wants.<pid>` marker while it waits and is admitted ahead of every waiting
# preflight; a PREFLIGHT (role preflight) yields while any live gate marker exists. The stage runner
# takes it for a manifest stage marked "host_exclusive": true (role AUTOCODER_HOST_EXCLUSIVE_ROLE,
# default gate; enqueue.sh exports preflight for a project's preflight), and a repository's own
# script can take it for the same stage names. Bounded by AUTOCODER_HOST_EXCLUSIVE_WAIT_MAX_S (default
# 7200; exit 125 past it, naming the holder), polled every AUTOCODER_HOST_EXCLUSIVE_POLL_S (default 5).
#
# WHERE. <dir> is AUTOCODER_PREFLIGHT_DIR, default ${XDG_STATE_HOME:-$HOME/.local/state}/autocoder/preflight-budget.
# A host whose workers run under several accounts points every account at one shared directory.
#
# Every line this file prints goes to stderr, prefixed `preflight budget:`, so a caller that reads
# CMD's stdout reads only CMD's.

_pfb_DIR_DEFAULT="${XDG_STATE_HOME:-$HOME/.local/state}/autocoder/preflight-budget"
_pfb_NAME_RE='^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'

pfb_say() { printf 'preflight budget: %s\n' "$*" >&2; }
pfb_dir() { printf '%s' "${AUTOCODER_PREFLIGHT_DIR:-$_pfb_DIR_DEFAULT}"; }
pfb_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# pfb_uint VALUE DEFAULT -- VALUE when it is a non-negative integer, else DEFAULT.
pfb_uint() { if [[ "${1:-}" =~ ^[0-9]+$ ]]; then printf '%s' "$1"; else printf '%s' "$2"; fi; }
# pfb_decimal VALUE DEFAULT -- VALUE when it is a non-negative decimal, else DEFAULT.
pfb_decimal() { if [[ "${1:-}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then printf '%s' "$1"; else printf '%s' "$2"; fi; }

# ── the host ──────────────────────────────────────────────────────────────────────────────────
# pfb_host_memory_kib -- MemTotal in KiB (the meminfo seam, else sysctl on a host without /proc), or nothing.
pfb_host_memory_kib() {
  local file="${AUTOCODER_PREFLIGHT_MEMINFO_FILE:-/proc/meminfo}" v
  v="$(awk '/^MemTotal:/ {print $2; exit}' "$file" 2>/dev/null || true)"
  if ! [[ "$v" =~ ^[0-9]+$ ]] && [ ! -e "$file" ] && command -v sysctl >/dev/null 2>&1; then
    v="$(sysctl -n hw.memsize 2>/dev/null || true)"; [[ "$v" =~ ^[0-9]+$ ]] && v=$(( v / 1024 ))
  fi
  [[ "$v" =~ ^[0-9]+$ ]] && printf '%s' "$v"
  return 0
}

# pfb_load1 -- the host's 1-minute load average as a decimal, or nothing when unreadable.
pfb_load1() {
  local v; v="$(awk '{print $1; exit}' "${AUTOCODER_LOADAVG_FILE:-/proc/loadavg}" 2>/dev/null || true)"
  [[ "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]] && printf '%s' "$v"
  return 0
}

# pfb_cores -- the core count (AUTOCODER_HOST_CORES, else nproc, else sysctl), 1 when unknown.
pfb_cores() {
  local n="${AUTOCODER_HOST_CORES:-}"
  [[ "$n" =~ ^[1-9][0-9]*$ ]] || n="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || true)"
  [[ "$n" =~ ^[1-9][0-9]*$ ]] || n=1
  printf '%s' "$n"
}

# pfb_running_gates -- what AUTOCODER_PREFLIGHT_GATES_CMD prints, when it prints a count; else 0.
pfb_running_gates() {
  local n=""
  [ -z "${AUTOCODER_PREFLIGHT_GATES_CMD:-}" ] || n="$(bash -c "$AUTOCODER_PREFLIGHT_GATES_CMD" 2>/dev/null | tail -1 | tr -d '[:space:]')"
  pfb_uint "$n" 0
}

# ── the arithmetic (pure) ─────────────────────────────────────────────────────────────────────
# pfb_gate_cap_mib TOTAL_KIB RESERVE_GIB CEILING FLOOR_MIB -- (total - reserve) / ceiling, never under the floor.
pfb_gate_cap_mib() {
  local total_kib="$1" reserve_gib="$2" ceiling="$3" floor="$4" cap
  [[ "$total_kib" =~ ^[0-9]+$ ]] || { printf '%s' "$floor"; return 0; }
  cap=$(( (total_kib / 1024 - reserve_gib * 1024) / ceiling ))
  (( cap < floor )) && cap="$floor"
  printf '%s' "$cap"
}

# pfb_slot_count TOTAL_KIB RESERVE_GIB GATES GATE_CAP_MIB SLOT_MIB -- floor((total - reserve - gates x cap) / slot), never under 1.
pfb_slot_count() {
  local total_kib="$1" reserve_gib="$2" gates="$3" gate_cap="$4" slot="$5" free n
  [[ "$total_kib" =~ ^[0-9]+$ ]] || { echo 1; return 0; }
  [[ "$slot" =~ ^[1-9][0-9]*$ ]] || { echo 1; return 0; }
  free=$(( total_kib / 1024 - reserve_gib * 1024 - gates * gate_cap ))
  n=$(( free / slot ))
  (( n < 1 )) && n=1
  echo "$n"
}

# pfb_compute_slots -- sets PFB_TOTAL_KIB PFB_RESERVE_GIB PFB_GATES PFB_GATE_CAP_MIB PFB_SLOT_MIB PFB_SLOTS from
# the configuration and the host as they are now.
pfb_compute_slots() {
  PFB_TOTAL_KIB="$(pfb_host_memory_kib)"
  PFB_RESERVE_GIB="$(pfb_uint "${AUTOCODER_PREFLIGHT_RESERVE_GIB:-}" 4)"
  PFB_GATES="$(pfb_running_gates)"
  PFB_GATE_CAP_MIB="$(pfb_uint "${AUTOCODER_PREFLIGHT_GATE_CAP_MIB:-}" 0)"
  [ "$PFB_GATE_CAP_MIB" -gt 0 ] || PFB_GATE_CAP_MIB="$(pfb_gate_cap_mib "$PFB_TOTAL_KIB" "$PFB_RESERVE_GIB" \
    "$(pfb_uint "${AUTOCODER_PREFLIGHT_GATE_CEILING:-}" 3)" "$(pfb_uint "${AUTOCODER_PREFLIGHT_GATE_CAP_FLOOR_MIB:-}" 4096)")"
  PFB_SLOT_MIB="$(pfb_uint "${AUTOCODER_PREFLIGHT_SLOT_MIB:-}" 0)"
  [ "$PFB_SLOT_MIB" -gt 0 ] || PFB_SLOT_MIB="$PFB_GATE_CAP_MIB"
  PFB_SLOTS="$(pfb_uint "${AUTOCODER_PREFLIGHT_SLOTS:-}" 0)"
  [ "$PFB_SLOTS" -gt 0 ] || PFB_SLOTS="$(pfb_slot_count "$PFB_TOTAL_KIB" "$PFB_RESERVE_GIB" "$PFB_GATES" "$PFB_GATE_CAP_MIB" "$PFB_SLOT_MIB")"
}

# pfb_budget_line -- the one line that says how the slots were sized.
pfb_budget_line() {
  local total="unknown"
  [[ "${PFB_TOTAL_KIB:-}" =~ ^[0-9]+$ ]] && total="$(( PFB_TOTAL_KIB / 1024 / 1024 )) GiB"
  if [[ "${AUTOCODER_PREFLIGHT_SLOTS:-}" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s slot(s) (AUTOCODER_PREFLIGHT_SLOTS; MemTotal %s, %s MiB per slot)' "$PFB_SLOTS" "$total" "$PFB_SLOT_MIB"
  else
    printf '%s slot(s) (MemTotal %s, reserve %s GiB, %s running gate(s) x %s MiB cap, %s MiB per slot)' \
      "$PFB_SLOTS" "$total" "$PFB_RESERVE_GIB" "$PFB_GATES" "$PFB_GATE_CAP_MIB" "$PFB_SLOT_MIB"
  fi
}

# ── CPU admission ─────────────────────────────────────────────────────────────────────────────
# pfb_load_factor -- the configured factor, or `off`.
pfb_load_factor() {
  local f="${AUTOCODER_PREFLIGHT_LOAD_FACTOR:-1.0}"
  case "$f" in off|none|0|0.0) printf 'off'; return 0 ;; esac
  pfb_decimal "$f" 1.0
}
# pfb_cpu_limit CORES FACTOR -- cores x factor, two decimals.
pfb_cpu_limit() { awk -v c="$1" -v f="$2" 'BEGIN { printf "%.2f", c * f }'; }
# pfb_cpu_over LOAD LIMIT -- 0 when LOAD exceeds LIMIT; 1 otherwise or when LOAD is unknown.
pfb_cpu_over() {
  [[ "${1:-}" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
  [[ "${2:-}" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
  awk -v l="$1" -v m="$2" 'BEGIN { exit (l > m) ? 0 : 1 }'
}
# pfb_cpu_line LOAD CORES FACTOR LIMIT -- the reason line for a CPU refusal.
pfb_cpu_line() { printf 'host 1-minute load %s over %s cores x %s = %s; no new preflight starts until it falls' "$1" "$2" "$3" "$4"; }
# pfb_admission_recent STAMP_FILE GAP_S [NOW_S] -- the seconds since the last admission when under GAP_S; else nothing.
pfb_admission_recent() {
  local last age now="${3:-}"
  [[ "$now" =~ ^[0-9]+$ ]] || now="$(date +%s)"
  last="$(head -1 "$1" 2>/dev/null || true)"
  [[ "$last" =~ ^[0-9]+$ ]] || return 0
  age=$(( now - last ))
  (( age >= 0 && age < $2 )) && printf '%s' "$age"
  return 0
}

# ── pids ──────────────────────────────────────────────────────────────────────────────────────
# pfb_pid_token PID -- `pid@starttime` from /proc (a recycled pid is not the same process), else the bare pid.
pfb_pid_token() {
  local pid="$1" stat start
  if stat="$(cat "/proc/$pid/stat" 2>/dev/null)" && [ -n "$stat" ]; then
    start="$(printf '%s' "${stat##*) }" | awk '{print $20}')"
    [[ "$start" =~ ^[0-9]+$ ]] && { printf '%s@%s' "$pid" "$start"; return 0; }
  fi
  printf '%s' "$pid"
}
# pfb_pid_live TOKEN -- true when the token's pid is alive (signalable, or present in /proc) and still the same process.
pfb_pid_live() {
  local token="${1:-}" pid="${1%%@*}"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || [ -d "/proc/$pid" ] || return 1
  [[ "$token" == *@* ]] || return 0
  [ "$(pfb_pid_token "$pid")" = "$token" ]
}
# pfb_file_token FILE -- the `token=` of a ticket or holder file, else its `pid=`.
pfb_file_token() {
  local t; t="$(sed -n '1s/.*token=\([^ ]*\).*/\1/p' "$1" 2>/dev/null)"
  [ -n "$t" ] || t="$(sed -n '1s/.*pid=\([0-9]*\).*/\1/p' "$1" 2>/dev/null)"
  printf '%s' "$t"
}

# ── the line (tickets) ────────────────────────────────────────────────────────────────────────
# pfb_priority_rank BRANCH [OVERRIDE] -- 0 for a hotfix (OVERRIDE or AUTOCODER_PREFLIGHT_PRIORITY says `hotfix`,
# or BRANCH is `hotfix/*`), 1 otherwise; OVERRIDE `ordinary` wins over the branch.
pfb_priority_rank() {
  local branch="${1:-}" over; over="$(printf '%s' "${2:-${AUTOCODER_PREFLIGHT_PRIORITY:-}}" | tr '[:upper:]' '[:lower:]')"
  case "$over" in hotfix) printf '0'; return 0 ;; ordinary) printf '1'; return 0 ;; esac
  [[ "$branch" == hotfix/* ]] && { printf '0'; return 0; }
  printf '1'
}
pfb_rank_name() { [ "${1:-1}" = 0 ] && printf 'hotfix' || printf 'ordinary'; }

# pfb_queue_enter QUEUE_DIR PID DETAIL RANK -- claims `+<rank>-<arrival ns>-<pid>.ticket` by noclobber and prints its path.
pfb_queue_enter() {
  local dir="$1" pid="$2" detail="$3" rank="$4" stamp ticket tries=0
  mkdir -p "$dir" || return 1
  while :; do
    stamp="$(date +%s%N 2>/dev/null)"; [[ "$stamp" =~ ^[0-9]+$ ]] || stamp="$(date +%s)000000000"
    ticket="$dir/+$rank-$(printf '%020d' "$stamp")-$pid.ticket"
    if ( set -o noclobber; printf 'pid=%s token=%s %s\n' "$pid" "$(pfb_pid_token "$pid")" "$detail" >"$ticket" ) 2>/dev/null; then
      printf '%s' "$ticket"; return 0
    fi
    tries=$((tries + 1)); (( tries >= 100 )) && return 1
    sleep 0.01
  done
}
# pfb_queue_tickets QUEUE_DIR -- the live tickets in line order, sweeping the dead ones.
pfb_queue_tickets() {
  local t
  while IFS= read -r t; do
    [ -n "$t" ] && [ -e "$t" ] || continue
    if pfb_pid_live "$(pfb_file_token "$t")"; then printf '%s\n' "$t"; else rm -f "$t"; fi
  done < <(printf '%s\n' "$1"/*.ticket 2>/dev/null | LC_ALL=C sort)
}
# pfb_queue_position QUEUE_DIR TICKET -- sets PFB_AHEAD (live tickets ahead of TICKET: 0 means next) and
# PFB_HOTFIX_AHEAD (how many of them are hotfixes). Call it directly: it sets variables, prints nothing.
pfb_queue_position() {
  local t
  PFB_AHEAD=0 PFB_HOTFIX_AHEAD=0
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    [ "$t" = "$2" ] && break
    PFB_AHEAD=$((PFB_AHEAD + 1)); [[ "$(basename "$t")" == +0-* ]] && PFB_HOTFIX_AHEAD=$((PFB_HOTFIX_AHEAD + 1))
  done < <(pfb_queue_tickets "$1")
}

# ── the slots ─────────────────────────────────────────────────────────────────────────────────
# pfb_slot_try SLOTS_DIR N DETAIL -- tries slot-0 .. slot-(N-1), non-blocking flock each; on success sets
# PFB_SLOT_INDEX and PFB_SLOT_FD (an open descriptor the caller keeps; the lock lives as long as it), writes
# the holder file, returns 0. Call it DIRECTLY, never in $(...): a subshell's descriptor dies with it.
pfb_slot_try() {
  local dir="$1" n="$2" detail="$3" i fd token
  mkdir -p "$dir" || return 1
  for ((i = 0; i < n; i++)); do
    exec {fd}>>"$dir/slot-$i.lock" || continue
    if flock -n "$fd"; then
      PFB_SLOT_INDEX="$i" PFB_SLOT_FD="$fd"
      token="$(pfb_pid_token "$$")"
      printf 'pid=%s token=%s started=%s %s\n' "$$" "$token" "$(pfb_now_iso)" "$detail" >"$dir/slot-$i.holder"
      return 0
    fi
    exec {fd}>&-
  done
  return 1
}
# pfb_slot_release SLOTS_DIR -- drops the held slot (the descriptor and the holder file).
pfb_slot_release() {
  [ -n "${PFB_SLOT_FD:-}" ] || return 0
  rm -f "$1/slot-${PFB_SLOT_INDEX}.holder"
  exec {PFB_SLOT_FD}>&-
  PFB_SLOT_FD="" PFB_SLOT_INDEX=""
}
# pfb_slot_holders SLOTS_DIR -- sets PFB_HELD (how many slots are held) and PFB_HOLDERS (one line per held slot,
# `slot <i>: <holder line>`, `;`-joined), probing every slot file ever made (a holder admitted under a larger count
# keeps its higher slot after the count fell). A free slot's stale holder file (its holder died: flock went with it)
# is removed. Call it directly: it sets variables, prints nothing.
pfb_slot_holders() {
  local dir="$1" f i fd line
  PFB_HELD=0 PFB_HOLDERS=""
  for f in "$dir"/slot-*.lock; do
    [ -e "$f" ] || continue
    i="${f##*/slot-}"; i="${i%.lock}"
    exec {fd}>>"$f" || continue
    if flock -n "$fd"; then rm -f "$dir/slot-$i.holder"
    else
      PFB_HELD=$((PFB_HELD + 1))
      line="$(head -1 "$dir/slot-$i.holder" 2>/dev/null || true)"
      PFB_HOLDERS="${PFB_HOLDERS:+$PFB_HOLDERS; }slot $i: ${line:-holder unknown}"
    fi
    exec {fd}>&-
  done
}

# ── acquiring a preflight slot ────────────────────────────────────────────────────────────────
# pfb_acquire [--priority hotfix|ordinary] [--branch B] [--what TEXT] -- waits in line for a slot under the CPU rule and
# takes it: 0 holding it (PFB_SLOT_INDEX, PFB_SLOT_FD, PFB_WAITED_S, PFB_BUDGET_LINE set); 1 past the wait bound,
# naming the holders and the reason; 2 when the lock directory cannot be used. Release with pfb_release.
pfb_acquire() {
  local priority="" branch="" what="" rank detail ticket ahead poll waitmax t0 waited said="" line cpu_line
  local load cores factor limit stamp recent slots_seen
  while [ $# -gt 0 ]; do
    case "$1" in
      --priority) priority="$2"; shift 2 ;;
      --branch) branch="$2"; shift 2 ;;
      --what) what="$2"; shift 2 ;;
      *) pfb_say "pfb_acquire: unknown argument '$1'"; return 2 ;;
    esac
  done
  PFB_ROOT="$(pfb_dir)"; PFB_SLOTS_DIR="$PFB_ROOT/slots"; PFB_QUEUE_DIR="$PFB_ROOT/queue"
  mkdir -p "$PFB_SLOTS_DIR" "$PFB_QUEUE_DIR" 2>/dev/null || { pfb_say "cannot create $PFB_ROOT (AUTOCODER_PREFLIGHT_DIR)"; return 2; }
  rank="$(pfb_priority_rank "$branch" "$priority")"
  detail="priority=$(pfb_rank_name "$rank")${branch:+ branch=$branch}${what:+ what=$what}"
  poll="$(pfb_decimal "${AUTOCODER_PREFLIGHT_POLL_S:-}" 15)"
  waitmax="$(pfb_uint "${AUTOCODER_PREFLIGHT_WAIT_MAX_S:-}" 7200)"
  factor="$(pfb_load_factor)"; cores="$(pfb_cores)"; limit=""
  [ "$factor" = off ] || limit="$(pfb_cpu_limit "$cores" "$factor")"
  stamp="$PFB_ROOT/last-admitted"
  ticket="$(pfb_queue_enter "$PFB_QUEUE_DIR" "$$" "$detail" "$rank")" || { pfb_say "cannot take a queue ticket under $PFB_QUEUE_DIR"; return 2; }
  PFB_TICKET="$ticket"
  [ "$rank" = 0 ] && pfb_say "hotfix preflight: it takes the next free slot ahead of every ordinary waiter"
  pfb_compute_slots; slots_seen="$PFB_SLOTS"
  t0="$(date +%s)"
  while :; do
    [ -e "$ticket" ] || { ticket="$(pfb_queue_enter "$PFB_QUEUE_DIR" "$$" "$detail" "$rank")" || return 2; PFB_TICKET="$ticket"; pfb_say "this waiter's ticket was removed under it; queued again at the back of its rank"; }
    pfb_queue_position "$PFB_QUEUE_DIR" "$ticket"; ahead="$PFB_AHEAD"
    cpu_line=""
    if [ "$factor" != off ]; then
      load="$(pfb_load1)"
      if pfb_cpu_over "$load" "$limit"; then cpu_line="$(pfb_cpu_line "$load" "$cores" "$factor" "$limit")"
      else
        recent="$(pfb_admission_recent "$stamp" "$(pfb_uint "${AUTOCODER_PREFLIGHT_ADMISSION_GAP_S:-}" 60)")"
        [ -z "$recent" ] || cpu_line="a preflight was admitted ${recent}s ago and the 1-minute load (${load:-?}) has not caught up yet; one admission per $(pfb_uint "${AUTOCODER_PREFLIGHT_ADMISSION_GAP_S:-}" 60)s"
      fi
    fi
    if [ -z "$cpu_line" ] && [ "$ahead" -eq 0 ] && pfb_slot_try "$PFB_SLOTS_DIR" "$PFB_SLOTS" "$detail"; then break; fi
    waited=$(( $(date +%s) - t0 ))
    pfb_slot_holders "$PFB_SLOTS_DIR"
    # Say why before judging the bound, so a wait that ends at once on a slow host still names its reason.
    if [ -n "$cpu_line" ]; then line="waiting: $cpu_line (position $((ahead + 1)) in line; $PFB_HOTFIX_AHEAD hotfix ahead; this one is $(pfb_rank_name "$rank"))"
    else line="waiting: all $PFB_SLOTS slot(s) held ($PFB_HELD live; $(pfb_budget_line)); behind $ahead waiter(s), $PFB_HOTFIX_AHEAD hotfix ahead; this one is $(pfb_rank_name "$rank"); holders: ${PFB_HOLDERS:-none}"; fi
    if [ "$line" != "$said" ]; then pfb_say "$line"; said="$line"; fi
    if [ "$waited" -ge "$waitmax" ]; then
      rm -f "$ticket"
      if [ -n "$cpu_line" ]; then pfb_say "no slot after ${waited}s (AUTOCODER_PREFLIGHT_WAIT_MAX_S=$waitmax): $cpu_line; $ahead waiting ahead. Wait for the load to fall, or raise AUTOCODER_PREFLIGHT_LOAD_FACTOR (off disables the rule)."
      else pfb_say "no slot after ${waited}s (AUTOCODER_PREFLIGHT_WAIT_MAX_S=$waitmax): all $PFB_SLOTS slot(s) held, $ahead waiting ahead ($PFB_HOTFIX_AHEAD hotfix); holders: ${PFB_HOLDERS:-none}"; fi
      return 1
    fi
    sleep "$poll"
    pfb_compute_slots
    [ "$PFB_SLOTS" = "$slots_seen" ] || { pfb_say "the host budget moved while waiting ($slots_seen -> $PFB_SLOTS slot(s): $PFB_GATES running gate(s) now)"; slots_seen="$PFB_SLOTS"; }
  done
  rm -f "$ticket"; PFB_TICKET=""
  [ "$factor" = off ] || date +%s >"$stamp" 2>/dev/null
  PFB_WAITED_S=$(( $(date +%s) - t0 ))
  PFB_BUDGET_LINE="slot $((PFB_SLOT_INDEX + 1))/$PFB_SLOTS after ${PFB_WAITED_S}s in line; $(pfb_budget_line)"
  pfb_say "$PFB_BUDGET_LINE"
  return 0
}
# pfb_release -- gives the slot (and any ticket still held) back.
pfb_release() {
  [ -z "${PFB_TICKET:-}" ] || rm -f "$PFB_TICKET"
  PFB_TICKET=""
  pfb_slot_release "${PFB_SLOTS_DIR:-$(pfb_dir)/slots}"
}
# pfb_run [acquire options] -- CMD [ARG...] -- runs CMD holding a slot; CMD's exit, 1 past the wait bound, 2 usage.
pfb_run() {
  local opts=() rc
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do opts+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  [ $# -gt 0 ] || { pfb_say "run: no command after --"; return 2; }
  pfb_acquire "${opts[@]+"${opts[@]}"}" || return $?
  "$@"; rc=$?
  pfb_release
  return "$rc"
}

# ── host-exclusive stages ─────────────────────────────────────────────────────────────────────
# host_exclusive_wants LOCK -- 0 when a gate with a live pid waits for LOCK (dead markers are swept). Sets HOST_EXCLUSIVE_WANTS.
host_exclusive_wants() {
  local m pid any=1; HOST_EXCLUSIVE_WANTS=""
  for m in "$1".wants.*; do
    [ -e "$m" ] || continue
    pid="${m##*.wants.}"
    if pfb_pid_live "$(pfb_file_token "$m")"; then any=0; HOST_EXCLUSIVE_WANTS="${HOST_EXCLUSIVE_WANTS:+$HOST_EXCLUSIVE_WANTS; }$(head -1 "$m")"; else rm -f "$m"; fi
  done
  return "$any"
}
# host_exclusive_holder LOCK -- the holder line, or nothing; a dead holder's line is dropped.
host_exclusive_holder() {
  local line; line="$(head -1 "$1.holder" 2>/dev/null || true)"
  [ -n "$line" ] || return 0
  if pfb_pid_live "$(pfb_file_token "$1.holder")"; then printf '%s' "$line"; else rm -f "$1.holder"; fi
  return 0
}
# host_exclusive_lock NAME ROLE [WHAT] -- takes <dir>/exclusive/NAME.lock: 0 holding it (HOST_EXCLUSIVE_FD,
# HOST_EXCLUSIVE_WAITED_S, HOST_EXCLUSIVE_LOCK set); 125 past the wait bound or when the lock cannot be opened
# (a host condition, never a verdict on the tree); 2 for a bad name or role. ROLE gate is admitted ahead of
# waiting preflights (it leaves a `.wants.<pid>` marker while it waits); ROLE preflight yields to any live marker.
host_exclusive_lock() {
  local name="$1" role="$2" what="${3:-}" lock fd poll waitmax t0 waited holder said="__unset__" marker=""
  # BASHPID is read here, in this shell: inside a $(...) it would be the substitution's own pid.
  local me="$BASHPID" token; token="$(pfb_pid_token "$me")"
  [[ "$name" =~ $_pfb_NAME_RE ]] || { pfb_say "host_exclusive_lock: '$name' is not a stage name (letters, digits, . _ -)"; return 2; }
  case "$role" in gate|preflight) ;; *) pfb_say "host_exclusive_lock: role must be gate or preflight, got '$role'"; return 2 ;; esac
  lock="$(pfb_dir)/exclusive/$name.lock"
  mkdir -p "$(dirname "$lock")" 2>/dev/null || { pfb_say "cannot create $(dirname "$lock") (AUTOCODER_PREFLIGHT_DIR)"; return 125; }
  exec {fd}>>"$lock" || { pfb_say "cannot open $lock for the host-exclusive lock"; return 125; }
  poll="$(pfb_decimal "${AUTOCODER_HOST_EXCLUSIVE_POLL_S:-}" 5)"
  waitmax="$(pfb_uint "${AUTOCODER_HOST_EXCLUSIVE_WAIT_MAX_S:-}" 7200)"
  if [ "$role" = gate ]; then
    marker="$lock.wants.$me"
    printf 'pid=%s token=%s role=gate since=%s%s\n' "$me" "$token" "$(pfb_now_iso)" "${what:+ what=$what}" >"$marker"
  fi
  t0="$(date +%s)"
  while :; do
    if [ "$role" = gate ] || ! host_exclusive_wants "$lock"; then
      flock -n "$fd" && break
    fi
    holder="$(host_exclusive_holder "$lock")"
    if [ "$role" != gate ] && host_exclusive_wants "$lock"; then holder="${holder:+$holder; }the gate wants it next ($HOST_EXCLUSIVE_WANTS)"; fi
    waited=$(( $(date +%s) - t0 ))
    if [ "$holder" != "$said" ]; then pfb_say "$name: waiting for the host-exclusive lock (${waited}s so far; one at a time host-wide): ${holder:-holder unknown}"; said="$holder"; fi
    if [ "$waited" -ge "$waitmax" ]; then
      [ -z "$marker" ] || rm -f "$marker"
      exec {fd}>&-
      pfb_say "$name: the host-exclusive lock did not come in ${waited}s (AUTOCODER_HOST_EXCLUSIVE_WAIT_MAX_S=$waitmax): ${holder:-holder unknown}"
      return 125
    fi
    sleep "$poll"
  done
  [ -z "$marker" ] || rm -f "$marker"
  HOST_EXCLUSIVE_FD="$fd" HOST_EXCLUSIVE_LOCK="$lock" HOST_EXCLUSIVE_WAITED_S=$(( $(date +%s) - t0 ))
  printf 'pid=%s token=%s role=%s since=%s%s\n' "$me" "$token" "$role" "$(pfb_now_iso)" "${what:+ what=$what}" >"$lock.holder"
  [ "$HOST_EXCLUSIVE_WAITED_S" -eq 0 ] || pfb_say "$name: the host-exclusive lock is ours after ${HOST_EXCLUSIVE_WAITED_S}s"
  return 0
}
# host_exclusive_unlock -- releases the lock host_exclusive_lock took.
host_exclusive_unlock() {
  [ -n "${HOST_EXCLUSIVE_FD:-}" ] || return 0
  rm -f "$HOST_EXCLUSIVE_LOCK.holder"
  exec {HOST_EXCLUSIVE_FD}>&-
  HOST_EXCLUSIVE_FD="" HOST_EXCLUSIVE_LOCK=""
}
# host_exclusive_run NAME ROLE [--waited-file F] [--what TEXT] -- CMD [ARG...] -- runs CMD holding the lock; CMD's exit,
# 125 when the lock never came. The waited file, when named, receives the seconds waited the moment the lock is taken
# (the stage runner reads it: the wait is not the stage's own time).
host_exclusive_run() {
  local name="$1" role="$2" waited_file="" what="" rc; shift 2
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do
    case "$1" in
      --waited-file) waited_file="$2"; shift 2 ;;
      --what) what="$2"; shift 2 ;;
      *) pfb_say "exclusive: unknown argument '$1'"; return 2 ;;
    esac
  done
  [ "${1:-}" = "--" ] && shift
  [ $# -gt 0 ] || { pfb_say "exclusive: no command after --"; return 2; }
  host_exclusive_lock "$name" "$role" "$what" || return $?
  [ -z "$waited_file" ] || printf '%s\n' "$HOST_EXCLUSIVE_WAITED_S" >"$waited_file" 2>/dev/null || true
  "$@"; rc=$?
  host_exclusive_unlock
  return "$rc"
}

# ── status ────────────────────────────────────────────────────────────────────────────────────
# pfb_status -- the slots, their holders, the waiters in order and the host-exclusive locks, on stdout.
pfb_status() {
  local root t l n=0
  root="$(pfb_dir)"
  pfb_compute_slots
  echo "preflight budget: $(pfb_budget_line); directory $root"
  pfb_slot_holders "$root/slots"
  echo "held: $PFB_HELD"
  [ -z "$PFB_HOLDERS" ] || printf '%s\n' "$PFB_HOLDERS" | tr ';' '\n' | sed 's/^ *//; s/^/  /'
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    n=$((n + 1)); echo "  waiting $n: $(sed -n '1s/^pid=\([0-9]*\) token=[^ ]* /pid=\1 /p' "$t")"
  done < <(pfb_queue_tickets "$root/queue")
  echo "waiting: $n"
  for l in "$root"/exclusive/*.lock; do
    [ -e "$l" ] || continue
    local name="${l##*/}" holder; name="${name%.lock}"; holder="$(host_exclusive_holder "$l")"
    if host_exclusive_wants "$l"; then echo "exclusive $name: ${holder:-free}; gate wants it: $HOST_EXCLUSIVE_WANTS"
    elif [ -n "$holder" ]; then echo "exclusive $name: $holder"; fi
  done
  return 0
}

# ── command line ──────────────────────────────────────────────────────────────────────────────
pfb_usage() { sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
pfb_main() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    run) pfb_run "$@" ;;
    exclusive)
      local name="" role="${AUTOCODER_HOST_EXCLUSIVE_ROLE:-gate}" rest=()
      while [ $# -gt 0 ] && [ "$1" != "--" ]; do
        case "$1" in
          --name) name="$2"; shift 2 ;;
          --role) role="$2"; shift 2 ;;
          *) rest+=("$1"); shift ;;
        esac
      done
      [ -n "$name" ] || { pfb_say "exclusive: --name NAME is required"; return 2; }
      host_exclusive_run "$name" "$role" "${rest[@]+"${rest[@]}"}" "$@" ;;
    status) pfb_status ;;
    -h|--help|help) pfb_usage ;;
    *) pfb_say "unknown command '${sub}' (run, exclusive, status; --help)"; return 2 ;;
  esac
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -uo pipefail
  pfb_main "$@"
  exit $?
fi
