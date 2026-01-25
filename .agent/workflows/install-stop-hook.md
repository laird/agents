---
description: Install autocoder stop hook for infinite loops
---

# Install Autocoder Stop Hook

Configures the stop hook in your project's `.claude/settings.json` to enable the infinite `/fix-loop`.

## Activity Detection

The stop hook intelligently detects when Claude is actively working and pauses the loop to avoid interruptions. It only triggers `/fix` when ALL of these conditions are met:

1. **No active tasks** - Task system has no pending/in_progress tasks
2. **No recent conversation** - Last message was ≥ 2 minutes ago
3. **No recent file changes** - No files modified in last 5 minutes

When any activity is detected, you'll see:
- `⏸️  Fix-github loop: Paused - active tasks detected`
- `⏸️  Fix-github loop: Paused - recent conversation activity`
- `⏸️  Fix-github loop: Paused - recent file changes detected`

The loop automatically resumes when Claude becomes idle.

## Usage

```bash
/install-stop-hook
```

This command automatically:

1. Creates `.claude/settings.json` if it doesn't exist
2. Adds the stop hook configuration for the autocoder plugin
3. Preserves any existing hooks or settings

## Instructions

```bash
# Ensure .claude directory exists
mkdir -p .claude

# Check if settings.json exists
if [ -f ".claude/settings.json" ]; then
  echo "📋 Found existing .claude/settings.json"

  # Check if stop hook already configured
  if grep -q "fix-loop" .claude/settings.json 2>/dev/null; then
    echo "✅ Stop hook already configured!"
    cat .claude/settings.json
    exit 0
  fi

  # Merge with existing settings using Python
  python3 << 'PYTHON_SCRIPT'
import json
import os

settings_path = ".claude/settings.json"

# Read existing settings
with open(settings_path, 'r') as f:
    settings = json.load(f)

# Define the stop hook
stop_hook = {
    "matcher": "",
    "hooks": [
        {
            "type": "command",
            "command": "bash ~/.claude/plugins/autocoder/hooks/stop-hook.sh"
        }
    ]
}

# Ensure hooks.Stop exists and add our hook
if "hooks" not in settings:
    settings["hooks"] = {}
if "Stop" not in settings["hooks"]:
    settings["hooks"]["Stop"] = []

# Check if already present
already_present = any(
    "fix" in str(h.get("hooks", []))
    for h in settings["hooks"]["Stop"]
)

if not already_present:
    settings["hooks"]["Stop"].append(stop_hook)

    # Write back
    with open(settings_path, 'w') as f:
        json.dump(settings, f, indent=2)
    print("✅ Stop hook added to existing settings")
else:
    print("✅ Stop hook already configured")

# Display result
with open(settings_path, 'r') as f:
    print(f.read())
PYTHON_SCRIPT

else
  echo "📝 Creating .claude/settings.json"

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
            "command": "bash ~/.claude/plugins/autocoder/hooks/stop-hook.sh"
          }
        ]
      }
    ]
  }
}
SETTINGS_JSON

  echo "✅ Stop hook configured!"
  cat .claude/settings.json
fi

echo ""
echo "🎉 Setup complete! You can now run:"
echo ""
echo "   /fix-loop"
echo ""
echo "This will start the infinite loop that:"
echo "  1. Triages unprioritized issues"
echo "  2. Fixes bugs (P0 → P1 → P2 → P3)"
echo "  3. Runs regression tests"
echo "  4. Implements approved enhancements"
echo "  5. Generates proposals"
echo "  6. Sleeps when idle, then repeats"
```
