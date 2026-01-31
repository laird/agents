# Start Infinite Fix-GitHub Loop

Wrapper around `/fix` that installs a stop hook to keep it running forever.

## Usage

```bash
# Start infinite loop
/fix-loop

# Limit to 100 iterations
/fix-loop 100

# Custom idle sleep time (default: 15 minutes)
/fix-loop --sleep 30

# Multi-agent coordination with deployment
/fix-loop --branch main --deploy "deploy.sh staging ."

# Or set via environment
export CLAUDE_CODE_INTEGRATION_BRANCH="main"
export CLAUDE_CODE_DEPLOY_COMMAND="deploy.sh staging ."
/fix-loop
```

## How It Works

1. Installs stop hook in `.claude/settings.json` (if not present)
2. Creates state file `.claude/fix-loop.local.md`
3. Runs `/fix`
4. When Claude tries to exit, stop hook feeds `/fix` back as input
5. Loop continues until manually stopped or max iterations reached

## Multi-Agent Coordination (Automatic)

When `CLAUDE_CODE_TASK_LIST_ID` is set, `/fix-loop` automatically coordinates with other agents:

**Setup:**
```bash
# 1. Configure deployment in your CLAUDE.md:
cat >> CLAUDE.md << 'EOF'

## Deployment

Integration branch: main
Deploy to staging: deploy.sh staging .
EOF

# 2. Set shared task list ID in all worktrees
export CLAUDE_CODE_TASK_LIST_ID="project-$(date +%Y%m%d)"

# 3. Run /fix-loop in each worktree (same command everywhere)
# Main worktree
cd /path/to/project
/fix-loop  # → Auto-detects: "I'm coordinator, will deploy when ready"

# Feature worktree 1
cd /path/to/project-wt-auth
/fix-loop  # → Auto-detects: "I'm worker, will complete tasks"

# Feature worktree 2
cd /path/to/project-wt-api
/fix-loop  # → Auto-detects: "I'm worker, will complete tasks"
```

**Configuration Options:**

The integration branch and deploy command can be specified:

1. **In CLAUDE.md** (recommended):
   ```markdown
   ## Deployment
   Integration branch: main
   Deploy to staging: deploy.sh staging .
   ```

2. **Via environment**:
   ```bash
   export CLAUDE_CODE_INTEGRATION_BRANCH="main"
   export CLAUDE_CODE_DEPLOY_COMMAND="deploy.sh staging ."
   ```

3. **Via command line**:
   ```bash
   /fix-loop --branch main --deploy "deploy.sh staging ."
   ```

4. **Auto-detection**: Defaults to `main` branch and looks for:
   - `scripts/deploy-staging.sh`
   - `deploy.sh staging`
   - Deployment commands in CLAUDE.md

**Automatic Deployment Trigger:**

When ALL these conditions are met:
- ✅ All agents idle (no pending/in_progress tasks)
- ✅ Integration branch ready (clean working tree, all pushed)
- ✅ I'm in main worktree (not a feature worktree)
- ✅ New changes to deploy (current commit not already deployed)
- ✅ Deploy command configured

Then: Main worktree automatically:
1. Switches to integration branch
2. Commits any uncommitted changes
3. Pushes integration branch (if needed)
4. Pulls latest integration branch
5. Merges all feature branches from worktrees
6. Pushes merged integration branch
7. Executes deployment command

**Benefits:**
- Zero manual coordination needed
- Same `/fix-loop` command everywhere
- Automatic role detection (coordinator vs worker)
- Safe deployment (only when all work complete and pushed)
- Project-specific deployment via CLAUDE.md

## Stopping the Loop

- **Ctrl+C** - Manual interrupt
- **Output `STOP_FIX_GITHUB_LOOP`** - Explicit stop signal
- **Max iterations** - If set, stops when reached
- **Delete state file** - `rm .claude/fix-loop.local.md`

## Instructions

```bash
# Parse arguments
MAX_ITERATIONS="${1:-0}"  # 0 = unlimited
IDLE_SLEEP_MINUTES="15"
INTEGRATION_BRANCH="${CLAUDE_CODE_INTEGRATION_BRANCH:-}"
DEPLOY_COMMAND="${CLAUDE_CODE_DEPLOY_COMMAND:-}"

args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  case ${args[i]} in
    --sleep)
      IDLE_SLEEP_MINUTES="${args[i+1]}"
      ((i++))
      ;;
    --branch)
      INTEGRATION_BRANCH="${args[i+1]}"
      ((i++))
      ;;
    --deploy)
      DEPLOY_COMMAND="${args[i+1]}"
      ((i++))
      ;;
    [0-9]*)
      MAX_ITERATIONS="${args[i]}"
      ;;
  esac
done

# If not set, try to extract from CLAUDE.md
if [[ -z "$INTEGRATION_BRANCH" ]]; then
  for claude_file in CLAUDE.md claude.md README.md; do
    if [[ -f "$claude_file" ]]; then
      # Look for integration branch patterns
      INTEGRATION_BRANCH=$(grep -i "integration.*branch\|main.*branch\|merge.*into" "$claude_file" | \
        grep -Eo '\b(main|master|develop|integration)\b' | head -1)
      [[ -n "$INTEGRATION_BRANCH" ]] && break
    fi
  done
fi

# Default to main if still not found
INTEGRATION_BRANCH="${INTEGRATION_BRANCH:-main}"

# If not set, try to extract deploy command from CLAUDE.md
if [[ -z "$DEPLOY_COMMAND" ]]; then
  for claude_file in CLAUDE.md claude.md README.md; do
    if [[ -f "$claude_file" ]]; then
      # Look for deployment command patterns
      DEPLOY_COMMAND=$(grep -i "deploy.*staging\|staging.*deploy" "$claude_file" | \
        grep -Eo '(\.?/)?[a-zA-Z0-9_/-]+\.sh\s+[a-zA-Z0-9_. /-]*' | head -1)
      [[ -n "$DEPLOY_COMMAND" ]] && break
    fi
  done
fi

# Export for stop hook to use
export CLAUDE_CODE_INTEGRATION_BRANCH="$INTEGRATION_BRANCH"
export CLAUDE_CODE_DEPLOY_COMMAND="$DEPLOY_COMMAND"

mkdir -p .claude

# ============================================================
# Install stop hook if not configured
# ============================================================
if [ -f ".claude/settings.json" ] && grep -q "stop-hook.sh" .claude/settings.json 2>/dev/null; then
  echo "✅ Stop hook already configured"
else
  echo "📝 Installing stop hook..."

  if [ -f ".claude/settings.json" ]; then
    python3 << 'PYTHON_SCRIPT'
import json
with open(".claude/settings.json", 'r') as f:
    settings = json.load(f)
stop_hook = {"matcher": "", "hooks": [{"type": "command", "command": "bash ~/.claude/plugins/autocoder/hooks/stop-hook.sh"}]}
if "hooks" not in settings:
    settings["hooks"] = {}
if "Stop" not in settings["hooks"]:
    settings["hooks"]["Stop"] = []
if not any("stop-hook.sh" in str(h) for h in settings["hooks"]["Stop"]):
    settings["hooks"]["Stop"].append(stop_hook)
    with open(".claude/settings.json", 'w') as f:
        json.dump(settings, f, indent=2)
PYTHON_SCRIPT
  else
    cat > .claude/settings.json << 'EOF'
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/plugins/autocoder/hooks/stop-hook.sh"
          }
        ]
      }
    ]
  }
}
EOF
  fi
  echo "✅ Stop hook installed"
fi

# ============================================================
# Create loop state file
# ============================================================
cat > .claude/fix-loop.local.md << EOF
---
iteration: 0
max_iterations: $MAX_ITERATIONS
idle_sleep_minutes: $IDLE_SLEEP_MINUTES
integration_branch: $INTEGRATION_BRANCH
deploy_command: $DEPLOY_COMMAND
started: $(date -Iseconds)
---

/fix
EOF

echo ""
echo "🔄 Loop initialized"
echo "   Max iterations: $([ "$MAX_ITERATIONS" = "0" ] && echo "unlimited" || echo "$MAX_ITERATIONS")"
echo "   Idle sleep: $IDLE_SLEEP_MINUTES minutes"
if [[ -n "$CLAUDE_CODE_TASK_LIST_ID" ]]; then
  echo "   Coordination: Enabled (task list: ${CLAUDE_CODE_TASK_LIST_ID:0:20}...)"
  echo "   Integration branch: $INTEGRATION_BRANCH"
  if [[ -n "$DEPLOY_COMMAND" ]]; then
    echo "   Deploy command: $DEPLOY_COMMAND"
  else
    echo "   Deploy command: Not configured (won't deploy)"
  fi
fi
echo ""
```

Now execute the `/fix` command to start the autonomous fix loop. The stop hook will automatically re-invoke `/fix` when it tries to exit, creating an infinite loop.

**Execute `/fix` now using the Skill tool:**

```
Use the Skill tool to invoke: autocoder:fix
```
