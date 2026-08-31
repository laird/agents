#!/bin/bash
# Run the Codex worker monitor on a recurring interval.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

usage() {
  echo "Usage: $0 [interval_minutes]"
}

INTERVAL_MINUTES="${1:-15}"

if [ "$INTERVAL_MINUTES" = "-h" ] || [ "$INTERVAL_MINUTES" = "--help" ]; then
  usage
  exit 0
fi

if ! [[ "$INTERVAL_MINUTES" =~ ^[0-9]+$ ]]; then
  echo "❌ Interval must be an integer number of minutes" >&2
  exit 1
fi

if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
  echo "❌ Must be run inside a git repository" >&2
  exit 1
fi

REPO_ROOT=$(git rev-parse --show-toplevel)
STATE_DIR="$REPO_ROOT/.codex/loops"
STOP_FILE="$STATE_DIR/monitor-loop.stop"
mkdir -p "$STATE_DIR"
rm -f "$STOP_FILE"

echo "🔄 Starting Codex monitor loop"
echo "   Interval: ${INTERVAL_MINUTES}m"
echo "   Stop file: $STOP_FILE"
echo ""

while true; do
  if [ -f "$STOP_FILE" ]; then
    echo "🛑 Stop file detected, ending Codex monitor loop"
    break
  fi
  bash "$SCRIPT_DIR/codex-monitor-workers.sh"
  sleep "$((INTERVAL_MINUTES * 60))"
done

echo "✅ Codex monitor loop stopped"
