#!/bin/bash
# Run the Codex worker monitor.
set -euo pipefail
codex exec --full-auto "/monitor-workers"
