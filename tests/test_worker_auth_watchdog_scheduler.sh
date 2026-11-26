#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"
# tests/test_worker_auth_watchdog_scheduler.sh — worker-auth-watchdog.sh --ensure
# picks a scheduler from the host and never installs two.
#
# crontab when a cron daemon is up; a systemd user timer (with the linger
# note) when crontab is missing; a launchd agent when uname is Darwin; a
# --loop message when nothing is available. Re-running does not duplicate,
# and a second mechanism left behind is removed.
#
# PATH is a copy of the real one minus crontab, systemctl, loginctl,
# launchctl, uname and pgrep, plus the fakes this file drops in front.
# HOME is a scratch directory, so units never land in the operator's config.

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
mkdir -p "$T/bin" "$T/home" "$T/sysd" "$T/realbin"

IFS=: read -ra _dirs <<< "$PATH"
for _d in "${_dirs[@]}"; do
  [ -d "$_d" ] || continue
  for _f in "$_d"/*; do
    _n=${_f##*/}
    case "$_n" in crontab|systemctl|loginctl|launchctl|uname|pgrep) continue ;; esac
    [ -e "$T/realbin/$_n" ] && continue
    [ -x "$_f" ] && [ ! -d "$_f" ] && ln -s "$_f" "$T/realbin/$_n" 2>/dev/null
  done
done
REAL_UNAME=$(command -v uname)

cat > "$T/bin/uname" <<EOF
#!/bin/bash
if [ "\${1:-}" = -s ] && [ -n "\${FAKE_UNAME:-}" ]; then echo "\$FAKE_UNAME"; exit 0; fi
exec "$REAL_UNAME" "\$@"
EOF
cat > "$T/bin/pgrep" <<'EOF'
#!/bin/bash
if [ "${1:-}" = -x ] && { [ "${2:-}" = cron ] || [ "${2:-}" = crond ]; }; then
  [ "${FAKE_CROND:-no}" = yes ]; exit
fi
exit 1
EOF
cat > "$T/bin/crontab" <<'EOF'
#!/bin/bash
if [ "${1:-}" = -l ]; then cat "$CRONTAB_FILE" 2>/dev/null || exit 1
elif [ "${1:-}" = - ]; then cat > "$CRONTAB_FILE.new" && mv "$CRONTAB_FILE.new" "$CRONTAB_FILE"
else exit 1; fi
EOF
cat > "$T/bin/systemctl" <<'EOF'
#!/bin/bash
echo "$*" >> "$SYSD/calls"
[ "${1:-}" = "--user" ] || exit 1
shift
[ "${SYSTEMCTL_DOWN:-0}" = 1 ] && exit 1
case "$1" in
  show-environment) echo "HOME=$HOME"; exit 0 ;;
  daemon-reload) exit 0 ;;
  enable)
    shift; [ "${1:-}" = "--now" ] && shift
    echo "$1" >> "$SYSD/enabled"; exit 0 ;;
  disable)
    shift; [ "${1:-}" = "--now" ] && shift
    echo "disable $1" >> "$SYSD/calls"; exit 0 ;;
  is-enabled) exit 1 ;;
esac
exit 0
EOF
cat > "$T/bin/loginctl" <<'EOF'
#!/bin/bash
echo "Linger=${FAKE_LINGER:-no}"
EOF
cat > "$T/bin/launchctl" <<'EOF'
#!/bin/bash
echo "$*" >> "$SYSD/launchctl"
exit 0
EOF
chmod +x "$T/bin/"*

export CRONTAB_FILE="$T/crontab"
export HOME="$T/home"
export XDG_CONFIG_HOME="$T/home/.config"
export XDG_STATE_HOME="$T/state"
export AUTH_WATCHDOG_STATE_DIR="$T/state/auth-watchdog"
export PATH="$T/bin:$T/realbin"

run() {
  env FAKE_UNAME="${FAKE_UNAME:-}" FAKE_CROND="${FAKE_CROND:-no}" \
    FAKE_LINGER="${FAKE_LINGER:-no}" SYSTEMCTL_DOWN="${SYSTEMCTL_DOWN:-0}" \
    CRONTAB_FILE="$CRONTAB_FILE" SYSD="$T/sysd" \
    HOME="$HOME" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" XDG_STATE_HOME="$XDG_STATE_HOME" \
    AUTH_WATCHDOG_STATE_DIR="$AUTH_WATCHDOG_STATE_DIR" PATH="$PATH" \
    bash "$SCRIPT" --ensure 2>&1
}

reset() {
  rm -rf "$T/sysd" "$T/home/.config" "$T/home/Library" "$T/crontab" "$AUTH_WATCHDOG_STATE_DIR"
  mkdir -p "$T/sysd" "$T/home"
  FAKE_UNAME=""; FAKE_CROND=no; FAKE_LINGER=no; SYSTEMCTL_DOWN=0
}

# ── Linux, no crontab: systemd user timer, linger note, no second copy ──
reset
SYSTEMCTL_DOWN=0
rm -f "$T/bin/crontab"
OUT=$(run); RC=$?
[ "$RC" -eq 0 ] && pass "systemd ensure exits 0" || fail "systemd ensure exits 0 — rc $RC: $OUT"
assert_contains "systemd ensure names the timer" "installed systemd user timer" "$OUT"
assert_contains "systemd ensure notes linger" "loginctl enable-linger" "$OUT"
UNIT="$XDG_CONFIG_HOME/systemd/user/autocoder-worker-auth-watchdog"
[ -f "$UNIT.timer" ] && [ -f "$UNIT.service" ] && pass "systemd unit files written" || fail "systemd unit files written"
grep -q 'OnUnitInactiveSec=120s' "$UNIT.timer" && pass "timer is every 2 minutes" || fail "timer interval: $(cat "$UNIT.timer")"
grep -q 'enable --now autocoder-worker-auth-watchdog.timer' "$T/sysd/calls" \
  && pass "timer is enabled" || fail "timer is enabled — $(cat "$T/sysd/calls")"
# crontab is back for the idempotent re-run; it must not gain an entry.
cat > "$T/bin/crontab" <<'EOF'
#!/bin/bash
if [ "${1:-}" = -l ]; then cat "$CRONTAB_FILE" 2>/dev/null || exit 1
elif [ "${1:-}" = - ]; then cat > "$CRONTAB_FILE.new" && mv "$CRONTAB_FILE.new" "$CRONTAB_FILE"
else exit 1; fi
EOF
chmod +x "$T/bin/crontab"
: > "$CRONTAB_FILE"
OUT=$(run)
assert_contains "systemd re-run is idempotent" "systemd entry already installed" "$OUT"
[ ! -s "$CRONTAB_FILE" ] && pass "re-run does not also install cron" || fail "re-run wrote crontab: $(cat "$CRONTAB_FILE")"
[ "$(grep -c . "$UNIT.timer")" -ge 1 ] && pass "timer file still present" || fail "timer file removed"

# ── cron daemon up: one new crontab line, existing jobs kept ──
reset
FAKE_CROND=yes
echo "0 3 * * * existing-job" > "$CRONTAB_FILE"
OUT=$(run); RC=$?
[ "$RC" -eq 0 ] && pass "cron ensure exits 0" || fail "cron ensure exits 0 — rc $RC: $OUT"
assert_contains "cron ensure installs the entry" "installed cron entry" "$OUT"
[ "$(grep -c 'autocoder-worker-auth-watchdog' "$CRONTAB_FILE")" = 1 ] \
  && pass "exactly one watchdog cron line" || fail "cron lines: $(cat "$CRONTAB_FILE")"
grep -q 'existing-job' "$CRONTAB_FILE" && pass "existing cron jobs are preserved" || fail "existing job dropped"
OUT=$(run)
assert_contains "cron re-run is idempotent" "cron entry already installed" "$OUT"
[ "$(grep -c 'autocoder-worker-auth-watchdog' "$CRONTAB_FILE")" = 1 ] \
  && pass "re-run does not duplicate the cron line" || fail "duplicated: $(cat "$CRONTAB_FILE")"

# A timer file left beside a cron entry is the second mechanism: --ensure
# keeps cron (it is already the installed one) and deletes the timer.
mkdir -p "$XDG_CONFIG_HOME/systemd/user"
echo leftover > "$UNIT.timer"
echo leftover > "$UNIT.service"
OUT=$(run)
assert_contains "cron stays when a timer is also present" "cron entry already installed" "$OUT"
[ ! -f "$UNIT.timer" ] && pass "leftover systemd timer removed" || fail "leftover systemd timer remains"
[ "$(grep -c 'autocoder-worker-auth-watchdog' "$CRONTAB_FILE")" = 1 ] \
  && pass "removing the timer does not add a cron line" || fail "cron lines after retire: $(cat "$CRONTAB_FILE")"

# ── macOS: launchd, not cron, even if crontab exists ──
reset
FAKE_UNAME=Darwin
FAKE_CROND=yes
echo "0 3 * * * existing-job" > "$CRONTAB_FILE"
OUT=$(run); RC=$?
[ "$RC" -eq 0 ] && pass "launchd ensure exits 0" || fail "launchd ensure exits 0 — rc $RC: $OUT"
assert_contains "launchd ensure names the agent" "installed launchd agent" "$OUT"
PLIST="$HOME/Library/LaunchAgents/com.autocoder.worker-auth-watchdog.plist"
[ -f "$PLIST" ] && pass "LaunchAgent plist written" || fail "LaunchAgent plist written"
grep -q '<integer>120</integer>' "$PLIST" && pass "launchd interval is 120s" || fail "plist interval"
grep -q 'bootstrap gui/' "$T/sysd/launchctl" && pass "launchctl bootstrap ran" || fail "launchctl: $(cat "$T/sysd/launchctl" 2>/dev/null)"
grep -q 'autocoder-worker-auth-watchdog' "$CRONTAB_FILE" \
  && fail "launchd ensure also wrote cron" || pass "launchd ensure leaves crontab alone"
# The pre-existing job stays.
grep -q 'existing-job' "$CRONTAB_FILE" && pass "unrelated cron job kept" || fail "unrelated cron job dropped"
# Both mechanisms present: keep launchd, drop the crontab mark.
echo "*/2 * * * * /bin/true # autocoder-worker-auth-watchdog" >> "$CRONTAB_FILE"
OUT=$(run)
assert_contains "launchd wins when cron is also installed" "launchd entry already installed" "$OUT"
if grep -q 'autocoder-worker-auth-watchdog' "$CRONTAB_FILE"; then
  fail "cron mark still present beside launchd — $(cat "$CRONTAB_FILE")"
else
  pass "cron mark removed when launchd is kept"
fi
grep -q 'existing-job' "$CRONTAB_FILE" && pass "unrelated cron job still kept" || fail "unrelated cron job dropped while retiring"
OUT=$(run)
assert_contains "launchd re-run is idempotent" "launchd entry already installed" "$OUT"

# ── nothing available: say to use --loop, and do not install ──
reset
SYSTEMCTL_DOWN=1
rm -f "$T/bin/crontab" "$T/bin/launchctl"
OUT=$(run); RC=$?
[ "$RC" -ne 0 ] && pass "no scheduler exits non-zero" || fail "no scheduler exits non-zero — rc $RC"
assert_contains "no scheduler names --loop" "--loop" "$OUT"
assert_contains "no scheduler says none was found" "No scheduler available" "$OUT"
[ ! -f "$UNIT.timer" ] && pass "no scheduler writes no unit" || fail "unit written with systemd down"

# ── --loop refuses when a scheduler is already installed ──
reset
cat > "$T/bin/crontab" <<'EOF'
#!/bin/bash
if [ "${1:-}" = -l ]; then cat "$CRONTAB_FILE" 2>/dev/null || exit 1
elif [ "${1:-}" = - ]; then cat > "$CRONTAB_FILE.new" && mv "$CRONTAB_FILE.new" "$CRONTAB_FILE"
else exit 1; fi
EOF
chmod +x "$T/bin/crontab"
echo "*/2 * * * * /bin/true # autocoder-worker-auth-watchdog" > "$CRONTAB_FILE"
if OUT=$(env FAKE_CROND=yes CRONTAB_FILE="$CRONTAB_FILE" SYSD="$T/sysd" \
    HOME="$HOME" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" \
    AUTH_WATCHDOG_STATE_DIR="$AUTH_WATCHDOG_STATE_DIR" PATH="$PATH" \
    bash "$SCRIPT" --loop 2>&1); then
  fail "--loop with cron exits non-zero"
else
  pass "--loop with cron exits non-zero"
fi
assert_contains "--loop names the existing scheduler" "already scheduled via cron" "$OUT"

echo ""
echo "$PASS passed / $FAIL failed / $((PASS + FAIL)) total"
[ "$FAIL" -eq 0 ]
