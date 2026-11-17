#!/usr/bin/env bash
# install-release-hook.sh — install a pre-push hook that cuts a GitHub Release
# (release.sh) for each push of the integration branch made from the main
# checkout (see release-pre-push.sh). Pushes from the swarm's worktrees and merge
# jobs never release.
#
# USAGE (from inside the repo):
#   install-release-hook.sh [--uninstall]
#
# The hook goes in the hooks directory every checkout shares (core.hooksPath,
# else <git common dir>/hooks), as a short shim that runs this directory's
# release-pre-push.sh. When a plugin update removes that path, the shim falls
# back to the newest installed autocoder plugin's copy, and does nothing if there
# is none. An existing pre-push hook that is not this one is left alone: the
# script stops and says so.
set -euo pipefail

UNINSTALL=false
case "${1:-}" in
  --uninstall) UNINSTALL=true ;;
  "") ;;
  -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
  *) echo "install-release-hook.sh: unknown argument: $1" >&2; exit 1 ;;
esac

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
common=$(cd "$(git rev-parse --git-common-dir)" && pwd -P)
main=$(cd "$common/.." && pwd -P)
hooks=$(git config core.hooksPath || true)
case "$hooks" in
  "") hooks="$common/hooks" ;;
  /*) ;;
  *) hooks="$main/$hooks" ;;
esac
hook="$hooks/pre-push"
MARK="# autocoder release hook"
LEGACY="# agents-ui release hook"   # tools/install-hooks.sh's, replaced in place

if [ -e "$hook" ] && ! grep -qF -e "$MARK" -e "$LEGACY" "$hook"; then
  echo "install-release-hook.sh: $hook exists and is not autocoder's; leaving it alone." >&2
  echo "  To release on push as well, end that hook with: exec bash \"$here/release-pre-push.sh\" \"\$@\"" >&2
  exit 1
fi
if [ "$UNINSTALL" = true ]; then
  rm -f "$hook"
  echo "install-release-hook.sh: removed $hook"
  exit 0
fi
mkdir -p "$hooks"
cat > "$hook" <<HOOK
#!/usr/bin/env bash
$MARK (install-release-hook.sh)
s="$here/release-pre-push.sh"
if [ ! -f "\$s" ]; then
  s=""
  for f in "\$HOME"/.claude/plugins/cache/*/autocoder/*/scripts/release-pre-push.sh; do
    [ -f "\$f" ] && s="\$f"
  done
fi
[ -n "\$s" ] || exit 0
exec bash "\$s" "\$@"
HOOK
chmod +x "$hook"
echo "install-release-hook.sh: installed $hook"
echo "  A push of the integration branch from $main now releases it"
echo "  (log: \${XDG_STATE_HOME:-~/.local/state}/autocoder/release.log)."
echo "  AUTOCODER_NO_RELEASE=1 git push ... pushes without releasing."
