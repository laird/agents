#!/bin/bash
# scheduler-ensure.sh — install exactly one user scheduler for a command.
#
# Sourced by worker-auth-watchdog.sh and quota-failover.sh. idle-sentinel.sh
# uses scheduler_print_host and scheduler_warn_linger; its own units stay,
# because they run the version-independent shim rather than a fixed argv.
#
# The caller sets these, then calls scheduler_ensure:
#   SCHED_UNIT    systemd unit basename, without .timer
#   SCHED_LABEL   launchd label (default com.autocoder.<SCHED_UNIT>)
#   SCHED_MARK    crontab comment that identifies this job
#   SCHED_EVERY   seconds between runs (default 120)
#   SCHED_LOG     log file
#   SCHED_DESC    one-line description (no newlines)
#   SCHED_CMD     executable
#   SCHED_ARGS    bash array of arguments after the executable
#
# Choice, first that works: launchd on macOS; else crontab when its daemon is
# running (or when there is no systemd user manager); else a systemd user
# timer; else a message naming --loop. Re-running does not add a second
# mechanism. If more than one of ours is installed, the extra is removed.
# On macOS an existing LaunchAgent wins over a crontab entry.
#
# Nothing here is a hostname or a home directory. Units go under
# ${XDG_CONFIG_HOME:-~/.config}/systemd/user and ~/Library/LaunchAgents.

# shellcheck source=reboot-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/reboot-lib.sh"

scheduler_yes_no() { if "$@"; then echo yes; else echo no; fi; }

scheduler_print_host() {
  local sd linger=n/a cron
  sd=$(scheduler_yes_no systemd_user_available)
  [ "$sd" = yes ] && linger=$(linger_state)
  cron=$(scheduler_yes_no cron_available)
  [ "$cron" = yes ] && ! cron_daemon_running && cron="yes(no daemon running)"
  echo "host: os=$(host_os) cron=$cron systemd-user=$sd launchd=$(scheduler_yes_no launchd_available) linger=$linger"
}

# Without lingering, a systemd user timer stops at logout and does not start at boot.
scheduler_warn_linger() {
  local user
  user=$(id -un 2>/dev/null) || return 0
  if [ "$(linger_state)" = no ]; then
    echo "⚠️  Lingering is off for $user: the timer runs only while $user is logged in, and not after a reboot until they log in."
    echo "    To keep it running: loginctl enable-linger $user  (may need sudo; never done for you)"
  fi
}

_sched_label() { printf '%s' "${SCHED_LABEL:-com.autocoder.${SCHED_UNIT}}"; }
_sched_user_dir() { printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"; }
_sched_launchd_dir() { printf '%s\n' "$HOME/Library/LaunchAgents"; }
_sched_every() { printf '%s' "${SCHED_EVERY:-120}"; }

_sched_cron_has() {
  cron_available || return 1
  crontab -l 2>/dev/null | grep -qF "$SCHED_MARK"
}
_sched_systemd_has() { [ -f "$(_sched_user_dir)/$SCHED_UNIT.timer" ]; }
_sched_launchd_has() { [ -f "$(_sched_launchd_dir)/$(_sched_label).plist" ]; }

# cron | systemd | launchd | none
scheduler_installed() {
  if launchd_available && _sched_launchd_has; then echo launchd; return; fi
  if _sched_cron_has; then echo cron; return; fi
  if _sched_systemd_has; then echo systemd; return; fi
  if _sched_launchd_has; then echo launchd; return; fi
  echo none
}

_sched_refuse_newlines() {
  local _p
  for _p in "$SCHED_CMD" "$SCHED_LOG" "$SCHED_DESC" "$PATH" "$HOME" "${SCHED_ARGS[@]}"; do
    case "$_p" in *$'\n'*|*$'\r'*)
      echo "❌ Refusing to install a scheduler: a path (or PATH) contains a newline ($(printf '%q' "$_p"))." >&2
      return 1 ;;
    esac
  done
}

_sched_cron_times() {
  local secs mins
  secs=$(_sched_every)
  mins=$(( secs / 60 ))
  [ "$mins" -lt 1 ] && mins=1
  if [ "$mins" -ge 60 ]; then
    printf '0 */%s * * *' "$(( mins / 60 ))"
  else
    printf '*/%s * * * *' "$mins"
  fi
}

_sched_retire() {
  local keep=$1 dir plist
  if [ "$keep" != cron ] && _sched_cron_has; then
    crontab -l 2>/dev/null | grep -vF "$SCHED_MARK" | crontab - \
      && echo "removed the crontab entry so only $keep runs"
  fi
  dir=$(_sched_user_dir)
  if [ "$keep" != systemd ] && [ -f "$dir/$SCHED_UNIT.timer" ]; then
    if systemd_user_available; then
      systemctl --user disable --now "$SCHED_UNIT.timer" >/dev/null 2>&1 || true
      systemctl --user daemon-reload >/dev/null 2>&1 || true
    fi
    rm -f "$dir/$SCHED_UNIT.timer" "$dir/$SCHED_UNIT.service"
    echo "removed the systemd user timer so only $keep runs"
  fi
  plist="$(_sched_launchd_dir)/$(_sched_label).plist"
  if [ "$keep" != launchd ] && [ -f "$plist" ]; then
    if launchd_available; then
      launchctl bootout "gui/$(id -u)" "$plist" >/dev/null 2>&1 || true
      launchctl unload "$plist" >/dev/null 2>&1 || true
    fi
    rm -f "$plist"
    echo "removed the launchd agent so only $keep runs"
  fi
}

_sched_install_cron() {
  _sched_refuse_newlines || return 1
  mkdir -p "$(dirname "$SCHED_LOG")" || return 1
  local args="" a line
  for a in "${SCHED_ARGS[@]}"; do args+=" $(sh_quote "$a")"; done
  line="$(cron_escape "$(_sched_cron_times) PATH=$(sh_quote "$PATH") $(sh_quote "$SCHED_CMD")${args} >> $(sh_quote "$SCHED_LOG") 2>&1") $SCHED_MARK"
  cron_daemon_running || {
    echo "⚠️  crontab is installed but no cron daemon is running: the entry will not fire until one starts"
    echo "    (e.g. sudo service cron start, or enable systemd in WSL)."
  }
  ( crontab -l 2>/dev/null; echo "$line" ) | crontab - || {
    echo "❌ crontab install failed" >&2
    return 1
  }
  echo "✓ installed cron entry (every 2 minutes); log: $SCHED_LOG"
}

_sched_render_service() {
  local args="" a
  for a in "${SCHED_ARGS[@]}"; do args+=" $(systemd_word "$a" arg)"; done
  cat <<UNIT
# Installed by scheduler-ensure.sh. PATH is the one --ensure ran with.
[Unit]
Description=${SCHED_DESC}

[Service]
Type=oneshot
Environment=$(systemd_word "PATH=$PATH")
ExecStart=$(systemd_word "$SCHED_CMD")${args}
UNIT
}

_sched_render_timer() {
  cat <<UNIT
# Installed by scheduler-ensure.sh.
[Unit]
Description=${SCHED_DESC}

[Timer]
OnBootSec=2min
OnUnitInactiveSec=$(_sched_every)s
AccuracySec=30s

[Install]
WantedBy=timers.target
UNIT
}

_sched_install_systemd() {
  _sched_refuse_newlines || return 1
  local dir svc tmr
  dir=$(_sched_user_dir)
  svc="$dir/$SCHED_UNIT.service"
  tmr="$dir/$SCHED_UNIT.timer"
  mkdir -p "$(dirname "$SCHED_LOG")" "$dir" || return 1
  _sched_render_service > "$svc" && _sched_render_timer > "$tmr" || {
    echo "❌ could not write the systemd units in $dir" >&2
    return 1
  }
  if ! systemctl --user daemon-reload || ! systemctl --user enable --now "$SCHED_UNIT.timer"; then
    echo "❌ systemctl --user could not enable $SCHED_UNIT.timer" >&2
    return 1
  fi
  echo "✓ installed systemd user timer $SCHED_UNIT.timer (every 2 minutes); log: $SCHED_LOG"
  scheduler_warn_linger
}

_sched_render_plist() {
  local a
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!-- Installed by scheduler-ensure.sh: one run every $(_sched_every)s. -->
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$(_sched_label)</string>
  <key>ProgramArguments</key>
  <array>
    <string>$(xml_escape "$SCHED_CMD")</string>
$(for a in "${SCHED_ARGS[@]}"; do printf '    <string>%s</string>\n' "$(xml_escape "$a")"; done)
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>$(xml_escape "$PATH")</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>StartInterval</key>
  <integer>$(_sched_every)</integer>
  <key>StandardOutPath</key>
  <string>$(xml_escape "$SCHED_LOG")</string>
  <key>StandardErrorPath</key>
  <string>$(xml_escape "$SCHED_LOG")</string>
</dict>
</plist>
PLIST
}

_sched_install_launchd() {
  _sched_refuse_newlines || return 1
  local dir plist berr
  dir=$(_sched_launchd_dir)
  plist="$dir/$(_sched_label).plist"
  mkdir -p "$(dirname "$SCHED_LOG")" "$dir" || return 1
  _sched_render_plist > "$plist" || { echo "❌ could not write $plist" >&2; return 1; }
  if ! berr=$(launchctl bootstrap "gui/$(id -u)" "$plist" 2>&1) && ! launchctl load -w "$plist"; then
    echo "❌ launchctl could not load $plist (bootstrap said: ${berr:-nothing})" >&2
    return 1
  fi
  echo "✓ installed launchd agent $(_sched_label) (every 2 minutes); log: $SCHED_LOG"
}

scheduler_ensure() {
  mkdir -p "$(dirname "$SCHED_LOG")"
  scheduler_print_host
  local existing
  existing=$(scheduler_installed)
  if [ "$existing" != none ]; then
    _sched_retire "$existing"
    echo "✓ $existing entry already installed"
    return 0
  fi
  if launchd_available; then
    if _sched_install_launchd; then _sched_retire launchd; return 0; fi
    echo "⚠️  launchd agent install failed — trying the next scheduler" >&2
  fi
  if cron_available && { cron_daemon_running || ! systemd_user_available; }; then
    if _sched_install_cron; then _sched_retire cron; return 0; fi
    echo "⚠️  crontab install failed — trying the next scheduler" >&2
  fi
  if systemd_user_available; then
    if _sched_install_systemd; then _sched_retire systemd; return 0; fi
    echo "⚠️  systemd user timer install failed" >&2
  fi
  echo "❌ No scheduler available (no crontab, no systemd user manager, no launchd)." >&2
  echo "   Run --loop in a session that stays up. It does not survive reboot or logout." >&2
  return 1
}
