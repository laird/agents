#!/bin/bash
# Install Droid runtime assets from the shared agents repository.
# Usage:
#   bash /path/to/agents/scripts/install-droid.sh [target_repo]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET_REPO="${1:-$PWD}"
BIN_DIR="$HOME/.local/bin"
ALIAS_SNIPPET="$AGENTS_REPO_ROOT/scripts/droid-shell-aliases.sh"
SHELL_NAME="$(basename "${SHELL:-}")"
RUNTIME_TARGET_DIR="$TARGET_REPO/scripts"
RUNTIME_SCRIPTS=(
  droid-autocoder.sh
  droid-fix-loop.sh
  droid-manage-workers.sh
  droid-manage-workers-loop.sh
  droid-monitor-workers.sh
  droid-monitor-loop.sh
  droid-stop-loop.sh
)

if [ ! -d "$TARGET_REPO" ]; then
  echo "❌ Target repo does not exist: $TARGET_REPO" >&2
  exit 1
fi

case "$SHELL_NAME" in
  zsh)
    SHELL_RC="$HOME/.zshrc"
    ;;
  bash)
    SHELL_RC="$HOME/.bashrc"
    ;;
  *)
    SHELL_RC="$HOME/.profile"
    ;;
esac

echo "🔧 Droid installer"
echo "Agents repo:  $AGENTS_REPO_ROOT"
echo "Target repo:  $TARGET_REPO"
echo ""

echo "📍 Dependency check"
if command -v droid >/dev/null 2>&1; then
  echo "✅ droid installed"
else
  echo "⚠️  droid not found on PATH"
fi

if command -v gh >/dev/null 2>&1; then
  echo "✅ gh installed"
else
  echo "⚠️  gh not found on PATH"
fi

if command -v tmux >/dev/null 2>&1; then
  echo "✅ tmux installed"
else
  echo "⚠️  tmux not found on PATH"
fi

if command -v cmux >/dev/null 2>&1; then
  echo "✅ cmux installed"
else
  echo "⚠️  cmux not found on PATH"
fi

echo ""
echo "📍 Installing Droid plugin (skills, droids, commands)"

FACTORY_DIR="$TARGET_REPO/.factory"
mkdir -p "$FACTORY_DIR"

# Link skills
if [ -d "$AGENTS_REPO_ROOT/.factory/skills" ]; then
  mkdir -p "$FACTORY_DIR/skills"
  for skill_dir in "$AGENTS_REPO_ROOT/.factory/skills"/*/; do
    skill_name=$(basename "$skill_dir")
    ln -sfn "$skill_dir" "$FACTORY_DIR/skills/$skill_name"
  done
  echo "✅ Linked skills into $FACTORY_DIR/skills/"
fi

# Link droids
if [ -d "$AGENTS_REPO_ROOT/.factory/droids" ]; then
  mkdir -p "$FACTORY_DIR/droids"
  for droid_file in "$AGENTS_REPO_ROOT/.factory/droids"/*.md; do
    ln -sfn "$droid_file" "$FACTORY_DIR/droids/$(basename "$droid_file")"
  done
  echo "✅ Linked droids into $FACTORY_DIR/droids/"
fi

# Link commands (from plugins)
mkdir -p "$FACTORY_DIR/commands"
for cmd_file in "$AGENTS_REPO_ROOT/plugins/autocoder/commands"/*.md; do
  ln -sfn "$cmd_file" "$FACTORY_DIR/commands/$(basename "$cmd_file")"
done
for cmd_file in "$AGENTS_REPO_ROOT/plugins/modernize/commands"/*.md; do
  ln -sfn "$cmd_file" "$FACTORY_DIR/commands/$(basename "$cmd_file")"
done
echo "✅ Linked commands into $FACTORY_DIR/commands/"

echo ""
echo "📍 Installing parallel-agent commands"
mkdir -p "$BIN_DIR"
ln -sfn "$AGENTS_REPO_ROOT/plugins/autocoder/scripts/start-parallel-agents.sh" "$BIN_DIR/start-parallel"
ln -sfn "$AGENTS_REPO_ROOT/scripts/droid-start-parallel.sh" "$BIN_DIR/droid-start-parallel"
ln -sfn "$AGENTS_REPO_ROOT/plugins/autocoder/scripts/join-parallel-agents.sh" "$BIN_DIR/join-parallel"
ln -sfn "$AGENTS_REPO_ROOT/plugins/autocoder/scripts/end-parallel-agents.sh" "$BIN_DIR/end-parallel"
ln -sfn "$AGENTS_REPO_ROOT/plugins/autocoder/scripts/stop-parallel-agents.sh" "$BIN_DIR/stop-parallel"
echo "✅ Linked parallel-agent commands into $BIN_DIR"

if [[ ":$PATH:" == *":$BIN_DIR:"* ]]; then
  echo "✅ $BIN_DIR already on PATH"
else
  echo "⚠️  $BIN_DIR is not on PATH in this shell"
fi

echo ""
echo "📍 Installing repo-local runtime wrappers"
mkdir -p "$RUNTIME_TARGET_DIR"
for script_name in "${RUNTIME_SCRIPTS[@]}"; do
  ln -sfn "$AGENTS_REPO_ROOT/scripts/$script_name" "$RUNTIME_TARGET_DIR/$script_name"
done
echo "✅ Linked Droid runtime wrappers into $RUNTIME_TARGET_DIR"

echo ""
echo "📍 Installing shell aliases"
mkdir -p "$(dirname "$SHELL_RC")"
SOURCE_LINE="source $ALIAS_SNIPPET"
if [ -f "$SHELL_RC" ] && grep -Fqx "$SOURCE_LINE" "$SHELL_RC"; then
  echo "✅ Alias source already present in $SHELL_RC"
else
  printf '\n%s\n' "$SOURCE_LINE" >> "$SHELL_RC"
  echo "✅ Added alias source to $SHELL_RC"
fi

echo ""
echo "📍 Target repo guidance"
if [ -f "$TARGET_REPO/AGENTS.md" ]; then
  echo "✅ Found AGENTS.md in target repo"
else
  echo "⚠️  No AGENTS.md found in target repo"
fi

echo ""
echo "Next steps:"
echo "  1. Restart your shell or run: source $SHELL_RC"
echo "  2. cd $TARGET_REPO"
echo "  3. Run: droid    (interactive mode)"
echo "  4. Use /fix, /assess, /plan, etc. as slash commands"
echo "  5. For parallel workers: startdt 3  (tmux) or startdc 3  (cmux)"
