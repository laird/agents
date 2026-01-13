# Install Autocoder Stop Hook

Configures the stop hook in your project's `.claude/settings.json` to enable the infinite `/fix-github-loop`.

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
  if grep -q "fix-github-loop" .claude/settings.json 2>/dev/null; then
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
    "fix-github" in str(h.get("hooks", []))
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
echo "   /fix-github-loop"
echo ""
echo "This will start the infinite loop that:"
echo "  1. Triages unprioritized issues"
echo "  2. Fixes bugs (P0 → P1 → P2 → P3)"
echo "  3. Runs regression tests"
echo "  4. Implements approved enhancements"
echo "  5. Generates proposals"
echo "  6. Sleeps when idle, then repeats"
```
