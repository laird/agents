#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255: never write the real event logs
# tests/test_reboot_boot.sh: once-per-boot reboot recovery (#275, part of #271).
#
#   1. reboot-lib.sh: boot identity (Linux boot_id, macOS kern.boottime, none)
#      and the per-user swarm-roots registry.
#   2. idle-sentinel.sh's boot wake: first run records, a changed boot id runs
#      exactly one `reboot` wake, unchanged / nested / no boot id runs none, a
#      failed recovery is retried, --dry-run changes nothing.
#   3. reboot-recover.sh --boot: once per boot under a lock, roots from the
#      registry on a tmux-only host, herdr roots, the herdr readiness wait, and
#      a sentinel tick after the boot trigger doing nothing.
#   4. reboot-recover.sh --install on each host kind: systemd user, cron only,
#      launchd (macOS), none; idempotent; --dry-run writes nothing.
#   5. swarm creation registers the root.
#
# Isolation: the state dir, boot id file, HOME (units, plists, shim) and every
# scheduler binary (systemctl, crontab, launchctl, loginctl, uname) are fakes
# under $T. Install runs use a PATH farm without the real ones, so nothing here
# reaches the operator's user manager, crontab or launchd.

set -u
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS="$ROOT/plugins/autocoder/scripts"
RR="$SCRIPTS/reboot-recover.sh"
SENTINEL="$SCRIPTS/idle-sentinel.sh"

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
has()  { if printf '%s' "$3" | grep -qF -- "$2"; then pass "$1"; else fail "$1: '$2' not in: $3"; fi; }
hasnt(){ if printf '%s' "$3" | grep -qF -- "$2"; then fail "$1: unexpected '$2' in: $3"; else pass "$1"; fi; }
eq()   { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: wanted '$2', got '$3'"; fi; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
T=$(cd "$T" && pwd -P)
export AUTOCODER_REBOOT_STATE_DIR="$T/state" AUTOCODER_BOOT_ID_FILE="$T/boot_id"
unset AUTOCODER_REBOOT_RECOVER AUTOCODER_AGENT HERDR_PANE_ID
STAMP="$T/state/last-boot-id"
mkdir -p "$T/bin"

# Fakes shared by every section. systemctl: user manager up unless
# SYSTEMCTL_DOWN=1; is-enabled herdr.service only with HERDR_SERVICE=1.
cat > "$T/bin/systemctl" <<'EOF'
#!/bin/bash
echo "$*" >> "$FAKE_DIR/systemctl.calls"
[ "$1" = --user ] || exit 1
[ "${SYSTEMCTL_DOWN:-0}" = 1 ] && exit 1
case "$2" in
  show-environment) echo "HOME=$HOME" ;;
  is-enabled) [ "${HERDR_SERVICE:-0}" = 1 ] ;;
  *) exit 0 ;;
esac
EOF
printf '#!/bin/bash\necho "Linger=${FAKE_LINGER:-yes}"\n' > "$T/bin/loginctl"
printf '#!/bin/bash\necho "${FAKE_UNAME:-Linux}"\n' > "$T/bin/uname"
printf '#!/bin/bash\n[ "$2" = kern.boottime ] && echo "{ sec = 1700000000, usec = 42 } Tue Nov 14 22:13:20 2023"\n' > "$T/bin/sysctl"
# crontab backed by a file: -l prints, - replaces.
cat > "$T/bin/crontab" <<'EOF'
#!/bin/bash
case "$1" in
  -l) [ -f "$CRONTAB_STORE" ] && cat "$CRONTAB_STORE" || exit 1 ;;
  -)  cat > "$CRONTAB_STORE" ;;
esac
EOF
printf '#!/bin/bash\necho "$*" >> "$FAKE_DIR/launchctl.calls"\n' > "$T/bin/launchctl"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/pgrep"
# Dead herdr / dead tmux / dead cmux: a host with no multiplexer running.
for b in herdr tmux cmux; do printf '#!/bin/bash\nexit 1\n' > "$T/bin/$b"; done
chmod +x "$T"/bin/*
export FAKE_DIR="$T" CRONTAB_STORE="$T/crontab" AUTOCODER_HERDR_PROBE_SECONDS=2 AUTOCODER_MUX_TIMEOUT_SECONDS=5

# ── 1. reboot-lib.sh ─────────────────────────────────────────────────────────
lib() { PATH="$T/bin:$PATH" bash -c "source '$SCRIPTS/reboot-lib.sh'; $1"; }
echo "aaa-111" > "$T/boot_id"
eq "boot id read from the boot_id file" "aaa-111" "$(lib boot_id_current)"
eq "boot id source names the file" "file:$T/boot_id" "$(lib boot_id_source)"
rm -f "$T/boot_id"
eq "no boot_id file on Linux: no boot id" "none" "$(lib boot_id_source)"
lib boot_id_current >/dev/null && fail "boot_id_current succeeded with no source" || pass "no boot id → boot_id_current fails"
eq "macOS: kern.boottime" "1700000000.42" "$(FAKE_UNAME=Darwin lib boot_id_current)"
eq "macOS: source is kern.boottime" "kern.boottime" "$(FAKE_UNAME=Darwin lib boot_id_source)"

mkdir -p "$T/r1" "$T/r2"
ln -s "$T/r1" "$T/r1-link"
lib "swarm_roots_register '$T/r1'; swarm_roots_register '$T/r1-link'; swarm_roots_register '$T/r2'; swarm_roots_register '$T/r1'; swarm_roots_register '$T/missing'"
eq "registry: deduplicated, physical paths, missing dirs not added" "$T/r1
$T/r2" "$(cat "$T/state/swarm-roots")"
rmdir "$T/r2"
eq "registry list skips roots that no longer exist" "$T/r1" "$(lib swarm_roots_list)"
rm -rf "$T/state"

# ── 2. the sentinel's boot wake ──────────────────────────────────────────────
P="$T/proj"
mkdir -p "$P/.autocoder" "$T/issues"/{open,working,blocked,closed}
git init -q "$P"
printf '{"issueSource":"file","issueDir":"%s"}\n' "$T/issues" > "$P/.autocoder.json"
# Fake recovery: records its call; stamps the boot like the real one unless FAKE_RR_RC is set.
cat > "$T/fake-rr" <<'EOF'
#!/bin/bash
echo "RR $* nested=${AUTOCODER_REBOOT_RECOVER:-}" >> "$FAKE_DIR/rr.calls"
[ -n "${FAKE_RR_RC:-}" ] && exit "$FAKE_RR_RC"
mkdir -p "$AUTOCODER_REBOOT_STATE_DIR" && cat "$AUTOCODER_BOOT_ID_FILE" > "$AUTOCODER_REBOOT_STATE_DIR/last-boot-id"
EOF
chmod +x "$T/fake-rr"
tick() { PATH="$T/bin:$PATH" ISSUE_SOURCE=file AUTOCODER_REBOOT_RECOVER_SCRIPT="$T/fake-rr" bash "$SENTINEL" --once --project "$P" "$@" 2>&1; }
calls() { grep -c . "$T/rr.calls" 2>/dev/null || echo 0; }

echo "boot-1" > "$T/boot_id"
tick >/dev/null
eq "first run records the boot id" "boot-1" "$(cat "$STAMP" 2>/dev/null)"
eq "first run fires no reboot wake" 0 "$(calls)"
tick >/dev/null
eq "unchanged boot id → no reboot wake" 0 "$(calls)"

echo "boot-2" > "$T/boot_id"
tick >/dev/null
eq "changed boot id → exactly one recovery run" 1 "$(calls)"
has "recovery gets --boot and this project" "RR --boot --project $P nested=" "$(cat "$T/rr.calls")"
has "logged as a reboot wake that skips dedup" "WAKE reason=reboot (boot boot-1 -> boot-2; duty wake, dedup skipped)" "$(cat "$P/.autocoder/sentinel.log")"
eq "state records the reboot wake" "reboot" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["last_wake"]["reason"])' "$P/.autocoder/sentinel-state.json")"
tick >/dev/null
eq "next tick, same boot → no second wake" 1 "$(calls)"

echo "boot-3" > "$T/boot_id"
AUTOCODER_REBOOT_RECOVER=1 tick >/dev/null
eq "tick started by reboot-recover.sh skips its own boot wake" 1 "$(calls)"

FAKE_RR_RC=1 tick >/dev/null
eq "failed recovery: called" 2 "$(calls)"
eq "failed recovery leaves the old stamp" "boot-2" "$(cat "$STAMP")"
FAKE_RR_RC=1 tick >/dev/null
eq "failed recovery is retried next tick" 3 "$(calls)"

echo "boot-4" > "$T/boot_id"
OUT=$(tick --dry-run)
has "--dry-run names the reboot wake" "DRY-RUN boot id changed (boot-2 -> boot-4): would run reboot wake" "$OUT"
eq "--dry-run runs no recovery" 3 "$(calls)"
eq "--dry-run leaves the stamp" "boot-2" "$(cat "$STAMP")"

rm -f "$T/boot_id"
OUT=$(tick); RC=$?
eq "no boot id: tick exits 0" 0 "$RC"
eq "no boot id: no reboot wake" 3 "$(calls)"
tick >/dev/null
eq "no boot id: logged once, not every tick" 1 "$(grep -c 'REBOOT check off' "$P/.autocoder/sentinel.log")"

# ── 3. reboot-recover.sh --boot ──────────────────────────────────────────────
rm -rf "$T/state" "$T/rr.calls"
cat > "$T/sentinel-stub" <<'EOF'
#!/bin/bash
echo "SENTINEL $3 recover=${AUTOCODER_REBOOT_RECOVER:-}" >> "$FAKE_DIR/sentinel.calls"
EOF
chmod +x "$T/sentinel-stub"
mkswarm() {
  git init -q "$T/$1"
  git -C "$T/$1" -c user.email=t@e -c user.name=T commit -q --allow-empty -m init
  git -C "$T/$1" worktree add -q -b "wt-$1" "$T/$1-wt-1"
}
mkswarm alpha; mkswarm beta
lib "swarm_roots_register '$T/alpha'; swarm_roots_register '$T/beta'; swarm_roots_register '$T/gone'"
# tmux-only host: a live tmux, a herdr that never answers, no herdr service.
mkdir -p "$T/tmuxbin"
printf '#!/bin/bash\nexit 0\n' > "$T/tmuxbin/tmux"; chmod +x "$T/tmuxbin/tmux"
boot() { PATH="$1:$T/bin:$PATH" AUTOCODER_REBOOT_SENTINEL="$T/sentinel-stub" bash "$RR" --boot "${@:2}" 2>&1; }

echo "new-boot" > "$T/boot_id"
OUT=$(cd "$T" && boot "$T/tmuxbin")
has "no stamp yet: records, recovers nothing" "no boot recorded yet" "$OUT"
eq "no stamp yet: stamp written" "new-boot" "$(cat "$STAMP")"
[ ! -f "$T/sentinel.calls" ] && pass "no stamp yet: no manager started" || fail "managers started on first run"

echo "old-boot" > "$STAMP"
OUT=$(cd "$T" && boot "$T/tmuxbin")
has "tmux host detected" " mux=tmux " "$OUT"
has "detection names scheduler and boot id" "scheduler=systemd-user" "$OUT"
has "herdr installed but no service: not started, said so" "not running and not a user service here; not starting it" "$OUT"
has "registry root alpha recovered" "SENTINEL $T/alpha recover=1" "$(cat "$T/sentinel.calls")"
has "registry root beta recovered" "SENTINEL $T/beta recover=1" "$(cat "$T/sentinel.calls")"
eq "exactly two managers started" 2 "$(grep -c . "$T/sentinel.calls")"
[ -e "$T/alpha/.autocoder/wake" ] && pass "wake file written for the sentinel spawn" || fail "no wake file in alpha"
eq "stamp written after recovery" "new-boot" "$(cat "$STAMP")"
OUT=$(cd "$T" && boot "$T/tmuxbin")
has "second trigger in the same boot does nothing" "already recovered; nothing to do" "$OUT"
eq "second trigger started no manager" 2 "$(grep -c . "$T/sentinel.calls")"

echo "boot-x" > "$T/boot_id"
ln -s "$$ boot-x" "$T/state/reboot-recover.lock"
OUT=$(cd "$T" && boot "$T/tmuxbin")
has "a live lock holder this boot: leave it to finish" "another recovery (pid $$) is running" "$OUT"
eq "locked out: stamp untouched" "new-boot" "$(cat "$STAMP")"
rm -f "$T/state/reboot-recover.lock"; ln -s "999999 boot-x" "$T/state/reboot-recover.lock"
OUT=$(cd "$T" && boot "$T/tmuxbin")
eq "a dead holder's lock is taken over" "boot-x" "$(cat "$STAMP")"
[ ! -L "$T/state/reboot-recover.lock" ] && pass "lock released after the run" || fail "lock left behind"
# A lock left by a crash before the reboot, its pid now reused by a live process.
echo "boot-x2" > "$T/boot_id"
ln -s "$$ boot-x" "$T/state/reboot-recover.lock"
OUT=$(cd "$T" && boot "$T/tmuxbin")
has "a lock from an earlier boot is stale even with a live pid" "removing a stale lock ($$ boot-x)" "$OUT"
eq "...and recovery ran" "boot-x2" "$(cat "$STAMP")"

# A swarm that fails keeps the boot unrecorded; the retry covers only it.
cat > "$T/sentinel-flaky" <<'EOF'
#!/bin/bash
echo "SENTINEL $3" >> "$FAKE_DIR/flaky.calls"
case "$3" in */beta) exit "${BETA_RC:-1}" ;; esac
EOF
chmod +x "$T/sentinel-flaky"
flaky() { PATH="$T/tmuxbin:$T/bin:$PATH" AUTOCODER_REBOOT_SENTINEL="$T/sentinel-flaky" bash "$RR" --boot 2>&1; }
echo "boot-f" > "$T/boot_id"
OUT=$(cd "$T" && flaky)
has "a failed swarm: boot left unrecorded" "1 swarm(s) not recovered (attempt 1 of 3)" "$OUT"
eq "a failed swarm: stamp not written" "boot-x2" "$(cat "$STAMP")"
OUT=$(cd "$T" && flaky)
has "retry skips the swarm already recovered" "$T/alpha: recovered earlier this boot" "$OUT"
eq "retry ran only the failed swarm" "1" "$(grep -c "SENTINEL $T/alpha" "$T/flaky.calls")"
OUT=$(cd "$T" && flaky)
has "after 3 failed attempts the boot is recorded anyway" "still not recovered after 3 attempts" "$OUT"
eq "...stamp written" "boot-f" "$(cat "$STAMP")"
OUT=$(cd "$T" && flaky)
has "...and no more retries" "already recovered; nothing to do" "$OUT"
echo "boot-g" > "$T/boot_id"; : > "$T/flaky.calls"
OUT=$(cd "$T" && BETA_RC=0 flaky)
eq "the next boot starts fresh (both swarms again)" "2" "$(grep -c SENTINEL "$T/flaky.calls")"

# herdr is a user service here but does not answer: wait (0s in tests), report, go on.
echo "boot-y" > "$T/boot_id"
OUT=$(cd "$T" && HERDR_SERVICE=1 AUTOCODER_REBOOT_MUX_WAIT=0 boot "$T/tmuxbin")
has "herdr service silent: waits, reports, continues" "herdr.service did not answer within 0s; continuing without it" "$OUT"
eq "recovery still ran" "boot-y" "$(cat "$STAMP")"

# Boot trigger with a fake herdr holding the two roots (workspaces, no agent
# panes) → a manager started in both; then a sentinel tick sees the same boot.
mkdir -p "$T/herdrbin"
cat > "$T/herdrbin/herdr" <<EOF
#!/bin/bash
case "\$1 \$2" in
  "workspace list") echo '{"result":{"workspaces":[{"cwd":"$T/alpha-wt-1"},{"cwd":"$T/beta"}]}}' ;;
  "agent list") echo '{"result":{"agents":[]}}' ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$T/herdrbin/herdr"
rm -f "$T/state/swarm-roots" "$T/sentinel.calls"
echo "boot-z" > "$T/boot_id"
OUT=$(cd "$T" && boot "$T/herdrbin")
has "herdr host detected" " mux=herdr " "$OUT"
eq "herdr roots: a manager started in both" "SENTINEL $T/alpha recover=1
SENTINEL $T/beta recover=1" "$(sort "$T/sentinel.calls")"
cat > "$T/rr-wrap" <<EOF
#!/bin/bash
echo "WRAP \$*" >> "$T/rr.calls"
exec bash "$RR" "\$@"
EOF
chmod +x "$T/rr-wrap"
PATH="$T/bin:$PATH" ISSUE_SOURCE=file AUTOCODER_REBOOT_RECOVER_SCRIPT="$T/rr-wrap" bash "$SENTINEL" --once --project "$P" >/dev/null 2>&1
[ ! -f "$T/rr.calls" ] && pass "sentinel tick after the boot trigger: same boot, no recovery" || fail "sentinel re-ran recovery: $(cat "$T/rr.calls")"

rm -f "$T/boot_id"
OUT=$(cd "$T" && boot "$T/tmuxbin"); RC=$?
has "--boot with no boot id: skipped, no error" "boot check skipped" "$OUT"
eq "--boot with no boot id exits 0" 0 "$RC"

# ── 4. --install, per host ───────────────────────────────────────────────────
SAFE="$T/safebin"; mkdir -p "$SAFE"
IFS=: read -ra _dirs <<< "$PATH"
for _d in "${_dirs[@]}"; do
  [ -d "$_d" ] || continue
  for _f in "$_d"/*; do
    _n=${_f##*/}
    case "$_n" in crontab|systemctl|loginctl|launchctl|uname|pgrep|herdr|tmux|cmux|sysctl) continue ;; esac
    [ -e "$SAFE/$_n" ] || { [ -x "$_f" ] && [ ! -d "$_f" ] && ln -s "$_f" "$SAFE/$_n" 2>/dev/null; }
  done
done
# hostbin <names...>: a PATH dir holding only the named fakes.
hostbin() { local d="$T/host-$RANDOM$RANDOM" b; mkdir -p "$d"; for b in uname pgrep "$@"; do ln -s "$T/bin/$b" "$d/$b"; done; echo "$d"; }
install_on() {  # install_on <hostbin> [VAR=val...] -- [args]
  local hb="$1"; shift
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift
  env -i HOME="$H" PATH="$hb:$SAFE" FAKE_DIR="$T" CRONTAB_STORE="$T/crontab" \
    AUTOCODER_REBOOT_STATE_DIR="$T/state" AUTOCODER_BOOT_ID_FILE="$T/boot_id" ${envs[@]+"${envs[@]}"} \
    bash "$RR" --install "$@" 2>&1
}
echo "inst-boot" > "$T/boot_id"

# systemd user (Arch, Ubuntu, Fedora...), lingering off.
H="$T/home-sd"; rm -rf "$T/state" "$T/systemctl.calls"; mkdir -p "$H"
HB=$(hostbin systemctl loginctl)
OUT=$(install_on "$HB" FAKE_LINGER=no)
UNIT="$H/.config/systemd/user/autocoder-reboot-recover.service"
has "systemd: detection line" "scheduler=systemd-user linger=no mux=- boot_id=file:$T/boot_id state=$T/state" "$OUT"
[ -f "$UNIT" ] && pass "systemd: unit written" || fail "systemd: no unit: $OUT"
has "systemd: ordered after herdr" "After=herdr.service network-online.target" "$(cat "$UNIT" 2>/dev/null)"
has "systemd: oneshot" "Type=oneshot" "$(cat "$UNIT" 2>/dev/null)"
has "systemd: wanted by default.target" "WantedBy=default.target" "$(cat "$UNIT" 2>/dev/null)"
has "systemd: runs the shim with --boot" "ExecStart=\"$H/.local/bin/autocoder-reboot-recover\" --boot" "$(cat "$UNIT" 2>/dev/null)"
has "systemd: PATH captured at install" "Environment=\"PATH=$HB:$SAFE\"" "$(cat "$UNIT" 2>/dev/null)"
has "systemd: state dir carried (a custom XDG_STATE_HOME still finds the stamp)" "Environment=\"AUTOCODER_REBOOT_STATE_DIR=$T/state\"" "$(cat "$UNIT" 2>/dev/null)"
OUT2=$(install_on "$HB:relative/bin:." -- --dry-run)
hasnt "systemd: relative PATH entries are not baked into the unit" "relative/bin" "$OUT2"
has "systemd: enabled" "--user enable autocoder-reboot-recover.service" "$(cat "$T/systemctl.calls")"
has "systemd: linger off is warned, with the command" "loginctl enable-linger" "$OUT"
eq "install stamps this boot" "inst-boot" "$(cat "$STAMP")"
cmp -s "$SCRIPTS/idle-sentinel-shim.sh" "$H/.local/bin/autocoder-reboot-recover" && [ -x "$H/.local/bin/autocoder-reboot-recover" ] \
  && pass "shim installed, executable" || fail "shim not installed"
mkdir -p "$T/emptycache"
SHIMOUT=$(AUTOCODER_PLUGIN_CACHE="$T/emptycache" AUTOCODER_REBOOT_FALLBACK="$T/fake-rr" FAKE_DIR="$T" "$H/.local/bin/autocoder-reboot-recover" --boot 2>&1; tail -1 "$T/rr.calls" 2>/dev/null)
has "shim under its reboot name runs reboot-recover (fallback)" "RR --boot" "$SHIMOUT"
mkdir -p "$T/cache/mkt/autocoder/9.1.0/scripts"
printf '#!/bin/bash\necho "CACHED-RR $*"\n' > "$T/cache/mkt/autocoder/9.1.0/scripts/reboot-recover.sh"
printf '#!/bin/bash\necho "CACHED-SENTINEL $*"\n' > "$T/cache/mkt/autocoder/9.1.0/scripts/idle-sentinel.sh"
eq "shim under its reboot name resolves the newest plugin's reboot-recover.sh" "CACHED-RR --boot" \
  "$(AUTOCODER_PLUGIN_CACHE="$T/cache" "$H/.local/bin/autocoder-reboot-recover" --boot)"
cp "$H/.local/bin/autocoder-reboot-recover" "$T/autocoder-idle-sentinel"
eq "the same shim under the sentinel name still resolves idle-sentinel.sh" "CACHED-SENTINEL --once" \
  "$(AUTOCODER_PLUGIN_CACHE="$T/cache" "$T/autocoder-idle-sentinel" --once)"
N=$(grep -c daemon-reload "$T/systemctl.calls")
OUT=$(install_on "$HB")
eq "systemd: second install rewrites nothing (no daemon-reload)" "$N" "$(grep -c daemon-reload "$T/systemctl.calls")"

# cron only: WSL without systemd, containers.
H="$T/home-cron"; rm -rf "$T/state"; mkdir -p "$H"
echo "0 * * * * other-job" > "$T/crontab"
HB=$(hostbin crontab)
OUT=$(install_on "$HB")
has "cron: detection line" "scheduler=cron" "$OUT"
eq "cron: one @reboot line, other jobs kept" "2" "$(grep -c . "$T/crontab")"
has "cron: @reboot carries PATH, state dir and fallback, runs the shim with --boot" "@reboot PATH='$HB:$SAFE' AUTOCODER_REBOOT_STATE_DIR='$T/state' AUTOCODER_REBOOT_FALLBACK='$RR' '$H/.local/bin/autocoder-reboot-recover' --boot >> '$T/state/reboot-recover.log' 2>&1 # autocoder-reboot-recover" "$(cat "$T/crontab")"
eq "state dir is private (0700)" "700" "$(stat -c %a "$T/state" 2>/dev/null || stat -f %Lp "$T/state")"
install_on "$HB" >/dev/null
eq "cron: second install adds nothing" "2" "$(grep -c . "$T/crontab")"
[ ! -e "$H/.config/systemd" ] && pass "cron: no systemd unit" || fail "cron: unit written"

# macOS: launchd agent with RunAtLoad.
H="$T/home-mac"; rm -rf "$T/state" "$T/launchctl.calls"; mkdir -p "$H"
HB=$(hostbin launchctl crontab sysctl)
rm -f "$T/crontab"
OUT=$(install_on "$HB" FAKE_UNAME=Darwin AUTOCODER_BOOT_ID_FILE="$T/no-such-file")
has "macOS: detection line" "os=macos scheduler=launchd linger=n/a mux=- boot_id=kern.boottime" "$OUT"
PL="$H/Library/LaunchAgents/com.autocoder.reboot-recover.plist"
eq "macOS: plist parses; RunAtLoad; shim --boot; PATH" "True True ['--boot'] True" "$(python3 - "$PL" <<'PY' 2>&1
import plistlib, sys
d = plistlib.load(open(sys.argv[1], "rb"))
print(d["RunAtLoad"], d["ProgramArguments"][0].endswith("/.local/bin/autocoder-reboot-recover"), d["ProgramArguments"][1:], "PATH" in d["EnvironmentVariables"])
PY
)"
has "macOS: loaded with launchctl bootstrap" "bootstrap gui/" "$(cat "$T/launchctl.calls" 2>/dev/null)"
[ ! -s "$T/crontab" ] && pass "macOS: no cron entry" || fail "macOS: cron entry written"
eq "macOS: install stamps kern.boottime" "1700000000.42" "$(cat "$STAMP")"

# Nothing to schedule with.
H="$T/home-none"; rm -rf "$T/state"; mkdir -p "$H"
HB=$(hostbin)
OUT=$(install_on "$HB"); RC=$?
has "no scheduler: said so" "No boot scheduler on this host" "$OUT"
eq "no scheduler: exit 0" 0 "$RC"
[ ! -e "$H/.local/bin/autocoder-reboot-recover" ] && pass "no scheduler: nothing installed" || fail "no scheduler: shim installed"

# --dry-run writes nothing.
H="$T/home-dry"; rm -rf "$T/state" "$T/systemctl.calls"; mkdir -p "$H"
HB=$(hostbin systemctl loginctl)
OUT=$(install_on "$HB" -- --dry-run)
has "dry run prints the unit" "DRY-RUN would write $H/.config/systemd/user/autocoder-reboot-recover.service" "$OUT"
[ ! -e "$H/.config" ] && [ ! -e "$H/.local" ] && [ ! -e "$T/state" ] && pass "dry run writes nothing" || fail "dry run wrote files"
hasnt "dry run enables nothing" "enable" "$(cat "$T/systemctl.calls" 2>/dev/null)"

# --ensure honours AUTOCODER_BOOT_TRIGGER=off.
H="$T/home-off"; rm -rf "$T/state" "$T/systemctl.calls"; mkdir -p "$H" "$T/offproj"
git init -q "$T/offproj"
HB=$(hostbin systemctl loginctl)
OUT=$(env -i HOME="$H" PATH="$HB:$SAFE" FAKE_DIR="$T" AUTOCODER_REBOOT_STATE_DIR="$T/state" AUTOCODER_BOOT_ID_FILE="$T/boot_id" \
  AUTOCODER_BOOT_TRIGGER=off bash "$SENTINEL" --ensure --dry-run --project "$T/offproj" 2>&1)
has "--ensure with AUTOCODER_BOOT_TRIGGER=off installs no boot trigger" "AUTOCODER_BOOT_TRIGGER=off: no host boot trigger installed" "$OUT"
hasnt "...and does not plan one" "autocoder-reboot-recover.service" "$OUT"
OUT=$(env -i HOME="$H" PATH="$HB:$SAFE" FAKE_DIR="$T" AUTOCODER_REBOOT_STATE_DIR="$T/state" AUTOCODER_BOOT_ID_FILE="$T/boot_id" \
  bash "$SENTINEL" --ensure --dry-run --project "$T/offproj" 2>&1)
has "--ensure plans the boot trigger by default" "DRY-RUN would write $H/.config/systemd/user/autocoder-reboot-recover.service" "$OUT"

# ── 5. swarm creation registers the root ─────────────────────────────────────
rm -rf "$T/state"
(cd "$T/alpha-wt-1" && bash "$SCRIPTS/swarm-register.sh" >/dev/null 2>&1)
eq "swarm-register.sh registers the main checkout" "$T/alpha" "$(cat "$T/state/swarm-roots" 2>/dev/null)"
for s in start-parallel-agents.sh add-worker.sh; do
  grep -q 'swarm_roots_register "\$PROJECT_ROOT"' "$SCRIPTS/$s" && pass "$s registers its root" || fail "$s does not register"
done

echo ""
echo "$PASS passed / $FAIL failed / $((PASS + FAIL)) total"
[ "$FAIL" -eq 0 ]
