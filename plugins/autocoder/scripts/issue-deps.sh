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
# completed, removed). One the tracker could not READ (a rate limit, an outage,
# a 5xx) is UNMET and said so (#380): under a rate limit every lookup fails, and
# "unreadable counts as met" let gated issues read as claimable and woke managers
# for work that could not start. A clean "no such issue" (a typo'd number) still
# counts as met: a typo must never wedge the queue. AUTOCODER_IGNORE_DEPENDENCIES=1
# turns the filter off.
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
    ''|closed|done|resolved|completed|removed|merged) return 0 ;;
    *) return 1 ;;
  esac
}

# _ideps_say_unreadable <n> — the one wording for a dependency the tracker could not read (#380).
_ideps_say_unreadable() {
  echo "⏳ #$1 could not be read (a tracker error, or no such issue): counted as unmet until it can be" >&2
}

# _ideps_lookup <n> [<back>] — one backend read of issue <n>: prints
# "<state> <parent> <waits-back>" ("-" for an unknown state or parent;
# <waits-back> is 1 when <n> declares a dependency on <back>, else 0). An
# unreadable issue prints "- - 0".
_ideps_lookup() {
  local raw out err
  # A read the backend could not make is "unreadable", never silently "no state" (#380), EXCEPT
  # a clean "no such issue" (the backend's not-found text, or a silent negative exit as the file
  # backend gives), which is a typo'd number and must never wedge the queue: that reads as before.
  err=$(mktemp "${TMPDIR:-/tmp}/ideps-err.XXXXXX") || err=""
  if ! raw=$("$_ifns_BACKEND_BIN" get "$1" 2>"${err:-/dev/null}"); then
    local text=""
    [ -n "$err" ] && { text=$(cat "$err" 2>/dev/null); rm -f "$err"; }
    if [ -z "$text" ] || printf '%s' "$text" | grep -qiE 'could not resolve|not found|no such issue|does not exist'; then
      echo "- - 0"; return 0
    fi
    echo "unreadable - 0"; return 0
  fi
  [ -n "$err" ] && rm -f "$err"
  out=$(printf '%s' "$raw" \
    | jq -r --argjson back "${2:-0}" "$_IDEPS_JQ_DEFS"'
        "\(.state // "-" | if . == "" then "-" else . end) \(parent_num // "-") \(if (decl_deps | index($back)) then 1 else 0 end)"' 2>/dev/null)
  echo "${out:-unreadable - 0}"
}

# _ideps_gh_lookup_many <n>... — the GitHub backend's batched read of the
# dependencies outside the open list: ONE GraphQL request per 100 numbers
# (aliased `issueOrPullRequest(number:)` fields, so a dependency on a pull
# request keeps its state as `gh issue view` gave it; a merged one is met),
# where `_ideps_lookup` costs one `gh issue view` per number. Measured on a
# 500-issue backlog, the per-number reads took 0.7 to 0.9 s each and put the
# claim tick past its ceiling; the batch is one round trip.
#
# Prints one line per number: "<n> <state> <parent>" ("-" for no parent).
#   - a number GitHub answered: its state (OPEN, CLOSED, MERGED) and the
#     "Sub-task of #N" parent read from its body;
#   - a clean not-found (the alias is null AND its error is NOT_FOUND, "Could
#     not resolve"): state "-", met as before (a typo'd number never wedges the
#     queue);
#   - anything else (no origin, no gh, no repo, a failed request, a null alias
#     with any other error or none): state "unreadable", unmet and said (#380).
#     A failed request marks ONLY its own chunk's numbers unreadable; the
#     chunks GitHub answered keep their answers.
_ideps_gh_lookup_many() {
  local repo owner name n query aliases out chunk
  [ $# -gt 0 ] || return 0
  local all=("$@")
  if ! git remote get-url origin >/dev/null 2>&1 \
     || ! repo=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || [ -z "$repo" ]; then
    for n in "${all[@]}"; do echo "$n unreadable -"; done
    return 0
  fi
  owner="${repo%%/*}"; name="${repo#*/}"
  set -- "${all[@]}"
  while [ $# -gt 0 ]; do
    chunk=("${@:1:100}"); shift "${#chunk[@]}"
    aliases=""
    for n in "${chunk[@]}"; do
      case "$n" in ''|*[!0-9]*) echo "$n unreadable -"; continue ;; esac
      # Past GraphQL's Int a number fails the whole request's validation; it is a pasted id, not an issue: a clean not-found.
      [ "${#n}" -le 10 ] && [ "$n" -le 2147483647 ] 2>/dev/null || { echo "$n - -"; continue; }
      aliases="$aliases i$n: issueOrPullRequest(number: $n) { ... on Issue { number state body } ... on PullRequest { number state body } }"
    done
    [ -n "$aliases" ] || continue
    query="query(\$owner: String!, \$name: String!) { repository(owner: \$owner, name: \$name) {$aliases } }"
    # gh exits 1 when any alias is an error, with the data of the others beside the errors:
    # read the data whatever the exit; only a missing repository object is a failed request.
    out=$(gh api graphql -f owner="$owner" -f name="$name" -f query="$query" 2>/dev/null) || true
    if ! printf '%s' "$out" | jq -e '.data.repository | type == "object"' >/dev/null 2>&1; then
      for n in "${chunk[@]}"; do echo "$n unreadable -"; done
      continue
    fi
    printf '%s' "$out" | jq -r "$_IDEPS_JQ_DEFS"'
      ( [ (.errors // [])[] | select((.path // []) | length >= 2) | { key: (.path[1] | tostring), value: . } ] | from_entries ) as $errs
      | .data.repository | to_entries[] | select(.key | test("^i[0-9]+$"))
      | (.key | ltrimstr("i")) as $n
      | if .value == null then
          ( $errs[.key] // {} ) as $e
          | if ($e.type // "") == "NOT_FOUND" or (($e.message // "") | test("could not resolve|not found|does not exist"; "i"))
            then "\($n) - -" else "\($n) unreadable -" end
        else "\($n) \(.value.state // "unreadable") \(.value | parent_num // "-")" end' 2>/dev/null \
      || for n in "${chunk[@]}"; do echo "$n unreadable -"; done
  done
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
  # gate its parent). On the GitHub backend the outside ones are read in ONE
  # batched request (`_ideps_gh_lookup_many`); any other backend reads each.
  # One jq pass splits the two sets, and one more adds the unmet ones, so a
  # backlog of a hundred dependencies costs a handful of processes, not hundreds.
  local split outside=() lines unmet_add=() seen split_failed="" prev
  split=$(printf '%s' "$issues" | jq -c --argjson deps "$body_deps" '
    [ .[].number | tonumber? // . ] as $open
    | ([ $deps[][] ] | unique) as $all
    | { inside: [ $all[] | select(IN($open[])) ], outside: [ $all[] | select(IN($open[]) | not) ] }' 2>/dev/null) || split=""
  if [ -z "$split" ]; then
    # The split could not be made: every dependency is unreadable, never silently met (#380).
    split_failed=1
    split=$(printf '%s' "$body_deps" | jq -c '{ inside: [], outside: ([ .[][] ] | unique) }' 2>/dev/null) || split='{"inside":[],"outside":[]}'
  fi
  prev="$unmet"
  unmet=$(jq -n -c --argjson u "$unmet" --argjson s "$split" '$u + $s.inside | unique' 2>/dev/null) || unmet="$prev"
  mapfile -t outside < <(printf '%s' "$split" | jq -r '.outside[] | select(type == "number") | tostring' 2>/dev/null)
  if [ ${#outside[@]} -gt 0 ]; then
    if [ -n "$split_failed" ]; then
      lines=$(for n in "${outside[@]}"; do echo "$n unreadable -"; done)
    else
      case "$_ifns_BACKEND_BIN" in
        *issues-gh.sh) lines=$(_ideps_gh_lookup_many "${outside[@]}") ;;
        *) lines=$(for n in "${outside[@]}"; do read -r state parent _ <<<"$(_ideps_lookup "$n")"; echo "$n $state $parent"; done) ;;
      esac
    fi
    seen=" "
    while read -r n state parent _; do
      case "$n" in ''|*[!0-9]*) continue ;; esac   # not a number: no line of ours; the number stays unanswered below
      seen="$seen$n "
      [ "$state" = "-" ] && state=""
      if [ "$state" = "unreadable" ]; then
        _ideps_say_unreadable "$n"; unmet_add+=("$n"); continue
      fi
      _ideps_state_is_met "$state" || unmet_add+=("$n")
    done <<<"$lines"
    # A number no line answered (a read that produced nothing) is unreadable, never silently met.
    for n in "${outside[@]}"; do
      case "$seen" in *" $n "*) ;; *) _ideps_say_unreadable "$n"; unmet_add+=("$n") ;; esac
    done
    # The parents the answered dependencies named, in one pass over the same lines.
    prev="$parents"
    parents=$(printf '%s\n' "$lines" | jq -R -s -c --argjson p "$parents" '
      $p + ( [ split("\n")[] | select(length > 0) | split(" ")
               | select(length >= 3 and (.[0] | test("^[0-9]+$")) and (.[2] | test("^[0-9]+$")))
               | { key: .[0], value: (.[2] | tonumber) } ] | from_entries )' 2>/dev/null) || parents="$prev"
    if [ ${#unmet_add[@]} -gt 0 ]; then
      prev="$unmet"
      unmet=$(printf '%s\n' "${unmet_add[@]}" | jq -R -s -c --argjson u "$unmet" '$u + (split("\n") | map(select(test("^[0-9]+$")) | tonumber)) | unique' 2>/dev/null) || unmet="$prev"
    fi
  fi
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
    if [ "$state" = "unreadable" ]; then
      _ideps_say_unreadable "$d"; waiting+=("#$d"); continue
    fi
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
