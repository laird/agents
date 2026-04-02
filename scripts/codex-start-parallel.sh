#!/bin/bash
# Start the shared parallel-agent launcher in Codex mode.

set -euo pipefail

usage() {
  echo "Usage: $0 [tmux|cmux] [num_agents] [extra start-parallel options]"
}

MUX_ARGS=()

if [ $# -gt 0 ]; then
  case "$1" in
    tmux|cmux)
      MUX_ARGS=(--mux "$1")
      shift
      ;;
    -h|--help|help)
      usage
      exit 0
      ;;
  esac
fi

SOURCE_PATH="${BASH_SOURCE[0]}"
while [ -L "$SOURCE_PATH" ]; do
  SOURCE_DIR="$(cd "$(dirname "$SOURCE_PATH")" && pwd)"
  SOURCE_PATH="$(readlink "$SOURCE_PATH")"
  [[ "$SOURCE_PATH" != /* ]] && SOURCE_PATH="$SOURCE_DIR/$SOURCE_PATH"
done

SCRIPT_DIR="$(cd "$(dirname "$SOURCE_PATH")" && pwd)"
exec bash "$SCRIPT_DIR/../plugins/autocoder/scripts/start-parallel-agents.sh" "${MUX_ARGS[@]}" --agent codex "$@"
