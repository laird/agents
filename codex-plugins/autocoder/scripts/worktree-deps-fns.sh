#!/bin/bash
# worktree-deps-fns.sh — give a fresh throwaway worktree the git-ignored build inputs a
# test command needs, taken from an existing checkout of the same repo.
#
# Source this file; callers use:
#   seed_worktree_deps <src-repo> <dst-worktree>
#
# node_modules: hardlinked (`cp -al`, instant, shares inodes). #1967: `cp -al` across a
# filesystem boundary (repo on ext4, $TMPDIR on tmpfs) fails per file with "Invalid
# cross-device link" while succeeding for directories and symlinks, leaving a tree of
# empty shells that still reports success; fall back to a real copy, wiping the partial
# destination first because `cp -a` into a populated directory nests instead of merging.
#
# software-factory/packages/*/dist: copied, never hardlinked, then touched. `git worktree
# add` checks out src/ with a brand-new mtime, so a hardlinked dist/ carrying the original
# build's older mtime reads as stale to a freshness check even though the content is
# identical, and fixing the mtime on a hardlink would touch the source checkout's dist too.

_wtd_hardlink_or_copy() {
  local src="$1" dst="$2"
  [ -e "$dst" ] && return 0
  mkdir -p "$(dirname "$dst")" 2>/dev/null || true
  if ! cp -al "$src" "$dst" 2>/dev/null; then
    rm -rf "$dst"
    cp -a "$src" "$dst" 2>/dev/null || true
  fi
}

seed_worktree_deps() {
  local src="$1" dest="$2" nm d rel
  while IFS= read -r nm; do
    rel="${nm#"$src"/}"
    _wtd_hardlink_or_copy "$nm" "$dest/$rel"
  done < <(find "$src" -maxdepth 4 -type d -name node_modules 2>/dev/null | grep -v '/node_modules/.*/node_modules$')
  while IFS= read -r d; do
    rel="${d#"$src"/}"
    [ -e "$dest/$rel" ] && continue
    mkdir -p "$(dirname "$dest/$rel")" 2>/dev/null || true
    cp -a "$d" "$dest/$rel" 2>/dev/null || true
    find "$dest/$rel" -exec touch {} + 2>/dev/null || true
  done < <(find "$src/software-factory/packages" -mindepth 2 -maxdepth 2 -type d -name dist 2>/dev/null)
}
