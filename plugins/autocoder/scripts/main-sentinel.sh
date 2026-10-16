#!/bin/bash
# main-sentinel.sh — gate the integration branch AFTER merges land; on red, bisect to the
# culprit, revert it, and file the regression against the issue that introduced it.
#
# WHY THIS EXISTS:
#   merge-to-integration.sh may push a push-race re-sync without re-gating it, and may push
#   onto an integration branch that is already red. Both are only safe because something
#   tests the integration tip after the fact and repairs it. This is that something: test
#   post-merge, bisect, auto-revert, file the culprit. Gate verdicts go through
#   gate-cache-fns.sh, so a tip whose tree a worker already gated costs nothing here, and a
#   bisect never re-runs a commit it has a verdict for.
#
# USAGE:
#   main-sentinel.sh [--repo DIR] [--integration main] [--green-ref main-green]
#                    [--test-cmd "<cmd>"] [--loop SECONDS] [--state-dir DIR]
#   One invocation is one idempotent tick; --loop N repeats it every N seconds forever.
#   --test-cmd falls back to the '### Regression Test Suite' block of AGENTS.md / CLAUDE.md
#   and the script refuses to run when neither yields a command.
#
# STATE (one file, tmp+rename), default dir
#   ${AUTOCODER_SENTINEL_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/autocoder/sentinel}
#   file <repo-id>-<integration> holding:
#     last_tested=<sha>   tip this sentinel last gated; an unmoved tip is an idle tick
#     last_green=<sha>    tip that last passed; origin/<green-ref> overrides it when present
#     red_issue=<num>     open P0 tracking the current red streak, empty when green
#   origin/<green-ref> is the source of truth another tool (a deploy) can read; the file is
#   a cache of it plus the two fields git has no home for.
#
# SCRATCH: ${AUTOCODER_TMP:-/tmp}/autocoder-sentinel-<repo-id> is a persistent worktree
#   (created once, re-pointed every tick). The same directory is scanned for
#   merge-launch.sh's autocoder-merge-<issue>.{pid,exit} files to detect crashed hand-offs.
#
# EXIT: 0 tick done (idle, green, or repaired) · 1 config/setup error · 3 red, not repaired.

set -uo pipefail

_MS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=gate-cache-fns.sh
source "${_MS_DIR}/gate-cache-fns.sh"

# `git bisect run` probe: exit 0 good / 1 bad. Reusing a recorded fail is what makes a
# revisit free; the top-level gate below deliberately does not reuse fails (flake).
#
# The probe READS the shared cache (a tip a worker gated is free) but WRITES to a
# bisect-local cache ($5). Bisect visits feature-side commits that were never integration
# tips; recording their passes in the shared cache would make them indistinguishable from
# real tips, which mainline_parent relies on.
if [ "${1:-}" = "--bisect-probe" ]; then
  _tree=$(git -C "$2" rev-parse 'HEAD^{tree}')
  if [ "$(gate_cache_get "$_tree" "$3" 2>/dev/null)" = pass ]; then
    echo "gate-cache: pass recorded for tree ${_tree:0:8}; not re-running" >> "$4"
    exit 0
  fi
  AUTOCODER_GATE_CACHE_DIR="$5" GATE_CACHE_REUSE_FAIL=1 gate_cache_run "$2" "$3" >> "$4" 2>&1
  exit $?
fi

REPO="" INTEGRATION="main" GREEN="main-green" TEST_CMD="" LOOP="" STATE_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo|--integration|--green-ref|--test-cmd|--loop|--state-dir)
      [ $# -ge 2 ] || { echo "main-sentinel.sh: $1 needs a value" >&2; exit 1; } ;;
  esac
  case "$1" in
    --repo)        REPO="$2"; shift 2 ;;
    --integration) INTEGRATION="$2"; shift 2 ;;
    --green-ref)   GREEN="$2"; shift 2 ;;
    --test-cmd)    TEST_CMD="$2"; shift 2 ;;
    --loop)        LOOP="$2"; shift 2 ;;
    --state-dir)   STATE_DIR="$2"; shift 2 ;;
    *) echo "main-sentinel.sh: unknown arg '$1'" >&2; exit 1 ;;
  esac
done

REPO=$(git -C "${REPO:-.}" rev-parse --show-toplevel 2>/dev/null) || { echo "❌ --repo is not a git checkout" >&2; exit 1; }
cd "$REPO" || exit 1
# shellcheck source=issue-fns.sh
source "${_MS_DIR}/issue-fns.sh"
# shellcheck source=test-cmd-fns.sh
source "${_MS_DIR}/test-cmd-fns.sh"

[ -z "$TEST_CMD" ] && TEST_CMD=$(resolve_test_cmd "$REPO")
if [ -z "$TEST_CMD" ]; then
  echo "❌ No test command: pass --test-cmd or add a '### Regression Test Suite' fenced block to AGENTS.md or CLAUDE.md." >&2
  exit 1
fi

COMMON_DIR=$(cd "$(git rev-parse --git-common-dir)" && pwd -P)
REPO_ID="$(basename "$(dirname "$COMMON_DIR")")-$(printf '%s' "$COMMON_DIR" | sha1sum | cut -c1-8)"
STATE_DIR="${STATE_DIR:-${AUTOCODER_SENTINEL_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/autocoder/sentinel}}"
STATE_FILE="$STATE_DIR/${REPO_ID}-${INTEGRATION}"
GATE_LOG="$STATE_FILE.gate.log"
RED_LOG="$STATE_FILE.red.log"
BISECT_LOG="$STATE_FILE.bisect.log"
TMP_ROOT="${AUTOCODER_TMP:-/tmp}"
WT="$TMP_ROOT/autocoder-sentinel-${REPO_ID}"
mkdir -p "$STATE_DIR" || exit 1

last_tested="" last_green="" red_issue=""
state_load() {
  [ -f "$STATE_FILE" ] || return 0
  local k v
  while IFS='=' read -r k v; do
    case "$k" in last_tested|last_green|red_issue) printf -v "$k" '%s' "$v" ;; esac
  done < "$STATE_FILE"
}
state_save() {
  local t
  t=$(mktemp "$STATE_DIR/.tmp.XXXXXX") || return 1
  printf 'last_tested=%s\nlast_green=%s\nred_issue=%s\n' "$last_tested" "$last_green" "$red_issue" > "$t" && mv -f "$t" "$STATE_FILE"
}

# node_modules and dist are git-ignored, so a fresh worktree has none. Hardlink them from
# --repo (instant), falling back to a copy across filesystem boundaries where cp -al fails.
copy_build_dirs() {
  local src rel
  while IFS= read -r src; do
    rel="${src#"$REPO"/}"
    [ -e "$WT/$rel" ] && continue
    mkdir -p "$(dirname "$WT/$rel")"
    cp -al "$src" "$WT/$rel" 2>/dev/null || { rm -rf "$WT/$rel"; cp -a "$src" "$WT/$rel" 2>/dev/null || true; }
  done < <(find "$REPO" -maxdepth 4 \( -path '*/node_modules/*' -o -name .git \) -prune -o -type d \( -name node_modules -o -name dist \) -print 2>/dev/null)
}

# Persistent worktree, re-pointed at $1. A tick that died mid-bisect or mid-revert leaves
# state behind; the resets and --force make the next tick start from a clean checkout.
ensure_worktree() {
  if ! git -C "$WT" rev-parse --verify HEAD >/dev/null 2>&1; then
    git worktree remove --force "$WT" 2>/dev/null || rm -rf "$WT"
    git worktree prune 2>/dev/null
    git worktree add --detach "$WT" "$1" >/dev/null 2>&1 || { echo "❌ Could not create sentinel worktree $WT" >&2; return 1; }
    copy_build_dirs
  fi
  git -C "$WT" bisect reset >/dev/null 2>&1
  git -C "$WT" revert --abort >/dev/null 2>&1
  git -C "$WT" merge --abort >/dev/null 2>&1
  git -C "$WT" checkout -q --detach --force "$1" || { echo "❌ Could not check out $1 in $WT" >&2; return 1; }
}

gate() {
  gate_cache_run "$WT" "$TEST_CMD" 2>&1 | tee "$GATE_LOG"
  return "${PIPESTATUS[0]}"
}

push_green() {
  git push -q origin "$1:refs/heads/$GREEN" 2>/dev/null && return 0
  echo "ℹ️  origin/$GREEN did not fast-forward to ${1:0:7}; leaving it where it is"
}

origin_issue() { git log -1 --format=%B "$1" | grep -oE '#[0-9]+|issue-[0-9]+' | head -1 | grep -oE '[0-9]+'; }

# Which parent (1 or 2) of merge $1 is the integration branch's own side. Rules in order,
# each decisive only when it names exactly one parent:
#   0. the parent IS last_green;
#   1. the merge subject is one our scripts write: "Merge/Re-sync origin/<int> into <feature>"
#      (merge-to-integration.sh, this script) puts the integration on parent 2;
#      "Merge issue #N (...) into <int>" (api-push.py) puts it on parent 1;
#   2. only one parent has last_green as an ancestor (feature branched before the last green);
#   3. only one parent's tree has a recorded gate pass in the SHARED cache (only integration
#      tips get recorded there; the bisect probe writes elsewhere);
#   4. one parent is an ancestor of the other, so the descendant is the feature side.
# Prints nothing and returns 1 when none decides.
mainline_parent() {
  local m="$1" p1 p2 a b subject
  p1=$(git rev-parse "$m^1") p2=$(git rev-parse "$m^2")
  [ "$p1" = "$last_green" ] && { echo 1; return; }
  [ "$p2" = "$last_green" ] && { echo 2; return; }
  subject=$(git log -1 --format=%s "$m")
  case "$subject" in
    "Merge origin/${INTEGRATION} into "*|"Re-sync origin/${INTEGRATION} into "*) echo 2; return ;;
    *" into ${INTEGRATION}") echo 1; return ;;
  esac
  a=0; b=0
  git merge-base --is-ancestor "$last_green" "$p1" 2>/dev/null && a=1
  git merge-base --is-ancestor "$last_green" "$p2" 2>/dev/null && b=1
  [ "$a$b" = 10 ] && { echo 1; return; }
  [ "$a$b" = 01 ] && { echo 2; return; }
  a=0; b=0
  [ "$(gate_cache_get "$(git rev-parse "$p1^{tree}")" "$TEST_CMD" 2>/dev/null)" = pass ] && a=1
  [ "$(gate_cache_get "$(git rev-parse "$p2^{tree}")" "$TEST_CMD" 2>/dev/null)" = pass ] && b=1
  [ "$a$b" = 10 ] && { echo 1; return; }
  [ "$a$b" = 01 ] && { echo 2; return; }
  git merge-base --is-ancestor "$p1" "$p2" 2>/dev/null && { echo 1; return; }
  git merge-base --is-ancestor "$p2" "$p1" 2>/dev/null && { echo 2; return; }
  return 1
}
issue_is_open() { issue_get "$1" 2>/dev/null | grep -q '"state": *"OPEN"'; }

# Bisect $1 (red) against last_green, revert the culprit, gate, push with the same CAS loop
# merge-to-integration.sh uses. Sets CULPRIT and REVERT; returns 0 only once the revert is on
# origin/<integration> and the state records it.
CULPRIT="" REVERT=""
repair() {
  local tip="$1" mflag="" attempt before pushed
  CULPRIT="" REVERT=""
  if [ -z "$last_green" ] || ! git merge-base --is-ancestor "$last_green" "$tip" 2>/dev/null; then
    echo "ℹ️  No green baseline that is an ancestor of ${tip:0:7}; cannot bisect."
    return 1
  fi
  echo "🔍 Bisecting ${last_green:0:7}..${tip:0:7} (first-parent)"
  : > "$GATE_LOG.bisect"
  git -C "$WT" bisect start --first-parent "$tip" "$last_green" >/dev/null 2>&1 || { git -C "$WT" bisect reset >/dev/null 2>&1; return 1; }
  git -C "$WT" bisect run bash "${BASH_SOURCE[0]}" --bisect-probe "$WT" "$TEST_CMD" "$GATE_LOG.bisect" "$STATE_FILE.bisect-cache" >/dev/null 2>&1
  CULPRIT=$(git -C "$WT" rev-parse -q --verify refs/bisect/bad 2>/dev/null)
  git -C "$WT" bisect log > "$BISECT_LOG" 2>/dev/null
  git -C "$WT" bisect reset >/dev/null 2>&1
  git -C "$WT" checkout -q --detach --force "$tip"
  [ -n "$CULPRIT" ] || { echo "⚠️  Bisect did not name a culprit."; return 1; }
  echo "🎯 Culprit ${CULPRIT:0:7}: $(git log -1 --format=%s "$CULPRIT")"

  # A merge culprit is reverted against the parent that carries the integration branch's
  # own history, which is NOT always the first parent: a worker pushes its feature tip as
  # the new integration tip, so its "Merge origin/main into feature/…" sync merge has the
  # feature as parent 1 and main as parent 2. `-m 1` there would revert every sibling's
  # landed work. The mainline parent is the one last_green is an ancestor of; if that is
  # ambiguous (both, or neither) a human decides.
  if git rev-parse -q --verify "$CULPRIT^2" >/dev/null 2>&1; then
    local side
    side=$(mainline_parent "$CULPRIT") || {
      echo "⚠️  Cannot tell which parent of merge ${CULPRIT:0:7} is the integration mainline; leaving it to a human."
      return 1
    }
    mflag="-m $side"
  fi
  # shellcheck disable=SC2086
  if ! git -C "$WT" revert --no-edit $mflag "$CULPRIT" >/dev/null 2>&1; then
    git -C "$WT" revert --abort >/dev/null 2>&1
    echo "⚠️  Reverting ${CULPRIT:0:7} conflicts; leaving it to a human."
    return 1
  fi
  REVERT=$(git -C "$WT" rev-parse HEAD)
  gate || { echo "⚠️  Still red after reverting ${CULPRIT:0:7}."; return 1; }

  for attempt in 1 2 3 4 5; do
    if git -C "$WT" push -q origin "HEAD:refs/heads/$INTEGRATION" 2>/dev/null; then
      pushed=$(git -C "$WT" rev-parse HEAD)
      push_green "$pushed"
      last_green="$pushed"; last_tested="$pushed"; red_issue=""
      state_save
      return 0
    fi
    echo "⚠️  Push to '$INTEGRATION' rejected; re-syncing (attempt $attempt/5)"
    git fetch -q origin "$INTEGRATION" || return 1
    before=$(git -C "$WT" rev-parse HEAD)
    if ! git -C "$WT" merge -q --no-ff "origin/$INTEGRATION" -m "Merge origin/$INTEGRATION into sentinel revert of ${CULPRIT:0:7} (push retry $attempt)" >/dev/null 2>&1; then
      git -C "$WT" merge --abort >/dev/null 2>&1
      return 1
    fi
    if [ "$(git -C "$WT" rev-parse HEAD)" != "$before" ]; then
      gate || return 1
    fi
  done
  return 1
}

# File the P0 for a red $1. Culprit/revert fields come from the globals when repair ran.
NEW_ISSUE=""
file_red() {
  local tip="$1" subject="" origin="" title body out
  NEW_ISSUE=""
  if [ -n "$CULPRIT" ]; then
    subject=$(git log -1 --format=%s "$CULPRIT")
    origin=$(origin_issue "$CULPRIT")
  fi
  if [ -n "$REVERT" ]; then
    title="Regression gate red on ${INTEGRATION}: reverted ${CULPRIT:0:7} \"${subject}\""
  else
    title="Regression gate red on ${INTEGRATION} at ${tip:0:7}"
  fi
  body="The integration branch \`${INTEGRATION}\` failed its regression gate at \`${tip}\`.

Gate: \`${TEST_CMD}\`
"
  [ -n "$CULPRIT" ] && body+="Culprit: \`${CULPRIT}\` \"${subject}\"
"
  [ -n "$origin" ] && body+="Originating issue: #${origin}
"
  if [ -n "$REVERT" ]; then
    body+="Revert: \`${REVERT}\` is on \`${INTEGRATION}\` and \`${GREEN}\` points at the pushed tip. Re-land the change with a fix.
"
  else
    body+="Not repaired automatically: no usable green baseline, or the revert conflicted or stayed red. A human must fix or revert on \`${INTEGRATION}\`.
"
  fi
  [ -s "$BISECT_LOG" ] && body+="
## Bisect log
\`\`\`
$(cat "$BISECT_LOG")
\`\`\`
"
  body+="
## Gate output (last 40 lines)
\`\`\`
$(tail -n 40 "$RED_LOG" 2>/dev/null)
\`\`\`"
  out=$(issue_create --title "$title" --body "$body" --label P0 --label test-failure) || { echo "❌ issue_create failed" >&2; return 1; }
  NEW_ISSUE=$(printf '%s' "$out" | grep -oE '[0-9]+' | tail -1)
  if [ -n "$origin" ]; then
    issue_comment "$origin" --body "⚠️ Regression: \`${CULPRIT:0:7}\` from this issue broke the \`${INTEGRATION}\` gate.${REVERT:+ The sentinel reverted it as \`${REVERT:0:7}\`.} Tracking: #${NEW_ISSUE}." >/dev/null 2>&1 || true
  fi
}

# Workers hand issues to a detached merge job and move on. A pidfile whose pid is dead with
# no exit file is a job that crashed before reporting; put the issue back in the queue.
reconcile_handoffs() {
  local pf num pid
  for pf in "$TMP_ROOT"/autocoder-merge-*.pid; do
    [ -f "$pf" ] || continue
    num="${pf##*/autocoder-merge-}"; num="${num%.pid}"
    [[ "$num" =~ ^[0-9]+$ ]] || continue
    pid=$(cat "$pf" 2>/dev/null)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && continue
    [ -f "${pf%.pid}.exit" ] && continue
    if issue_get "$num" 2>/dev/null | grep -q '"name": *"awaiting-integration"'; then
      issue_update "$num" --remove-label awaiting-integration >/dev/null 2>&1
      issue_comment "$num" --body "⚠️ The detached merge job for this issue (pid ${pid:-?}) died before it reported a result. Removed \`awaiting-integration\`; the issue is re-queued for a worker to re-land." >/dev/null 2>&1
      echo "♻️  issue #${num}: merge job died; re-queued"
    fi
    rm -f "$pf"
  done
}

tick() {
  local tip green
  state_load
  git fetch -q origin "$INTEGRATION" || { echo "❌ Could not fetch origin/${INTEGRATION}" >&2; return 1; }
  git fetch -q origin "+refs/heads/${GREEN}:refs/remotes/origin/${GREEN}" 2>/dev/null \
    || git update-ref -d "refs/remotes/origin/${GREEN}" 2>/dev/null
  tip=$(git rev-parse "origin/${INTEGRATION}") || return 1
  green=$(git rev-parse -q --verify "origin/${GREEN}" 2>/dev/null) && last_green="$green"
  reconcile_handoffs
  if [ "$tip" = "$last_tested" ]; then
    echo "💤 ${INTEGRATION} idle at ${tip:0:7} (already gated)"
    return 0
  fi
  ensure_worktree "$tip" || return 1
  : > "$BISECT_LOG"
  if gate; then
    push_green "$tip"
    last_green="$tip"; last_tested="$tip"; red_issue=""
    state_save
    echo "✅ ${INTEGRATION} green at ${tip:0:7}"
    return 0
  fi
  cp -f "$GATE_LOG" "$RED_LOG" 2>/dev/null
  echo "❌ ${INTEGRATION} red at ${tip:0:7}"
  if repair "$tip"; then
    file_red "$tip"
    echo "🔁 reverted ${CULPRIT:0:7} as ${REVERT:0:7}; filed #${NEW_ISSUE}"
    return 0
  fi
  if [ -n "$red_issue" ] && issue_is_open "$red_issue"; then
    issue_comment "$red_issue" --body "Still red: \`${INTEGRATION}\` fails the gate at \`${tip}\`.${CULPRIT:+ Bisect names \`${CULPRIT:0:7}\`.}" >/dev/null 2>&1
    echo "   updated #${red_issue}"
  else
    file_red "$tip" && red_issue="$NEW_ISSUE"
    echo "   filed #${red_issue}"
  fi
  last_tested="$tip"
  state_save
  return 3
}

if [ -n "$LOOP" ]; then
  while :; do
    tick
    sleep "$LOOP"
  done
fi
tick
