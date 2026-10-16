#!/bin/bash
# repo-id-fns.sh — one short, stable id per repository, shared by every script that keys
# host-local state (merge job files, sentinel state, worktree scratch) on "which repo".
#
# Source this file; callers use:
#   autocoder_repo_id [dir]   -> prints "<repo-dir-name>-<8 hex>"
#
# The id is "<basename of the repo top>-<first 8 hex of sha1(absolute git common dir)>".
# The repo top is the directory that holds the common .git dir, so every linked worktree
# of one clone (main-wt-1, main-wt-2, the sentinel's checkout) computes the same id and
# finds each other's files; the hash part keeps two clones with the same directory name
# apart.

autocoder_repo_id() {
  local dir="${1:-.}" common
  common=$(cd "$dir" 2>/dev/null && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P) || return 1
  printf '%s-%s' "$(basename "$(dirname "$common")")" "$(printf '%s' "$common" | sha1sum | cut -c1-8)"
}
