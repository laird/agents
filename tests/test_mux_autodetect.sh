#!/bin/bash
# Tests for multiplexer auto-detect liveness probing (issue #18).
#
# The bug: auto-detect chose cmux whenever the `cmux` binary was on $PATH.
# The cask keeps it there permanently, so a machine with cmux installed but not
# running selected cmux and then failed on every subsequent cmux call, even
# though a working tmux was available.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/plugins/autocoder/scripts/mux-send-lib.sh"

PLUGIN_SCRIPTS=(
  "$ROOT/plugins/autocoder/scripts/start-parallel-agents.sh"
  "$ROOT/plugins/autocoder/scripts/add-worker.sh"
  "$ROOT/plugins/autocoder/scripts/join-parallel-agents.sh"
)
AGENT_SCRIPTS=(
  "$ROOT/.agent/scripts/start-parallel-agents.sh"
  "$ROOT/.agent/scripts/join-parallel-agents.sh"
)

fail() { echo "FAIL: $1" >&2; exit 1; }

STUB_DIR=$(mktemp -d)
trap 'rm -rf "$STUB_DIR"' EXIT

# Build a stub `cmux` whose `tree` subcommand behaves per $CMUX_STUB_MODE.
make_cmux_stub() {
  cat > "$STUB_DIR/cmux" <<'STUB'
#!/bin/bash
case "$CMUX_STUB_MODE" in
  running) exit 0 ;;
  dead)    echo "cmux: could not connect to daemon" >&2; exit 1 ;;
  hang)    sleep 60; exit 0 ;;
esac
exit 0
STUB
  chmod +x "$STUB_DIR/cmux"
}

# ── 1. Every script is syntactically valid ───────────────────────────────────
for s in "${PLUGIN_SCRIPTS[@]}" "${AGENT_SCRIPTS[@]}" "$LIB"; do
  [ -f "$s" ] || fail "missing script: $s"
  bash -n "$s" || fail "syntax error in $s"
done

# ── 2. The lib exposes a liveness probe ──────────────────────────────────────
grep -q 'cmux_is_running()' "$LIB" || fail "mux-send-lib.sh does not define cmux_is_running"

# ── 3. Behavior of the probe against stub cmux ───────────────────────────────
# shellcheck source=/dev/null
source "$LIB"
make_cmux_stub

# 3a. cmux not installed at all -> probe must fail (and not error out)
PATH="/usr/bin:/bin:/usr/sbin:/sbin" bash -c "
  source '$LIB'
  cmux_is_running && exit 1 || exit 0
" || fail "probe should fail when cmux is not installed"

# 3b. cmux installed AND running -> probe succeeds
if ! CMUX_STUB_MODE=running PATH="$STUB_DIR:$PATH" bash -c "source '$LIB'; cmux_is_running"; then
  fail "probe should succeed when cmux is running"
fi

# 3c. cmux installed but NOT running -> probe fails (this is the bug)
if CMUX_STUB_MODE=dead PATH="$STUB_DIR:$PATH" bash -c "source '$LIB'; cmux_is_running"; then
  fail "probe should fail when cmux is installed but not running"
fi

# 3d. wedged cmux -> probe must time out, not hang the fleet start
START=$(date +%s)
if CMUX_STUB_MODE=hang AUTOCODER_CMUX_PROBE_SECONDS=2 PATH="$STUB_DIR:$PATH" \
   bash -c "source '$LIB'; cmux_is_running"; then
  fail "probe should fail when cmux hangs"
fi
ELAPSED=$(( $(date +%s) - START ))
[ "$ELAPSED" -lt 20 ] || fail "probe did not honor its timeout (took ${ELAPSED}s)"

# ── 4. Auto-detect uses the probe, not bare presence ─────────────────────────
# Each script's auto-detect block must gate on cmux_is_running. A bare
# `command -v cmux` deciding MUX is exactly the regression being fixed.
#
# The precise invariant: `MUX="cmux"` may only be reached through a
# cmux_is_running guard. A `command -v cmux` still appears legitimately in the
# fallback branch (to decide whether to print the notice), so presence of that
# string is not itself the regression — selecting cmux from it is.
for s in "${PLUGIN_SCRIPTS[@]}" "${AGENT_SCRIPTS[@]}"; do
  name=$(basename "$s")
  grep -q 'cmux_is_running' "$s" || fail "$name: auto-detect does not use cmux_is_running"
  python3 - "$s" "$name" <<'PY' || exit 1
import re, sys
path, name = sys.argv[1], sys.argv[2]
lines = open(path).read().splitlines()
for i, line in enumerate(lines):
    if re.search(r'MUX="cmux"', line):
        # Walk back to the nearest enclosing `if`/`elif` condition.
        guard = None
        for j in range(i, max(-1, i - 4), -1):
            if re.search(r'\b(if|elif)\b', lines[j]):
                guard = lines[j]
                break
        if guard is None or 'cmux_is_running' not in guard:
            print(f"FAIL: {name}: MUX=\"cmux\" set at line {i+1} without a "
                  f"cmux_is_running guard (guard was: {guard!r})", file=sys.stderr)
            sys.exit(1)
sys.exit(0)
PY
done

# ── 5. Fallback is announced, not silent ─────────────────────────────────────
for s in "${PLUGIN_SCRIPTS[@]}" "${AGENT_SCRIPTS[@]}"; do
  name=$(basename "$s")
  grep -qi 'cmux installed but not running' "$s" \
    || fail "$name: no notice emitted when falling back to tmux"
done

# ── 6. Explicit --mux cmux is still honored and fails loudly ─────────────────
# The fallback is auto-detect behavior ONLY. An explicit choice must not be
# silently rewritten, so validation still rejects on absence rather than
# switching multiplexers.
for s in "$ROOT/plugins/autocoder/scripts/start-parallel-agents.sh" \
         "$ROOT/.agent/scripts/start-parallel-agents.sh"; do
  name=$(basename "$s")
  grep -q 'Unknown multiplexer' "$s" || fail "$name: lost explicit --mux validation"
  sed -n '/Validate multiplexer choice/,/^esac$/p' "$s" | grep -q 'cmux_is_running' \
    && fail "$name: explicit --mux path must not silently fall back"
done

echo "ok mux-autodetect"
