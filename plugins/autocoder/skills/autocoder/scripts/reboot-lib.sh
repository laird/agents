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
  mkdir -p "$dir" || return 1
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
  mkdir -p "$dir" 2>/dev/null || return 0
  grep -qxF -- "$root" "$file" 2>/dev/null && return 0
  printf '%s\n' "$root" >> "$file" 2>/dev/null
  # Appends from two processes can race; rewrite deduplicated, order kept.
  awk '!seen[$0]++' "$file" > "$file.tmp.$$" 2>/dev/null && mv -f "$file.tmp.$$" "$file" 2>/dev/null
  rm -f "$file.tmp.$$" 2>/dev/null
  return 0
}

# swarm_roots_list: registered roots that still exist, one per line.
swarm_roots_list() {
  local r
  while IFS= read -r r; do
    [ -n "$r" ] && [ -d "$r" ] && printf '%s\n' "$r"
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

