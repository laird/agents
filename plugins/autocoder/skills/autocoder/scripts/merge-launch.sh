#!/bin/bash
# merge-launch.sh — start merge-to-integration.sh fully DETACHED (#1693).
#
# WHY THIS EXISTS:
#   merge-to-integration.sh legitimately takes 25-30 minutes (it re-runs the
#   full regression gate on the combined tree). The /fix workflow used to
#   invoke it directly inside one foreground Bash-tool call, which agent
#   harnesses kill at a ~2-minute default timeout — a guaranteed failure, not
#   a flake. The kill sometimes tears down the merge script outright and
#   sometimes orphans its gate subtree (reparented to init, ppid=1), left
#   running with nothing to read its exit status and contending for host CPU
#   with live merges.
#
#   This script launches merge-to-integration.sh in a brand-new session via
#   `setsid`, with stdin/stdout/stderr fully detached from the caller, so a
#   killed caller (or a killed poller — see merge-poll.sh) can never take the
#   merge subtree down with it. It returns almost immediately; the caller
#   polls with merge-poll.sh.
#
#   It also resolves $FEATURE to a commit SHA before returning (#1821) and
#   passes that fixed SHA through, so the merge tests and pushes the tree that
#   was actually finished here — not whatever branch happens to be checked
#   out in this directory by the time the detached process gets scheduled.
#
# QUEUEING (#189):
#   Launching does not mean landing now. The detached job waits its turn on this host's
#   landing queue for the integration branch (merge-queue-fns.sh) before it fetches the
#   tip, so jobs launched together land one after another instead of racing a push. A
#   waiting job's log says "⏳ Queued: …".
#
# DUPLICATE DETECTION:
#   Refuses to start a second merge for the same issue while one is already
#   running — the caller should poll the existing job (merge-poll.sh) instead.
#   This makes re-entering this step after a restart/crash safe: launching
#   again is a no-op that just points back at the in-flight job.
#
# USAGE:
#   merge-launch.sh --feature <branch> --issue <num> \
#     [--integration <branch>] [--test-cmd "<cmd>"] \
#     [--summary-file <path>] [--own-issue]
#
#   Without --test-cmd the command is resolved from AGENTS.md / CLAUDE.md
#   ('### Regression Test Suite'), exactly as merge-to-integration.sh does, and
#   the launch is refused if none resolves (documents-only changes excepted) —
#   the caller sees the refusal now instead of in a detached log.
#
#   --summary-file and --own-issue pass straight through: with --own-issue the
#   detached job owns the issue from its first act (`working` → `merging`) to
#   its last (close, park under `awaiting-integration`, or escalate to
#   needs-clarification). The worker writes NO label after this returns; it
#   moves on. Nobody has to poll; merge-poll.sh remains for humans and
#   monitors who want to watch.
#
# State files, under the private temp root (autocoder_tmp_root, #213), keyed by <repo-id>-<issue>: only one
# worker holds an issue's lock at a time, and repo-id (repo-id-fns.sh: the main
# checkout's basename plus a hash of its git common dir) keeps two repos on one
# host from sharing state for the same issue number. The id is computed from
# the directory this is run in, so poll from the same checkout.
#   autocoder-merge-<repo-id>-<issue>.pid    — PID of the detached run
#   autocoder-merge-<repo-id>-<issue>.log    — merge-to-integration.sh output
#   autocoder-merge-<repo-id>-<issue>.exit   — its exit code, written on completion
#   autocoder-merge-<repo-id>-<issue>.run.sh — generated wrapper (avoids nested-quote hell)
#   autocoder-merge-<repo-id>-<issue>.scripts.XXXXXX/ — frozen copy of the scripts the
#                                               job runs (#212); removed when it finishes
#
# Exit codes:
#   0  launched (or an equivalent job was already running) — poll with merge-poll.sh
#   1  bad arguments, or no test command resolvable
set -uo pipefail

FEATURE=""
ISSUE_NUM=""
INTEGRATION_BRANCH="main"
TEST_CMD=""
SUMMARY_FILE=""
OWN_ISSUE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --feature)      FEATURE="$2"; shift 2 ;;
    --issue)        ISSUE_NUM="$2"; shift 2 ;;
    --integration)  INTEGRATION_BRANCH="${2:-main}"; shift 2 ;;
    --test-cmd)     TEST_CMD="$2"; shift 2 ;;
    --summary-file) SUMMARY_FILE="$2"; shift 2 ;;
    --own-issue)    OWN_ISSUE=1; shift ;;
    *) echo "merge-launch.sh: unknown arg '$1'" >&2; exit 1 ;;
  esac
done

if [ -z "$FEATURE" ] || [ -z "$ISSUE_NUM" ]; then
  echo "merge-launch.sh: --feature and --issue are required" >&2
  exit 1
fi
: "${INTEGRATION_BRANCH:=main}"

# Resolve the feature branch to a fixed commit NOW, synchronously, before the
# caller can move on. merge-to-integration.sh used to `git checkout "$FEATURE"`
# lazily, inside the detached background process, in whatever directory it
# inherited as CWD. The /fix loop routinely reuses that same directory for the
# NEXT issue before this merge finishes (#1821) — by the time the background
# process ran, the checkout had already been swapped out from under it, so the
# gate tested (and could push) an unrelated branch. A SHA captured here, before
# returning, is immune to every checkout that happens in this directory after
# we return. Empty is a valid fallback: merge-to-integration.sh re-resolves
# $FEATURE itself when no SHA is supplied (e.g. this isn't run inside a git
# checkout, as in tests/test_merge_launch_poll.sh's fixtures).
_MLI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The pushed origin/$FEATURE wins over a same-named local branch, which every
# worktree on the host shares and which may be a stray from another run (#143).
# shellcheck source=feature-ref-fns.sh
source "${_MLI_DIR}/feature-ref-fns.sh"
FEATURE_SHA=$(resolve_feature_sha "$PWD" "$FEATURE" || echo "")

# Inside a checkout, a name that resolves nowhere (not on origin, not local, not a
# commit) will fail in the detached job too, but only after it has handed the issue
# off to `merging`, and it then escalates to needs-clarification (#206). Refuse here
# instead, while nothing has started and no label has changed. resolve_feature_sha
# has already said why on stderr when the cause is a failed fetch.
if [ -z "$FEATURE_SHA" ] && git rev-parse --git-dir >/dev/null 2>&1; then
  echo "merge-launch.sh: could not resolve '${FEATURE}' on origin or locally." >&2
  echo "   Push it, or check the name, then launch again. Nothing was started; no label changed." >&2
  exit 1
fi

# shellcheck source=test-cmd-fns.sh
source "${_MLI_DIR}/test-cmd-fns.sh"
# shellcheck source=repo-id-fns.sh
source "${_MLI_DIR}/repo-id-fns.sh"
# shellcheck source=merge-archive-fns.sh
source "${_MLI_DIR}/merge-archive-fns.sh"

if [ -z "$TEST_CMD" ]; then
  TEST_CMD=$(resolve_test_cmd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")
  if [ -z "$TEST_CMD" ] && ! is_docs_only_diff "$(pwd)" "${FEATURE_SHA:-$FEATURE}" "$INTEGRATION_BRANCH"; then
    echo "merge-launch.sh: no test command — pass --test-cmd or add a '### Regression Test Suite' fenced block to AGENTS.md or CLAUDE.md. Not launching an untested merge." >&2
    exit 1
  fi
fi
# A private per-user directory, not shared /tmp (#213): see autocoder_tmp_root.
TMP_ROOT=$(autocoder_tmp_root) || { echo "merge-launch.sh: no private temp directory. Not launching." >&2; exit 1; }
export AUTOCODER_TMP="$TMP_ROOT"   # the job, poll and sentinel all resolve to this same root
STATE="${TMP_ROOT}/autocoder-merge-$(autocoder_repo_id "$PWD")-${ISSUE_NUM}"
LOG="${STATE}.log"
PIDFILE="${STATE}.pid"
EXITFILE="${STATE}.exit"
RUNSCRIPT="${STATE}.run.sh"

if [ -f "$PIDFILE" ]; then
  OLD_PID=$(cat "$PIDFILE" 2>/dev/null || echo "")
  if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    echo "ℹ️  A merge for issue #${ISSUE_NUM} is already running (pid ${OLD_PID}) — not starting a duplicate."
    echo "   Poll it with: ${_MLI_DIR}/merge-poll.sh --issue ${ISSUE_NUM}"
    exit 0
  fi
  # Stale pidfile from a finished/dead run — clear state before relaunching,
  # including a snapshot a killed job never got to remove (#212).
  rm -f "$PIDFILE" "$RUNSCRIPT"
  rm -rf "${STATE}".scripts.*
fi

# Keep every attempt (#184): archive the previous attempt's log and exit status as
# <state>.<n>.log/.exit (merge-archive-fns.sh). The current attempt keeps the plain
# names, which merge-poll.sh reads.
merge_archive_attempt "$STATE"
ATTEMPT=$(merge_next_attempt "$STATE")

: > "$LOG"
rm -f "$EXITFILE"

# Run a frozen snapshot of the scripts, not the live ones in this checkout (#212).
# The job runs for 8-30 minutes while this worker moves on: it switches branches
# and edits files, including these very scripts. Bash reads a running script
# incrementally, so an in-place change resumes the job at a byte offset into the
# new text and executes garbage (observed: "line 550: hip.: command not found",
# then a wrong exit path). Every top-level file is copied, not a computed list, so
# whatever merge-to-integration.sh sources or runs from its directory comes along.
# mktemp -d: a fresh, unpredictable, 0700 directory per launch, so nothing else can
# plant or swap files in it, and a second launch can never delete a running job's copy.
SNAPSHOT=""
if ! { SNAPSHOT=$(mktemp -d "${STATE}.scripts.XXXXXX") \
       && find "$_MLI_DIR" -maxdepth 1 -type f -exec cp -p {} "$SNAPSHOT"/ \; ; } \
   || [ ! -x "$SNAPSHOT/merge-to-integration.sh" ]; then
  echo "merge-launch.sh: could not snapshot ${_MLI_DIR} into ${SNAPSHOT:-a temp dir}. Not launching." >&2
  [ -n "$SNAPSHOT" ] && rm -rf "$SNAPSHOT"
  exit 1
fi

# Generate a real wrapper script rather than nesting this into a `bash -c`
# string: --test-cmd carries its own quoting-heavy shell (&&, quoted env vars,
# pipes), and re-quoting that into another layer of quotes is exactly the kind
# of fragility this fix is trying to remove. printf %q escapes it once, safely.
# Create it fresh and exclusively (noclobber = O_EXCL): whatever sat at this name
# before, including a planted symlink, is removed and never written through (#213).
rm -f "$RUNSCRIPT"
( set -o noclobber
{
  printf '#!/bin/bash\n'
  printf 'echo $$ > %q\n' "$PIDFILE"
  printf 'export AUTOCODER_MERGE_ATTEMPT=%q\n' "$ATTEMPT"
  printf '%q --feature %q --feature-sha %q --issue %q --integration %q --test-cmd %q' \
    "${SNAPSHOT}/merge-to-integration.sh" "$FEATURE" "$FEATURE_SHA" "$ISSUE_NUM" "$INTEGRATION_BRANCH" "$TEST_CMD"
  [ -n "$SUMMARY_FILE" ] && printf ' --summary-file %q' "$SUMMARY_FILE"
  [ "$OWN_ISSUE" -eq 1 ] && printf ' --own-issue'
  printf ' > %q 2>&1\n' "$LOG"
  printf 'echo $? > %q\n' "$EXITFILE"
  printf 'rm -rf %q\n' "$SNAPSHOT"
} > "$RUNSCRIPT" ) && chmod 700 "$RUNSCRIPT" && [ -O "$RUNSCRIPT" ] && [ ! -L "$RUNSCRIPT" ] || {
  # Never setsid a run.sh we did not just write ourselves (#213).
  echo "merge-launch.sh: could not write ${RUNSCRIPT} as this user. Not launching." >&2
  rm -rf "$SNAPSHOT"
  exit 1
}

setsid "$RUNSCRIPT" < /dev/null > /dev/null 2>&1 &
disown 2>/dev/null || true

# The pidfile is written by the wrapper itself (via $$, immune to any
# uncertainty about what `$!` refers to across setsid's fork-or-exec cases);
# give it a moment to land before returning.
for _ in 1 2 3 4 5; do
  [ -f "$PIDFILE" ] && break
  sleep 0.2
done

echo "🚀 merge-to-integration.sh launched detached for issue #${ISSUE_NUM}."
echo "   Log:  ${LOG}"
if [ "$OWN_ISSUE" -eq 1 ]; then
  echo "   The job closes or escalates the issue itself; watch it with: ${_MLI_DIR}/merge-poll.sh --issue ${ISSUE_NUM}"
else
  echo "   Poll: ${_MLI_DIR}/merge-poll.sh --issue ${ISSUE_NUM}"
fi
exit 0
