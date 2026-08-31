#!/bin/bash
# Run the Droid worker monitor on a recurring interval.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
INTERVAL_MINUTES="${1:-15}"
while true; do
  bash "$SCRIPT_DIR/droid-monitor-workers.sh"
  sleep "$((INTERVAL_MINUTES * 60))"
done
