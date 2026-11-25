#!/usr/bin/env bash
# claim-window.sh — count the claim evidence that belongs to the current claim (#309).
#
# claim-issue.sh refuses an issue when it sees a second `[autocoder-claim]` marker
# or an earlier work-started comment. Counted over the whole comment history, one
# abandoned run (a start comment, or the marker of a worker that lost a race and
# backed off) makes the issue unclaimable forever, even after its claim was
# released or the issue was blocked and approved again (#144).
#
# Two rules narrow the count:
#   1. Only comments after the last one that ended a claim count: a release (🔓,
#      from /fix, the gate, release-gate-claim.sh or the abandoned-claim sweep) or
#      a block (🚫 / 🎨, from add-blocking-label.sh). With --own, that ender is
#      looked for before this run's marker only, so a release posted after our
#      marker cannot hide a rival's marker from us.
#   2. With --own, a rival marker counts only when it was posted within
#      --race-window seconds (default 120) before ours, or after it, by the
#      server's createdAt. An older marker is a racer that backed off: a racer
#      that went on to work would have posted a start comment, which rule 1 still
#      counts. A marker without a timestamp always counts.
#
# Usage:
#   issue_get N | claim-window.sh [--own TEXT] [--race-window SECS] [--branch BRANCH]
#
#   --own TEXT     a string unique to this run's `[autocoder-claim]` marker.
#   --branch B     count only work-started comments that name B.
#
# Prints "<markers> <started>": `[autocoder-claim]` markers, and work-started
# comments that are not markers, in the window. Prints "0 0" for input it
# cannot parse.

OWN=""
BRANCH=""
RACE_WINDOW=120
while [ $# -gt 0 ]; do
  case "$1" in
    --own|--branch|--race-window)
      [ $# -ge 2 ] || { echo "claim-window.sh: $1 needs a value" >&2; exit 2; }
      case "$1" in
        --own) OWN="$2" ;;
        --branch) BRANCH="$2" ;;
        --race-window) RACE_WINDOW="$2" ;;
      esac
      shift 2 ;;
    *) echo "claim-window.sh: unknown argument $1" >&2; exit 2 ;;
  esac
done
case "$RACE_WINDOW" in ''|*[!0-9]*) echo "claim-window.sh: --race-window must be whole seconds" >&2; exit 2 ;; esac

jq -r --arg own "$OWN" --arg branch "$BRANCH" --argjson win "$RACE_WINDOW" '
  def ts: (.createdAt // "" | if . == "" then null else (try (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) catch null) end);
  [(.comments // [])[] | {body: (.body // ""), t: ts}] as $c
  | (if $own == "" then null
     else ([range(0; $c | length) | select($c[.].body | contains($own))] | first)
     end) as $mine
  | ($mine // ($c | length)) as $limit
  | ([range(0; $limit) | select($c[.].body | test("^\\s*(🔓|🚫|🎨)"))] | max // -1) as $start
  | (if $mine == null then null else $c[$mine].t end) as $mine_t
  | $c[($start + 1):] as $live
  | [ ([$live[]
        | select(.body | test("\\[autocoder-claim\\]"))
        | select($mine_t == null or .t == null or .t >= ($mine_t - $win))] | length),
      ([$live[] | .body
        | select(test("Automated Fix Started|Implementation Started|Enhancement Implementation Started"))
        | select(test("\\[autocoder-claim\\]") | not)
        | select($branch == "" or contains($branch))] | length) ]
  | "\(.[0]) \(.[1])"
' 2>/dev/null || echo "0 0"
