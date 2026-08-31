#!/usr/bin/env bash
# Claude Code status line: context | memory | model | repo | worktree | branch | quota
#
# Renders one line like:
#   ctx 47% of 1M | mem 12 | Sonnet 5 | repo athena2 | wt athena2-wt-3 | branch feature/issue-264
#
# In a swarm this is the manager's only cheap read on worker health. `tmux
# capture-pane` shows it on every worker pane, so context exhaustion is visible
# before a worker starts truncating its own history — which otherwise presents
# as a worker that "went stupid" for no apparent reason.
#
# Reads the session JSON on stdin (see https://code.claude.com/docs/en/statusline).
# Every segment degrades to silence rather than to a wrong number:
#   - context_window.* is null before the first API call and after /compact
#   - rate_limits.* exists only for Claude.ai Pro/Max sessions; on Vertex or
#     a raw API key it is absent, and an absent quota must not render as 0%.
#   - repo/worktree/branch are silent outside a git repo (no error noise).
#
# Installed to a stable path by install-statusline.sh; do not point settings.json
# at this file directly, since its plugin directory is version-scoped and moves
# on every upgrade.

input=$(cat)
j() { printf '%s' "$input" | jq -r "$1" 2>/dev/null; }

parts=()

# --- context -----------------------------------------------------------------
used=$(j '.context_window.used_percentage // empty')
if [ -n "$used" ]; then
  size=$(j '.context_window.context_window_size // empty')
  if [ -n "$size" ] && [ "$size" -ge 1000000 ] 2>/dev/null; then
    parts+=("$(printf 'ctx %.0f%% of 1M' "$used")")
  else
    parts+=("$(printf 'ctx %.0f%%' "$used")")
  fi
fi

# --- memory ------------------------------------------------------------------
# The per-project memory directory sits beside the transcript. Deriving it from
# cwd would be wrong: this project's directory is keyed on the launch dir, not
# the working dir, and the two differ whenever the session cd's into a subtree.
transcript=$(j '.transcript_path // empty')
if [ -n "$transcript" ]; then
  memdir="$(dirname "$transcript")/memory"
  if [ -d "$memdir" ]; then
    # One file per memory; MEMORY.md is the index, not a memory.
    n=$(find "$memdir" -maxdepth 1 -type f -name '*.md' ! -name 'MEMORY.md' 2>/dev/null | wc -l)
    parts+=("mem $n")
  fi
fi

# --- model -------------------------------------------------------------------
model=$(j '.model.display_name // empty')
[ -n "$model" ] && parts+=("$model")

cwd=$(j '.workspace.current_dir // .cwd // empty')

# --- repo --------------------------------------------------------------------
# The repository, as distinct from the worktree. A worker sits in
# `<repo>-wt-N`, and a manager reading a wall of panes needs to know WHICH
# repo a worker belongs to -- with several swarms running, the worktree name
# alone is easy to misread across projects.
#
# Derived from the common git dir rather than the toplevel: for a linked
# worktree the toplevel is the worktree itself, while the common dir always
# points into the main checkout (`/path/to/repo/.git`), so its parent is the
# repo under both layouts. --path-format=absolute matters because a plain
# checkout otherwise reports a bare relative `.git`.
if [ -n "$cwd" ]; then
  common=$(git -C "$cwd" --no-optional-locks rev-parse --path-format=absolute \
    --git-common-dir 2>/dev/null)
  if [ -n "$common" ]; then
    repo=$(basename "$(dirname "$common")")
    [ -n "$repo" ] && [ "$repo" != "/" ] && parts+=("repo $repo")
  fi
fi

# --- worktree ------------------------------------------------------------
# Prefer the explicit fields Claude Code provides (worktree.name for a
# --worktree session, workspace.git_worktree for a linked worktree the
# session merely happens to be in). Fall back to deriving it from git so a
# plain worktree checkout -- which is what every autocoder worker runs in --
# still shows a name instead of silence.
wt=$(j '.worktree.name // .workspace.git_worktree // empty')
if [ -z "$wt" ] && [ -n "$cwd" ]; then
  gitdir=$(git -C "$cwd" --no-optional-locks rev-parse --git-dir 2>/dev/null)
  common=$(git -C "$cwd" --no-optional-locks rev-parse --git-common-dir 2>/dev/null)
  if [ -n "$gitdir" ] && [ -n "$common" ] && [ "$gitdir" != "$common" ]; then
    wt=$(basename "$(git -C "$cwd" --no-optional-locks rev-parse --show-toplevel 2>/dev/null)")
  fi
fi
[ -n "$wt" ] && parts+=("wt $wt")

# --- branch --------------------------------------------------------------
if [ -n "$cwd" ]; then
  branch=$(git -C "$cwd" --no-optional-locks branch --show-current 2>/dev/null)
  [ -n "$branch" ] && parts+=("branch $branch")
fi

# --- quota -------------------------------------------------------------------
five=$(j '.rate_limits.five_hour.used_percentage // empty')
week=$(j '.rate_limits.seven_day.used_percentage // empty')
quota=()
[ -n "$five" ] && quota+=("$(printf '5h %.0f%%' "$five")")
[ -n "$week" ] && quota+=("$(printf '7d %.0f%%' "$week")")
if [ ${#quota[@]} -gt 0 ]; then
  printf -v joined '%s ' "${quota[@]}"
  parts+=("${joined% }")
fi

[ ${#parts[@]} -eq 0 ] && exit 0
printf -v out '%s | ' "${parts[@]}"
printf '%s' "${out% | }"
