#!/bin/bash
# Create a GitHub issue with multi-line body support
#
# Opens your $EDITOR for composing the issue body, then creates the issue.
# Supports labels, assignees, and all standard gh issue create flags.
#
# Usage:
#   create-issue.sh "Issue title" [--label bug] [--label P1] [--assignee @me]
#   create-issue.sh                # Interactive: prompts for title too
#   create-issue.sh --editor       # Opens editor for both title and body
#
# The first line of editor content is the title, remaining lines are the body.
# Alternatively, pass --title "title" to skip the title prompt.

set -e

# If --editor flag is present, pass through directly to gh
if [[ " $* " == *" --editor "* ]] || [[ " $* " == *" -e "* ]]; then
  exec gh issue create "$@"
fi

# Collect title from first positional arg or prompt
TITLE=""
GH_ARGS=()

while [[ $# -gt 0 ]]; do
  case $1 in
    --title|-t)
      TITLE="$2"
      shift 2
      ;;
    --body|-b|--body-file|-F)
      # If user explicitly passes body, just forward everything to gh
      exec gh issue create "$@"
      ;;
    -*)
      GH_ARGS+=("$1")
      if [[ "$1" == --* ]] && [[ $# -gt 1 ]] && [[ "$2" != -* ]]; then
        GH_ARGS+=("$2")
        shift
      fi
      shift
      ;;
    *)
      if [ -z "$TITLE" ]; then
        TITLE="$1"
      else
        GH_ARGS+=("$1")
      fi
      shift
      ;;
  esac
done

# If no title, prompt for one
if [ -z "$TITLE" ]; then
  echo -n "Issue title: "
  read -r TITLE
  if [ -z "$TITLE" ]; then
    echo "❌ Title is required" >&2
    exit 1
  fi
fi

# Create temp file for body
TMPFILE=$(mktemp "${TMPDIR:-/tmp}/gh-issue-body.XXXXXX.md")
trap 'rm -f "$TMPFILE"' EXIT

cat > "$TMPFILE" << 'TEMPLATE'

<!-- Write your issue description below this line. Save and close to create. -->
<!-- Lines starting with <!-- are comments and will be stripped. -->
<!-- Delete this template text and replace with your description. -->

## Description



## Acceptance Criteria

- [ ]

TEMPLATE

# Open editor
EDITOR="${VISUAL:-${EDITOR:-vi}}"
"$EDITOR" "$TMPFILE"

# Strip HTML comments and check if body has content
BODY=$(sed '/^<!--.*-->$/d' "$TMPFILE" | sed '/^$/N;/^\n$/d')

if [ -z "$(echo "$BODY" | tr -d '[:space:]')" ]; then
  echo "❌ Empty body, aborting issue creation" >&2
  exit 1
fi

# Create the issue
gh issue create --title "$TITLE" --body-file "$TMPFILE" "${GH_ARGS[@]}"
