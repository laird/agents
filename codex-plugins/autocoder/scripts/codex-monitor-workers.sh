#!/bin/bash
# Run the Codex worker monitor.
set -euo pipefail
# codex exec is headless and its default sandbox is read-only; workspace-write lets
# the monitor act, still sandboxed. AUTOCODER_CODEX_FLAGS overrides it ("" defers to
# ~/.codex/config.toml). See codex-autocoder.sh (#286).
read -r -a CODEX_FLAGS <<< "${AUTOCODER_CODEX_FLAGS---sandbox workspace-write}"
codex exec ${CODEX_FLAGS[@]+"${CODEX_FLAGS[@]}"} "/monitor-workers"
