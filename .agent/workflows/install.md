# Install Agents Framework (Antigravity)

Install the Modernize agents framework into a project repository to enable autonomous issue resolution and parallel agent coordination.

## Usage

```bash
/install
```

## What Gets Installed

This command installs the agents framework into your project:

### 1. Agents Framework (`.agent/` directory)
- **Options**:
  - **Symlink** (Recommended) - Stays updated with framework improvements
  - **Copy** - Independent snapshot, customize as needed
- **Purpose**: Provides protocols, agent rules, and workflows
- **Scope**: Project-specific

### 2. Parallel Agent Scripts
- **Files**: Optional symlinks in `~/.local/bin/`
  - `start-parallel` → Framework path to `start-parallel-agents.sh`
  - `join-parallel` → Framework path to `join-parallel-agents.sh`
- **Purpose**: Terminal commands to manage parallel agents
- **Action**: Creates symlinks, adds `~/.local/bin` to PATH
- **Scope**: Global (available in all terminals)

### 3. Shell Aliases (optional)
- **File**: `~/.bashrc` or `~/.zshrc`
- **Aliases**:
  - `start-parallel='bash <framework-path>/.agent/scripts/start-parallel-agents.sh'`
  - `join-parallel='bash <framework-path>/.agent/scripts/join-parallel-agents.sh'`
- **Purpose**: Quick commands to manage parallel agents
- **Scope**: Global

## Installation Process

The installer will:

1. ✅ **Detect** framework location and target project
2. 📋 **Explain** what will be installed
3. ❓ **Ask** for your preference (symlink vs copy)
4. ✅ **Install** the framework
5. 📝 **Report** what was done

## No Surprises

Before making any changes:
- Shows exactly what will be installed
- Explains symlink vs copy trade-offs
- Asks for your approval
- Never modifies files without permission

## Instructions

### Step 1: Determine Installation Type

First, determine where you're running this command:

```bash
# Check if we're in the agents framework repo
if [ -d ".agent/rules" ] && [ -d ".agent/protocols" ] && [ -f ".agent/workflows/install.md" ]; then
  echo "📍 Running from agents framework repository"
  echo ""
  IN_FRAMEWORK_REPO=true
  FRAMEWORK_PATH=$(pwd)
else
  echo "📍 Running from target project"
  echo ""
  IN_FRAMEWORK_REPO=false
  TARGET_PROJECT=$(pwd)
fi
```

### Step 2: Framework Installation

If running from framework repo, ask for target project:

```bash
if [ "$IN_FRAMEWORK_REPO" = true ]; then
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "🎯 Target Project Installation"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
fi
```

Use AskUserQuestion to ask about the target project path and installation method:

```
Question: "Where should the agents framework be installed?"
Options:
- "Current directory" - Install in the current project (if not in framework repo)
- "Specify path" - Provide a path to the target project
```

Then ask:

```
Question: "How should the .agent/ directory be installed?"
Options:
- "Symlink (Recommended)" - "Stays updated with framework. Changes sync automatically. Best for most projects."
- "Copy (Independent)" - "Standalone copy you can customize. Won't receive automatic updates."
```

### Step 3: Perform Installation

Based on user choice:

**If Symlink:**

```bash
TARGET_PATH="<user-specified-path>"
FRAMEWORK_PATH="<detected-framework-path>"

# Check if .agent already exists
if [ -L "$TARGET_PATH/.agent" ]; then
  EXISTING_TARGET=$(readlink "$TARGET_PATH/.agent")
  echo "⚠️  .agent/ symlink already exists"
  echo "   Points to: $EXISTING_TARGET"
  echo ""

  # Ask if they want to replace it
  # If yes, remove and recreate
  # If no, skip this step
elif [ -d "$TARGET_PATH/.agent" ]; then
  echo "⚠️  .agent/ directory already exists (not a symlink)"
  echo ""

  # Ask what to do:
  # - Backup and replace with symlink
  # - Skip installation
  # - Abort
else
  echo "📁 Creating symlink..."
  ln -s "$FRAMEWORK_PATH/.agent" "$TARGET_PATH/.agent"
  echo "   ✓ Created: $TARGET_PATH/.agent -> $FRAMEWORK_PATH/.agent"
  echo ""
fi
```

**If Copy:**

```bash
TARGET_PATH="<user-specified-path>"
FRAMEWORK_PATH="<detected-framework-path>"

# Check if .agent already exists
if [ -d "$TARGET_PATH/.agent" ]; then
  echo "⚠️  .agent/ directory already exists"
  echo ""

  # Ask what to do:
  # - Backup and replace
  # - Skip installation
  # - Abort
else
  echo "📁 Copying framework..."
  cp -r "$FRAMEWORK_PATH/.agent" "$TARGET_PATH/.agent"
  echo "   ✓ Copied to: $TARGET_PATH/.agent"
  echo ""
fi
```

### Step 4: Optional Script Installation

Ask if they want global script access:

```
Question: "Install parallel agent scripts globally?"
Options:
- "Yes, install scripts" - "Add start-parallel and join-parallel commands to ~/.local/bin"
- "No, skip scripts" - "Use scripts directly from .agent/scripts/ directory"
```

**If Yes:**

```bash
FRAMEWORK_PATH="<detected-framework-path>"

# Ensure ~/.local/bin exists
mkdir -p ~/.local/bin

# Create symlinks
ln -sf "$FRAMEWORK_PATH/.agent/scripts/start-parallel-agents.sh" ~/.local/bin/start-parallel
ln -sf "$FRAMEWORK_PATH/.agent/scripts/join-parallel-agents.sh" ~/.local/bin/join-parallel

echo "✓ Installed: ~/.local/bin/start-parallel"
echo "✓ Installed: ~/.local/bin/join-parallel"
echo ""

# Check if ~/.local/bin is in PATH
if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
  echo "⚠️  ~/.local/bin is not in your PATH"
  echo ""
  echo "Add this to ~/.bashrc or ~/.zshrc:"
  echo '   export PATH="$HOME/.local/bin:$PATH"'
  echo ""
fi
```

### Step 5: Optional Shell Aliases

Ask if they want shorter aliases:

```
Question: "Add shell aliases for convenience?"
Options:
- "Yes, add aliases" - "Add 'start' and 'join' aliases to shell config"
- "No, skip aliases" - "Use full command names (start-parallel, join-parallel)"
```

**If Yes:**

```bash
# Detect shell
SHELL_RC=""
if [ -n "$ZSH_VERSION" ]; then
  SHELL_RC="$HOME/.zshrc"
elif [ -n "$BASH_VERSION" ]; then
  SHELL_RC="$HOME/.bashrc"
else
  echo "⚠️  Could not detect shell type"
  echo "   Please add aliases manually"
  exit 0
fi

# Check for existing aliases
if grep -q "alias start=" "$SHELL_RC" 2>/dev/null; then
  echo "⚠️  Alias 'start' already exists in $SHELL_RC"
  # Ask if they want to overwrite
fi

if grep -q "alias join=" "$SHELL_RC" 2>/dev/null; then
  echo "⚠️  Alias 'join' already exists in $SHELL_RC"
  # Ask if they want to overwrite
fi

# Add aliases
cat >> "$SHELL_RC" << 'EOF'

# Antigravity parallel agents
alias start='start-parallel'
alias join='join-parallel'
EOF

echo "✓ Added aliases to $SHELL_RC"
echo ""
echo "Run this to activate:"
echo "   source $SHELL_RC"
echo ""
```

### Step 6: Installation Summary

```bash
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Installation Complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📋 What was installed:"
echo ""

if [ "$INSTALL_METHOD" = "symlink" ]; then
  echo "   • .agent/ framework (symlinked)"
  echo "     Target: $TARGET_PATH/.agent"
  echo "     Source: $FRAMEWORK_PATH/.agent"
  echo "     Updates: Automatic (follows framework)"
else
  echo "   • .agent/ framework (copied)"
  echo "     Location: $TARGET_PATH/.agent"
  echo "     Updates: Manual (independent copy)"
fi

if [ "$INSTALL_SCRIPTS" = true ]; then
  echo "   • Parallel agent scripts"
  echo "     Commands: start-parallel, join-parallel"
fi

if [ "$INSTALL_ALIASES" = true ]; then
  echo "   • Shell aliases"
  echo "     Shortcuts: start, join"
fi

echo ""
echo "🚀 Next Steps:"
echo ""
echo "   1. Navigate to your project:"
echo "      cd $TARGET_PATH"
echo ""
echo "   2. Start parallel agents:"
echo "      start-parallel 3    # or: bash .agent/scripts/start-parallel-agents.sh 3"
echo ""
echo "   3. In Antigravity, open the configured workspaces"
echo ""
echo "   4. Run workflows:"
echo "      /fix-loop           # In coordinator and worker workspaces"
echo "      /review-blocked     # In review workspace"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
```

## Notes

- **Symlink Recommendation**: Most users should choose symlink to receive framework updates automatically
- **Copy Option**: Use copy if you need to customize protocols/rules for your specific project
- **Framework Updates**: If using symlink, `git pull` in the framework repo updates all linked projects
- **Multiple Projects**: You can symlink multiple projects to the same framework installation
- **Customization**: After copying, you can modify `.agent/` files without affecting the framework
- **Worktree Support**: When creating git worktrees with `start-parallel-agents.sh`, the script automatically detects if `.agent/` is a symlink and replicates it to each worktree. This ensures all parallel agents share the same framework files.

## Troubleshooting

### Symlink Not Working

If symlink doesn't work:
- Ensure source path is absolute
- Check file system supports symlinks
- Verify permissions on both directories

### PATH Not Updated

If commands not found after installation:
```bash
# Add to ~/.bashrc or ~/.zshrc
export PATH="$HOME/.local/bin:$PATH"

# Then reload
source ~/.bashrc  # or source ~/.zshrc
```

### Antigravity Not Found

The install script attempts to launch Antigravity automatically but may fail if:
- Antigravity not in PATH
- Different installation method needed for your platform

You can still use the framework by manually opening workspaces in Antigravity GUI.
