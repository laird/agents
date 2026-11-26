#!/bin/bash
# Start the Pi manager loop.
#
# The two banner lines are a contract, not decoration: a manager UI waits for
# them to confirm the manager pane actually started, and launch tests assert
# on them.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
echo "Starting Pi monitor loop"
echo "== Pi Worker Monitor =="
bash "$SCRIPT_DIR/pi-monitor-loop.sh" "$@"
