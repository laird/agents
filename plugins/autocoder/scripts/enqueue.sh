#!/usr/bin/env bash
# enqueue.sh — bank a finished branch from a host that does NOT gate.
#
# Some hosts cannot run the project's pre-check or gate (missing tools, child processes a
# supervisor stops, a database that is not there), and a pre-check that stalls for hours or fails
# on files the branch never touched is worse than none. On such a host a worker ENQUEUES instead:
# a short PREFLIGHT proves the branch is current and whole, the branch is pushed, and the READY
# comment the merge queue reads (merge-train.py, train_lib.pick_ready) is posted with the
# preflight block in it. The queue takes it as a first-class item whose first full test is the
# batch gate on a gate host; nothing here gates, and nothing here pushes the integration branch.
#
# The preflight, in order, stopping at the first FAIL (the rest print SKIP):
#   fetch        git fetch <remote>
#   rebase       the working tree must be clean; HEAD is rebased onto <remote>/<integration>
#                when it is behind (a conflict aborts the rebase and FAILS naming the files)
#   merge-tree   git merge-tree --write-tree <remote>/<integration> HEAD is clean
#   preflight    the project's own preflight command when one is configured (it prints its own
#                rows; its exit status is the row's), ELSE the two generic rows below
#   build        the project's build-or-typecheck command over what changed, when configured
#   tests        the project's test command over the CHANGED TEST FILES (`{files}`), when
#                configured and at least one changed file matches the test pattern
#   push         git push --force-with-lease <remote> HEAD:refs/heads/<branch> (the rebase moved
#                the tip; the lease refuses to overwrite a tip this host never saw)
#   ready        the READY comment (`READY `<branch>` @ <tip>`, the block, the --note lines),
#                the ready labels added, the working label removed, a `ready` landing-timings row
#
# Commands the project configures run through `bash -c` in the repository root with
#   AUTOCODER_ENQUEUE_BASE          the integration tip the branch sits on (a sha)
#   AUTOCODER_ENQUEUE_INTEGRATION   the integration branch name
#   AUTOCODER_ENQUEUE_CHANGED_FILE  a file listing the changed paths, one per line
#   AUTOCODER_ENQUEUE_TEST_FILES    (tests row) the changed test files, space-separated
#
# Usage:
#   enqueue.sh --issue N [--branch B] [--repo DIR] [--remote NAME] [--integration BRANCH]
#              [--preflight-cmd CMD] [--build-cmd CMD] [--test-cmd CMD] [--test-pattern REGEX]
#              [--add-label L]... [--remove-label L]... [--note TEXT]...
#              [--no-fetch] [--no-push] [--no-post] [--block-only]
#
# Configuration, lowest precedence first: the `train.enqueue` object of the main worktree's
# .autocoder.json {preflightCmd, buildCmd, testCmd, testPattern, workingLabel}, the environment
# (AUTOCODER_ENQUEUE_PREFLIGHT_CMD, _BUILD_CMD, _TEST_CMD, _TEST_PATTERN, _WORKING_LABEL), then
# the flags. The ready labels are `train.readyLabels` (default ready-for-review); the working
# label removed at READY defaults to `working`. The integration branch and remote default to
# the queue's (AUTOCODER_TRAIN_INTEGRATION / _REMOTE, `train.integration` / `train.remote`, the
# remote HEAD, master).
#
# Exit: 0 enqueued (or the block printed with --block-only); 1 the preflight failed (nothing was
# pushed or posted); 2 usage; 3 the tracker refused the comment or a label (the branch IS pushed:
# say READY by hand, the block is in the output).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO="." REMOTE="" INTEGRATION="" BRANCH="" ISSUE=""
PREFLIGHT_CMD="${AUTOCODER_ENQUEUE_PREFLIGHT_CMD-}" BUILD_CMD="${AUTOCODER_ENQUEUE_BUILD_CMD-}"
TEST_CMD="${AUTOCODER_ENQUEUE_TEST_CMD-}" TEST_PATTERN="${AUTOCODER_ENQUEUE_TEST_PATTERN-}"
WORKING_LABEL="${AUTOCODER_ENQUEUE_WORKING_LABEL-}"
ADD_LABELS=() REMOVE_LABELS=() NOTES=()
NO_FETCH=0 NO_PUSH=0 NO_POST=0 BLOCK_ONLY=0
FLAG_PREFLIGHT="" FLAG_BUILD="" FLAG_TEST="" FLAG_PATTERN="" FLAG_WORKING=""

usage() { sed -n '2,/^set -uo pipefail/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --issue) ISSUE="$2"; shift 2 ;;
    --branch) BRANCH="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --remote) REMOTE="$2"; shift 2 ;;
    --integration) INTEGRATION="$2"; shift 2 ;;
    --preflight-cmd) FLAG_PREFLIGHT="$2"; shift 2 ;;
    --build-cmd) FLAG_BUILD="$2"; shift 2 ;;
    --test-cmd) FLAG_TEST="$2"; shift 2 ;;
    --test-pattern) FLAG_PATTERN="$2"; shift 2 ;;
    --working-label) FLAG_WORKING="$2"; shift 2 ;;
    --add-label) ADD_LABELS+=("$2"); shift 2 ;;
    --remove-label) REMOVE_LABELS+=("$2"); shift 2 ;;
    --note) NOTES+=("$2"); shift 2 ;;
    --no-fetch) NO_FETCH=1; shift ;;
    --no-push) NO_PUSH=1; shift ;;
    --no-post) NO_POST=1; shift ;;
    --block-only) BLOCK_ONLY=1; NO_PUSH=1; NO_POST=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "enqueue: unknown argument '$1' (see --help)" >&2; exit 2 ;;
  esac
done
[ -n "$ISSUE" ] || { echo "enqueue: --issue N is required" >&2; exit 2; }
[[ "$ISSUE" =~ ^[0-9A-Za-z._-]+$ ]] || { echo "enqueue: --issue must be an issue id, got '$ISSUE'" >&2; exit 2; }
REPO="$(cd "$REPO" 2>/dev/null && pwd)" || { echo "enqueue: --repo is not a directory" >&2; exit 2; }
cd "$REPO" || exit 2
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "enqueue: $REPO is not a git work tree" >&2; exit 2; }

# ── configuration: .autocoder.json `train` and `train.enqueue`, then the environment, then the flags ──
_main_worktree() { git worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | head -1; }
_cfg() {  # <dotted key>: the value of .autocoder.json's key, empty when absent
  local path; path="$(_main_worktree)/.autocoder.json"
  [ -f "$path" ] || return 0
  python3 - "$path" "$1" <<'PY' 2>/dev/null
import json, sys
try:
    v = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for k in sys.argv[2].split("."):
    v = v.get(k) if isinstance(v, dict) else None
if isinstance(v, list):
    print(" ".join(str(x) for x in v))
elif v not in (None, ""):
    print(v)
PY
}
[ -n "$REMOTE" ] || REMOTE="${AUTOCODER_TRAIN_REMOTE:-$(_cfg train.remote)}"
[ -n "$REMOTE" ] || REMOTE=origin
if [ -z "$INTEGRATION" ]; then
  INTEGRATION="${AUTOCODER_TRAIN_INTEGRATION:-$(_cfg train.integration)}"
  if [ -z "$INTEGRATION" ]; then
    INTEGRATION="$(git symbolic-ref --short "refs/remotes/$REMOTE/HEAD" 2>/dev/null | sed "s@^$REMOTE/@@")"
    [ -n "$INTEGRATION" ] || { git show-ref --verify --quiet "refs/remotes/$REMOTE/main" && INTEGRATION=main; }
    [ -n "$INTEGRATION" ] || INTEGRATION=master
  fi
fi
[ -n "$PREFLIGHT_CMD" ] || PREFLIGHT_CMD="$(_cfg train.enqueue.preflightCmd)"
[ -n "$BUILD_CMD" ] || BUILD_CMD="$(_cfg train.enqueue.buildCmd)"
[ -n "$TEST_CMD" ] || TEST_CMD="$(_cfg train.enqueue.testCmd)"
[ -n "$TEST_PATTERN" ] || TEST_PATTERN="$(_cfg train.enqueue.testPattern)"
[ -n "$WORKING_LABEL" ] || WORKING_LABEL="$(_cfg train.enqueue.workingLabel)"
[ -n "$FLAG_PREFLIGHT" ] && PREFLIGHT_CMD="$FLAG_PREFLIGHT"
[ -n "$FLAG_BUILD" ] && BUILD_CMD="$FLAG_BUILD"
[ -n "$FLAG_TEST" ] && TEST_CMD="$FLAG_TEST"
[ -n "$FLAG_PATTERN" ] && TEST_PATTERN="$FLAG_PATTERN"
[ -n "$FLAG_WORKING" ] && WORKING_LABEL="$FLAG_WORKING"
[ -n "$TEST_PATTERN" ] || TEST_PATTERN='(^|/)(tests?|__tests__|spec)/|[._](test|spec)\.[A-Za-z0-9]+$|(^|/)test_[^/]*\.py$'
[ -n "$WORKING_LABEL" ] || WORKING_LABEL=working
READY_LABELS="$(_cfg train.readyLabels)"; [ -n "$READY_LABELS" ] || READY_LABELS=ready-for-review
[ -n "$BRANCH" ] || BRANCH="$(git symbolic-ref --short -q HEAD)"
[ -n "$BRANCH" ] || { echo "enqueue: HEAD is detached; name the branch with --branch" >&2; exit 2; }
case "$BRANCH" in "$INTEGRATION"|main|master|develop|uat|prod) echo "enqueue: refusing to enqueue the integration or an environment branch ($BRANCH)" >&2; exit 2 ;; esac

BASE_REF="$REMOTE/$INTEGRATION"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/autocoder-enqueue.XXXXXX")" || exit 1
trap 'rm -rf "$WORK"' EXIT
START=$SECONDS
RESULTS=() FIRST_FAIL="" BASE_SHA="" CHANGED_FILE="$WORK/changed.txt" PREFLIGHT_LOG="$WORK/project-preflight.log"

record() { RESULTS+=("$1|$2|$3|$4"); }
# run_row ID FUNCTION: runs one stage, records PASS/FAIL with seconds and its verdict (the
# function's last non-empty line); a stage after the first FAIL records SKIP and does not run.
run_row() {
  local id="$1" fn="$2" out status started=$SECONDS last
  if [ -n "$FIRST_FAIL" ]; then record "$id" SKIP 0 "not run: $FIRST_FAIL failed first"; return 0; fi
  out="$WORK/$id.log"
  "$fn" >"$out" 2>&1; status=$?
  echo "--- enqueue: $id"; cat "$out"
  last="$(grep -v '^[[:space:]]*$' "$out" | tail -1 | cut -c1-220)"
  if [ "$status" -eq 0 ]; then record "$id" PASS $((SECONDS - started)) "${last:-ok}"
  elif [ "$status" -eq 75 ]; then record "$id" SKIP $((SECONDS - started)) "${last:-skipped}"   # EX_TEMPFAIL: a named skip
  else record "$id" FAIL $((SECONDS - started)) "exit $status: ${last:-no output}"; FIRST_FAIL="$id"; fi
}

row_fetch() {
  if [ "$NO_FETCH" -eq 1 ]; then echo "fetch skipped (--no-fetch); $BASE_REF as this checkout has it"
  else git fetch -q "$REMOTE" || { echo "git fetch $REMOTE failed"; return 1; }; fi
  BASE_SHA="$(git rev-parse --verify --quiet "$BASE_REF^{commit}")" || { echo "$BASE_REF does not resolve in $REPO"; return 1; }
  echo "$BASE_REF at ${BASE_SHA:0:10}"
}

row_rebase() {
  local dirty behind conflicts
  dirty="$(git status --porcelain --untracked-files=no)"
  [ -z "$dirty" ] || { printf '%s\n' "$dirty" | head -10; echo "the working tree has uncommitted changes (above); commit or discard them first"; return 1; }
  behind="$(git rev-list --count "HEAD..$BASE_SHA")"
  if [ "$behind" -eq 0 ]; then echo "already on $BASE_REF (${BASE_SHA:0:10}), $(git rev-list --count "$BASE_SHA..HEAD") commit(s) ahead"; return 0; fi
  if ! git rebase -q "$BASE_SHA" >"$WORK/rebase.out" 2>&1; then
    conflicts="$(git diff --name-only --diff-filter=U | tr '\n' ' ')"
    git rebase --abort >/dev/null 2>&1 || true
    echo "rebase onto $BASE_REF (${BASE_SHA:0:10}) CONFLICTS in ${conflicts:-$(tail -3 "$WORK/rebase.out" | tr '\n' ' ')}; resolve on this host and run again (nothing was pushed)"
    return 1
  fi
  echo "rebased $(git rev-list --count "$BASE_SHA..HEAD") commit(s) onto $BASE_REF (${BASE_SHA:0:10}); was $behind behind"
}

row_merge_tree() {
  local tree
  if ! tree="$(git merge-tree --write-tree "$BASE_SHA" HEAD 2>&1)"; then
    echo "merge-tree against $BASE_REF (${BASE_SHA:0:10}) CONFLICTS:"; printf '%s\n' "$tree" | grep -E '^CONFLICT' | head -20; return 1
  fi
  git diff --name-only "$BASE_SHA" HEAD >"$CHANGED_FILE"
  echo "clean against $BASE_REF (${BASE_SHA:0:10}); $(grep -c . "$CHANGED_FILE") file(s) changed"
}

_project() {  # <command>: run a configured command in the repo root with the enqueue environment
  AUTOCODER_ENQUEUE_BASE="$BASE_SHA" AUTOCODER_ENQUEUE_INTEGRATION="$INTEGRATION" AUTOCODER_ENQUEUE_CHANGED_FILE="$CHANGED_FILE" \
    bash -c "$1" </dev/null
}

row_preflight() {
  echo "enqueue: running the project's preflight: $PREFLIGHT_CMD"
  _project "$PREFLIGHT_CMD" 2>&1 | tee "$PREFLIGHT_LOG"
  local rc=${PIPESTATUS[0]}
  [ "$rc" -eq 0 ] && echo "project preflight passed: $PREFLIGHT_CMD" || echo "project preflight FAILED (exit $rc): $PREFLIGHT_CMD"
  return "$rc"
}

row_build() {
  [ -n "$BUILD_CMD" ] || { echo "no build command configured (train.enqueue.buildCmd); the batch gate builds"; return 75; }
  _project "$BUILD_CMD" || { echo "build command FAILED: $BUILD_CMD"; return 1; }
  echo "build command passed: $BUILD_CMD"
}

row_tests() {
  local files
  [ -n "$TEST_CMD" ] || { echo "no test command configured (train.enqueue.testCmd); the batch gate is the test"; return 75; }
  files="$(grep -E -- "$TEST_PATTERN" "$CHANGED_FILE" | while IFS= read -r f; do [ -f "$f" ] && printf '%s\n' "$f"; done | tr '\n' ' ')"
  files="${files% }"
  [ -n "$files" ] || { echo "no test file changed (pattern: $TEST_PATTERN); the batch gate is the test"; return 75; }
  local cmd="${TEST_CMD//\{files\}/$files}"
  AUTOCODER_ENQUEUE_TEST_FILES="$files" _project "$cmd" || { echo "tests FAILED over the changed test files ($files): $cmd"; return 1; }
  echo "tests passed over the changed test file(s): $files"
}

row_push() {
  local head; head="$(git rev-parse HEAD)"
  if [ "$NO_PUSH" -eq 1 ]; then
    if [ "$BLOCK_ONLY" -eq 1 ]; then echo "push skipped (--block-only)"; return 0; fi
    local remote_tip; remote_tip="$(git rev-parse --verify --quiet "refs/remotes/$REMOTE/$BRANCH^{commit}" || true)"
    [ "$remote_tip" = "$head" ] || { echo "--no-push, but $REMOTE/$BRANCH is at ${remote_tip:-nothing}, not HEAD ${head:0:10}; push it or drop --no-push"; return 1; }
    echo "$REMOTE/$BRANCH already at ${head:0:10} (--no-push)"; return 0
  fi
  git push -q --force-with-lease "$REMOTE" "HEAD:refs/heads/$BRANCH" 2>"$WORK/push.err" || { echo "push refused: $(tr '\n' ' ' <"$WORK/push.err")"; return 1; }
  echo "$REMOTE/$BRANCH at ${head:0:10}"
}

run_row fetch row_fetch
run_row rebase row_rebase
run_row merge-tree row_merge_tree
if [ -n "$PREFLIGHT_CMD" ]; then run_row preflight row_preflight
else run_row build row_build; run_row tests row_tests; fi
run_row push row_push

# ── the block ──────────────────────────────────────────────────────────────────
HEAD_SHA="$(git rev-parse --short HEAD)"
VERDICT=PASS; [ -n "$FIRST_FAIL" ] && VERDICT=FAIL
BLOCK="$WORK/block.txt"
{
  echo "=== preflight (enqueue.sh): $VERDICT === tree $HEAD_SHA on $BASE_REF ${BASE_SHA:0:10} === host $(hostname -s 2>/dev/null || hostname) === $((SECONDS - START))s"
  for row in "${RESULTS[@]}"; do
    IFS='|' read -r id status secs detail <<<"$row"
    printf '%-4s %-12s %5ss  %s\n' "$status" "$id" "$secs" "$detail"
  done
  if [ -n "$FIRST_FAIL" ]; then echo "=== preflight: FAIL at $FIRST_FAIL -- fix it on this host and run again; nothing was posted ==="
  else echo "=== preflight: PASS -- not gated on this host; the batch gate is the test ==="; fi
} >"$BLOCK"
echo; cat "$BLOCK"
[ -z "$FIRST_FAIL" ] || exit 1
[ "$BLOCK_ONLY" -eq 0 ] || exit 0

# ── the READY comment ──────────────────────────────────────────────────────────
COMMENT="$WORK/comment.md"
{
  echo "READY \`$BRANCH\` @ $HEAD_SHA (enqueued from a host that does not gate: preflight only, no pre-check; the batch gate is the first full test)."
  echo; echo '```'; cat "$BLOCK"; echo '```'
  if [ -n "$PREFLIGHT_CMD" ] && [ -s "$PREFLIGHT_LOG" ]; then
    echo; echo "Project preflight (\`$PREFLIGHT_CMD\`), last lines:"; echo '```'; tail -40 "$PREFLIGHT_LOG"; echo '```'
  fi
  for n in "${NOTES[@]+"${NOTES[@]}"}"; do echo; echo "$n"; done
} >"$COMMENT"

if [ "$NO_POST" -eq 1 ]; then
  echo; echo "--- enqueue: READY comment (not posted, --no-post):"; cat "$COMMENT"; exit 0
fi

# shellcheck source=issue-fns.sh
source "$SCRIPT_DIR/issue-fns.sh"
landing_change() { :; }
# shellcheck source=landing-timings-lib.sh
[ -f "$SCRIPT_DIR/landing-timings-lib.sh" ] && source "$SCRIPT_DIR/landing-timings-lib.sh"
rc=0
issue_comment "$ISSUE" --body "$(cat "$COMMENT")" || { echo "enqueue: the tracker refused the READY comment on #$ISSUE (exit $?); the branch is pushed at $HEAD_SHA: post the block above by hand" >&2; rc=3; }
for lb in $READY_LABELS "${ADD_LABELS[@]+"${ADD_LABELS[@]}"}"; do
  issue_update "$ISSUE" --add-label "$lb" || { echo "enqueue: could not add label $lb on #$ISSUE" >&2; rc=3; }
done
for lb in "$WORKING_LABEL" "${REMOVE_LABELS[@]+"${REMOVE_LABELS[@]}"}"; do
  [ -n "$lb" ] || continue
  issue_update "$ISSUE" --remove-label "$lb" || { echo "enqueue: could not remove label $lb on #$ISSUE" >&2; rc=3; }
done
[ "$rc" -eq 0 ] || exit "$rc"
landing_change "$ISSUE" ready
added="$(printf '+%s ' $READY_LABELS "${ADD_LABELS[@]+"${ADD_LABELS[@]}"}")"
removed="$(printf -- '-%s ' "$WORKING_LABEL" "${REMOVE_LABELS[@]+"${REMOVE_LABELS[@]}"}")"
echo "enqueued #$ISSUE: READY \`$BRANCH\` @ $HEAD_SHA posted; labels ${added}${removed% }; the batch gate is the test"
