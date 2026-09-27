#!/bin/bash
# tests/test_worker_auth_watchdog.sh — pins worker-auth-watchdog.sh behaviour.
#
# The pane fixtures are the real screens from a 2026-09-27 fleet outage, when
# the host's gcloud ADC expired (invalid_rapt) and every Vertex-backed worker
# stalled: some on a failed turn, some on a failed auto-compaction.
#
# herdr is stubbed: `agent list` returns $HERDR_STUB_AGENTS, `pane read <id>`
# returns $HERDR_STUB_PANES/<id>, and every argv line is recorded so the tests
# can assert exactly what would have been typed into which pane.

set -u
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
SCRIPT="$ROOT/plugins/autocoder/scripts/worker-auth-watchdog.sh"

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_contains() {
  if printf '%s' "$3" | grep -qF -- "$2"; then pass "$1"; else fail "$1 — '$2' not in: $3"; fi
}
assert_not_contains() {
  if printf '%s' "$3" | grep -qF -- "$2"; then fail "$1 — unexpected '$2' in: $3"; else pass "$1"; fi
}

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/panes"

cat > "$T/bin/herdr" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$HERDR_ARGV_CAPTURE"
case "$1 $2" in
  "agent list") cat "$HERDR_STUB_AGENTS" ;;
  "pane read")  cat "$HERDR_STUB_PANES/${3//:/_}" ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$T/bin/herdr"

# ── Fixtures ─────────────────────────────────────────────────────────────────
CHROME='
────────────────────────────────────────
❯
────────────────────────────────────────
  ctx 39% of 1M | Sonnet 5 | repo athena2 | wt athena2-wt-2
  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents'

# Turn failed outright → needs a resume prompt.
cat > "$T/panes/wT_p1" <<EOF
✻ Running scheduled task (Sep 27 8:09pm)

❯ /autocoder:gate

● API Error: Could not load Google Cloud credentials · {"error":"invalid_grant","error_description":"reauth related error (invalid_rapt)"}. Check or refresh your Google Cloud credentials and try again.

✻ Brewed for 1s · done 8:09 PM
$CHROME
EOF

# Auto-compaction failed on the same error → needs /compact.
cat > "$T/panes/w12_p1" <<EOF
❯ /autocoder:gate
  ⎿  Prompt is too long · automatic compaction failed: API Error: Could not load Google Cloud credentials ·
     {"error":"invalid_grant","error_description":"reauth related error (invalid_rapt)"}. · /clear to start fresh
✻ Cooked for 2s · done 8:09 PM
$CHROME
EOF

# Error in an OLDER turn, then a successful turn → must be left alone.
cat > "$T/panes/w11_p1" <<EOF
❯ /autocoder:gate
● API Error: Could not load Google Cloud credentials · invalid_rapt
✻ Brewed for 1s · done 8:09 PM

❯ /autocoder:gate
  Ran 1 shell command
● IDLE_NO_WORK_AVAILABLE
✻ Churned for 9s · done 10:25 PM
$CHROME
EOF

# Healthy finished worker.
cat > "$T/panes/w13_p1" <<EOF
❯ continue
● #3172 landed and closed. This worker is fully retired.
✻ Brewed for 1m 13s · done 4:30 PM
$CHROME
EOF

cp "$T/panes/wT_p1" "$T/panes/wZ_p1"    # same error, but still working
cp "$T/panes/wT_p1" "$T/panes/wW_p1"    # the pane running the watchdog

agents_json() { # agents_json "<pane>:<status>" ...
  local out='{"id":"cli:agent:list","result":{"agents":[' sep='' e
  for e in "$@"; do
    out+="$sep{\"agent\":\"claude\",\"pane_id\":\"${e%:*}\",\"agent_status\":\"${e##*:}\"}"
    sep=','
  done
  echo "$out],\"type\":\"agent_list\"}}"
}
agents_json wT:p1:done w12:p1:idle w11:p1:idle w13:p1:done wZ:p1:working wW:p1:done > "$T/agents.json"

run() { # run <probe-exit-code> <mode...>
  local probe="$1"; shift
  : > "$T/argv"
  PATH="$T/bin:$PATH" HERDR_ARGV_CAPTURE="$T/argv" HERDR_STUB_AGENTS="$T/agents.json" \
    HERDR_STUB_PANES="$T/panes" HERDR_PANE_ID="wW:p1" AUTH_WATCHDOG_STATE_DIR="$T/state" \
    AUTH_WATCHDOG_PROBE_CMD="exit $probe" AUTOCODER_MUX_SUBMIT_DELAY=0 \
    bash "$SCRIPT" "$@" 2>&1
}
sends() { grep -E '^pane send-text' "$T/argv" || true; }

# ── Credentials still invalid: notify once, nudge nothing ────────────────────
OUT=$(run 1 --once)
assert_contains "invalid creds: reports the stall" "STALLED 2 worker(s)" "$OUT"
assert_contains "invalid creds: notifies the human" "notification show" "$(cat "$T/argv")"
assert_contains "invalid creds: notification names the reauth command" "gcloud auth application-default login" "$(cat "$T/argv")"
[ -z "$(sends)" ] && pass "invalid creds: zero sends" || fail "invalid creds: zero sends — $(sends)"

OUT=$(run 1 --once)
assert_not_contains "invalid creds: second tick does not re-notify" "notification show" "$(cat "$T/argv")"

# ── Credentials valid: resume + compact the right panes, only them ───────────
OUT=$(run 0 --once)
S=$(sends)
assert_contains "failed turn gets the resume prompt" "pane send-text wT:p1 Your last turn failed" "$S"
assert_contains "failed compaction gets /compact" "pane send-text w12:p1 /compact" "$S"
assert_contains "each send is submitted with a separate enter" "pane send-keys wT:p1 enter" "$(cat "$T/argv")"
assert_not_contains "error in an older turn is ignored" "w11:p1" "$S"
assert_not_contains "healthy worker is ignored" "w13:p1" "$S"
assert_not_contains "working pane is ignored" "wZ:p1" "$S"
assert_not_contains "the watchdog never nudges its own pane" "wW:p1" "$S"
[ ! -f "$T/state/outage" ] && pass "recovery clears the outage flag" || fail "recovery clears the outage flag"

# ── Cooldown: an unchanged stall is not re-nudged ────────────────────────────
OUT=$(run 0 --once)
[ -z "$(sends)" ] && pass "cooldown suppresses a repeat nudge" || fail "cooldown suppresses a repeat nudge — $(sends)"
assert_contains "cooldown skip is logged" "SKIP wT:p1" "$OUT"

OUT=$(AUTH_WATCHDOG_COOLDOWN=0 run 0 --once)
assert_contains "expired cooldown nudges again" "pane send-text wT:p1" "$(sends)"

# ── A fresh outage after recovery notifies again ─────────────────────────────
rm -rf "$T/state"
run 1 --once >/dev/null
run 0 --once >/dev/null
OUT=$(run 1 --once)
assert_contains "a new outage after recovery re-notifies" "notification show" "$(cat "$T/argv")"

# ── Dry run: reports, but writes and sends nothing ───────────────────────────
rm -rf "$T/state"
OUT=$(run 0 --dry-run)
assert_contains "dry-run reports the resume it would send" "DRY-RUN would send wT:p1" "$OUT"
assert_contains "dry-run reports the compact it would send" "DRY-RUN would send w12:p1: /compact" "$OUT"
[ -z "$(sends)" ] && pass "dry-run sends nothing" || fail "dry-run sends nothing — $(sends)"
[ ! -e "$T/state" ] && pass "dry-run writes no state" || fail "dry-run writes no state"

# ── No stall: quiet OK, probe never needed ───────────────────────────────────
agents_json w11:p1:idle w13:p1:done > "$T/agents.json"
OUT=$(run 1 --once)
assert_contains "no stall reports OK" "OK no worker stalled" "$OUT"
assert_not_contains "no stall never notifies, even with bad creds" "notification show" "$(cat "$T/argv")"

# ── herdr unreachable fails loudly ───────────────────────────────────────────
rm -f "$T/agents.json"
if OUT=$(run 0 --once); then fail "unreachable herdr exits non-zero"; else pass "unreachable herdr exits non-zero"; fi
assert_contains "unreachable herdr is named" "herdr unreachable" "$OUT"

# ── --ensure installs one cron entry, idempotently ───────────────────────────
cat > "$T/bin/crontab" <<'STUB'
#!/bin/bash
if [ "${1:-}" = "-l" ]; then cat "$CRONTAB_FILE" 2>/dev/null || exit 1
elif [ "${1:-}" = "-" ]; then cat > "$CRONTAB_FILE.new" && mv "$CRONTAB_FILE.new" "$CRONTAB_FILE"; fi
STUB
chmod +x "$T/bin/crontab"
export CRONTAB_FILE="$T/crontab"
echo "0 3 * * * existing-job" > "$CRONTAB_FILE"
OUT=$(run 0 --ensure)
assert_contains "ensure installs the entry" "installed cron entry" "$OUT"
OUT=$(run 0 --ensure)
assert_contains "ensure is idempotent" "already installed" "$OUT"
[ "$(grep -c 'autocoder-worker-auth-watchdog' "$CRONTAB_FILE")" = 1 ] \
  && pass "exactly one watchdog cron line" || fail "exactly one watchdog cron line — $(cat "$CRONTAB_FILE")"
assert_contains "existing cron jobs are preserved" "existing-job" "$(cat "$CRONTAB_FILE")"
assert_contains "cron line runs --once" "--once" "$(cat "$CRONTAB_FILE")"

# ── Usage errors ─────────────────────────────────────────────────────────────
if bash "$SCRIPT" --bogus >/dev/null 2>&1; then fail "unknown flag exits non-zero"; else pass "unknown flag exits non-zero"; fi
if bash "$SCRIPT" >/dev/null 2>&1; then fail "no mode exits non-zero"; else pass "no mode exits non-zero"; fi

echo ""
echo "$PASS passed / $FAIL failed / $((PASS + FAIL)) total"
[ "$FAIL" -eq 0 ]
