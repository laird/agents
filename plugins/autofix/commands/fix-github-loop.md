# Start Infinite Fix-GitHub Loop

Initialize and start an infinite `/fix-github` loop that runs forever using Claude Code's stop hook mechanism.

## Usage

```bash
# Start infinite loop (runs forever)
/fix-github-loop

# Start with max iterations limit
/fix-github-loop 100

# Custom idle sleep time (default: 60 minutes)
/fix-github-loop --sleep 120

# Combine options
/fix-github-loop 100 --sleep 30
```

## How It Works

This command uses Claude Code's stop hook mechanism to prevent the session from exiting. When Claude finishes processing, the stop hook intercepts the exit and feeds `/fix-github` back as input, creating an infinite loop.

### Stop Hook Mechanism

1. Creates state file: `.claude/fix-github-loop.local.md`
2. Stop hook checks for this file when Claude tries to exit
3. If file exists, hook returns `{"decision": "block", "reason": "/fix-github"}`
4. Claude receives `/fix-github` as new input and continues

### Stopping the Loop

The loop can be stopped in several ways:

1. **Manual interrupt**: Press `Ctrl+C`
2. **Explicit stop**: Output `STOP_FIX_GITHUB_LOOP` in response
3. **Max iterations**: If limit set, stops when reached
4. **Critical errors**: Automatically pauses on auth failures, rate limits, etc.
5. **Delete state file**: `rm .claude/fix-github-loop.local.md`

## Instructions

```bash
# Parse arguments
MAX_ITERATIONS="${1:-0}"  # 0 = unlimited
IDLE_SLEEP_MINUTES="60"   # Default: sleep 60 minutes when idle

args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  case ${args[i]} in
    --sleep)
      IDLE_SLEEP_MINUTES="${args[i+1]}"
      ((i++))
      ;;
    [0-9]*)
      MAX_ITERATIONS="${args[i]}"
      ;;
  esac
done

# Ensure .claude directory exists
mkdir -p .claude

# ============================================================
# STEP 0: Auto-install stop hook if not configured
# ============================================================
echo "🔧 Checking stop hook configuration..."

HOOK_INSTALLED=false

if [ -f ".claude/settings.json" ]; then
  if grep -q "stop-hook.sh" .claude/settings.json 2>/dev/null; then
    HOOK_INSTALLED=true
    echo "✅ Stop hook already configured"
  fi
fi

if [ "$HOOK_INSTALLED" = "false" ]; then
  echo "📝 Installing stop hook..."

  if [ -f ".claude/settings.json" ]; then
    # Merge with existing settings
    python3 << 'PYTHON_SCRIPT'
import json

settings_path = ".claude/settings.json"

with open(settings_path, 'r') as f:
    settings = json.load(f)

stop_hook = {
    "matcher": "",
    "hooks": [
        {
            "type": "command",
            "command": "bash ~/.claude/plugins/autofix/hooks/stop-hook.sh"
        }
    ]
}

if "hooks" not in settings:
    settings["hooks"] = {}
if "Stop" not in settings["hooks"]:
    settings["hooks"]["Stop"] = []

already_present = any(
    "stop-hook.sh" in str(h.get("hooks", []))
    for h in settings["hooks"]["Stop"]
)

if not already_present:
    settings["hooks"]["Stop"].append(stop_hook)
    with open(settings_path, 'w') as f:
        json.dump(settings, f, indent=2)
    print("  Added to existing settings.json")
PYTHON_SCRIPT
  else
    # Create new settings file
    cat > .claude/settings.json << 'SETTINGS_JSON'
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/plugins/autofix/hooks/stop-hook.sh"
          }
        ]
      }
    ]
  }
}
SETTINGS_JSON
    echo "  Created .claude/settings.json"
  fi

  echo "✅ Stop hook installed"
fi

echo ""

# ============================================================
# STEP 1: Ensure all required labels exist
# ============================================================
echo "🏷️  Ensuring required GitHub labels exist..."

EXISTING_LABELS=$(gh label list --json name --jq '.[].name' 2>/dev/null || echo "")

# Define all required labels: name:description:color
REQUIRED_LABELS=(
  "P0:Critical priority - system down, security, data loss:d73a4a"
  "P1:High priority - major feature broken, no workaround:ff6b6b"
  "P2:Medium priority - feature degraded, workaround exists:ff9800"
  "P3:Low priority - minor issue, cosmetic, nice-to-have:4caf50"
  "bug:Something isn't working:d73a4a"
  "enhancement:New feature or request:a2eeef"
  "proposal:AI-generated proposal awaiting human approval:c5def5"
  "test-failure:Regression test failure:f9d0c4"
  "needs-review:Requires human review before proceeding:fbca04"
  "in-progress:Currently being worked on by automation:0e8a16"
)

for label_def in "${REQUIRED_LABELS[@]}"; do
  IFS=':' read -r name desc color <<< "$label_def"
  if ! echo "$EXISTING_LABELS" | grep -qFx "$name"; then
    echo "  Creating label: $name"
    gh label create "$name" --description "$desc" --color "$color" 2>/dev/null || true
  fi
done

echo "✅ Labels verified"
echo ""

# ============================================================
# STEP 2: Triage any unprioritized issues
# ============================================================
echo "🔍 Checking for unprioritized issues..."

gh issue list --state open --json number,title,body,labels --limit 100 > /tmp/all-open-issues.json

# Find issues without any priority label (P0-P3)
UNPRIORITIZED=$(cat /tmp/all-open-issues.json | python3 -c "
import json, sys
issues = json.load(sys.stdin)
unprioritized = [i for i in issues if not any(l['name'] in ['P0','P1','P2','P3'] for l in i.get('labels',[]))]
for issue in unprioritized:
    labels = ','.join([l['name'] for l in issue.get('labels',[])])
    print(f\"{issue['number']}|{issue['title']}|{labels}|{issue.get('body', '')[:200]}\")
" 2>/dev/null || echo "")

if [ -n "$UNPRIORITIZED" ]; then
  UNPRIORITIZED_COUNT=$(echo "$UNPRIORITIZED" | grep -c "^" || echo "0")
  echo "⚠️  Found $UNPRIORITIZED_COUNT unprioritized issue(s)"
  echo ""
  echo "TRIAGE_REQUIRED=true"
  echo "UNPRIORITIZED_ISSUES:"
  echo "$UNPRIORITIZED" | while IFS='|' read -r num title labels body; do
    echo "  #$num: $title"
    [ -n "$labels" ] && echo "       Labels: $labels"
  done
  echo ""
  echo "These issues will be triaged as part of the first /fix-github iteration."
else
  echo "✅ All open issues have priority labels"
fi

echo ""

# ============================================================
# STEP 3: Create the loop state file
# ============================================================

# Create the loop state file
cat > .claude/fix-github-loop.local.md << EOF
---
iteration: 0
max_iterations: $MAX_ITERATIONS
idle_sleep_minutes: $IDLE_SLEEP_MINUTES
started: $(date -Iseconds)
---

/fix-github
EOF

echo "🔄 Fix-GitHub Loop Initialized"
echo ""
echo "Configuration:"
echo "  Max iterations: $([ "$MAX_ITERATIONS" = "0" ] && echo "unlimited" || echo "$MAX_ITERATIONS")"
echo "  Idle sleep: $IDLE_SLEEP_MINUTES minutes"
echo "  State file: .claude/fix-github-loop.local.md"
echo ""
echo "Workflow priority:"
echo "  1. Triage unprioritized issues"
echo "  2. Fix bugs (P0 → P1 → P2 → P3)"
echo "  3. Run regression tests"
echo "  4. Implement approved enhancements"
echo "  5. Generate proposals (until nothing useful)"
echo "  6. Sleep $IDLE_SLEEP_MINUTES min, then repeat"
echo ""
echo "Stop methods:"
echo "  • Press Ctrl+C"
echo "  • Output: STOP_FIX_GITHUB_LOOP"
echo "  • Delete: rm .claude/fix-github-loop.local.md"
echo ""
echo "Starting first iteration..."
echo ""
```

Now execute `/fix-github` to start the loop. The stop hook will automatically continue the loop when this iteration completes.
