#!/bin/bash
# Run one Codex autocoder workflow pass.
# Usage:
#   codex-autocoder.sh fix [issue_number]
#   codex-autocoder.sh review-blocked [extra guidance]

set -euo pipefail

usage() {
  echo "Usage:"
  echo "  $0 fix [issue_number]"
  echo "  $0 review-blocked [extra guidance]"
}

if [ $# -lt 1 ]; then
  usage >&2
  exit 1
fi

if ! command -v codex >/dev/null 2>&1; then
  echo "❌ codex CLI not found in PATH" >&2
  exit 1
fi

if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
  echo "❌ Must be run inside a git repository" >&2
  exit 1
fi

REPO_ROOT=$(git rev-parse --show-toplevel)
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
AGENTS_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
COMMAND="$1"
shift

build_fix_prompt() {
  local user_scope="$1"
  printf '%s\n' \
    "Use the repository's Codex autocoder workflow for exactly one pass." \
    "" \
    "Start by reading:" \
    "- AGENTS.md" \
    "- skills/autocoder/SKILL.md" \
    "- skills/autocoder/references/workflow-map.md" \
    "- skills/autocoder/references/command-mapping.md" \
    "" \
    "Use Claude plugin docs only as legacy reference material. Do not rely on Claude-only runtime features like slash commands, hooks, or /loop." \
    "" \
    "$user_scope" \
    "" \
    "Execution requirements:" \
    "- Respect the workflow order: triage -> bugs -> regression failures -> approved enhancements -> proposals." \
    "- Respect blocking labels: needs-approval, needs-design, needs-clarification, too-complex." \
    "- Use existing repo scripts where appropriate, especially plugins/autocoder/scripts/regression-test.sh and scripts/append-to-history.sh." \
    "- If you make code changes, run the most relevant tests you can without weakening repo standards." \
    "- If you make code changes, create a git commit with a concise message after tests pass." \
    "- After committing successful code changes, push the current HEAD to the appropriate remote branch unless repo rules explicitly forbid that push target." \
    "- Log significant work with scripts/append-to-history.sh." \
    "- Stop after one actionable unit of work and summarize the outcome." \
    "" \
    "If there is no actionable work after checking the queue, the final line of your response must be exactly:" \
    "IDLE_NO_WORK_AVAILABLE"
}

build_review_blocked_prompt() {
  local extra_guidance="$1"
  local shared_fetch_script="$AGENTS_ROOT/plugins/autocoder/scripts/fetch-blocked-issues.sh"
  printf '%s\n' \
    "Review the repository's blocked autocoder issues." \
    "" \
    "Start by reading:" \
    "- AGENTS.md" \
    "- skills/autocoder/SKILL.md" \
    "- skills/autocoder/references/workflow-map.md" \
    "- plugins/autocoder/scripts/fetch-blocked-issues.sh if present in this repo" \
    "- otherwise use the shared runtime script at $shared_fetch_script" \
    "" \
    "Then:" \
    "- Run the blocked-issues fetch script from the repo-local plugins path when present, otherwise from the shared runtime path above." \
    "- Summarize the blocked queue by priority and blocking label." \
    "- Recommend the next 1-3 issues a human should review first." \
    "- For the top issue, provide 2-3 concrete approaches with one recommended option." \
    "- Do not approve, reject, relabel, or close issues unless the user explicitly asks." \
    "" \
    "Extra guidance from the caller:" \
    "$extra_guidance"
}

case "$COMMAND" in
  fix)
    ISSUE_NUMBER="${1:-}"
    if [ -n "$ISSUE_NUMBER" ]; then
      USER_SCOPE="Work issue #$ISSUE_NUMBER specifically."
    else
      USER_SCOPE="Select the next highest-priority unblocked issue yourself."
    fi

    PROMPT="$(build_fix_prompt "$USER_SCOPE")"

    codex exec --full-auto -C "$REPO_ROOT" "$PROMPT"
    ;;
  review-blocked)
    EXTRA_GUIDANCE="${*:-}"
    PROMPT="$(build_review_blocked_prompt "$EXTRA_GUIDANCE")"

    codex exec --full-auto -C "$REPO_ROOT" "$PROMPT"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    echo "❌ Unknown command: $COMMAND" >&2
    usage >&2
    exit 1
    ;;
esac
