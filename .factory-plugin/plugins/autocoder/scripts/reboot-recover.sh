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
#    - restored herdr agent panes in the repo root → pick the manager and
#      prompt only it with the sentinel's wake prompt (manager-resume
#      --non-interactive, then monitor-loop). The manager is, in order: the pane
#      the manifest records (manager.herdrPane), the pane in the workspace named
#      manager-<project>, the pane whose processes carry AUTOCODER_MANAGER=<session>,
#      else the only agent pane in the root (#291). Other root panes (a person's
#      own session) are left alone and listed as such. The pane running this
#      script counts too: it is named "this pane", and never prompted;
#    - two or more that nothing tells apart → report them and prompt none;
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
# Boot triggers (#275). Recovery should run once per boot, from whichever
# trigger fires first. --boot compares this boot's id (Linux boot_id, macOS
# kern.boottime) with the per-user stamp in the state directory (reboot-lib.sh)
# and does nothing when they match; otherwise it waits for herdr when herdr is a
# service here, recovers every known swarm, and only then writes the stamp, so
# a crash mid-recovery is retried by the next trigger. Callers:
#   - the boot trigger --install sets up for this host, detected at run time:
#     a systemd user unit (wanted by default.target, ordered on no unit it does
#     not own, #280), else a cron @reboot line, else
#     (macOS) a launchd agent with RunAtLoad, else none (said so);
#   - idle-sentinel.sh's boot wake, a backstop on hosts with no boot trigger.
# Swarms are found from herdr (as above) and, with --all or --boot, from the
# per-user swarm-roots registry that swarm creation and --ensure append to:
# on a tmux host, or with no multiplexer, nothing else survives a reboot.
#
# Usage: reboot-recover.sh [--project DIR]... [--all] [--boot] [--dry-run]
#        reboot-recover.sh --install [--dry-run]
#   --project DIR  a directory inside a swarm's repository (repeatable; default:
#                  $PWD when nothing else names a swarm)
#   --all          also every root in the swarm-roots registry
#   --boot         once per boot: skip when this boot was already recovered;
#                  implies --all
#   --install      install this host's boot trigger (runs --boot at boot)
#   --dry-run      print the host detection and what would be done; change nothing
#
# Exit: 0 ran (each per-swarm failure is reported), 1 bad usage or a failed install.
#
# Environment:
#   AUTOCODER_AGENT              agent kind when no manifest names one (claude);
#                                non-claude agents use bare command names
#   AUTOCODER_REBOOT_SENTINEL    sentinel to run for a spawn (default: the
#                                idle-sentinel.sh beside this script)
#   AUTOCODER_REBOOT_MUX_WAIT    seconds --boot waits for a herdr service (90)
#   AUTOCODER_REBOOT_MAX_ATTEMPTS  --boot attempts per boot while a swarm fails (3);
#                                each retry covers only the swarms not yet recovered
#   AUTOCODER_REBOOT_SHIM        installed entry point
#                                (default ~/.local/bin/autocoder-reboot-recover)
#   AUTOCODER_REBOOT_STATE_DIR, AUTOCODER_BOOT_ID_FILE: see reboot-lib.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=mux-send-lib.sh
source "$SCRIPT_DIR/mux-send-lib.sh"
# shellcheck source=reboot-lib.sh
source "$SCRIPT_DIR/reboot-lib.sh"

PROJECTS=()
DRY_RUN=false
ALL=false
BOOT=false
INSTALL=false
while [ $# -gt 0 ]; do
  case "$1" in
    --project) [ $# -ge 2 ] || { echo "reboot-recover: --project needs a directory" >&2; exit 1; }
               PROJECTS+=("$2"); shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --all)     ALL=true; shift ;;
    --boot)    BOOT=true; ALL=true; shift ;;
    --install) INSTALL=true; shift ;;
    -h|--help) sed -n '2,/^set -u/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "reboot-recover: unknown argument '$1'" >&2; exit 1 ;;
  esac
done
SENTINEL="${AUTOCODER_REBOOT_SENTINEL:-$SCRIPT_DIR/idle-sentinel.sh}"

SHIM_SRC="$SCRIPT_DIR/idle-sentinel-shim.sh"
SHIM="${AUTOCODER_REBOOT_SHIM:-$HOME/.local/bin/autocoder-reboot-recover}"
SELF_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
STATE_DIR=$(reboot_state_dir)
UNIT_NAME=$REBOOT_UNIT_NAME
SYSTEMD_USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
LAUNCHD_LABEL=com.autocoder.reboot-recover
LAUNCHD_PLIST="$HOME/Library/LaunchAgents/$LAUNCHD_LABEL.plist"
CRON_MARK="# autocoder-reboot-recover"
MAX_BOOT_ATTEMPTS="${AUTOCODER_REBOOT_MAX_ATTEMPTS:-3}"

# trigger_path: the PATH a boot trigger runs with: the one --install ran with,
# minus relative entries (".", "node_modules/.bin"), which would resolve
# against whatever directory the trigger happens to start in.
trigger_path() {
  local d out="" dirs
  IFS=: read -ra dirs <<< "$PATH"
  for d in ${dirs[@]+"${dirs[@]}"}; do
    case "$d" in /*) out="${out:+$out:}$d" ;; esac
  done
  printf '%s\n' "${out:-/usr/local/bin:/usr/bin:/bin}"
}

# boot_scheduler: launchd (macOS) | systemd-user | cron | none. systemd comes
# before cron: a unit reports its result (journalctl, boot_trigger_missed).
boot_scheduler() {
  if launchd_available; then echo launchd
  elif systemd_user_available; then echo systemd-user
  elif cron_available; then echo cron
  else echo none
  fi
}

print_detection() {
  local sched linger=n/a
  sched=$(boot_scheduler)
  [ "$sched" = systemd-user ] && linger=$(linger_state)
  echo "reboot-recover: host os=$(host_os) scheduler=$sched linger=$linger mux=$1 boot_id=$(boot_id_source) state=$STATE_DIR$([ "$DRY_RUN" = true ] && echo ' (dry run)')"
}

# The unit's only ordering. network-online.target is not a user-manager unit;
# ordering on a unit that does not exist is a no-op, never a cycle.
UNIT_AFTER=network-online.target

# unit_ordering: one line naming the ordering the unit uses (--dry-run).
unit_ordering() {
  echo "ordering: After=$UNIT_AFTER, WantedBy=default.target; no ordering on herdr.service (--boot waits up to ${AUTOCODER_REBOOT_MUX_WAIT:-90}s for herdr when it is a user service)"
}

# unit_cycle_check: the ordering cycles systemd reports for default.target that
# involve our unit, one per line; empty when none or systemd-analyze is
# missing. verify on the unit alone misses a cycle that runs through
# default.target's Wants= (it needs the enable symlink), and verify exits 0
# even when it finds one, so read its output.
unit_cycle_check() {
  command -v systemd-analyze >/dev/null 2>&1 || return 0
  systemd-analyze --user verify default.target 2>&1 | grep -F "ordering cycle" | grep -F "$UNIT_NAME"
}

render_unit() {
  cat <<UNIT
# Installed by reboot-recover.sh --install (#275). At boot, starts one manager
# per swarm; once per boot (the stamp in $STATE_DIR is shared with the idle
# sentinel's boot wake). PATH is the one --install ran with.
# No After= on herdr.service or any unit we do not own (#280): a host unit
# ordered After=default.target closes a cycle through this unit's WantedBy, and
# systemd breaks it by deleting this start job. --boot waits for herdr itself.
[Unit]
Description=autocoder: start one manager per swarm after a reboot
After=$UNIT_AFTER

[Service]
Type=oneshot
TimeoutStartSec=20min
Environment=$(systemd_word "AUTOCODER_REBOOT_FALLBACK=$SELF_PATH")
Environment=$(systemd_word "AUTOCODER_REBOOT_STATE_DIR=$STATE_DIR")
Environment=$(systemd_word "PATH=$(trigger_path)")
ExecStart=$(systemd_word "$SHIM") --boot

[Install]
WantedBy=default.target
UNIT
}

render_plist() {
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!-- Installed by reboot-recover.sh (#275): start one manager per swarm at login after a reboot. -->
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LAUNCHD_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$(xml_escape "$SHIM")</string>
    <string>--boot</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>$(xml_escape "$(trigger_path)")</string>
    <key>AUTOCODER_REBOOT_STATE_DIR</key>
    <string>$(xml_escape "$STATE_DIR")</string>
    <key>AUTOCODER_REBOOT_FALLBACK</key>
    <string>$(xml_escape "$SELF_PATH")</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$(xml_escape "$STATE_DIR/reboot-recover.log")</string>
  <key>StandardErrorPath</key>
  <string>$(xml_escape "$STATE_DIR/reboot-recover.log")</string>
</dict>
</plist>
PLIST
}

# install_shim: the version-independent entry point (#273's shim, under a name
# that makes it resolve reboot-recover.sh), copied when missing or changed.
install_shim() {
  [ -f "$SHIM" ] && cmp -s "$SHIM_SRC" "$SHIM" && return 0
  mkdir -p "$(dirname "$SHIM")" || return 1
  cp "$SHIM_SRC" "$SHIM.tmp.$$" && chmod 755 "$SHIM.tmp.$$" && mv -f "$SHIM.tmp.$$" "$SHIM" \
    || { rm -f "$SHIM.tmp.$$"; return 1; }
}

# write_if_changed <file>: stdin to file; 0 when the content changed.
write_if_changed() {
  local new
  new=$(cat)
  [ -f "$1" ] && [ "$(cat "$1")" = "$new" ] && return 1
  mkdir -p "$(dirname "$1")" && printf '%s\n' "$new" > "$1"
}

cmd_install() {
  local sched _p cur
  print_detection "-"
  for _p in "$SHIM" "$SELF_PATH" "$PATH" "$STATE_DIR"; do
    case "$_p" in *$'\n'*|*$'\r'*)
      echo "❌ Refusing to install a boot trigger: a path (or PATH) contains a newline ($(printf '%q' "$_p"))." >&2
      return 1 ;;
    esac
  done
  case "$SHIM" in *\'*|*\"*|*\\*|*%*)
    echo "❌ Refusing to install a boot trigger for $SHIM (it contains ' \" \\ or %). Set AUTOCODER_REBOOT_SHIM to a plainer path." >&2
    return 1 ;;
  esac
  [ -f "$SHIM_SRC" ] || { echo "❌ $SHIM_SRC is missing" >&2; return 1; }
  sched=$(boot_scheduler)
  if [ "$sched" = none ]; then
    echo "⚠️  No boot scheduler on this host (no systemd user manager, crontab or launchd)."
    echo "    After a reboot only projects running the idle sentinel recover (its boot wake), or run: reboot-recover.sh --all"
    return 0
  fi
  if [ "$DRY_RUN" = true ]; then
    echo "DRY-RUN would install the version-independent entry point: $SHIM (from $SHIM_SRC)"
    case "$sched" in
      systemd-user) echo "DRY-RUN would write $SYSTEMD_USER_DIR/$UNIT_NAME ($(unit_ordering)):"; render_unit | sed 's/^/  /'
                    echo "DRY-RUN would check for ordering cycles: systemd-analyze --user verify default.target"
                    echo "DRY-RUN would run: systemctl --user daemon-reload && systemctl --user enable $UNIT_NAME" ;;
      cron)         echo "DRY-RUN would install crontab entry: @reboot $(sh_quote "$SHIM") --boot ... $CRON_MARK" ;;
      launchd)      echo "DRY-RUN would write $LAUNCHD_PLIST:"; render_plist | sed 's/^/  /' ;;
    esac
    return 0
  fi
  install_shim || { echo "❌ could not install $SHIM" >&2; return 1; }
  reboot_state_mkdir || return 1
  # The first boot after installing must count as a change: stamp this one now.
  [ -n "$(boot_stamp_get)" ] || { cur=$(boot_id_current) && boot_stamp_set "$cur"; }
  case "$sched" in
    systemd-user)
      if render_unit | write_if_changed "$SYSTEMD_USER_DIR/$UNIT_NAME"; then
        systemctl --user daemon-reload || { echo "❌ systemctl --user daemon-reload failed" >&2; return 1; }
      fi
      systemctl --user enable "$UNIT_NAME" >/dev/null 2>&1 \
        || { echo "❌ systemctl --user could not enable $UNIT_NAME" >&2; return 1; }
      # A cycle makes systemd delete the start job at boot, silently (#280).
      local cycles
      cycles=$(unit_cycle_check)
      if [ -n "$cycles" ]; then
        systemctl --user disable "$UNIT_NAME" >/dev/null 2>&1
        echo "❌ $UNIT_NAME is in an ordering cycle, so systemd would drop it at boot; disabled it again:" >&2
        printf '   %s\n' "$cycles" >&2
        echo "   Remove the After= that loops back (often After=default.target in another user unit), then re-run --install." >&2
        return 1
      fi
      echo "✅ Boot trigger: systemd user unit $UNIT_NAME (wanted by default.target; runs $SHIM --boot)"
      if [ "$(linger_state)" = no ]; then
        echo "⚠️  Lingering is off for $(id -un): the unit runs at boot only once $(id -un) logs in."
        echo "    To run it at boot: loginctl enable-linger $(id -un)  (may need sudo; never done for you)"
      fi ;;
    cron)
      local line
      # Cron runs @reboot with PATH=/usr/bin:/bin and nothing else: carry
      # what the unit and the plist carry.
      line="@reboot $(cron_escape "PATH=$(sh_quote "$(trigger_path)") AUTOCODER_REBOOT_STATE_DIR=$(sh_quote "$STATE_DIR") AUTOCODER_REBOOT_FALLBACK=$(sh_quote "$SELF_PATH") $(sh_quote "$SHIM") --boot >> $(sh_quote "$STATE_DIR/reboot-recover.log") 2>&1") $CRON_MARK"
      local current
      current=$(crontab -l 2>/dev/null)   # read fully before writing (no pipeline race)
      if ! printf '%s\n' "$current" | grep -qxF -- "$line"; then
        { [ -z "$current" ] || printf '%s\n' "$current" | grep -vF -- "$CRON_MARK"; echo "$line"; } | crontab - \
          || { echo "❌ crontab install failed" >&2; return 1; }
      fi
      cron_daemon_running || echo "⚠️  crontab is installed but no cron daemon is running: @reboot will not fire until one does."
      echo "✅ Boot trigger: cron @reboot (runs $SHIM --boot)" ;;
    launchd)
      # Rewritten, or written earlier but not loaded (e.g. booted out by hand): load it.
      if render_plist | write_if_changed "$LAUNCHD_PLIST" ||
         ! launchctl print "gui/$(id -u)/$LAUNCHD_LABEL" >/dev/null 2>&1; then
        launchctl bootout "gui/$(id -u)/$LAUNCHD_LABEL" >/dev/null 2>&1
        launchctl bootstrap "gui/$(id -u)" "$LAUNCHD_PLIST" 2>/dev/null || launchctl load -w "$LAUNCHD_PLIST" \
          || { echo "❌ launchctl could not load $LAUNCHD_PLIST" >&2; return 1; }
      fi
      echo "✅ Boot trigger: launchd agent $LAUNCHD_LABEL (RunAtLoad; runs $SHIM --boot)" ;;
  esac
  return 0
}

if [ "$INSTALL" = true ]; then
  cmd_install
  exit $?
fi

# ── --boot: once per boot, under a per-user lock ─────────────────────────────
BOOT_ID=""
if [ "$BOOT" = true ]; then
  if ! BOOT_ID=$(boot_id_current); then
    echo "reboot-recover: this host has no boot id (no $(boot_id_file), no kern.boottime): boot check skipped"
    exit 0
  fi
  if [ -z "$(boot_stamp_get)" ]; then
    echo "reboot-recover: no boot recorded yet; recording $BOOT_ID, nothing to recover"
    [ "$DRY_RUN" = true ] || boot_stamp_set "$BOOT_ID"
    exit 0
  fi
  if [ "$(boot_stamp_get)" = "$BOOT_ID" ]; then
    echo "reboot-recover: boot $BOOT_ID already recovered; nothing to do"
    exit 0
  fi
  if [ "$DRY_RUN" != true ]; then
    reboot_state_mkdir
    # The lock is a symlink whose target is "<pid> <boot id>": created
    # atomically with its content, so no contender ever sees a lock without a
    # holder. It lives in the persistent state dir, so a lock left by a crash
    # or power loss survives the reboot; a holder from another boot is stale
    # even when its pid has been reused by an unrelated process since.
    LOCK="$STATE_DIR/reboot-recover.lock"
    MY_LOCK="$$ $BOOT_ID"
    # A directory here is an older build's lock: ln -s would succeed inside it.
    [ -d "$LOCK" ] && [ ! -L "$LOCK" ] && rm -rf "$LOCK"
    if ! ln -s "$$ $BOOT_ID" "$LOCK" 2>/dev/null; then
      holder=$(readlink "$LOCK" 2>/dev/null)
      if [ "${holder#* }" = "$BOOT_ID" ] && kill -0 "${holder%% *}" 2>/dev/null; then
        echo "reboot-recover: another recovery (pid ${holder%% *}) is running; leaving it to finish"
        exit 0
      fi
      echo "reboot-recover: removing a stale lock ($holder)"
      rm -f "$LOCK"
      ln -s "$$ $BOOT_ID" "$LOCK" 2>/dev/null || { echo "reboot-recover: another recovery took the lock; leaving it to finish"; exit 0; }
    fi
    # Remove the lock only while it is still ours.
    trap '[ "$(readlink "$LOCK" 2>/dev/null)" = "$MY_LOCK" ] && rm -f "$LOCK"' EXIT
    # Re-read under the lock: the holder we waited out may have finished this boot.
    [ "$(boot_stamp_get)" = "$BOOT_ID" ] && { echo "reboot-recover: boot $BOOT_ID already recovered; nothing to do"; exit 0; }
  fi
  # herdr restores the panes, so start nothing before it answers. Wait only
  # where herdr is a user service; never start a server ourselves.
  if command -v herdr >/dev/null 2>&1 && ! herdr_is_running; then
    if command -v systemctl >/dev/null 2>&1 && systemctl --user is-enabled herdr.service >/dev/null 2>&1; then
      waited=0; wait_s="${AUTOCODER_REBOOT_MUX_WAIT:-90}"
      while [ "$waited" -lt "$wait_s" ] && ! herdr_is_running; do sleep 3; waited=$((waited + 3)); done
      herdr_is_running || echo "reboot-recover: herdr.service did not answer within ${wait_s}s; continuing without it"
    else
      echo "reboot-recover: herdr is installed but not running and not a user service here; not starting it"
    fi
  fi
fi

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

# pane_label <pane>: the pane id, marked when it is the pane running this script.
pane_label() {
  if [ -n "${HERDR_PANE_ID:-}" ] && [ "$1" = "$HERDR_PANE_ID" ]; then printf '%s (this pane)' "$1"; else printf '%s' "$1"; fi
}

# choose_manager <root> <"pane\tworkspace" lines>: which agent pane in the root
# is the swarm's manager (#291). Prints "PICK\t<pane>\t<reason>" plus one
# "OTHER\t<pane>" per pane left alone, or "AMBIGUOUS\t<panes>" when two or more
# remain and nothing tells them apart; nothing when there is no pane.
# Each signal narrows the candidates only when it matches at least one of them.
choose_manager() {
  ROOT="$1" ROOT_PANES="$2" WS_LABELS="${WS_LABELS:-}" MARKED="${MARKED:-}" python3 -c '
import glob, json, os
root = os.environ["ROOT"]
panes = []   # (pane, workspace) in listing order
for line in os.environ["ROOT_PANES"].splitlines():
    if line.strip():
        pane, _, ws = line.partition("\t")
        panes.append((pane, ws))
if not panes:
    raise SystemExit(0)
labels = dict(l.split("\t", 1) for l in os.environ["WS_LABELS"].splitlines() if "\t" in l)
marked = {}
for l in os.environ["MARKED"].splitlines():
    if "\t" in l:
        p, sess = l.split("\t", 1)
        marked.setdefault(p, set()).add(sess)
recorded, sessions = set(), set()
for f in sorted(glob.glob(os.path.join(root, ".autocoder", "swarm", "*.json"))):
    try:
        data = json.load(open(f, encoding="utf-8"))
    except (OSError, ValueError):
        continue
    if not isinstance(data, dict):
        continue
    if data.get("session"):
        sessions.add(str(data["session"]))
    m = data.get("manager")
    if isinstance(m, dict) and m.get("herdrPane"):
        recorded.add(str(m["herdrPane"]))
name = "manager-" + os.path.basename(root)
signals = [
    ("the manifest records it as the manager", lambda p, w: p in recorded),
    ("its workspace is named " + name, lambda p, w: labels.get(w) == name),
    ("it carries the AUTOCODER_MANAGER marker",
     lambda p, w: bool(marked.get(p)) and (not sessions or bool(marked[p] & sessions))),
]
cands, reason = panes, None
for why, test in signals:
    hit = [c for c in cands if test(*c)]
    if hit:
        cands = hit
        if len(hit) == 1:
            reason = why
            break
if len(cands) == 1:
    pick = cands[0][0]
    print("PICK\t%s\t%s" % (pick, reason or "the only agent in the root"))
    for p, _ in panes:
        if p != pick:
            print("OTHER\t" + p)
else:
    print("AMBIGUOUS\t" + " ".join(p for p, _ in cands))
'
}

# ── Host detection: printed so a run on a new host shows its decisions ───────
MUX=none
if herdr_is_running; then MUX=herdr
elif command -v tmux >/dev/null 2>&1 && tmux list-sessions >/dev/null 2>&1; then MUX=tmux
elif cmux_is_running 2>/dev/null; then MUX=cmux
fi
print_detection "$MUX"
echo "reboot-recover: sentinel=$SENTINEL"

# ── herdr agent panes: "<pane>\t<physical cwd>" ──────────────────────────────
PANES=""
if [ "$MUX" = herdr ]; then
  agents_json=$(run_with_timeout "$AUTOCODER_MUX_TIMEOUT_SECONDS" herdr agent list 2>/dev/null) || agents_json=""
  # Every agent pane, this one included: the manager choice below must see the
  # pane running this script too (#291), and says so instead of hiding it.
  pane_ids=$(printf '%s' "$agents_json" | python3 -c '
import json, sys
try:
    agents = json.load(sys.stdin)["result"]["agents"]
except Exception:
    sys.exit(0)
for a in agents:
    if a.get("pane_id"):
        print(a["pane_id"])
' 2>/dev/null)
  for pane in $pane_ids; do
    # foreground_cwd is the agent's own directory; cwd is the pane's shell.
    info=$(run_with_timeout "$AUTOCODER_MUX_TIMEOUT_SECONDS" herdr pane get "$pane" 2>/dev/null | python3 -c '
import json, sys
try:
    p = json.load(sys.stdin)["result"]["pane"]
except Exception:
    sys.exit(0)
print((p.get("foreground_cwd") or p.get("cwd") or "") + "\t" + (p.get("workspace_id") or ""))' 2>/dev/null)
    cwd="${info%%	*}"; ws="${info#*	}"
    [ -n "$cwd" ] || continue
    cwd=$(cd "$cwd" 2>/dev/null && pwd -P) || continue
    PANES="$PANES$pane	$cwd	$ws
"
  done
  # Workspaces restored without an agent still name a directory, when herdr reports one.
  # Also each workspace's name ("<id>\t<label>"): start-parallel-agents.sh names
  # the manager's workspace manager-<project> (#291).
  ws_json=$(run_with_timeout "$AUTOCODER_MUX_TIMEOUT_SECONDS" herdr workspace list 2>/dev/null) || ws_json=""
  WS_CWDS=$(printf '%s' "$ws_json" | python3 -c '
import json, sys
try:
    wss = json.load(sys.stdin)["result"]["workspaces"]
except Exception:
    sys.exit(0)
for w in wss:
    if w.get("cwd"):
        print(w["cwd"])' 2>/dev/null)
  WS_LABELS=$(printf '%s' "$ws_json" | python3 -c '
import json, sys
try:
    wss = json.load(sys.stdin)["result"]["workspaces"]
except Exception:
    sys.exit(0)
for w in wss:
    name = w.get("label") or w.get("custom_name") or ""
    if w.get("workspace_id") and name:
        print(w["workspace_id"] + "\t" + name)' 2>/dev/null)
  # Panes whose processes carry the manager marker: "<pane>\t<session>" (Linux
  # /proc only; elsewhere this signal is simply absent).
  # AUTOCODER_PROC_ROOT stands in for /proc in tests.
  MARKED=$(PROC="${AUTOCODER_PROC_ROOT:-/proc}" python3 -c '
import os
proc = os.environ["PROC"]
for d in os.listdir(proc) if os.path.isdir(proc) else []:
    if not d.isdigit():
        continue
    try:
        env = open(os.path.join(proc, d, "environ"), "rb").read().split(b"\0")
    except OSError:
        continue
    pane = mgr = None
    for kv in env:
        if kv.startswith(b"HERDR_PANE_ID="):
            pane = kv[14:].decode("utf-8", "replace")
        elif kv.startswith(b"AUTOCODER_MANAGER="):
            mgr = kv[18:].decode("utf-8", "replace")
    if pane and mgr:
        print(pane + "\t" + mgr)' 2>/dev/null | sort -u)
fi

# ── 1. Find the swarms ───────────────────────────────────────────────────────
CANDIDATES=()
for p in ${PROJECTS[@]+"${PROJECTS[@]}"}; do CANDIDATES+=("$p"); done
if [ "$ALL" = true ]; then
  while IFS= read -r p; do [ -n "$p" ] && CANDIDATES+=("$p"); done <<< "$(swarm_roots_list)"
fi
while IFS='	' read -r _ cwd _; do [ -n "${cwd:-}" ] && CANDIDATES+=("$cwd"); done <<< "$PANES"
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
# --boot: roots already recovered in an earlier attempt for this boot.
DONE_FILE="$STATE_DIR/reboot-done"
root_done() { [ "$BOOT" = true ] && grep -qxF -- "$BOOT_ID $1" "$DONE_FILE" 2>/dev/null; }
mark_done() {
  [ "$BOOT" = true ] && [ "$DRY_RUN" != true ] || return 0
  printf '%s %s\n' "$BOOT_ID" "$1" >> "$DONE_FILE"
}
[ "$BOOT" = true ] && [ "$DRY_RUN" != true ] && [ -f "$DONE_FILE" ] && {
  grep -F -- "$BOOT_ID " "$DONE_FILE" > "$DONE_FILE.tmp.$$"; mv -f "$DONE_FILE.tmp.$$" "$DONE_FILE"
}

while IFS= read -r root; do
  [ -n "$root" ] || continue
  if root_done "$root"; then
    echo "✔️  $root: recovered earlier this boot"; continue
  fi
  wts=$(swarm_worktrees "$root")
  [ -n "$wts" ] || continue
  nwt=$(printf '%s\n' "$wts" | grep -c .)
  if swarm_paused "$root"; then
    echo "⏸️  $root: paused (manifest); skipped"
    SKIPPED=$((SKIPPED + 1)); mark_done "$root"; continue
  fi
  echo "🐝 swarm $root ($nwt worktree$([ "$nwt" -eq 1 ] || echo s))"

  agent=$(manifest_agent "$root") || agent="${AUTOCODER_AGENT:-claude}"
  case "$agent" in claude) pfx="autocoder:" ;; *) pfx="" ;; esac
  prompt="Run /${pfx}manager-resume --non-interactive and let it complete. Then run /${pfx}monitor-loop. You were woken by the idle sentinel (reason: reboot — the host restarted; recover every worktree's worker)."

  # ── 2. One manager in the repo root ──
  # Several agents can share the root (a person's own session beside the
  # manager, #291), so the manager is the first of these that names exactly one
  # of them: the manifest's manager pane, the workspace named manager-<project>,
  # the AUTOCODER_MANAGER=<session> marker, and only then "the only agent here".
  # The others are left alone.
  root_panes=""
  while IFS='	' read -r pane cwd ws; do
    [ -n "${pane:-}" ] || continue
    [ "$(toplevel "$cwd")" = "$root" ] && root_panes="$root_panes$pane	${ws:-}
"
  done <<< "$PANES"
  pick=$(choose_manager "$root" "$root_panes")
  chosen=$(printf '%s\n' "$pick" | sed -n 's/^PICK	\([^	]*\)	.*/\1/p')
  why=$(printf '%s\n' "$pick" | sed -n 's/^PICK	[^	]*	//p')
  others=$(printf '%s\n' "$pick" | sed -n 's/^OTHER	//p' | tr '\n' ' ' | sed 's/ $//')
  ambiguous=$(printf '%s\n' "$pick" | sed -n 's/^AMBIGUOUS	//p')
  if [ -n "$ambiguous" ]; then
    n=$(printf '%s\n' $ambiguous | grep -c .)
    echo "⚠️  $n agent panes in $root ($ambiguous) and nothing tells which is the manager (manifest manager pane, workspace manager-$(basename "$root"), AUTOCODER_MANAGER marker); prompting none. Close the extras, or rename the manager's workspace manager-$(basename "$root"), then re-run."
    FAILED=$((FAILED + 1)); continue
  fi
  if [ -n "$chosen" ]; then
    for o in $others; do echo "   $(pane_label "$o"): not the manager, left alone"; done
    if [ "$chosen" = "${HERDR_PANE_ID:-}" ] && [ "$DRY_RUN" != true ]; then
      # Prompting the pane this runs in would type into its own input.
      echo "   manager is $(pane_label "$chosen") ($why); not prompting the pane running this script"
      mark_done "$root"
    elif [ "$DRY_RUN" = true ]; then
      echo "   DRY-RUN would prompt restored manager pane $(pane_label "$chosen") ($why)"
    elif send_agent_prompt herdr "$chosen" "$prompt"; then
      echo "   prompted restored manager pane $chosen ($why)"; PROMPTED=$((PROMPTED + 1)); mark_done "$root"
    else
      echo "❌ could not prompt manager pane $chosen"; FAILED=$((FAILED + 1))
    fi
    continue
  fi
  if [ "$DRY_RUN" = true ]; then
    echo "   DRY-RUN would create $root/.autocoder/wake and run: $SENTINEL --once --project $root"
    continue
  fi
  mkdir -p "$root/.autocoder" && : > "$root/.autocoder/wake"
  if AUTOCODER_REBOOT_RECOVER=1 bash "$SENTINEL" --once --project "$root"; then
    echo "   started a manager via the idle sentinel"; STARTED=$((STARTED + 1)); mark_done "$root"
  else
    echo "❌ the idle sentinel did not start a manager in $root (see $root/.autocoder/sentinel.log)"
    FAILED=$((FAILED + 1))
  fi
done <<< "$ROOTS"

echo ""
echo "reboot-recover: managers prompted=$PROMPTED started=$STARTED skipped(paused)=$SKIPPED problems=$FAILED$([ "$DRY_RUN" = true ] && echo ' (dry run)')"
# Stamp the boot only now that every swarm was attempted: a crash above leaves
# the old stamp, and the next trigger (sentinel tick, next login) retries.
# A swarm that failed keeps the boot unstamped, so the next trigger (the
# sentinel's next tick) retries it, and only it: the others are in reboot-done.
# After MAX_BOOT_ATTEMPTS failed attempts the boot is stamped anyway, so a
# swarm that can never start does not retry forever.
if [ "$BOOT" = true ] && [ "$DRY_RUN" != true ]; then
  if [ "$FAILED" -gt 0 ]; then
    attempts=$(grep -cxF -- "$BOOT_ID" "$STATE_DIR/reboot-attempts" 2>/dev/null)
    attempts=$(( ${attempts:-0} + 1 ))
    echo "$BOOT_ID" >> "$STATE_DIR/reboot-attempts"
    if [ "$attempts" -lt "$MAX_BOOT_ATTEMPTS" ]; then
      echo "reboot-recover: $FAILED swarm(s) not recovered (attempt $attempts of $MAX_BOOT_ATTEMPTS); boot left unrecorded so the next trigger retries them"
      exit 0
    fi
    echo "reboot-recover: $FAILED swarm(s) still not recovered after $attempts attempts; recording the boot, no more retries"
  fi
  boot_stamp_set "$BOOT_ID" && echo "reboot-recover: boot $BOOT_ID recorded"
  rm -f "$DONE_FILE" "$STATE_DIR/reboot-attempts"
fi
exit 0
