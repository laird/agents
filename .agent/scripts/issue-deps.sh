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
#   - in the issue body, on a line that STARTS with "Depends on" or "Blocked by"
#     (case-insensitive). List markers, a checkbox, a "[", quote marks and bold
#     or italics may come first: "Depends on: #11, #12", "- **Blocked by #12**",
#     "- [Depends on: #11 — reason]". Every #N on such a line is a dependency.
#     The words mid-sentence are prose, not a declaration (#181): "this depends
#     on how #12 lands" declares nothing. Template placeholders like
#     "#<sibling-subtask-number>" carry no number.
#   - on GitHub, as a native "blocked by" relationship (issue dependencies),
#     read for every open issue in one GraphQL query. Prefer these where you
#     can: they are explicit and no wording can create one by accident.
#
# An issue never waits on itself, on its parent (the "Sub-task of #N" line), or
# on its own sub-tasks (issues whose body says "Sub-task of #<it>"): a parent
# that lists its children next to "Depends on" would otherwise gate itself on
# work that can only start after it.
#
# A dependency is met when its state is closed (closed, done, resolved,
# completed, removed). One that can't be read counts as met: a typo must never
# wedge the queue. AUTOCODER_IGNORE_DEPENDENCIES=1 turns the filter off.
#
# Issues that wait on each other can never start. They stay gated (which one
# goes first is a human call), but the cycle is reported on stderr every time
# the queue is read: "⚠ cycle: #367 ↔ #387".
#
# Expects $_ifns_BACKEND_BIN (set by issue-fns.sh).

# jq definitions shared by the parsers below.
#   decl_prefix: what may precede a declaration at the start of a line: quote
#                marks, a heading, a list marker, a checkbox, "[", bold/italics.
#   parent_num:  issue object → the number on its "Sub-task of #N" line (a line
#                that starts with it, like a dependency), or null.
#   decl_deps:   issue object → sorted numbers its body declares, minus itself
#                and its parent.
_IDEPS_JQ_DEFS='
def decl_prefix:
  "(?i)^\\s*(>\\s*)*(#{1,6}\\s+)?([-*+]\\s+|[0-9]+[.)]\\s+)?(\\[[ xX]\\]\\s+)?\\[?\\s*([*_]{1,2}\\s*)?";
def parent_num:
  [ (.body // "") | split("\n")[]
    | select(test(decl_prefix + "sub-?task of\\s*#[0-9]"))
    | capture("(?i)sub-?task of\\s*#(?<n>[0-9]+)").n | tonumber ][0];
def decl_deps:
  (.number | tonumber? // .) as $self | parent_num as $parent
  | [ (.body // "") | split("\n")[]
      | select(test(decl_prefix + "(depends on|blocked by)\\b"))
      | scan("#([0-9]+)") | .[0] | tonumber
      | select(. != $self and . != $parent) ]
  | unique;
'

# Body-declared dependencies: JSON array of issues on stdin →
# {"<number>": [dep, ...]} on stdout.
_ideps_body_deps() {
  jq -c "$_IDEPS_JQ_DEFS"'[ .[] | { key: (.number | tostring), value: decl_deps } ] | from_entries'
}

# Parents: JSON array of issues on stdin → {"<number>": parent} for each issue
# that names one.
_ideps_parents() {
  jq -c "$_IDEPS_JQ_DEFS"'[ .[] | parent_num as $p | select($p != null)
                           | { key: (.number | tostring), value: $p } ] | from_entries'
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

# _ideps_state_is_met <state> — true (exit 0) for a closed state, or none.
_ideps_state_is_met() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    ''|closed|done|resolved|completed|removed) return 0 ;;
    *) return 1 ;;
  esac
}

# _ideps_lookup <n> [<back>] — one backend read of issue <n>: prints
# "<state> <parent> <waits-back>" ("-" for an unknown state or parent;
# <waits-back> is 1 when <n> declares a dependency on <back>, else 0). An
# unreadable issue prints "- - 0".
_ideps_lookup() {
  local out
  out=$("$_ifns_BACKEND_BIN" get "$1" 2>/dev/null \
    | jq -r --argjson back "${2:-0}" "$_IDEPS_JQ_DEFS"'
        "\(.state // "-" | if . == "" then "-" else . end) \(parent_num // "-") \(if (decl_deps | index($back)) then 1 else 0 end)"' 2>/dev/null)
  echo "${out:-- - 0}"
}

# Cycles in a wait graph: {"<n>": [m, ...]} on stdin → one line per cycle,
# each found once, starting from its lowest number: "⚠ cycle: #3 ↔ #7" or
# "⚠ cycle: #3 → #5 → #7 → #3".
_ideps_cycles() {
  jq -r '
    . as $g
    | def from($start; $path):
        ($path[-1] | tostring) as $cur
        | ($g[$cur] // [])[] as $next
        | if $next == $start then $path
          elif ($next < $start) or ($path | index([$next])) or ($path | length) > 25 then empty
          else from($start; $path + [$next]) end;
      [ keys[] | tonumber ] | sort[] as $s | from($s; [$s])
    | if length == 2 then "⚠ cycle: #\(.[0]) ↔ #\(.[1])"
      else "⚠ cycle: \(map("#\(.)") | join(" → ")) → #\(.[0])" end' 2>/dev/null
}

# Split a JSON array of issues (stdin) into those whose dependencies are all
# met (stdout, same shape) and those still waiting (one line each on stderr:
# "⏳ #350 waits on #347, #348", then any cycles among them). Non-array input
# passes through untouched.
_ideps_filter() {
  local issues body_deps parents native unmet='[]' n result state parent
  issues=$(cat)
  if [ "${AUTOCODER_IGNORE_DEPENDENCIES:-}" = "1" ] \
     || ! printf '%s' "$issues" | jq -e 'type == "array" and length > 0' >/dev/null 2>&1; then
    printf '%s\n' "$issues"; return 0
  fi
  body_deps=$(printf '%s' "$issues" | _ideps_body_deps 2>/dev/null) || body_deps='{}'
  [ -n "$body_deps" ] || body_deps='{}'
  parents=$(printf '%s' "$issues" | _ideps_parents 2>/dev/null) || parents='{}'
  [ -n "$parents" ] || parents='{}'
  native='{}'
  case "$_ifns_BACKEND_BIN" in *issues-gh.sh) native=$(_ideps_gh_blockers) ;; esac
  # Resolve each distinct body dependency once. One that is itself in this
  # (open) list is unmet without asking the backend; one outside it is read
  # once, for its state and for its parent (a sub-task being worked must not
  # gate its parent).
  for n in $(printf '%s' "$body_deps" | jq -r '[ .[][] ] | unique | .[]'); do
    if printf '%s' "$issues" | jq -e --argjson n "$n" 'any(.[]; .number == $n or .number == ($n | tostring))' >/dev/null 2>&1; then
      unmet=$(printf '%s' "$unmet" | jq -c --argjson n "$n" '. + [$n]')
      continue
    fi
    read -r state parent _ <<<"$(_ideps_lookup "$n")"
    [ "$state" = "-" ] && state=""
    if [ "$parent" != "-" ] && [ -n "$parent" ]; then
      parents=$(printf '%s' "$parents" | jq -c --arg k "$n" --argjson p "$parent" '. + {($k): $p}' 2>/dev/null || printf '%s' "$parents")
    fi
    _ideps_state_is_met "$state" || unmet=$(printf '%s' "$unmet" | jq -c --argjson n "$n" '. + [$n]')
  done
  result=$(printf '%s' "$issues" | jq -c --argjson deps "$body_deps" --argjson native "$native" \
                                        --argjson unmet "$unmet" --argjson parents "$parents" '
    [ .[] | (.number | tostring) as $k | (.number | tonumber? // .) as $self
      | { issue: .,
          waiting: ( ((($deps[$k] // []) | map(select(IN($unmet[])))) + ($native[$k] // []))
                     | map(select(. != $self and . != $parents[$k] and $parents[tostring] != $self))
                     | unique ) } ]
    | { ready: [ .[] | select(.waiting | length == 0) | .issue ],
        waiting: [ .[] | select(.waiting | length > 0) | "⏳ #\(.issue.number) waits on \(.waiting | map("#\(.)") | join(", "))" ],
        graph: ( [ .[] | (.issue.number | tostring) ] as $open
                 | [ .[] | select(.waiting | length > 0)
                     | { key: (.issue.number | tostring),
                         value: [ .waiting[] | select((tostring) | IN($open[])) ] } ]
                 | from_entries ) }') \
    || { printf '%s\n' "$issues"; return 0; }
  printf '%s' "$result" | jq -r '.waiting[]' >&2
  printf '%s' "$result" | jq -c '.graph' | _ideps_cycles >&2
  printf '%s' "$result" | jq -c '.ready'
}

# issue_unmet_dependencies <number> — print the dependencies of <number> that
# are not closed yet, space-separated (empty when it is free to start).
# Exit 0 when none, 1 when some. For explicit dispatch ("/fix 350"). A
# dependency that in turn waits on <number> is reported on stderr as a cycle.
issue_unmet_dependencies() {
  local n="$1" issue deps native parent waiting=() d state dparent back
  [ "${AUTOCODER_IGNORE_DEPENDENCIES:-}" = "1" ] && return 0
  issue=$("$_ifns_BACKEND_BIN" get "$n" 2>/dev/null) || return 0
  deps=$(printf '%s' "$issue" | jq -c '[.]' | _ideps_body_deps 2>/dev/null | jq -r --arg k "$n" '.[$k] // [] | .[]' 2>/dev/null)
  parent=$(printf '%s' "$issue" | jq -r "$_IDEPS_JQ_DEFS"'parent_num // empty' 2>/dev/null)
  for d in $deps; do
    read -r state dparent back <<<"$(_ideps_lookup "$d" "$n")"
    [ "$state" = "-" ] && state=""
    [ "$dparent" = "$n" ] && continue        # its own sub-task
    _ideps_state_is_met "$state" && continue
    waiting+=("#$d")
    [ "$back" = "1" ] && echo "⚠ cycle: #$n ↔ #$d" >&2
  done
  case "$_ifns_BACKEND_BIN" in
    *issues-gh.sh)
      native=$(_ideps_gh_blockers | jq -r --arg k "$n" '.[$k] // [] | .[]' 2>/dev/null)
      for d in $native; do
        { [ "$d" = "$n" ] || [ "$d" = "$parent" ]; } && continue
        case " ${waiting[*]} " in *" #$d "*) continue ;; esac
        read -r _ dparent _ <<<"$(_ideps_lookup "$d")"
        [ "$dparent" = "$n" ] && continue    # its own sub-task
        waiting+=("#$d")
      done ;;
  esac
  [ ${#waiting[@]} -eq 0 ] && return 0
  echo "${waiting[*]}"
  return 1
}
