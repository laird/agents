#!/bin/bash
# gate-env-fns.sh — run a gate's test command in the host environment (default) or, when
# the project opts in, in a hermetic one (#223).
#
# The local gate runs the test command in the developer's own environment, so a test that
# secretly depends on the host (a tool on PATH, a file under ~/.config, a newer runtime)
# passes the gate and fails CI. A project opts in with .autocoder.json:
#
#   "gate": {"hermetic": true,
#            "path": ["~/.cargo/bin", "/usr/local/bin"],   # toolchain dirs to keep
#            "env":  ["RUSTUP_HOME", "CARGO_HOME"]}         # variables passed by name
#
# A hermetic gate runs `env -i` with PATH = the declared dirs + /usr/bin:/bin, a fresh
# temporary HOME (XDG_* under it, removed afterwards), LANG=C.UTF-8, and only the declared
# variables. PATH, HOME, XDG_* and LANG are always ours: a declared name cannot override them.
# AUTOCODER_GATE_RETEST_FILES, when set, always crosses (#298).
#
# The mode is a property of the TREE being gated: the config is read from the
# .autocoder.json committed in that tree, never from the working directory, so the gate
# cache (gate-cache-fns.sh) can key a verdict by mode and a host-mode pass never
# satisfies a hermetic gate. An uncommitted .autocoder.json does not switch it on.
#
# Source this file; callers use:
#   gate_env_config <tree-ish> [git-dir]   -> prints the normalized hermetic config, or
#                                             nothing for host mode; rc 2 if the tree is
#                                             not in that repository, rc 3 if its config
#                                             could not be parsed (e.g. python3 missing)
#   gate_env_run <dir> "<test-cmd>"         -> runs the command in <dir> in the tree's mode

gate_env_config() {
  local tree="$1" gd="${2:-.}" json
  git -C "$gd" cat-file -e "${tree}^{tree}" 2>/dev/null || return 2
  json=$(git -C "$gd" cat-file blob "${tree}:.autocoder.json" 2>/dev/null) || return 0
  case "$json" in *hermetic*) ;; *) return 0 ;; esac   # not opted in: no parser needed
  local out
  out=$(printf '%s' "$json" | python3 -c '
import json, re, sys
try:
    g = json.load(sys.stdin).get("gate")
except Exception:
    sys.exit(0)
if not isinstance(g, dict) or g.get("hermetic") is not True:
    sys.exit(0)
print("hermetic")
for p in g.get("path") or []:
    if isinstance(p, str) and p and "\n" not in p and ":" not in p:
        print("path " + p)
for e in g.get("env") or []:
    if isinstance(e, str) and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", e):
        print("env " + e)
') || return 3
  [ -z "$out" ] || printf '%s\n' "$out"
}

gate_env_run() {
  local dir="$1" cmd="$2" cfg line p path="" names=() n
  if ! cfg=$(gate_env_config HEAD "$dir"); then
    echo "gate-env: cannot read the gate environment for $dir (python3 missing?); refusing to run the gate" >&2
    return 1
  fi
  if [ -z "$cfg" ]; then
    echo "gate-env: host environment"
    (cd "$dir" && bash -c "$cmd")
    return
  fi
  while IFS= read -r line; do
    case "$line" in
      "path "*)
        p=${line#path }
        case "$p" in
          "~"|"~/"*)
            if [ -z "${HOME:-}" ] || [[ "$HOME" == *:* ]]; then
              echo "gate-env: ignoring gate.path entry $p (HOME is unset or contains ':')" >&2; continue
            fi
            [ "$p" = "~" ] && p=$HOME || p="$HOME/${p#\~/}" ;;
          /*)     ;;
          *)      echo "gate-env: ignoring gate.path entry that is not absolute: $p" >&2; continue ;;
        esac
        path+="$p:" ;;
      "env "*) names+=("${line#env }") ;;
    esac
  done <<< "$cfg"
  path+="/usr/bin:/bin"
  echo "gate-env: hermetic (PATH=$path; fresh HOME; passed through: ${names[*]:-none})"
  (
    home=$(mktemp -d "${TMPDIR:-/tmp}/autocoder-gate-home.XXXXXX") || exit 1
    trap 'rm -rf "$home"' EXIT
    trap 'exit 143' TERM INT HUP
    args=()
    for n in ${names[@]+"${names[@]}"}; do
      [ -n "${!n+x}" ] && args+=("$n=${!n}")
    done
    # The files a red-base re-run is told to re-run (#298) always cross.
    [ -n "${AUTOCODER_GATE_RETEST_FILES:-}" ] && args+=(AUTOCODER_GATE_RETEST_FILES="$AUTOCODER_GATE_RETEST_FILES")
    args+=(PATH="$path" HOME="$home" XDG_CONFIG_HOME="$home/.config" XDG_DATA_HOME="$home/.local/share"
           XDG_CACHE_HOME="$home/.cache" XDG_STATE_HOME="$home/.local/state" LANG=C.UTF-8)
    cd "$dir" && env -i "${args[@]}" "$BASH" -c "$cmd"
  )
}
