#!/bin/bash
# watchdog-fix.sh
# Ensures the /fix workflow runs continuously.
# Usage: ./watchdog-fix.sh [agent_command] [--once]

# Defaults
AGENT_CMD="antigravity"
WORKFLOW="/fix"
TARGET_DIR="/home/laird/src/agents"
RUN_ONCE=false
ITERATION=0
STATE_FILE="${TARGET_DIR}/.claude/fix-loop.local.md"

# Simple argument parsing
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --once) RUN_ONCE=true ;;
        -*) echo "Unknown option: $1"; exit 1 ;;
        *) AGENT_CMD="$1" ;;
    esac
    shift
done

echo "=================================================="
echo "   Antigravity Watchdog: $WORKFLOW"
echo "   Agent Command: $AGENT_CMD"
echo "   Target Dir: $TARGET_DIR"
echo "   Single Run: $RUN_ONCE"
echo "=================================================="

# Check if command exists
if ! command -v "$AGENT_CMD" &> /dev/null; then
    echo "Error: Command '$AGENT_CMD' not found in PATH."
    echo "Usage: $0 [--once] [agent_command]"
    exit 1
fi

while true; do
    ITERATION=$((ITERATION + 1))
    START_TIME=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${START_TIME}] --- Starting Iteration ${ITERATION} ---"
    
    # Update state file if it exists
    if [ -f "$STATE_FILE" ]; then
        sed -i "s/^iteration: .*/iteration: ${ITERATION}/" "$STATE_FILE"
        sed -i "s/^started: .*/started: $(date -Iseconds)/" "$STATE_FILE"
    fi

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
    END_TIME=$(date '+%Y-%m-%d %H:%M:%S')
    
    if [ $EXIT_CODE -ne 0 ]; then
        echo "[${END_TIME}] ⚠️  Iteration ${ITERATION} exited with error (Code: $EXIT_CODE)"
        echo "Restarting in 10 seconds..."
        sleep 10
    else
        echo "[${END_TIME}] ✅ Iteration ${ITERATION} complete."
    fi

    if [ "$RUN_ONCE" = true ]; then
        echo "[${END_TIME}] ✅ Single run complete. Exiting."
        exit 0
    fi

    echo "Sleeping for 60 seconds before next cycle..."
    sleep 60
done
