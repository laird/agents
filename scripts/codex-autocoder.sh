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
SOURCE_PATH="${BASH_SOURCE[0]}"
while [ -L "$SOURCE_PATH" ]; do
  SOURCE_DIR="$(cd "$(dirname "$SOURCE_PATH")" && pwd)"
  SOURCE_PATH="$(readlink "$SOURCE_PATH")"
  [[ "$SOURCE_PATH" != /* ]] && SOURCE_PATH="$SOURCE_DIR/$SOURCE_PATH"
done
SCRIPT_DIR=$(cd "$(dirname "$SOURCE_PATH")" && pwd)
AGENTS_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
START_ISSUE_WORK="$AGENTS_ROOT/plugins/autocoder/scripts/start-issue-work.sh"
MERGE_TO_INTEGRATION="$AGENTS_ROOT/plugins/autocoder/scripts/merge-to-integration.sh"
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
    "- Before editing files for any issue N, run: bash '$START_ISSUE_WORK' N" \
    "- The issue-start helper is mandatory: it claims the issue, switches to feature/issue-N, and posts the Implementation Started marker peers use to validate the lock." \
    "- If the helper exits nonzero, do not work that issue; choose another claimable issue or stop with IDLE_NO_WORK_AVAILABLE if none exists." \
    "- If the wrapper already ran the helper for a targeted issue, verify you are on feature/issue-N and do not rerun it unless you are still on the same branch." \
    "- Use existing repo scripts where appropriate, especially plugins/autocoder/scripts/regression-test.sh and scripts/append-to-history.sh." \
    "- If you make code changes, run the most relevant tests you can without weakening repo standards." \
    "- If you make code changes, create a git commit with a concise message after tests pass." \
    "- To land the work, run: bash '$MERGE_TO_INTEGRATION' --feature feature/issue-N --issue N --integration main --test-cmd '<the repo regression test command>' (use enhancement/issue-N-auto for enhancements)." \
    "- That helper is worktree-safe: it merges origin/main into your feature branch, re-runs tests on the combined tree, and pushes to origin/main with retry. Do NOT merge into or push the per-worktree branch (main-wt-N) — that strands work off main." \
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
      bash "$START_ISSUE_WORK" "$ISSUE_NUMBER"
      USER_SCOPE="Work issue #$ISSUE_NUMBER specifically. The wrapper has already run the issue-start handshake; verify the current branch is feature/issue-$ISSUE_NUMBER before editing."
    else
      USER_SCOPE="Select the next highest-priority unblocked issue yourself."
    fi

    PROMPT="$(build_fix_prompt "$USER_SCOPE")"

    codex exec --dangerously-bypass-approvals-and-sandbox -C "$REPO_ROOT" "$PROMPT"
    ;;
  review-blocked)
    EXTRA_GUIDANCE="${*:-}"
    PROMPT="$(build_review_blocked_prompt "$EXTRA_GUIDANCE")"

    codex exec --dangerously-bypass-approvals-and-sandbox -C "$REPO_ROOT" "$PROMPT"
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
