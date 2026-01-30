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
```

## How It Works

1. Installs stop hook in `.claude/settings.json` (if not present)
2. Creates state file `.claude/fix-loop.local.md`
3. Runs `/fix`
4. When Claude tries to exit, stop hook feeds `/fix` back as input
5. Loop continues until manually stopped or max iterations reached

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
started: $(date -Iseconds)
---

/fix
EOF

echo ""
echo "🔄 Loop initialized"
echo "   Max iterations: $([ "$MAX_ITERATIONS" = "0" ] && echo "unlimited" || echo "$MAX_ITERATIONS")"
echo "   Idle sleep: $IDLE_SLEEP_MINUTES minutes"
echo ""
```

Now run `/fix` to start. The stop hook will keep it running.
