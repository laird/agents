#!/bin/bash
set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/plugins/autocoder/scripts/start-parallel-agents.sh"
HELP=$("$SCRIPT" --help)

for expected in "--paused" "--no-start" "--issue-source file|github" "--issue-dir PATH" "start-parallel-agents.sh 5 --mux tmux --agent codex --issue-source github --paused"; do
  if ! grep -Fq -- "$expected" <<<"$HELP"; then
    echo "FAIL: help missing '$expected'" >&2
    exit 1
  fi
done

ADD_WORKER="$(cd "$(dirname "$0")/.." && pwd)/plugins/autocoder/scripts/add-worker.sh"
ADD_HELP=$("$ADD_WORKER" --help)
grep -Fq "Usage: add-worker.sh [count]" <<<"$ADD_HELP"

REMOVE_WORKER="$(cd "$(dirname "$0")/.." && pwd)/plugins/autocoder/scripts/remove-worker.sh"
REMOVE_HELP=$("$REMOVE_WORKER" --help)
grep -Fq "Usage: remove-worker WORKER_NUMBER" <<<"$REMOVE_HELP"

echo "ok start-parallel help"
