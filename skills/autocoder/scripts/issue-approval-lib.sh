#!/bin/bash
# issue-approval-lib.sh — the approved-work gate.
#
# By default a swarm treats every open, unblocked issue as fair game. That is
# the right default for a repo whose whole backlog is meant to be worked, and
# the wrong one for a repo where the backlog is a mix of "yes, please" and
# "not yet, and definitely not by a robot". Without a gate the only way to keep
# an issue away from the swarm is to give it a blocking label, which overloads
# labels that mean something else ("needs-design" on an issue that needs no
# design) and reads as a defect to a human browsing the tracker.
#
# When a required label is configured, an issue is claimable only if it carries
# that label. Approval becomes an explicit, positive act: tag it `swarm` and the
# workers may take it; leave it untagged and they will not, no matter how the
# issue is reached.
#
# Configuration, in precedence order:
#   1. AUTOCODER_REQUIRED_LABEL in the environment (empty string disables the
#      gate even when the repo config sets one -- useful for a one-off manual
#      run without editing committed config).
#   2. "requiredLabel" in the main worktree's .autocoder.json.
#   3. Unset: no gate, every open issue is claimable. The pre-existing
#      behaviour, so turning this on is opt-in and nothing changes for repos
#      that never configure it.
#
# Source this file; do not execute it.

# Echo the configured required label, or nothing when the gate is off.
#
# The env var is checked with ${VAR+set} rather than a non-empty test, so an
# explicitly empty AUTOCODER_REQUIRED_LABEL means "no gate" instead of falling
# through to the repo config. Turning the gate OFF for one command has to be
# possible without editing a committed file.
required_issue_label() {
  if [ -n "${AUTOCODER_REQUIRED_LABEL+set}" ]; then
    printf '%s' "$AUTOCODER_REQUIRED_LABEL"
    return 0
  fi

  local root json
  root=$(git worktree list --porcelain 2>/dev/null | grep -m1 "^worktree" | cut -d' ' -f2)
  [ -n "$root" ] || root=$(git rev-parse --show-toplevel 2>/dev/null)
  [ -n "$root" ] || return 0
  json="${root}/.autocoder.json"
  [ -f "$json" ] || return 0

  python3 - "$json" <<'PY' 2>/dev/null
import json, sys
try:
    value = json.load(open(sys.argv[1])).get("requiredLabel", "")
    print(value if isinstance(value, str) else "", end="")
except Exception:
    print("", end="")
PY
}

# True when `labels` (whitespace- or newline-separated) satisfies the gate.
# With no gate configured, every issue passes.
issue_labels_approved() {
  local required label
  required=$(required_issue_label)
  [ -n "$required" ] || return 0
  for label in $1; do
    [ "$label" = "$required" ] && return 0
  done
  return 1
}

# Explain a refusal on stderr, in the same voice for every backend.
issue_approval_refusal() {
  local number="$1" required="$2"
  echo "Issue #${number} is not approved for autonomous work: it does not carry the '${required}' label." >&2
  echo "Add the label to approve it, or unset requiredLabel in .autocoder.json to disable the gate." >&2
}
