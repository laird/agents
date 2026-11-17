#!/bin/bash
# worker-idle.sh — decide whether a worker pane is IDLE or BUSY, by evidence.
#
# Read-only. This exists because the manager keeps dispatching work to workers
# that are mid-task. The old heuristic — documented in monitor-workers.md as
# "bare prompt `❯` with no active tool calls" — is simply wrong: the agent TUI
# renders an empty `❯` input box at ALL times, including while a turn is
# running. The liveness signal is the status line ABOVE the box
# (`✽ Determining… (7m 11s · ↓ 25.8k tokens)`), which a `capture-pane | tail -8`
# window routinely scrolls past. Reading the prompt line therefore reports
# "idle" for a worker that is 20 minutes into a build, and the manager
# interrupts real work.
#
# The primary check here is a DOUBLE SAMPLE, not a pattern match: capture the
# pane, wait, capture again, and compare. A working agent's status line carries
# a per-second elapsed timer, so its pane content changes even when the
# underlying command prints nothing for minutes. This is independent of glyph
# set, TUI version, colour, and locale — all of which the pattern-matching
# approach is hostage to. Pattern matching is kept only as a fast path that can
# prove BUSY early; it is never allowed to prove IDLE on its own.
#
# The caller's own pane is always excluded. The manager runs inside the same
# tmux server as its workers, so `--all` without this exclusion has the manager
# classify itself, and a dispatch aimed at that pane types the prompt into the
# manager's own input box instead of a worker's.
#
# Usage:
#   worker-idle.sh --pane <pane-id>     # one pane; exit 0 = idle, 1 = busy
#   worker-idle.sh --all                # table for every pane but our own
#   worker-idle.sh --all --json
#
# Options:
#   --mux tmux|herdr     multiplexer (default: auto-detect; tmux wins when both host panes)
#   --settle-seconds N   gap between the two samples (default 4)
#   --json               machine-readable output
#
# Exit status:
#   --pane : 0 = IDLE, 1 = BUSY, 2 = usage/probe error
#   --all  : 0 if at least one pane is IDLE, 1 if none are, 2 on error
#
# Env: AUTOCODER_IDLE_SETTLE_SECONDS overrides --settle-seconds.
#
# herdr: the same double-sample logic runs over `herdr agent read`, with one
# extra fast path — herdr tracks agent state natively, so `agent_status ==
# "working"` proves BUSY before any capture. Native status is never allowed to
# prove IDLE on its own (a worker parked at a permission prompt reads "idle"
# too); the settle-window comparison stays the load-bearing check.

set -e

SETTLE_SECONDS="${AUTOCODER_IDLE_SETTLE_SECONDS:-4}"
CAPTURE_LINES="${AUTOCODER_IDLE_CAPTURE_LINES:-40}"
TARGET_PANE=""
ALL=false
JSON=false
MUX="${AUTOCODER_MUX:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --pane) TARGET_PANE="$2"; shift 2 ;;
    --all) ALL=true; shift ;;
    --json) JSON=true; shift ;;
    --mux) MUX="$2"; shift 2 ;;
    --settle-seconds) SETTLE_SECONDS="$2"; shift 2 ;;
    -h|--help) sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "worker-idle: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

if [ -z "$TARGET_PANE" ] && [ "$ALL" = false ]; then
  echo "worker-idle: need --pane <id> or --all" >&2
  exit 2
fi

herdr_is_running() {
  command -v herdr >/dev/null 2>&1 && herdr agent list >/dev/null 2>&1
}

# Auto-detect. The test harness pins tmux via AUTOCODER_TMUX_SOCKET; a live tmux
# server with panes wins next (matches start-parallel-agents.sh precedence when
# not launched from inside herdr); herdr is chosen when it is the only
# multiplexer actually hosting anything.
if [ -z "$MUX" ]; then
  if [ -n "${AUTOCODER_TMUX_SOCKET:-}" ]; then
    MUX="tmux"
  elif [ "${HERDR_ENV:-}" = "1" ] && herdr_is_running; then
    MUX="herdr"
  elif command -v tmux >/dev/null 2>&1 && tmux list-panes -a >/dev/null 2>&1; then
    MUX="tmux"
  elif herdr_is_running; then
    MUX="herdr"
  else
    MUX="tmux"
  fi
fi

case "$MUX" in
  tmux)
    command -v tmux >/dev/null 2>&1 || { echo "worker-idle: tmux not found" >&2; exit 2; } ;;
  herdr)
    herdr_is_running || { echo "worker-idle: herdr not running" >&2; exit 2; }
    command -v jq >/dev/null 2>&1 || { echo "worker-idle: herdr mode needs jq" >&2; exit 2; } ;;
  *) echo "worker-idle: unsupported --mux '$MUX' (tmux|herdr)" >&2; exit 2 ;;
esac

# All tmux access goes through this one wrapper so the test suite can point the
# script at a throwaway server (`-L <socket>`) instead of the developer's live
# session. Unset in normal use, which is the plain `tmux` invocation.
tmux_cmd() {
  if [ -n "${AUTOCODER_TMUX_SOCKET:-}" ]; then
    tmux -L "$AUTOCODER_TMUX_SOCKET" "$@"
  else
    tmux "$@"
  fi
}

# Our own pane, so --all can skip it. $TMUX_PANE is set by tmux in every pane
# it spawns and is the only trustworthy answer.
#
# The `display-message` fallback is gated on $TMUX — i.e. on actually being
# inside a tmux client — because outside one it does not fail, it cheerfully
# returns the server's *currently active* pane. That is some unrelated worker,
# which the script would then refuse to classify as "your own pane": a busy
# worker silently exempted from monitoring, which is the same family of bug
# this script exists to kill. No $TMUX means no self pane, so classify all.
if [ "$MUX" = "herdr" ]; then
  # Inside a herdr pane, `herdr pane current` answers for the calling pane.
  # Outside one it errors, which correctly leaves no self pane to exclude.
  SELF_PANE="$(herdr pane current 2>/dev/null | jq -r '.result.pane.pane_id // empty' 2>/dev/null || true)"
elif [ -n "${TMUX_PANE:-}" ]; then
  SELF_PANE="$TMUX_PANE"
elif [ -n "${TMUX:-}" ]; then
  SELF_PANE="$(tmux_cmd display-message -p '#{pane_id}' 2>/dev/null || true)"
else
  SELF_PANE=""
fi

# Patterns that PROVE a turn is in flight. Each is a thing the TUI only renders
# while working:
#   - an elapsed-time counter in the status line: "(7m 11s ·" / "(45s ·"
#   - a token meter: "↓ 25.8k tokens"
#   - the spinner glyphs the status line and the pane title cycle through
#   - "esc to interrupt", which only appears when there is something to interrupt
BUSY_PATTERNS='\([0-9]+m [0-9]+s( |·)|\([0-9]+s( |·)|↓ *[0-9.]+k? tokens|esc to interrupt|[⠂⠄⠈⠐⠠⡀⢀✽✶✻✳✢·*] +[A-Z][a-z]+…'

# Positive evidence of idleness. Unlike a bare prompt, each of these is emitted
# only after a turn ends.
IDLE_PATTERNS='IDLE_NO_WORK_AVAILABLE|Brewed for [0-9]+m'

pane_snapshot() {
  if [ "$MUX" = "herdr" ]; then
    # Screen content plus the terminal title (carries the spinner) — same
    # composition as the tmux snapshot.
    herdr agent read "$1" --lines "$CAPTURE_LINES" --format text 2>/dev/null
    herdr agent list 2>/dev/null | jq -r --arg p "$1" \
      '.result.agents[] | select(.pane_id==$p) | (.terminal_title // "")' 2>/dev/null
    return
  fi
  # Pane content AND title: the title carries the spinner even when the
  # status line has scrolled out of the captured window.
  tmux_cmd capture-pane -t "$1" -p 2>/dev/null | tail -n "$CAPTURE_LINES"
  tmux_cmd display-message -p -t "$1" '#{pane_title}|#{pane_current_command}' 2>/dev/null
}

herdr_agent_status() {
  herdr agent list 2>/dev/null | jq -r --arg p "$1" \
    '.result.agents[] | select(.pane_id==$p) | .agent_status // "unknown"' 2>/dev/null
}

# Prints IDLE or BUSY plus the reason, tab-separated.
classify_pane() {
  local pane="$1" first second

  # herdr fast path: native state can prove BUSY early (never IDLE — a worker
  # parked at a permission prompt also reports "idle"/"blocked").
  if [ "$MUX" = "herdr" ] && [ "$(herdr_agent_status "$pane")" = "working" ]; then
    printf 'BUSY\therdr agent_status=working\n'
    return
  fi

  first="$(pane_snapshot "$pane")"
  if [ -z "$first" ]; then
    printf 'UNKNOWN\tpane %s produced no output (gone?)\n' "$pane"
    return
  fi

  # Fast path: a busy marker in the first sample settles it without waiting.
  if printf '%s' "$first" | grep -qE "$BUSY_PATTERNS"; then
    printf 'BUSY\tactivity marker in pane (timer/spinner/token meter)\n'
    return
  fi

  sleep "$SETTLE_SECONDS"
  second="$(pane_snapshot "$pane")"

  # The load-bearing check. Any change over the settle window means the pane is
  # producing output, which no finished turn does.
  if [ "$first" != "$second" ]; then
    printf 'BUSY\tpane content changed over %ss\n' "$SETTLE_SECONDS"
    return
  fi

  if printf '%s' "$second" | grep -qE "$BUSY_PATTERNS"; then
    printf 'BUSY\tactivity marker appeared during settle window\n'
    return
  fi

  if printf '%s' "$second" | grep -qE "$IDLE_PATTERNS"; then
    printf 'IDLE\texplicit idle sentinel\n'
    return
  fi

  # Static for the whole window, no busy markers, no sentinel. Treated as idle,
  # but reported as the weaker inference it is: a worker blocked on a
  # permission prompt also looks like this, and the manager should read the
  # pane before dispatching over it.
  printf 'IDLE\tno output for %ss and no activity markers (verify before dispatch)\n' "$SETTLE_SECONDS"
}

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

if [ -n "$TARGET_PANE" ]; then
  if [ "$TARGET_PANE" = "$SELF_PANE" ]; then
    echo "worker-idle: $TARGET_PANE is this session's own pane — never dispatch to it" >&2
    exit 2
  fi
  result="$(classify_pane "$TARGET_PANE")"
  state="${result%%	*}"
  reason="${result#*	}"
  if [ "$JSON" = true ]; then
    printf '{"pane":"%s","state":"%s","reason":"%s"}\n' \
      "$(json_escape "$TARGET_PANE")" "$state" "$(json_escape "$reason")"
  else
    printf '%-8s %-6s %s\n' "$TARGET_PANE" "$state" "$reason"
  fi
  [ "$state" = "IDLE" ] && exit 0 || exit 1
fi

# --all
if [ "$MUX" = "herdr" ]; then
  panes="$(herdr agent list 2>/dev/null | jq -r '.result.agents[].pane_id' 2>/dev/null || true)"
else
  panes="$(tmux_cmd list-panes -a -F '#{pane_id}' 2>/dev/null || true)"
fi
if [ -z "$panes" ]; then
  echo "worker-idle: no $MUX panes found" >&2
  exit 2
fi

any_idle=1
[ "$JSON" = true ] && printf '['
sep=""
for pane in $panes; do
  if [ "$pane" = "$SELF_PANE" ]; then
    if [ "$JSON" = false ]; then
      printf '%-8s %-6s %s\n' "$pane" "SELF" "this session's own pane — excluded from dispatch"
    fi
    continue
  fi
  result="$(classify_pane "$pane")"
  state="${result%%	*}"
  reason="${result#*	}"
  [ "$state" = "IDLE" ] && any_idle=0
  if [ "$JSON" = true ]; then
    printf '%s{"pane":"%s","state":"%s","reason":"%s"}' \
      "$sep" "$(json_escape "$pane")" "$state" "$(json_escape "$reason")"
    sep=","
  else
    printf '%-8s %-6s %s\n' "$pane" "$state" "$reason"
  fi
done
[ "$JSON" = true ] && printf ']\n'

exit "$any_idle"
