#!/bin/bash
# Start Codex monitor loop.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
echo "Starting Codex monitor loop"
echo "== Codex Worker Monitor =="
bash "$SCRIPT_DIR/codex-monitor-loop.sh" "$@"
