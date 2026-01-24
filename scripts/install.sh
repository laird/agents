#!/bin/bash
# Install Antigravity agents into the current project
# Usage: curl -sSL https://raw.githubusercontent.com/laird/agents/main/scripts/install.sh | bash
#
# This script fetches only the .agent/ directory from the repository
# and copies it to your current working directory.

set -e

REPO_URL="https://github.com/laird/agents.git"
TEMP_DIR=$(mktemp -d)
TARGET_DIR=".agent"

echo "🚀 Installing Antigravity agents..."

# Check if .agent already exists
if [ -d "$TARGET_DIR" ]; then
    echo "⚠️  .agent/ directory already exists."
    read -p "Overwrite? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "❌ Installation cancelled."
        rm -rf "$TEMP_DIR"
        exit 1
    fi
    rm -rf "$TARGET_DIR"
fi

# Clone with sparse checkout (only .agent directory)
echo "📦 Fetching agents from repository..."
git clone --depth 1 --filter=blob:none --sparse "$REPO_URL" "$TEMP_DIR" 2>/dev/null
cd "$TEMP_DIR"
git sparse-checkout set .agent 2>/dev/null

# Copy to target
echo "📁 Installing to .agent/..."
cp -r .agent "$OLDPWD/"

# Cleanup
cd "$OLDPWD"
rm -rf "$TEMP_DIR"

echo "✅ Antigravity agents installed successfully!"
echo ""
echo "Available workflows:"
echo "  /assess            - Evaluate modernization viability"
echo "  /plan              - Create execution strategy"  
echo "  /modernize         - Execute multi-phase modernization"
echo "  /fix        - Autonomous issue resolution"
echo "  /retro             - Analyze project for improvements"
echo ""
echo "Run any workflow by typing its name in Antigravity."
