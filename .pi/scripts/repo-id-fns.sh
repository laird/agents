#!/bin/bash
# repo-id-fns.sh — one short id per repository, for naming host-wide scratch files.
# Source this file; do not execute it.
#
#   autocoder_repo_id [dir]   -> "<basename>-<8 hex>", e.g. agents-3f9a1c2b
#
# <basename> is the main checkout's directory name (every linked worktree of a repo
# shares it) and the hex is the first 8 of sha1 over the git common dir's absolute
# path, so two checkouts of a same-named repo on one host never share merge state.
# Outside a git repo the directory itself stands in for the common dir.
#
# merge-launch.sh, merge-poll.sh, merge-to-integration.sh and the sentinel all key
# their <tmp-root>/autocoder-merge-<repo-id>-<issue>.* files on this, so
# the function name and output format are a contract between them.
autocoder_repo_id() {
  local dir="${1:-$PWD}" common name
  common=$(cd "$dir" 2>/dev/null && git rev-parse --git-common-dir 2>/dev/null) || common=""
  if [ -n "$common" ]; then
    common=$(cd "$dir" && cd "$common" && pwd -P)
  else
    common=$(cd "$dir" 2>/dev/null && pwd -P) || common="$dir"
  fi
  name=$(basename "$common")
  [ "$name" = ".git" ] && name=$(basename "$(dirname "$common")")
  printf '%s-%s\n' "$name" "$(printf '%s' "$common" | _autocoder_sha1 | cut -c1-8)"
}

# SHA-1 hex of stdin with whatever this host has (#272): GNU coreutils ships
# sha1sum, macOS ships shasum, and python3 covers the rest. All three print the
# same lowercase hex first, so a repo's id does not depend on which one ran.
_autocoder_sha1() {
  if command -v sha1sum >/dev/null 2>&1; then sha1sum
  elif command -v shasum >/dev/null 2>&1; then shasum -a 1
  else python3 -c 'import hashlib,sys; print(hashlib.sha1(sys.stdin.buffer.read()).hexdigest())'
  fi
}

# autocoder_tmp_root -> the directory for host-local merge/sentinel state (#213, #272).
#
# $AUTOCODER_TMP when set (the caller chose it). Otherwise a PRIVATE per-user
# directory, mode 0700:
#
#   1. ${XDG_STATE_HOME:-$HOME/.local/state}/autocoder/merge   (the default)
#   2. /tmp/autocoder-<uid>                                    (fallback only)
#
# The state dir comes first because it survives a reboot (#272). The merge job's
# .pid/.exit/.log/.run.sh used to default to /tmp/autocoder-<uid>; on a host with
# a tmpfs /tmp a reboot mid-merge deleted them, so a waiting worker never saw an
# exit code and the sentinel had no run.sh to re-run. /tmp is kept only for hosts
# where the state dir cannot be made safe. A relative XDG_STATE_HOME is ignored,
# as the XDG spec requires.
#
# Private, not shared (#213): the state files used to sit directly in shared /tmp
# under predictable names (autocoder-merge-<repo-id>-<issue>.run.sh, .pid, .exit,
# .log), so on a multi-user host another local user could pre-create the .run.sh
# and have merge-launch.sh (or the sentinel's re-run) execute it as us. Nobody
# else can create files in a 0700 directory we own.
#
# Each candidate must be a real directory (not a symlink), owned by us, with no
# group/other permissions (tightened with chmod when it is ours but too open); one
# that fails that is skipped, never used.
# Nothing here assumes the host: not whether /tmp is tmpfs, not GNU userland
# (stat -c on Linux, stat -f on macOS/BSD), not systemd. When the state dir is
# unusable and /tmp is used instead, one line on stderr says so and why, so a
# run on a new host shows the decision; the default path stays silent.
# Prints the path; exits 1 (with a message on stderr) when no safe directory exists.
# AUTOCODER_TMP_BASE (default /tmp) replaces /tmp, for tests.
autocoder_tmp_root() {
  if [ -n "${AUTOCODER_TMP:-}" ]; then printf '%s\n' "$AUTOCODER_TMP"; return 0; fi
  local d mode why="" state="${XDG_STATE_HOME:-}"
  local tmpd="${AUTOCODER_TMP_BASE:-/tmp}/autocoder-$(id -u)"
  case "$state" in /*) ;; *) state="${HOME:+$HOME/.local/state}" ;; esac
  [ -n "$state" ] || why="neither XDG_STATE_HOME nor HOME is set"
  for d in ${state:+"$state/autocoder/merge"} "$tmpd"; do
    if [ ! -e "$d" ] && [ ! -L "$d" ]; then
      (umask 077 && mkdir -p "$d") 2>/dev/null || { why="cannot create $d"; continue; }
    fi
    if [ -L "$d" ]; then why="$d is a symlink"; continue; fi
    if [ ! -d "$d" ]; then why="$d is not a directory"; continue; fi
    if [ ! -O "$d" ]; then why="$d is not owned by uid $(id -u)"; continue; fi
    mode=$(stat -c %a "$d" 2>/dev/null || stat -f %Lp "$d" 2>/dev/null) || { why="cannot stat $d"; continue; }
    case "$mode" in
      *00) ;;
      *) chmod 700 "$d" 2>/dev/null || { why="$d is mode $mode and cannot be made 0700"; continue; } ;;
    esac
    [ "$d" = "$tmpd" ] && [ -n "$why" ] &&
      echo "autocoder: state dir unusable ($why); using $d, which may not survive a reboot" >&2
    printf '%s\n' "$d"; return 0
  done
  echo "autocoder: no private state directory ($why); set AUTOCODER_TMP" >&2
  return 1
}
