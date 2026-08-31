#!/bin/bash
# Probe whether Codex /goal is available in the current installation.
# Exit 0 = /goal available, exit 1 = not available.
# Caches result in /tmp/codex-goals-probe-<version> to avoid repeated invocations.

set -euo pipefail

if ! command -v codex &>/dev/null; then
  exit 1
fi

VERSION=$(codex --version 2>/dev/null | tr ' ' '-')
CACHE_FILE="/tmp/codex-goals-probe-${VERSION}"

if [ -f "$CACHE_FILE" ]; then
  exit "$(cat "$CACHE_FILE")"
fi

if codex features list 2>/dev/null | grep -E "^goals\s" | grep -q "true"; then
  echo -n "0" > "$CACHE_FILE"
  exit 0
else
  echo -n "1" > "$CACHE_FILE"
  exit 1
fi
