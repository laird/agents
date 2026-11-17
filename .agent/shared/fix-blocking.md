# /fix reference: blocking detection

Moved out of the `/fix` command file (#240) because a worker rarely needs it.
The command keeps a pointer at each place this text used to be.

### Detection Process

**Step 1: Read the issue carefully**

Look for these red flags:
- **Vague or incomplete**: No specific steps, missing context, unclear acceptance criteria → `needs-clarification`
- **Multiple solutions**: Several valid approaches, trade-offs unclear, design needed → `needs-design`
- **Major decision**: Architectural change, breaking change, security impact → `needs-approval`
- **Too large**: >100 test failures, affects multiple systems, irreversible → `too-complex`

**Step 2: If blocked, add label and skip**

```bash
BLOCKING_LABEL=""  # Will be set to one of: needs-clarification, needs-design, needs-approval, too-complex
BLOCKING_REASON=""  # Human-readable explanation

# Example: Issue has unclear requirements
if [issue description is vague or missing critical information]; then
  BLOCKING_LABEL="needs-clarification"
  BLOCKING_REASON="Issue description is unclear. Need specific details about: [what's missing]"
fi

# Example: Issue requires design decisions
#
# IMPORTANT: when applying `needs-design`, BLOCKING_REASON MUST explain
# *what specifically* needs designing. Do not leave placeholder text — the
# script rejects reasons containing unfilled brackets like `[list options]`.
#
# Write a multi-line reason covering, at minimum:
#   - The specific design questions that are open (1–N concrete questions)
#   - The candidate approaches you considered and why none is the clear winner
#   - What artifact would unblock the work (ADR? spec doc? a decision from a named owner?)
#
# Example of a good reason:
#   "Issue asks for 'real-time notifications' but doesn't specify transport.
#    Open questions:
#    1. SSE (we use it elsewhere) vs WebSocket vs polling?
#    2. Who is the audience — specific user groups only, or all users?
#    3. Persistence semantics — at-least-once? best-effort?
#    Approaches considered:
#    - SSE: matches existing infra but only server-push.
#    - WebSocket: bidirectional but new infra surface.
#    Needs an ADR or a decision from the platform owner before implementation."
if [multiple approaches possible, no clear winner]; then
  BLOCKING_LABEL="needs-design"
  BLOCKING_REASON="$(cat <<'NEEDS_DESIGN_REASON'
<one-paragraph summary of what is undecided>

Open questions:
1. <specific question>
2. <specific question>

Approaches considered:
- <approach>: <pros/cons>
- <approach>: <pros/cons>

Unblocks when: <ADR/spec/decision-owner that needs to land>
NEEDS_DESIGN_REASON
)"
fi

# Example: Issue requires architectural approval
if [breaking change or major architectural decision]; then
  BLOCKING_LABEL="needs-approval"
  BLOCKING_REASON="This requires architectural decision: [describe the decision]"
fi

# Example: Issue is too complex for autonomous resolution
if [>100 test failures or cross-cutting concerns]; then
  BLOCKING_LABEL="too-complex"
  BLOCKING_REASON="Too large for autonomous resolution: [describe complexity]"
fi

# If a blocking label was identified, use the script to add it and skip
if [ -n "$BLOCKING_LABEL" ]; then
  # Determine script location (portable across different plugin install locations)
  SCRIPT_DIR="$HOME/.agent/plugins/autocoder/scripts"

  bash "$SCRIPT_DIR/add-blocking-label.sh" "$ISSUE_NUM" "$BLOCKING_LABEL" "$BLOCKING_REASON"
  # Log to history
  "${SCRIPT_DIR}/append-to-history.sh" --history-file "HISTORY.md" --backend auto \
    "Blocked #${ISSUE_NUM}: ${ISSUE_TITLE}" \
    "Added label: ${BLOCKING_LABEL}." \
    "${BLOCKING_REASON:0:200}" \
    "Requires human review before proceeding."

  echo "⏭️  Skipping to next issue..."
  echo ""
  # Continue to next issue in the workflow
fi
```

**Step 3: If not blocked, proceed with fix**

If no blocking conditions detected, continue with the normal fix workflow (simple vs complex vs ultra-complex determination).

### Skip Criteria (Legacy)

Skip to next issue if:
- Issue requires external dependencies (API keys, services) → add `needs-clarification` label
- Issue is blocked by another issue → add comment, don't add blocking label
- Issue requires user input/decision → add appropriate blocking label (`needs-approval`, `needs-design`, or `needs-clarification`)
