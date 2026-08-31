#!/bin/bash
# Start Droid monitor loop.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
echo "Starting Droid monitor loop"
echo "== Droid Worker Monitor =="
bash "$SCRIPT_DIR/droid-monitor-loop.sh" "$@"
