#!/bin/bash
# Run the Droid autocoder workflow repeatedly.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
while true; do
  bash "$SCRIPT_DIR/droid-autocoder.sh" fix
  sleep 900
done
