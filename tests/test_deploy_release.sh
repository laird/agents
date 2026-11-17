#!/usr/bin/env bash
# tests/test_deploy_release.sh — deploy.sh, release.sh and the pre-push release hook
# (release-pre-push.sh, install-release-hook.sh), ported from agents-ui's
# tools/test_deploy.sh and tools/test_release.sh (#200). Each case runs the real
# scripts in a throwaway git repo with its own origin and .autocoder.json, and a
# stub `gh` on PATH, so nothing is installed, restarted, released or recorded for
# real. The environment's own deploy/restart/check commands are stubs that log.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPTS="$ROOT/plugins/autocoder/scripts"
DEPLOY="$SCRIPTS/deploy.sh"
RELEASE="$SCRIPTS/release.sh"
# Resolved (pwd -P): on macOS mktemp's /var/folders is a link to /private/var,
# and git and the scripts report the resolved path.
TMP=$(cd "$(mktemp -d -t deploy-release-test.XXXXXX)" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
FAILS=0; PASSES=0

# ---- stubs ---------------------------------------------------------------------
STUBS="$TMP/bin"; mkdir -p "$STUBS"
cat > "$STUBS/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >> "$STUB_LOG"
case "$*" in
  "release create"*) exit "${STUB_CREATE_RC:-0}" ;;
  "release view"*"--json url"*) echo "https://github.com/o/r/releases/tag/x" ;;
  "release view"*) exit 1 ;;
  *"/statuses"*) ;;
  *deployments*) echo 42 ;;
esac
EOF
# step <name>: an environment command that logs itself, its DEPLOY_* variables, and
# exits STUB_<NAME>_RC. `check` passes once STUB_CHECK_AFTER attempts have failed.
cat > "$STUBS/step" <<'EOF'
#!/usr/bin/env bash
echo "step $1 env=$DEPLOY_ENV sha=$DEPLOY_SHA left=${DEPLOY_TIME_LEFT:-}" >> "$STUB_LOG"
case "$1" in
  preflight) exit "${STUB_PREFLIGHT_RC:-0}" ;;
  deploy) exit "${STUB_DEPLOY_RC:-0}" ;;
  restart) exit "${STUB_RESTART_RC:-0}" ;;
  check)
    n=$(grep -c '^step check' "$STUB_LOG")
    [ "$n" -gt "${STUB_CHECK_AFTER:-0}" ] ;;
esac
EOF
chmod +x "$STUBS"/*

# ---- a landed checkout ---------------------------------------------------------
git init -q --bare "$TMP/origin.git"
git -C "$TMP/origin.git" symbolic-ref HEAD refs/heads/main
git init -q "$TMP/work"
(
  cd "$TMP/work"
  git checkout -q -b main
  git config user.email t@example.com; git config user.name test
  cat > .autocoder.json <<'EOF'
{"environments": [
  {"name": "nuc-1", "requires": "integration", "label": "agents-tui",
   "preflight": "step preflight", "deploy": "step deploy", "restart": "step restart",
   "check": "step check", "wait": 3, "release": true},
  {"name": "plain", "requires": "integration"},
  {"name": "staging", "requires": "green", "deploy": "step deploy"},
  {"name": "release", "requires": "nuc-1"}
]}
EOF
  echo one > file
  git add -A; git commit -qm "landed"
  git remote add origin "$TMP/origin.git"; git push -q origin main
)

# run <script> <name> [env assignments...] -- [args...]: sets RC, OUT, LOG
run() {
  local script=$1 name=$2; shift 2
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift
  export STUB_LOG="$TMP/$name.log"; : > "$STUB_LOG"
  OUT=$(cd "$TMP/work" && env -u AUTOCODER_DEPLOY_WAIT -u AUTOCODER_CONFIG HOME="$TMP/home" \
    PATH="$STUBS:$PATH" RELEASE_DATE=2026.11.09 ${envs[@]+"${envs[@]}"} bash "$script" "$@" 2>&1)
  RC=$?
  LOG=$(cat "$STUB_LOG")
  CASE=$name
}
check() {  # check <description> <command...>
  if "${@:2}"; then
    PASSES=$((PASSES + 1))
  else
    echo "FAIL [$CASE] $1"; echo "  rc=$RC"; echo "$OUT" | sed 's/^/  out: /'; echo "$LOG" | sed 's/^/  log: /'
    FAILS=$((FAILS + 1))
  fi
}
has() { grep -qF -- "$1" <<< "$2"; }
hasnt() { ! grep -qF -- "$1" <<< "$2"; }
SHA=$(git -C "$TMP/work" rev-parse HEAD)
# with_config <file> <python expression on d>: a copy of .autocoder.json, edited, for
# AUTOCODER_CONFIG (editing the committed one would make the tree dirty).
with_config() {
  python3 - "$TMP/work/.autocoder.json" "$1" "$2" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); exec(sys.argv[3]); json.dump(d, open(sys.argv[2], "w"))
PY
}

# ---- deploy.sh: refusals ---------------------------------------------------------
run "$DEPLOY" unknown-env -- --env qa
check "an environment not in .autocoder.json: exit 1" test "$RC" -eq 1
check "says so" has "environment 'qa' is not in" "$OUT"
check "records nothing" hasnt "gh " "$LOG"

run "$DEPLOY" no-env --
check "--env is required when several environments deploy" test "$RC" -eq 1
check "says so" has "--env is required" "$OUT"

run "$DEPLOY" preflight-fails STUB_PREFLIGHT_RC=1 -- --env nuc-1
check "a failing preflight: exit 1" test "$RC" -eq 1
check "says the preflight failed" has "the preflight failed" "$OUT"
check "opens no Deployment" hasnt "gh " "$LOG"
check "installs nothing" hasnt "step deploy" "$LOG"

run "$DEPLOY" preflight-fails-dry STUB_PREFLIGHT_RC=1 -- --env nuc-1 --dry-run
check "a dry run runs the preflight too" test "$RC" -eq 1

echo dirty > "$TMP/work/file"
run "$DEPLOY" dirty -- --env nuc-1
check "a dirty tree: exit 1" test "$RC" -eq 1
check "says so" has "uncommitted changes" "$OUT"
git -C "$TMP/work" checkout -q -- file
mkdir -p "$TMP/work/.claude"; echo x > "$TMP/work/.claude/state"
git -C "$TMP/work" add -f .claude/state 2>/dev/null; git -C "$TMP/work" commit -qm "harness state" 2>/dev/null
git -C "$TMP/work" push -q origin main; SHA=$(git -C "$TMP/work" rev-parse HEAD)
echo y > "$TMP/work/.claude/state"
run "$DEPLOY" claude-dirt -- --env nuc-1 --dry-run
check "harness state under .claude/ does not count as dirty" test "$RC" -eq 0
git -C "$TMP/work" checkout -q -- .claude/state

git -C "$TMP/work" commit -q --allow-empty -m "not pushed"
run "$DEPLOY" unlanded -- --env nuc-1
check "a HEAD not on origin/main: exit 1" test "$RC" -eq 1
check "says only landed work deploys" has "is not on origin/main; only landed work deploys" "$OUT"
git -C "$TMP/work" reset -q --hard origin/main

run "$DEPLOY" branch-env -- --env staging
check "an environment promote.sh moves deploys from its own branch: exit 1 while absent" test "$RC" -eq 1
check "it names origin/env/staging" has "origin/env/staging" "$OUT"
git -C "$TMP/work" push -q origin "HEAD:refs/heads/env/staging"
run "$DEPLOY" branch-env-landed -- --env staging --dry-run
check "and deploys once HEAD is on origin/env/staging" test "$RC" -eq 0

# ---- deploy.sh: dry run --------------------------------------------------------------
run "$DEPLOY" dry-run -- --env nuc-1 --dry-run
check "exits 0" test "$RC" -eq 0
check "names the deploy command" has "would run: step deploy" "$OUT"
check "names the restart command" has "would run: step restart" "$OUT"
check "names the check and its wait" has "would wait up to 3s for: step check" "$OUT"
check "names the tag and commit it would release" has "release: dry run: would run: gh release create v2026.11.09.1 --target $SHA" "$OUT"
check "records nothing" hasnt "gh " "$LOG"
check "installs nothing" hasnt "step deploy" "$LOG"
run "$DEPLOY" dry-run-no-release -- --env nuc-1 --dry-run --no-release
check "a dry run with --no-release says it would not release" has "would not release (--no-release)" "$OUT"

# ---- deploy.sh: deploys --------------------------------------------------------------
run "$DEPLOY" deploys -- --env nuc-1
check "exits 0" test "$RC" -eq 0
check "opens the Deployment of HEAD to the environment" has "-f ref=$SHA -f environment=nuc-1" "$LOG"
check "describes it with the label" has "description=agents-tui installed on $(hostname)" "$LOG"
check "runs preflight, deploy, restart, check in order" \
  test "$(grep -o '^step [a-z]*' <<< "$LOG" | tr '\n' ' ')" = "step preflight step deploy step restart step check "
check "commands see DEPLOY_ENV and DEPLOY_SHA" has "step deploy env=nuc-1 sha=$SHA" "$LOG"
check "the check sees the time left" grep -q '^step check .* left=[1-3]$' <<< "$LOG"
check "records in_progress, then success" \
  test "$(grep -o 'state=[a-z_]*' <<< "$LOG" | head -2 | tr '\n' ' ')" = "state=in_progress state=success "
check "the success names label, commit and host" has "description=agents-tui ${SHA:0:12} installed on $(hostname)" "$LOG"
check "then releases the same commit under a date tag" has "gh release create v2026.11.09.1 --target $SHA --generate-notes" "$LOG"
check "and records the release Deployment" has "environment=release -f description=Release v2026.11.09.1" "$LOG"

run "$DEPLOY" slow-check STUB_CHECK_AFTER=2 -- --env nuc-1 --no-release
check "a check that passes within the wait: exit 0" test "$RC" -eq 0
check "is retried until it passes" test "$(grep -c '^step check' <<< "$LOG")" -eq 3

run "$DEPLOY" check-never STUB_CHECK_AFTER=99 AUTOCODER_DEPLOY_WAIT=1 -- --env nuc-1
check "a check that never passes: exit 2" test "$RC" -eq 2
check "says it did not pass within the wait" has "the check did not pass within 1s" "$OUT"
check "records failure" has "state=failure" "$LOG"
check "does not record success" hasnt "state=success" "$LOG"
check "does not release" hasnt "release create" "$LOG"

run "$DEPLOY" bad-wait AUTOCODER_DEPLOY_WAIT=soon -- --env nuc-1
check "a non-numeric AUTOCODER_DEPLOY_WAIT is refused before anything is opened" test "$RC" -eq 1
check "records nothing" hasnt "gh " "$LOG"

with_config "$TMP/long.json" 'd["environments"][1]["deploy"] = "false " + "x" * 300'
run "$DEPLOY" long-cmd AUTOCODER_CONFIG="$TMP/long.json" -- --env plain
check "a failing long command: exit 2" test "$RC" -eq 2
check "its failure description fits GitHub's 140 characters" \
  test "$(grep 'state=failure' <<< "$LOG" | sed 's/.*-f description=//' | awk '{ print length($0) }')" -le 140

run "$DEPLOY" deploy-fails STUB_DEPLOY_RC=1 -- --env nuc-1
check "a failing deploy command: exit 2" test "$RC" -eq 2
check "records failure" has "state=failure" "$LOG"
check "restarts nothing" hasnt "step restart" "$LOG"

run "$DEPLOY" restart-fails STUB_RESTART_RC=1 -- --env nuc-1
check "a failing restart: exit 2" test "$RC" -eq 2
check "records failure" has "state=failure" "$LOG"

run "$DEPLOY" no-restart -- --env nuc-1 --no-release --no-restart
check "--no-restart: exit 0" test "$RC" -eq 0
check "installs" has "step deploy" "$LOG"
check "neither restarts" hasnt "step restart" "$LOG"
check "nor checks" hasnt "step check" "$LOG"

run "$DEPLOY" no-release -- --env nuc-1 --no-release
check "--no-release: exit 0" test "$RC" -eq 0
check "deploys" has "state=success" "$LOG"
check "does not release" hasnt "release create" "$LOG"
check "says so" has "not releasing (--no-release)" "$OUT"

run "$DEPLOY" plain -- --env plain
check "an environment without commands only records the Deployment" test "$RC" -eq 0
check "records success" has "state=success" "$LOG"
check "and does not release unless configured" hasnt "release create" "$LOG"

with_config "$TMP/rod.json" 'd["releaseOnDeploy"] = True'
run "$DEPLOY" release-on-deploy AUTOCODER_CONFIG="$TMP/rod.json" -- --env plain
check "a top-level releaseOnDeploy releases every environment's deploy" has "release create" "$LOG"

run "$DEPLOY" release-fails STUB_CREATE_RC=1 -- --env nuc-1
check "a failed release: exit 3" test "$RC" -eq 3
check "the deploy still stands" has "state=success" "$LOG"
check "and never records failure" hasnt "state=failure" "$LOG"
check "says the release failed and will be retried" has "but the release failed; the next deploy releases it" "$OUT"

# Released already: tag the deployed commit on origin, and a redeploy cuts no second release.
git -C "$TMP/work" tag v2026.11.09.1 && git -C "$TMP/work" push -q origin --tags
run "$DEPLOY" redeploy -- --env nuc-1
check "a redeploy: exit 0" test "$RC" -eq 0
check "deploys again" has "state=success" "$LOG"
check "but does not release the same commit twice" hasnt "release create" "$LOG"

# ---- release.sh ------------------------------------------------------------------------
tag_origin() { git -C "$TMP/work" tag -f "$1" "$2" >/dev/null && git -C "$TMP/work" push -q -f origin "refs/tags/$1"; }
ONE=$SHA
run "$RELEASE" next-of-day -- --next-tag
check "counts up within the day" test "$OUT" = v2026.11.09.2
tag_origin v2026.11.08.4 "$ONE"
run "$RELEASE" other-days -- --next-tag
check "ignoring other days" test "$OUT" = v2026.11.09.2

run "$RELEASE" unchanged --
check "the newest release again: exit 0" test "$RC" -eq 0
check "says it is already released" has "is already the newest release (v2026.11.09.1)" "$OUT"
check "creates no release" hasnt "release create" "$LOG"

(cd "$TMP/work" && echo two > file && git commit -qam two && git push -q origin main)
TWO=$(git -C "$TMP/work" rev-parse HEAD)
run "$RELEASE" dry-run -- --dry-run
check "a dry run names the tag and commit" has "would run: gh release create v2026.11.09.2 --target $TWO" "$OUT"
check "and changes nothing" hasnt "gh " "$LOG"

run "$RELEASE" auto --
check "releases the tip under the next tag" has "gh release create v2026.11.09.2 --target $TWO --generate-notes" "$LOG"
check "records a release Deployment described 'Release <tag>'" has "environment=release -f description=Release v2026.11.09.2" "$LOG"
check "marks it success with the Release's page" has "log_url=https://github.com/o/r/releases/tag/x" "$LOG"
check "does not look up a tag it just made up" test "$(grep -cx 'gh release view v2026.11.09.2' <<< "$LOG")" -eq 0

run "$RELEASE" release-fails STUB_CREATE_RC=1 --
check "gh failing: exit 1" test "$RC" -eq 1
check "says gh failed" has "gh release create failed" "$OUT"
check "records no Deployment for a release that does not exist" hasnt "environment=release" "$LOG"

# The newest release is found by number, not by text: .10 is after .9.
tag_origin v2026.11.09.9 "$ONE"
tag_origin v2026.11.09.10 "$TWO"
run "$RELEASE" newest-by-number --
check "takes .10 as newer than .9" has "is already the newest release (v2026.11.09.10)" "$OUT"
tag_origin v2026.11.09.11-rc1 "$ONE"
run "$RELEASE" not-the-scheme --
check "a tag outside the scheme is not a release" has "is already the newest release (v2026.11.09.10)" "$OUT"

git -C "$TMP/work" commit -q --allow-empty -m "local only"
run "$RELEASE" unlanded -- --commit HEAD
check "a commit not on origin/main: exit 1" test "$RC" -eq 1
check "says only landed work is released" has "only landed work is released" "$OUT"
git -C "$TMP/work" reset -q --hard origin/main

# tagScheme semver, and a renamed release environment.
with_config "$TMP/semver.json" 'd["tagScheme"] = "semver"; d["releaseEnvironment"] = "production"'
run "$RELEASE" semver-first AUTOCODER_CONFIG="$TMP/semver.json" -- --next-tag
check "semver with no vX.Y.Z tag starts at v0.1.0" test "$OUT" = v0.1.0
tag_origin v1.2.9 "$ONE"; tag_origin v1.2.10 "$ONE"; tag_origin v1.3.0-rc1 "$ONE"
run "$RELEASE" semver-next AUTOCODER_CONFIG="$TMP/semver.json" -- --next-tag
check "semver bumps the newest vX.Y.Z's patch, by number" test "$OUT" = v1.2.11
run "$RELEASE" semver-auto AUTOCODER_CONFIG="$TMP/semver.json" --
check "semver releases the tip as the next patch" has "gh release create v1.2.11 --target $TWO" "$LOG"
check "recorded to the configured environment" has "environment=production -f description=Release v1.2.11" "$LOG"
with_config "$TMP/calver.json" 'd["tagScheme"] = "calver"'
run "$RELEASE" bad-scheme AUTOCODER_CONFIG="$TMP/calver.json" --
check "an unknown tagScheme: exit 1" test "$RC" -eq 1

# ---- the pre-push hook -------------------------------------------------------------------
export STUB_LOG="$TMP/hook.log"
(cd "$TMP/work" && HOME="$TMP/home" bash "$SCRIPTS/install-release-hook.sh" >/dev/null)
CASE=install
check "installs a pre-push hook" test -x "$TMP/work/.git/hooks/pre-push"
check "the hook runs this plugin's release-pre-push.sh" grep -qF "$SCRIPTS/release-pre-push.sh" "$TMP/work/.git/hooks/pre-push"
git -C "$TMP/work" worktree add -q -b worker "$TMP/work-wt-1" main

# push_from <dir> <refspec> [env...]: commit and push, then wait for the hook's job.
push_from() {
  local dir=$1 spec=$2; shift 2
  : > "$STUB_LOG"
  (cd "$dir" && git config user.email t@example.com && git config user.name test \
    && echo "$RANDOM$RANDOM" > file && git commit -qam change \
    && env HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" PATH="$STUBS:$PATH" RELEASE_DATE=2026.11.10 \
         AUTOCODER_RELEASE_WAIT=10 "$@" git push -q origin "$spec" 2>/dev/null)
  PUSHED=$(git -C "$dir" rev-parse HEAD)
  for _ in $(seq 1 40); do grep -q "statuses" "$STUB_LOG" && break; sleep 0.25; done
  LOG=$(cat "$STUB_LOG"); OUT=$(cat "$TMP/state/autocoder/release.log" 2>/dev/null); RC=0
}
push_from "$TMP/work" main
CASE=hook-main
check "a push of main from the main checkout releases the pushed commit" has "gh release create v2026.11.10.1 --target $PUSHED" "$LOG"
check "and logs to autocoder's state directory" has "pushed ${PUSHED:0:12} to origin/main" "$OUT"

git -C "$TMP/work-wt-1" fetch -q origin && git -C "$TMP/work-wt-1" reset -q --hard origin/main
push_from "$TMP/work-wt-1" HEAD:main
sleep 1; LOG=$(cat "$STUB_LOG")
CASE=hook-worktree
check "a push of main from a worktree (a worker, a merge job) does not release" hasnt "release create" "$LOG"

git -C "$TMP/work" fetch -q origin && git -C "$TMP/work" reset -q --hard origin/main
push_from "$TMP/work" HEAD:refs/heads/feature/x
sleep 1; LOG=$(cat "$STUB_LOG")
CASE=hook-branch
check "pushing another branch from the main checkout does not release" hasnt "release create" "$LOG"

git -C "$TMP/work" reset -q --hard origin/main
push_from "$TMP/work" main AUTOCODER_NO_RELEASE=1
sleep 1; LOG=$(cat "$STUB_LOG")
CASE=hook-opt-out
check "AUTOCODER_NO_RELEASE=1 pushes without releasing" hasnt "release create" "$LOG"
push_from "$TMP/work" main AGENTS_UI_NO_RELEASE=1
sleep 1; LOG=$(cat "$STUB_LOG")
CASE=hook-opt-out-legacy
check "AGENTS_UI_NO_RELEASE=1 still works" hasnt "release create" "$LOG"

echo "not ours" > "$TMP/work/.git/hooks/pre-push"
OUT=$(cd "$TMP/work" && bash "$SCRIPTS/install-release-hook.sh" 2>&1); RC=$?; CASE=foreign-hook
check "leaves someone else's pre-push hook alone" test "$RC" -eq 1
check "and keeps it" grep -qx "not ours" "$TMP/work/.git/hooks/pre-push"
printf '#!/usr/bin/env bash\n# agents-ui release hook (tools/install-hooks.sh)\nexec bash x "$@"\n' > "$TMP/work/.git/hooks/pre-push"
OUT=$(cd "$TMP/work" && bash "$SCRIPTS/install-release-hook.sh" 2>&1); RC=$?; CASE=legacy-hook
check "replaces agents-ui's own release hook" grep -qF "release-pre-push.sh" "$TMP/work/.git/hooks/pre-push"
OUT=$(cd "$TMP/work" && bash "$SCRIPTS/install-release-hook.sh" --uninstall 2>&1); RC=$?; CASE=uninstall
check "--uninstall removes it" test ! -e "$TMP/work/.git/hooks/pre-push"

# ---- the hook shim: quoting and the plugin-update fallback ---------------------------------
# A plugin path with quotes and a command substitution stays data; when the version the
# hook names is gone, the newest version (by number) of the SAME marketplace runs, never
# another marketplace's plugin called autocoder.
CACHE="$TMP/cache/plugins/cache"
for v in mkt/autocoder/1.9.0 mkt/autocoder/1.10.0 evil/autocoder/9.9.9; do mkdir -p "$CACHE/$v/scripts"; done
cp "$SCRIPTS/install-release-hook.sh" "$SCRIPTS/release-pre-push.sh" "$CACHE/mkt/autocoder/1.9.0/scripts/"
echo 'echo "ran 1.10.0 $*"' > "$CACHE/mkt/autocoder/1.10.0/scripts/release-pre-push.sh"
echo 'echo "ran evil"' > "$CACHE/evil/autocoder/9.9.9/scripts/release-pre-push.sh"
NASTY="$TMP/a\"b\$(touch PWNED)'c/scripts"
mkdir -p "$NASTY"; cp "$SCRIPTS/install-release-hook.sh" "$SCRIPTS/release-pre-push.sh" "$NASTY/"
git init -q "$TMP/shim1"
OUT=$(cd "$TMP/shim1" && bash "$NASTY/install-release-hook.sh" >/dev/null && AUTOCODER_NO_RELEASE=1 .git/hooks/pre-push origin u </dev/null 2>&1); RC=$?; LOG=""; CASE=shim-quoting
check "a plugin path with quotes and \$(...) installs a working hook" test "$RC" -eq 0
check "and runs nothing from the path" test ! -e "$TMP/shim1/PWNED"
git init -q "$TMP/shim2"
(cd "$TMP/shim2" && bash "$CACHE/mkt/autocoder/1.9.0/scripts/install-release-hook.sh" >/dev/null)
rm -rf "$CACHE/mkt/autocoder/1.9.0"
OUT=$(cd "$TMP/shim2" && .git/hooks/pre-push origin u </dev/null 2>&1); RC=$?; CASE=shim-fallback
check "after an update removes its version, the hook runs the newest of the same marketplace" test "$OUT" = "ran 1.10.0 origin u"

run "$RELEASE" bad-tag -- "v1/../../x"
check "a hand-given tag that is not a plain name: exit 1" test "$RC" -eq 1
check "and nothing reaches gh" hasnt "gh " "$LOG"

# ---- portability: macOS bash 3.2 and BSD tools ----------------------------------------------
# What broke in agents-ui's CI on macOS, kept out: an empty array as "${a[@]}" under
# `set -u`, `sort -V`, `date -I`, GNU-only flags, bash 4 builtins.
CASE=portable; RC=0; LOG=""
for f in "$DEPLOY" "$RELEASE" "$SCRIPTS/release-pre-push.sh" "$SCRIPTS/install-release-hook.sh"; do
  OUT=$(grep -v '^[[:space:]]*#' "$f" | sed 's/\${envs\[@\]+"\${envs\[@\]}"}//g' \
    | grep -nE 'sort -V|date -I|readlink -f|sed -i|declare -A|mapfile|readarray|grep -P|stat -c|"\$\{envs\[@\]\}"' || true)
  check "$(basename "$f") avoids Linux-only shell" test -z "$OUT"
done

echo "deploy/release tests: $PASSES passed, $FAILS failed"
[ "$FAILS" -eq 0 ]
