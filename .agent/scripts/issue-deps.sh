#!/bin/bash
# issue-deps.sh — issue dependencies: an issue is claimable only once every
# issue it depends on is closed. Sourced by issue-fns.sh; do not execute.
#
# Why this exists: workers self-claim the highest-priority open issue, and the
# decomposition template writes "Depends on: #N" into sub-task bodies — but
# nothing read it. A worker that finished one sub-task promptly claimed its
# dependents, released them by hand, and left stale `working` labels behind.
#
# A dependency is declared either way:
#   - in the issue body, on a line that says "Depends on" or "Blocked by":
#     every #N on that line is a dependency ("- **Depends on: #347 and #348**",
#     "Blocked by #12"). "Sub-task of #N" (the parent) is not a dependency, and
#     template placeholders like "#<sibling-subtask-number>" carry no number.
#   - on GitHub, as a native "blocked by" relationship (issue dependencies),
#     read for every open issue in one GraphQL query.
#
# A dependency is met when its state is closed (closed, done, resolved,
# completed, removed). One that can't be read counts as met: a typo must never
# wedge the queue. AUTOCODER_IGNORE_DEPENDENCIES=1 turns the filter off.
#
# Expects $_ifns_BACKEND_BIN (set by issue-fns.sh).

# Body-declared dependencies: JSON array of issues on stdin →
# {"<number>": [dep, ...]} on stdout.
_ideps_body_deps() {
  jq -c '[ .[] | {
      key: (.number | tostring),
      value: ([ (.body // "") | split("\n")[]
                | select(test("(?i)\\b(depends on|blocked by)\\b"))
                | [ scan("#([0-9]+)") | .[0] | tonumber ] ] | add // [] | unique)
    } ] | from_entries'
}

# Native GitHub blockers that are still open: {"<number>": [blocker, ...]}.
# Fails open to {} (no gh, no repo, or a server without issue dependencies).
_ideps_gh_blockers() {
  local repo
  # No origin (a scratch repo, a test fixture): nothing to ask GitHub about.
  git remote get-url origin >/dev/null 2>&1 || { echo '{}'; return; }
  repo=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || { echo '{}'; return; }
  [ -n "$repo" ] || { echo '{}'; return; }
  gh api graphql --paginate -f owner="${repo%%/*}" -f name="${repo#*/}" -f query='
    query($owner: String!, $name: String!, $endCursor: String) {
      repository(owner: $owner, name: $name) {
        issues(states: OPEN, first: 100, after: $endCursor) {
          pageInfo { hasNextPage endCursor }
          nodes { number blockedBy(first: 50) { nodes { number state } } }
        }
      }
    }' 2>/dev/null \
    | jq -s -c '[ .[].data.repository.issues.nodes[]
                  | { key: (.number | tostring),
                      value: [ .blockedBy.nodes[] | select(.state == "OPEN") | .number ] } ]
                | from_entries' 2>/dev/null \
    || echo '{}'
}

# True (exit 0) when the backend reports issue <n> closed, or can't read it.
_ideps_is_met() {
  local state
  state=$("$_ifns_BACKEND_BIN" get "$1" 2>/dev/null | jq -r '.state // empty' 2>/dev/null)
  case "$(printf '%s' "$state" | tr '[:upper:]' '[:lower:]')" in
    ''|closed|done|resolved|completed|removed) return 0 ;;
    *) return 1 ;;
  esac
}

# Split a JSON array of issues (stdin) into those whose dependencies are all
# met (stdout, same shape) and those still waiting (one line each on stderr:
# "⏳ #350 waits on #347, #348"). Non-array input passes through untouched.
_ideps_filter() {
  local issues body_deps native unmet='[]' n result
  issues=$(cat)
  if [ "${AUTOCODER_IGNORE_DEPENDENCIES:-}" = "1" ] \
     || ! printf '%s' "$issues" | jq -e 'type == "array" and length > 0' >/dev/null 2>&1; then
    printf '%s\n' "$issues"; return 0
  fi
  body_deps=$(printf '%s' "$issues" | _ideps_body_deps 2>/dev/null) || body_deps='{}'
  [ -n "$body_deps" ] || body_deps='{}'
  native='{}'
  case "$_ifns_BACKEND_BIN" in *issues-gh.sh) native=$(_ideps_gh_blockers) ;; esac
  # Resolve each distinct body dependency once. One that is itself in this
  # (open) list is unmet without asking the backend.
  for n in $(printf '%s' "$body_deps" | jq -r '[ .[][] ] | unique | .[]'); do
    if printf '%s' "$issues" | jq -e --argjson n "$n" 'any(.[]; .number == $n or .number == ($n | tostring))' >/dev/null 2>&1 \
       || ! _ideps_is_met "$n"; then
      unmet=$(printf '%s' "$unmet" | jq -c --argjson n "$n" '. + [$n]')
    fi
  done
  result=$(printf '%s' "$issues" | jq -c --argjson deps "$body_deps" --argjson native "$native" --argjson unmet "$unmet" '
    [ .[] | (.number | tostring) as $k
      | { issue: ., waiting: ((($deps[$k] // []) | map(select(IN($unmet[])))) + ($native[$k] // []) | unique) } ]
    | { ready: [ .[] | select(.waiting | length == 0) | .issue ],
        waiting: [ .[] | select(.waiting | length > 0) | "⏳ #\(.issue.number) waits on \(.waiting | map("#\(.)") | join(", "))" ] }') \
    || { printf '%s\n' "$issues"; return 0; }
  printf '%s' "$result" | jq -r '.waiting[]' >&2
  printf '%s' "$result" | jq -c '.ready'
}

# issue_unmet_dependencies <number> — print the dependencies of <number> that
# are not closed yet, space-separated (empty when it is free to start).
# Exit 0 when none, 1 when some. For explicit dispatch ("/fix 350").
issue_unmet_dependencies() {
  local n="$1" issue deps native waiting=() d
  [ "${AUTOCODER_IGNORE_DEPENDENCIES:-}" = "1" ] && return 0
  issue=$("$_ifns_BACKEND_BIN" get "$n" 2>/dev/null) || return 0
  deps=$(printf '%s' "$issue" | jq -c '[.]' | _ideps_body_deps 2>/dev/null | jq -r --arg k "$n" '.[$k] // [] | .[]' 2>/dev/null)
  for d in $deps; do _ideps_is_met "$d" || waiting+=("#$d"); done
  case "$_ifns_BACKEND_BIN" in
    *issues-gh.sh)
      native=$(_ideps_gh_blockers | jq -r --arg k "$n" '.[$k] // [] | .[]' 2>/dev/null)
      for d in $native; do case " ${waiting[*]} " in *" #$d "*) ;; *) waiting+=("#$d") ;; esac; done ;;
  esac
  [ ${#waiting[@]} -eq 0 ] && return 0
  echo "${waiting[*]}"
  return 1
}
