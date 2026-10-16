#!/bin/bash
# promote.sh — move an environment's branch to a commit that carries proof it passed the
# full regression gate. Releases flow through environments; main does not have to be green.
#
# WHY THIS EXISTS:
#   Workers land on main fast and main-sentinel.sh repairs main when it goes red. That is
#   the deliberate trade: main absorbs the risk so development stays quick. A release
#   (staging, uat, prod) must not. Each environment is a branch on origin that a deploy
#   reads, and this script is the only thing that moves it. It moves it only to a commit
#   with proof: the sentinel's green tip, the previous environment's tip, or a tree the
#   gate cache records as passing the full suite. Being on main is never enough.
#
# CONFIG: the "environments" array of .autocoder.json in the main worktree. Order is the
# pipeline, and each entry may only require "green" or an environment listed before it.
#   "environments": [
#     {"name": "staging", "ref": "env/staging", "requires": "green", "auto": true},
#     {"name": "uat",     "requires": "staging"},
#     {"name": "prod",    "requires": "uat", "test": "npm run e2e"}
#   ]
#   name      how operators refer to it
#   ref       the branch on origin that IS the environment (default env/<name>)
#   requires  "green" (origin/<green-ref>, the sentinel's proof) or an earlier environment
#   test      optional extra command (an E2E suite) run on the candidate tree in a throwaway
#             worktree before the move, through gate-cache-fns.sh so a repeat is free
#   auto      the sentinel promotes it after every green tick (default false)
#
# USAGE:
#   promote.sh --to <env> [--commit <sha|ref>] [--allow-rollback] [--dry-run]
#   promote.sh --list
#   promote.sh --auto                 every auto:true environment, in pipeline order
#   common: [--repo DIR] [--green-ref main-green] [--test-cmd "<cmd>"]
#   --commit defaults to the newest proven commit: origin/<green-ref> for requires=green,
#     otherwise the required environment's tip.
#   --test-cmd is the full regression command whose gate-cache records count as proof. It
#     defaults to the '### Regression Test Suite' block of AGENTS.md / CLAUDE.md, as in the
#     sentinel, and must match what the sentinel ran. Without one, only an exact tip counts.
#
# EXIT: 0 moved or already there · 1 setup/config error · 2 refused (reason printed, nothing moved)

set -uo pipefail

_PR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=gate-cache-fns.sh
source "${_PR_DIR}/gate-cache-fns.sh"
# shellcheck source=test-cmd-fns.sh
source "${_PR_DIR}/test-cmd-fns.sh"

REPO="" GREEN="main-green" TEST_CMD="" TO="" COMMIT="" MODE="promote" ROLLBACK=0 DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo|--green-ref|--test-cmd|--to|--commit)
      [ $# -ge 2 ] || { echo "promote.sh: $1 needs a value" >&2; exit 1; } ;;
  esac
  case "$1" in
    --repo)           REPO="$2"; shift 2 ;;
    --green-ref)      GREEN="$2"; shift 2 ;;
    --test-cmd)       TEST_CMD="$2"; shift 2 ;;
    --to)             TO="$2"; shift 2 ;;
    --commit)         COMMIT="$2"; shift 2 ;;
    --allow-rollback) ROLLBACK=1; shift ;;
    --dry-run)        DRY=1; shift ;;
    --list)           MODE=list; shift ;;
    --auto)           MODE=auto; shift ;;
    *) echo "promote.sh: unknown arg '$1'" >&2; exit 1 ;;
  esac
done
if [ "$MODE" = promote ] && [ -z "$TO" ]; then
  echo "promote.sh: --to <env> is required (or --list / --auto)" >&2
  exit 1
fi

REPO=$(git -C "${REPO:-.}" rev-parse --show-toplevel 2>/dev/null) || { echo "❌ --repo is not a git checkout" >&2; exit 1; }
cd "$REPO" || exit 1
[ -z "$TEST_CMD" ] && TEST_CMD=$(resolve_test_cmd "$REPO")
MAIN_WT=$(git worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')
CONFIG="${MAIN_WT:-$REPO}/.autocoder.json"
TMP_ROOT="${AUTOCODER_TMP:-/tmp}"

# The pipeline as parallel arrays indexed by position. Every rule below is a function over
# one index, so adding an environment is a config edit and never a new branch here.
ENV_NAME=() ENV_REF=() ENV_REQUIRES=() ENV_TEST=() ENV_AUTO=()
load_environments() {
  local name ref req test auto
  while IFS=$'\x1f' read -r name ref req test auto; do
    case "$name" in
      "") continue ;;
      "!"*) echo "❌ ${CONFIG}: ${name#!}" >&2; return 1 ;;
    esac
    ENV_NAME+=("$name"); ENV_REF+=("$ref"); ENV_REQUIRES+=("$req"); ENV_TEST+=("$test"); ENV_AUTO+=("$auto")
  done < <(python3 - "$CONFIG" <<'PY'
import json, os, sys
path = sys.argv[1]
if not os.path.exists(path):
    sys.exit(0)
try:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
except Exception as e:
    print("!cannot parse: %s" % e); sys.exit(0)
envs = data.get("environments") or []
if not isinstance(envs, list):
    print("!environments must be an array"); sys.exit(0)
seen = []
for i, e in enumerate(envs):
    if not isinstance(e, dict) or not e.get("name"):
        print("!environments[%d] needs a name" % i); sys.exit(0)
    name = str(e["name"])
    req = str(e.get("requires") or "")
    if name in seen or name == "green":
        print("!environment name %r is taken" % name); sys.exit(0)
    if req != "green" and req not in seen:
        print("!environment %r requires %r; must be 'green' or an environment listed before it" % (name, req)); sys.exit(0)
    row = [name, str(e.get("ref") or "env/%s" % name), req, str(e.get("test") or ""), "1" if e.get("auto") else "0"]
    if any(("\x1f" in v or "\n" in v) for v in row):
        print("!environment %r: fields must not contain newlines" % name); sys.exit(0)
    print("\x1f".join(row))
    seen.append(name)
PY
  )
}

env_index() {
  local i
  for i in "${!ENV_NAME[@]}"; do
    [ "${ENV_NAME[i]}" = "$1" ] && { echo "$i"; return 0; }
  done
  return 1
}
tip_of() { git rev-parse -q --verify "$1^{commit}" 2>/dev/null; }
# The ref whose tip is proof for a `requires` value.
proof_ref() {
  if [ "$1" = green ]; then echo "origin/$GREEN"; else echo "origin/${ENV_REF[$(env_index "$1")]}"; fi
}

fetch_refs() {
  local r
  for r in "$GREEN" "${ENV_REF[@]}"; do
    git fetch -q origin "+refs/heads/$r:refs/remotes/origin/$r" 2>/dev/null \
      || git update-ref -d "refs/remotes/origin/$r" 2>/dev/null
  done
}

# Proof that $1 passed the full regression gate, for requirement $2: it is the proof ref's
# tip, or its tree has a recorded pass. Sets PROOF to the sentence that says which.
PROOF=""
has_proof() {
  local sha="$1" req="$2" pr tip tree
  pr=$(proof_ref "$req"); tip=$(tip_of "$pr")
  if [ -n "$tip" ] && [ "$tip" = "$sha" ]; then PROOF="tip of $pr"; return 0; fi
  if [ -n "$TEST_CMD" ]; then
    tree=$(git rev-parse "$sha^{tree}")
    if [ "$(gate_cache_get "$tree" "$TEST_CMD" 2>/dev/null)" = pass ]; then
      PROOF="tree ${tree:0:7} has a recorded full-regression pass"; return 0
    fi
  fi
  return 1
}
missing_proof_reason() {
  local sha="$1" req="$2" pr
  pr=$(proof_ref "$req")
  if [ -z "$(tip_of "$pr")" ]; then
    if [ "$req" = green ]; then echo "$pr does not exist yet (the sentinel has not recorded a green tip)"
    else echo "$pr does not exist yet (nothing has been promoted to $req)"; fi
  elif [ -z "$TEST_CMD" ]; then
    echo "${sha:0:7} is not the tip of $pr (no test command resolved, so only that tip counts)"
  else
    echo "${sha:0:7} is not the tip of $pr and its tree has no recorded full-regression pass"
  fi
}

# node_modules and dist are git-ignored, so a fresh worktree has none. Hardlink them from
# the repo (instant), falling back to a copy across filesystem boundaries.
seed_build_dirs() {
  local wt="$1" src rel
  while IFS= read -r src; do
    rel="${src#"$REPO"/}"
    [ -e "$wt/$rel" ] && continue
    mkdir -p "$(dirname "$wt/$rel")"
    cp -al "$src" "$wt/$rel" 2>/dev/null || { rm -rf "$wt/$rel"; cp -a "$src" "$wt/$rel" 2>/dev/null || true; }
  done < <(find "$REPO" -maxdepth 4 \( -path '*/node_modules/*' -o -name .git \) -prune -o -type d \( -name node_modules -o -name dist \) -print 2>/dev/null)
}

# Run the environment's own test ($2) on commit $1 in a throwaway worktree. gate_cache_run
# keys on the tree, so the same tree is never tested twice.
run_env_test() {
  local sha="$1" cmd="$2" wt rc
  wt=$(mktemp -d "$TMP_ROOT/autocoder-promote.XXXXXX") || return 1
  if ! git worktree add -q --detach "$wt" "$sha" >/dev/null 2>&1; then
    rmdir "$wt" 2>/dev/null
    echo "❌ could not create a worktree for ${sha:0:7}" >&2
    return 1
  fi
  seed_build_dirs "$wt"
  gate_cache_run "$wt" "$cmd" 2>&1 | sed 's/^/   /'
  rc=${PIPESTATUS[0]}
  git worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"
  return "$rc"
}

log_history() {
  local name="$1" ref="$2" from="$3" to="$4" h="${_PR_DIR}/append-to-history.sh"
  [ -f "$h" ] || return 0
  bash "$h" "Promoted $name to ${to:0:7}" \
    "origin/$ref moved ${from:+from ${from:0:7} }to ${to:0:7}" \
    "$PROOF" \
    "deploys that read origin/$ref now get ${to:0:7}" >/dev/null 2>&1 || true
}

# One promotion: $1 env, $2 commit or empty for the default, $3 allow-rollback, $4 dry-run.
# Prints one line. Returns 0 moved or already there, 1 setup error, 2 refused.
promote() {
  local name="$1" want="$2" rollback="$3" dry="$4" i ref req sha cur verb="→" force=()
  i=$(env_index "$name") || { echo "⛔ unknown environment '$name' (configured: ${ENV_NAME[*]})"; return 2; }
  ref="${ENV_REF[i]}"; req="${ENV_REQUIRES[i]}"
  if [ -n "$want" ]; then
    sha=$(tip_of "$want") || { echo "❌ cannot resolve commit '$want'" >&2; return 1; }
  else
    sha=$(tip_of "$(proof_ref "$req")") || { echo "⛔ $name: refused, $(missing_proof_reason "" "$req")"; return 2; }
  fi
  cur=$(tip_of "origin/$ref")
  if [ "$cur" = "$sha" ]; then echo "✔ $name already at ${sha:0:7}"; return 0; fi
  has_proof "$sha" "$req" || { echo "⛔ $name: refused, $(missing_proof_reason "$sha" "$req")"; return 2; }
  if [ -n "$cur" ] && ! git merge-base --is-ancestor "$cur" "$sha" 2>/dev/null; then
    if [ "$rollback" != 1 ]; then
      echo "⛔ $name: refused, ${sha:0:7} is not a fast-forward of origin/$ref (${cur:0:7}); pass --allow-rollback to move it anyway"
      return 2
    fi
    verb="rolled back →"; force=("--force-with-lease=refs/heads/$ref:$cur")
  fi
  if [ -n "${ENV_TEST[i]}" ]; then
    echo "🧪 $name: '${ENV_TEST[i]}' on ${sha:0:7}"
    run_env_test "$sha" "${ENV_TEST[i]}" || {
      echo "⛔ $name: refused, '${ENV_TEST[i]}' failed on ${sha:0:7}; origin/$ref stays ${cur:+at ${cur:0:7}}${cur:-absent}"
      return 2
    }
  fi
  if [ "$dry" = 1 ]; then
    echo "🔎 dry-run: would move $name (origin/$ref) ${cur:+from ${cur:0:7} }to ${sha:0:7} ($PROOF)"
    return 0
  fi
  git push -q ${force[@]+"${force[@]}"} origin "$sha:refs/heads/$ref" 2>/dev/null \
    || { echo "❌ push to origin/$ref rejected (did it move under us?)" >&2; return 1; }
  git fetch -q origin "+refs/heads/$ref:refs/remotes/origin/$ref" 2>/dev/null
  [ "$(tip_of "origin/$ref")" = "$sha" ] || { echo "❌ origin/$ref is not at ${sha:0:7} after the push" >&2; return 1; }
  if [ "$verb" = "→" ]; then echo "✅ $name → ${sha:0:7} ($PROOF)"; else echo "🔄 $name $verb ${sha:0:7} ($PROOF)"; fi
  log_history "$name" "$ref" "$cur" "$sha"
  return 0
}

list_envs() {
  local i name ref req cur tip cand proof auto note
  printf '%-10s %-18s %-8s %-6s %-5s %s\n' ENV REF TIP PROOF AUTO PROMOTABLE
  for i in "${!ENV_NAME[@]}"; do
    name=${ENV_NAME[i]} ref=${ENV_REF[i]} req=${ENV_REQUIRES[i]}
    cur=$(tip_of "origin/$ref"); cand=$(tip_of "$(proof_ref "$req")")
    tip=${cur:0:7}; [ -n "$tip" ] || tip=-
    [ "${ENV_AUTO[i]}" = 1 ] && auto=yes || auto=no
    if [ -z "$cur" ]; then proof="-"; elif has_proof "$cur" "$req"; then proof=yes; else proof=NO; fi
    if [ -z "$cand" ]; then note="none ($(proof_ref "$req") absent)"
    elif [ "$cand" = "$cur" ]; then note="${cand:0:7} (current)"
    elif [ -n "$cur" ] && ! git merge-base --is-ancestor "$cur" "$cand" 2>/dev/null; then note="${cand:0:7} (needs --allow-rollback)"
    else note="${cand:0:7}"; fi
    [ -n "$cand" ] && [ -n "${ENV_TEST[i]}" ] && note+=" after '${ENV_TEST[i]}'"
    printf '%-10s %-18s %-8s %-6s %-5s %s\n' "$name" "$ref" "$tip" "$proof" "$auto" "$note"
  done
}

auto_all() {
  local i
  for i in "${!ENV_NAME[@]}"; do
    [ "${ENV_AUTO[i]}" = 1 ] || continue
    promote "${ENV_NAME[i]}" "" 0 "$DRY"
  done
  return 0
}

load_environments || exit 1
if [ "${#ENV_NAME[@]}" -eq 0 ]; then
  [ "$MODE" = auto ] && exit 0
  echo "❌ no 'environments' configured in $CONFIG" >&2
  exit 1
fi
fetch_refs
case "$MODE" in
  list)    list_envs ;;
  auto)    auto_all ;;
  promote) promote "$TO" "$COMMIT" "$ROLLBACK" "$DRY" ;;
esac
