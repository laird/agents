# /fix reference: unprioritized-issue triage

Moved out of the `/fix` command file (#240) because a worker rarely needs it.
The command keeps a pointer at each place this text used to be.

## Unprioritized Issue Triage

When unprioritized issues are detected, review each one and assign an appropriate priority label before continuing with the fix workflow.

### Triage Process

For each unprioritized issue:

1. **Read the issue** - Understand the title, description, and any labels
2. **Assess severity and impact**:
   - **P0 (Critical)**: System down, data loss, security vulnerability, blocks all users
   - **P1 (High)**: Major feature broken, significant user impact, no workaround
   - **P2 (Medium)**: Feature partially broken, workaround exists, moderate impact
   - **P3 (Low)**: Minor issue, cosmetic, nice-to-have, minimal user impact
3. **Assign the priority label**:

```bash
# Assign priority to an issue (backend-neutral).
#
# Apply labels ONE AT A TIME and check each result. `gh issue edit` is
# all-or-nothing: if any single label is unknown to the repo it rejects the
# WHOLE edit, so a combined
#     issue_update "$N" --add-label "P3" --add-label "needs-clarification"
# applies NEITHER when the blocking label is missing. The issue then keeps zero
# labels — neither prioritized nor blocked — so it re-enters the claimable pool
# and every worker re-triages it, fails identically, and moves on. The failure
# goes to stderr while the workflow continues, so it is silent and repeating.
apply_label() {  # apply_label <issue> <label>
  if issue_update "$1" --add-label "$2"; then
    return 0
  fi
  echo "⚠️  Could not apply '$2' to issue #$1 — does the label exist in this repo?" >&2
  return 1
}

apply_label <ISSUE_NUMBER> "P2"                    # priority: apply first, on its own
apply_label <ISSUE_NUMBER> "needs-clarification"   # then each blocking label separately
```

Applying the priority first and separately matters: if a later label fails, the
issue is still correctly prioritized rather than left bare.

4. **Add a triage comment** explaining the priority decision:

```bash
issue_comment <ISSUE_NUMBER> --body "🏷️ **Triage Complete**

**Priority Assigned**: P2 (Medium)

**Rationale**: [Brief explanation of why this priority was chosen]

🤖 Triaged by autonomous fix workflow"
```

### Triage Decision Matrix

| Indicator | P0 | P1 | P2 | P3 |
|-----------|----|----|----|----|
| Production impact | Critical/Down | Major degradation | Partial impact | Minimal |
| User scope | All users | Many users | Some users | Few users |
| Workaround | None | Difficult | Available | Easy |
| Data risk | Loss/corruption | Possible | Unlikely | None |
| Security | Active exploit | Vulnerability | Potential | None |
| Keywords | "crash", "down", "urgent", "security" | "broken", "fails", "blocking" | "issue", "bug", "incorrect" | "minor", "cosmetic", "enhancement" |

### Triage Instructions

When `UNPRIORITIZED_ISSUES_FOUND=true` is detected:

1. Parse the `UNPRIORITIZED_DATA` to get issue numbers, titles, and descriptions
2. For each issue, use the decision matrix to determine priority
3. Assign the label and post a triage comment
4. Continue to the main fix workflow after all issues are triaged

**Model Selection for Triage**: Use **Haiku** for straightforward triage decisions, escalate to **Sonnet** if the issue description is ambiguous or requires deeper analysis.
