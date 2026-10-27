#!/bin/bash
# regate-fns.sh — does a re-sync oblige a second gate run?
#
# A push to the integration branch that loses the race is re-synced onto the new tip. The
# re-synced tree is only re-gated when the incoming commits could interact with the change
# being pushed: they touch a file the change touched, or a global path (lockfiles,
# manifests, build config, CI). merge-to-integration.sh and main-sentinel.sh both make
# this call, so the rule and the global-path list live here, once.
#
# Source this file; callers use:
#   regate_needed <files-file> <old> <new> [git-dir]
#     files-file  a file listing, one per line, the paths the change being pushed touches;
#                 an empty argument means the set is unknown and every incoming file counts
#     old, new    the integration tip before and after the re-sync
#     git-dir     where to run git (default .)
#     -> rc 0 and prints the first incoming path that obliges a re-gate, with the reason;
#        rc 1 when the incoming files are disjoint from the change and from every global path
#
#   AUTOCODER_GATE_GLOBAL_PATHS  space-separated bash globs matched against each incoming
#     path and its basename. Overrides REGATE_GLOBAL_PATHS_DEFAULT below.

REGATE_GLOBAL_PATHS_DEFAULT="package.json package-lock.json pnpm-lock.yaml yarn.lock Makefile Dockerfile* tsconfig*.json *.config.* .github/* CLAUDE.md AGENTS.md *.csproj *.sln Directory.*.props Directory.*.targets global.json NuGet.config packages.config go.mod go.sum Cargo.toml Cargo.lock pyproject.toml requirements*.txt poetry.lock Pipfile* Gemfile* conftest.py"

# `read -a` splits without pathname expansion, so `Dockerfile*` stays a pattern instead of
# becoming whatever Dockerfiles happen to exist in the current directory.
IFS=' ' read -r -a REGATE_GLOBAL_PATHS <<< "${AUTOCODER_GATE_GLOBAL_PATHS:-$REGATE_GLOBAL_PATHS_DEFAULT}"

regate_path_is_global() {
  local path="$1" glob
  for glob in "${REGATE_GLOBAL_PATHS[@]}"; do
    # shellcheck disable=SC2053
    if [[ "$path" == $glob || "${path##*/}" == $glob ]]; then
      return 0
    fi
  done
  return 1
}

regate_needed() {
  local files_file="$1" old="$2" new="$3" dir="${4:-.}" f
  if [ -z "$files_file" ]; then
    echo "every incoming file (the change's file set is unknown)"
    return 0
  fi
  declare -A touched=()
  while IFS= read -r f; do
    [ -n "$f" ] && touched["$f"]=1
  done < "$files_file"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ -n "${touched[$f]+x}" ]; then
      echo "$f (a file this change touched)"
      return 0
    fi
    if regate_path_is_global "$f"; then
      echo "$f (a global path)"
      return 0
    fi
  done < <(git -C "$dir" diff --name-only --no-renames "$old" "$new")
  return 1
}
