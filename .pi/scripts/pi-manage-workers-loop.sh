#!/bin/bash
# Start the Pi manager loop.
#
# The two banner lines are a contract, not decoration: agents-tui waits for
# them to confirm the manager pane actually started, and its launch test
# asserts on them (see adapter/claude.rs).
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
echo "Starting Pi monitor loop"
echo "== Pi Worker Monitor =="
bash "$SCRIPT_DIR/pi-monitor-loop.sh" "$@"
