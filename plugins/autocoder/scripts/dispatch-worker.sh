#!/bin/bash
# Dispatch one issue to a worker and submit it in a single, tested operation.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/mux-send-lib.sh"

MUX="tmux"
AGENT="claude"
TARGET=""
ISSUE_NUM=""

while [ $# -gt 0 ]; do
  case "$1" in
    --mux) MUX="$2"; shift 2 ;;
    --agent) AGENT="$2"; shift 2 ;;
    --target) TARGET="$2"; shift 2 ;;
    --issue) ISSUE_NUM="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: dispatch-worker.sh --target TARGET --issue N [--mux tmux|cmux] [--agent claude|gemini|codex|droid]"
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$TARGET" ] || ! [[ "$ISSUE_NUM" =~ ^[0-9]+$ ]]; then
  echo "--target and a numeric --issue are required" >&2
  exit 2
fi

case "$AGENT" in
  codex) COMMAND="bash scripts/codex-autocoder.sh fix $ISSUE_NUM" ;;
  gemini) COMMAND="/fix $ISSUE_NUM" ;;
  claude|droid) COMMAND="/autocoder:fix $ISSUE_NUM" ;;
  *) echo "Unsupported agent: $AGENT" >&2; exit 2 ;;
esac

case "$MUX" in
  tmux) send_tmux_text_enter "$TARGET" "$COMMAND" ;;
  cmux) send_cmux_command "$TARGET" "$COMMAND" ;;
  *) echo "Unsupported mux: $MUX" >&2; exit 2 ;;
esac
