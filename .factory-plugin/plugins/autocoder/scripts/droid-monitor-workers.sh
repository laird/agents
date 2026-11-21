#!/bin/bash
# Run the Droid worker monitor.
set -euo pipefail
# droid exec is headless and read-only by default; --auto high lets the monitor act
# (see droid-autocoder.sh, #286). AUTOCODER_DROID_FLAGS overrides it ("" for droid's default).
read -r -a DROID_FLAGS <<< "${AUTOCODER_DROID_FLAGS---auto high}"
droid exec ${DROID_FLAGS[@]+"${DROID_FLAGS[@]}"} "/monitor-workers"
