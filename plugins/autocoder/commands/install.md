# Install Autocoder Plugin

Complete installation of autocoder plugin components for autonomous issue resolution and parallel agent coordination.

## Usage

```bash
/install
```

## What Gets Installed

This command installs all autocoder plugin components:

### 1. Stop Hook (for infinite loops)
- **File**: `.claude/settings.json` in current project
- **Purpose**: Enables `/fix-loop` to run continuously
- **Action**: Adds stop hook configuration to settings
- **Scope**: Current project only

### 2. Parallel Agent Scripts (for multi-agent coordination)
- **Files**: Symlinks in `~/.local/bin/`
  - `start-parallel` → `~/.claude/plugins/autocoder/scripts/start-parallel-agents.sh`
  - `join-parallel` → `~/.claude/plugins/autocoder/scripts/join-parallel-agents.sh`
- **Purpose**: Terminal commands to launch/join parallel agent sessions
- **Action**: Creates symlinks, adds `~/.local/bin` to PATH
- **Scope**: Global (available in all terminals)

### 3. Shell Aliases (optional)
- **File**: `~/.bashrc` or `~/.zshrc`
- **Aliases**:
  - `start='start-parallel'`
  - `join='join-parallel'`
- **Purpose**: Shorter commands for convenience
- **Action**: Appends aliases to shell config
- **Scope**: Global (available in all terminals after restart)

## Installation Process

The installer will:

1. ✅ **Check** what's already installed
2. 📋 **Explain** what changes will be made
3. ❓ **Ask** for confirmation before each change
4. ✅ **Install** only what you approve
5. 📝 **Report** what was done

## No Surprises

Before making any changes:
- Shows exactly what files will be modified
- Shows exact content that will be added
- Asks for your approval
- Skips anything you decline
- Never modifies files without permission

## Instructions

Run the installer now:

```bash
echo "🔧 Autocoder Plugin Installer"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "This installer will set up:"
echo "  1. Stop hook (for infinite /fix-loop)"
echo "  2. Parallel agent scripts (terminal commands)"
echo "  3. Shell aliases (optional shortcuts)"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
```

### Part 1: Stop Hook Installation

```bash
echo "📍 Part 1: Stop Hook Installation"
echo ""
echo "Purpose: Enables /fix-loop to run continuously by intercepting"
echo "         session exits and feeding /fix back as input."
echo ""
echo "Location: .claude/settings.json (current project only)"
echo ""

# Check if already installed
if [ -f ".claude/settings.json" ] && grep -q "stop-hook.sh" .claude/settings.json 2>/dev/null; then
  echo "✅ Stop hook already installed in this project"
  INSTALL_STOP_HOOK=false
else
  echo "📝 Stop hook not found. Will add this to .claude/settings.json:"
  echo ""
  cat << 'PREVIEW'
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
PREVIEW
  echo ""
  INSTALL_STOP_HOOK=true
fi

echo ""
```

Use AskUserQuestion to ask about stop hook:

```
Question: "Install stop hook in this project?"
Header: "Stop Hook"
Options:
  - "Yes, install stop hook" - "Required for /fix-loop to run continuously"
  - "No, skip this step" - "You can install later with /install"
```

If approved:

```bash
if [ "$USER_APPROVED_STOP_HOOK" = "yes" ]; then
  mkdir -p .claude

  if [ -f ".claude/settings.json" ]; then
    # Merge with existing settings
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
    print("✅ Stop hook installed")
PYTHON_SCRIPT
  else
    # Create new settings file
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
    echo "✅ Stop hook installed"
  fi
else
  echo "⏭️  Skipped stop hook installation"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
```

### Part 2: Parallel Agent Scripts

```bash
echo "📍 Part 2: Parallel Agent Scripts"
echo ""
echo "Purpose: Terminal commands for multi-agent coordination using"
echo "         tmux and git worktrees."
echo ""
echo "Location: ~/.local/bin/ (global, all projects)"
echo ""

INSTALL_DIR="$HOME/.local/bin"
SCRIPT_DIR="$HOME/.claude/plugins/autocoder/scripts"

# Check if already installed
if [ -f "$INSTALL_DIR/start-parallel" ] && [ -f "$INSTALL_DIR/join-parallel" ] && [ -f "$INSTALL_DIR/end-parallel" ]; then
  echo "✅ Parallel agent scripts already installed"
  INSTALL_SCRIPTS=false
else
  echo "📝 Will create these symlinks in $INSTALL_DIR:"
  echo ""
  echo "  start-parallel -> $SCRIPT_DIR/start-parallel-agents.sh"
  echo "  join-parallel  -> $SCRIPT_DIR/join-parallel-agents.sh"
  echo "  end-parallel   -> $SCRIPT_DIR/end-parallel-agents.sh"
  echo ""
  echo "Terminal usage after install:"
  echo "  cd ~/src/myproject"
  echo "  start-parallel 3    # Launch 3 parallel agents"
  echo "  join-parallel       # Rejoin session"
  echo "  end-parallel        # End session and optionally clean up worktrees"
  echo ""
  INSTALL_SCRIPTS=true
fi

# Check PATH
PATH_OK=false
if [[ ":$PATH:" == *":$HOME/.local/bin:"* ]]; then
  echo "✅ ~/.local/bin is already in your PATH"
  PATH_OK=true
else
  # Detect shell
  if [ -n "$BASH_VERSION" ]; then
    SHELL_RC="$HOME/.bashrc"
    SHELL_NAME="bash"
  elif [ -n "$ZSH_VERSION" ]; then
    SHELL_RC="$HOME/.zshrc"
    SHELL_NAME="zsh"
  else
    SHELL_RC="$HOME/.profile"
    SHELL_NAME="shell"
  fi

  echo "⚠️  ~/.local/bin is NOT in your PATH"
  echo ""
  echo "📝 Will add this line to $SHELL_RC:"
  echo ""
  echo '  export PATH="$HOME/.local/bin:$PATH"'
  echo ""
  echo "After install, restart your $SHELL_NAME or run:"
  echo "  source $SHELL_RC"
  echo ""
fi

echo ""
```

Use AskUserQuestion:

```
Question: "Install parallel agent scripts?"
Header: "Scripts"
Options:
  - "Yes, install scripts" - "Global terminal commands: start-parallel, join-parallel, end-parallel"
  - "No, skip this step" - "You can install later with /install"
```

If approved:

```bash
if [ "$USER_APPROVED_SCRIPTS" = "yes" ]; then
  # Create install directory
  mkdir -p "$INSTALL_DIR"

  # Create symlinks
  ln -sf "$SCRIPT_DIR/start-parallel-agents.sh" "$INSTALL_DIR/start-parallel"
  ln -sf "$SCRIPT_DIR/join-parallel-agents.sh" "$INSTALL_DIR/join-parallel"
  ln -sf "$SCRIPT_DIR/end-parallel-agents.sh" "$INSTALL_DIR/end-parallel"

  echo "✅ Symlinks created:"
  echo "   $INSTALL_DIR/start-parallel"
  echo "   $INSTALL_DIR/join-parallel"
  echo "   $INSTALL_DIR/end-parallel"

  # Add to PATH if needed
  if [ "$PATH_OK" = false ]; then
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$SHELL_RC"
    echo "✅ PATH updated in $SHELL_RC"
    echo "   ⚡ Restart your shell or run: source $SHELL_RC"
  fi
else
  echo "⏭️  Skipped script installation"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
```

### Part 3: Shell Aliases (Optional)

```bash
echo "📍 Part 3: Shell Aliases (Optional)"
echo ""
echo "Purpose: Shorter commands for convenience."
echo ""
echo "Location: $SHELL_RC"
echo ""
echo "📝 Will add these aliases:"
echo ""
echo "  alias start='start-parallel'"
echo "  alias join='join-parallel'"
echo "  alias end='end-parallel'"
echo ""
echo "⚠️  Warning: Only install if you don't have conflicting 'start',"
echo "            'join', or 'end' aliases in your shell."
echo ""
echo "Usage after install:"
echo "  cd ~/src/myproject"
echo "  start 3    # Instead of: start-parallel 3"
echo "  join       # Instead of: join-parallel"
echo "  end        # Instead of: end-parallel"
echo ""
```

Use AskUserQuestion:

```
Question: "Create shell aliases?"
Header: "Aliases"
Options:
  - "Yes, create aliases" - "Shorter commands: 'start', 'join', and 'end'"
  - "No, use full names" - "Keep using 'start-parallel', 'join-parallel', and 'end-parallel'"
```

If approved:

```bash
if [ "$USER_APPROVED_ALIASES" = "yes" ]; then
  # Check for conflicts
  CONFLICTS=false
  if alias start 2>/dev/null | grep -qv "start-parallel"; then
    echo "⚠️  Warning: 'start' alias already exists:"
    alias start
    CONFLICTS=true
  fi
  if alias join 2>/dev/null | grep -qv "join-parallel"; then
    echo "⚠️  Warning: 'join' alias already exists:"
    alias join
    CONFLICTS=true
  fi
  if alias end 2>/dev/null | grep -qv "end-parallel"; then
    echo "⚠️  Warning: 'end' alias already exists:"
    alias end
    CONFLICTS=true
  fi

  if [ "$CONFLICTS" = true ]; then
    echo ""
    echo "⚠️  Existing aliases detected. Skipping to avoid conflicts."
  else
    echo "alias start='start-parallel'" >> "$SHELL_RC"
    echo "alias join='join-parallel'" >> "$SHELL_RC"
    echo "alias end='end-parallel'" >> "$SHELL_RC"
    echo "✅ Aliases added to $SHELL_RC"
    echo "   ⚡ Restart your shell or run: source $SHELL_RC"
  fi
else
  echo "⏭️  Skipped alias creation"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
```

### Summary

```bash
echo "✅ Installation Complete!"
echo ""
echo "📊 What was installed:"
echo ""

if [ "$INSTALL_STOP_HOOK" = true ] && [ "$USER_APPROVED_STOP_HOOK" = "yes" ]; then
  echo "  ✅ Stop hook in .claude/settings.json"
  echo "     → Enables /fix-loop to run continuously"
else
  echo "  ⏭️  Stop hook (skipped)"
fi

if [ "$INSTALL_SCRIPTS" = true ] && [ "$USER_APPROVED_SCRIPTS" = "yes" ]; then
  echo "  ✅ Parallel agent scripts in ~/.local/bin/"
  echo "     → start-parallel: Launch multi-agent system"
  echo "     → join-parallel: Rejoin existing session"
else
  echo "  ⏭️  Parallel agent scripts (skipped)"
fi

if [ "$USER_APPROVED_ALIASES" = "yes" ] && [ "$CONFLICTS" = false ]; then
  echo "  ✅ Shell aliases in $SHELL_RC"
  echo "     → start: Shortcut for start-parallel"
  echo "     → join: Shortcut for join-parallel"
else
  echo "  ⏭️  Shell aliases (skipped)"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "🚀 Quick Start:"
echo ""
echo "1. Test in this project:"
echo "   /fix-loop"
echo ""
if [ "$USER_APPROVED_SCRIPTS" = "yes" ]; then
  echo "2. From terminal (after restarting shell):"
  echo "   cd ~/src/myproject"
  if [ "$USER_APPROVED_ALIASES" = "yes" ] && [ "$CONFLICTS" = false ]; then
    echo "   start 3       # Launch 3 parallel agents"
    echo "   join          # Rejoin session"
  else
    echo "   start-parallel 3    # Launch 3 parallel agents"
    echo "   join-parallel       # Rejoin session"
  fi
  echo ""
fi
echo "💡 Tip: Run /install again anytime to install skipped components"
echo ""
```

## What Gets Modified

### Files Created/Modified

1. **`.claude/settings.json`** (project-local)
   - Only if stop hook approved
   - Merged with existing settings if file exists
   - Creates new file if doesn't exist

2. **`~/.local/bin/start-parallel`** (symlink, global)
   - Only if scripts approved
   - Points to plugin script, stays updated with plugin

3. **`~/.local/bin/join-parallel`** (symlink, global)
   - Only if scripts approved
   - Points to plugin script, stays updated with plugin

4. **`~/.bashrc` or `~/.zshrc`** (global)
   - Only if PATH needed or aliases approved
   - Appends lines, never modifies existing content
   - Safe to run multiple times (checks before adding)

### What's Safe

- ✅ No files deleted
- ✅ No existing content modified
- ✅ Only appends to config files
- ✅ Checks for conflicts before adding
- ✅ Symlinks (not copies) stay updated
- ✅ Safe to run multiple times
- ✅ Clear explanation before each change
- ✅ User approval required for each step

## Uninstallation

To remove installed components:

```bash
# Remove stop hook
rm .claude/settings.json

# Remove scripts
rm ~/.local/bin/start-parallel
rm ~/.local/bin/join-parallel

# Remove PATH (edit manually)
# Remove aliases (edit manually)
nano ~/.bashrc  # or ~/.zshrc
```

## Re-running

Safe to run `/install` multiple times:
- Detects what's already installed
- Skips or offers to reinstall
- No duplicate entries in config files
