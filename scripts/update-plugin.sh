#!/bin/bash
# Update installed autocoder plugin from repo
# Works from any location - auto-detects repo path

set -e

# Auto-detect repo root (where this script lives)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_PATH="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_PATH="$HOME/.claude/plugins/autocoder"

# Verify we're in the right repo
if [ ! -f "$REPO_PATH/.claude-plugin/plugins/autocoder/plugin.json" ]; then
  echo "❌ Error: Could not find agents repository" >&2
  echo "   Expected: $REPO_PATH/.claude-plugin/plugins/autocoder/plugin.json" >&2
  exit 1
fi

echo "📦 Updating autocoder plugin from repository..."
echo ""
echo "   Repository: $REPO_PATH"
echo "   Plugin:     $PLUGIN_PATH"
echo ""

# Ensure plugin directory exists
mkdir -p "$PLUGIN_PATH"

# Copy all plugin files
echo "Copying files..."
cp -r "$REPO_PATH/plugins/autocoder/"* "$PLUGIN_PATH/"
cp "$REPO_PATH/.claude-plugin/plugins/autocoder/plugin.json" "$PLUGIN_PATH/"

echo "✓ Plugin updated"
echo ""

# Show version
VERSION=$(grep '"version"' "$PLUGIN_PATH/plugin.json" | head -1 | sed 's/.*"version": "\(.*\)".*/\1/')
echo "Current version: $VERSION"
echo ""

# List what's installed
echo "Installed components:"
echo "  • Commands: $(ls "$PLUGIN_PATH/commands/" 2>/dev/null | wc -l)"
echo "  • Scripts:  $(ls "$PLUGIN_PATH/scripts/" 2>/dev/null | wc -l)"
echo "  • Hooks:    $(ls "$PLUGIN_PATH/hooks/" 2>/dev/null | wc -l)"
echo ""
echo "✅ Done! The autocoder plugin is now up to date."
