#!/bin/bash
# reboot-lib.sh: host-level reboot state shared by every boot trigger (#275).
#
# Sourced by reboot-recover.sh, idle-sentinel.sh and the scripts that create
# swarms. Two per-user files, in the persistent state directory (never /tmp,
# whether or not it is tmpfs on this host):
#
#   last-boot-id   the boot this user's swarms were last recovered for. Every
#                  trigger (the boot unit, cron @reboot, a launchd agent, the
#                  sentinel's boot wake) compares against the same stamp, so
#                  recovery runs once per boot, whichever trigger fires first.
#   swarm-roots    one absolute swarm root per line, deduplicated. Hosts where
#                  nothing survives a reboot to name the swarms (tmux, no
#                  multiplexer) read the roots from here at boot.
#
# Boot identity is detected, not assumed: Linux's boot_id, else macOS's
# kern.boottime, else none (the boot check is then skipped, never an error).
#
# Environment:
#   AUTOCODER_REBOOT_STATE_DIR  state directory
#                               (default ${XDG_STATE_HOME:-~/.local/state}/autocoder)
#   AUTOCODER_BOOT_ID_FILE      boot id file (default /proc/sys/kernel/random/boot_id)

reboot_state_dir() {
  printf '%s\n' "${AUTOCODER_REBOOT_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/autocoder}"
}

# reboot_state_mkdir: create the state dir private to this user (0700).
reboot_state_mkdir() {
  local dir
  dir=$(reboot_state_dir)
  [ -d "$dir" ] && return 0
  (umask 077 && mkdir -p "$dir")
}

boot_id_file() { printf '%s\n' "${AUTOCODER_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}"; }

# boot_id_source: file:<path> | kern.boottime | none
boot_id_source() {
  local f
  f=$(boot_id_file)
  if [ -r "$f" ]; then
    echo "file:$f"
  elif [ "$(uname -s 2>/dev/null)" = Darwin ] && command -v sysctl >/dev/null 2>&1 &&
       [ -n "$(sysctl -n kern.boottime 2>/dev/null)" ]; then
    echo kern.boottime
  else
    echo none
  fi
}

# boot_id_current: this boot's identity, or exit 1 when the host has none.
# macOS: kern.boottime moves when the clock is stepped, which reads as a reboot;
# the cost is one manager-resume prompt to managers that were already running.
boot_id_current() {
  local src id
  src=$(boot_id_source)
  case "$src" in
    file:*) id=$(tr -d '[:space:]' < "${src#file:}" 2>/dev/null) ;;
    # "{ sec = 1700000000, usec = 123456 } Tue Nov 14 ..." -> 1700000000.123456
    kern.boottime) id=$(sysctl -n kern.boottime 2>/dev/null | sed -nE 's/.*sec = ([0-9]+), usec = ([0-9]+).*/\1.\2/p') ;;
    *) return 1 ;;
  esac
  [ -n "$id" ] || return 1
  printf '%s\n' "$id"
}

boot_stamp_get() { cat "$(reboot_state_dir)/last-boot-id" 2>/dev/null | tr -d '[:space:]'; }

boot_stamp_set() {
  local dir
  dir=$(reboot_state_dir)
  reboot_state_mkdir || return 1
  printf '%s\n' "$1" > "$dir/last-boot-id.tmp.$$" && mv -f "$dir/last-boot-id.tmp.$$" "$dir/last-boot-id"
}

# swarm_roots_register <dir>: add dir (made absolute, physical) to the registry.
# Best effort: a failure to register must never fail the caller.
swarm_roots_register() {
  local root dir file
  root=$(cd "$1" 2>/dev/null && pwd -P) || return 0
  case "$root" in *$'\n'*) return 0 ;; esac
  dir=$(reboot_state_dir)
  file="$dir/swarm-roots"
  reboot_state_mkdir 2>/dev/null || return 0
  grep -qxF -- "$root" "$file" 2>/dev/null && return 0
  printf '%s\n' "$root" >> "$file" 2>/dev/null || return 0
  # Appends from two processes can race; rewrite deduplicated, order kept.
  awk '!seen[$0]++' "$file" > "$file.tmp.$$" 2>/dev/null && mv -f "$file.tmp.$$" "$file" 2>/dev/null
  rm -f "$file.tmp.$$" 2>/dev/null
  return 0
}

# swarm_roots_list: registered roots that still exist and belong to this user,
# one per line. Ownership matters: recovery runs the root's sentinel, which
# sources its .autocoder hooks, so a registered path deleted and recreated by
# another user (a root under /tmp) must not be acted on.
swarm_roots_list() {
  local r
  while IFS= read -r r; do
    [ -n "$r" ] && [ -d "$r" ] && [ -O "$r" ] && printf '%s\n' "$r"
  done < "$(reboot_state_dir)/swarm-roots" 2>/dev/null
  return 0
}

# ── host detection and quoting (#271, #273; moved here from idle-sentinel.sh
# for #275 so the sentinel and reboot-recover.sh detect the host the same way) ──

# sh_quote <s>: <s> as one POSIX-shell word, '…' with each ' written '\'' (#235).
# Cron runs its lines with /bin/sh, so bash's printf %q ($'…' forms) is not safe here.
sh_quote() { local s=${1//\'/\'\\\'\'}; printf "'%s'" "$s"; }
# cron_escape <s>: cron turns an unescaped % in the command into a newline; \% keeps it
# (Vixie cron / cronie; other crons may differ).
cron_escape() { printf '%s' "${1//%/\\%}"; }

# host_os: macos | linux/<os-release ID>[+wsl] | <kernel name> | unknown
host_os() {
  local kernel id
  kernel=$(uname -s 2>/dev/null)
  case "$kernel" in
    Darwin) echo macos ;;
    Linux)
      id=$(sed -nE "s/^ID=[\"']?([^\"']*)[\"']?\$/\\1/p" "${AUTOCODER_OS_RELEASE:-/etc/os-release}" 2>/dev/null | head -1)
      if [ -n "${WSL_DISTRO_NAME:-}" ] ||
         grep -qi microsoft "${AUTOCODER_PROC_VERSION:-/proc/version}" 2>/dev/null; then
        echo "linux/${id:-unknown}+wsl"
      else
        echo "linux/${id:-unknown}"
      fi ;;
    "") echo unknown ;;
    *) printf '%s\n' "$kernel" | tr 'A-Z' 'a-z' ;;
  esac
}

cron_available() { command -v crontab >/dev/null 2>&1; }

# cron_daemon_running: crontab(1) can exist with no daemon to run the entries
# (WSL without the cron service, minimal containers). Unknown counts as yes.
cron_daemon_running() {
  command -v pgrep >/dev/null 2>&1 || return 0
  pgrep -x cron >/dev/null 2>&1 || pgrep -x crond >/dev/null 2>&1
}

# A launchd agent is the macOS scheduler; launchctl elsewhere is not launchd.
launchd_available() {
  [ "$(uname -s 2>/dev/null)" = Darwin ] && command -v launchctl >/dev/null 2>&1
}

# linger_state: yes | no | n/a (no loginctl, or it cannot tell)
linger_state() {
  command -v loginctl >/dev/null 2>&1 || { echo n/a; return; }
  case "$(loginctl show-user "$(id -un 2>/dev/null)" -p Linger 2>/dev/null)" in
    Linger=yes) echo yes ;;
    Linger=no) echo no ;;
    *) echo n/a ;;
  esac
}

systemd_user_available() {
  command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1
}

# The systemd user unit reboot-recover.sh --install writes.
REBOOT_UNIT_NAME=autocoder-reboot-recover.service

# boot_trigger_missed: 0, printing why, when this host's systemd boot unit is
# enabled but did not do its job this boot: user-manager startup has finished
# (default.target is active, which waits for the oneshot unit to exit) and the
# unit never started (systemd dropped its start job, e.g. to break an ordering
# cycle, #280) or ran and failed. 1 otherwise, including "not run yet" and
# hosts with no systemd user manager, where nothing can be said for certain.
boot_trigger_missed() {
  local props state="" result="" started=0 line
  systemd_user_available || return 1
  systemctl --user is-enabled "$REBOOT_UNIT_NAME" >/dev/null 2>&1 || return 1
  [ "$(systemctl --user is-active default.target 2>/dev/null)" = active ] || return 1
  props=$(systemctl --user show "$REBOOT_UNIT_NAME" -p ActiveState -p Result -p ExecMainStartTimestampMonotonic 2>/dev/null) || return 1
  while IFS= read -r line; do
    case "$line" in
      ActiveState=*) state=${line#*=} ;;
      Result=*) result=${line#*=} ;;
      ExecMainStartTimestampMonotonic=*) started=${line#*=} ;;
    esac
  done <<< "$props"
  case "$state" in activating|active|reloading|deactivating|"") return 1 ;; esac
  if [ "${started:-0}" = 0 ]; then
    echo "$REBOOT_UNIT_NAME is enabled but did not start this boot (systemd dropped its start job; check: systemd-analyze --user verify default.target)"
    return 0
  fi
  if [ -n "$result" ] && [ "$result" != success ]; then
    echo "$REBOOT_UNIT_NAME ran this boot and failed (Result=$result; see: journalctl --user -u $REBOOT_UNIT_NAME -b)"
    return 0
  fi
  return 1
}

# systemd_word <s> [arg]: <s> as one double-quoted word in a unit file: \ and
# " are backslash-escaped and % (specifiers) doubled. Pass "arg" for an
# ExecStart= ARGUMENT, the only place systemd expands $ (doubled there). The
# executable path and Environment= keep a $ literally, so doubling it there
# would corrupt the value.
systemd_word() {
  local s=${1//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//%/%%}
  [ "${2:-}" = arg ] && s=${s//\$/\$\$}
  printf '"%s"' "$s"
}

# sed, not ${s//&/&amp;}: since bash 5.2 (patsub_replacement) an & in the
# replacement means "the match", so the parameter-expansion form breaks on the
# Homebrew/mise bash a Mac often has first on PATH, while 3.2 is fine.
xml_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}


# ── herdr's socket (#372) ─────────────────────────────────────────────────────
# Recovery runs at boot, while herdr may still be starting. It asks the socket
# before running any herdr command, so no herdr command runs when no server
# is listening (herdr 0.9's socket subcommands refuse to start one, but a bare
# `herdr` does, and nothing pins that behaviour).

# herdr_socket_candidates: herdr's socket paths, one per line: $HERDR_SOCKET_PATH
# when set, else under $XDG_CONFIG_HOME and under ~/.config.
herdr_socket_candidates() {
  if [ -n "${HERDR_SOCKET_PATH:-}" ]; then printf '%s\n' "$HERDR_SOCKET_PATH"; return; fi
  [ -n "${XDG_CONFIG_HOME:-}" ] && printf '%s\n' "$XDG_CONFIG_HOME/herdr/herdr.sock"
  printf '%s\n' "$HOME/.config/herdr/herdr.sock"
}

# herdr_socket: the first candidate a server is listening on; 1 when none is.
# A connect, not a file test: a server that died leaves its socket file behind.
herdr_socket() {
  local s
  while IFS= read -r s; do
    [ -S "$s" ] || continue
    python3 -c '
import socket, sys
c = socket.socket(socket.AF_UNIX)
c.settimeout(2)
try:
    c.connect(sys.argv[1])
except OSError:
    sys.exit(1)
' "$s" 2>/dev/null && { printf '%s\n' "$s"; return 0; }
  done <<< "$(herdr_socket_candidates)"
  return 1
}

# herdr_server_pid <socket>: the pid of the process listening on it (Linux
# /proc), or nothing. Only for the log: it shows whose server answered.
herdr_server_pid() {
  python3 - "$1" <<'PY' 2>/dev/null
import os, sys
path = sys.argv[1]
inodes = set()
try:
    for line in open("/proc/net/unix"):
        f = line.split()
        if len(f) >= 8 and f[7] == path:
            inodes.add(f[6])
except OSError:
    sys.exit(0)
want = {"socket:[%s]" % i for i in inodes}
for pid in sorted((d for d in os.listdir("/proc") if d.isdigit()), key=int):
    try:
        fds = os.listdir("/proc/%s/fd" % pid)
    except OSError:
        continue
    for fd in fds:
        try:
            if os.readlink("/proc/%s/fd/%s" % (pid, fd)) in want:
                print(pid)
                sys.exit(0)
        except OSError:
            pass
PY
}
