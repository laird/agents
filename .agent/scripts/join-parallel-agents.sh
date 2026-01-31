#!/bin/bash
# Join an existing parallel agent workspace configuration
# Usage: join-parallel-agents.sh

# Check if parallel workspace config exists
CONFIG_FILE=".agent/parallel-workspaces.json"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "❌ No parallel agent configuration found"
  echo ""
  echo "   Expected config file: $CONFIG_FILE"
  echo ""
  echo "💡 To start a new parallel agent system:"
  echo "   start-parallel-agents.sh [num_agents]"
  echo ""
  exit 1
fi

# Read configuration
PROJECT_ROOT=$(pwd)
SESSION_ID=$(python3 -c "import json,sys; print(json.load(open('$CONFIG_FILE'))['session_id'])" 2>/dev/null || echo "unknown")
INTEGRATION_BRANCH=$(python3 -c "import json,sys; print(json.load(open('$CONFIG_FILE'))['integration_branch'])" 2>/dev/null || echo "unknown")
NUM_WORKSPACES=$(python3 -c "import json,sys; print(len(json.load(open('$CONFIG_FILE'))['workspaces']))" 2>/dev/null || echo "0")

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📋 Parallel Agent Configuration Found"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📌 Configuration Details:"
echo "   Session ID: $SESSION_ID"
echo "   Integration Branch: $INTEGRATION_BRANCH"
echo "   Workspaces: $NUM_WORKSPACES"
echo "   Config File: $CONFIG_FILE"
echo ""

# List workspaces
echo "📁 Configured Workspaces:"
echo ""

python3 << 'EOF'
import json
import os

with open('.agent/parallel-workspaces.json', 'r') as f:
    config = json.load(f)

for ws in config['workspaces']:
    role_emoji = {
        'coordinator': '🎯',
        'worker': '🔧',
        'review': '📋'
    }.get(ws['role'], '❓')

    print(f"   {role_emoji} {ws['id'].upper()}")
    print(f"   • Path: {ws['path']}")
    print(f"   • Branch: {ws['branch']}")
    print(f"   • Command: {ws['command']}")

    # Check if path exists
    if os.path.exists(ws['path']):
        print(f"   • Status: ✓ Path exists")
    else:
        print(f"   • Status: ⚠️  Path not found")

    print()
EOF

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Try to launch Antigravity
echo "🚀 Attempting to launch Antigravity workspaces..."
echo ""

LAUNCHED=false

# Try different methods to launch Antigravity
if command -v antigravity &> /dev/null; then
  echo "   Found 'antigravity' command, attempting to open workspaces..."

  # Read workspaces and try to open them
  python3 << 'EOF'
import json
import subprocess

with open('.agent/parallel-workspaces.json', 'r') as f:
    config = json.load(f)

for ws in config['workspaces']:
    try:
        subprocess.run(['antigravity', 'workspace', 'open', ws['path']],
                       check=True, capture_output=True, timeout=5)
        print(f"   ✓ Opened workspace: {ws['id']}")
    except:
        pass
EOF

  LAUNCHED=true

elif [[ "$OSTYPE" == "darwin"* ]]; then
  # macOS: try to open Antigravity app
  if [ -d "/Applications/Antigravity.app" ]; then
    echo "   Found Antigravity.app, launching..."
    open -a "Antigravity" "$PROJECT_ROOT" 2>/dev/null && LAUNCHED=true
  fi
fi

echo ""

if [ "$LAUNCHED" = true ]; then
  echo "✅ Antigravity launched with workspaces"
else
  echo "⚠️  Could not auto-launch Antigravity"
  echo ""
  echo "💡 Manual Steps:"
  echo "   1. Launch Antigravity manually"
  echo "   2. Open the workspaces listed above"
  echo "   3. In each workspace, run the specified command"
fi

echo ""
echo "🔄 Agent Coordination:"
echo "   Agents coordinate through GitHub issues and labels:"
echo "   • 'working' label - Agent currently working on issue"
echo "   • 'needs-approval', 'needs-design', etc. - Blocking labels"
echo "   • P0-P3 labels - Priority levels"
echo ""
