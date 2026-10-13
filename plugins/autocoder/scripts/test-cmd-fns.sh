#!/bin/bash
# test-cmd-fns.sh — shared by merge-launch.sh and merge-to-integration.sh.
#
# WHY THIS EXISTS:
#   merge-to-integration.sh used to treat --test-cmd as optional: without it, it
#   printed a warning, pushed the untested combined tree to the integration
#   branch, and then announced the issue "merged and verified". A hand call or
#   a caller that forgot the flag silently bypassed the gate. The gate command
#   is now required: an explicit --test-cmd wins, otherwise it is resolved from
#   the repo's doctrine file, and if neither yields one the merge is refused
#   before anything is fetched, merged, or pushed. The only exemption is a
#   documents-only change, which has nothing for a test suite to verify.
#
# Usage (sourced):
#   resolve_test_cmd <repo-dir>
#       Prints the first command in the fenced block under the
#       '### Regression Test Suite' heading of <repo-dir>/AGENTS.md, falling
#       back to <repo-dir>/CLAUDE.md. Prints nothing if neither has one.
#   is_docs_only_diff <repo-dir> <feature-sha> <integration-branch>
#       Exit 0 iff every file changed between origin/<integration-branch> (as
#       already known locally; this never fetches) and <feature-sha> is
#       documentation. Exit 1 otherwise, including when it cannot tell.

_doctrine_test_cmd() {
  awk '
    /^### Regression Test Suite[[:space:]]*$/ { in_section = 1; next }
    in_section && /^```/ { if (in_fence) exit; in_fence = 1; next }
    in_fence && NF && $0 !~ /^[[:space:]]*#/ { print; exit }
    in_section && !in_fence && /^##?#? / { exit }
  ' "$1"
}

resolve_test_cmd() {
  local dir="$1" f cmd
  for f in AGENTS.md CLAUDE.md; do
    [ -f "$dir/$f" ] || continue
    cmd=$(_doctrine_test_cmd "$dir/$f")
    if [ -n "$cmd" ]; then
      printf '%s\n' "$cmd"
      return 0
    fi
  done
  return 0
}

is_docs_only_diff() {
  local dir="$1" sha="$2" integration="$3" base files f
  base=$(git -C "$dir" merge-base "origin/${integration}" "$sha" 2>/dev/null) || return 1
  files=$(git -C "$dir" diff --name-only "$base" "$sha" 2>/dev/null) || return 1
  [ -n "$files" ] || return 1
  while IFS= read -r f; do
    case "$f" in
      *.md|*.markdown|*.rst|*.adoc|docs/*) ;;
      *) return 1 ;;
    esac
  done <<< "$files"
  return 0
}
