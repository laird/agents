#!/usr/bin/env bash
# install-statusline.sh — give every worker (and the manager) a status line
# showing context / memory / model / worktree / branch.
#
#   ctx 47% of 1M | mem 12 | Sonnet 5 | wt athena2-wt-3 | branch feature/issue-264
#
# Why this is installed rather than typed: workers relaunch Claude once per
# issue (claude-worker-loop.sh), so a `/statusline` typed into a pane is gone at
# the next restart. Settings persist; the command does not. Installing into the
# USER settings file also means every worker created later inherits it without
# a second step.
#
# Usage:
#   install-statusline.sh              # install if absent, refresh if ours
#   install-statusline.sh --force      # take over a foreign statusLine too
#   install-statusline.sh --quiet      # only speak on error
#
# Exit codes: 0 installed/refreshed/already-correct/deliberately-skipped,
#             1 error. Never fails a launch: callers treat non-zero as advisory.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SCRIPT_DIR/statusline.sh"

CLAUDE_HOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
DEST="$CLAUDE_HOME/autocoder-statusline.sh"
SETTINGS="$CLAUDE_HOME/settings.json"

FORCE=0
QUIET=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    --quiet) QUIET=1 ;;
    *) echo "install-statusline.sh: unknown argument '$arg'" >&2; exit 1 ;;
  esac
done

say() { [ "$QUIET" -eq 1 ] || echo "$@"; }

[ -f "$SRC" ] || { echo "❌ statusline.sh not found next to install-statusline.sh ($SRC)" >&2; exit 1; }

# The status line itself parses JSON with jq. Without it every segment would go
# silent and the line would render empty -- which looks like "no status line
# configured" and sends you looking in the wrong place.
if ! command -v jq >/dev/null 2>&1; then
  echo "⚠️  jq not found — the status line needs it to parse session JSON." >&2
  echo "   Install jq (apt install jq / brew install jq), then rerun." >&2
  exit 1
fi

mkdir -p "$CLAUDE_HOME" || { echo "❌ cannot create $CLAUDE_HOME" >&2; exit 1; }

# Always refresh the script body: a plugin upgrade should update the renderer
# even when settings.json already points at it.
cp "$SRC" "$DEST" || { echo "❌ cannot write $DEST" >&2; exit 1; }
chmod +x "$DEST"

# Point settings at $DEST. Merge rather than overwrite -- settings.json holds
# model, env, enabledPlugins and more, and clobbering it to set one key would
# be a spectacular own goal.
verdict=$(DEST="$DEST" SETTINGS="$SETTINGS" FORCE="$FORCE" python3 - <<'PY'
import json, os, sys, tempfile

dest     = os.environ["DEST"]
settings = os.environ["SETTINGS"]
force    = os.environ["FORCE"] == "1"

data = {}
if os.path.exists(settings):
    try:
        with open(settings) as fh:
            data = json.load(fh)
    except (json.JSONDecodeError, OSError) as exc:
        print(f"❌ {settings} is not readable JSON ({exc}); refusing to rewrite it", file=sys.stderr)
        sys.exit(1)
    if not isinstance(data, dict):
        print(f"❌ {settings} is not a JSON object; refusing to rewrite it", file=sys.stderr)
        sys.exit(1)

current = data.get("statusLine")
existing_cmd = current.get("command", "") if isinstance(current, dict) else ""

# Someone else's status line is not ours to replace. Recognise our own by
# filename so a refresh is idempotent, and leave anything else alone unless
# --force. Compare on the basename: the stored path may be tilde-form.
ours = os.path.basename(dest)
if existing_cmd and ours not in existing_cmd and not force:
    print(f"STATUSLINE_SKIPPED {existing_cmd}")
    sys.exit(0)

home = os.path.expanduser("~")
pretty = "~" + dest[len(home):] if dest.startswith(home + os.sep) else dest

if isinstance(current, dict) and current.get("command") == pretty and current.get("type") == "command":
    print("STATUSLINE_CURRENT")
    sys.exit(0)

data["statusLine"] = {"type": "command", "command": pretty}

# Write via a temp file in the same directory, then rename. A crash midway
# through an in-place rewrite would leave settings.json truncated, and Claude
# Code would start with no settings at all.
directory = os.path.dirname(settings) or "."
fd, tmp = tempfile.mkstemp(dir=directory, prefix=".settings.", suffix=".json")
try:
    with os.fdopen(fd, "w") as fh:
        json.dump(data, fh, indent=2)
        fh.write("\n")
    os.replace(tmp, settings)
except Exception:
    if os.path.exists(tmp):
        os.unlink(tmp)
    raise

print("STATUSLINE_INSTALLED" if not existing_cmd else "STATUSLINE_UPDATED")
PY
)
rc=$?
[ $rc -eq 0 ] || exit $rc

case "$verdict" in
  STATUSLINE_INSTALLED)
    say "✅ Status line installed → $SETTINGS"
    say "   ctx / mem / model / worktree / branch on every new pane." ;;
  STATUSLINE_UPDATED)
    say "✅ Status line repointed at $DEST" ;;
  STATUSLINE_CURRENT)
    say "✅ Status line already current (renderer refreshed)" ;;
  STATUSLINE_SKIPPED*)
    say "ℹ️  Leaving your existing status line alone: ${verdict#STATUSLINE_SKIPPED }"
    say "   Run with --force to replace it with the swarm one." ;;
  *)
    echo "⚠️  install-statusline.sh: unexpected verdict '$verdict'" >&2
    exit 1 ;;
esac

exit 0
