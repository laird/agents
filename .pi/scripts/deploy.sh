#!/usr/bin/env bash
# deploy.sh — install this checkout on this machine with the repo's own commands,
# and record it as a GitHub Deployment to an environment; then, if configured,
# cut a release of the same commit (release.sh).
#
# A Deployment is what says which commit an environment runs: the Deployment is
# opened before installing, then marked `success` once the check passes, or
# `failure` if the install, the restart or the check fails.
#
# USAGE:
#   deploy.sh --env <name> [--dry-run] [--no-restart] [--no-release] [--integration <branch>]
#
#   --env          environment to record; must be in .autocoder.json "environments"
#                  (default: the only environment with a "deploy" command, if exactly one has one)
#   --dry-run      run every refusal and the preflight, print what would run; install,
#                  restart and record nothing
#   --no-restart   install and record, but neither restart nor check
#   --no-release   deploy without releasing afterwards
#   --integration  the integration branch (default: origin/HEAD, else main)
#
# CONFIG (.autocoder.json in the main worktree), per environment:
#   {"name": "nuc-1", "requires": "integration",
#    "label": "agents-tui",                      what is installed, for descriptions (default: repo dir name)
#    "preflight": "systemctl --user cat agents-tui.service >/dev/null",
#    "deploy": "cargo install --path . --locked",
#    "restart": "systemctl --user restart agents-tui.service",
#    "check": "agents-tui service status --wait",
#    "wait": 30,                                 seconds the check may take, retried (default 30)
#    "release": true}                            release after a successful deploy
#   Top level: "releaseOnDeploy": true releases after every environment's deploy;
#   "tagScheme" and "releaseEnvironment" are release.sh's.
#
#   Every command runs with `bash -c` at the top of the checkout, in order, with
#   DEPLOY_ENV, DEPLOY_SHA and (for check) DEPLOY_TIME_LEFT in its environment. An
#   environment without commands only records the Deployment. A failing preflight
#   refuses before anything is opened: use it for "is there anything to deploy to".
#
# What it refuses, before opening a Deployment (exit 1):
#   - an environment that is not in .autocoder.json
#   - a dirty tree (what is installed must be exactly the recorded commit;
#     harness state under .claude/ is ignored)
#   - a HEAD that is not landed: on origin/<integration>, or on origin/<ref> for an
#     environment promote.sh moves (requires "green" or another such environment)
#   - a failing preflight
#
# Every deploy may release: with "release": true on the environment, or a top-level
# "releaseOnDeploy": true, a `success` is followed by release.sh for the same
# commit. A commit that already is the newest release is not released again. A
# failed release does not undo the deploy: it stays `success`, and the script
# exits 3, so the next deploy retries.
#
# EXIT: 0 deployed (and released, if configured) or dry run passed · 1 refused or
#       setup error · 2 deploy failed (recorded as failure) · 3 deployed, release failed
set -euo pipefail

_DP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENVIRONMENT=""
DRY_RUN=false
RESTART=true
RELEASE=true
INTEGRATION=""
while [ $# -gt 0 ]; do
  case "$1" in
    --env|--integration) [ $# -ge 2 ] || { echo "deploy.sh: $1 needs a value" >&2; exit 1; } ;;
  esac
  case "$1" in
    --env) ENVIRONMENT="$2"; shift 2 ;;
    --integration) INTEGRATION="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --no-restart) RESTART=false; shift ;;
    --no-release) RELEASE=false; shift ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) echo "deploy.sh: unknown argument: $1" >&2; exit 1 ;;
  esac
done

say() { echo "deploy.sh: $*"; }
refuse() { echo "deploy.sh: refusing: $*" >&2; exit 1; }

TOP=$(git rev-parse --show-toplevel 2>/dev/null) || refuse "not inside a git checkout"
cd "$TOP"
MAIN_WT=$(git worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p' || true)
CONFIG="${AUTOCODER_CONFIG:-${MAIN_WT:-$TOP}/.autocoder.json}"
[ -f "$CONFIG" ] || refuse "no $CONFIG; environments are configured there"

# The environment's settings, one "key<TAB>value" per line. Exit 2 when it is not
# configured; 3 when --env was omitted and no single environment has a deploy command.
# A function, not a heredoc inside $(...): bash 3.2 misparses quotes in one.
env_rows() {
  python3 - "$CONFIG" "$ENVIRONMENT" <<'PY'
import json, os, sys
path, name = sys.argv[1], sys.argv[2]
try:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
except Exception as e:
    print("parse error: %s" % e, file=sys.stderr); sys.exit(4)
envs = [e for e in (data.get("environments") or []) if isinstance(e, dict) and e.get("name")]
if not name:
    with_deploy = [e for e in envs if e.get("deploy")]
    if len(with_deploy) != 1:
        sys.exit(3)
    name = str(with_deploy[0]["name"])
byname = {str(e["name"]): e for e in envs}
env = byname.get(name)
if env is None:
    sys.exit(2)
# promote.sh moves an environment whose chain of `requires` ends in "green": that
# environment's branch is what deploys. Anything else deploys from the integration branch.
def branch_env(e, seen=()):
    req = str(e.get("requires") or "")
    if req == "green":
        return True
    nxt = byname.get(req)
    return nxt is not None and req not in seen and branch_env(nxt, seen + (req,))
def one_line(v):
    return str(v).replace("\t", " ").replace("\n", " ")
release = bool(env.get("release")) or bool(data.get("releaseOnDeploy"))
wait = env.get("wait", 30)
try:
    wait = max(1, int(wait))
except (TypeError, ValueError):
    wait = 30
rows = {
    "name": name,
    "ref": (str(env.get("ref") or "env/%s" % name)) if branch_env(env) else "",
    "label": env.get("label") or "",
    "preflight": env.get("preflight") or "",
    "deploy": env.get("deploy") or "",
    "restart": env.get("restart") or "",
    "check": env.get("check") or "",
    "wait": wait,
    "release": "1" if release else "0",
}
for k, v in rows.items():
    print("%s\t%s" % (k, one_line(v)))
PY
}
ENV_ROWS=$(env_rows) || case $? in
  2) refuse "environment '$ENVIRONMENT' is not in $CONFIG" ;;
  3) refuse "--env is required: name one of the environments in $CONFIG" ;;
  *) refuse "cannot read $CONFIG" ;;
esac
field() { printf '%s\n' "$ENV_ROWS" | awk -F '\t' -v k="$1" '$1 == k { sub(/^[^\t]*\t/, ""); print; exit }'; }
ENVIRONMENT=$(field name)
ENV_REF=$(field ref)
LABEL=$(field label); [ -n "$LABEL" ] || LABEL=$(basename "${MAIN_WT:-$TOP}")
PREFLIGHT=$(field preflight)
DEPLOY_CMD=$(field deploy)
RESTART_CMD=$(field restart)
CHECK_CMD=$(field check)
WAIT="${AUTOCODER_DEPLOY_WAIT:-$(field wait)}"
case "$WAIT" in ''|*[!0-9]*) refuse "AUTOCODER_DEPLOY_WAIT must be a whole number of seconds, not '$WAIT'" ;; esac
[ "$(field release)" = 1 ] || RELEASE=false
CONFIGURED_RELEASE=$(field release)

if [ -z "$INTEGRATION" ]; then
  INTEGRATION=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@' || true)
  # No origin/HEAD (a clone made by `git remote add`): main, or master when only it exists.
  if [ -z "$INTEGRATION" ]; then
    INTEGRATION=main
    git rev-parse -q --verify refs/remotes/origin/main >/dev/null \
      || ! git rev-parse -q --verify refs/remotes/origin/master >/dev/null || INTEGRATION=master
  fi
fi

if [ -n "$(git status --porcelain --untracked-files=no -- . ':(exclude).claude')" ]; then
  git status --short --untracked-files=no -- . ':(exclude).claude' >&2
  refuse "the working tree has uncommitted changes; what is installed must be exactly the recorded commit"
fi

# Landed: on the branch this environment deploys from.
LANDED="${ENV_REF:-$INTEGRATION}"
git fetch --quiet origin "+refs/heads/$LANDED:refs/remotes/origin/$LANDED" \
  || refuse "cannot fetch origin/$LANDED"
SHA=$(git rev-parse HEAD)
git merge-base --is-ancestor "$SHA" "origin/$LANDED" \
  || refuse "HEAD ${SHA:0:12} is not on origin/$LANDED; only landed work deploys"

export DEPLOY_ENV="$ENVIRONMENT" DEPLOY_SHA="$SHA"
if [ -n "$PREFLIGHT" ]; then
  bash -c "$PREFLIGHT" || refuse "the preflight failed ($PREFLIGHT); nothing was installed or recorded"
fi

say "environment: $ENVIRONMENT"
say "commit:      $SHA ($(git log -1 --format=%s "$SHA"))"

if [ "$DRY_RUN" = true ]; then
  say "dry run: would record a Deployment of ${SHA:0:12} to '$ENVIRONMENT'"
  [ -n "$DEPLOY_CMD" ] && say "dry run: would run: $DEPLOY_CMD"
  if [ "$RESTART" = false ]; then
    say "dry run: would neither restart nor check (--no-restart)"
  else
    [ -n "$RESTART_CMD" ] && say "dry run: would run: $RESTART_CMD"
    [ -n "$CHECK_CMD" ] && say "dry run: would wait up to ${WAIT}s for: $CHECK_CMD"
  fi
  if [ "$RELEASE" = false ]; then
    if [ "$CONFIGURED_RELEASE" = 1 ]; then say "dry run: would not release (--no-release)"
    else say "dry run: would not release (not configured)"; fi
  else
    bash "$_DP_DIR/release.sh" --integration "$INTEGRATION" --commit "$SHA" --dry-run 2>&1 \
      | sed 's/^release\.sh: /deploy.sh: release: /' \
      || say "dry run: the release check failed; the deploy would still go ahead"
  fi
  say "dry run: checks passed, nothing changed"
  exit 0
fi

command -v gh >/dev/null || refuse "gh is not installed; it records the deployment"
HOST=$(hostname)

# Open the deployment first, so a failed install is on record too.
DEPLOYMENT_ID=$(gh api "repos/{owner}/{repo}/deployments" \
  -f ref="$SHA" -f environment="$ENVIRONMENT" \
  -f description="$LABEL installed on $HOST" \
  -F auto_merge=false -F 'required_contexts[]' --jq .id) \
  || refuse "GitHub would not create the deployment"
status() {  # status <state> <description>; GitHub caps a description at 140 characters
  local d="$2"
  [ "${#d}" -le 140 ] || d="${d:0:137}..."
  gh api "repos/{owner}/{repo}/deployments/$DEPLOYMENT_ID/statuses" \
    -f state="$1" -f description="$d" >/dev/null \
    || echo "deploy.sh: could not record '$1' on deployment $DEPLOYMENT_ID" >&2
}
fail() { echo "deploy.sh: $*" >&2; status failure "$*"; exit 2; }
status in_progress "installing ${SHA:0:12}"
say "deployment $DEPLOYMENT_ID opened"

if [ -n "$DEPLOY_CMD" ]; then
  bash -c "$DEPLOY_CMD" || fail "the deploy command failed: $DEPLOY_CMD"
fi

if [ "$RESTART" = true ]; then
  if [ -n "$RESTART_CMD" ]; then
    bash -c "$RESTART_CMD" || fail "the restart command failed: $RESTART_CMD"
  fi
  if [ -n "$CHECK_CMD" ]; then
    # Deployed when the check passes, not when the restart returned. Each attempt
    # learns the time left (DEPLOY_TIME_LEFT), so a slow first answer can use it all.
    deadline=$((SECONDS + WAIT))
    until DEPLOY_TIME_LEFT=$(( deadline - SECONDS > 0 ? deadline - SECONDS : 1 )) bash -c "$CHECK_CMD"; do
      [ "$SECONDS" -lt "$deadline" ] || fail "the check did not pass within ${WAIT}s: $CHECK_CMD"
      sleep 1
    done
    say "check passed: $CHECK_CMD"
  fi
fi

status success "$LABEL ${SHA:0:12} installed on $HOST"
say "deployed ${SHA:0:12} to $ENVIRONMENT"
# Lifecycle event (#190): repo-wide, so no issue; an issue is deployed once its landed
# commit is an ancestor of this one.
if [ -f "$_DP_DIR/issue-events-lib.sh" ]; then
  # shellcheck source=issue-events-lib.sh
  source "$_DP_DIR/issue-events-lib.sh"
  issue_event deployed - environment="$ENVIRONMENT" sha="$SHA" deployment="$DEPLOYMENT_ID" || true
fi

if [ "$RELEASE" = false ]; then
  if [ "$CONFIGURED_RELEASE" = 1 ]; then say "not releasing (--no-release)"; fi
  exit 0
fi
# The deploy stands whatever happens here: it is recorded, and only the release is retried.
if ! bash "$_DP_DIR/release.sh" --integration "$INTEGRATION" --commit "$SHA"; then
  echo "deploy.sh: deployed ${SHA:0:12} to $ENVIRONMENT, but the release failed; the next deploy releases it" >&2
  exit 3
fi
