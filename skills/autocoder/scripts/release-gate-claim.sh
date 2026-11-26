#!/bin/bash
# release-gate-claim.sh — give back a claim the fix-loop gate took this tick when
# the session will not work the issue (#248).
#
# fix-loop-gate.sh claims an issue (the `working` label plus a `🔒 claim` comment)
# BEFORE the session that ran it decides what to do with the work plan. When that
# session then declines the issue — most often because it must compact its context
# before starting a new one — nothing works the issue, yet its claim keeps every
# other worker off it. The gate's own EXIT trap (#204) cannot help: the gate has
# already exited 0 and handed the plan over.
#
# Usage:
#   release-gate-claim.sh <issue> "<reason>"
#
# Releases only a claim this worktree's gate recorded (the worker-state record,
# worker-state-fns.sh) and only before /fix has started on it HERE: if a
# feature/issue-<N> branch exists in this checkout, the work has begun and /fix's
# explicit-release path (comment + label removal) is the right tool, not this. A
# branch that exists only on origin is another worker's (a banked READY, a
# worker mid-flight whose claim the gate took over): the gate's label is still
# the only thing this worktree put on the issue, and giving it back is right
# (athena2#7185; the still-ours check below keeps a rival's claim untouched).
#
# Exit codes:
#   0  released, or the claim had already ended or passed to another worker
#      (record cleared, issue untouched)
#   1  refused: bad arguments, the record names another issue, work has started,
#      the issue cannot be read back, or the label could not be removed
set -uo pipefail

N="${1:-}"
REASON="${2:-}"
if ! [[ "$N" =~ ^[0-9]+$ ]] || [ -z "$REASON" ]; then
  echo "usage: release-gate-claim.sh <issue> \"<reason>\"" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=issue-fns.sh
source "${SCRIPT_DIR}/issue-fns.sh"
# shellcheck source=worker-state-fns.sh
source "${SCRIPT_DIR}/worker-state-fns.sh"

STATE_FILE="$(worker_state_file 2>/dev/null || true)"
HELD=""; HELD_MS=""
[ -n "$STATE_FILE" ] && [ -f "$STATE_FILE" ] && read -r HELD HELD_MS _ < "$STATE_FILE"
[ "$HELD_MS" = "-" ] && HELD_MS=""
if [ "$HELD" != "$N" ]; then
  echo "release-gate-claim: this worktree's gate holds no claim on #${N} (record: ${HELD:-none}); not touching it" >&2
  exit 1
fi

# Only a LOCAL branch means this worktree started the work (claim-issue.sh cuts
# it here); a branch on origin alone is another worker's, and the still-ours
# check below keeps that worker's own claim untouched.
if git show-ref --verify --quiet "refs/heads/feature/issue-${N}"; then
  echo "release-gate-claim: feature/issue-${N} exists in this checkout, so work on #${N} has started here; use /fix's explicit release instead" >&2
  exit 1
fi

# An issue that cannot be read back is left alone, as the gate's own #204
# release does: removing the label blind could strip a lock that is not ours.
if ! JSON="$(issue_get "$N" 2>/dev/null)" || ! printf '%s' "$JSON" | jq -e 'type == "object"' >/dev/null 2>&1; then
  echo "release-gate-claim: cannot read #${N} back; leaving its claim and the record alone" >&2
  exit 1
fi

# Still ours: open, `working`, and no `🔒 claim` posted after our claim's race
# window (a takeover or a re-claim after a release), the rule a resume uses too.
# Otherwise the claim has already ended or passed to someone else: forget it.
if ! _worker_still_ours "$JSON" "$HELD_MS"; then
  echo "release-gate-claim: #${N} is no longer this worktree's claim (ended or re-claimed); clearing the record only" >&2
  worker_state_clear
  exit 0
fi

# The reason is free text from the agent: keep it short and unable to @-mention.
REASON="${REASON:0:200}"
REASON="${REASON//@/@​}"

# Label first, then the 🔓: a racer that reads the 🔓 and wins re-adds the label,
# and that must come after our removal (same order as the gate's #204 release).
# If the label cannot be removed, post nothing: a 🔓 on a still-locked issue
# would end every claim on it in the parsers while the lock stays.
if ! issue_release "$N" 2>/dev/null && ! issue_update "$N" --remove-label working 2>/dev/null; then
  echo "release-gate-claim: could not remove 'working' from #${N}; record kept, retry later" >&2
  exit 1
fi
issue_comment "$N" --body "🔓 **Releasing claim**

**Reason**: ${REASON}
**Worktree**: \`$(git rev-parse --show-toplevel 2>/dev/null || pwd)\`
**State left behind**: nothing; the fix-loop gate claimed this issue, but no work was started.

Releasing the \`working\` lock so another agent can pick this up." 2>/dev/null || true
worker_state_clear
echo "release-gate-claim: released #${N}"
exit 0
