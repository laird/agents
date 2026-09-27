#!/bin/bash
# worker-auth-watchdog.sh — detect workers stalled on an expired-credential API
# error and nudge them back to work once the credentials are valid again.
#
# WHY THIS EXISTS:
#   On a Vertex-backed fleet (CLAUDE_CODE_USE_VERTEX=1) every worker shares the
#   host's gcloud Application Default Credentials. When Google's reauth policy
#   expires them, EVERY worker's next API call fails with
#     API Error: Could not load Google Cloud credentials ... (invalid_rapt)
#   and the agent goes idle. Refreshing the credentials is a human step
#   (`gcloud auth application-default login` — reauth cannot be scripted), but
#   what happens AFTER it is mechanical and was being done by hand:
#     - a worker whose turn simply failed needs a "resume" prompt;
#     - a worker whose auto-compaction failed on the same error ("Prompt is too
#       long · automatic compaction failed") needs an explicit /compact, or it
#       stays wedged at a full context forever;
#     - a worker with a scheduled /loop task recovers on its own, but only at
#       its next tick.
#   This script does that mechanical part at zero token cost, and raises ONE
#   herdr notification per outage so the human knows to reauth.
#
# DETECTION (per herdr agent pane, excluding the pane running this script):
#   - agent_status is idle or done (a working pane is already recovering;
#     a blocked pane is waiting on a human dialog and is left alone), AND
#   - the pane's MOST RECENT TURN — the text after the last `❯ <prompt>` line —
#     ENDS in an error block: its final `●`/`⎿` message opens with an error
#     (ERROR_START_RE: "API Error", a failed compaction, "Invalid API key", ...)
#     and contains an auth-error signature (AUTH_WATCHDOG_ERROR_RE). Looking
#     only at the latest turn means an error that a later successful turn has
#     already scrolled past never re-triggers; requiring the final block to
#     OPEN with the error means an answer that merely quotes the signatures
#     (e.g. an agent discussing an outage) is not mistaken for one.
#
# RECOVERY:
#   1. Probe the credentials (AUTH_WATCHDOG_PROBE_CMD; default: mint an ADC
#      token with gcloud when an ADC file exists, otherwise assume valid).
#   2. Probe fails → notify once per outage, nudge nothing (a nudge would only
#      fail again).
#   3. Probe passes → send `/compact` to compaction-wedged panes and a resume
#      prompt to the rest. Each pane is nudged at most once per
#      AUTH_WATCHDOG_COOLDOWN seconds, so a persistent error cannot loop.
#
# Usage:
#   worker-auth-watchdog.sh --once       one tick (the cron entry point)
#   worker-auth-watchdog.sh --loop       tick forever, sleeping --interval
#   worker-auth-watchdog.sh --dry-run    report what a tick WOULD do; no sends,
#                                        no notifications, no state writes
#   worker-auth-watchdog.sh --ensure     idempotently install a cron entry
#                                        running --once every 2 minutes
#   Options: --interval N (seconds, --loop only; default 120)
#
# Environment:
#   AUTH_WATCHDOG_STATE_DIR   default ~/.local/state/autocoder/auth-watchdog
#   AUTH_WATCHDOG_COOLDOWN    per-pane re-nudge cooldown, seconds (default 600)
#   AUTH_WATCHDOG_PROBE_CMD   credential probe, run with bash -c; exit 0 = valid
#   AUTH_WATCHDOG_ERROR_RE    extended regex of auth-error signatures
#   AUTH_WATCHDOG_RESUME_PROMPT  text sent to resume a failed turn
#
# Exit status: 0 on a completed tick (stalls found or not); 1 on bad usage or
# when herdr is unreachable.

set -u

SOURCE_PATH="${BASH_SOURCE[0]}"
while [ -L "$SOURCE_PATH" ]; do
  SOURCE_DIR="$(cd "$(dirname "$SOURCE_PATH")" && pwd)"
  SOURCE_PATH="$(readlink "$SOURCE_PATH")"
  [[ "$SOURCE_PATH" != /* ]] && SOURCE_PATH="$SOURCE_DIR/$SOURCE_PATH"
done
SCRIPT_DIR="$(cd "$(dirname "$SOURCE_PATH")" && pwd)"
SELF_PATH="$SCRIPT_DIR/$(basename "$SOURCE_PATH")"

# shellcheck source=mux-send-lib.sh
source "$SCRIPT_DIR/mux-send-lib.sh"

STATE_DIR="${AUTH_WATCHDOG_STATE_DIR:-$HOME/.local/state/autocoder/auth-watchdog}"
COOLDOWN="${AUTH_WATCHDOG_COOLDOWN:-600}"
ERROR_RE="${AUTH_WATCHDOG_ERROR_RE:-Could not load Google Cloud credentials|invalid_rapt|reauth related error|OAuth token has expired|Please run /login|authentication_error|Invalid API key}"
COMPACT_RE='Prompt is too long|automatic compaction failed'
ERROR_START_RE='^(API Error|Prompt is too long|Invalid API key|OAuth token has expired|Please run /login)'
RESUME_PROMPT="${AUTH_WATCHDOG_RESUME_PROMPT:-Your last turn failed with an API credential error. Credentials have been refreshed — resume exactly where you left off.}"
CRON_MARK="# autocoder-worker-auth-watchdog"
INTERVAL=120
MODE=""

usage() {
  sed -n '/^# Usage:/,/^# Exit status/p' "$SELF_PATH" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --once|--loop|--dry-run|--ensure) MODE="${1#--}"; shift ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "❌ Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done
[ -n "$MODE" ] || { usage >&2; exit 1; }

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }

# ── Credential probe ─────────────────────────────────────────────────────────
default_probe() {
  local adc="${CLOUDSDK_CONFIG:-$HOME/.config/gcloud}/application_default_credentials.json"
  # No ADC file means this host is not ADC-backed; there is nothing to probe,
  # and the worst case of assuming valid is one cheap failed nudge per cooldown.
  [ -f "$adc" ] || return 0
  command -v gcloud >/dev/null 2>&1 || return 0
  run_with_timeout 30 gcloud auth application-default print-access-token >/dev/null 2>&1
}

credentials_valid() {
  if [ -n "${AUTH_WATCHDOG_PROBE_CMD:-}" ]; then
    bash -c "$AUTH_WATCHDOG_PROBE_CMD" >/dev/null 2>&1
  else
    default_probe
  fi
}

# ── Stall classification ─────────────────────────────────────────────────────
# Reads pane text on stdin; prints "compact", "resume" or "none".
classify_pane_text() {
  ERROR_RE="$ERROR_RE" COMPACT_RE="$COMPACT_RE" ERROR_START_RE="$ERROR_START_RE" python3 -c '
import os, re, sys
lines = [l.replace("\u00a0", " ") for l in sys.stdin.read().splitlines()]
# A turn starts at a submitted prompt: "❯ <text>". The bare input box ("❯" or
# "❯" + nbsp) at the bottom of the screen is not a turn boundary.
start = 0
for i, line in enumerate(lines):
    s = line.strip()
    if s.startswith("❯ ") and s[2:].strip():
        start = i + 1
# The final message block: from the last line opening with a message marker.
# The "✻ Worked for …" footer and the input-box chrome below it open with
# neither marker, so they never become the block start.
block_start = None
for i in range(start, len(lines)):
    s = lines[i].strip()
    if s[:1] in ("●", "⎿"):
        block_start = i
if block_start is None:
    print("none"); sys.exit()
first = lines[block_start].strip()[1:].strip()
block = "\n".join(lines[block_start:])
if not (re.search(os.environ["ERROR_START_RE"], first) and re.search(os.environ["ERROR_RE"], block)):
    print("none")
elif re.search(os.environ["COMPACT_RE"], block):
    print("compact")
else:
    print("resume")
'
}

# Prints "<pane_id> <agent_status>" for every agent pane except our own.
list_agent_panes() {
  local json
  json=$(run_with_timeout "$AUTOCODER_MUX_TIMEOUT_SECONDS" herdr agent list 2>/dev/null) || return 1
  SELF_PANE="${HERDR_PANE_ID:-}" python3 -c '
import json, os, sys
self_pane = os.environ["SELF_PANE"]
for a in json.load(sys.stdin)["result"]["agents"]:
    if a.get("pane_id") and a["pane_id"] != self_pane:
        print(a["pane_id"], a.get("agent_status", "unknown"))
' <<<"$json"
}

# ── State (cooldowns + outage flag) ──────────────────────────────────────────
pane_key() { printf '%s' "$1" | tr -c 'A-Za-z0-9_-' '_'; }

in_cooldown() {
  local f="$STATE_DIR/nudged-$(pane_key "$1")" last
  [ -f "$f" ] || return 1
  last=$(cat "$f" 2>/dev/null || echo 0)
  [ $(( $(date +%s) - last )) -lt "$COOLDOWN" ]
}

mark_nudged() { date +%s > "$STATE_DIR/nudged-$(pane_key "$1")"; }

notify() {
  run_with_timeout "$AUTOCODER_MUX_TIMEOUT_SECONDS" herdr notification show "$1" \
    --body "$2" --sound request >/dev/null 2>&1 || true
}

# ── One tick ─────────────────────────────────────────────────────────────────
tick() {
  local dry="$1" panes pane status text action stalled=()

  panes=$(list_agent_panes) || { log "❌ herdr unreachable (herdr agent list failed)"; return 1; }

  while read -r pane status; do
    [ -n "$pane" ] || continue
    case "$status" in idle|done) ;; *) continue ;; esac
    text=$(run_with_timeout "$AUTOCODER_MUX_TIMEOUT_SECONDS" \
      herdr pane read "$pane" --source recent-unwrapped --lines 80 2>/dev/null) || continue
    action=$(printf '%s\n' "$text" | classify_pane_text)
    [ "$action" = none ] || stalled+=("$pane:$action")
  done <<<"$panes"

  if [ ${#stalled[@]} -eq 0 ]; then
    [ "$dry" = true ] || rm -f "$STATE_DIR/outage"
    log "OK no worker stalled on a credential error"
    return 0
  fi

  if ! credentials_valid; then
    log "STALLED ${#stalled[@]} worker(s) on a credential error; credentials still INVALID — waiting for a human reauth"
    if [ "$dry" = true ]; then
      log "DRY-RUN would notify (once per outage)"
    elif [ ! -f "$STATE_DIR/outage" ]; then
      date +%s > "$STATE_DIR/outage"
      notify "Workers stalled: credentials expired" \
        "${#stalled[@]} worker(s) hit an API credential error. Run: gcloud auth application-default login — the watchdog resumes them once it succeeds."
      log "NOTIFIED human"
    fi
    return 0
  fi

  [ "$dry" = true ] || rm -f "$STATE_DIR/outage"
  local entry msg
  for entry in "${stalled[@]}"; do
    pane="${entry%:*}"; action="${entry##*:}"
    if in_cooldown "$pane"; then
      log "SKIP $pane ($action) — nudged within the last ${COOLDOWN}s"
      continue
    fi
    if [ "$action" = compact ]; then msg="/compact"; else msg="$RESUME_PROMPT"; fi
    if [ "$dry" = true ]; then
      log "DRY-RUN would send $pane: $msg"
      continue
    fi
    if send_herdr_command "$pane" "$msg"; then
      mark_nudged "$pane"
      log "NUDGED $pane ($action)"
    else
      log "❌ send to $pane failed"
    fi
  done
  return 0
}

# ── Scheduler install ────────────────────────────────────────────────────────
ensure_cron() {
  command -v crontab >/dev/null 2>&1 || { echo "❌ crontab not available; run --loop instead" >&2; return 1; }
  if crontab -l 2>/dev/null | grep -qF "$CRON_MARK"; then
    echo "✓ cron entry already installed"
    return 0
  fi
  mkdir -p "$STATE_DIR"
  # cron's PATH is minimal; carry ours so herdr, gcloud and python3 resolve.
  local line="*/2 * * * * PATH='$PATH' '$SELF_PATH' --once >> '$STATE_DIR/watchdog.log' 2>&1 $CRON_MARK"
  ( crontab -l 2>/dev/null; echo "$line" ) | crontab - || { echo "❌ crontab install failed" >&2; return 1; }
  echo "✓ installed cron entry (every 2 minutes); log: $STATE_DIR/watchdog.log"
}

case "$MODE" in
  ensure)  ensure_cron ;;
  dry-run) tick true ;;
  once)    mkdir -p "$STATE_DIR"; tick false ;;
  loop)
    mkdir -p "$STATE_DIR"
    while true; do tick false || true; sleep "$INTERVAL"; done
    ;;
esac
