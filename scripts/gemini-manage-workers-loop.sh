#!/bin/bash
# Start Gemini monitor loop.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
echo "Starting Gemini monitor loop"
echo "MANAGER_LOOP_STARTED"
bash "$SCRIPT_DIR/gemini-monitor-loop.sh" "$@"
