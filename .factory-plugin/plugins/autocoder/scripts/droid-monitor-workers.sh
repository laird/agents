#!/bin/bash
# Run the Droid worker monitor.
set -euo pipefail
droid exec --full-auto "/monitor-workers"
