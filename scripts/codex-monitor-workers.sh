#!/bin/bash
# Run the Codex worker monitor.
set -euo pipefail
# codex exec is headless and its default sandbox is read-only. workspace-write
# lets the monitor act, and --ask-for-approval never keeps it off an approval
# prompt. AUTOCODER_CODEX_FLAGS overrides it ("" defers to ~/.codex/config.toml).
# See codex-autocoder.sh (#286). Current codex rejects --full-auto.
read -r -a CODEX_FLAGS <<< "${AUTOCODER_CODEX_FLAGS---sandbox workspace-write --ask-for-approval never}"
codex exec ${CODEX_FLAGS[@]+"${CODEX_FLAGS[@]}"} "/monitor-workers"
