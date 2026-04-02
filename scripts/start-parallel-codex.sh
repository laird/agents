#!/bin/bash
# Backward-compatible Codex launcher that delegates to the shared parallel starter.

set -euo pipefail

usage() {
  echo "Usage: $0 [tmux|cmux] [num_agents] [extra start-parallel options]"
}

SOURCE_PATH="${BASH_SOURCE[0]}"
while [ -L "$SOURCE_PATH" ]; do
  SOURCE_DIR="$(cd "$(dirname "$SOURCE_PATH")" && pwd)"
  SOURCE_PATH="$(readlink "$SOURCE_PATH")"
  [[ "$SOURCE_PATH" != /* ]] && SOURCE_PATH="$SOURCE_DIR/$SOURCE_PATH"
done

SCRIPT_DIR="$(cd "$(dirname "$SOURCE_PATH")" && pwd)"

MUX_ARGS=(--mux tmux)
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
    [0-9]*)
      ;;
    *)
      echo "❌ Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
fi

if [ "${MUX_ARGS[1]-}" = "tmux" ]; then
  exec bash "$SCRIPT_DIR/codex-start-parallel.sh" "$@"
else
  exec bash "$SCRIPT_DIR/codex-start-parallel.sh" "${MUX_ARGS[1]}" "$@"
fi
