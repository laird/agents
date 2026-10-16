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
# their ${AUTOCODER_TMP:-/tmp}/autocoder-merge-<repo-id>-<issue>.* files on this, so
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
