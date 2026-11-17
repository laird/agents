#!/bin/bash
# Install parallel-agent shell aliases for all platforms.
# Adds source lines to ~/.zshrc or ~/.bashrc for each selected platform.
#
# Usage:
#   bash /path/to/agents/scripts/install-shell-aliases.sh [--all] [--claude] [--codex] [--gemini] [--droid]
#
# With no flags, installs aliases for all detected agent CLIs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SHELL_NAME="$(basename "${SHELL:-}")"
case "$SHELL_NAME" in
  zsh)  SHELL_RC="$HOME/.zshrc" ;;
  bash) SHELL_RC="$HOME/.bashrc" ;;
  *)    SHELL_RC="$HOME/.profile" ;;
esac

# Parse flags
INSTALL_CLAUDE=false
INSTALL_CODEX=false
INSTALL_GEMINI=false
INSTALL_DROID=false
EXPLICIT=false

for arg in "$@"; do
  case "$arg" in
    --all)    INSTALL_CLAUDE=true; INSTALL_CODEX=true; INSTALL_GEMINI=true; INSTALL_DROID=true; EXPLICIT=true ;;
    --claude) INSTALL_CLAUDE=true; EXPLICIT=true ;;
    --codex)  INSTALL_CODEX=true;  EXPLICIT=true ;;
    --gemini) INSTALL_GEMINI=true; EXPLICIT=true ;;
    --droid)  INSTALL_DROID=true;  EXPLICIT=true ;;
    *) echo "Unknown flag: $arg" >&2; exit 1 ;;
  esac
done

# Auto-detect if no flags given
if [ "$EXPLICIT" = false ]; then
  command -v claude  &>/dev/null && INSTALL_CLAUDE=true
  command -v codex   &>/dev/null && INSTALL_CODEX=true
  command -v gemini  &>/dev/null && INSTALL_GEMINI=true
  command -v droid   &>/dev/null && INSTALL_DROID=true
fi

add_source_line() {
  local alias_file="$1"
  local label="$2"
  local source_line="source $alias_file"
  if grep -Fqx "$source_line" "$SHELL_RC" 2>/dev/null; then
    echo "✅ $label aliases already in $SHELL_RC"
  else
    printf '\n%s\n' "$source_line" >> "$SHELL_RC"
    echo "✅ Added $label aliases to $SHELL_RC"
  fi
}

echo "🔧 Installing parallel-agent shell aliases"
echo "   Shell config: $SHELL_RC"
echo ""

installed=0

if [ "$INSTALL_CLAUDE" = true ]; then
  add_source_line "$SCRIPT_DIR/claude-shell-aliases.sh" "Claude (startclt/startclc)"
  installed=$((installed + 1))
fi

if [ "$INSTALL_CODEX" = true ]; then
  add_source_line "$SCRIPT_DIR/codex-shell-aliases.sh" "Codex (startct/startcc)"
  installed=$((installed + 1))
fi

if [ "$INSTALL_GEMINI" = true ]; then
  add_source_line "$SCRIPT_DIR/gemini-shell-aliases.sh" "Gemini (startgt/startgc)"
  installed=$((installed + 1))
fi

if [ "$INSTALL_DROID" = true ]; then
  add_source_line "$SCRIPT_DIR/droid-shell-aliases.sh" "Droid (startdt/startdc)"
  installed=$((installed + 1))
fi

if [ "$installed" -eq 0 ]; then
  echo "⚠️  No agent CLIs detected and no flags specified."
  echo "   Install claude, codex, gemini, or droid — or use --all to install all aliases."
  exit 1
fi

echo ""
echo "✅ Done. Reload your shell:"
echo "   source $SHELL_RC"
echo ""
echo "Available aliases:"
echo "   startclt / startclc  — Claude Code (tmux / cmux)"
echo "   startct  / startcc   — Codex      (tmux / cmux)"
echo "   startgt  / startgc   — Gemini     (tmux / cmux)"
echo "   startdt  / startdc   — Droid      (tmux / cmux)"
