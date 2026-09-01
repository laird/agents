#!/bin/bash
# Run the Pi manager monitor pass repeatedly.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SLEEP_SECONDS="${PI_MONITOR_SLEEP:-300}"

while true; do
  bash "$SCRIPT_DIR/pi-monitor-workers.sh" || echo "⚠️  pi monitor pass failed; retrying after ${SLEEP_SECONDS}s" >&2
  sleep "$SLEEP_SECONDS"
done
