#!/bin/bash
# merge-worktree-fns.sh — the stale-worktree prune for merge-to-integration.sh (#144).
#
# WHY:
#   Each merge job checks the change out into a throwaway worktree under the per-user
#   temp root (autocoder_tmp_root, #213): autocoder-merge-worktree-<repo-id>-<issue>, plus
#   a -base sibling while the integration tip is gated alone. The job's EXIT trap removes
#   both. A job that dies without running the trap leaves a full checkout behind (a
#   SIGKILL, an OOM kill, a reboot of a host whose temp root is on disk), and on a swarm
#   host those add up to gigabytes nobody owns.
#
# WHO OWNS A WORKTREE:
#   The job writes its pid to autocoder-merge-worktree-<repo-id>-<issue>.owner BEFORE it
#   creates the worktree, so no worktree of a live job is ever without an owner file. A
#   worktree is stale when its owner pid is not running. A worktree with no owner file was
#   made by a job from before #144; it is stale when merge-launch.sh's pidfile for the
#   issue (autocoder-merge-<repo-id>-<issue>.pid) names no running process either.
#   A recycled pid reads as alive, which only means the prune keeps a worktree it could
#   have removed.
#
# SCOPE:
#   Only this repo's worktrees (the <repo-id> prefix): they are removed through this
#   repo's git, so its worktree list stays in step. The caller's own issue is skipped; the
#   job clears those itself.

# merge_worktree_owner_alive <tmp-root> <repo-id> <issue>: exit 0 when a live process owns
# the issue's merge worktrees.
merge_worktree_owner_alive() {
  local root="$1" repo="$2" issue="$3" pid
  if [ -f "${root}/autocoder-merge-worktree-${repo}-${issue}.owner" ]; then
    pid=$(head -n1 "${root}/autocoder-merge-worktree-${repo}-${issue}.owner" 2>/dev/null | tr -cd '0-9')
  else
    pid=$(head -n1 "${root}/autocoder-merge-${repo}-${issue}.pid" 2>/dev/null | tr -cd '0-9')
  fi
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# merge_worktree_prune_stale <tmp-root> <repo-id> <caller-dir> <own-issue>: remove this
# repo's merge worktrees whose job is gone. Prints one line per removal. Always returns 0:
# a failed prune must never stop a merge.
merge_worktree_prune_stale() {
  local root="$1" repo="$2" caller="$3" own="$4" prefix d name issue pruned=0
  prefix="autocoder-merge-worktree-${repo}-"
  for d in "${root}/${prefix}"*; do
    [ -d "$d" ] && [ ! -L "$d" ] || continue
    name="${d##*/}"
    issue="${name#"$prefix"}"; issue="${issue%-base}"
    [ -n "$issue" ] && [ "$issue" != "$own" ] || continue
    merge_worktree_owner_alive "$root" "$repo" "$issue" && continue
    echo "🧹 Removing a merge worktree left by a dead job for issue #${issue}: ${d}"
    git -C "$caller" worktree remove --force "$d" 2>/dev/null || rm -rf "$d" 2>/dev/null || true
    [ -d "$d" ] || pruned=1
    # The owner file goes once the issue has no worktree left (a -base may remain).
    if [ ! -d "${root}/${prefix}${issue}" ] && [ ! -d "${root}/${prefix}${issue}-base" ]; then
      rm -f "${root}/${prefix}${issue}.owner"
    fi
  done
  # An owner file whose worktrees are already gone and whose job is dead is just litter.
  for d in "${root}/${prefix}"*.owner; do
    [ -f "$d" ] || continue
    name="${d##*/}"; issue="${name#"$prefix"}"; issue="${issue%.owner}"
    [ "$issue" != "$own" ] || continue
    [ -d "${root}/${prefix}${issue}" ] || [ -d "${root}/${prefix}${issue}-base" ] && continue
    merge_worktree_owner_alive "$root" "$repo" "$issue" || rm -f "$d"
  done
  [ "$pruned" -eq 1 ] && git -C "$caller" worktree prune 2>/dev/null
  return 0
}
