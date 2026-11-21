#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255: never write the real event logs
# tests/test_idle_sentinel_systemd.sh — idle-sentinel --ensure on a host with
# no crontab (#273): systemd user timer + version-independent shim, the
# Linger warning, stale-loop replacement, and the detached-loop last resort.
#
# Isolation rules (hard):
#   - the sentinel runs under `env -i` with HOME in a scratch dir, so units
#     and the shim land under $TMP, never in the operator's ~/.config;
#   - PATH is a curated symlink farm of the real PATH MINUS crontab,
#     systemctl and loginctl, with fakes for the last two in front: nothing
#     here can reach the real user manager or crontab.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
SCRIPTS="$ROOT/plugins/autocoder/scripts"
SENTINEL="$SCRIPTS/idle-sentinel.sh"
SHIM_SRC="$SCRIPTS/idle-sentinel-shim.sh"

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

if [ ! -d /proc/self ]; then
  echo "SKIP: this suite reads /proc to find running loops"
  echo "Results: 0 passed, 0 failed"
  exit 0
fi

TMP=$(mktemp -d /tmp/idsys.XXXXXX)
FAKEHOME="$TMP/home"
FAKESYS="$TMP/fakesys"     # fake systemctl + loginctl
SAFEBIN="$TMP/bin"         # real PATH minus crontab/systemctl/loginctl
SYSD="$TMP/sysd"           # fake systemctl state
mkdir -p "$FAKEHOME" "$FAKESYS" "$SAFEBIN" "$SYSD"

CLEANUP_PIDS=()
cleanup() {
  local p
  for p in "${CLEANUP_PIDS[@]}"; do
    pkill -P "$p" 2>/dev/null
    kill "$p" 2>/dev/null
  done
  rm -rf "$TMP"
}
trap cleanup EXIT

IFS=: read -ra _dirs <<< "$PATH"
for _d in "${_dirs[@]}"; do
  [ -d "$_d" ] || continue
  for _f in "$_d"/*; do
    _n=${_f##*/}
    case "$_n" in crontab|systemctl|loginctl) continue ;; esac
    [ -e "$SAFEBIN/$_n" ] && continue
    [ -x "$_f" ] && [ ! -d "$_f" ] && ln -s "$_f" "$SAFEBIN/$_n" 2>/dev/null
  done
done

# Fake systemctl: SYSTEMCTL_DOWN=1 makes the user manager unreachable;
# enable --now records the timer, list-timers prints the recorded ones.
cat > "$FAKESYS/systemctl" <<'EOF'
#!/bin/bash
echo "$*" >> "$SYSD/calls"
[ "$1" = "--user" ] || exit 1
shift
case "$1" in
  show-environment) [ "${SYSTEMCTL_DOWN:-0}" = 1 ] && exit 1; echo "HOME=$HOME"; exit 0 ;;
  daemon-reload) exit 0 ;;
  enable)
    shift; [ "$1" = "--now" ] && shift
    echo "$1" >> "$SYSD/enabled"; exit 0 ;;
  list-timers)
    [ "${SYSTEMCTL_DOWN:-0}" = 1 ] && exit 1
    echo "NEXT LEFT LAST PASSED UNIT ACTIVATES"
    [ -f "$SYSD/enabled" ] && sed 's/^/- - - - /' "$SYSD/enabled"
    exit 0 ;;
esac
exit 0
EOF
cat > "$FAKESYS/loginctl" <<'EOF'
#!/bin/bash
echo "Linger=${FAKE_LINGER:-yes}"
EOF
chmod +x "$FAKESYS/systemctl" "$FAKESYS/loginctl"
TESTPATH="$FAKESYS:$SAFEBIN"

new_project() {
  local dir
  dir=$(mktemp -d "$TMP/${1}XXXXXX") || return 1
  git init -q "$dir"
  mkdir -p "$dir/.issues"
  printf '{"issueSource":"file","issueDir":"%s"}\n' "$dir/.issues" > "$dir/.autocoder.json"
  echo "$dir"
}

# run_sentinel_at <script> [VAR=val ...] -- <args...>
run_sentinel_at() {
  local script="$1"; shift
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  env -i HOME="$FAKEHOME" PATH="$TESTPATH" SYSD="$SYSD" TERM=xterm "${envs[@]}" \
    bash "$script" "$@"
}

state_mode() {
  python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("scheduler_mode",""))
except Exception: pass' "$1/.autocoder/sentinel-state.json"
}

unit_for() {
  printf 'autocoder-idle-sentinel-%s' \
    "$(printf '%s' "$1" | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest()[:12])')"
}

reset_sysd() { rm -f "$SYSD/calls" "$SYSD/enabled"; rm -rf "$FAKEHOME/.config" "$FAKEHOME/.local"; }

command -v crontab >/dev/null 2>&1 && PATH="$TESTPATH" command -v crontab >/dev/null 2>&1 \
  && bad "test PATH still has a crontab" || ok "test PATH has no crontab"

# ── 1. no crontab + working systemctl --user → timer + service ──────────────
reset_sysd
P=$(new_project sys)
UNIT=$(unit_for "$P")
UDIR="$FAKEHOME/.config/systemd/user"
OUT=$(run_sentinel_at "$SENTINEL" -- --ensure --project "$P" 2>&1)
echo "$OUT" | grep -q "scheduled via systemd" \
  && ok "--ensure reports scheduled via systemd" || bad "no systemd report: $OUT"
[ -f "$UDIR/$UNIT.timer" ] && [ -f "$UDIR/$UNIT.service" ] \
  && ok "timer and service written under ~/.config/systemd/user" \
  || bad "unit files missing in $UDIR: $(ls "$UDIR" 2>&1)"
grep -qx "OnBootSec=2min" "$UDIR/$UNIT.timer" && grep -qx "OnUnitInactiveSec=900s" "$UDIR/$UNIT.timer" \
  && ok "timer has OnBootSec and OnUnitInactiveSec=<interval>" \
  || bad "timer contents: $(cat "$UDIR/$UNIT.timer" 2>&1)"
grep -q "daemon-reload" "$SYSD/calls" && grep -qx -- "--user enable --now $UNIT.timer" "$SYSD/calls" \
  && ok "daemon-reload, then enable --now the timer" || bad "systemctl calls: $(cat "$SYSD/calls" 2>&1)"
SHIM="$FAKEHOME/.local/bin/autocoder-idle-sentinel"
[ -x "$SHIM" ] && cmp -s "$SHIM" "$SHIM_SRC" \
  && ok "version-independent shim installed in ~/.local/bin" || bad "shim missing or differs: $SHIM"
EXEC=$(grep '^ExecStart=' "$UDIR/$UNIT.service")
[ "$EXEC" = "ExecStart=\"$SHIM\" --once --project \"$P\"" ] \
  && ok "ExecStart runs the shim, not a versioned script path" || bad "ExecStart: $EXEC"
grep -qxF "Environment=\"PATH=$TESTPATH\"" "$UDIR/$UNIT.service" \
  && ok "service carries the PATH --ensure ran with" || bad "no PATH in service: $(cat "$UDIR/$UNIT.service")"
[ "$(state_mode "$P")" = systemd ] && ok "scheduler_mode=systemd recorded" \
  || bad "scheduler_mode=$(state_mode "$P")"

OUT=$(run_sentinel_at "$SENTINEL" -- --ensure --project "$P" 2>&1)
echo "$OUT" | grep -q "already scheduled via systemd" \
  && ok "second --ensure is idempotent (already scheduled via systemd)" || bad "second run: $OUT"
[ "$(grep -c -- "enable --now" "$SYSD/calls")" = 1 ] \
  && ok "second --ensure did not enable again" || bad "enable calls: $(cat "$SYSD/calls")"

# A changed shim is refreshed by --ensure on an already-scheduled host.
echo "# stale" >> "$SHIM"
run_sentinel_at "$SENTINEL" -- --ensure --project "$P" >/dev/null 2>&1
cmp -s "$SHIM" "$SHIM_SRC" && ok "--ensure refreshes an outdated shim" || bad "shim not refreshed"

# ── 2. Linger ────────────────────────────────────────────────────────────────
reset_sysd
P=$(new_project lingeroff)
OUT=$(run_sentinel_at "$SENTINEL" FAKE_LINGER=no -- --ensure --project "$P" 2>&1)
echo "$OUT" | grep -q "Lingering is off" && echo "$OUT" | grep -q "loginctl enable-linger" \
  && ok "Linger=no → warning with the fix" || bad "no linger warning: $OUT"
reset_sysd
P=$(new_project lingeron)
OUT=$(run_sentinel_at "$SENTINEL" FAKE_LINGER=yes -- --ensure --project "$P" 2>&1)
echo "$OUT" | grep -q "Lingering is off" && bad "linger warning with Linger=yes: $OUT" \
  || ok "Linger=yes → no warning"

# ── 3. --dry-run prints the units, installs nothing ─────────────────────────
reset_sysd
P=$(new_project dry)
OUT=$(run_sentinel_at "$SENTINEL" -- --ensure --dry-run --project "$P" 2>&1)
echo "$OUT" | grep -q "OnUnitInactiveSec=900s" && echo "$OUT" | grep -q "ExecStart=" \
  && ok "--dry-run prints the unit files" || bad "dry-run output: $OUT"
[ ! -e "$FAKEHOME/.config/systemd" ] && [ ! -e "$FAKEHOME/.local/bin/autocoder-idle-sentinel" ] \
  && ! grep -q "enable" "$SYSD/calls" 2>/dev/null \
  && ok "--dry-run wrote no units, no shim, enabled nothing" || bad "dry-run side effects"

# ── 4. a path that needs unit-file escaping ─────────────────────────────────
reset_sysd
QDIR="$TMP/it's 100% \$HOME \"q\" proj"
git init -q "$QDIR"; mkdir -p "$QDIR/.issues"
python3 -c 'import json,sys; json.dump({"issueSource":"file","issueDir":sys.argv[1]}, open(sys.argv[2],"w"))' \
  "$QDIR/.issues" "$QDIR/.autocoder.json"
run_sentinel_at "$SENTINEL" -- --ensure --project "$QDIR" >/dev/null 2>&1
EXEC=$(grep '^ExecStart=' "$FAKEHOME/.config/systemd/user/$(unit_for "$QDIR").service" 2>/dev/null)
case "$EXEC" in
  *'"'"$TMP/it's 100%% \$\$HOME \\\"q\\\" proj"'"') ok "% \$ and \" in the project path are unit-escaped" ;;
  *) bad "escaped ExecStart: $EXEC" ;;
esac

if command -v systemd-analyze >/dev/null 2>&1; then
  V=$(systemd-analyze verify "$FAKEHOME/.config/systemd/user/$(unit_for "$QDIR").service" 2>&1)
  [ -z "$V" ] && ok "systemd-analyze verify accepts the escaped service" || bad "systemd-analyze: $V"
fi

# A shim path systemd will not execute (' " or \) is refused; --ensure falls
# back to the loop instead of enabling a timer that can never start.
reset_sysd
P=$(new_project badshim)
OUT=$(run_sentinel_at "$SENTINEL" AUTOCODER_SENTINEL_SHIM="$TMP/it's/shim" AUTOCODER_SENTINEL_INTERVAL=120 \
  -- --ensure --project "$P" 2>&1)
LPID=$(echo "$OUT" | sed -nE 's/.*started a detached --loop \(pid ([0-9]+)\).*/\1/p')
[ -n "$LPID" ] && CLEANUP_PIDS+=("$LPID")
echo "$OUT" | grep -q "systemd will not run" && echo "$OUT" | grep -q "started a detached --loop" \
  && ! grep -q "enable" "$SYSD/calls" 2>/dev/null \
  && ok "unrunnable shim path → refused, falls back to the loop" || bad "bad shim path: $OUT"
if [ -n "$LPID" ]; then pkill -P "$LPID" 2>/dev/null; kill "$LPID" 2>/dev/null; fi

# ── 5. neither cron nor systemd → detached loop, as before ──────────────────
reset_sysd
P=$(new_project noloop)
OUT=$(run_sentinel_at "$SENTINEL" SYSTEMCTL_DOWN=1 AUTOCODER_SENTINEL_INTERVAL=120 -- --ensure --project "$P" 2>&1)
LPID=$(echo "$OUT" | sed -nE 's/.*started a detached --loop \(pid ([0-9]+)\).*/\1/p')
[ -n "$LPID" ] && CLEANUP_PIDS+=("$LPID")
echo "$OUT" | grep -q "started a detached --loop" \
  && ok "no cron + no systemd → detached --loop" || bad "loop fallback: $OUT"
[ ! -e "$FAKEHOME/.config/systemd" ] && ok "no unit written without a user manager" || bad "units written"
if [ -n "$LPID" ]; then pkill -P "$LPID" 2>/dev/null; kill "$LPID" 2>/dev/null; fi

# ── 6. a --loop from an older plugin version is replaced ────────────────────
CACHE="$TMP/cache/mkt/autocoder"
mkdir -p "$CACHE/4.35.0" "$CACHE/4.40.1"
cp -r "$SCRIPTS" "$CACHE/4.35.0/scripts"
cp -r "$SCRIPTS" "$CACHE/4.40.1/scripts"
OLD="$CACHE/4.35.0/scripts/idle-sentinel.sh"
NEW="$CACHE/4.40.1/scripts/idle-sentinel.sh"

start_loop() {  # start_loop <script> <project> → sets LOOPPID
  env -i HOME="$FAKEHOME" PATH="$TESTPATH" SYSD="$SYSD" TERM=xterm SYSTEMCTL_DOWN=1 \
    AUTOCODER_SENTINEL_INTERVAL=120 bash "$1" --loop --project "$2" </dev/null >/dev/null 2>&1 &
  LOOPPID=$!
  CLEANUP_PIDS+=("$LOOPPID")
  sleep 1.5
}

reset_sysd
P=$(new_project stale)
start_loop "$OLD" "$P"
kill -0 "$LOOPPID" 2>/dev/null && ok "old-version loop running" || bad "old loop did not start"
OUT=$(run_sentinel_at "$NEW" -- --ensure --project "$P" 2>&1)
echo "$OUT" | grep -q "Stopped the --loop (pid $LOOPPID)" \
  && ok "--ensure stops the --loop running an older plugin version" || bad "stale loop not replaced: $OUT"
sleep 0.5
kill -0 "$LOOPPID" 2>/dev/null && bad "old loop still alive" || ok "old loop is gone"
echo "$OUT" | grep -q "scheduled via systemd" \
  && ok "…and the timer replaces it" || bad "no timer after replacement: $OUT"

reset_sysd
P=$(new_project same)
start_loop "$NEW" "$P"
OUT=$(run_sentinel_at "$NEW" -- --ensure --project "$P" 2>&1)
echo "$OUT" | grep -q "already scheduled via loop" && kill -0 "$LOOPPID" 2>/dev/null \
  && ok "a same-version loop is left alone" || bad "same-version loop: $OUT"
pkill -P "$LOOPPID" 2>/dev/null; kill "$LOOPPID" 2>/dev/null

reset_sysd
P=$(new_project dryst)
start_loop "$OLD" "$P"
OUT=$(run_sentinel_at "$NEW" -- --ensure --dry-run --project "$P" 2>&1)
echo "$OUT" | grep -q "DRY-RUN would stop the --loop (pid $LOOPPID)" && kill -0 "$LOOPPID" 2>/dev/null \
  && ok "--dry-run names the stale loop and leaves it running" || bad "dry-run stale loop: $OUT"
pkill -P "$LOOPPID" 2>/dev/null; kill "$LOOPPID" 2>/dev/null

# ── 7. the shim resolves the sentinel at run time ───────────────────────────
SC="$TMP/shimcache"
mkcached() {  # mkcached <marketplace> <version>
  mkdir -p "$SC/$1/autocoder/$2/scripts"
  printf '#!/bin/bash\necho "cache %s %s $*"\n' "$1" "$2" > "$SC/$1/autocoder/$2/scripts/idle-sentinel.sh"
}
mkcached zzz-mkt 1.9.0
mkcached aaa-mkt 1.10.0
mkcached zzz-mkt not-a-version
SP="$TMP/shimproj"
mkdir -p "$SP/.agent/scripts"
printf '#!/bin/bash\necho "project $*"\n' > "$SP/.agent/scripts/idle-sentinel.sh"
: > "$SP/.agent/scripts/issue-fns.sh"
run_shim() { env -i HOME="$FAKEHOME" PATH="$SAFEBIN" "$@"; }

OUT=$(run_shim AUTOCODER_PLUGIN_CACHE="$SC" bash "$SHIM_SRC" --once --project "$SP")
[ "$OUT" = "cache aaa-mkt 1.10.0 --once --project $SP" ] \
  && ok "shim: newest version by sort -V on the version, whatever the marketplace name" \
  || bad "shim newest: $OUT"
case "$OUT" in project*) bad "shim ran the project's vendored copy" ;; *) ok "shim: a project's vendored tree is never run" ;; esac
printf '#!/bin/bash\necho "override $*"\n' > "$TMP/override.sh"
OUT=$(run_shim AUTOCODER_SENTINEL_SCRIPT="$TMP/override.sh" AUTOCODER_PLUGIN_CACHE="$TMP/shimcache" \
  bash "$SHIM_SRC" --once --project "$SP")
[ "$OUT" = "override --once --project $SP" ] && ok "shim: AUTOCODER_SENTINEL_SCRIPT overrides" \
  || bad "shim override: $OUT"
OUT=$(run_shim AUTOCODER_PLUGIN_CACHE="$TMP/none" AUTOCODER_SENTINEL_FALLBACK="$TMP/override.sh" \
  bash "$SHIM_SRC" --once --project "$TMP/nowhere")
[ "$OUT" = "override --once --project $TMP/nowhere" ] && ok "shim: fallback used only when nothing else exists" \
  || bad "shim fallback: $OUT"
run_shim AUTOCODER_PLUGIN_CACHE="$TMP/none" bash "$SHIM_SRC" --once --project "$TMP/nowhere" >/dev/null 2>&1
[ $? -ne 0 ] && ok "shim: exits non-zero when no sentinel is found" || bad "shim found nothing but exited 0"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
