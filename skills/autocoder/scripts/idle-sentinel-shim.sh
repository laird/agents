#!/usr/bin/env bash
# idle-sentinel-shim.sh: the version-independent entry point for the idle
# sentinel (#273).
#
# `idle-sentinel.sh --ensure` installs a copy of this file as
# ~/.local/bin/autocoder-idle-sentinel (override: AUTOCODER_SENTINEL_SHIM) and
# points the systemd user timer at that copy, never at a versioned plugin
# path. A scheduler that pins the absolute path of the plugin version that
# installed it keeps running that version after an upgrade (#271: a host ran
# 4.35.0's sentinel for days after the fix shipped). This shim looks the
# sentinel up again on every run, so an upgrade takes effect at the next tick.
#
# Resolution order, first hit wins:
#   1. $AUTOCODER_SENTINEL_SCRIPT, an explicit override.
#   2. The newest installed plugin: the highest <version> (sort -V on the
#      version alone, so the marketplace directory name cannot outrank it) among
#      ${AUTOCODER_PLUGIN_CACHE:-~/.claude/plugins/cache}/<marketplace>/autocoder/<version>/scripts/idle-sentinel.sh
#   3. $AUTOCODER_SENTINEL_FALLBACK: the script that installed the timer,
#      used only when no plugin is installed (e.g. a checkout-only host).
#
# A project's own vendored tree is deliberately NOT consulted: a stale vendored
# copy would pin an old sentinel on every tick, the failure this shim exists to
# prevent, and an unattended timer should not run whatever a checkout contains.
#
# All arguments are passed through unchanged.
#
# The same file is installed as ~/.local/bin/autocoder-reboot-recover by
# `reboot-recover.sh --install` (#275). Under a name containing
# "reboot-recover" it resolves reboot-recover.sh instead, by the same rules,
# with $AUTOCODER_REBOOT_SCRIPT and $AUTOCODER_REBOOT_FALLBACK as the override
# and the fallback.

set -u

project=""
prev=""
for a in "$@"; do
  [ "$prev" = "--project" ] && project="$a"
  prev="$a"
done

run_sentinel() {
  local script="$1"
  shift
  exec bash "$script" "$@"
}

target=idle-sentinel.sh
override="${AUTOCODER_SENTINEL_SCRIPT:-}"
fallback="${AUTOCODER_SENTINEL_FALLBACK:-}"
case "$(basename "$0")" in
  *reboot-recover*)
    target=reboot-recover.sh
    override="${AUTOCODER_REBOOT_SCRIPT:-}"
    fallback="${AUTOCODER_REBOOT_FALLBACK:-}" ;;
esac

if [ -n "$override" ]; then
  run_sentinel "$override" "$@"
fi

cache="${AUTOCODER_PLUGIN_CACHE:-${HOME:-}/.claude/plugins/cache}"
newest=""
if [ -d "$cache" ]; then
  # "<version><TAB><path>" for <marketplace>/autocoder/<version>/scripts/idle-sentinel.sh
  # exactly (the version must start with a digit), sorted on the version only.
  newest=$(find "$cache" -mindepth 5 -maxdepth 5 -type f -path "*/autocoder/*/scripts/$target" 2>/dev/null \
    | sed -nE "s#^.*/autocoder/([0-9][^/]*)/scripts/${target%.sh}\\.sh\$#\\1\t&#p" \
    | sort -t "$(printf '\t')" -k1,1V | tail -1 | cut -f2-)
fi
if [ -z "$newest" ]; then
  # Grok copies the plugin to ~/.grok/installed-plugins/<name>-<hash>/scripts.
  # There is no <version> directory, so the Claude cache search above misses it.
  grok_plugins="${AUTOCODER_GROK_PLUGINS:-${HOME:-}/.grok/installed-plugins}"
  if [ -d "$grok_plugins" ]; then
    newest=$(find "$grok_plugins" -type f -path "*/autocoder-*/scripts/$target" -not -path "*/skills/*" 2>/dev/null \
      | sort | tail -1)
  fi
fi
if [ -n "$newest" ]; then
  run_sentinel "$newest" "$@"
fi

if [ -n "$fallback" ] && [ -f "$fallback" ]; then
  run_sentinel "$fallback" "$@"
fi

echo "$(basename "$0"): no $target found (project '${project}', plugin cache '${cache}')" >&2
exit 1
