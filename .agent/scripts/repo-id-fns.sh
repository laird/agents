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
  printf '%s-%s\n' "$name" "$(printf '%s' "$common" | sha1sum | cut -c1-8)"
}

# autocoder_tmp_root -> the directory for host-local merge/sentinel state (#213).
#
# $AUTOCODER_TMP when set (the caller chose it). Otherwise a PRIVATE per-user
# directory, /tmp/autocoder-<uid>, mode 0700. The state files used to sit directly
# in shared /tmp under predictable names (autocoder-merge-<repo-id>-<issue>.run.sh,
# .pid, .exit, .log), so on a multi-user host another local user could pre-create
# the .run.sh and have merge-launch.sh (or the sentinel's re-run) execute it as us.
# Nobody else can create files in a 0700 directory we own.
#
# The directory must be a real directory (not a symlink), owned by us, with no
# group/other permissions; one that fails that (someone else made it first) is not
# used, and the fallback is ${XDG_STATE_HOME:-$HOME/.local/state}/autocoder/tmp.
# Prints the path; exits 1 (with a message on stderr) when no safe directory exists.
# AUTOCODER_TMP_BASE (default /tmp) replaces /tmp, for tests.
autocoder_tmp_root() {
  if [ -n "${AUTOCODER_TMP:-}" ]; then printf '%s\n' "$AUTOCODER_TMP"; return 0; fi
  local d mode
  for d in "${AUTOCODER_TMP_BASE:-/tmp}/autocoder-$(id -u)" "${XDG_STATE_HOME:-$HOME/.local/state}/autocoder/tmp"; do
    if [ ! -e "$d" ] && [ ! -L "$d" ]; then
      (umask 077 && mkdir -p "$d") 2>/dev/null || continue
    fi
    [ -d "$d" ] && [ ! -L "$d" ] && [ -O "$d" ] || continue
    mode=$(stat -c %a "$d" 2>/dev/null || stat -f %Lp "$d" 2>/dev/null) || continue
    case "$mode" in *00) printf '%s\n' "$d"; return 0 ;; esac
    chmod 700 "$d" 2>/dev/null && { printf '%s\n' "$d"; return 0; }
  done
  echo "autocoder: no private temp directory (tried /tmp/autocoder-$(id -u) and ~/.local/state/autocoder/tmp); set AUTOCODER_TMP" >&2
  return 1
}
