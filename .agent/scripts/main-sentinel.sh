#!/bin/bash
# main-sentinel.sh — gate the integration branch AFTER merges land; on red, find the push
# that broke it among the pushes the pipeline recorded, revert exactly that push, and file
# the regression against the issue that made it.
#
# WHY THIS EXISTS:
#   merge-to-integration.sh may push a push-race re-sync without re-gating it, and may push
#   onto an integration branch that is already red. Both are only safe because something
#   tests the integration tip after the fact and repairs it. This is that something.
#
# WHY TIP REFS, NOT git bisect:
#   Workers merge the integration branch INTO their feature and push the feature tip as the
#   new integration tip, so consecutive tips are joined by second-parent links or by plain
#   fast-forwards. `git bisect --first-parent` from the tip only ever visits the newest
#   push's own commits: a break from any earlier push is never a candidate, and the newest
#   push gets reverted for it. Every verified push now records itself as a tip ref,
#     refs/autocoder/tips/<integration>/<landed-sha>-<issue>
#   so the sentinel bisects over the real sequence of pushes, with the issue attached to
#   each. A push nobody recorded (a human) is a synthetic tip with issue `unknown`.
#
# USAGE:
#   main-sentinel.sh [--repo DIR] [--integration main] [--green-ref <integration>-green]
#                    [--test-cmd "<cmd>"] [--loop SECONDS] [--state-dir DIR]
#                    [--auto-revert | --report-only]
#   One invocation is one idempotent tick; --loop N repeats it every N seconds forever.
#   By default the sentinel is REPORT-ONLY: on red it gates, bisects to name the culprit
#   push, and files or updates the P0, but never pushes a revert; the fix rolls forward
#   through a normal gated change. --auto-revert (or AUTOCODER_SENTINEL_AUTO_REVERT=1)
#   lets it revert exactly the culprit push and re-gate; use that only where every party
#   pushing to the branch has agreed to it. Green ticks move the green ref, close parked
#   issues, and auto-promote in both modes.
#   --test-cmd falls back to the '### Regression Test Suite' block of AGENTS.md / CLAUDE.md
#   and the script refuses to run when neither yields a command.
#   The green ref defaults to AUTOCODER_GREEN_REF, then <integration>-green.
#   A tick holds flock on <state file>.lock; a second invocation prints that another tick
#   is running and exits 0.
#
# STATE (one file, tmp+rename), default dir
#   ${AUTOCODER_SENTINEL_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/autocoder/sentinel}
#   file <repo-id>-<integration> holding:
#     last_tested=<sha>      tip this sentinel last gated; an unmoved tip is an idle tick
#     last_green=<sha>       tip that last passed; origin/<green-ref> overrides it when present
#     red_issue=<num>        open P0 tracking the current red streak, empty when green
#     pending_revert=<sha>   a revert built and about to be pushed, with pending_culprit,
#     pending_issue, pending_p0; a tick that finds the sha on origin finishes the
#     bookkeeping, a tick that does not clears it and lets the next repair redo it.
#   origin/<green-ref> is the source of truth another tool (a deploy) can read; the file is
#   a cache of it plus the fields git has no home for. After every green tick, promote.sh
#   --auto moves each auto:true environment of .autocoder.json to it.
#
# SCRATCH: a throwaway worktree per tick under
#   ${AUTOCODER_TMP:-/tmp}/autocoder-sentinel-<repo-id>-<integration>/<pid>, seeded with the
#   node_modules/dist treatment merge-to-integration.sh uses and removed on exit. The same
#   tmp root holds merge-launch.sh's autocoder-merge-<repo-id>-<issue>.{pid,exit,run.sh}
#   files (and, for one release, the older autocoder-merge-<issue>.* names), which the
#   sentinel reads to reconcile hand-offs whose job died.
#
# EXIT: 0 tick done (idle, green, or repaired) · 1 config/setup error · 3 red, not repaired.

set -uo pipefail

_MS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=gate-cache-fns.sh
source "${_MS_DIR}/gate-cache-fns.sh"
# shellcheck source=repo-id-fns.sh
source "${_MS_DIR}/repo-id-fns.sh"
# shellcheck source=regate-fns.sh
source "${_MS_DIR}/regate-fns.sh"
# shellcheck source=worktree-deps-fns.sh
source "${_MS_DIR}/worktree-deps-fns.sh"

REPO="" INTEGRATION="main" GREEN="${AUTOCODER_GREEN_REF:-}" TEST_CMD="" LOOP="" STATE_DIR=""
REPORT_ONLY=1
[ "${AUTOCODER_SENTINEL_AUTO_REVERT:-0}" = 1 ] && REPORT_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo|--integration|--green-ref|--test-cmd|--loop|--state-dir)
      [ $# -ge 2 ] || { echo "main-sentinel.sh: $1 needs a value" >&2; exit 1; } ;;
  esac
  case "$1" in
    --report-only) REPORT_ONLY=1; shift ;;
    --auto-revert) REPORT_ONLY=0; shift ;;
    --repo)        REPO="$2"; shift 2 ;;
    --integration) INTEGRATION="$2"; shift 2 ;;
    --green-ref)   GREEN="$2"; shift 2 ;;
    --test-cmd)    TEST_CMD="$2"; shift 2 ;;
    --loop)        LOOP="$2"; shift 2 ;;
    --state-dir)   STATE_DIR="$2"; shift 2 ;;
    *) echo "main-sentinel.sh: unknown arg '$1'" >&2; exit 1 ;;
  esac
done
[ -n "$GREEN" ] || GREEN="${INTEGRATION}-green"

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

REPO_ID=$(autocoder_repo_id "$REPO") || exit 1
STATE_DIR="${STATE_DIR:-${AUTOCODER_SENTINEL_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/autocoder/sentinel}}"
STATE_FILE="$STATE_DIR/${REPO_ID}-${INTEGRATION}"
GATE_LOG="$STATE_FILE.gate.log"
RED_LOG="$STATE_FILE.red.log"
BISECT_LOG="$STATE_FILE.bisect.log"
TMP_ROOT="${AUTOCODER_TMP:-/tmp}"
WT_ROOT="$TMP_ROOT/autocoder-sentinel-${REPO_ID}-${INTEGRATION}"
WT="$WT_ROOT/$$"
TIPS="refs/autocoder/tips/${INTEGRATION}"
mkdir -p "$STATE_DIR" || exit 1

STATE_KEYS="last_tested last_green red_issue pending_revert pending_culprit pending_issue pending_p0"
last_tested="" last_green="" red_issue="" pending_revert="" pending_culprit="" pending_issue="" pending_p0=""
state_load() {
  [ -f "$STATE_FILE" ] || return 0
  local k v
  while IFS='=' read -r k v; do
    case " $STATE_KEYS " in *" $k "*) printf -v "$k" '%s' "$v" ;; esac
  done < "$STATE_FILE"
}
state_save() {
  local t k
  t=$(mktemp "$STATE_DIR/.tmp.XXXXXX") || return 1
  for k in $STATE_KEYS; do printf '%s=%s\n' "$k" "${!k}"; done > "$t" && mv -f "$t" "$STATE_FILE"
}
clear_pending() { pending_revert="" pending_culprit="" pending_issue="" pending_p0=""; }

is_ancestor() { git merge-base --is-ancestor "$1" "$2" 2>/dev/null; }

# ── worktree ──────────────────────────────────────────────────────────────────────────────
# One throwaway worktree per tick, created on first use and removed on exit. A tick that
# died leaves <pid> behind; the next tick removes every directory whose pid is gone.
worktree_at() {
  if ! git -C "$WT" rev-parse --verify HEAD >/dev/null 2>&1; then
    mkdir -p "$WT_ROOT"
    git worktree add --detach "$WT" "$1" >/dev/null 2>&1 || { echo "❌ Could not create sentinel worktree $WT" >&2; return 1; }
    seed_worktree_deps "$REPO" "$WT"
    return 0
  fi
  git -C "$WT" reset -q --hard >/dev/null 2>&1
  git -C "$WT" checkout -q --detach --force "$1" || { echo "❌ Could not check out $1 in $WT" >&2; return 1; }
}
drop_worktree() {
  [ -d "$WT" ] || return 0
  git worktree remove --force "$WT" >/dev/null 2>&1 || rm -rf "$WT"
  git worktree prune >/dev/null 2>&1
}
trap drop_worktree EXIT
prune_stale_worktrees() {
  local d pid
  for d in "$WT_ROOT"/*; do
    [ -d "$d" ] || continue
    pid="${d##*/}"
    [ "$pid" = "$$" ] && continue
    [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null && continue
    git worktree remove --force "$d" >/dev/null 2>&1 || rm -rf "$d"
  done
  git worktree prune >/dev/null 2>&1
}

gate() {
  gate_cache_run "$WT" "$TEST_CMD" 2>&1 | tee "$GATE_LOG"
  return "${PIPESTATUS[0]}"
}

# ── refs ──────────────────────────────────────────────────────────────────────────────────
# origin/<green-ref> moves only forward. $2=gated says $1 passed the gate this tick; with
# AUTOCODER_GREEN_FORCE=1 that permits a lease-protected force when a history rewrite left
# the ref somewhere $1 does not descend from (never backwards). Non-zero when it stays.
push_green() {
  local sha="$1" cur
  if git push -q origin "$sha:refs/heads/$GREEN" 2>/dev/null; then
    git update-ref "refs/remotes/origin/$GREEN" "$sha" 2>/dev/null
    return 0
  fi
  cur=$(git rev-parse -q --verify "origin/$GREEN" 2>/dev/null)
  if [ "${2:-}" = gated ] && [ "${AUTOCODER_GREEN_FORCE:-0}" = 1 ] && [ -n "$cur" ] && ! is_ancestor "$sha" "$cur"; then
    if git push -q "--force-with-lease=refs/heads/$GREEN:$cur" origin "$sha:refs/heads/$GREEN" 2>/dev/null; then
      git update-ref "refs/remotes/origin/$GREEN" "$sha" 2>/dev/null
      echo "ℹ️  origin/$GREEN forced from ${cur:0:7} to ${sha:0:7} (AUTOCODER_GREEN_FORCE=1)"
      return 0
    fi
  fi
  echo "⚠️  origin/$GREEN did not fast-forward to ${sha:0:7}; leaving it where it is"
  return 1
}

fetch_tips() { git fetch -q --prune origin "+${TIPS}/*:${TIPS}/*" 2>/dev/null || true; }
publish_tip() {
  git push -q origin "$1:${TIPS}/$1-$2" 2>/dev/null || return 1
  git update-ref "${TIPS}/$1-$2" "$1" 2>/dev/null
}
# Newest recorded tip for issue $1 that is on $2 (a commit), or rc 1.
landed_tip_for_issue() {
  local sha
  while read -r sha; do
    is_ancestor "$sha" "$2" && { echo "$sha"; return 0; }
  done < <(git for-each-ref --sort=-committerdate --format='%(objectname)' "${TIPS}/*-$1")
  return 1
}
# Was the push $1 reverted by this sentinel somewhere in $1..$2? The revert commit's trailer
# is the record.
push_was_reverted() {
  git log --format='%(trailers:key=Autocoder-Reverts,valueonly)' "$1..$2" 2>/dev/null | grep -qx "$1"
}

# Recorded tips strictly after last_green and on the way to $1, oldest first, as
# "<sha> <issue>" lines. $1 itself is appended as a synthetic tip when nobody recorded it.
candidate_tips() {
  local tip="$1" sha name
  declare -A issue_of=()
  while read -r sha name; do
    issue_of["$sha"]="${name##*-}"
  done < <(git for-each-ref --format='%(objectname) %(refname)' "${TIPS}/")
  while read -r sha; do
    [ -n "${issue_of[$sha]+x}" ] && echo "$sha ${issue_of[$sha]}"
  done < <(git rev-list --topo-order --reverse --ancestry-path "^$last_green" "$tip")
  [ -n "${issue_of[$tip]+x}" ] || echo "$tip unknown"
}

# ── issues ────────────────────────────────────────────────────────────────────────────────
issue_is_open()   { issue_get "$1" 2>/dev/null | grep -q '"state": *"OPEN"'; }
issue_has_label() { issue_get "$1" 2>/dev/null | grep -q "\"name\": *\"$2\""; }
issue_mentions()  { issue_get "$1" 2>/dev/null | grep -q "$2"; }
issue_ref()       { if [[ "$1" =~ ^[0-9]+$ ]]; then echo "#$1"; else echo "an unrecorded push"; fi; }
open_issues_with_label() {
  issue_list --state open --label "$1" 2>/dev/null | python3 -c '
import json, sys
try:
    rows = json.load(sys.stdin)
except Exception:
    rows = []
for r in rows:
    if str(r.get("state", "OPEN")).upper() == "OPEN" and r.get("number") is not None:
        print(r["number"])'
}
# An open test-failure issue whose title starts with $1, so a crash between filing and
# saving state, or a second sentinel, never files a duplicate.
find_open_p0() {
  issue_list --state open --label test-failure 2>/dev/null | python3 -c '
import json, sys
p = sys.argv[1]
try:
    rows = json.load(sys.stdin)
except Exception:
    rows = []
for r in rows:
    if str(r.get("title", "")).startswith(p) and str(r.get("state", "OPEN")).upper() == "OPEN":
        print(r["number"]); break' "$1"
}
gate_tail() {
  printf '\n## Gate output (last 40 lines)\n```\n%s\n```' "$(tail -n 40 "$RED_LOG" 2>/dev/null)"
}

# ── repair ────────────────────────────────────────────────────────────────────────────────
CULPRIT="" CULPRIT_ISSUE="" PREV_GOOD="" REVERT="" NEW_ISSUE=""

# Probe one recorded tip. Reads the shared cache (a tip a worker gated is free) but writes
# its own verdicts to the per-repair cache $2, so a flaky fail here never poisons the record
# the merge jobs and promote.sh trust.
probe_tip() {
  local tree
  worktree_at "$1" || return 1
  tree=$(git rev-parse "$1^{tree}")
  if [ "$(gate_cache_get "$tree" "$TEST_CMD" 2>/dev/null)" = pass ]; then
    echo "gate-cache: pass recorded for tree ${tree:0:8}; not re-running" >> "$GATE_LOG.bisect"
    return 0
  fi
  AUTOCODER_GATE_CACHE_DIR="$2" GATE_CACHE_REUSE_FAIL=1 gate_cache_run "$WT" "$TEST_CMD" >> "$GATE_LOG.bisect" 2>&1
}

# Binary search over the recorded tips for the first bad one. Sets CULPRIT, CULPRIT_ISSUE,
# PREV_GOOD (the recorded tip before it, else last_green).
bisect_tips() {
  local tip="$1" cache="$STATE_FILE.bisect-cache.$1" lo hi mid sha issue
  local -a tips
  rm -rf "$cache"
  mapfile -t tips < <(candidate_tips "$tip")
  [ "${#tips[@]}" -ge 1 ] || return 1
  : > "$BISECT_LOG"
  printf 'recorded tips after %s (oldest first):\n' "$last_green" >> "$BISECT_LOG"
  printf '  %s\n' "${tips[@]}" >> "$BISECT_LOG"
  lo=0; hi=$(( ${#tips[@]} - 1 ))
  while [ "$lo" -lt "$hi" ]; do
    mid=$(( (lo + hi) / 2 ))
    sha="${tips[mid]%% *}"; issue="${tips[mid]#* }"
    if probe_tip "$sha" "$cache"; then
      echo "good $sha (issue $issue)" >> "$BISECT_LOG"; lo=$((mid + 1))
    else
      echo "bad  $sha (issue $issue)" >> "$BISECT_LOG"; hi=$mid
    fi
  done
  rm -rf "$cache"
  CULPRIT="${tips[lo]%% *}"; CULPRIT_ISSUE="${tips[lo]#* }"
  if [ "$lo" -gt 0 ]; then PREV_GOOD="${tips[lo-1]%% *}"; else PREV_GOOD="$last_green"; fi
  echo "first bad push: $CULPRIT (issue $CULPRIT_ISSUE), previous good tip $PREV_GOOD" >> "$BISECT_LOG"
}

# Commit the reverse of the culprit push (the tree diff PREV_GOOD..CULPRIT) on top of $1.
# Sets REVERT. A conflict means a later push built on the culprit's change; a human decides.
make_revert() {
  worktree_at "$1" || return 1
  if ! git -C "$WT" diff --binary "$PREV_GOOD" "$CULPRIT" | git -C "$WT" apply -R --3way --index >/dev/null 2>&1; then
    git -C "$WT" reset -q --hard >/dev/null 2>&1
    echo "⚠️  Reverting push ${CULPRIT:0:7} on ${1:0:7} conflicts; leaving it to a human."
    return 1
  fi
  if git -C "$WT" diff --cached --quiet; then
    echo "⚠️  Push ${CULPRIT:0:7} changes nothing against ${PREV_GOOD:0:7}; nothing to revert."
    return 1
  fi
  git -C "$WT" commit -q -m "Revert autocoder push ${CULPRIT:0:7} (issue $(issue_ref "$CULPRIT_ISSUE"))" \
    -m "Range ${PREV_GOOD}..${CULPRIT}" \
    -m "Autocoder-Reverts: ${CULPRIT}
Autocoder-Reverts-Issue: ${CULPRIT_ISSUE}" >/dev/null 2>&1 || return 1
  REVERT=$(git -C "$WT" rev-parse HEAD)
}

reland_howto() {
  echo "To re-land: branch from \`${INTEGRATION}\`, \`git revert ${1}\`, fix the regression, then land again through /fix."
}

# The P0 for a repair, filed BEFORE the push so its number can be recorded as intent. One
# per culprit: a retry after a failed push finds the open one. Sets NEW_ISSUE, red_issue.
file_repair_p0() {
  local tip="$1" title body out
  title="Reverted ${CULPRIT:0:7} on ${INTEGRATION} (issue $(issue_ref "$CULPRIT_ISSUE")): regression gate red"
  NEW_ISSUE=$(find_open_p0 "Reverted ${CULPRIT:0:7} on ${INTEGRATION}")
  if [ -n "$NEW_ISSUE" ]; then
    red_issue="$NEW_ISSUE"; state_save
    return 0
  fi
  body="The integration branch \`${INTEGRATION}\` failed its regression gate at \`${tip}\`.

Gate: \`${TEST_CMD}\`

Culprit push: \`${CULPRIT}\` (issue $(issue_ref "$CULPRIT_ISSUE")), range \`${PREV_GOOD}..${CULPRIT}\`.
Every other recorded push is kept; only this push's change is reverted. A comment below names the revert commit once it is on \`${INTEGRATION}\`.

$(reland_howto "<revert-sha>")

## Bisect over recorded tips
\`\`\`
$(cat "$BISECT_LOG")
\`\`\`
$(gate_tail)"
  out=$(issue_create --title "$title" --body "$body" --label P0 --label test-failure) || { echo "❌ issue_create failed" >&2; return 1; }
  NEW_ISSUE=$(printf '%s' "$out" | grep -oE '[0-9]+' | tail -1)
  [ -n "$NEW_ISSUE" ] || return 1
  red_issue="$NEW_ISSUE"; state_save
}

# After the revert is verified on origin: tip ref, green ref, comments, state. Idempotent, so
# a tick that finds pending_revert already on origin can run it again.
finish_revert() {
  local note
  publish_tip "$REVERT" "$NEW_ISSUE" || echo "⚠️  Could not publish tip ref for ${REVERT:0:7}"
  push_green "$REVERT" "${1:-gated}" || true
  if [ -n "$NEW_ISSUE" ] && ! issue_mentions "$NEW_ISSUE" "$REVERT"; then
    issue_comment "$NEW_ISSUE" --body "🔁 Reverted push \`${CULPRIT}\` as \`${REVERT}\` on \`${INTEGRATION}\`; \`${GREEN}\` points at it. $(reland_howto "$REVERT")" >/dev/null 2>&1 || true
  fi
  if [[ "$CULPRIT_ISSUE" =~ ^[0-9]+$ ]] && ! issue_mentions "$CULPRIT_ISSUE" "$REVERT"; then
    note="⚠️ Regression: push \`${CULPRIT}\` from this issue (range \`${PREV_GOOD}..${CULPRIT}\`) broke the \`${INTEGRATION}\` gate and was reverted as \`${REVERT}\`. Tracking: #${NEW_ISSUE}. $(reland_howto "$REVERT")"
    if issue_is_open "$CULPRIT_ISSUE" && { issue_has_label "$CULPRIT_ISSUE" awaiting-integration || issue_has_label "$CULPRIT_ISSUE" merging; }; then
      issue_requeue "$CULPRIT_ISSUE" --comment "$note"
    else
      issue_comment "$CULPRIT_ISSUE" --body "$note" >/dev/null 2>&1 || true
    fi
  fi
  last_green="$REVERT"; last_tested="$REVERT"; red_issue=""
  clear_pending
  state_save
}

# Find the culprit among the recorded tips, revert that push on the current tip, gate, push
# with a retry loop that rebuilds the revert on whatever tip wins the race. Returns 0 only
# once the revert is verified on origin/<integration> and the bookkeeping is done.
repair() {
  local tip="$1" attempt base new files reason
  CULPRIT="" CULPRIT_ISSUE="" PREV_GOOD="" REVERT="" NEW_ISSUE=""
  if [ -z "$last_green" ] || ! is_ancestor "$last_green" "$tip"; then
    echo "ℹ️  No green baseline that is an ancestor of ${tip:0:7}; cannot bisect."
    return 1
  fi
  echo "🔍 Bisecting recorded pushes in ${last_green:0:7}..${tip:0:7}"
  : > "$GATE_LOG.bisect"
  bisect_tips "$tip" || { echo "⚠️  No recorded pushes after ${last_green:0:7}."; return 1; }
  echo "🎯 Culprit push ${CULPRIT:0:7} (issue $(issue_ref "$CULPRIT_ISSUE")), range ${PREV_GOOD:0:7}..${CULPRIT:0:7}"
  if [ "$REPORT_ONLY" = 1 ]; then
    echo "ℹ️  Report-only: not reverting; filing the P0 for a human to decide."
    return 1
  fi
  make_revert "$tip" || return 1
  gate || { echo "⚠️  Still red after reverting push ${CULPRIT:0:7}."; return 1; }
  files=$(mktemp "$STATE_DIR/.revert-files.XXXXXX")
  git diff --name-only --no-renames "$PREV_GOOD" "$CULPRIT" > "$files"
  file_repair_p0 "$tip" || { rm -f "$files"; return 1; }

  base="$tip"
  for attempt in 1 2 3 4 5 6 7 8; do
    pending_revert="$REVERT" pending_culprit="$CULPRIT" pending_issue="$CULPRIT_ISSUE" pending_p0="$NEW_ISSUE"
    state_save
    if git -C "$WT" push -q origin "HEAD:refs/heads/$INTEGRATION" 2>/dev/null; then
      git fetch -q origin "$INTEGRATION" 2>/dev/null
      if is_ancestor "$REVERT" "origin/$INTEGRATION"; then
        finish_revert gated
        rm -f "$files"
        return 0
      fi
    fi
    echo "⚠️  Push to '$INTEGRATION' rejected; rebuilding the revert on the new tip (attempt $attempt/8)"
    git fetch -q origin "$INTEGRATION" || break
    new=$(git rev-parse "origin/$INTEGRATION")
    [ "$new" = "$base" ] && continue
    make_revert "$new" || break
    if reason=$(regate_needed "$files" "$base" "$new" "$REPO"); then
      echo "ℹ️  Incoming work touches ${reason}; re-gating the rebuilt revert"
      gate || { echo "⚠️  Red after rebuilding the revert on ${new:0:7}."; break; }
    fi
    base="$new"
  done
  clear_pending; state_save
  rm -f "$files"
  return 1
}

# A previous tick recorded a revert it was about to push and died. If the revert is on
# origin, finish its bookkeeping; otherwise forget it (the next repair rebuilds it).
resume_pending() {
  [ -n "$pending_revert" ] || return 0
  if is_ancestor "$pending_revert" "origin/$INTEGRATION"; then
    REVERT="$pending_revert" CULPRIT="$pending_culprit" CULPRIT_ISSUE="$pending_issue" NEW_ISSUE="$pending_p0"
    PREV_GOOD=$(git log -1 --format=%b "$REVERT" 2>/dev/null | sed -n 's/^Range \([0-9a-f]*\)\.\..*/\1/p')
    echo "♻️  Finishing bookkeeping for revert ${REVERT:0:7} pushed by an earlier tick"
    finish_revert ""
  else
    echo "♻️  Dropping unpushed pending revert ${pending_revert:0:7}"
    clear_pending; state_save
  fi
}

# The P0 for a red tip nobody repaired. Reuses the open one (title prefix) when present.
file_red() {
  local tip="$1" title body out
  NEW_ISSUE=$(find_open_p0 "Regression gate red on ${INTEGRATION}")
  [ -n "$NEW_ISSUE" ] && return 0
  title="Regression gate red on ${INTEGRATION} at ${tip:0:7}"
  body="The integration branch \`${INTEGRATION}\` failed its regression gate at \`${tip}\`.

Gate: \`${TEST_CMD}\`
"
  [ -n "$CULPRIT" ] && body+="Bisect over recorded pushes names \`${CULPRIT}\` (issue $(issue_ref "$CULPRIT_ISSUE")), range \`${PREV_GOOD}..${CULPRIT}\`.
"
  if [ "$REPORT_ONLY" = 1 ]; then
    body+="Report-only mode: the sentinel does not revert. A human decides whether to revert the culprit push on \`${INTEGRATION}\` or fix forward.
"
  else
    body+="Not repaired automatically: no usable green baseline, or the revert conflicted or stayed red. A human must fix or revert on \`${INTEGRATION}\`.
"
  fi
  [ -s "$BISECT_LOG" ] && body+="
## Bisect over recorded tips
\`\`\`
$(cat "$BISECT_LOG")
\`\`\`
"
  body+="$(gate_tail)"
  out=$(issue_create --title "$title" --body "$body" --label P0 --label test-failure) || { echo "❌ issue_create failed" >&2; return 1; }
  NEW_ISSUE=$(printf '%s' "$out" | grep -oE '[0-9]+' | tail -1)
}

# ── issues landed by a push ───────────────────────────────────────────────────────────────
# Close issue $1 whose push $2 is on origin/<integration>, when the sentinel has green proof
# that contains it and verify-shipped.sh agrees; otherwise park it under
# `awaiting-integration` (a later green tick closes it). A push this sentinel reverted is
# left alone: its issue was told how to re-land.
close_or_park() {
  local num="$1" sha="$2" green="${3:-$last_green}" ship_branch
  if [ -n "$green" ] && push_was_reverted "$sha" "$green"; then
    return 0
  fi
  if [ -n "$green" ] && is_ancestor "$sha" "$green" && "${_MS_DIR}/verify-shipped.sh" "$sha" >/dev/null 2>&1; then
    if issue_close "$num" --comment "✅ **Issue Resolved**

Landed as \`${sha}\`; \`${INTEGRATION}\` green at \`${green}\`.

🤖 Closed by main-sentinel.sh after the post-merge gate passed" >/dev/null 2>&1; then
      issue_update "$num" --remove-label awaiting-integration >/dev/null 2>&1 || true
      issue_update "$num" --remove-label merging >/dev/null 2>&1 || true
      echo "✅ issue #${num}: landed as ${sha:0:7}, closed"
    fi
    return 0
  fi
  issue_has_label "$num" awaiting-integration && return 0
  ship_branch="${CLAUDE_CODE_SHIP_BRANCH:-$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name 2>/dev/null || echo main)}"
  issue_update "$num" --remove-label merging >/dev/null 2>&1 || true
  issue_update "$num" --remove-label working >/dev/null 2>&1 || true
  issue_update "$num" --add-label awaiting-integration >/dev/null 2>&1 || true
  issue_comment "$num" --body "⏳ **Fix complete, not yet shipped — leaving this issue OPEN**

The work is merged to \`${INTEGRATION}\` as \`${sha}\`. It has **not** reached \`${ship_branch}\` with a green \`${INTEGRATION}\` behind it, so closing would assert something false.

Labelled \`awaiting-integration\` so it is findable rather than silently reopened as new work; the sentinel closes it once \`${INTEGRATION}\` is green past it and it is on \`${ship_branch}\`.

🤖 main-sentinel.sh" >/dev/null 2>&1 || true
  echo "⏳ issue #${num}: landed as ${sha:0:7}, parked under awaiting-integration"
}

# After a green tick at $1: every parked issue whose recorded push is on $1 gets closed.
close_parked_on_green() {
  local tip="$1" num sha
  while read -r num; do
    sha=$(landed_tip_for_issue "$num" "$tip") || continue
    close_or_park "$num" "$sha" "$tip"
  done < <(open_issues_with_label awaiting-integration)
}

# ── hand-offs ─────────────────────────────────────────────────────────────────────────────
# Workers hand issues to a detached merge job (label `merging`, older shape
# `awaiting-integration` + pidfile) and move on. The job's files are
# autocoder-merge-<repo-id>-<issue>.{pid,exit,run.sh} (one release of tolerance for the
# older autocoder-merge-<issue>.* names). Prints the base path of the newest shape present.
merge_job_base() {
  local b ext
  for b in "$TMP_ROOT/autocoder-merge-${REPO_ID}-$1" "$TMP_ROOT/autocoder-merge-$1"; do
    for ext in pid exit run.sh; do
      [ -e "$b.$ext" ] && { echo "$b"; return 0; }
    done
  done
  return 1
}
job_is_live() { local pid; pid=$(cat "$1.pid" 2>/dev/null); [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; }

reconcile_handoffs() {
  local num base sha pid
  declare -A seen=()
  while read -r num; do
    [ -n "${seen[$num]+x}" ] && continue
    seen["$num"]=1
    base=$(merge_job_base "$num") || base=""
    if [ -n "$base" ] && job_is_live "$base"; then
      continue
    fi
    if issue_has_label "$num" merging && sha=$(landed_tip_for_issue "$num" "origin/$INTEGRATION"); then
      close_or_park "$num" "$sha"
      continue
    fi
    [ -n "$base" ] && [ -f "$base.pid" ] && [ ! -f "$base.exit" ] || continue
    pid=$(cat "$base.pid" 2>/dev/null)
    if [ -f "$base.run.sh" ] && [ ! -f "$base.rerun" ]; then
      : > "$base.rerun"
      rm -f "$base.pid"
      setsid bash "$base.run.sh" < /dev/null > /dev/null 2>&1 &
      issue_comment "$num" --body "♻️ The detached merge job for this issue (pid ${pid:-?}) died before it reported a result; re-ran it once (\`$base.run.sh\`). A landed push is detected and not merged twice." >/dev/null 2>&1 || true
      echo "♻️  issue #${num}: merge job died; re-ran its run.sh"
      continue
    fi
    rm -f "$base.pid"
    issue_requeue "$num" --comment "⚠️ The detached merge job for this issue (pid ${pid:-?}) died before it reported a result and could not be re-run. Removed the in-flight label; the issue is re-queued for a worker to re-land."
    echo "♻️  issue #${num}: merge job died; re-queued"
  done < <(open_issues_with_label merging; open_issues_with_label awaiting-integration)

  # A finished job (--own-issue) has nobody reading its exit file any more; keep it a day
  # for humans and monitor-workers, then reap the set so the tmp root does not fill up.
  local pf
  for pf in "$TMP_ROOT"/autocoder-merge-*.exit; do
    [ -f "$pf" ] || continue
    job_is_live "${pf%.exit}" && continue
    [ -n "$(find "$pf" -mmin +1440 2>/dev/null)" ] || continue
    rm -f "${pf%.exit}".{pid,exit,run.sh,log,rerun}
  done
}

# ── housekeeping ──────────────────────────────────────────────────────────────────────────
# Tip refs far behind the green tip are history nobody will bisect again; keep the ones a
# parked issue still needs. Gate-cache records expire at 30 days.
prune() {
  local sha name issue
  local -a del=()
  declare -A parked=()
  if [ -n "$last_green" ]; then
    while read -r issue; do parked["$issue"]=1; done < <(open_issues_with_label awaiting-integration)
    while read -r sha name; do
      [ "$sha" = "$last_green" ] && continue
      issue="${name##*-}"
      [ -n "${parked[$issue]+x}" ] && continue
      is_ancestor "$sha" "$last_green" || continue
      [ "$(git rev-list --count "$sha..$last_green" 2>/dev/null)" -gt 200 ] || continue
      del+=("$name")
    done < <(git for-each-ref --format='%(objectname) %(refname)' "${TIPS}/")
    if [ "${#del[@]}" -gt 0 ] && git push -q origin --delete "${del[@]}" 2>/dev/null; then
      for name in "${del[@]}"; do git update-ref -d "$name" 2>/dev/null; done
      echo "🧹 pruned ${#del[@]} old tip ref(s)"
    fi
  fi
  gate_cache_prune 30
}

# Environments with auto:true (promote.sh, .autocoder.json "environments") follow every
# green tick. Their outcome never changes the tick's exit code: a refused promotion is the
# release gate doing its job, not a sentinel failure.
auto_promote() {
  [ -f "${_MS_DIR}/promote.sh" ] || return 0
  bash "${_MS_DIR}/promote.sh" --auto --repo "$REPO" --green-ref "$GREEN" --test-cmd "$TEST_CMD" 2>&1 | sed 's/^/   /'
  return 0
}

green_tick() {
  local tip="$1"
  push_green "$tip" gated || true
  last_green="$tip"; last_tested="$tip"
  if [ -n "$red_issue" ]; then
    if issue_is_open "$red_issue"; then
      issue_close "$red_issue" --comment "✅ \`${INTEGRATION}\` is green again at \`${tip}\`." >/dev/null 2>&1 \
        && echo "   closed #${red_issue} (green again)"
    fi
    red_issue=""
  fi
  state_save
  echo "✅ ${INTEGRATION} green at ${tip:0:7}"
  close_parked_on_green "$tip"
  auto_promote
}

tick() {
  local tip green
  state_load
  git fetch -q origin "$INTEGRATION" || { echo "❌ Could not fetch origin/${INTEGRATION}" >&2; return 1; }
  git fetch -q origin "+refs/heads/${GREEN}:refs/remotes/origin/${GREEN}" 2>/dev/null \
    || git update-ref -d "refs/remotes/origin/${GREEN}" 2>/dev/null
  fetch_tips
  tip=$(git rev-parse "origin/${INTEGRATION}") || return 1
  green=$(git rev-parse -q --verify "origin/${GREEN}" 2>/dev/null) && last_green="$green"
  prune_stale_worktrees
  resume_pending
  reconcile_handoffs
  if [ "$tip" = "$last_tested" ]; then
    echo "💤 ${INTEGRATION} idle at ${tip:0:7} (already gated)"
    prune
    return 0
  fi
  worktree_at "$tip" || return 1
  : > "$BISECT_LOG"
  if gate; then
    green_tick "$tip"
    prune
    return 0
  fi
  cp -f "$GATE_LOG" "$RED_LOG" 2>/dev/null
  echo "❌ ${INTEGRATION} red at ${tip:0:7}"
  if repair "$tip"; then
    echo "🔁 reverted push ${CULPRIT:0:7} as ${REVERT:0:7}; filed #${NEW_ISSUE}"
    close_parked_on_green "$REVERT"
    auto_promote
    prune
    return 0
  fi
  if [ -n "$red_issue" ] && issue_is_open "$red_issue"; then
    issue_comment "$red_issue" --body "Still red: \`${INTEGRATION}\` fails the gate at \`${tip}\`.${CULPRIT:+ Bisect names push \`${CULPRIT:0:7}\`.}" >/dev/null 2>&1
    echo "   updated #${red_issue}"
  else
    file_red "$tip" && red_issue="$NEW_ISSUE"
    echo "   filed #${red_issue}"
  fi
  last_tested="$tip"
  state_save
  prune
  return 3
}

locked_tick() {
  local rc
  exec 9>"$STATE_FILE.lock"
  if ! flock -n 9; then
    echo "⏳ another tick is running on ${REPO_ID}-${INTEGRATION} (lock ${STATE_FILE}.lock); exiting"
    exec 9>&-
    return 0
  fi
  tick; rc=$?
  drop_worktree
  flock -u 9; exec 9>&-
  return "$rc"
}

if [ -n "$LOOP" ]; then
  while :; do
    locked_tick
    sleep "$LOOP"
  done
fi
locked_tick
