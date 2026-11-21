#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255: never write the real event logs
# tests/test_reboot_recover.sh: reboot-recover.sh starts exactly one manager per
# swarm after a host reboot (#274, part of #271).
#
# herdr is a stub: `agent list` prints $HERDR_DIR/agents.json, `pane get <p>`
# reports the cwd in $HERDR_DIR/cwd-<p>, and every `agent prompt` is recorded.
# The sentinel is a stub (AUTOCODER_REBOOT_SENTINEL) that records how it was
# called. Covered hosts: herdr live, tmux only (panes never survive a reboot, so
# always spawned), and no multiplexer at all.

set -u
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/plugins/autocoder/scripts/reboot-recover.sh"

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
has()  { if printf '%s' "$3" | grep -qF -- "$2"; then pass "$1"; else fail "$1: '$2' not in: $3"; fi; }
hasnt(){ if printf '%s' "$3" | grep -qF -- "$2"; then fail "$1: unexpected '$2' in: $3"; else pass "$1"; fi; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
T=$(cd "$T" && pwd -P)
mkdir -p "$T/herdrbin" "$T/tmuxbin" "$T/nobin" "$T/state"

cat > "$T/herdrbin/herdr" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$HERDR_DIR/argv"
case "$1 $2" in
  "workspace list") echo '{"result":{"workspaces":[]}}' ;;
  "agent list")     cat "$HERDR_DIR/agents.json" ;;
  "pane get")       printf '{"result":{"pane":{"pane_id":"%s","foreground_cwd":"%s"}}}\n' "$3" "$(cat "$HERDR_DIR/cwd-${3//:/_}")" ;;
  "pane read")      echo "❯ " ;;
  "agent prompt")   printf 'PROMPT %s %s\n' "$3" "$4" >> "$HERDR_DIR/prompts" ;;
  *) exit 0 ;;
esac
STUB
# Hosts without herdr: a herdr that never answers, ahead of any real one.
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$HERDR_DIR/argv"\nexit 1\n' > "$T/tmuxbin/herdr"
cp "$T/tmuxbin/herdr" "$T/nobin/herdr"
printf '#!/bin/bash\nprintf "tmux %%s\\n" "$*" >> "$HERDR_DIR/argv"\nexit 0\n' > "$T/tmuxbin/tmux"
printf '#!/bin/bash\nexit 1\n' > "$T/nobin/tmux"
printf '#!/bin/bash\nexit 1\n' > "$T/nobin/cmux"; cp "$T/nobin/cmux" "$T/tmuxbin/cmux"; cp "$T/nobin/cmux" "$T/herdrbin/cmux"
cat > "$T/sentinel" <<'STUB'
#!/bin/bash
printf 'SENTINEL %s recover=%s wake=%s\n' "$*" "${AUTOCODER_REBOOT_RECOVER:-}" \
  "$([ -e "${3:-x}/.autocoder/wake" ] && echo present || echo absent)" >> "$HERDR_DIR/sentinel"
exit "${SENTINEL_RC:-0}"
STUB
chmod +x "$T"/herdrbin/* "$T"/tmuxbin/* "$T"/nobin/* "$T/sentinel"

export HERDR_DIR="$T/state" AUTOCODER_REBOOT_SENTINEL="$T/sentinel" AUTOCODER_MUX_SUBMIT_DELAY=0 \
  AUTOCODER_HERDR_PROBE_SECONDS=2 AUTOCODER_MUX_TIMEOUT_SECONDS=5
unset HERDR_PANE_ID AUTOCODER_AGENT

mkrepo() {  # mkrepo <name> <worktree-suffix>...
  local name="$1"; shift
  git init -q "$T/$name"
  git -C "$T/$name" -c user.email=t@e -c user.name=T commit -q --allow-empty -m init
  for s in "$@"; do git -C "$T/$name" worktree add -q -b "b-$name-$s" "$T/$name-$s"; done
}
setup() {
  rm -rf "$T"/alpha* "$T"/beta* "$T"/gamma* "$T/state"/*
  mkrepo alpha wt-1 wt-2   # swarm with a restored manager pane
  mkrepo beta  wt-1        # swarm without one
  mkrepo gamma scratch     # worktree not named <repo>-wt-*: not a swarm
  : > "$HERDR_DIR/prompts"; : > "$HERDR_DIR/argv"; : > "$HERDR_DIR/sentinel"
}
agents() {  # agents <pane>=<dir>...
  local spec list=""
  for spec in "$@"; do
    printf '%s' "${spec#*=}" > "$HERDR_DIR/cwd-$(printf '%s' "${spec%%=*}" | tr ':' '_')"
    list="$list${list:+,}{\"pane_id\":\"${spec%%=*}\",\"agent_status\":\"idle\"}"
  done
  printf '{"result":{"agents":[%s]}}\n' "$list" > "$HERDR_DIR/agents.json"
}
manifest() {  # manifest <repo> <state> [agent]
  mkdir -p "$T/$1/.autocoder/swarm"
  printf '{"session":"s","state":"%s","agent":"%s"}\n' "$2" "${3:-claude}" > "$T/$1/.autocoder/swarm/s.json"
}
run() { local bin="$1"; shift; PATH="$bin:$PATH" bash "$SCRIPT" "$@" 2>&1; }

# ── 1. herdr: two swarms, one restored manager, one non-swarm repo ───────────
setup
agents "w0:p1=$T/alpha" "w1:p1=$T/alpha-wt-1" "w2:p1=$T/beta-wt-1" "w3:p1=$T/gamma"
OUT=$(run "$T/herdrbin"); RC=$?
P=$(cat "$HERDR_DIR/prompts"); S=$(cat "$HERDR_DIR/sentinel"); A=$(cat "$HERDR_DIR/argv")
[ "$RC" -eq 0 ] && pass "exits 0" || fail "rc=$RC: $OUT"
has "host detection is printed" " mux=herdr " "$OUT"
has "restored manager pane in alpha's root is prompted" "PROMPT w0:p1 Run /autocoder:manager-resume --non-interactive" "$P"
has "manager prompt chains monitor-loop" "Then run /autocoder:monitor-loop" "$P"
[ "$(grep -c PROMPT "$HERDR_DIR/prompts")" -eq 1 ] && pass "only one prompt sent (no worker driven)" || fail "prompts: $P"
hasnt "alpha is not handed to the sentinel (not duplicated)" "--project $T/alpha " "$S "
has "beta (no manager pane) is started through the sentinel" "SENTINEL --once --project $T/beta" "$S"
has "the sentinel run is marked as reboot recovery" "recover=1" "$S"
has "the wake file exists when the sentinel runs" "wake=present" "$S"
[ "$(grep -c SENTINEL "$HERDR_DIR/sentinel")" -eq 1 ] && pass "exactly one sentinel spawn" || fail "sentinel calls: $S"
hasnt "gamma (no <repo>-wt-* worktree) gets no manager" "gamma" "$P$S"
hasnt "no workspace created by the script" "workspace create" "$A"
hasnt "no agent started by the script" "agent start" "$A"
has "summary" "managers prompted=1 started=1 skipped(paused)=0 problems=0" "$OUT"

# Worktree panes alone also lead to their swarm (beta found via beta-wt-1 above).
has "swarm found from a worker pane's cwd" "swarm $T/beta" "$OUT"

# ── 2. Paused manifest: skipped ──────────────────────────────────────────────
setup
manifest beta paused
agents "w0:p1=$T/alpha" "w2:p1=$T/beta-wt-1"
OUT=$(run "$T/herdrbin")
has "paused swarm reported" "$T/beta: paused (manifest); skipped" "$OUT"
hasnt "paused swarm not started" "beta" "$(cat "$HERDR_DIR/sentinel")"
[ ! -e "$T/beta/.autocoder/wake" ] && pass "paused swarm gets no wake file" || fail "wake file written for a paused swarm"
manifest beta running
OUT=$(run "$T/herdrbin")
has "running manifest is not skipped" "SENTINEL --once --project $T/beta" "$(cat "$HERDR_DIR/sentinel")"

# ── 3. --dry-run changes nothing ─────────────────────────────────────────────
setup
agents "w0:p1=$T/alpha" "w2:p1=$T/beta-wt-1"
OUT=$(run "$T/herdrbin" --dry-run)
[ ! -s "$HERDR_DIR/prompts" ] && pass "dry run prompts nothing" || fail "dry run prompted: $(cat "$HERDR_DIR/prompts")"
[ ! -s "$HERDR_DIR/sentinel" ] && pass "dry run runs no sentinel" || fail "dry run ran the sentinel"
[ ! -e "$T/beta/.autocoder/wake" ] && pass "dry run writes no wake file" || fail "dry run wrote a wake file"
has "dry run lists alpha" "swarm $T/alpha" "$OUT"
has "dry run says it would prompt alpha's pane" "DRY-RUN would prompt restored manager pane w0:p1" "$OUT"
has "dry run says it would start beta" "DRY-RUN would create $T/beta/.autocoder/wake" "$OUT"

# ── 4. Two agents in one root: neither prompted, nothing spawned ─────────────
setup
agents "w0:p1=$T/alpha" "w0:p2=$T/alpha"
OUT=$(run "$T/herdrbin")
[ ! -s "$HERDR_DIR/prompts" ] && pass "duplicate managers: none prompted" || fail "prompted: $(cat "$HERDR_DIR/prompts")"
hasnt "duplicate managers: no spawn" "alpha" "$(cat "$HERDR_DIR/sentinel")"
has "duplicate managers reported" "2 agent panes in $T/alpha" "$OUT"

# ── 5. tmux host: never adopted, always spawned via the sentinel ─────────────
setup
OUT=$(run "$T/tmuxbin" --project "$T/alpha-wt-2" --project "$T/beta")
has "tmux detected" " mux=tmux " "$OUT"
S=$(cat "$HERDR_DIR/sentinel")
has "tmux: alpha started via the sentinel (from a worktree path)" "--project $T/alpha" "$S"
has "tmux: beta started via the sentinel" "--project $T/beta" "$S"
[ ! -s "$HERDR_DIR/prompts" ] && pass "tmux: no pane prompted" || fail "tmux prompted a pane"
hasnt "tmux: herdr asked nothing beyond the probe" "agent" "$(cat "$HERDR_DIR/argv")"

# ── 6. No multiplexer at all: the sentinel decides (it reports what it lacks) ──
setup
OUT=$(run "$T/nobin" --project "$T/beta")
has "no mux detected" " mux=none " "$OUT"
has "no mux: sentinel still asked to start beta" "--project $T/beta" "$(cat "$HERDR_DIR/sentinel")"
setup
OUT=$(SENTINEL_RC=1 run "$T/nobin" --project "$T/beta")
has "a failed sentinel run is reported" "did not start a manager in $T/beta" "$OUT"
has "a failed sentinel run is counted" "problems=1" "$OUT"

# ── 7. Agent kind from the manifest: bare command names for non-claude ───────
setup
manifest alpha running gemini
agents "w0:p1=$T/alpha"
run "$T/herdrbin" >/dev/null
has "gemini manager gets bare names" "PROMPT w0:p1 Run /manager-resume --non-interactive" "$(cat "$HERDR_DIR/prompts")"

# ── 8. Not a swarm / usage ───────────────────────────────────────────────────
setup
OUT=$(run "$T/nobin" --project "$T/gamma")
[ ! -s "$HERDR_DIR/sentinel" ] && pass "repo without <repo>-wt-* worktrees: nothing started" || fail "started: $(cat "$HERDR_DIR/sentinel")"
OUT=$(run "$T/nobin" --project /nonexistent-dir); RC=$?
[ "$RC" -eq 0 ] && [ ! -s "$HERDR_DIR/sentinel" ] && pass "a non-repo directory is ignored" || fail "rc=$RC: $OUT"
OUT=$(bash "$SCRIPT" --bogus 2>&1); RC=$?
[ "$RC" -eq 1 ] && pass "unknown argument exits 1" || fail "rc=$RC"

echo ""
echo "$PASS passed / $FAIL failed / $((PASS + FAIL)) total"
[ "$FAIL" -eq 0 ]
