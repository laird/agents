#!/bin/bash
# merge-conflict-fns.sh — resolve a conflicted rebase in the merge job's throwaway
# worktree before bouncing or escalating it (#164). Sourced by merge-to-integration.sh.
#
# When `git rebase origin/<integration>` stops on a conflict, conflict_try_resolve runs
# in the job's worktree (never the worker's checkout) and tries, for each stop:
#
#   1. Union merge. Files a repo declares as append-only (module lists, test lists,
#      changelog paragraphs) are rebuilt with `git merge-file --union`: both sides'
#      added lines are kept. Deterministic and cheap, so it is tried on every stop.
#   2. A resolver command, once per job and bounded by a timeout. It is given the
#      conflicted files and both sides' commit messages and edits the files in place;
#      exit 0 means "resolved", anything else means "declined". The job then checks that
#      no unmerged path or conflict marker is left and that the resolver did not move
#      HEAD, stages the files and continues the rebase.
#
# Nothing here pushes or decides the outcome. The caller gates the resolved tree like any
# other rebased tree, and a gate failure goes down the usual bounce/escalate path with
# the attempted resolution attached (conflict_resolution_note).
#
# CONFIG (env wins over the main worktree's .autocoder.json):
#   AUTOCODER_UNION_MERGE            newline- or colon-separated globs; .autocoder.json
#                                    "unionMerge": ["CHANGELOG.md", "tests/*.list"].
#                                    A glob is a bash pattern on the repo-relative path
#                                    (`*` also matches `/`).
#   AUTOCODER_CONFLICT_RESOLVER      "off" (default), "claude" (the bundled
#                                    merge-conflict-claude.sh), or a shell command run with
#                                    bash -c in the worktree; .autocoder.json
#                                    "conflictResolver".
#   AUTOCODER_CONFLICT_RESOLVER_TIMEOUT
#                                    seconds for the one resolver attempt (default 600);
#                                    .autocoder.json "conflictResolverTimeout".
#
# THE RESOLVER'S ENVIRONMENT:
#   AUTOCODER_CONFLICT_FILES     the conflicted files, one per line (repo-relative)
#   AUTOCODER_CONFLICT_CONTEXT   a file holding both sides' commit messages
#   AUTOCODER_INTEGRATION_BRANCH, AUTOCODER_ISSUE
#   The working directory is the job's worktree, mid-rebase. It must edit only the listed
#   files and must not commit, stage, or run rebase/merge/reset itself.
#
# STATE (read by merge-to-integration.sh):
#   CONFLICT_RESOLVED_FILES   files resolved during this job, one per line
#   CONFLICT_RESOLVED_BY      "union", "resolver" or "union+resolver"
#   CONFLICT_RESOLVER_TRIED   1 once the resolver has run (one attempt per job)
#   CONFLICT_ATTEMPT_FILE     the resolver's last attempt as a diff, kept when it failed
#   CONFLICT_ATTEMPT_REASON   why the last attempt was refused

CONFLICT_RESOLVED_FILES=""
CONFLICT_RESOLVED_BY=""
CONFLICT_RESOLVER_TRIED=0
CONFLICT_ATTEMPT_FILE=""
CONFLICT_ATTEMPT_REASON=""

_CF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# _cf_config <key>: a string or a newline-joined list from the main worktree's
# .autocoder.json, or nothing. $1 is the caller's checkout (any worktree of the repo).
_cf_config() {
  local dir="$1" key="$2" main json
  main=$(git -C "$dir" worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')
  json="${main:-$dir}/.autocoder.json"
  [ -f "$json" ] || return 0
  python3 - "$json" "$key" <<'PY' 2>/dev/null
import json, sys
try:
    v = json.load(open(sys.argv[1])).get(sys.argv[2])
except Exception:
    sys.exit(0)
if isinstance(v, list):
    print("\n".join(str(x) for x in v))
elif v is not None:
    print(v)
PY
}

conflict_load_config() {  # <caller dir>
  CF_UNION_GLOBS="${AUTOCODER_UNION_MERGE-$(_cf_config "$1" unionMerge)}"
  CF_UNION_GLOBS=$(printf '%s' "$CF_UNION_GLOBS" | tr ':' '\n' | sed '/^[[:space:]]*$/d')
  CF_RESOLVER="${AUTOCODER_CONFLICT_RESOLVER-$(_cf_config "$1" conflictResolver)}"
  CF_RESOLVER="${CF_RESOLVER:-off}"
  CF_TIMEOUT="${AUTOCODER_CONFLICT_RESOLVER_TIMEOUT-$(_cf_config "$1" conflictResolverTimeout)}"
  case "$CF_TIMEOUT" in ''|*[!0-9]*) CF_TIMEOUT=600 ;; esac
  [ "$CF_TIMEOUT" -gt 0 ] || CF_TIMEOUT=600
}

_cf_unmerged() { git diff --name-only --diff-filter=U 2>/dev/null; }
# A rebase is in progress. Not REBASE_HEAD: that ref can outlive a finished rebase.
_cf_rebasing() {
  [ -d "$(git rev-parse --git-path rebase-merge 2>/dev/null)" ] \
    || [ -d "$(git rev-parse --git-path rebase-apply 2>/dev/null)" ]
}

_cf_matches_union() {
  local f="$1" g
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    # shellcheck disable=SC2053  # the glob is meant to match as a pattern
    [[ "$f" == $g ]] && return 0
  done <<< "$CF_UNION_GLOBS"
  return 1
}

# Conflict markers at line starts. "=======" alone is too common in docs (setext
# headings), so it counts only between an opening and a closing marker.
_cf_has_markers() {
  awk '/^<<<<<<< /{o=1} o&&/^=======$/{m=1} o&&m&&/^>>>>>>> /{found=1; exit} END{exit !found}' "$1" 2>/dev/null
}

# Union-merge one conflicted text file from its index stages. rc 0 when resolved.
_cf_union_one() {
  local f="$1" tmp base ours theirs
  # Both sides must still have the file (not modify/delete), and git must see text.
  git cat-file -e ":2:$f" 2>/dev/null && git cat-file -e ":3:$f" 2>/dev/null || return 1
  tmp=$(mktemp -d "${TMP_ROOT:-${TMPDIR:-/tmp}}/autocoder-union.XXXXXX") || return 1
  base="$tmp/base" ours="$tmp/ours" theirs="$tmp/theirs"
  git show ":1:$f" > "$base" 2>/dev/null || : > "$base"   # add/add: empty base
  git show ":2:$f" > "$ours" && git show ":3:$f" > "$theirs" || { rm -rf "$tmp"; return 1; }
  # merge-file refuses binary input (negative exit); with --union it reports 0 conflicts.
  if ! git merge-file --union -p "$ours" "$base" "$theirs" > "$tmp/out" 2>/dev/null; then
    rm -rf "$tmp"; return 1
  fi
  cat "$tmp/out" > "$f" && git add -- "$f" || { rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
  return 0
}

_cf_note_resolved() {  # <files> <method>
  CONFLICT_RESOLVED_FILES=$(printf '%s\n%s\n' "$CONFLICT_RESOLVED_FILES" "$1" | sed '/^$/d' | sort -u)
  case "$CONFLICT_RESOLVED_BY" in
    "") CONFLICT_RESOLVED_BY="$2" ;;
    *"$2"*) ;;
    *) CONFLICT_RESOLVED_BY="union+resolver" ;;
  esac
}

# Both sides' commit messages for the stop the rebase is at.
_cf_write_context() {
  local out="$1" onto stopped
  onto=$(git rev-parse -q --verify "origin/${INTEGRATION_BRANCH}" 2>/dev/null)
  stopped=$(git rev-parse -q --verify REBASE_HEAD 2>/dev/null)
  {
    echo "Rebasing the feature branch ${FEATURE:-?} (issue #${ISSUE_NUM:-?}) onto origin/${INTEGRATION_BRANCH:-?} stopped on a conflict."
    echo
    echo "== The feature commit being replayed (\"theirs\" in the markers) =="
    [ -n "$stopped" ] && git log -1 --format='%H%n%n%B' "$stopped"
    echo
    echo "== Integration commits since the feature branched that touch the conflicted files (\"ours\") =="
    if [ -n "$onto" ] && [ -n "${FEATURE_SHA:-}" ]; then
      local paths=() log
      mapfile -t paths <<< "$2"
      log=$(git log --format='--- %H%n%B' "$(git merge-base "$onto" "$FEATURE_SHA" 2>/dev/null)..$onto" \
        -- "${paths[@]}" 2>/dev/null)
      printf '%s\n' "$log" | head -n 400
    fi
  } > "$out"
}

_cf_timeout_bin() {
  if command -v timeout >/dev/null 2>&1; then echo timeout
  elif command -v gtimeout >/dev/null 2>&1; then echo gtimeout
  fi
}

# Run the resolver once over the files still conflicted. rc 0 when every one is resolved.
_cf_run_resolver() {
  local files="$1" cmd ctx head_before rc=0 tb f left="" attempt
  CONFLICT_RESOLVER_TRIED=1
  case "$CF_RESOLVER" in
    claude) cmd="bash $(printf '%q' "${_CF_DIR}/merge-conflict-claude.sh")" ;;
    *)      cmd="$CF_RESOLVER" ;;
  esac
  ctx=$(mktemp "${TMP_ROOT:-${TMPDIR:-/tmp}}/autocoder-conflict-context.XXXXXX") || return 1
  _cf_write_context "$ctx" "$files"
  head_before=$(git rev-parse HEAD)
  tb=$(_cf_timeout_bin)
  echo "🤝 Conflict in $(printf '%s' "$files" | wc -l | tr -d ' ') file(s); asking the resolver (${CF_RESOLVER}, up to ${CF_TIMEOUT}s)."
  AUTOCODER_CONFLICT_FILES="$files" AUTOCODER_CONFLICT_CONTEXT="$ctx" \
  AUTOCODER_INTEGRATION_BRANCH="${INTEGRATION_BRANCH:-}" AUTOCODER_ISSUE="${ISSUE_NUM:-}" \
    ${tb:+$tb -k 10 "$CF_TIMEOUT"} bash -c "$cmd" </dev/null || rc=$?
  rm -f "$ctx"

  # Keep what it did, whatever the verdict: a refused attempt goes into the comment.
  attempt=$(mktemp "${TMP_ROOT:-${TMPDIR:-/tmp}}/autocoder-conflict-attempt.XXXXXX")
  local paths=()
  mapfile -t paths <<< "$files"
  git diff HEAD -- "${paths[@]}" > "$attempt" 2>/dev/null || true
  [ -n "$CONFLICT_ATTEMPT_FILE" ] && rm -f "$CONFLICT_ATTEMPT_FILE"
  CONFLICT_ATTEMPT_FILE="$attempt"

  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    CONFLICT_ATTEMPT_REASON="the resolver timed out after ${CF_TIMEOUT}s"
  elif [ "$rc" -ne 0 ]; then
    CONFLICT_ATTEMPT_REASON="the resolver declined (exit ${rc})"
  elif [ "$(git rev-parse HEAD)" != "$head_before" ] || ! _cf_rebasing; then
    CONFLICT_ATTEMPT_REASON="the resolver moved HEAD or ended the rebase itself"
  else
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      if [ -e "$f" ] && _cf_has_markers "$f"; then left="${left}${f}"$'\n'; fi
    done <<< "$files"
    if [ -n "$left" ]; then
      CONFLICT_ATTEMPT_REASON="the resolver left conflict markers in: $(printf '%s' "$left" | paste -sd, -)"
    else
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        if [ -e "$f" ]; then git add -- "$f"; else git rm -q --cached -- "$f" 2>/dev/null || true; fi
      done <<< "$files"
      if [ -n "$(_cf_unmerged)" ]; then
        CONFLICT_ATTEMPT_REASON="unmerged paths remain after the resolver: $(_cf_unmerged | paste -sd, -)"
      else
        CONFLICT_ATTEMPT_REASON=""
        _cf_note_resolved "$files" resolver
        echo "✅ The resolver resolved: $(printf '%s' "$files" | paste -sd, -)"
        return 0
      fi
    fi
  fi
  echo "❌ Conflict not resolved: ${CONFLICT_ATTEMPT_REASON}."
  return 1
}

# conflict_try_resolve: call with a rebase stopped in the current directory. rc 0 when the
# rebase was carried through to the end; rc 1 leaves the rebase stopped (conflicted files
# still unmerged) so the caller can list them and abort as before.
conflict_try_resolve() {
  local files union_left f stops=0
  [ -n "$CF_UNION_GLOBS" ] || [ "$CF_RESOLVER" != off ] || return 1
  while _cf_rebasing; do
    stops=$((stops + 1))
    [ "$stops" -le 50 ] || return 1   # a runaway rebase is not ours to finish
    files=$(_cf_unmerged)
    [ -n "$files" ] || return 1       # stopped for another reason: not a conflict
    union_left=""
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      if [ -n "$CF_UNION_GLOBS" ] && _cf_matches_union "$f" && _cf_union_one "$f"; then
        echo "🔗 Union-merged ${f} (declared append-only)."
        _cf_note_resolved "$f" union
      else
        union_left="${union_left}${f}"$'\n'
      fi
    done <<< "$files"
    union_left=$(printf '%s' "$union_left" | sed '/^$/d')
    if [ -n "$union_left" ]; then
      [ "$CF_RESOLVER" != off ] && [ "$CONFLICT_RESOLVER_TRIED" -eq 0 ] || return 1
      _cf_run_resolver "$union_left" || return 1
    fi
    # The resolved stop may leave nothing to commit (both sides made the same change).
    if ! GIT_EDITOR=true git "${_GIT_PINNED[@]}" rebase --continue >/dev/null 2>&1; then
      if _cf_rebasing && [ -z "$(_cf_unmerged)" ] \
         && git diff --cached --quiet; then
        git "${_GIT_PINNED[@]}" rebase --skip >/dev/null 2>&1 || true
      fi
    fi
  done
  return 0
}

# conflict_resolution_note: markdown for a comment. Empty when nothing was attempted.
conflict_resolution_note() {
  local note="" diff
  if [ -n "$CONFLICT_RESOLVED_FILES" ]; then
    note="

**Conflict auto-resolved** (#164, ${CONFLICT_RESOLVED_BY}) in the merge job's worktree:
$(printf '%s\n' "$CONFLICT_RESOLVED_FILES" | sed 's/^/- `/; s/$/`/')"
  fi
  if [ -n "$CONFLICT_ATTEMPT_REASON" ]; then
    note="${note}

**Automatic conflict resolution was tried and refused** (#164): ${CONFLICT_ATTEMPT_REASON}."
    if [ -s "$CONFLICT_ATTEMPT_FILE" ]; then
      diff=$(head -n 120 "$CONFLICT_ATTEMPT_FILE")
      note="${note}
<details><summary>Attempted resolution (first 120 lines of the diff)</summary>

\`\`\`diff
${diff}
\`\`\`
</details>"
    fi
  fi
  printf '%s' "$note"
}
