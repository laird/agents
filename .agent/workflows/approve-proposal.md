# Approve Proposals

Approve one or more AI-generated proposals for implementation by removing the `proposal` label.

## Optional skill enhancements

<!-- BEGIN optional-skills-prelude v1 -->
Invoke listed skills via the `Skill` tool (Gemini/Antigravity: `activate_skill`). Match names exactly (`plugin:skill` or bare). `A → B` = sequence, `A + B` = parallel. Missing `superpowers:*` skill: emit one tip at entry. Not-installed: silent fallback. Mid-run failure: surface and fall back to inline. Skills are advisory — inline protocol defines completion.
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
SCRIPT_DIR=$(
  if [ -d "$(pwd)/.agent/scripts" ]; then echo "$(pwd)/.agent/scripts"
  elif [ -d "$(pwd)/plugins/autocoder/scripts" ]; then echo "$(pwd)/plugins/autocoder/scripts"
  elif [ -d "$(pwd)/.claude-plugin/plugins/autocoder/scripts" ]; then echo "$(pwd)/.claude-plugin/plugins/autocoder/scripts"
  else find "$HOME/.agent/plugins/cache" -type d -name "scripts" -path "*/autocoder/*" 2>/dev/null | sort -V | tail -1
  fi
)
source "${SCRIPT_DIR}/issue-fns.sh"

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
  ISSUE_NUMBERS=($(issue_list --state blocked --label "proposal" | jq -r '.[].number'))

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
  ISSUE_INFO=$(issue_get "$num" 2>/dev/null)

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
  if issue_update "$num" --remove-label "proposal" >/dev/null 2>&1; then
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
