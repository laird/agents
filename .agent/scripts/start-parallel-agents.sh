#!/bin/bash
# Start parallel Antigravity agents using git worktrees and workspace configuration
# Usage: start-parallel-agents.sh [num_agents] [--no-worktrees]

set -e

# Parse arguments
NUM_AGENTS="${1:-3}"
USE_WORKTREES=true

for arg in "$@"; do
  case $arg in
    --no-worktrees)
      USE_WORKTREES=false
      shift
      ;;
    [0-9]*)
      NUM_AGENTS="$arg"
      shift
      ;;
  esac
done

# Validate we're in a git repo (if using worktrees)
if [ "$USE_WORKTREES" = true ]; then
  if ! git rev-parse --git-dir > /dev/null 2>&1; then
    echo "❌ Error: Not in a git repository" >&2
    echo "   Use --no-worktrees flag to run without git worktrees" >&2
    exit 1
  fi
fi

# Get project info
PROJECT_ROOT=$(pwd)
PROJECT_NAME=$(basename "$PROJECT_ROOT")
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
SESSION_ID="parallel-$(date +%Y%m%d-%H%M%S)"

echo "🚀 Starting parallel agent system"
echo "   Project: $PROJECT_NAME"
echo "   Main path: $PROJECT_ROOT"
echo "   Num agents: $NUM_AGENTS"
echo "   Session ID: $SESSION_ID"
echo "   Branch: $CURRENT_BRANCH"
echo ""

# Create worktrees if needed
WORKTREE_PATHS=()

if [ "$USE_WORKTREES" = true ]; then
  echo "📁 Setting up git worktrees..."

  for i in $(seq 1 $((NUM_AGENTS - 1))); do
    WORKTREE_PATH="${PROJECT_ROOT}-wt-${i}"
    WORKTREE_BRANCH="${CURRENT_BRANCH}-wt-${i}"

    if [ -d "$WORKTREE_PATH" ]; then
      echo "   ✓ Worktree already exists: $WORKTREE_PATH"
    else
      echo "   Creating worktree: $WORKTREE_PATH"

      # Create branch if it doesn't exist
      if ! git show-ref --verify --quiet "refs/heads/$WORKTREE_BRANCH"; then
        git branch "$WORKTREE_BRANCH" "$CURRENT_BRANCH"
      fi

      git worktree add "$WORKTREE_PATH" "$WORKTREE_BRANCH"
    fi

    WORKTREE_PATHS+=("$WORKTREE_PATH")
  done
  echo ""

  # Check if .agent is a symlink in main repo, replicate in worktrees
  if [ -L "$PROJECT_ROOT/.agent" ]; then
    AGENT_TARGET=$(readlink "$PROJECT_ROOT/.agent")
    echo "📁 Detected .agent/ symlink, replicating to worktrees..."

    for i in $(seq 1 $((NUM_AGENTS - 1))); do
      WORKTREE_PATH="${WORKTREE_PATHS[$((i-1))]}"

      if [ ! -L "$WORKTREE_PATH/.agent" ]; then
        ln -s "$AGENT_TARGET" "$WORKTREE_PATH/.agent"
        echo "   ✓ Created symlink in worktree $i: .agent -> $AGENT_TARGET"
      else
        echo "   ✓ Symlink already exists in worktree $i"
      fi
    done
    echo ""
  elif [ ! -d "$PROJECT_ROOT/.agent" ]; then
    echo "⚠️  Warning: .agent/ directory not found in project root"
    echo "   Run /install to set up the agents framework first"
    echo ""
  fi
fi

# Generate workspace configuration
CONFIG_FILE=".agent/parallel-workspaces.json"
echo "📝 Generating workspace configuration..."

# Build JSON configuration
cat > "$CONFIG_FILE" << EOF
{
  "session_id": "$SESSION_ID",
  "integration_branch": "$CURRENT_BRANCH",
  "created": "$(date -Iseconds)",
  "workspaces": [
    {
      "id": "coordinator",
      "role": "coordinator",
      "path": "$PROJECT_ROOT",
      "branch": "$CURRENT_BRANCH",
      "command": "/fix-loop"
    }
EOF

# Add worker workspaces
for i in $(seq 1 $((NUM_AGENTS - 1))); do
  if [ "$USE_WORKTREES" = true ]; then
    WORKSPACE_PATH="${WORKTREE_PATHS[$((i-1))]}"
    WORKSPACE_BRANCH="${CURRENT_BRANCH}-wt-${i}"
  else
    WORKSPACE_PATH="$PROJECT_ROOT"
    WORKSPACE_BRANCH="$CURRENT_BRANCH"
  fi

  # Add comma if not the last item
  echo "," >> "$CONFIG_FILE"

  cat >> "$CONFIG_FILE" << EOF
    {
      "id": "worker-$i",
      "role": "worker",
      "path": "$WORKSPACE_PATH",
      "branch": "$WORKSPACE_BRANCH",
      "command": "/fix-loop"
    }
EOF
done

# Add review workspace
cat >> "$CONFIG_FILE" << EOF
,
    {
      "id": "review",
      "role": "review",
      "path": "$PROJECT_ROOT",
      "branch": "$CURRENT_BRANCH",
      "command": "/review-blocked"
    }
  ]
}
EOF

echo "   ✓ Configuration saved to: $CONFIG_FILE"
echo ""

# Try to launch Antigravity
echo "🚀 Attempting to launch Antigravity..."
echo ""

LAUNCHED=false

# Try different methods to launch Antigravity
if command -v antigravity &> /dev/null; then
  echo "   Found 'antigravity' command, attempting to launch..."

  # Try to open each workspace
  if antigravity workspace open "$PROJECT_ROOT" &> /dev/null; then
    echo "   ✓ Opened coordinator workspace: $PROJECT_ROOT"
    LAUNCHED=true

    # Open worker workspaces
    if [ "$USE_WORKTREES" = true ]; then
      for i in $(seq 1 $((NUM_AGENTS - 1))); do
        WORKSPACE_PATH="${WORKTREE_PATHS[$((i-1))]}"
        if antigravity workspace open "$WORKSPACE_PATH" &> /dev/null; then
          echo "   ✓ Opened worker workspace $i: $WORKSPACE_PATH"
        fi
      done
    fi
  else
    # Try just launching Antigravity without specific workspaces
    if antigravity &> /dev/null & then
      echo "   ✓ Launched Antigravity (workspaces may need manual opening)"
      LAUNCHED=true
    fi
  fi
elif [[ "$OSTYPE" == "darwin"* ]]; then
  # macOS: try to open Antigravity app
  if [ -d "/Applications/Antigravity.app" ]; then
    echo "   Found Antigravity.app, launching..."
    open -a "Antigravity" "$PROJECT_ROOT" 2>/dev/null && LAUNCHED=true
  fi
fi

echo ""

# Print appropriate instructions based on whether we launched
if [ "$LAUNCHED" = true ]; then
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "✅ Antigravity launched!"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "📋 Workspaces to configure in Antigravity:"
  echo ""
else
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "✅ Parallel agent system configured!"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "⚠️  Could not auto-launch Antigravity"
  echo ""
  echo "📋 Manual Steps - Open Workspaces in Antigravity GUI:"
  echo ""
  echo "1. Launch Antigravity manually"
  echo ""
  echo "2. Add these workspaces:"
  echo ""
fi

# Print workspace details
echo "   Coordinator Agent (main repo):"
echo "   • Path: $PROJECT_ROOT"
echo "   • Branch: $CURRENT_BRANCH"
echo "   • Command: /fix-loop"
echo ""

if [ "$USE_WORKTREES" = true ]; then
  for i in $(seq 1 $((NUM_AGENTS - 1))); do
    WORKSPACE_PATH="${WORKTREE_PATHS[$((i-1))]}"
    WORKSPACE_BRANCH="${CURRENT_BRANCH}-wt-${i}"
    echo "   Worker Agent $i:"
    echo "   • Path: $WORKSPACE_PATH"
    echo "   • Branch: $WORKSPACE_BRANCH"
    echo "   • Command: /fix-loop"
    echo ""
  done
fi

echo "   Review Agent (main repo):"
echo "   • Path: $PROJECT_ROOT"
echo "   • Branch: $CURRENT_BRANCH"
echo "   • Command: /review-blocked"
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📌 Configuration Details:"
echo "   Session ID: $SESSION_ID"
echo "   Integration Branch: $CURRENT_BRANCH"
echo "   Config File: $CONFIG_FILE"
echo ""
echo "🔄 Agent Coordination:"
echo "   Agents coordinate through GitHub issues and labels:"
echo "   • 'working' label - Agent currently working on issue"
echo "   • 'needs-approval', 'needs-design', etc. - Blocking labels"
echo "   • P0-P3 labels - Priority levels"
echo ""
echo "💡 Each agent works independently on different issues."
echo "   Git worktrees provide isolation for parallel work."
echo ""
