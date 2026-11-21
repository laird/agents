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
#   2. The project's own complete script tree (the --project argument):
#      .agent/scripts, plugins/autocoder/scripts, then
#      .claude-plugin/plugins/autocoder/scripts. A tree counts only if it also
#      has issue-fns.sh, the same rule the commands' SCRIPT_DIR resolver uses,
#      so the sentinel runs the code the project's workers run.
#   3. The newest installed plugin: sort -V over
#      ${AUTOCODER_PLUGIN_CACHE:-~/.claude/plugins/cache}/*/autocoder/<version>/scripts/idle-sentinel.sh
#   4. $AUTOCODER_SENTINEL_FALLBACK: the script that installed the timer,
#      used only when nothing above exists.
#
# All arguments are passed through unchanged.

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

if [ -n "${AUTOCODER_SENTINEL_SCRIPT:-}" ]; then
  run_sentinel "$AUTOCODER_SENTINEL_SCRIPT" "$@"
fi

if [ -n "$project" ]; then
  for d in "$project/.agent/scripts" \
           "$project/plugins/autocoder/scripts" \
           "$project/.claude-plugin/plugins/autocoder/scripts"; do
    if [ -f "$d/idle-sentinel.sh" ] && [ -f "$d/issue-fns.sh" ]; then
      run_sentinel "$d/idle-sentinel.sh" "$@"
    fi
  done
fi

cache="${AUTOCODER_PLUGIN_CACHE:-${HOME:-}/.claude/plugins/cache}"
newest=""
if [ -d "$cache" ]; then
  newest=$(find "$cache" -type f -path '*/autocoder/*/scripts/idle-sentinel.sh' 2>/dev/null \
    | sort -V | tail -1)
fi
if [ -n "$newest" ]; then
  run_sentinel "$newest" "$@"
fi

if [ -n "${AUTOCODER_SENTINEL_FALLBACK:-}" ] && [ -f "$AUTOCODER_SENTINEL_FALLBACK" ]; then
  run_sentinel "$AUTOCODER_SENTINEL_FALLBACK" "$@"
fi

echo "autocoder-idle-sentinel: no idle-sentinel.sh found (project '${project}', plugin cache '${cache}')" >&2
exit 1
