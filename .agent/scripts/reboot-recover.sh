#!/bin/bash
# reboot-recover.sh: start one manager per swarm after a host reboot (#274, part of #271).
#
# After a reboot nothing restarts a swarm's turn: herdr restores panes and runs
# `claude --resume` in each, but a resumed session waits; tmux restores nothing
# (unless tmux-resurrect is in use). The worktrees, their branches and their
# uncommitted edits are still on disk. This script gets ONE manager running in
# each swarm's repo root and leaves the worktrees to it: the manager's
# reboot-recovery step (manager-resume) adopts or spawns a worker in every
# worktree and sends it `/autocoder:fix <N>` for that worktree's issue
# (worktree-issue.sh maps worktree → issue).
#
# 1. Find the swarms. A swarm is a repo main checkout with at least one linked
#    worktree named <repo>-wt-<something>. Candidate directories come from
#    --project (repeatable) and from the working directories of herdr's agent
#    panes and workspaces; each is resolved to its main checkout. A swarm whose
#    every manifest (.autocoder/swarm/*.json) says "paused" (the sentinel's
#    step-down, #218) is skipped.
# 2. For each swarm, exactly one manager:
#    - one restored herdr agent pane in the repo root → prompt it with the
#      sentinel's wake prompt (manager-resume --non-interactive, then
#      monitor-loop);
#    - two or more → report them and prompt none (a person picks one);
#    - none → create .autocoder/wake and run `idle-sentinel.sh --once` for that
#      root. The sentinel detects the multiplexer (herdr, tmux, cmux), checks
#      that no manager is alive, spawns one with the same prompt and records it
#      in the manifest. tmux panes never survive a reboot, so under tmux this
#      is always the spawn path.
#    The nested sentinel run gets AUTOCODER_REBOOT_RECOVER=1 so its own reboot
#    wake (#275) does not call this script again.
#
# The script does not drive workers, release claims, prune worktrees or touch
# merge jobs; the manager does those (manager-resume, "Reboot recovery").
#
# Usage: reboot-recover.sh [--project DIR]... [--dry-run]
#   --project DIR  a directory inside a swarm's repository (repeatable; default:
#                  $PWD when no herdr pane names any swarm). Manifests live
#                  inside each repo, so without herdr (tmux, no mux) only the
#                  swarms named here are found: callers pass every root they know.
#   --dry-run      list the swarms and what would be done; change nothing
#
# Exit: 0 ran (each per-swarm failure is reported), 1 bad usage.
#
# Environment:
#   AUTOCODER_AGENT              agent kind when no manifest names one (claude);
#                                non-claude agents use bare command names
#   AUTOCODER_REBOOT_SENTINEL    sentinel to run for a spawn (default: the
#                                idle-sentinel.sh beside this script)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=mux-send-lib.sh
source "$SCRIPT_DIR/mux-send-lib.sh"

PROJECTS=()
DRY_RUN=false
while [ $# -gt 0 ]; do
  case "$1" in
    --project) [ $# -ge 2 ] || { echo "reboot-recover: --project needs a directory" >&2; exit 1; }
               PROJECTS+=("$2"); shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) sed -n '2,/^set -u/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "reboot-recover: unknown argument '$1'" >&2; exit 1 ;;
  esac
done
SENTINEL="${AUTOCODER_REBOOT_SENTINEL:-$SCRIPT_DIR/idle-sentinel.sh}"

# main_checkout <dir>: the repo's main worktree (physical path), or nothing.
main_checkout() {
  local common
  common=$(cd "$1" 2>/dev/null && git rev-parse --git-common-dir 2>/dev/null) || return 1
  common=$(cd "$1" && cd "$common" && pwd -P) || return 1
  case "$common" in
    */.git) printf '%s\n' "${common%/.git}" ;;
    *) return 1 ;;   # a bare repository has no checkout to run a manager in
  esac
}

# toplevel <dir>: the worktree containing dir (physical path), or nothing.
toplevel() {
  local top
  top=$(cd "$1" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null) || return 1
  (cd "$top" && pwd -P)
}

# swarm_worktrees <root>: linked worktrees named <repo>-wt-*, one per line.
swarm_worktrees() {
  local root="$1" base path
  base=$(basename "$root")
  git -C "$root" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | while IFS= read -r path; do
    case "$(basename "$path")" in "$base"-wt-*) printf '%s\n' "$path" ;; esac
  done
}

# swarm_paused <root>: true when manifests exist and every one says paused.
swarm_paused() {
  local f any=false
  for f in "$1"/.autocoder/swarm/*.json; do
    [ -f "$f" ] || continue
    any=true
    [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("state",""))' "$f" 2>/dev/null)" = paused ] || return 1
  done
  [ "$any" = true ]
}

# manifest_agent <root>: the agent kind a manifest records, or nothing.
manifest_agent() {
  local f a
  for f in "$1"/.autocoder/swarm/*.json; do
    [ -f "$f" ] || continue
    a=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("agent","") or "")' "$f" 2>/dev/null)
    [ -n "$a" ] && { printf '%s\n' "$a"; return 0; }
  done
  return 1
}

# ── Host detection: printed so a run on a new host shows its decisions ───────
MUX=none
if herdr_is_running; then MUX=herdr
elif command -v tmux >/dev/null 2>&1 && tmux list-sessions >/dev/null 2>&1; then MUX=tmux
elif cmux_is_running 2>/dev/null; then MUX=cmux
fi
echo "reboot-recover: host mux=$MUX sentinel=$SENTINEL$([ "$DRY_RUN" = true ] && echo ' (dry run)')"

# ── herdr agent panes: "<pane>\t<physical cwd>" ──────────────────────────────
PANES=""
if [ "$MUX" = herdr ]; then
  agents_json=$(run_with_timeout "$AUTOCODER_MUX_TIMEOUT_SECONDS" herdr agent list 2>/dev/null) || agents_json=""
  pane_ids=$(printf '%s' "$agents_json" | SELF_PANE="${HERDR_PANE_ID:-}" python3 -c '
import json, os, sys
try:
    agents = json.load(sys.stdin)["result"]["agents"]
except Exception:
    sys.exit(0)
for a in agents:
    p = a.get("pane_id")
    if p and p != os.environ["SELF_PANE"]:
        print(p)
' 2>/dev/null)
  for pane in $pane_ids; do
    # foreground_cwd is the agent's own directory; cwd is the pane's shell.
    cwd=$(run_with_timeout "$AUTOCODER_MUX_TIMEOUT_SECONDS" herdr pane get "$pane" 2>/dev/null | python3 -c '
import json, sys
try:
    p = json.load(sys.stdin)["result"]["pane"]
except Exception:
    sys.exit(0)
print(p.get("foreground_cwd") or p.get("cwd") or "")' 2>/dev/null)
    [ -n "$cwd" ] || continue
    cwd=$(cd "$cwd" 2>/dev/null && pwd -P) || continue
    PANES="$PANES$pane	$cwd
"
  done
  # Workspaces restored without an agent still name a directory, when herdr reports one.
  WS_CWDS=$(run_with_timeout "$AUTOCODER_MUX_TIMEOUT_SECONDS" herdr workspace list 2>/dev/null | python3 -c '
import json, sys
try:
    wss = json.load(sys.stdin)["result"]["workspaces"]
except Exception:
    sys.exit(0)
for w in wss:
    if w.get("cwd"):
        print(w["cwd"])' 2>/dev/null)
fi

# ── 1. Find the swarms ───────────────────────────────────────────────────────
CANDIDATES=()
for p in ${PROJECTS[@]+"${PROJECTS[@]}"}; do CANDIDATES+=("$p"); done
while IFS='	' read -r _ cwd; do [ -n "${cwd:-}" ] && CANDIDATES+=("$cwd"); done <<< "$PANES"
while IFS= read -r cwd; do [ -n "$cwd" ] && CANDIDATES+=("$cwd"); done <<< "${WS_CWDS:-}"
[ "${#CANDIDATES[@]}" -gt 0 ] || CANDIDATES+=("$PWD")

ROOTS=""   # newline-separated, unique
for c in "${CANDIDATES[@]}"; do
  root=$(main_checkout "$c") || continue
  case "
$ROOTS" in *"
$root
"*) continue ;; esac
  ROOTS="$ROOTS$root
"
done

STARTED=0; PROMPTED=0; SKIPPED=0; FAILED=0
while IFS= read -r root; do
  [ -n "$root" ] || continue
  wts=$(swarm_worktrees "$root")
  [ -n "$wts" ] || continue
  nwt=$(printf '%s\n' "$wts" | grep -c .)
  if swarm_paused "$root"; then
    echo "⏸️  $root: paused (manifest); skipped"
    SKIPPED=$((SKIPPED + 1)); continue
  fi
  echo "🐝 swarm $root ($nwt worktree$([ "$nwt" -eq 1 ] || echo s))"

  agent=$(manifest_agent "$root") || agent="${AUTOCODER_AGENT:-claude}"
  case "$agent" in claude) pfx="autocoder:" ;; *) pfx="" ;; esac
  prompt="Run /${pfx}manager-resume --non-interactive and let it complete. Then run /${pfx}monitor-loop. You were woken by the idle sentinel (reason: reboot — the host restarted; recover every worktree's worker)."

  # ── 2. Exactly one manager in the repo root ──
  managers=""
  while IFS='	' read -r pane cwd; do
    [ -n "${pane:-}" ] || continue
    [ "$(toplevel "$cwd")" = "$root" ] && managers="$managers${managers:+ }$pane"
  done <<< "$PANES"
  # shellcheck disable=SC2086
  set -- $managers
  if [ $# -gt 1 ]; then
    echo "⚠️  $# agent panes in $root ($managers): one manager per swarm expected; prompting none. Close the extras, then re-run."
    FAILED=$((FAILED + 1)); continue
  fi
  if [ $# -eq 1 ]; then
    if [ "$DRY_RUN" = true ]; then
      echo "   DRY-RUN would prompt restored manager pane $1"
    elif send_agent_prompt herdr "$1" "$prompt"; then
      echo "   prompted restored manager pane $1"; PROMPTED=$((PROMPTED + 1))
    else
      echo "❌ could not prompt manager pane $1"; FAILED=$((FAILED + 1))
    fi
    continue
  fi
  if [ "$DRY_RUN" = true ]; then
    echo "   DRY-RUN would create $root/.autocoder/wake and run: $SENTINEL --once --project $root"
    continue
  fi
  mkdir -p "$root/.autocoder" && : > "$root/.autocoder/wake"
  if AUTOCODER_REBOOT_RECOVER=1 bash "$SENTINEL" --once --project "$root"; then
    echo "   started a manager via the idle sentinel"; STARTED=$((STARTED + 1))
  else
    echo "❌ the idle sentinel did not start a manager in $root (see $root/.autocoder/sentinel.log)"
    FAILED=$((FAILED + 1))
  fi
done <<< "$ROOTS"

echo ""
echo "reboot-recover: managers prompted=$PROMPTED started=$STARTED skipped(paused)=$SKIPPED problems=$FAILED$([ "$DRY_RUN" = true ] && echo ' (dry run)')"
exit 0
