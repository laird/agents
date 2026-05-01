---
description: Approve proposals for implementation
---

# Approve Proposals

Approve one or more AI-generated proposals for implementation by removing the `proposal` label.

## Optional skill enhancements

<!-- BEGIN optional-skills-prelude v1 — keep in sync across all command files; see plugins/shared/optional-skills-prelude.md -->

If a named skill appears in your available skills list (delivered in the session-start system-reminder), invoke it via the `Skill` tool at the indicated step. Otherwise, follow the inline protocol below — it remains the source of truth and is unchanged by this section.

In Gemini CLI / Antigravity, skills activate via `activate_skill` instead of the `Skill` tool; the mapping is otherwise identical.

**Skill-name matching.** Match each table entry as an exact string. Mapping tables use fully-qualified names (`<plugin>:<skill>`) for plugin-installed skills and bare names for personal toolkit skills.

**Notation.** `A → B → C` means sequence (invoke in order). `A + B + C` means independent facets (all apply, order irrelevant). `A (primary)` means A is the orchestration spine. A leading `→` on a row indicates "next in sequence if applicable."

**Failure semantics.** Not-installed: silent fallback. Mid-run failure or interruption of an installed skill: surface the failure message, fall back to the inline protocol for the rest of that step, no retry. Self-skip (e.g., `<SUBAGENT-STOP>`): silent fallback, not treated as failure. If at least one `superpowers:*` skill named in this command's mapping table is missing from your available-skills list, emit one consolidated recommendation line at command entry: *Tip: this command works best with the `superpowers` plugin (https://github.com/obra/superpowers) — install via `/plugin install superpowers@claude-plugins-official`.* Never emit such notices for personal toolkit skills.

**Skills are advisory, not gating.** A command's completion criteria are defined by its inline protocol. Optional skill outcomes are surfaced and considered, but do not override inline success criteria. "Always applied" in a mapping table means the skill is invoked when installed; outcomes remain advisory. When a command claims success while an advisory skill earlier in the run surfaced a failure, the success summary acknowledges the advisory finding.

**Version trust.** Skills are matched by name; the integration does not pin or verify versions. If a tracked skill's contract changes in a way that breaks the chain, the integration is stale and must be updated.

<!-- END optional-skills-prelude v1 -->

<!-- BEGIN optional-skills-mapping approve-proposal v1 — keep in sync between Claude/Antigravity mirrors of this command -->

| Step | Skill mapping |
|---|---|
| Critical design review of the proposal | `critical-design-review` (always for non-trivial proposals) |
| Architectural soundness check | `→ arch-review` (only if the proposal introduces or changes architectural patterns, module boundaries, or technology choices) |
| Security implications | `→ security-review` (only if the proposal touches authentication, authorization, data handling, external interfaces, secret storage, or dependencies) |

<!-- END optional-skills-mapping approve-proposal v1 -->

## Usage

```bash
# Approve a single proposal
/approve-proposal 42

# Approve multiple proposals
/approve-proposal 42 45 47

# Approve all pending proposals
/approve-proposal --all
```

## What This Does

Removes the `proposal` label from specified GitHub issues, allowing `/fix-loop` to implement them automatically.

## Instructions

```bash
# Parse arguments
ISSUE_NUMBERS=()
APPROVE_ALL=false

for arg in "$@"; do
  case "$arg" in
    --all|-a)
      APPROVE_ALL=true
      ;;
    [0-9]*)
      ISSUE_NUMBERS+=("$arg")
      ;;
    *)
      echo "⚠️  Ignoring invalid argument: $arg"
      ;;
  esac
done

# Handle --all flag
if [ "$APPROVE_ALL" = true ]; then
  echo "📋 Fetching all pending proposals..."
  ISSUE_NUMBERS=($(gh issue list --state open --label "proposal" --json number --jq '.[].number'))

  if [ ${#ISSUE_NUMBERS[@]} -eq 0 ]; then
    echo "✅ No pending proposals to approve."
    exit 0
  fi

  echo "   Found ${#ISSUE_NUMBERS[@]} proposal(s)"
  echo ""
fi

# Validate we have issues to approve
if [ ${#ISSUE_NUMBERS[@]} -eq 0 ]; then
  echo "❌ No proposal numbers specified."
  echo ""
  echo "Usage:"
  echo "  /approve-proposal 42        # Approve issue #42"
  echo "  /approve-proposal 42 45 47  # Approve multiple issues"
  echo "  /approve-proposal --all     # Approve all pending proposals"
  echo ""
  echo "Run /list-proposals to see pending proposals."
  exit 1
fi

echo "═══════════════════════════════════════════════════════════════"
echo "                    APPROVING PROPOSALS"
echo "═══════════════════════════════════════════════════════════════"
echo ""

APPROVED=0
FAILED=0

for num in "${ISSUE_NUMBERS[@]}"; do
  # Verify the issue exists and has the proposal label
  ISSUE_INFO=$(gh issue view "$num" --json number,title,labels,state 2>/dev/null)

  if [ -z "$ISSUE_INFO" ]; then
    echo "❌ #$num - Issue not found"
    ((FAILED++))
    continue
  fi

  STATE=$(echo "$ISSUE_INFO" | python3 -c "import json,sys; print(json.load(sys.stdin).get('state',''))")
  if [ "$STATE" != "OPEN" ]; then
    echo "⚠️  #$num - Issue is not open (state: $STATE)"
    ((FAILED++))
    continue
  fi

  HAS_PROPOSAL=$(echo "$ISSUE_INFO" | python3 -c "import json,sys; labels=[l['name'] for l in json.load(sys.stdin).get('labels',[])]; print('yes' if 'proposal' in labels else 'no')")

  if [ "$HAS_PROPOSAL" != "yes" ]; then
    echo "⚠️  #$num - Does not have 'proposal' label (already approved?)"
    ((FAILED++))
    continue
  fi

  TITLE=$(echo "$ISSUE_INFO" | python3 -c "import json,sys; print(json.load(sys.stdin).get('title',''))")

  # Remove the proposal label
  if gh issue edit "$num" --remove-label "proposal" >/dev/null 2>&1; then
    echo "✅ #$num - $TITLE"
    ((APPROVED++))
  else
    echo "❌ #$num - Failed to remove label"
    ((FAILED++))
  fi
done

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo ""

if [ $APPROVED -gt 0 ]; then
  echo "✅ Approved: $APPROVED proposal(s)"
fi

if [ $FAILED -gt 0 ]; then
  echo "⚠️  Failed:   $FAILED proposal(s)"
fi

echo ""

if [ $APPROVED -gt 0 ]; then
  echo "🚀 Next steps:"
  echo "   • Run /fix-loop to implement approved proposals"
  echo "   • Or run /fix for a single iteration"
fi
```

## Workflow Integration

```
┌─────────────────────┐
│  /list-proposals    │  ← Review pending proposals
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│  /approve-proposal  │  ← You are here
│  42 45 47           │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│  /fix-loop   │  ← Implements approved issues
└─────────────────────┘
```

## See Also

- `/list-proposals` - View all pending proposals
- `/fix` - Single iteration of issue resolution
- `/fix-loop` - Continuous issue resolution loop
