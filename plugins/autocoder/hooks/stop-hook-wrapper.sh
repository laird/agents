#!/bin/bash

# Stop Hook Wrapper
# Auto-detects plugin installation context and runs the correct stop hook

set -euo pipefail

# Determine where the plugin is installed
# Priority 1: Project context (.claude-plugin/plugins/autocoder/)
# Priority 2: Personal context (~/.claude/plugins/autocoder/)

SCRIPT_DIR=""

# Check project context first
if [[ -f ".claude-plugin/plugins/autocoder/hooks/stop-hook.sh" ]]; then
    SCRIPT_DIR=".claude-plugin/plugins/autocoder/hooks"
# Check personal context
elif [[ -f "$HOME/.claude/plugins/autocoder/hooks/stop-hook.sh" ]]; then
    SCRIPT_DIR="$HOME/.claude/plugins/autocoder/hooks"
# Fallback: try alternate personal paths
elif [[ -f "$HOME/.config/claude-code/plugins/autocoder/hooks/stop-hook.sh" ]]; then
    SCRIPT_DIR="$HOME/.config/claude-code/plugins/autocoder/hooks"
else
    echo "⚠️ Error: Could not locate stop-hook.sh in any known location:" >&2
    echo "  - .claude-plugin/plugins/autocoder/hooks/stop-hook.sh (project context)" >&2
    echo "  - ~/.claude/plugins/autocoder/hooks/stop-hook.sh (personal context)" >&2
    echo "  - ~/.config/claude-code/plugins/autocoder/hooks/stop-hook.sh (alt personal)" >&2
    exit 1
fi

# Execute the actual stop hook with all stdin passed through
exec bash "$SCRIPT_DIR/stop-hook.sh"
