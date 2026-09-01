#!/bin/bash
# Run the Pi autocoder workflow repeatedly.
#
# A fresh `pi -p` process per pass is the point: each issue starts from an
# empty context rather than inheriting the previous issue's investigation, so a
# long-running worker cannot slowly fill its window and start truncating its
# own history. Same reason claude-worker-loop.sh exists.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SLEEP_SECONDS="${PI_LOOP_SLEEP:-900}"

echo "PI_FIX_LOOP_STARTED"
while true; do
  # Fail-soft: one bad pass (rate limit, transient tool error) must not end the
  # worker. The loop is the durable thing; a pass is not.
  bash "$SCRIPT_DIR/pi-autocoder.sh" fix || echo "⚠️  pi fix pass failed; retrying after ${SLEEP_SECONDS}s" >&2
  sleep "$SLEEP_SECONDS"
done
