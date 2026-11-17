#!/bin/bash
# tests/test_autocoder_ctl.sh — autocoder-ctl.sh, the one command surface for UIs (#243).
#
# The contract: every invocation prints exactly one JSON object
# {ok, action, target, detail} on stdout and exits 0 ok / 1 failed / 2 usage /
# 3 not implemented. release goes through issue_release and comments with actor
# and reason, run against the file backend in a private temp repo (never the real
# tracker). status reads a swarm manifest and asks a stubbed worker-idle.sh about
# each pane.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$ROOT/plugins/autocoder/scripts"
CTL="$SCRIPTS/autocoder-ctl.sh"
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
unset ISSUE_SOURCE ISSUE_BACKEND ISSUE_DIR

# run <expected-rc> <expected-ok> <name> -- <ctl> <args...>
# Checks: the exit code, stdout is exactly one line holding one JSON object with
# the four keys, ok matches, action is the verb. Leaves the object in $OUT.
run() {
  local want_rc="$1" want_ok="$2" name="$3"; shift 4
  OUT=$("$@" 2>"$TMP/stderr"); local rc=$?
  if [ "$rc" -ne "$want_rc" ]; then bad "$name: exit $rc, want $want_rc (out: $OUT)"; return 1; fi
  if [ "$(printf '%s\n' "$OUT" | wc -l)" -ne 1 ] \
     || ! printf '%s' "$OUT" | jq -e --argjson ok "$want_ok" \
          'type == "object" and (keys == ["action","detail","ok","target"]) and .ok == $ok' >/dev/null 2>&1; then
    bad "$name: not one result object with ok=$want_ok: $OUT"; return 1
  fi
  ok "$name"
}

# ── Contract: usage, unknown verbs, missing arguments ─────────────────────────
run 2 false "no verb is a usage error"                      -- "$CTL"
run 0 true  "help lists the verbs"                          -- "$CTL" help
printf '%s' "$OUT" | jq -e '.detail.verbs | index("release") and index("stop-swarm")' >/dev/null \
  && ok "help names every group's verbs" || bad "help verbs: $OUT"
run 2 false "an unknown verb is a usage error"              -- "$CTL" frobnicate
[ "$(jq -r .action <<<"$OUT")" = frobnicate ] && ok "the unknown verb is echoed as the action" || bad "action: $OUT"
run 2 false "release with no issue is a usage error"        -- "$CTL" release
run 2 false "release --reason with no value"                -- "$CTL" release 5 --reason
run 2 false "release with two issues"                       -- "$CTL" release 5 6
run 2 false "release with an unknown option"                -- "$CTL" release 5 --force
run 2 false "status with an unknown argument"               -- "$CTL" status --bogus
run 2 false "status --session with no value"                -- "$CTL" status --session

# ── Verbs whose module is not installed answer "not implemented" (exit 3) ─────
for v in nudge stop restart approve reject request-changes file start add-worker remove-worker stop-swarm; do
  case "$v" in
    nudge|stop|restart) g=workers ;; approve|reject|request-changes|file) g=issues ;; *) g=swarm ;;
  esac
  [ -f "$SCRIPTS/ctl-$g.sh" ] && continue   # a later sub-task installed it
  run 3 false "$v (ctl-$g.sh not installed) is not implemented" -- "$CTL" "$v" 1 \
    && { [ "$(jq -r .detail <<<"$OUT")" = "not implemented" ] || bad "$v detail: $OUT"; }
done

# ── Module loading, in a copy of the dispatcher with a fake module ────────────
mkdir -p "$TMP/mod"
cp "$CTL" "$TMP/mod/autocoder-ctl.sh"
cat > "$TMP/mod/ctl-workers.sh" <<'SH'
ctl_verb_nudge() { echo "noise a verb prints"; ctl_ok "wt-$1" '{"sent": true}' --json; }
ctl_verb_stop()  { :; }
ctl_verb_restart() { ctl_ok "x" 'not json' --json; }
SH
run 0 true  "a module verb runs and its own output stays off stdout" -- "$TMP/mod/autocoder-ctl.sh" nudge 3
jq -e '.target == "wt-3" and .detail.sent == true' <<<"$OUT" >/dev/null && ok "an object detail passes through" || bad "nudge: $OUT"
grep -q 'noise a verb prints' "$TMP/stderr" && ok "the verb's output went to stderr" || bad "verb output lost"
run 1 false "a verb that reports nothing fails"             -- "$TMP/mod/autocoder-ctl.sh" stop
run 1 false "a verb with invalid JSON detail fails"         -- "$TMP/mod/autocoder-ctl.sh" restart
run 3 false "a module without the verb's function"          -- "$TMP/mod/autocoder-ctl.sh" approve

# ── release, against the file backend in a private repo ───────────────────────
git init -q "$TMP/repo"; cd "$TMP/repo" || exit 1
git config user.email t@example.com; git config user.name T
printf '{"issueSource": "file"}\n' > .autocoder.json
echo a > a; git add -A; git commit -qm base
IF() { ( source "$SCRIPTS/issue-fns.sh" >/dev/null 2>&1; "$@" ); }
N=$(IF issue_create --title "t" --body "b" | jq -r .number)
IF issue_claim "$N" >/dev/null 2>&1

run 0 true "release drops a claim" -- env AUTOCODER_CTL_ACTOR=dashboard-ui "$CTL" release "$N" --reason "worker crashed"
jq -e --arg n "$N" '.target == $n and .detail.released and .detail.commented and .detail.actor == "dashboard-ui"
  and .detail.reason == "worker crashed"' <<<"$OUT" >/dev/null && ok "release reports issue, actor and reason" || bad "release detail: $OUT"
J=$(IF issue_get "$N")
jq -e '.labels | map(.name? // .) | index("working") | not' <<<"$J" >/dev/null && ok "the working label is gone" || bad "still working: $J"
# The file backend appends comments to the body; others list them under comments.
TEXT=$(jq -r '[.body, (.comments[]?.body)] | join("\n")' <<<"$J")
grep -q 'released\*\* by dashboard-ui' <<<"$TEXT" && grep -q 'Reason\*\*: worker crashed' <<<"$TEXT" \
  && ok "a comment names the actor and the reason" || bad "comment: $J"

run 1 false "releasing an unclaimed issue fails" -- "$CTL" release "$N"
run 0 true "release without --reason uses \$USER" -- env -u AUTOCODER_CTL_ACTOR USER=someone sh -c \
  "cd '$TMP/repo' && ( . '$SCRIPTS/issue-fns.sh' >/dev/null 2>&1; issue_claim $N >/dev/null 2>&1 ) ; '$CTL' release $N"
jq -e '.detail.actor == "someone" and .detail.reason == null' <<<"$OUT" >/dev/null && ok "actor falls back to \$USER" || bad "fallback: $OUT"

# ── status, with a manifest and a stubbed worker-idle.sh ──────────────────────
run 0 true "status with no swarm" -- "$CTL" status --json
jq -e '.detail == {swarms: 0, workers: []}' <<<"$OUT" >/dev/null && ok "no manifest means no workers" || bad "empty status: $OUT"
run 1 false "status for a session with no manifest" -- "$CTL" status --session nope

git worktree add -q -b feature/issue-41 "$TMP/wt-1"
git worktree add -q -b enhancement/issue-42-auto "$TMP/wt-2"
git worktree add -q -b some-branch "$TMP/wt-3"
mkdir -p .autocoder/swarm
jq -n --arg w1 "$TMP/wt-1" --arg w2 "$TMP/wt-2" --arg w3 "$TMP/wt-3" '{version: 1, session: "s1", mux: "tmux", workers: [
  {number: 1, worktree: $w1, tmuxTarget: "%11", herdrPane: null, state: "running"},
  {number: 2, worktree: $w2, tmuxTarget: "%12", herdrPane: null, state: "running"},
  {number: 3, worktree: $w3, tmuxTarget: null,  herdrPane: null, state: "paused"}]}' > .autocoder/swarm/s1.json
echo 'not json' > .autocoder/swarm/broken.json
cat > "$TMP/idle" <<'SH'
#!/bin/bash
# --pane P --mux M --json; %11 is busy, %12 idle.
[ "$3 $4 $5" = "--mux tmux --json" ] || exit 2
case "$2" in
  %11) echo '{"pane":"%11","state":"BUSY","reason":"timer"}'; exit 1 ;;
  %12) echo '{"pane":"%12","state":"IDLE","reason":"sentinel"}'; exit 0 ;;
esac
exit 2
SH
chmod +x "$TMP/idle"
export AUTOCODER_CTL_IDLE_CMD="$TMP/idle"

run 0 true "status lists the workers" -- "$CTL" status --json
jq -e --arg r "$TMP/repo" '.target == $r and .detail.swarms == 1 and (.detail.workers | length) == 3' <<<"$OUT" >/dev/null \
  && ok "one swarm, three workers (the unreadable manifest is skipped)" || bad "status shape: $OUT"
jq -e '.detail.workers[0] | .issue == 41 and .activity == "busy" and .pane == "%11" and .branch == "feature/issue-41" and .session == "s1"' \
  <<<"$OUT" >/dev/null && ok "a worker on feature/issue-41 is busy on #41" || bad "worker 1: $OUT"
jq -e '.detail.workers[1] | .issue == 42 and .activity == "idle"' <<<"$OUT" >/dev/null \
  && ok "an enhancement branch is read as its issue, and idle" || bad "worker 2: $OUT"
jq -e '.detail.workers[2] | .issue == null and .activity == "unknown" and .pane == null and .state == "paused"' <<<"$OUT" >/dev/null \
  && ok "a worker with no pane and no issue branch is unknown" || bad "worker 3: $OUT"
run 0 true "status --session picks one manifest" -- "$CTL" status --session s1
jq -e '.detail.swarms == 1' <<<"$OUT" >/dev/null && ok "--session reads that session" || bad "--session: $OUT"

echo ""
echo "Tests: $FAIL failed, $PASS passed, $((PASS + FAIL)) total"
[ "$FAIL" -eq 0 ]
