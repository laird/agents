#!/bin/bash
# append-to-history.sh - Universal history logging
# Shared between modernize and autocoder plugins.
#
# SYNC NOTE: This file is the canonical source. Keep all copies in sync:
#   plugins/autocoder/scripts/append-to-history.sh
#   plugins/modernize/scripts/append-to-history.sh
#   .agent/scripts/append-to-history.sh
#   plugins/modernize/protocols/protocols-overview.md (inline heredoc)
# When updating this file, update ALL copies above.

# Parse flags
BACKEND="auto"
HISTORY_FILE="docs/HISTORY.md"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backend)
      BACKEND="$2"
      shift 2
      ;;
    --history-file)
      HISTORY_FILE="$2"
      shift 2
      ;;
    *)
      break
      ;;
  esac
done

# Validate positional parameters
if [ $# -ne 4 ]; then
    echo "Error: Requires exactly 4 positional parameters"
    echo "Usage: $0 [--backend file|github|auto] [--history-file PATH] \"TITLE\" \"WHAT_CHANGED\" \"WHY_CHANGED\" \"IMPACT\""
    exit 1
fi

TITLE="$1"
WHAT_CHANGED="$2"
WHY_CHANGED="$3"
IMPACT="$4"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# Resolve backend from $ISSUE_SOURCE if auto
if [ "$BACKEND" = "auto" ]; then
  if [ "${ISSUE_SOURCE:-}" = "github" ]; then
    BACKEND="github"
  else
    BACKEND="file"
  fi
fi

if [ "$BACKEND" = "github" ]; then
  # Ensure the history-log label exists (idempotent — safe to call repeatedly)
  gh label create "history-log" --description "Autocoder history log" --color "0075ca" 2>/dev/null || true

  # Find or create the history-log issue
  HISTORY_ISSUE=$(gh issue list --label "history-log" --state open --limit 1 --json number --jq '.[0].number' 2>/dev/null)

  if [ -z "$HISTORY_ISSUE" ] || [ "$HISTORY_ISSUE" = "null" ]; then
    HISTORY_ISSUE=$(gh issue create \
      --label "history-log" \
      --title "Autocoder History Log" \
      --body "Auto-created by autocoder to track agent activity. Each comment is one history entry." \
      --json number --jq '.number' 2>/dev/null)
    if [ -z "$HISTORY_ISSUE" ] || [ "$HISTORY_ISSUE" = "null" ]; then
      echo "⚠️  Could not create history-log issue — check gh auth and label permissions" >&2
      exit 1
    fi
    echo "✅ Created history-log issue #${HISTORY_ISSUE}"
  fi

  # Post history entry as a comment
  gh issue comment "$HISTORY_ISSUE" --body "## ${TIMESTAMP} — ${TITLE}

**What Changed**: ${WHAT_CHANGED}

**Why Changed**: ${WHY_CHANGED}

**Impact**: ${IMPACT}"
  echo "✅ History entry posted to issue #${HISTORY_ISSUE}"

else
  # File backend
  # If given a bare filename (no directory component, e.g. "HISTORY.md"), resolve
  # to the main git worktree root so parallel fix-loop workers all write to one file.
  if [[ "$HISTORY_FILE" != */* ]]; then
    MAIN_WT=$(git worktree list --porcelain 2>/dev/null | grep -m1 '^worktree ' | sed 's/^worktree //')
    if [ -n "$MAIN_WT" ] && [ "$MAIN_WT" != "$(pwd)" ]; then
      HISTORY_FILE="${MAIN_WT}/${HISTORY_FILE}"
    fi
  fi

  # Create file if it doesn't exist
  if [ ! -f "$HISTORY_FILE" ]; then
    HISTORY_DIR=$(dirname "$HISTORY_FILE")
    [ "$HISTORY_DIR" != "." ] && mkdir -p "$HISTORY_DIR"
    echo "# Project History" > "$HISTORY_FILE"
    echo "" >> "$HISTORY_FILE"
    echo "This file tracks all significant changes, migrations, and decisions." >> "$HISTORY_FILE"
    echo "" >> "$HISTORY_FILE"
  fi

  # Append entry
  cat >> "$HISTORY_FILE" << EOF

---

## $TIMESTAMP - $TITLE

**What Changed**: $WHAT_CHANGED

**Why Changed**: $WHY_CHANGED

**Impact**: $IMPACT

EOF
  echo "✅ Entry added to $HISTORY_FILE"
fi
