# Stop Hook Path Fix

## Issue

The stop hook breaks when the autocoder plugin is installed in project context (`.claude-plugin/plugins/autocoder/`) because it uses a hardcoded path to the personal/global installation location (`~/.claude/plugins/autocoder/`).

## Root Cause

The `/install` command hardcoded the stop hook path in three locations (lines 101, 138, 160 of `install.md`):

```json
"command": "bash ~/.claude/plugins/autocoder/hooks/stop-hook.sh"
```

This only works when the plugin is installed in personal context. When installed in project context, the correct path should be:

```json
"command": "bash .claude-plugin/plugins/autocoder/hooks/stop-hook.sh"
```

## Plugin Installation Contexts

Claude Code plugins can be installed in two contexts:

1. **Personal/Global Context**: `~/.claude/plugins/autocoder/`
   - Available to all projects
   - User-wide installation

2. **Project Context**: `.claude-plugin/plugins/autocoder/`
   - Specific to the current project
   - Project-local installation

## Solution

Updated the `/install` command to auto-detect the plugin installation context:

```bash
# Auto-detect plugin installation context
STOP_HOOK_PATH=""
if [ -f ".claude-plugin/plugins/autocoder/hooks/stop-hook.sh" ]; then
  STOP_HOOK_PATH=".claude-plugin/plugins/autocoder/hooks/stop-hook.sh"
  CONTEXT="project"
elif [ -f "$HOME/.claude/plugins/autocoder/hooks/stop-hook.sh" ]; then
  STOP_HOOK_PATH="$HOME/.claude/plugins/autocoder/hooks/stop-hook.sh"
  CONTEXT="personal"
elif [ -f "$HOME/.config/claude-code/plugins/autocoder/hooks/stop-hook.sh" ]; then
  STOP_HOOK_PATH="$HOME/.config/claude-code/plugins/autocoder/hooks/stop-hook.sh"
  CONTEXT="personal"
else
  echo "❌ Error: Could not locate stop-hook.sh"
  exit 1
fi
```

The detected path is then used in the settings.json configuration.

## Files Changed

1. **`plugins/autocoder/commands/install.md`**
   - Added auto-detection logic for plugin installation context
   - Updated stop hook path to use detected location
   - Updated parallel agent scripts path to use detected location
   - Removed heredoc quotes to allow variable expansion

2. **`.claude/settings.json`** (project-specific fix)
   - Updated hardcoded path to use project context path

3. **`plugins/autocoder/hooks/stop-hook-wrapper.sh`** (created)
   - Alternative wrapper approach for path resolution
   - Not currently used but available as fallback

## Testing

To test the fix:

1. **With project-installed plugin** (current state):
   ```bash
   # Verify the path in .claude/settings.json
   cat .claude/settings.json | grep stop-hook
   # Should show: .claude-plugin/plugins/autocoder/hooks/stop-hook.sh
   ```

2. **Test stop hook execution**:
   ```bash
   # Run /fix-loop and exit
   # The stop hook should execute without errors
   ```

3. **Reinstall test**:
   ```bash
   # Run /install again
   # Should detect the plugin context correctly
   ```

## Impact

- **Existing installations**: Need to run `/install` again or manually update `.claude/settings.json`
- **New installations**: Will automatically detect and use correct path
- **Parallel maintenance**: Same fix needed for `.agent/` (Antigravity) version

## Related Issues

- Parallel agent scripts had the same hardcoded path issue - also fixed
- Both stop hook and parallel scripts now auto-detect installation context

## Date

2026-02-02
