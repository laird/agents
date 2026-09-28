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
# DUPLICATE DETECTION:
#   Refuses to start a second merge for the same issue while one is already
#   running — the caller should poll the existing job (merge-poll.sh) instead.
#   This makes re-entering this step after a restart/crash safe: launching
#   again is a no-op that just points back at the in-flight job.
#
# USAGE:
#   merge-launch.sh --feature <branch> --issue <num> \
#     [--integration <branch>] [--test-cmd "<cmd>"]
#
# State files (keyed by issue number, since only one worker holds an issue's
# `working` lock at a time so this is unique per in-flight merge):
#   /tmp/autocoder-merge-<issue>.pid   — PID of the detached run
#   /tmp/autocoder-merge-<issue>.log   — merge-to-integration.sh output
#   /tmp/autocoder-merge-<issue>.exit  — its exit code, written on completion
#   /tmp/autocoder-merge-<issue>.run.sh — generated wrapper (avoids nested-quote hell)
#
# Exit codes:
#   0  launched (or an equivalent job was already running) — poll with merge-poll.sh
#   1  bad arguments, or (#2997/#2998) the repo's scripts/check-gate-command.sh
#      rejected the --test-cmd or could not produce one, or the resolved
#      --integration branch does not exist on the remote — nothing was launched
set -uo pipefail

FEATURE=""
ISSUE_NUM=""
INTEGRATION_BRANCH=""
TEST_CMD=""

while [ $# -gt 0 ]; do
  case "$1" in
    --feature)     FEATURE="$2"; shift 2 ;;
    --issue)       ISSUE_NUM="$2"; shift 2 ;;
    --integration) INTEGRATION_BRANCH="$2"; shift 2 ;;
    --test-cmd)    TEST_CMD="$2"; shift 2 ;;
    *) echo "merge-launch.sh: unknown arg '$1'" >&2; exit 1 ;;
  esac
done

if [ -z "$FEATURE" ] || [ -z "$ISSUE_NUM" ]; then
  echo "merge-launch.sh: --feature and --issue are required" >&2
  exit 1
fi

# Integration-branch resolution (#2998, second case: the same "silent default
# that diverges from the repo's own declared configuration" shape as the
# --test-cmd hole above). A hardcoded "main" default fails only after a full
# worktree checkout when the real integration branch is something else (e.g.
# master) -- CLAUDE.md's own AUTOCODER SWARM CONFIG note names exactly this
# fallback as a known trap ("a renamed heading silently falls back to a
# default ... rather than erroring"). An explicit --integration always wins;
# derive from CLAUDE.md's "### Integration Branch" fenced block only when
# none was supplied, and fall back to "main" -- loudly, on stderr -- only
# when that block genuinely cannot be read.
if [ -z "$INTEGRATION_BRANCH" ]; then
  CLAUDE_MD_FOR_INTEGRATION="$(pwd)/CLAUDE.md"
  RESOLVED_INTEGRATION=""
  if [ -f "$CLAUDE_MD_FOR_INTEGRATION" ]; then
    RESOLVED_INTEGRATION="$(awk '/^### Integration Branch$/{f=1;next} f&&/^```$/{g=1;next} g&&/^```$/{exit} g{print}' "$CLAUDE_MD_FOR_INTEGRATION" | grep -v '^[[:space:]]*$' | head -1)"
  fi
  if [ -n "$RESOLVED_INTEGRATION" ]; then
    INTEGRATION_BRANCH="$RESOLVED_INTEGRATION"
    echo "merge-launch.sh: no --integration supplied — resolved to '${INTEGRATION_BRANCH}' from ${CLAUDE_MD_FOR_INTEGRATION}'s '### Integration Branch' block."
  else
    INTEGRATION_BRANCH="main"
    echo "merge-launch.sh: no --integration supplied and ${CLAUDE_MD_FOR_INTEGRATION}'s '### Integration Branch' block could not be read — falling back to 'main'. Verify this is actually the repo's integration branch, or pass --integration explicitly." >&2
  fi
fi

# merge-to-integration.sh's `git fetch origin "$INTEGRATION_BRANCH"` only runs
# AFTER a full `git worktree add` checkout of $FEATURE — a nonexistent
# integration branch (wrong default, typo, or stale CLAUDE.md) wastes that
# entire checkout before failing (#2998). Check here, synchronously, before
# anything is launched, so a bad branch never even reaches the worktree step.
if ! git ls-remote --exit-code --heads origin "$INTEGRATION_BRANCH" >/dev/null 2>&1; then
  echo "merge-launch.sh: integration branch 'origin/${INTEGRATION_BRANCH}' does not exist on the remote — refusing to launch (this would otherwise fail only after a full worktree checkout, #2998)." >&2
  exit 1
fi

# Gate-command extraction/validation (#2814/#2997/#2998). A hand-retyped or
# re-quoted --test-cmd is exactly what #2814 hit: a misplaced closing quote
# silently moved stages outside their isolated-database wrapper with no error
# at launch time. Repos that maintain a canonical gate command can expose it
# via an executable scripts/check-gate-command.sh (contract: `--extract`
# prints the canonical command and exits 0; a candidate string as $1 exits 0
# if it matches, non-zero with a diagnostic on stderr otherwise). This is a
# no-op for any repo without that script — other projects using this plugin
# have no such convention and are unaffected.
GATE_CMD_SCRIPT="$(pwd)/scripts/check-gate-command.sh"
if [ -x "$GATE_CMD_SCRIPT" ]; then
  if [ -z "$TEST_CMD" ]; then
    if TEST_CMD="$("$GATE_CMD_SCRIPT" --extract)" && [ -n "$TEST_CMD" ]; then
      echo "merge-launch.sh: no --test-cmd supplied — defaulted to the canonical gate command via ${GATE_CMD_SCRIPT} --extract."
    else
      echo "merge-launch.sh: no --test-cmd supplied and ${GATE_CMD_SCRIPT} --extract produced none — refusing to launch a gate with no regression suite (#2992)." >&2
      exit 1
    fi
  elif ! "$GATE_CMD_SCRIPT" "$TEST_CMD"; then
    echo "merge-launch.sh: supplied --test-cmd failed validation against ${GATE_CMD_SCRIPT} — refusing to launch (see diagnostic above)." >&2
    exit 1
  fi
fi

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
FEATURE_SHA=$(git rev-parse "$FEATURE" 2>/dev/null || echo "")

_MLI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="/tmp/autocoder-merge-${ISSUE_NUM}.log"
PIDFILE="/tmp/autocoder-merge-${ISSUE_NUM}.pid"
EXITFILE="/tmp/autocoder-merge-${ISSUE_NUM}.exit"
RUNSCRIPT="/tmp/autocoder-merge-${ISSUE_NUM}.run.sh"

if [ -f "$PIDFILE" ]; then
  OLD_PID=$(cat "$PIDFILE" 2>/dev/null || echo "")
  if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    echo "ℹ️  A merge for issue #${ISSUE_NUM} is already running (pid ${OLD_PID}) — not starting a duplicate."
    echo "   Poll it with: ${_MLI_DIR}/merge-poll.sh --issue ${ISSUE_NUM}"
    exit 0
  fi
  # Stale pidfile from a finished/dead run — clear state before relaunching.
  rm -f "$PIDFILE" "$EXITFILE" "$RUNSCRIPT"
fi

: > "$LOG"
rm -f "$EXITFILE"

# Generate a real wrapper script rather than nesting this into a `bash -c`
# string: --test-cmd carries its own quoting-heavy shell (&&, quoted env vars,
# pipes), and re-quoting that into another layer of quotes is exactly the kind
# of fragility this fix is trying to remove. printf %q escapes it once, safely.
{
  printf '#!/bin/bash\n'
  printf 'echo $$ > %q\n' "$PIDFILE"
  printf '%q --feature %q --feature-sha %q --issue %q --integration %q --test-cmd %q > %q 2>&1\n' \
    "${_MLI_DIR}/merge-to-integration.sh" "$FEATURE" "$FEATURE_SHA" "$ISSUE_NUM" "$INTEGRATION_BRANCH" "$TEST_CMD" "$LOG"
  printf 'echo $? > %q\n' "$EXITFILE"
} > "$RUNSCRIPT"
chmod +x "$RUNSCRIPT"

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
echo "   Poll: ${_MLI_DIR}/merge-poll.sh --issue ${ISSUE_NUM}"
exit 0
