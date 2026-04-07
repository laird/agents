# Install Autocoder Plugin

Complete installation of autocoder plugin components for autonomous issue resolution and parallel agent coordination.

## Usage

```bash
/install
```

## What Gets Installed

This command installs all autocoder plugin components:

### 0. Dependency Check
- **Checks for**: tmux, cmux, claude, gemini, codex, gh
- **Action**: Reports what's installed and suggests install commands for anything missing
- **Scope**: Read-only (no changes made)

### 1. Loop Mechanism (for infinite loops)
- **Preferred**: Claude Code `/loop` command (CronCreate) — no installation needed
- **Fallback**: Stop hook in `.claude/settings.json` for older Claude Code versions
- **Purpose**: Enables `/fix-loop` to run continuously
- **Scope**: Current project only

### 2. Parallel Agent Scripts (for multi-agent coordination)
- **Files**: Symlinks in `~/.local/bin/`
  - `start-parallel` → `start-parallel-agents.sh`
  - `join-parallel` → `join-parallel-agents.sh`
  - `end-parallel` → `end-parallel-agents.sh`
  - `stop-parallel` → `stop-parallel-agents.sh`
- **Purpose**: Terminal commands to launch, join, end, and stop parallel agent sessions
- **Action**: Creates symlinks, adds `~/.local/bin` to PATH
- **Scope**: Global (available in all terminals)

### 3. Shell Aliases (optional)
- **File**: Shell rc file for the current shell, typically `~/.bashrc` or `~/.zshrc`
- **Generic aliases**: `start`, `join`, `end` (auto-detect multiplexer)
- **tmux aliases**: `startt`, `joint`, `stopt`, `endt`
- **cmux aliases**: `startc`, `joinc`, `stopc`, `endc`
- **Codex tmux aliases**: `startct`, `joinct`
- **Codex cmux aliases**: `startcc`, `joincc`
- **Purpose**: Shorter multiplexer-specific commands
- **Action**: Appends aliases to shell config (only for installed multiplexers)
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
echo "  0. Dependency check (tmux/cmux, claude/gemini/codex, gh)"
echo "  1. Loop mechanism (for infinite /fix-loop)"
echo "  2. Parallel agent scripts (terminal commands)"
echo "  3. Shell aliases (optional shortcuts)"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
```

### Part 0: Dependency Check

```bash
echo "📍 Part 0: Dependency Check"
echo ""
echo "Checking for required and optional dependencies..."
echo ""

# Check for terminal multiplexers
HAS_TMUX=false
HAS_CMUX=false
if command -v tmux &> /dev/null; then
  TMUX_VERSION=$(tmux -V 2>/dev/null || echo "unknown")
  echo "✅ tmux installed ($TMUX_VERSION)"
  HAS_TMUX=true
else
  echo "❌ tmux not installed"
  echo "   Install: brew install tmux"
  echo "   (Required for headless parallel agents on Linux/macOS)"
fi

if command -v cmux &> /dev/null; then
  echo "✅ cmux installed"
  HAS_CMUX=true
else
  echo "⚠️  cmux not installed (optional, macOS only)"
  echo "   Install: brew tap manaflow-ai/cmux && brew install --cask cmux"
  echo "   (Native macOS GUI for parallel agents)"
fi

if [ "$HAS_TMUX" = false ] && [ "$HAS_CMUX" = false ]; then
  echo ""
  echo "⚠️  No terminal multiplexer found!"
  echo "   You need at least one of tmux or cmux to run parallel agents."
  echo "   Single-agent mode (/fix, /fix-loop) works without a multiplexer."
fi

echo ""

# Check for agent frameworks
HAS_CLAUDE=false
HAS_GEMINI=false
HAS_CODEX=false
if command -v claude &> /dev/null; then
  echo "✅ Claude Code installed"
  HAS_CLAUDE=true
else
  echo "❌ Claude Code not installed"
  echo "   Install: npm install -g @anthropic-ai/claude-code"
fi

if command -v gemini &> /dev/null; then
  echo "✅ Gemini CLI installed"
  HAS_GEMINI=true
else
  echo "⚠️  Gemini CLI not installed (optional)"
  echo "   Install: npm install -g @anthropic-ai/gemini-cli"
fi

if command -v codex &> /dev/null; then
  echo "✅ Codex CLI installed"
  HAS_CODEX=true
else
  echo "⚠️  Codex CLI not installed (optional)"
  echo "   Install the Codex CLI to enable Codex worker swarms"
fi

echo ""

# Check for GitHub CLI
if command -v gh &> /dev/null; then
  echo "✅ GitHub CLI (gh) installed"
else
  echo "❌ GitHub CLI (gh) not installed"
  echo "   Install: brew install gh"
  echo "   (Required for all autocoder commands)"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
```

### Part 1: Loop Mechanism

**Check whether Claude Code supports the `/loop` command** by looking for the `CronCreate` tool in the available deferred tools list.

**If CronCreate IS available (modern Claude Code):**

```bash
echo "📍 Part 1: Loop Mechanism"
echo ""
echo "✅ Claude Code /loop command detected (CronCreate available)"
echo "   /fix-loop will use the native /loop command — no stop hook needed."
echo ""
INSTALL_STOP_HOOK=false
```

If a legacy stop hook exists, offer to clean it up:

```bash
if [ -f ".claude/settings.json" ] && grep -q "stop-hook" .claude/settings.json 2>/dev/null; then
  echo "⚠️  Legacy stop hook found in .claude/settings.json"
  echo "   This is no longer needed since /loop replaces it."
  echo ""
fi
```

Use AskUserQuestion:

```
Question: "Remove legacy stop hook from .claude/settings.json? (No longer needed with /loop command)"
Header: "Cleanup"
Options:
  - "Yes, remove it" - "Clean up the legacy stop hook since /loop replaces it"
  - "No, leave it" - "Keep the stop hook (harmless but unnecessary)"
```

If approved:

```bash
if [ "$USER_APPROVED_CLEANUP" = "yes" ]; then
  python3 << 'PYTHON_SCRIPT'
import json
with open(".claude/settings.json", 'r') as f:
    settings = json.load(f)
if "hooks" in settings and "Stop" in settings["hooks"]:
    settings["hooks"]["Stop"] = [h for h in settings["hooks"]["Stop"] if "stop-hook" not in str(h)]
    if not settings["hooks"]["Stop"]:
        del settings["hooks"]["Stop"]
    if not settings["hooks"]:
        del settings["hooks"]
with open(".claude/settings.json", 'w') as f:
    json.dump(settings, f, indent=2)
print("✅ Legacy stop hook removed")
PYTHON_SCRIPT
else
  echo "⏭️  Kept legacy stop hook"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
```

Skip the cleanup question entirely if no legacy stop hook was found.

---

**If CronCreate is NOT available (older Claude Code) → Install stop hook as fallback:**

```bash
echo "📍 Part 1: Stop Hook Installation (fallback)"
echo ""
echo "⚠️  Claude Code /loop command not available in this version."
echo "   Installing stop hook for /fix-loop to run continuously."
echo ""
echo "Purpose: Intercepts session exits and feeds /fix back as input."
echo "Location: .claude/settings.json (current project only)"
echo ""

# Auto-detect plugin installation context
# Priority 1: project-local dev install (this repo's own plugins/ directory)
# Priority 2: marketplace cache (~/.claude/plugins/cache/**/autocoder/**)
# Priority 3: legacy fixed paths
STOP_HOOK_PATH=""
if [ -f "plugins/autocoder/hooks/stop-hook.sh" ]; then
  STOP_HOOK_PATH="plugins/autocoder/hooks/stop-hook.sh"
  CONTEXT="project (plugins/)"
elif [ -f ".claude-plugin/plugins/autocoder/hooks/stop-hook.sh" ]; then
  STOP_HOOK_PATH=".claude-plugin/plugins/autocoder/hooks/stop-hook.sh"
  CONTEXT="project (.claude-plugin/)"
else
  # Search plugin cache - finds any marketplace/version, picks latest by version sort
  CACHE_HOOK=$(find "$HOME/.claude/plugins/cache" -name "stop-hook.sh" -path "*/autocoder/*" ! -name "*wrapper*" 2>/dev/null | sort -V | tail -1)
  if [ -n "$CACHE_HOOK" ]; then
    STOP_HOOK_PATH="$CACHE_HOOK"
    CONTEXT="marketplace cache"
  else
    echo "❌ Error: Could not locate stop-hook.sh"
    echo "   Searched:"
    echo "   - plugins/autocoder/hooks/stop-hook.sh (project)"
    echo "   - .claude-plugin/plugins/autocoder/hooks/stop-hook.sh (project)"
    echo "   - ~/.claude/plugins/cache/**/autocoder/**/hooks/stop-hook.sh (marketplace)"
    exit 1
  fi
fi

echo "🔍 Detected: Plugin installed in $CONTEXT context"
echo "   Path: $STOP_HOOK_PATH"
echo ""

# Check if already installed
if [ -f ".claude/settings.json" ] && grep -qF "$STOP_HOOK_PATH" .claude/settings.json 2>/dev/null; then
  echo "✅ Stop hook already installed in this project"
  INSTALL_STOP_HOOK=false
else
  echo "📝 Stop hook not found. Will add this to .claude/settings.json:"
  echo ""
  cat << PREVIEW
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "bash $STOP_HOOK_PATH"
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
Question: "Install stop hook in this project? (needed for /fix-loop on older Claude Code)"
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
    python3 << PYTHON_SCRIPT
import json
import os
with open(".claude/settings.json", 'r') as f:
    settings = json.load(f)
stop_hook = {"matcher": "", "hooks": [{"type": "command", "command": "bash $STOP_HOOK_PATH"}]}
if "hooks" not in settings:
    settings["hooks"] = {}
if "Stop" not in settings["hooks"]:
    settings["hooks"]["Stop"] = []
CURRENT_CMD = "bash $STOP_HOOK_PATH"
# Remove stale/legacy stop hooks (e.g. stop-hook-wrapper.sh) that aren't the current hook
settings["hooks"]["Stop"] = [h for h in settings["hooks"]["Stop"] if "stop-hook" not in str(h) or CURRENT_CMD in str(h)]
if not any(CURRENT_CMD in str(h) for h in settings["hooks"]["Stop"]):
    settings["hooks"]["Stop"].append(stop_hook)
with open(".claude/settings.json", 'w') as f:
    json.dump(settings, f, indent=2)
print("✅ Stop hook installed")
PYTHON_SCRIPT
  else
    # Create new settings file
    cat > .claude/settings.json << EOF
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "bash $STOP_HOOK_PATH"
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

# Auto-detect plugin script directory (same priority order as stop hook)
if [ -d "plugins/autocoder/scripts" ]; then
  SCRIPT_DIR="$(pwd)/plugins/autocoder/scripts"
elif [ -d ".claude-plugin/plugins/autocoder/scripts" ]; then
  SCRIPT_DIR="$(pwd)/.claude-plugin/plugins/autocoder/scripts"
else
  # Search plugin cache - same logic as stop hook detection above
  CACHE_SCRIPTS=$(find "$HOME/.claude/plugins/cache" -type d -name "scripts" -path "*/autocoder/*" 2>/dev/null | sort -V | tail -1)
  if [ -n "$CACHE_SCRIPTS" ]; then
    SCRIPT_DIR="$CACHE_SCRIPTS"
  else
    echo "❌ Error: Could not locate autocoder scripts directory"
    echo "   Searched:"
    echo "   - plugins/autocoder/scripts (project)"
    echo "   - .claude-plugin/plugins/autocoder/scripts (project)"
    echo "   - ~/.claude/plugins/cache/**/autocoder/**/scripts (marketplace)"
    exit 1
  fi
fi

echo "🔍 Scripts directory: $SCRIPT_DIR"
echo ""

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
  echo "  stop-parallel  -> $SCRIPT_DIR/stop-parallel-agents.sh"
  echo ""
  echo "Terminal usage after install:"
  echo "  cd ~/src/myproject"
  echo "  start-parallel 3    # Launch 3 parallel agents"
  echo "  join-parallel       # Rejoin session"
  echo "  end-parallel        # End session and clean up worktrees"
  echo "  stop-parallel       # Stop sessions (no cleanup)"
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
  ln -sf "$SCRIPT_DIR/stop-parallel-agents.sh" "$INSTALL_DIR/stop-parallel"

  echo "✅ Symlinks created:"
  echo "   $INSTALL_DIR/start-parallel"
  echo "   $INSTALL_DIR/join-parallel"
  echo "   $INSTALL_DIR/end-parallel"
  echo "   $INSTALL_DIR/stop-parallel"

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
echo "Purpose: Shorter commands for convenience, with multiplexer-specific variants."
echo ""
echo "Location: $SHELL_RC"
echo ""
echo "📝 Will add these aliases:"
echo ""
echo "  # Generic (auto-detect multiplexer)"
echo "  alias start='start-parallel'"
echo "  alias join='join-parallel'"
echo "  alias end='end-parallel'"
echo ""
```

Check which multiplexers are available and offer mux-specific aliases:

```bash
if [ "$HAS_TMUX" = true ]; then
  echo "  # tmux-specific"
  echo "  alias startt='start-parallel --mux tmux'"
  echo "  alias joint='join-parallel --mux tmux'"
  echo "  alias stopt='stop-parallel --mux tmux'"
  echo "  alias endt='end-parallel'"
fi

if [ "$HAS_CMUX" = true ]; then
  echo "  # cmux-specific"
  echo "  alias startc='start-parallel --mux cmux'"
  echo "  alias joinc='join-parallel --mux cmux'"
  echo "  alias stopc='stop-parallel --mux cmux'"
  echo "  alias endc='end-parallel'"
fi

if [ "$HAS_CODEX" = true ] && [ "$HAS_TMUX" = true ]; then
  echo "  # Codex + tmux"
  echo "  alias startct='start-parallel --mux tmux --agent codex'"
  echo "  alias joinct='join-parallel --mux tmux'"
fi

if [ "$HAS_CODEX" = true ] && [ "$HAS_CMUX" = true ]; then
  echo "  # Codex + cmux"
  echo "  alias startcc='start-parallel --mux cmux --agent codex'"
  echo "  alias joincc='join-parallel --mux cmux'"
fi

echo ""
echo "⚠️  Warning: Only install if you don't have conflicting aliases."
echo ""
echo "Usage after install:"
echo "  cd ~/src/myproject"
if [ "$HAS_CMUX" = true ]; then
  echo "  startc 3   # Launch 3 agents in cmux"
  echo "  joinc      # Rejoin cmux session"
  echo "  endc       # End cmux session + cleanup"
fi
if [ "$HAS_CODEX" = true ] && [ "$HAS_CMUX" = true ]; then
  echo "  startcc 3  # Launch 1 manager + 3 Codex workers in cmux"
  echo "  joincc     # Rejoin/list Codex cmux workspaces"
fi
if [ "$HAS_TMUX" = true ]; then
  echo "  startt 3   # Launch 3 agents in tmux"
  echo "  joint      # Rejoin tmux session"
  echo "  endt       # End tmux session + cleanup"
fi
if [ "$HAS_CODEX" = true ] && [ "$HAS_TMUX" = true ]; then
  echo "  startct 3  # Launch 1 manager + 3 Codex workers in tmux"
  echo "  joinct     # Rejoin Codex tmux session"
fi
echo ""
```

Use AskUserQuestion:

```
Question: "Create shell aliases?"
Header: "Aliases"
Options:
  - "Yes, create aliases" - "Multiplexer-specific shortcuts including Codex aliases when Codex is installed"
  - "No, use full names" - "Keep using 'start-parallel', 'join-parallel', 'end-parallel', and 'stop-parallel'"
```

If approved:

```bash
if [ "$USER_APPROVED_ALIASES" = "yes" ]; then
  # Check for conflicts with generic aliases
  CONFLICTS=false
  if alias start 2>/dev/null | grep -qv "start-parallel"; then
    echo "⚠️  Warning: 'start' alias already exists — skipping generic aliases"
    CONFLICTS=true
  fi

  if [ "$CONFLICTS" = false ]; then
    # Generic aliases
    echo "" >> "$SHELL_RC"
    echo "# Autocoder parallel agent aliases" >> "$SHELL_RC"
    echo "alias start='start-parallel'" >> "$SHELL_RC"
    echo "alias join='join-parallel'" >> "$SHELL_RC"
    echo "alias end='end-parallel'" >> "$SHELL_RC"
    echo "✅ Generic aliases added (start, join, end)"
  fi

  # tmux-specific aliases (always safe — unique names)
  if [ "$HAS_TMUX" = true ]; then
    echo "alias startt='start-parallel --mux tmux'" >> "$SHELL_RC"
    echo "alias joint='join-parallel --mux tmux'" >> "$SHELL_RC"
    echo "alias stopt='stop-parallel --mux tmux'" >> "$SHELL_RC"
    echo "alias endt='end-parallel'" >> "$SHELL_RC"
    echo "✅ tmux aliases added (startt, joint, stopt, endt)"
  fi

  # cmux-specific aliases (always safe — unique names)
  if [ "$HAS_CMUX" = true ]; then
    echo "alias startc='start-parallel --mux cmux'" >> "$SHELL_RC"
    echo "alias joinc='join-parallel --mux cmux'" >> "$SHELL_RC"
    echo "alias stopc='stop-parallel --mux cmux'" >> "$SHELL_RC"
    echo "alias endc='end-parallel'" >> "$SHELL_RC"
    echo "✅ cmux aliases added (startc, joinc, stopc, endc)"
  fi

  if [ "$HAS_CODEX" = true ] && [ "$HAS_TMUX" = true ]; then
    echo "alias startct='start-parallel --mux tmux --agent codex'" >> "$SHELL_RC"
    echo "alias joinct='join-parallel --mux tmux'" >> "$SHELL_RC"
    echo "✅ Codex tmux aliases added (startct, joinct)"
  fi

  if [ "$HAS_CODEX" = true ] && [ "$HAS_CMUX" = true ]; then
    echo "alias startcc='start-parallel --mux cmux --agent codex'" >> "$SHELL_RC"
    echo "alias joincc='join-parallel --mux cmux'" >> "$SHELL_RC"
    echo "✅ Codex cmux aliases added (startcc, joincc)"
  fi

  echo "   ⚡ Restart your shell or run: source $SHELL_RC"
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

if [ "$INSTALL_STOP_HOOK" = false ] && grep -q "CronCreate" <<< "${AVAILABLE_TOOLS:-}"; then
  echo "  ✅ /loop command available (no stop hook needed)"
  echo "     → /fix-loop uses native CronCreate mechanism"
elif [ "$INSTALL_STOP_HOOK" = true ] && [ "$USER_APPROVED_STOP_HOOK" = "yes" ]; then
  echo "  ✅ Stop hook in .claude/settings.json (fallback)"
  echo "     → Enables /fix-loop to run continuously"
else
  echo "  ⏭️  Loop mechanism (skipped)"
fi

if [ "$INSTALL_SCRIPTS" = true ] && [ "$USER_APPROVED_SCRIPTS" = "yes" ]; then
  echo "  ✅ Parallel agent scripts in ~/.local/bin/"
  echo "     → start-parallel: Launch multi-agent system"
  echo "     → join-parallel: Rejoin existing session"
  echo "     → end-parallel: End session and clean up worktrees"
  echo "     → stop-parallel: Stop sessions (no cleanup)"
else
  echo "  ⏭️  Parallel agent scripts (skipped)"
fi

if [ "$USER_APPROVED_ALIASES" = "yes" ]; then
  echo "  ✅ Shell aliases in $SHELL_RC"
  if [ "$HAS_TMUX" = true ]; then
    echo "     → tmux: startt, joint, stopt, endt"
  fi
  if [ "$HAS_CMUX" = true ]; then
    echo "     → cmux: startc, joinc, stopc, endc"
  fi
  if [ "$HAS_CODEX" = true ] && [ "$HAS_TMUX" = true ]; then
    echo "     → Codex tmux: startct, joinct"
  fi
  if [ "$HAS_CODEX" = true ] && [ "$HAS_CMUX" = true ]; then
    echo "     → Codex cmux: startcc, joincc"
  fi
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
  if [ "$USER_APPROVED_ALIASES" = "yes" ]; then
    if [ "$HAS_CMUX" = true ]; then
      echo "   startc 3     # Launch 3 agents in cmux"
      echo "   joinc        # Rejoin cmux session"
      echo "   endc         # End session + cleanup"
    fi
    if [ "$HAS_CODEX" = true ] && [ "$HAS_CMUX" = true ]; then
      echo "   startcc 3    # Launch 1 manager + 3 Codex workers in cmux"
      echo "   joincc       # Rejoin/list Codex cmux workspaces"
    fi
    if [ "$HAS_TMUX" = true ]; then
      echo "   startt 3     # Launch 3 agents in tmux"
      echo "   joint        # Rejoin tmux session"
      echo "   endt         # End session + cleanup"
    fi
    if [ "$HAS_CODEX" = true ] && [ "$HAS_TMUX" = true ]; then
      echo "   startct 3    # Launch 1 manager + 3 Codex workers in tmux"
      echo "   joinct       # Rejoin Codex tmux session"
    fi
  else
    echo "   start-parallel 3    # Launch 3 parallel agents"
    echo "   join-parallel       # Rejoin session"
    echo "   end-parallel        # End session + cleanup"
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
