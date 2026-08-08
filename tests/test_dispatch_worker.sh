#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

cat > "$TMP/bin/tmux" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$DISPATCH_TEST_LOG"
SH
chmod +x "$TMP/bin/tmux"

DISPATCH_TEST_LOG="$TMP/tmux.log" AUTOCODER_TMUX_SUBMIT_DELAY_SECONDS=0 PATH="$TMP/bin:$PATH" \
  bash "$ROOT/plugins/autocoder/scripts/dispatch-worker.sh" \
    --mux tmux --agent codex --target codex-project:0.2 --issue 42

mapfile -t CALLS < "$TMP/tmux.log"
EXPECTED_TEXT="send-keys -t codex-project:0.2 -l -- bash scripts/codex-autocoder.sh fix 42"
EXPECTED_ENTER="send-keys -t codex-project:0.2 C-m"
if [ "${#CALLS[@]}" -ne 2 ] || [ "${CALLS[0]}" != "$EXPECTED_TEXT" ] || [ "${CALLS[1]}" != "$EXPECTED_ENTER" ]; then
  echo "FAIL: expected separate text and C-m calls, got '${CALLS[*]}'" >&2
  exit 1
fi

echo "ok dispatch-worker"
