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

# Optional: idle-sentinel cron install (OFF by default; opt-in only).
# The sentinel polls for work between waves at zero token cost and wakes an LLM
# manager only when its wake predicate fires — see
# docs/specs/2026-09-16-idle-sentinel-design.md (spend model: steady trickle
# load is cheaper on a warm monitor loop, so this is never installed silently).
# Non-interactive installs (curl | bash, no TTY) always skip this step.
SENTINEL="$TARGET_DIR/scripts/idle-sentinel.sh"
if [ -t 0 ] && [ -f "$SENTINEL" ]; then
    echo ""
    read -p "🕐 Install the idle-sentinel cron job (zero-spend monitoring between work waves)? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        mkdir -p .autocoder
        # Cron ticks run with a minimal environment; sentinel-env restores PATH
        # and AUTOCODER_* configuration. Never clobber an existing one.
        if [ ! -f .autocoder/sentinel-env ]; then
            cat > .autocoder/sentinel-env <<EOF
# Sourced by every idle-sentinel.sh tick (cron runs with a minimal environment).
# PATH must reach gh and your multiplexer (tmux/cmux/herdr).
export PATH="$PATH"
# Uncomment and set to override sentinel defaults:
# export AUTOCODER_SENTINEL_INTERVAL=15m
# export AUTOCODER_SENTINEL_DUTY_INTERVAL=6h
# export AUTOCODER_SENTINEL_ERROR_TOLERANCE=2
# export AUTOCODER_GH_USER=
# export AUTOCODER_MUX=
# export AUTOCODER_AGENT=
# export AUTOCODER_SESSION=
EOF
            echo "📝 Wrote .autocoder/sentinel-env (edit it to pin AUTOCODER_* settings)"
        else
            echo "📝 Keeping existing .autocoder/sentinel-env"
        fi
        # --ensure is idempotent: it inspects crontab, systemd user timers, and
        # running --loop processes, and installs a crontab entry running
        # `idle-sentinel.sh --once` at AUTOCODER_SENTINEL_INTERVAL (default 15m)
        # only when nothing is scheduled yet — it never double-installs.
        bash "$SENTINEL" --ensure || echo "⚠️  Sentinel scheduling failed — run 'bash $SENTINEL --ensure' manually."
    else
        echo "⏭️  Skipping idle sentinel (enable later with: bash $SENTINEL --ensure)"
    fi
fi

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
