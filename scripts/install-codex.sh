#!/bin/bash
# Install Codex runtime assets from the shared agents repository.
# Usage:
#   bash /path/to/agents/scripts/install-codex.sh [target_repo]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET_REPO="${1:-$PWD}"
SKILLS_DIR="$HOME/.codex/skills"
BIN_DIR="$HOME/.local/bin"
ALIAS_SNIPPET="$AGENTS_REPO_ROOT/scripts/codex-shell-aliases.sh"
SHELL_NAME="$(basename "${SHELL:-}")"
RUNTIME_TARGET_DIR="$TARGET_REPO/scripts"
RUNTIME_SCRIPTS=(
  codex-autocoder.sh
  codex-fix-loop.sh
  codex-manage-workers.sh
  codex-manage-workers-loop.sh
  codex-monitor-workers.sh
  codex-monitor-loop.sh
  codex-stop-loop.sh
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

echo "🔧 Codex installer"
echo "Agents repo:  $AGENTS_REPO_ROOT"
echo "Target repo:  $TARGET_REPO"
echo ""

echo "📍 Dependency check"
if command -v codex >/dev/null 2>&1; then
  echo "✅ codex installed"
else
  echo "⚠️  codex not found on PATH"
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
echo "📍 Installing Codex skills"
mkdir -p "$SKILLS_DIR"
ln -sfn "$AGENTS_REPO_ROOT/skills/autocoder" "$SKILLS_DIR/autocoder"
ln -sfn "$AGENTS_REPO_ROOT/skills/modernize" "$SKILLS_DIR/modernize"
echo "✅ Linked skills into $SKILLS_DIR"

echo ""
echo "📍 Installing parallel-agent commands"
mkdir -p "$BIN_DIR"
ln -sfn "$AGENTS_REPO_ROOT/plugins/autocoder/scripts/start-parallel-agents.sh" "$BIN_DIR/start-parallel"
ln -sfn "$AGENTS_REPO_ROOT/scripts/codex-start-parallel.sh" "$BIN_DIR/codex-start-parallel"
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
echo "✅ Linked Codex runtime wrappers into $RUNTIME_TARGET_DIR"

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
echo "  2. Restart Codex so it reloads skills"
echo "  3. cd $TARGET_REPO"
echo "  4. Run: startcc 3"
