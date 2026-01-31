#!/bin/bash
# watchdog-fix-github.sh
# Ensures the /fix-github workflow runs continuously.
# Usage: ./watchdog-fix-github.sh [agent_command]

# Default agent command - change this if your binary is named differently (e.g., 'cortex', 'claude')
AGENT_CMD=${1:-"antigravity"}
WORKFLOW="/fix-github"

TARGET_DIR="/home/laird/src/librarian"

echo "=================================================="
echo "   Antigravity Watchdog: $WORKFLOW"
echo "   Agent Command: $AGENT_CMD"
echo "   Target Dir: $TARGET_DIR"
echo "=================================================="

# Check if command exists
if ! command -v "$AGENT_CMD" &> /dev/null; then
    echo "Error: Command '$AGENT_CMD' not found in PATH."
    echo "Usage: $0 <path_to_agent_binary>"
    exit 1
fi

while true; do
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Ensuring workspace is open..."
    "$AGENT_CMD" "$TARGET_DIR"
    sleep 5

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting workflow $WORKFLOW..."
    
    # Run the agent with the workflow command
    # Use stdin pipe as it reliably triggers the chat processing
    pushd "$TARGET_DIR" > /dev/null
    echo "$WORKFLOW" | "$AGENT_CMD" chat --reuse-window -
    popd > /dev/null
    
    EXIT_CODE=$?
    
    if [ $EXIT_CODE -ne 0 ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠️  Workflow exited with error (Code: $EXIT_CODE)"
        echo "Restarting in 10 seconds..."
        sleep 10
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✅ Workflow cycle complete."
        echo "Sleeping for 60 seconds before next cycle..."
        sleep 60
    fi
done
