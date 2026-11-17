#!/bin/bash
# issue-spec.sh — print the spec a worker implements against: the issue body
# PLUS every human comment, oldest first, with autocoder's own bookkeeping
# (claim markers, work-started notices) filtered out.
#
# WHY THIS EXISTS (issue #134):
#   /fix used to read `.body` only. Every `.comments[]` read in it was a claim or
#   race check. The body is the oldest text on the page: review deltas,
#   corrected API contracts, narrowed scope and "that earlier instruction was
#   wrong" all arrive as comments, so a worker that reads only the body builds
#   the stalest spec available, confidently. A later comment overrides the body.
#
# Usage:
#   issue-spec.sh <issue-number>      # fetch via issue_get (configured backend)
#   issue-spec.sh --json <file|->     # format an issue_get JSON document
#
# Backend notes: the GitHub backend returns comments with author and timestamp;
# Jira and ADO return comment bodies only; the file backend folds comments into
# the body itself (as dated blockquotes), so its comments[] is always empty and
# the body already carries the whole thread.
#
# Exit: 0 printed, 1 usage error, 2 issue could not be fetched or parsed.

set -o pipefail

usage() { echo "usage: issue-spec.sh <issue-number> | --json <file|->" >&2; exit 1; }

# Comments matching this are autocoder bookkeeping, not spec. Keep it narrow:
# a filtered-out human correction is exactly the failure this script prevents.
BOOKKEEPING_RE='^🔒 \[autocoder-claim\]|^🔒 claim [^ ]+ [0-9]+$|^🤖 \*\*Automated Fix Started|^🚀 \*\*Enhancement Implementation Started|^🤖 \*\*Implementation Started'

format_spec() {
  jq -r --arg re "$BOOKKEEPING_RE" '
    def who: (.author.login? // .user.login? // .author? // "unknown")
             | if type == "string" then . else "unknown" end;
    def when: (.createdAt? // .created_at? // "") | if . == "" then "" else " at \(.)" end;
    ((.body // "") | sub("\\s+$"; "")) as $body
    | [ (.comments // [])[]
        | select(((.body // "") | gsub("^\\s+|\\s+$"; "")) as $b
                 | ($b != "") and (($b | test($re)) | not)) ]
    | to_entries
    | (if length == 0 then ""
       else "\n\n## Comments (oldest first — a later comment overrides the body and any earlier comment)\n"
            + (map("\n--- comment \(.key + 1) by \(.value | who)\(.value | when) ---\n\((.value.body // "") | sub("\\s+$"; ""))")
               | join("\n"))
       end) as $thread
    | $body + $thread
  '
}

case "${1:-}" in
  "") usage ;;
  --json)
    [ -n "${2:-}" ] || usage
    if [ "$2" = "-" ]; then format_spec || exit 2
    else [ -r "$2" ] || { echo "issue-spec.sh: cannot read $2" >&2; exit 2; }
         format_spec < "$2" || exit 2
    fi
    ;;
  *)
    [[ "$1" =~ ^[0-9]+$ ]] || usage
    SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=/dev/null
    source "$SELF_DIR/issue-fns.sh" || exit 2
    json=$(issue_get "$1") || { echo "issue-spec.sh: could not fetch issue #$1" >&2; exit 2; }
    printf '%s' "$json" | format_spec || exit 2
    ;;
esac
