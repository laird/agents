#!/bin/bash
# merge-to-integration.sh — land a completed feature/enhancement branch on the shared
# integration branch (default: main) in a way that is safe for parallel git worktrees.
#
# WHY THIS EXISTS:
#   The /fix auto-merge step used to do `git checkout "$PARENT_BRANCH"; git merge; git push`,
#   where PARENT_BRANCH = the branch the worktree was currently on. In a parallel-worktree
#   swarm each worktree sits on its own `main-wt-N` branch (git forbids checking out `main`
#   in two worktrees at once), so fixes got merged into and pushed to per-worktree branches
#   and NEVER reached `main`. Work fragmented across main-wt-1/2/3 and was never integration-
#   tested together.
#
#   This helper instead lands the work on origin/<integration-branch> WITHOUT checking out
#   that branch locally (so it never contends with other worktrees), re-runs the test suite
#   on the combined tree, and pushes with a fetch+rebase+retry loop to survive sibling workers
#   racing to push. Conflicts and red gates go back to the owning worker (#207), and escalate to a human only on a repeat.
#
#   #1821: this used to do all of that IN the caller's own worktree — `git checkout
#   "$FEATURE"` right here, then fetch/merge/test/push in place. merge-launch.sh runs this
#   detached (#1693) so the caller can move on immediately; in practice the /fix loop reused
#   that same worktree for the NEXT issue's branch before this finished, so N gates ended up
#   sharing one working tree, each `git checkout`-ing a different branch into it mid-flight.
#   One gate's test run and push could observe (and push) a DIFFERENT branch's tree than the
#   one it was asked to verify — exactly the failure PUSH & MERGE CONTRACT exists to prevent.
#   The fix is isolation, not serialization: do all of this in a throwaway `git worktree add`
#   keyed to $ISSUE_NUM, so nothing another /fix iteration does to the caller's own checkout
#   can touch it. The throwaway worktree is removed unconditionally on exit — it exists only
#   to get this fix's tree tested and pushed, never to persist.
#
# GATE COST:
#   In 938 measured runs 41% of pushes lost the race to a sibling, and every lost race used
#   to re-run the full gate (8-30 minutes) on the re-synced tree. Three things cut that:
#
#   - Every gate run goes through gate-cache-fns.sh, keyed by <tree, command>. A tree this
#     host already recorded as passing (this worker earlier, or a sibling) is not run again.
#   - A rejected push re-gates only when the incoming commits overlap this change: a file
#     this fix touched, a global path (lockfiles, manifests, build config, CI), or a path
#     the gate command itself runs. A disjoint re-sync is pushed as-is; the success line
#     then names the gated tree and the published tree separately instead of claiming the
#     published tree was verified, and under --own-issue the issue is parked, not closed.
#       AUTOCODER_GATE_GLOBAL_PATHS  space-separated bash globs, matched against each
#         incoming path and its basename. The default is REGATE_GLOBAL_PATHS_DEFAULT in regate-fns.sh,
#         the one place the list lives: JS/TS, .NET, Go, Rust, Python and Ruby manifests
#         and lockfiles, Makefile, Dockerfile*, CI, the agent doctrine files, conftest.py.
#       Gate-command paths: every whitespace token of the gate command that names a file
#         or directory in the tree (e.g. tests/run-shell-suite.sh, scripts/) is global too,
#         a directory covering everything under it. The gate's own code changing is a
#         reason to re-run it, whatever this change touched.
#       AUTOCODER_SCOPED_REGATE  default 1; 0 re-gates every re-sync that brought in work,
#         for a repo that wants the integration branch itself kept strictly green.
#   - A re-sync whose incoming files are ALL documents (test-cmd-fns.sh's is_docs_path:
#     Markdown, reStructuredText, AsciiDoc, docs/, plus AUTOCODER_DOCS_PATHS, minus
#     AUTOCODER_DOCS_CODE_PATHS), none of them a file this change touched or a path the
#     gate command runs, never re-runs the test stages, whatever the green ref or
#     AUTOCODER_SCOPED_REGATE say: documents are not an input to a test suite, so a second
#     run proves nothing new (a design spec pushed every few minutes once put one gate
#     through five full passes with no code change under it). The published tree is
#     recorded as basis `docs-resync`, which closes the issue like `tested`; the success
#     line names the tested tree, the document count and the published tree.
#       AUTOCODER_DOCS_RESYNC_CMD  optional; a repo's cheap document checks, run on the
#         re-synced tree before it is pushed on that basis. When it fails the delta is
#         treated as code and the ordinary re-gate rule decides.
#   - When the gate fails on the integrated tree, origin/<integration> is gated ALONE in a
#     second throwaway worktree. If the base passes, this change broke it: exit 2. If the
#     base fails too WITH THE SAME NAMED FAILURES, the integration branch is red independent
#     of this change, so the work is pushed anyway and the issue is told so (the post-merge
#     sentinel owns red main). The base run re-runs THE FILES THAT FAILED on the integrated
#     tree (#298): their names (the gate cache's failed-test parser, worktree path cut)
#     cross as AUTOCODER_GATE_RETEST_FILES, space-separated, which a gate command that
#     selects tests by the tree's diff should honour, since on the base that diff is empty
#     and selects nothing. The run's cache record is keyed by the list, and the log says,
#     per file, whether it fails on the base too or passes there (this change's).
#     Two things are required before that comparison counts:
#       * neither run was an INFRASTRUCTURE refusal. A gate that stopped because the host
#         could not run it (a disk-space stage over its threshold, ENOSPC, a tool that is
#         missing, a stage reporting itself as INFRASTRUCTURE because its tool died) says
#         nothing about master or this change: the merge aborts with exit 3 before gating
#         the base (or after it, when the base run is the one refused), prints
#         `::error::merge-to-integration: INFRASTRUCTURE -- <cause>` naming the line that
#         decided it, forgets the gate cache's fail record for that tree (it is not a
#         verdict), and leaves the branch for a relaunch once the host is fixed. On
#         2026-11-16 a disk-space stage at exactly its threshold failed both runs the same
#         way and a branch landed with no test stage run on either tree.
#         AUTOCODER_GATE_INFRA_PATTERNS  extended regex (grep -E) over the run's output;
#           the default covers the `::error::<stage>: INFRASTRUCTURE` marker,
#           `::error::check-disk-space:`, ENOSPC / "No space left on device", a heap or
#           memory death and "command not found", EACH ANCHORED to the line the shell,
#           node, npm, python or the kernel prints (never the same words quoted inside a
#           failing test's assertion, which is a verdict on the tree). A repo appends its
#           own stage names, anchored the same way.
#       * both runs named what failed, and the sets are the same. Named failures are the
#         run's output lines matching AUTOCODER_GATE_FAILURE_PATTERNS (default: GitHub
#         `::error::` annotations, lines opening with ❌, vitest/jest/go `FAIL`, pytest
#         `FAILED`, go `--- FAIL:`, cargo `... FAILED`, ✗/× bullets), trimmed, durations
#         and 7+ hex-digit ids blanked, each run's own worktree path read as <worktree>,
#         sorted unique. A failure named on the integrated
#         tree only is this change's: exit 2, naming it. A run that names nothing is not a
#         verdict either: exit 2, saying so. The base run still happens whenever the
#         integrated run was not refused, so "the base passes alone" keeps its attribution.
#         A base red in every named file prints one `merge-to-integration: RED-BASE -- ...`
#         line (a close-out reads it: that red is the integration branch's, nobody's to own)
#         and the refusal or landing names red <integration>, never the change; a change that
#         broke something besides is charged for its own failures, the base's named apart.
#       AUTOCODER_MERGE_ON_RED_BASE  default 1; 0 restores exit 2 on a red base.
#     The base gated alone is the one the integrated tree was built on (its merge base with
#     a freshly fetched origin/<integration>), never a tip that moved during the gate
#     (#375). When the tip has moved, the failure is not judged at all: the change is
#     re-synced onto the new tip and gated again, at most AUTOCODER_MOVED_BASE_REGATES
#     (default 2) times per job; after that the old base is the one measured. The base
#     run never reuses a cached pass recorded under the plain command (another change's
#     diff-scoped run may not have selected the failing files); under a retest list its
#     key is that list, so a pass recorded for it stands.
#   - Both relaxations exist because a sentinel re-gates the integration tip after the
#     fact. Until one has proven a green tip at least once, there is nobody to catch what
#     a skipped re-gate or a red-base landing lets through, so both are OFF: every re-sync
#     re-gates and a red base refuses the merge. The proof is the green ref:
#       AUTOCODER_GREEN_REF  default <integration>-green; the relaxations apply only when
#         refs/heads/<green-ref> exists on origin. The mode is logged once per run.
#   - Overlap is measured with `git diff --name-only --no-renames`, so a sibling renaming a
#     file this change edits shows up as that file, not as an unrelated new path.
#   - Gates on one host share a cap (per user: the slots live in the per-user temp root, #213): each gate_cache_run takes one of AUTOCODER_MAX_GATES
#     slots (default max(1, nproc/4)), flock-held files
#     <tmp-root>/autocoder-gate-slot-<k>.lock, trying each in turn and blocking
#     on the last. A job that has to wait says so in its log.
#   - Landings on one host queue (#189): a job takes merge-queue-fns.sh's lock for its
#     (origin, integration branch) before it fetches the tip, and drops it once the push
#     is verified. Jobs behind it sync onto the new tip only when their turn comes, so two
#     jobs on one host never race a push or write a "push retry" re-sync commit. The wait
#     is logged ("⏳ Queued: …"). AUTOCODER_MERGE_QUEUE=0 turns it off;
#     AUTOCODER_MERGE_QUEUE_WAIT caps the wait (default 7200 s, then it lands unqueued).
#
# LANDING BY REBASE (#221):
#   The feature commits are rebased onto origin/<integration> and pushed as a fast-forward,
#   so the integration branch gets one linear series per issue and no merge commits (a
#   merge-based landing wrote a "pre-integration sync" merge and, after every lost push race,
#   a "Re-sync … push retry N" merge: 39 of 98 commits on one repo in 12 hours). What this
#   changes:
#   - The landed commit is the REBASED tip, not FEATURE_SHA. LANDED_SHA, the published tip
#     ref, verify-shipped.sh and the close comment all name it.
#   - The Pre-Landing Review record names the pre-rebase HEAD. A clean rebase is
#     mechanical, so the close comment says so and names both commits; a conflicted rebase
#     is aborted and bounced to the worker (kind=conflict, #207), who resolves it and has it
#     re-reviewed.
#   - Before that bounce, merge-conflict-fns.sh tries to resolve the conflict in this
#     job's worktree (#164): union-merge for files .autocoder.json "unionMerge" declares
#     append-only, then one bounded attempt by the "conflictResolver" command (off by
#     default; "claude" runs merge-conflict-claude.sh). A resolved tree is gated like any
#     other (a re-sync that needed resolving is always re-gated), and the close comment
#     names the resolved files. A refused attempt is attached to the bounce or escalation.
#   - A lost push race re-syncs by rebasing again; whether that re-gates follows the same
#     rules as before (scoped re-gate, documents-only re-sync, strict mode).
#   - The feature branch is deleted with a lease on FEATURE_SHA, the commit that was on
#     origin, never on the rebased tip.
#   - A rebase that leaves nothing to land (every commit is already upstream, e.g. a re-run
#     after an earlier job landed the same work) is treated like a feature SHA already on
#     origin/<integration>: nothing is gated or pushed. It closes the issue only when the
#     feature's change applies in reverse to the tip; otherwise it escalates.
#   - A feature branch containing merge commits is squashed to its net change first: a
#     plain rebase would drop whatever the merges carried.
#   - The rebase runs with hooks, rerere, signing, autosquash, autostash, update-refs and
#     rebase-merges pinned off, so user git config cannot change what lands.
#
# SCRATCH:
#   Everything this job writes outside the repo lives under the private temp root (autocoder_tmp_root, #213) and is
#   keyed by <repo-id>-<issue>, where repo-id is repo-id-fns.sh's autocoder_repo_id (the
#   main checkout's basename plus a hash of its git common dir), so two repos on one host
#   never share a worktree, log or state file for the same issue number:
#     autocoder-merge-<repo-id>-<issue>.gate.XXXXXX   gate output, for the failure comment
#     autocoder-merge-worktree-<repo-id>-<issue>[-base]  the throwaway worktrees, created
#                                                     only once the landing queue lets the job in
#     autocoder-merge-worktree-<repo-id>-<issue>.owner   the job's pid; a later job removes a
#                                                     worktree whose owner is dead (#144)
#   merge-launch.sh keys its .pid/.log/.exit/.run.sh files the same way.
#
# USAGE:
#   merge-to-integration.sh --feature <branch> --issue <num> \
#     [--feature-sha <sha>] [--integration <branch>] [--test-cmd "<cmd>"] \
#     [--summary-file <path>] [--own-issue]
#
#   --test-cmd is the gate. When omitted it is resolved from the repo's AGENTS.md (falling
#   back to CLAUDE.md), '### Regression Test Suite' fenced block. If that yields nothing the
#   merge is refused before any fetch/merge/push, unless the change is documents-only.
#
#   --feature-sha pins the exact commit to test/push, resolved by the caller before anything
#   could move the branch out from under it (merge-launch.sh does this). When omitted, this
#   script resolves $FEATURE itself in the directory it was started from — sufficient for
#   direct/manual invocations, but exactly the lazy resolution #1821 exists to avoid, so
#   every caller in this repo passes --feature-sha.
#
# OWNING THE ISSUE:
#   --own-issue makes this job the owner of the issue from the moment it starts, so the
#   worker that launched it can move on instead of polling for 8-30 minutes. The worker
#   owns open → working (claim); this job owns everything after, through the backend's
#   lifecycle verbs (issue-fns.sh: handoff, park, escalate, requeue), never raw labels:
#     first act, before anything that can fail
#        → issue_handoff: `working` → `merging`. The worker writes NO label after the
#          launch returns; its late writes used to overwrite this job's fast-path outcome.
#     landed, gate passed on the published tree (or docs-only), and verify-shipped.sh
#     says the commit is on the ship branch
#        → issue_close with "✅ Issue Resolved" and the --summary-file contents
#     landed on any other basis (disjoint re-sync, red base) or not on the ship branch
#        → issue_park: `awaiting-integration` with a comment naming the landed commit
#          and the gated trees. The post-merge sentinel closes a parked issue once its
#          landed commit is on a green tip. Only `tested` and `docs-only` may close.
#     conflict (exit 1), or a gate failure this change caused (exit 2: integrated tree
#     red, origin/<integration> alone green), before anything was pushed
#        → bounced back to the owning worker (#207): `merging` → `working`, with a
#          comment naming the conflicting files or the failing suites and ending in
#          `<!-- autocoder-bounce kind=<conflict|gate> worktree=<caller dir>
#          sha=<feature sha> sig=<sha1 of the sorted list> -->`. Both are mechanical
#          (rebase, re-test, relaunch), not questions for a human. Only an identical
#          repeat (the newest earlier bounce has the same kind and sig) escalates to
#          needs-clarification.
#     any other failure before anything was pushed (unresolvable ref, publish failure,
#     red base refused, an INFRASTRUCTURE refusal, base worktree could not be created)
#        → issue_escalate --label needs-clarification, comment with the reason and the
#          last 40 lines of gate output (exit 3's reason opens with INFRASTRUCTURE and
#          says the branch is intact and the merge is to be relaunched once the host is
#          fixed; nothing about the change is in doubt). The rebase step is read the same
#          way: a rebase the HOST stopped (ENOSPC writing a file, a memory death, a
#          missing tool; its output matched against AUTOCODER_GATE_INFRA_PATTERNS) leaves
#          no conflicted file, so it is not a conflict; it is retried once after
#          AUTOCODER_REBASE_INFRA_RETRY_DELAY seconds (default 30) and a second such stop
#          is the same exit 3 refusal, never "failed without a conflict" (exit 1).
#     internal error AFTER the push succeeded
#        → issue_park (the work is on the branch; nothing is lost), never an escalation
#   Every transition converges: an issue that is already closed is left alone (the whole
#   run is skipped and a stale `merging` is retired), a feature SHA already on
#   origin/<integration> is not merged or gated again, and an issue someone already
#   parked stays parked. Without --own-issue none of this runs and the exit codes below
#   are the only outcome.
#
# PUBLISHED TIPS:
#   After a verified push the landed commit is also published as
#   refs/autocoder/tips/<integration>/<landed-sha>-<issue>, so the sentinel can map a
#   green tip back to the issues it proves. Failure to publish the ref is logged, never
#   fatal.
#
# Returns:
#   0  merged + pushed to <integration>
#   1  conflict, push failure, setup failure, or no test command
#   2  tests failed on the integrated tree and origin/<integration> passes alone

set -uo pipefail

FEATURE=""
FEATURE_SHA=""
ISSUE_NUM=""
INTEGRATION_BRANCH="main"
TEST_CMD=""
SUMMARY_FILE=""
OWN_ISSUE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --feature)      FEATURE="$2"; shift 2 ;;
    --feature-sha)  FEATURE_SHA="$2"; shift 2 ;;
    --issue)        ISSUE_NUM="$2"; shift 2 ;;
    --integration)  INTEGRATION_BRANCH="${2:-main}"; shift 2 ;;
    --test-cmd)     TEST_CMD="$2"; shift 2 ;;
    --summary-file) SUMMARY_FILE="$2"; shift 2 ;;
    --own-issue)    OWN_ISSUE=1; shift ;;
    *) echo "merge-to-integration.sh: unknown arg '$1'" >&2; exit 1 ;;
  esac
done

if [ -z "$FEATURE" ] || [ -z "$ISSUE_NUM" ]; then
  echo "merge-to-integration.sh: --feature and --issue are required" >&2
  exit 1
fi
: "${INTEGRATION_BRANCH:=main}"

# Capture the directory we were started in BEFORE doing anything else. This is the caller's
# worktree — the source of truth for "where is $FEATURE's work" when no --feature-sha was
# given, and the source of node_modules et al. we hardlink into the throwaway worktree below.
# It is deliberately not assumed to still be checked out to $FEATURE by the time we act on it.
CALLER_DIR="$(pwd)"

# issue_update / issue_comment live in the shared issue backend layer next to this script.
_MTI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Where the plugin's scripts are, for a gate command that runs one (stage-runner.py). A hermetic gate
# (gate.env) must list it to see it.
export AUTOCODER_SCRIPTS_DIR="$_MTI_DIR"
# shellcheck source=issue-fns.sh
source "${_MTI_DIR}/issue-fns.sh"
# shellcheck source=regate-fns.sh
source "${_MTI_DIR}/regate-fns.sh"
# shellcheck source=worktree-deps-fns.sh
source "${_MTI_DIR}/worktree-deps-fns.sh"
# shellcheck source=merge-worktree-fns.sh
source "${_MTI_DIR}/merge-worktree-fns.sh"   # #144: prune worktrees left by dead jobs
# shellcheck source=test-cmd-fns.sh
source "${_MTI_DIR}/test-cmd-fns.sh"
# shellcheck source=gate-cache-fns.sh
source "${_MTI_DIR}/gate-cache-fns.sh"
# Merge-attempt events (#184). Optional: a partial script tree loses the record, not the merge.
merge_event() { :; }
# shellcheck source=merge-events-lib.sh
[ -f "${_MTI_DIR}/merge-events-lib.sh" ] && source "${_MTI_DIR}/merge-events-lib.sh"
# Landing timings: batch and change rows for landing-report.py. Optional like merge_event.
landing_change() { :; }
landing_batch() { :; }
# shellcheck source=landing-timings-lib.sh
[ -f "${_MTI_DIR}/landing-timings-lib.sh" ] && source "${_MTI_DIR}/landing-timings-lib.sh"
# shellcheck source=repo-id-fns.sh
source "${_MTI_DIR}/repo-id-fns.sh"
# Lifecycle events (#190), sourced by issue-fns.sh. This job runs in a throwaway worktree,
# so name the worker and branch it acts for (shell variables, not exported).
declare -F issue_event >/dev/null || issue_event() { :; }
AUTOCODER_WORKER="${AUTOCODER_WORKER:-$(basename "$CALLER_DIR")}"
AUTOCODER_EVENT_BRANCH="$FEATURE"
AUTOCODER_EVENT_NO_RELEASE=1   # its label cleanup is not the worker releasing the issue
# shellcheck source=feature-ref-fns.sh
source "${_MTI_DIR}/feature-ref-fns.sh"
# shellcheck source=merge-queue-fns.sh
source "${_MTI_DIR}/merge-queue-fns.sh"
# shellcheck source=merge-conflict-fns.sh
source "${_MTI_DIR}/merge-conflict-fns.sh"   # #164: resolve a conflicted rebase first
conflict_load_config "$CALLER_DIR"

TMP_ROOT=$(autocoder_tmp_root) || exit 1   # private per-user dir (#213)
REPO_ID=$(autocoder_repo_id "$CALLER_DIR")

# The global-path list (paths whose change can break any test) is REGATE_GLOBAL_PATHS_DEFAULT
# in regate-fns.sh, shared with main-sentinel.sh; AUTOCODER_GATE_GLOBAL_PATHS overrides it.
GREEN_REF="${AUTOCODER_GREEN_REF:-${INTEGRATION_BRANCH}-green}"

# Gate output is kept so a failure comment can quote it.
GATE_LOG=$(mktemp "${TMP_ROOT}/autocoder-merge-${REPO_ID}-${ISSUE_NUM}.gate.XXXXXX")
GATE_LAST="${GATE_LOG}.integrated"   # output of the latest integrated-tree gate only
REBASE_LOG="${GATE_LOG}.rebase"      # the latest rebase's own output, read for a host condition
trap '_rc=$?; merge_queue_release >/dev/null 2>&1; _emit_attempt_event "$_rc"; rm -f "$GATE_LOG" "$GATE_LAST" "$REBASE_LOG"' EXIT

# Per-host cap on concurrent gate runs. Slot k is held by flock on its lock file for as
# long as the gate runs; a run tries slots 1..N-1 without waiting and blocks on slot N.
MAX_GATES="${AUTOCODER_MAX_GATES:-}"
if ! [ "$MAX_GATES" -ge 1 ] 2>/dev/null; then
  MAX_GATES=$(( $(nproc 2>/dev/null || echo 4) / 4 ))
  [ "$MAX_GATES" -ge 1 ] || MAX_GATES=1
fi
_gate_in_slot() {  # <dir> "<test-cmd>": gate_cache_run inside one slot; rc is the gate's
  local dir="$1" cmd="$2" k lock rc
  for k in $(seq 1 "$MAX_GATES"); do
    lock="${TMP_ROOT}/autocoder-gate-slot-${k}.lock"
    if [ "$k" -lt "$MAX_GATES" ]; then
      ( flock -n 9 || exit 75; gate_cache_run "$dir" "$cmd" ) 9>>"$lock"
      rc=$?
      [ "$rc" -eq 75 ] && continue
      return "$rc"
    fi
    (
      if ! flock -n 9; then
        echo "⏳ All ${MAX_GATES} gate slot(s) on this host are busy; waiting for slot ${k} ($(date +%H:%M:%S))"
        flock 9
        echo "▶️  Gate slot ${k} acquired ($(date +%H:%M:%S))"
      fi
      gate_cache_run "$dir" "$cmd"
    ) 9>>"$lock"
    return $?
  done
}

# A gate run's verdict is read from the slice of GATE_LOG that run wrote (tee appends
# every run to it): the byte offset before the run, and the log from there afterwards.
# Two readers: an INFRASTRUCTURE line means the host could not run the gate, so the run
# is no verdict at all; the named-failure lines are what a red-base comparison compares.
# EVERY ALTERNATIVE IS ANCHORED TO THE LINE THE SHELL, NODE, NPM, PYTHON OR THE KERNEL PRINTS.
# The patterns are grepped over the WHOLE run output, so a free-text alternative (`command not
# found`, `ENOSPC`) also matched the text a failing test QUOTED in its own assertion
# (`AssertionError: expected '...' to match /...(bash: tsx: command not found)/`), and a plain
# red became "did not reach a verdict": no push, no attribution, a relaunch of the same work.
# The shapes, one per alternative:
#   ^::error::<stage>: INFRASTRUCTURE                   the marker (a stage's own refusal, or this script's)
#   ^<one space-free token> ::error::<stage>: INFRASTRUCTURE --   the marker behind a log prefix
#   ^::error::check-disk-space:                         a disk stage from before it carried the marker
#   ^[Error: ENOSPC: ...                                node (`Error:`, `SystemError:`, `[Error:`)
#   ^npm ERR! code ENOSPC / ^npm error nospc ENOSPC:    npm's rows
#   ^OSError: [Errno 28] No space left on device, [Errno 12] Cannot allocate memory   python
#   ^fatal: Out of memory, malloc failed (tried to allocate N bytes)   git's own memory death
#   ...: No space left on device$ / ...: Cannot allocate memory$   libc's strerror ending a line
#        (git's `fatal: write error:`, cp's `error writing 'x':`, bash's `fork:`)
#   ^FATAL ERROR: ... JavaScript heap out of memory$    V8's abort, no quote anywhere on the line
#   ^[bash: ][line N: ]<word>: command not found$       bash's two shapes; dash's `sh: 1: x: not found`
# An assertion line quotes the text or ends in `'` or `/`, a snapshot diff row ends in `"` or
# `",`, so none of them matches. A test printing a raw host line verbatim still would.
GATE_INFRA_PATTERNS_DEFAULT='^::error::[^:]*: INFRASTRUCTURE|^[^ '"'"'"]+ ::error::[^:]*: INFRASTRUCTURE --|^::error::check-disk-space:|^[[:space:]]*\[?[A-Za-z]*Error: ENOSPC: |^npm (ERR!|error) [a-z]+ ENOSPC( |:|$)|^[A-Za-z]*Error: \[Errno [0-9]+\] (No space left on device|Cannot allocate memory)|^fatal: Out of memory, malloc failed|: (No space left on device|Cannot allocate memory)[[:space:]]*$|^[^'"'"'"]*FATAL ERROR: [^'"'"'"]*JavaScript heap out of memory[[:space:]]*$|^([^ :]+: )?((line )?[0-9]+: )?[^ :]+: (command )?not found[[:space:]]*$'

GATE_INFRA_PATTERNS="${AUTOCODER_GATE_INFRA_PATTERNS:-$GATE_INFRA_PATTERNS_DEFAULT}"
GATE_FAILURE_PATTERNS_DEFAULT='^::error::|^❌|^[[:space:]]*FAIL[[:space:]]|^FAILED[[:space:]]|^--- FAIL:|^test .* \.\.\. FAILED$|^[[:space:]]*(✗|×)[[:space:]]'
GATE_FAILURE_PATTERNS="${AUTOCODER_GATE_FAILURE_PATTERNS:-$GATE_FAILURE_PATTERNS_DEFAULT}"
_gate_log_size() { wc -c < "$GATE_LOG" | tr -d ' '; }
_gate_slice() {  # <offset>: the gate log written since <offset>, ANSI colour stripped
  tail -c +"$(( $1 + 1 ))" "$GATE_LOG" | sed -E $'s/\e\\[[0-9;]*[A-Za-z]//g'
}
# A test's report line is never the host's refusal, whatever it quotes (#318, #319).
# test_merge_infrastructure_refusal.sh prints `PASS: (h) the real line is a refusal:
# FATAL ERROR: ... JavaScript heap out of memory`, and a runner that excerpts a failing
# suite reprints it behind `      | `; two alternatives above (the heap abort and the
# strerror ending) are not anchored to the line start, so they matched it and the whole
# run became "did not reach a verdict". A failing test's report line is no refusal either
# (#319): `      | FAIL: writes the cache: No space left on device` is that test's verdict,
# and an ordinary red it must stay, so its failure is attributed. Lines that open with a
# test-report mark (`PASS`, `FAIL`, `FAILED`, `not ok`, `✓`, `✔`, `✗`, `×`), bare or behind
# that excerpt prefix, are dropped before the patterns are read.
GATE_REPORT_LINE='^[[:space:]]*(\|[[:space:]]*)?((PASS|FAIL|FAILED|not ok)([[:space:]:]|$)|✓|✔|✗|×)'
# The whole slice is read (`sed -n 1p`, never `grep -m1`): under pipefail an early exit
# kills the stage before it with SIGPIPE and the match would read as none.
_gate_infra_line() {  # <offset>: the first INFRASTRUCTURE line of the run (rc 0), or nothing (rc 1)
  local line
  line=$(_gate_slice "$1" | grep -avE "$GATE_REPORT_LINE" | grep -aE "$GATE_INFRA_PATTERNS" | sed -n 1p)
  [ -n "$line" ] && printf '%s\n' "$line"
}
# A failure line may quote its own worktree's path; the integrated and base runs use
# different worktrees, so the path is replaced by <worktree> before the sets are compared
# (#298). The -base worktree's path is the longer one and goes first.
_gate_unpath() {
  awk -v a="${BASE_WORKTREE_DIR:-}" -v b="${WORKTREE_DIR:-}" '
    function rep(s, p,    i, o) { if (p == "") return s; o = ""
      while ((i = index(s, p)) > 0) { o = o substr(s, 1, i - 1) "<worktree>"; s = substr(s, i + length(p)) }
      return o s }
    { print rep(rep($0, a), b) }'
}
# The test files a gate run's output (stdin) names as failing, relative to its worktree.
_gate_failed_files() {
  local t
  t=$(mktemp "${TMP_ROOT:-/tmp}/autocoder-gate-failed.XXXXXX") || return 1
  _gate_unpath | sed 's|<worktree>/||g' > "$t"
  # Plain path-shaped names only: they cross into the gate command's environment.
  gate_log_failed_tests "$t" files | grep -E '^[A-Za-z0-9_][A-Za-z0-9._/:+-]*$' | grep -vF '..' || true
  rm -f "$t"
}
_gate_named_failures() {  # <offset>: the run's failure names, one per line, sorted unique
  # A duration anywhere in the line is `<n>` (#7130: a stage runner's summary, `FAIL (... fail wall 1084.7 s; failed:
  # db-tests ...)`, differed between the integrated and the base run by its wall time alone, so the base's red read as
  # the change's and a train returned its member for master's failure); a trailing one is dropped as before.
  _gate_slice "$1" | grep -aE "$GATE_FAILURE_PATTERNS" | _gate_unpath \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]]*\(?[0-9]+(\.[0-9]+)?[[:space:]]?(ms|s|m|min)\)?$//; s/([^A-Za-z0-9_.])[0-9]+(\.[0-9]+)?[[:space:]]?(ms|s|m|min)([^A-Za-z0-9_]|$)/\1<n>\4/g; s/[0-9a-f]{7,40}/<sha>/g' \
    | sort -u
}
_join_lines() { awk '{ a = a (NR > 1 ? "`, `" : "") $0 } END { printf "%s", a }'; }  # x`, `y for a `...` list in a message

_issue_is_closed() {
  issue_get "$ISSUE_NUM" 2>/dev/null | grep -Eq '"state": *"CLOSED"'
}
_issue_has_label() {
  issue_get "$ISSUE_NUM" 2>/dev/null | grep -Eq "\"name\": *\"$1\""
}

# Set once a push to <integration> has succeeded. From then on a failure is bookkeeping,
# not lost work, and the issue is parked instead of escalated.
PUSHED=0

# One "attempt" event per job (#184), written from the EXIT trap so no path is missed.
# Decision points below set MERGE_OUTCOME and the lists; an unset outcome falls back to
# the exit status. merge-launch.sh passes AUTOCODER_MERGE_ATTEMPT.
MERGE_T0=$SECONDS MERGE_OUTCOME="" MERGE_ESCALATED=0 MERGE_FILES="" MERGE_TESTS=""
MERGE_REASON="" MERGE_LANDED="" PUSH_RETRIES=0
# 1 when the latest gate found origin/<integration> failing alone on the same command
# (#285): the attempt was refused, or landed, on a red base. Reset by every re-gate.
MERGE_RED_BASE=0
_merge_repo_id() {
  if declare -F autocoder_repo_id >/dev/null; then autocoder_repo_id "${CALLER_DIR:-$PWD}" 2>/dev/null
  else basename "$(git -C "${CALLER_DIR:-$PWD}" rev-parse --show-toplevel 2>/dev/null)"; fi
}
# Landing timings. This job is a batch of one: its gate seconds, the gate seconds a re-sync
# threw away, and why a change came back. LANDING_CAUSE is set where the reason is known.
# Every row names this repository (landing-timings.py's --repo, read from the environment), so the
# report can keep one repository's rows apart from another's in the shared file.
[ -n "${AUTOCODER_LANDING_REPO:-}" ] || { AUTOCODER_LANDING_REPO="$(_merge_repo_id)"; export AUTOCODER_LANDING_REPO; }
GATE_S=0 GATE_RUNS=0 GATE_LAST_S=0 DISCARDED_S=0 LANDING_CAUSE="" LANDING_BATCH=""
# A gate run in flight: set when a run starts, cleared when it ends. A job that dies mid-run (a
# signal from a memory-cap watcher, a host shutdown) reaches the EXIT trap with the run unrecorded;
# the trap counts the seconds spent up to then, so the ledger shows the wasted gate time instead of
# nothing, and a job that never reached a verdict is never a landing.
GATE_INFLIGHT_T0=""
# The stage runner's per-stage seconds (`--stage name=seconds` words) of the last INTEGRATED-tree
# run, for the batch row: each run gets its own timings file through AUTOCODER_STAGE_TIMINGS_FILE,
# which a gate command built on the plugin's stage runner honours; a command that writes none
# leaves the stages empty, as before.
STAGE_ARGS="" RUN_STAGE_ARGS=""
_landing_gate_done() {  # <seconds one gate run took>
  GATE_S=$((GATE_S + $1)) GATE_LAST_S="$1" GATE_RUNS=$((GATE_RUNS + 1)) GATE_INFLIGHT_T0=""
}
_stage_timings_begin() {
  if [ -z "${_STAGE_TIMINGS_CALLER:-}" ]; then
    _STAGE_TIMINGS_N=$(( ${_STAGE_TIMINGS_N:-0} + 1 ))
    export AUTOCODER_STAGE_TIMINGS_FILE="${TMP_ROOT}/autocoder-gate-stages-${ISSUE_NUM:-0}-$$-${_STAGE_TIMINGS_N}.json"
  fi
  rm -f "$AUTOCODER_STAGE_TIMINGS_FILE" 2>/dev/null || true
}
_stage_timings_end() {  # sets RUN_STAGE_ARGS from the run's timings file; nothing when none was written
  RUN_STAGE_ARGS=""
  [ -s "${AUTOCODER_STAGE_TIMINGS_FILE:-}" ] || return 0
  RUN_STAGE_ARGS=$(python3 "${_MTI_DIR}/stage-runner.py" --stage-args "$AUTOCODER_STAGE_TIMINGS_FILE" 2>/dev/null || true)
  [ -n "${_STAGE_TIMINGS_CALLER:-}" ] || rm -f "$AUTOCODER_STAGE_TIMINGS_FILE" 2>/dev/null || true
}
_STAGE_TIMINGS_CALLER="${AUTOCODER_STAGE_TIMINGS_FILE:-}"   # a caller's own file is read, never removed
_emit_landing_rows() {  # <outcome> <rc>
  local outcome="$1" rc="$2" verdict="" cause="" issue="${ISSUE_NUM:-}"
  [ -n "$issue" ] || return 0
  # A run still in flight when the job ends is gate time spent: count it, so the batch row says so.
  [ -z "$GATE_INFLIGHT_T0" ] || _landing_gate_done $((SECONDS - GATE_INFLIGHT_T0))
  case "$outcome" in
    landed|parked) verdict=green ;;
    gate-failed) verdict=red cause="${LANDING_CAUSE:-defect}" ;;
    skipped) return 0 ;;
    conflict) cause=conflict ;;
    *) verdict=aborted cause="${LANDING_CAUSE:-other}" ;;
  esac
  [ "$LANDING_CAUSE" = red-integration ] && verdict=red cause=red-integration
  if [ -n "${AUTOCODER_LANDING_BATCH:-}" ]; then
    # Inside a train (the train runner sets both): this gate IS the train's batch. Its row carries the train's id
    # and members with what only the gate measures (gate seconds, discarded gate time, re-syncs); the train
    # writes the per-member change rows, and this job's own issue is the gate's, not a change that landed or
    # came back, so NO change row is written here, gate run or not (a conflict or a refusal before any run
    # used to count the gate issue as a returned change).
    LANDING_BATCH="$AUTOCODER_LANDING_BATCH"
    # shellcheck disable=SC2086
    [ "$GATE_RUNS" -gt 0 ] && landing_batch --batch "$LANDING_BATCH" --members "${AUTOCODER_LANDING_MEMBERS:-$issue}" --gate-s "$GATE_S" \
      --discarded-gate-s "$DISCARDED_S" --resyncs "$PUSH_RETRIES" --push-rejected "$PUSH_RETRIES" \
      --verdict "$verdict" ${cause:+--cause "$cause"} $STAGE_ARGS
    return 0
  fi
  if [ "$GATE_RUNS" -gt 0 ]; then
    LANDING_BATCH="solo-${issue}-${AUTOCODER_MERGE_ATTEMPT:-1}-$(date +%s)"
    # shellcheck disable=SC2086
    landing_batch --batch "$LANDING_BATCH" --members "$issue" --gate-s "$GATE_S" \
      --discarded-gate-s "$DISCARDED_S" --resyncs "$PUSH_RETRIES" --push-rejected "$PUSH_RETRIES" \
      --verdict "$verdict" ${cause:+--cause "$cause"} $STAGE_ARGS
    landing_change "$issue" batched --batch "$LANDING_BATCH"
  fi
  # The landed row names the commit now on the integration branch, so the landing report can look up
  # that commit's CI verdict (how long after a landing the integration branch's CI judged it).
  if [ -n "$MERGE_LANDED" ]; then landing_change "$issue" landed ${LANDING_BATCH:+--batch "$LANDING_BATCH"} --sha "$MERGE_LANDED"
  elif [ "$outcome" = conflict ]; then landing_change "$issue" returned --cause conflict
  elif [ "$rc" -ne 0 ] || [ "$outcome" = gate-failed ] || [ "$outcome" = escalated ] || [ "$outcome" = aborted ] || [ "$outcome" = failed ]; then
    # (aborted: a killed job exits 0 through its trap; the change still came back, as infra)
    landing_change "$issue" returned --cause "${LANDING_CAUSE:-${cause:-other}}"
  fi
}
_emit_attempt_event() {
  local rc="$1" outcome="$MERGE_OUTCOME"
  # No outcome was set: the job did not end on one of its own paths. A landing is MERGE_LANDED (the
  # publish proof) and nothing else: bash runs this trap on a fatal signal with `$?` of the command
  # it interrupted, usually 0, so a gate a memory-cap watcher or a host shutdown killed mid-run used
  # to be recorded as `landed` with exit 0 and no sha. Such a job is `aborted` (a signal) or `failed`
  # (a fault that exited non-zero outside the gate's paths); either way the gate reached no verdict,
  # so its ledger rows say infra, not the change's defect.
  if [ -z "$outcome" ]; then
    if [ -n "$MERGE_LANDED" ]; then outcome=landed
    else
      [ "$rc" -eq 0 ] && outcome=aborted || outcome=failed
      MERGE_REASON="${MERGE_REASON:-the job ended without a verdict (exit $rc: a signal, a kill or a fault outside the paths the gate knows); nothing landed}"
      LANDING_CAUSE="${LANDING_CAUSE:-infra}"
    fi
  fi
  _emit_landing_rows "$outcome" "$rc"
  merge_event event=attempt outcome="$outcome" repo="$(_merge_repo_id)" issue="${ISSUE_NUM:-}" \
    branch="${FEATURE:-}" attempt="${AUTOCODER_MERGE_ATTEMPT:-}" escalated="$MERGE_ESCALATED" \
    files="$MERGE_FILES" gate_tests_failed="$MERGE_TESTS" duration_s="$((SECONDS - MERGE_T0))" \
    landed="$MERGE_LANDED" push_retries="$PUSH_RETRIES" exit="$rc" reason="$MERGE_REASON" \
    conflict_resolved_by="${CONFLICT_RESOLVED_BY:-}" red_base="$MERGE_RED_BASE"
  issue_event gate-end "${ISSUE_NUM:-}" repo="$(_merge_repo_id)" outcome="$outcome" \
    attempt="${AUTOCODER_MERGE_ATTEMPT:-}" duration_s="$((SECONDS - MERGE_T0))" exit="$rc" \
    reason="$MERGE_REASON"
  [ -z "$MERGE_LANDED" ] || issue_event landed "${ISSUE_NUM:-}" repo="$(_merge_repo_id)" \
    sha="$MERGE_LANDED" integration="${INTEGRATION_BRANCH:-}"
}
# A test that failed on a tree and then passed on the same tree (#191): gate-cache-fns.sh
# calls this from gate_cache_run, and it becomes a "flaky" line in merge-events.jsonl.
gate_cache_on_flaky() {  # <tree> <test> <first-failure excerpt>
  merge_event event=flaky outcome=flaky repo="$(_merge_repo_id)" issue="${ISSUE_NUM:-}" \
    branch="${FEATURE:-}" tree="$1" test="$2" first_failure_excerpt="$3"
}
# Set only immediately before the one _fail that bounces a gate failure (#207).
GATE_BOUNCE=0

# ── Bounce (#207) ──────────────────────────────────────────────────────────────
# A conflict or a red gate is the owning worker's to fix (rebase, re-test, relaunch), so
# under --own-issue it goes back to `working`, not to a human. The comment ends in one
# machine-readable marker line; the worktree path identifies the owner because worker
# ids (hostname-PID) change every tick.
_sha1() {
  if command -v sha1sum >/dev/null 2>&1; then sha1sum
  elif command -v shasum >/dev/null 2>&1; then shasum -a 1
  else python3 -c 'import hashlib,sys; print(hashlib.sha1(sys.stdin.buffer.read()).hexdigest())'
  fi | cut -c1-40
}
# "<kind> <sig>" of the newest bounce marker already on the issue, or nothing. Reads the
# body as well as the comments: the file backend folds comments into the body.
_last_bounce() {
  issue_get "$ISSUE_NUM" 2>/dev/null | python3 -c '
import json, re, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
texts = [d.get("body") or ""] + [(c or {}).get("body") or "" for c in (d.get("comments") or [])]
hits = [m for t in texts for m in re.findall(r"<!-- autocoder-bounce kind=([a-z]+) [^>]*?sig=([0-9a-f]+) -->", t)]
if hits:
    print(" ".join(hits[-1]))
' 2>/dev/null
}
# Names of the suites the latest integrated-tree gate reported failing, one per line:
# run-shell-suite.sh's "Failing suites:" line, else "FAIL <name>" lines.
_failing_suites() {
  local f="$GATE_LAST"
  [ -s "$f" ] || f="$GATE_LOG"
  gate_log_failed_tests "$f"
}
# _bounce <conflict|gate> <newline-separated items> <detail>. Returns 1, changing
# nothing, when the newest earlier bounce has the same kind and sig: the caller escalates.
_bounce() {
  local kind="$1" items="$2" detail="$3" sig list what fixit owner
  items=$(printf '%s\n' "$items" | sed '/^$/d' | sort -u)
  sig=$(printf '%s' "$items" | _sha1)
  [ -n "$sig" ] || return 1   # no signature means no repeat detection: escalate instead
  [ "$(_last_bounce)" = "$kind $sig" ] && return 1
  # The owner is the worktree's top level: the resume side (#208) matches on it.
  owner=$(git -C "$CALLER_DIR" rev-parse --show-toplevel 2>/dev/null || echo "$CALLER_DIR")
  if [ -n "$items" ]; then
    list=$(printf '%s\n' "$items" | sed 's/^/- `/; s/$/`/')
  else
    list="- (none reported; see the output below)"
  fi
  if [ "$kind" = conflict ]; then
    what="hit a merge conflict"
    fixit="Rebase \`${FEATURE}\` onto \`origin/${INTEGRATION_BRANCH}\`, resolve keeping both sides' behaviour, re-run the tests and relaunch the merge."
    list="Conflicting files:
${list}"
  else
    what="failed the gate on the integrated tree"
    fixit="Rebase \`${FEATURE}\` onto \`origin/${INTEGRATION_BRANCH}\`, fix the failing tests, re-run them and relaunch the merge."
    list="Failing suites:
${list}"
  fi
  issue_comment "$ISSUE_NUM" --body "🔁 **Auto-merge to \`${INTEGRATION_BRANCH}\` ${what}; returned to the owning worker.**

${list}

Nothing from this run landed on \`${INTEGRATION_BRANCH}\`; the work is still on \`${FEATURE}\` (\`${FEATURE_SHA:0:12}\`). ${fixit} The issue is back in \`working\` for that worker. A second bounce with the same ${kind} signature escalates to \`needs-clarification\`.${detail}

<!-- autocoder-bounce kind=${kind} worktree=${owner} sha=${FEATURE_SHA} sig=${sig} -->" 2>/dev/null || true
  # Add before remove: both labels at once is still out of the claimable pool, while
  # neither would put an issue with a live branch nowhere.
  issue_update "$ISSUE_NUM" --add-label working 2>/dev/null || true
  issue_update "$ISSUE_NUM" --remove-label merging 2>/dev/null || true
  MERGE_ESCALATED=0   # bounced to the worker, not escalated
  if [ "$kind" = conflict ]; then MERGE_OUTCOME=conflict MERGE_FILES="$items"
  else MERGE_OUTCOME=gate-failed MERGE_TESTS="$items"; fi
  echo "🔁 Issue #${ISSUE_NUM} bounced back to its worker (${kind}, sig ${sig:0:12})."
  return 0
}

# Terminal failure, exits with $1. Under --own-issue an issue someone already closed is
# left alone. A gate failure this change caused (GATE_BOUNCE=1: the integrated tree is
# red and origin/<integration> alone is green) is bounced to the worker (#207) unless it
# repeats identically. A red base or an infrastructure failure is not the worker's to
# fix, so it escalates like everything else. Anything else is escalated (nothing landed) or parked
# (the push landed and only this job's bookkeeping failed), with the reason and the
# gate's tail.
_fail() {
  local code="$1" reason="$2" tail="" repeat=""
  MERGE_REASON="$reason"
  if [ "$PUSHED" -eq 1 ]; then MERGE_OUTCOME=parked
  elif [ "${GATE_BOUNCE:-0}" -eq 1 ]; then MERGE_OUTCOME=gate-failed MERGE_ESCALATED=1 MERGE_TESTS="$(_failing_suites 2>/dev/null || true)"
  else MERGE_OUTCOME=escalated MERGE_ESCALATED=1; fi
  [ "$OWN_ISSUE" -eq 1 ] || MERGE_ESCALATED=0   # without --own-issue nothing is escalated
  if [ "$OWN_ISSUE" -eq 1 ] && ! _issue_is_closed; then
    [ -s "$GATE_LOG" ] && tail=$(tail -n 40 "$GATE_LOG")
    tail="${tail:+

Last gate output:
\`\`\`
${tail}
\`\`\`}"
    if [ "$PUSHED" -eq 0 ] && [ "${GATE_BOUNCE:-0}" -eq 1 ]; then
      if _bounce gate "$(_failing_suites)" "

Gate verdict: ${reason}$(conflict_resolution_note)${tail}"; then
        exit "$code"
      fi
      repeat="

This is the second identical gate bounce (same failing suites), so it is escalated instead of bounced again."
    fi
    if [ "$PUSHED" -eq 1 ]; then
      issue_park "$ISSUE_NUM" --comment "⚠️ **Auto-merge to \`${INTEGRATION_BRANCH}\` pushed, then hit an internal error** (exit ${code}): ${reason}

The work from \`${FEATURE}\` is on \`${INTEGRATION_BRANCH}\`; what failed was this job's bookkeeping after the push. Parked under \`awaiting-integration\` for the post-merge sentinel (or a human) to confirm and close.${tail}" 2>/dev/null || true
    else
      issue_escalate "$ISSUE_NUM" --label needs-clarification --comment "❌ **Auto-merge to \`${INTEGRATION_BRANCH}\` failed** (exit ${code}): ${reason}

The fix is committed on \`${FEATURE}\`; nothing from this run landed on \`${INTEGRATION_BRANCH}\`. Labelled \`needs-clarification\` for a human to look at.${repeat}$(conflict_resolution_note)${tail}" 2>/dev/null || true
    fi
  fi
  exit "$code"
}

_escalate_conflict() {
  local files
  files=$(git diff --name-only --diff-filter=U 2>/dev/null)
  git rebase --abort 2>/dev/null || git merge --abort 2>/dev/null || true
  if [ -z "$files" ]; then
    # The rebase stopped without a conflicted file (a refused commit, a dirty tree, …):
    # nothing for the worker to resolve, and an empty file list would make every such
    # failure look like the same conflict.
    echo "❌ Rebasing ${FEATURE} onto '${INTEGRATION_BRANCH}' failed without a conflict."
    _fail 1 "rebasing ${FEATURE_SHA:0:8} onto origin/${INTEGRATION_BRANCH} failed without a conflict (see the job log)"
  fi
  echo "❌ Conflict rebasing ${FEATURE} onto '${INTEGRATION_BRANCH}'."
  MERGE_OUTCOME=conflict MERGE_FILES="$files" MERGE_ESCALATED="$OWN_ISSUE"   # a successful _bounce clears it
  if [ "$OWN_ISSUE" -eq 1 ] && ! _issue_is_closed; then
    if _bounce conflict "$files" "$(conflict_resolution_note)"; then
      echo "   Aborted the rebase; the worker rebases and relaunches."
      exit 1
    fi
    echo "   Aborted the rebase; escalating issue #${ISSUE_NUM}: second identical conflict."
    issue_escalate "$ISSUE_NUM" --label needs-clarification --comment "⚠️ **Auto-merge to \`${INTEGRATION_BRANCH}\` hit the same conflict twice** on branch \`${FEATURE}\` and needs manual resolution. The fix is committed on \`${FEATURE}\`; resolve against \`${INTEGRATION_BRANCH}\` and push, then close this issue.

Conflicting files:
$(printf '%s\n' "$files" | sed '/^$/d' | sed 's/^/- `/; s/$/`/')$(conflict_resolution_note)" 2>/dev/null || true
  else
    echo "   Aborted the rebase. The fix is committed on ${FEATURE}; resolve against ${INTEGRATION_BRANCH} by hand."
  fi
  exit 1
}

# Terminal success under --own-issue. $1 is the landed commit. Only a tree the gate
# passed (tested) or that needs no gate (docs-only) may close the issue, and only when
# verify-shipped.sh says the commit is on the ship branch. Every other landing is parked
# under `awaiting-integration` with PARK_NOTE (set by the publish-basis case below); the
# post-merge sentinel closes a parked issue once its landed commit is on a green tip.
PARK_NOTE=""
# The exact command that undoes this landing (#170). After a rebase the landed series
# sits directly on REBASE_ONTO, so REBASE_ONTO..landed is this change and nothing else.
# Work that was already on the branch (landed by an earlier run or a human) has no
# known range; say how to find it instead of guessing.
landed_revert_note() {  # <landed sha>
  local landed="$1" n
  if [ -n "${REBASE_ONTO:-}" ] && [ "${PUBLISH_BASIS:-}" != already-landed ] \
     && n=$(git rev-list --count "${REBASE_ONTO}..${landed}" 2>/dev/null) && [ "$n" -ge 1 ]; then
    if [ "$n" -eq 1 ]; then
      printf '\n\n**How to revert what landed**: `git revert --no-edit %s`' "$landed"
    else
      printf '\n\n**How to revert what landed**: `git revert --no-edit %s..%s` (%s commits, newest first)' "$REBASE_ONTO" "$landed" "$n"
    fi
  else
    printf '\n\n**How to revert what landed**: this work was already on `%s` before this job ran; find its commits with `git log --oneline -E --grep='"'"'#%s([^0-9]|$)'"'"' origin/%s` and `git revert` them, newest first.' \
      "$INTEGRATION_BRANCH" "$ISSUE_NUM" "$INTEGRATION_BRANCH"
  fi
}
_park() {
  issue_park "$ISSUE_NUM" --comment "$1" 2>/dev/null || true
}
_close_or_park() {
  # Something landed whatever happens to the issue below: record it before any return.
  MERGE_LANDED="$1" MERGE_OUTCOME=landed
  [ "$OWN_ISSUE" -eq 1 ] || return 0
  local landed="$1" summary ship_branch rebase_note=""
  summary="Merged \`${FEATURE}\` into \`${INTEGRATION_BRANCH}\`."
  if [ -n "$SUMMARY_FILE" ] && [ -s "$SUMMARY_FILE" ]; then
    summary=$(cat "$SUMMARY_FILE")
  fi
  # The review record names the pre-rebase HEAD; say how the landed commit relates to it.
  if [ -n "$CONFLICT_RESOLVED_FILES" ] && [ "${PUBLISH_BASIS:-}" != already-landed ]; then
    rebase_note="

**Landed by rebase** (#221): \`${FEATURE_SHA}\` (the reviewed HEAD${SQUASH_BASE:+, squashed to one commit because it contained merge commits}) was rebased onto \`${INTEGRATION_BRANCH}\` and landed as \`${landed}\`. The rebase hit a conflict that the merge job resolved itself; the gate passed on the resolved tree, but the resolution was not part of the reviewed HEAD.$(conflict_resolution_note landed)"
  elif [ "$landed" != "$FEATURE_SHA" ] && [ "${PUBLISH_BASIS:-}" != already-landed ]; then
    rebase_note="

**Landed by rebase** (#221): \`${FEATURE_SHA}\` (the reviewed HEAD${SQUASH_BASE:+, squashed to one commit because it contained merge commits}) was rebased onto \`${INTEGRATION_BRANCH}\` without conflicts and landed as \`${landed}\`. A clean rebase is mechanical; a conflicted one is bounced back to the worker for re-review."
  fi
  summary="${summary}${rebase_note}$(landed_revert_note "$landed")"
  if _issue_is_closed; then
    # Most often GitHub closed it the moment our push landed, because a commit says
    # "Fix #N" (a closing keyword). Returning silently here lost the summary and
    # review record and left `merging` on a closed issue (#209, seen on #145 and
    # #195). If this job pushed, post the record anyway and retire the label; never
    # reopen or re-close.
    if [ "$PUSHED" -eq 1 ]; then
      local basis_note=""
      case "$PUBLISH_BASIS" in
        tested|docs-only|docs-resync|already-landed) ;;
        *) basis_note="

⚠️ It was closed before this job could decide: it landed on basis \`${PUBLISH_BASIS}\`, which would normally park it under \`awaiting-integration\` until a green tip. ${PARK_NOTE}" ;;
      esac
      issue_comment "$ISSUE_NUM" --body "✅ **Landed on \`${INTEGRATION_BRANCH}\` as \`${landed}\`** (the issue was already closed, probably by a closing keyword in a commit message).

${summary}${basis_note}

🤖 Auto-merge" 2>/dev/null || true
      echo "ℹ️  Issue #${ISSUE_NUM} was already closed; posted the landing summary anyway."
    else
      echo "ℹ️  Issue #${ISSUE_NUM} is already closed; leaving it alone."
    fi
    # Nobody owns a closed issue: retire every lock label, not just `merging` (#211).
    # `working` is left behind when the hand-off failed; `awaiting-integration` only
    # goes when this landing is one that would have closed the issue anyway.
    issue_update "$ISSUE_NUM" --remove-label "merging" 2>/dev/null || true
    issue_update "$ISSUE_NUM" --remove-label "working" 2>/dev/null || true
    if [ "$PUSHED" -eq 1 ]; then
      case "$PUBLISH_BASIS" in
        tested|docs-only|docs-resync|already-landed)
          if "${_MTI_DIR}/verify-shipped.sh" "$landed" >/dev/null 2>&1; then
            issue_update "$ISSUE_NUM" --remove-label "awaiting-integration" 2>/dev/null || true
          fi ;;
      esac
    fi
    return 0
  fi
  case "$PUBLISH_BASIS" in
    tested|docs-only|docs-resync|already-landed) ;;
    *)
      MERGE_OUTCOME=parked
      _park "⏳ **Landed on \`${INTEGRATION_BRANCH}\` as \`${landed}\`, not closed.** ${PARK_NOTE}

${summary}

Labelled \`awaiting-integration\`; the post-merge sentinel closes this issue once \`${landed}\` is on a green \`${INTEGRATION_BRANCH}\` tip.

🤖 Auto-merge (publish basis: ${PUBLISH_BASIS})"
      echo "⏳ Issue #${ISSUE_NUM} parked under awaiting-integration (${PUBLISH_BASIS}); the sentinel closes it once ${landed:0:8} is on a green tip."
      return 0 ;;
  esac
  if "${_MTI_DIR}/verify-shipped.sh" "$landed"; then
    if issue_close "$ISSUE_NUM" --comment "✅ **Issue Resolved**

${summary}

**Branch**: \`${FEATURE}\` (merged and deleted)

🤖 Auto-resolved by autonomous fix workflow"; then
      issue_update "$ISSUE_NUM" --remove-label "merging" 2>/dev/null || true
      echo "✅ Issue #${ISSUE_NUM} closed."
      # Sample closed work for later human review (#197). Never gates; never fatal.
      # The change measured is the feature's own (from the integration tip first seen).
      # After a rebase the landed series sits directly on REBASE_ONTO, so that pair is
      # exactly this change; otherwise (already landed) fall back to the feature tip.
      local sc_base="$INT_SEEN_SHA" sc_head="$FEATURE_SHA"
      [ -n "${REBASE_ONTO:-}" ] && sc_base="$REBASE_ONTO" sc_head="$landed"
      bash "${_MTI_DIR}/spot-check-select.sh" --issue "$ISSUE_NUM" --sha "$landed" \
        --base "$sc_base" --head "$sc_head" --apply || true
    else
      MERGE_OUTCOME=parked
      _park "⚠️ The work landed on \`${INTEGRATION_BRANCH}\` as \`${landed}\` but the tracker refused to close this issue. Parked under \`awaiting-integration\` for the sentinel or a human to close."
      echo "⚠️  Issue #${ISSUE_NUM} could not be closed; parked under 'awaiting-integration' with the work landed on '${INTEGRATION_BRANCH}'."
    fi
    return 0
  fi
  ship_branch="${CLAUDE_CODE_SHIP_BRANCH:-$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name 2>/dev/null || echo main)}"
  MERGE_OUTCOME=parked
  _park "⏳ **Fix complete, not yet shipped — leaving this issue OPEN**

The work is done, committed, and merged to \`${INTEGRATION_BRANCH}\` as \`${landed}\`. It has **not** reached \`${ship_branch}\`, so closing would assert something false.

**To ship**: \`${INTEGRATION_BRANCH}\` must merge to \`${ship_branch}\`.

Labelled \`awaiting-integration\` so it is findable rather than silently reopened as new work.

🤖 Ship gate (issue #35)"
  echo "⏳ Issue #${ISSUE_NUM} left OPEN — merged to ${INTEGRATION_BRANCH} but not on the shipping branch ${ship_branch}"
}

if [ "$OWN_ISSUE" -eq 1 ]; then
  if _issue_is_closed; then
    echo "ℹ️  Issue #${ISSUE_NUM} is already closed; nothing to merge."
    issue_update "$ISSUE_NUM" --remove-label "merging" 2>/dev/null || true
    MERGE_OUTCOME=skipped MERGE_REASON="issue already closed; nothing merged"
    exit 0
  fi
  # The hand-off is this job's first act, before anything that can fail, so a fast
  # failure path still finds the issue under `merging` and escalates it from there.
  if issue_handoff "$ISSUE_NUM" 2>/dev/null; then
    echo "ℹ️  Issue #${ISSUE_NUM} handed off: working → merging."
  else
    echo "⚠️  Could not hand issue #${ISSUE_NUM} off to this job (backend refused); continuing with the merge."
  fi
fi

# Resolve the exact commit to test/push. Prefer the SHA the caller pinned before we started;
# fall back to resolving $FEATURE in CALLER_DIR for direct invocations that skip --feature-sha.
# Resolve against the pushed origin/$FEATURE, not the shared local namespace (#143).
if [ -z "$FEATURE_SHA" ]; then
  FEATURE_SHA=$(resolve_feature_sha "$CALLER_DIR" "$FEATURE" || echo "")
fi
if [ -z "$FEATURE_SHA" ]; then
  echo "❌ Could not resolve '${FEATURE}' to a commit (no --feature-sha given and the branch is not in ${CALLER_DIR})." >&2
  _fail 1 "could not resolve '${FEATURE}' to a commit"
fi

# Resolve the gate BEFORE touching anything: an ungated push to the integration branch is
# never acceptable, so a missing command must stop us while the branch is still unmoved.
if [ -z "$TEST_CMD" ]; then
  _REPO_TOP=$(git -C "$CALLER_DIR" rev-parse --show-toplevel 2>/dev/null || echo "$CALLER_DIR")
  TEST_CMD=$(resolve_test_cmd "$_REPO_TOP")
  [ -n "$TEST_CMD" ] && echo "ℹ️  No --test-cmd given; using the Regression Test Suite command from the repo doctrine: $TEST_CMD"
fi
DOCS_ONLY=0
if [ -z "$TEST_CMD" ]; then
  if is_docs_only_diff "$CALLER_DIR" "$FEATURE_SHA" "$INTEGRATION_BRANCH"; then
    DOCS_ONLY=1
    echo "ℹ️  No test command, but ${FEATURE} changes documentation only; merging without a test run."
  else
    echo "❌ No test command: pass --test-cmd or add a '### Regression Test Suite' fenced block to AGENTS.md or CLAUDE.md." >&2
    echo "   Refusing to merge '${FEATURE}' into '${INTEGRATION_BRANCH}' untested. Nothing was fetched, merged, or pushed." >&2
    _fail 1 "no test command resolvable (pass --test-cmd or add a '### Regression Test Suite' block to AGENTS.md or CLAUDE.md)"
  fi
fi

# Isolated throwaway worktrees (#1821) — keyed by <repo-id>-<issue> like merge-launch.sh's
# state files (only one worker holds an issue's lock at a time, so this is unique per
# in-flight merge). Never persist past this run. The -base worktree exists only while
# the integration tip is gated alone.
WORKTREE_DIR="${TMP_ROOT}/autocoder-merge-worktree-${REPO_ID}-${ISSUE_NUM}"
BASE_WORKTREE_DIR="${WORKTREE_DIR}-base"

_remove_worktree() {
  git -C "$CALLER_DIR" worktree remove --force "$1" 2>/dev/null || rm -rf "$1" 2>/dev/null || true
}
_cleanup_worktrees() {
  _remove_worktree "$WORKTREE_DIR"
  _remove_worktree "$BASE_WORKTREE_DIR"
  git -C "$CALLER_DIR" worktree prune 2>/dev/null || true
}
_cleanup_worktrees
# A job that died without running its EXIT trap left its checkout behind (#144). Remove
# this repo's leftovers; a live job's worktrees are kept (merge-worktree-fns.sh).
merge_worktree_prune_stale "$TMP_ROOT" "$REPO_ID" "$CALLER_DIR" "$ISSUE_NUM"

# node_modules/dist seeding for throwaway worktrees lives in worktree-deps-fns.sh, shared
# with main-sentinel.sh (and it carries the #1967 cross-device and dist/mtime notes).

# 0. Wait our turn (#189): one landing per integration branch per host, held from this
#    fetch until the push is verified, so the tip we sync onto is still the tip when we
#    push. Jobs behind us sync only once we have landed. See merge-queue-fns.sh.
#    The worktree is created only once our turn has come (#144): a queued job holds no
#    checkout, so N jobs waiting on one branch cost one checkout's disk, not N.
merge_queue_acquire "$CALLER_DIR" "$INTEGRATION_BRANCH" "$ISSUE_NUM"

# The owner file comes first, so the stale-worktree prune never sees a live job's
# worktree without one (merge-worktree-fns.sh).
# --detach on the raw SHA (not the branch name) is required: $FEATURE is very likely still
# checked out in $CALLER_DIR, and git refuses to check out the same branch in two worktrees.
# A detached checkout of its tip commit carries the identical tree without that restriction.
WORKTREE_OWNER="${WORKTREE_DIR}.owner"
echo "$$" > "$WORKTREE_OWNER"
trap '_rc=$?; merge_queue_release >/dev/null 2>&1; _emit_attempt_event "$_rc"; _cleanup_worktrees; rm -f "$GATE_LOG" "$GATE_LAST" "$REBASE_LOG" "${CONFLICT_ATTEMPT_FILE:-}" "$WORKTREE_OWNER"' EXIT
if ! git -C "$CALLER_DIR" worktree add --detach "$WORKTREE_DIR" "$FEATURE_SHA"; then
  echo "❌ Could not create isolated worktree for ${FEATURE} (${FEATURE_SHA})." >&2
  _fail 1 "could not create the isolated merge worktree for ${FEATURE_SHA:0:8}"
fi

cd "$WORKTREE_DIR" || { echo "❌ Could not enter isolated worktree ${WORKTREE_DIR}." >&2; _fail 1 "could not enter ${WORKTREE_DIR}"; }
seed_worktree_deps "$CALLER_DIR" "$WORKTREE_DIR"
issue_event gate-start "$ISSUE_NUM" repo="$(_merge_repo_id)" attempt="${AUTOCODER_MERGE_ATTEMPT:-}"

# 1. Bring the latest integration state INTO the feature branch so the eventual push
#    is a fast-forward. Never checks out the integration branch -> worktree-safe.
fetch_rc=0
git_net_long fetch origin "$INTEGRATION_BRANCH" || fetch_rc=$?
if [ "$fetch_rc" -ne 0 ]; then
  if git_net_timed_out "$fetch_rc"; then
    echo "❌ Fetching origin/${INTEGRATION_BRANCH} timed out after ${AUTOCODER_GIT_TIMEOUT_LONG:-300}s (stalled connection)"
    _fail 1 "fetching origin/${INTEGRATION_BRANCH} timed out (stalled connection)"
  else
    echo "❌ Could not fetch origin/${INTEGRATION_BRANCH}"; _fail 1 "could not fetch origin/${INTEGRATION_BRANCH}"
  fi
fi
INT_SEEN_SHA=$(git rev-parse "origin/${INTEGRATION_BRANCH}")

# The relaxations (scoped re-gate, merge on a red base) are safe only once a sentinel
# re-gates the integration tip; its green ref is the proof that one exists.
if git_net ls-remote --exit-code origin "refs/heads/${GREEN_REF}" >/dev/null 2>&1; then
  SCOPED_REGATE="${AUTOCODER_SCOPED_REGATE:-1}"
  MERGE_ON_RED_BASE="${AUTOCODER_MERGE_ON_RED_BASE:-1}"
  RED_BASE_REFUSAL="AUTOCODER_MERGE_ON_RED_BASE=0 forbids landing on a red base"
  echo "ℹ️  origin/${GREEN_REF} exists (a sentinel has proven a green tip): scoped re-gate ${SCOPED_REGATE}, merge on a red base ${MERGE_ON_RED_BASE}."
else
  SCOPED_REGATE=0
  MERGE_ON_RED_BASE=0
  RED_BASE_REFUSAL="no sentinel has proven a green ${INTEGRATION_BRANCH} yet (origin/${GREEN_REF} missing), so landing on a red base is not allowed"
  echo "ℹ️  No origin/${GREEN_REF} yet (no sentinel has proven a green tip): strict mode, every re-sync re-gates and a red base refuses the merge."
fi

# A previous run (or a human) may already have landed this work; gating and pushing it
# again would land nothing. Go straight to the outcome. $1 is the commit on
# origin/<integration> that carries the work.
REBASE_ONTO="" SQUASH_BASE=""
_already_landed() {
  delete_feature_branch_if_at "$CALLER_DIR" "$FEATURE" "$FEATURE_SHA" || true
  if [ "$OWN_ISSUE" -eq 1 ] && _issue_has_label awaiting-integration; then
    # An earlier run parked it (disjoint, red base, or not shipped); landing nothing new
    # proves nothing new, so the sentinel keeps ownership.
    echo "ℹ️  Issue #${ISSUE_NUM} is parked under awaiting-integration from an earlier landing; leaving it to the sentinel."
    issue_update "$ISSUE_NUM" --remove-label "merging" 2>/dev/null || true
    MERGE_OUTCOME=skipped MERGE_REASON="already on ${INTEGRATION_BRANCH} and parked by an earlier run"
    exit 0
  fi
  PUBLISH_BASIS=already-landed
  _close_or_park "$1"
  exit 0
}
if git merge-base --is-ancestor "$FEATURE_SHA" "$INT_SEEN_SHA"; then
  echo "ℹ️  ${FEATURE} (${FEATURE_SHA:0:8}) is already on origin/${INTEGRATION_BRANCH}; nothing to merge or gate."
  _already_landed "$FEATURE_SHA"
fi

# The files this change touches, measured against the integration tip as first seen. A
# later re-sync is re-gated only when its incoming files meet this set or a global path.
# No merge base (unrelated histories) means the set is unknown, so every re-sync re-gates.
FEATURE_BASE=$(git merge-base "$INT_SEEN_SHA" "$FEATURE_SHA" 2>/dev/null || echo "")
declare -A FEATURE_FILE_SET=()
if [ -n "$FEATURE_BASE" ]; then
  while IFS= read -r f; do
    [ -n "$f" ] && FEATURE_FILE_SET["$f"]=1
  done < <(git diff --name-only --no-renames "$FEATURE_BASE" "$FEATURE_SHA")
fi

# Paths the gate command itself runs: each whitespace token that names something in the
# tree. A directory token covers its whole subtree.
declare -A TEST_CMD_PATHS=()
for _tok in $(printf '%s' "$TEST_CMD" | tr ';&|()<>`"'"'"'=' ' '); do
  _tok="${_tok#./}"; _tok="${_tok%/}"
  case "$_tok" in ""|-*|/*|'$'*) continue ;; esac
  [ -e "$WORKTREE_DIR/$_tok" ] && TEST_CMD_PATHS["$_tok"]=1
  # A stage manifest (stage-runner.py) hides the gate's scripts from the command line: name the
  # commands it runs too, so a change to one of them still counts as a gate path.
  case "$_tok" in
    *.json)
      [ -f "$WORKTREE_DIR/$_tok" ] || continue
      for _mtok in $(python3 "${_MTI_DIR}/stage-runner.py" --manifest "$WORKTREE_DIR/$_tok" --list-commands 2>/dev/null \
                       | tr ';&|()<>`"'"'"'=' ' '); do
        _mtok="${_mtok#./}"; _mtok="${_mtok%/}"
        case "$_mtok" in ""|-*|/*|'$'*) continue ;; esac
        [ -e "$WORKTREE_DIR/$_mtok" ] && TEST_CMD_PATHS["$_mtok"]=1
      done ;;
  esac
done
unset _tok _mtok

# Replay the feature commits onto the integration tip (#221) so the eventual push is a
# fast-forward and the integration branch stays linear. Never checks out the integration
# branch -> worktree-safe. A conflict aborts the rebase and bounces to the worker.
#
# The user's git config must not change what lands: hooks, rerere (it can auto-stage a
# replayed conflict, so the bounce would list no files), signing, autosquash/autostash,
# update-refs (it would rewrite the caller's local branches, which share this ref store)
# and rebase-merges are all pinned off.
_GIT_PINNED=(-c core.hooksPath=/dev/null -c rerere.enabled=false -c commit.gpgsign=false
  -c rebase.autoSquash=false -c rebase.autoStash=false -c rebase.updateRefs=false
  -c rebase.rebaseMerges=false)
# REBASE_RESOLVED=1 when this rebase stopped on a conflict that merge-conflict-fns.sh
# resolved: the tree then holds edits nobody gated, so a re-sync must re-gate it.
REBASE_RESOLVED=0
# A rebase the HOST stopped is not a conflict. Git writing the replayed tree can die on
# the same conditions the gate stages do (ENOSPC on a shared tmpfs under several
# concurrent gates, a memory death, a missing tool), and such a stop leaves no conflicted
# file, so `_escalate_conflict` read it as "failed without a conflict": exit 1, the issue
# labelled needs-clarification and a comment pointing a human at a conflict that never
# existed. The rebase's own output is classified with the gate's infrastructure patterns
# (AUTOCODER_GATE_INFRA_PATTERNS, the report-line filter included); a host stop is retried
# once after AUTOCODER_REBASE_INFRA_RETRY_DELAY seconds (default 30: a tmpfs under gate
# load drains in seconds), and a second one refuses as INFRASTRUCTURE (exit 3, the marker a
# train's classifier reads and re-gates on), the branch intact.
# Git's progress output ends in a carriage return, not a newline (`Rebasing (1/2)\r`),
# so an error printed behind it shares the line; the CRs are read as line ends first,
# which is what the start-anchored patterns need and what keeps the marker to git's line.
_rebase_infra_line() {  # the first infrastructure line of the latest rebase's output (rc 0), or nothing (rc 1)
  local line
  [ -s "$REBASE_LOG" ] || return 1
  line=$(tr '\r' '\n' < "$REBASE_LOG" | sed -E $'s/\e\\[[0-9;]*[A-Za-z]//g' | grep -avE "$GATE_REPORT_LINE" | grep -aE "$GATE_INFRA_PATTERNS" | sed -n 1p)
  [ -n "$line" ] && printf '%s\n' "$line"
}
# After a host stop the abort can find nothing to abort: git that died while writing its
# state (`rebase-merge/` made, `head-name` not yet written) is "not rebasing" to
# `--abort`, which leaves the directory, and the retry would stop on "there is already a
# rebase-merge directory" however healthy the host. The state is removed and the tree
# reset to where the attempt started, as git's own hint says.
_rebase_clear() {  # <HEAD before the attempt>
  if ! git rebase --abort >/dev/null 2>&1; then
    rm -rf "$(git rev-parse --git-path rebase-merge)" "$(git rev-parse --git-path rebase-apply)"
    git reset -q --hard "$1" >/dev/null 2>&1 || true
  fi
}
_refuse_rebase_infrastructure() {  # <line>: the output line that decided it
  local line="$1"
  echo "::error::merge-to-integration: INFRASTRUCTURE -- the rebase onto origin/${INTEGRATION_BRANCH} did not complete, twice: ${line}"
  echo "   That is a host condition, not a conflict and not a test failure, so nothing is known about this change. NOT pushing."
  echo "   Branch '${FEATURE}' is untouched; relaunch the merge once the host is fixed."
  LANDING_CAUSE=infra   # the ledger's cause, as a train records the same verdict
  _fail 3 "INFRASTRUCTURE: rebasing ${FEATURE_SHA:0:8} onto origin/${INTEGRATION_BRANCH} stopped on a host condition twice (${line}). Not a conflict and not a test failure: nothing about this change is in doubt and nothing landed. Relaunch the merge once the host is fixed; branch \`${FEATURE}\` is intact"
}
_rebase_onto_integration() {
  local attempt infra before prior="" delay="${AUTOCODER_REBASE_INFRA_RETRY_DELAY:-30}"
  if ! [[ "$delay" =~ ^[0-9]+$ ]]; then   # `sleep` would refuse it and the retry would be immediate
    echo "⚠️  AUTOCODER_REBASE_INFRA_RETRY_DELAY='${delay}' is not a whole number of seconds; using 30."
    delay=30
  fi
  REBASE_RESOLVED=0
  for attempt in 1 2; do
    before=$(git rev-parse HEAD)
    : > "$REBASE_LOG"
    if git "${_GIT_PINNED[@]}" rebase "origin/${INTEGRATION_BRANCH}" > "$REBASE_LOG" 2>&1; then
      cat "$REBASE_LOG"
      break
    fi
    cat "$REBASE_LOG"
    # A conflict is a stop that left unmerged files; only that is the resolver's to try.
    # (A stop that left none, with a resolver configured, used to be reported as
    # "Conflict resolved" by a resolver that resolved nothing, and the un-rebased tree went
    # on to the gate.)
    if [ -n "$(git diff --name-only --diff-filter=U 2>/dev/null)" ]; then
      if conflict_try_resolve; then
        REBASE_RESOLVED=1
        echo "ℹ️  Conflict resolved in the merge worktree (${CONFLICT_RESOLVED_BY}); the gate decides whether the result is right."
        break
      fi
      _escalate_conflict
    fi
    # A non-conflict stop right after a host stop is the host's too (the first stop can
    # leave a rebase the abort could not clear), so the retry inherits the first line.
    if infra=$(_rebase_infra_line) || { [ -n "$prior" ] && infra="$prior"; }; then
      _rebase_clear "$before"
      if [ "$attempt" -eq 1 ]; then
        prior="$infra"
        echo "⚠️  Rebasing ${FEATURE} onto origin/${INTEGRATION_BRANCH} stopped on a host condition, not a conflict (${infra}); retrying once in ${delay}s."
        sleep "$delay"
        continue
      fi
      _refuse_rebase_infrastructure "$infra"
    fi
    _escalate_conflict
  done
  REBASE_ONTO=$(git rev-parse "origin/${INTEGRATION_BRANCH}")
}

# A plain rebase replays only non-merge commits, so anything a merge commit on the
# feature branch carries (a conflict resolution, an edit made during the merge) would be
# silently lost, or its conflict replayed and bounced although the worker resolved it.
# A branch with merges is first squashed to one commit holding its net change against
# the newest integration commit it already contains (its merge base), then rebased.
if [ -n "$(git rev-list --merges "${INT_SEEN_SHA}..HEAD")" ]; then
  SQUASH_BASE=$(git merge-base HEAD "$INT_SEEN_SHA")
  SQUASH_MSG="Issue #${ISSUE_NUM}: ${FEATURE} (squashed: the branch contained merge commits)

$(git log --no-merges --format='- %s' "${SQUASH_BASE}..HEAD")"
  git reset -q --soft "$SQUASH_BASE" \
    || _fail 1 "could not squash ${FEATURE_SHA:0:8}, which contains merge commits, before rebasing it"
  if git diff --cached --quiet; then
    # No net change: nothing to commit, so the rebase below fast-forwards to the tip and
    # _nothing_left_to_land decides, instead of an empty commit landing.
    echo "ℹ️  ${FEATURE} contains merge commits and no net change against ${SQUASH_BASE:0:8}."
  elif git "${_GIT_PINNED[@]}" commit -q --no-verify \
         --author="$(git log -1 --format='%an <%ae>' "$FEATURE_SHA")" -m "$SQUASH_MSG"; then
    echo "ℹ️  ${FEATURE} contains merge commits; squashed its net change against ${SQUASH_BASE:0:8} into one commit before rebasing."
  else
    _fail 1 "could not squash ${FEATURE_SHA:0:8}, which contains merge commits, before rebasing it"
  fi
fi

# Every feature commit was dropped as already upstream (the same patch under another
# SHA). Patch equality does not prove the change is still on the tip (a copy that landed
# and was reverted matches too), so close only when the feature's whole change applies in
# reverse to the tip, i.e. the tip already carries it. Otherwise nothing lands and a
# human decides; the branch is kept.
# _landed_by_patch_id <tip>: the feature's change landed on <tip> and is still in effect,
# though later edited by others (#236). The tree check in _nothing_left_to_land
# reverse-applies the feature diff, which also fails when a later sibling commit edited the
# same lines. All of these must hold:
#   - every feature commit has a patch-equivalent commit in tip's history (git cherry);
#   - the feature diff does NOT apply forward to the tip, as a whole or for any one file
#     (#237): if it did, those lines look
#     exactly as before the change, i.e. it was undone (a manual undo or a squash/PR
#     revert leaves no standard revert message);
#   - no equivalent commit is named by a later "This reverts commit <sha>" message.
_landed_by_patch_id() {
  local tip="$1" base marks eq sha patch log
  git merge-base --is-ancestor "$FEATURE_SHA" "$tip" 2>/dev/null && return 0
  base=$(git merge-base "$tip" "$FEATURE_SHA" 2>/dev/null) || return 1
  marks=$(git cherry "$tip" "$FEATURE_SHA" "$base" 2>/dev/null) || return 1
  [ -n "$marks" ] || return 1
  case $'\n'"$marks" in *$'\n+'*) return 1 ;; esac      # some commit has no upstream copy
  patch=$(mktemp "${TMP_ROOT}/autocoder-merge-${REPO_ID}-${ISSUE_NUM}.fwd.XXXXXX")
  git diff --binary --no-renames "$base" "$FEATURE_SHA" > "$patch"
  if [ -s "$patch" ] && git apply --check "$patch" 2>/dev/null; then
    rm -f "$patch"; return 1                               # undone: the tip is pre-change there
  fi
  # Per file too (#237): a partial undo (one file restored by hand, another edited later)
  # fails the whole-patch check, but the restored file's slice still applies forward.
  # --no-renames on both the patch and the name list, so every name is a patch entry;
  # --include takes a glob, so the name is escaped; and an include that matches nothing
  # also exits 0, so a slice counts only when --numstat shows it is non-empty.
  local f pat names
  # Capture the list first: an error must refuse, not skip the per-file check.
  names=$(git diff -z --name-only --no-renames "$base" "$FEATURE_SHA" | tr '\0' '\001') \
    || { rm -f "$patch"; return 1; }
  while IFS= read -r -d $'\001' f; do
    pat=$(printf '%s' "$f" | sed 's/[][*?\\]/\\&/g')
    [ -n "$(git apply --numstat --include="$pat" "$patch" 2>/dev/null)" ] || continue
    if git apply --check --include="$pat" "$patch" 2>/dev/null; then
      rm -f "$patch"; return 1                             # this file's change was undone
    fi
  done <<< "$names"
  rm -f "$patch"
  # The upstream copies: commits on tip's side that git marks patch-equivalent ('=').
  eq=$(git log --cherry-mark --right-only --no-merges --format='%m %H' "${FEATURE_SHA}...${tip}" 2>/dev/null \
       | awk '$1 == "=" { print $2 }')
  [ -n "$eq" ] || return 1
  for sha in $eq; do
    log=$(git log --format=%B "${sha}..${tip}" 2>/dev/null)   # captured: no SIGPIPE under pipefail
    case "$log" in *"This reverts commit ${sha}"*) return 1 ;; esac
  done
  return 0
}

_nothing_left_to_land() {
  local tip="$1" patch
  patch=$(mktemp "${TMP_ROOT}/autocoder-merge-${REPO_ID}-${ISSUE_NUM}.patch.XXXXXX")
  git diff --binary "${FEATURE_BASE:-$INT_SEEN_SHA}" "$FEATURE_SHA" > "$patch"
  if [ -s "$patch" ] && git apply -R --check "$patch" 2>/dev/null; then
    rm -f "$patch"
    echo "ℹ️  Rebasing ${FEATURE} (${FEATURE_SHA:0:8}) onto origin/${INTEGRATION_BRANCH} left nothing to land: its changes are already there."
    _already_landed "$tip"
  fi
  rm -f "$patch"
  if _landed_by_patch_id "$tip"; then
    echo "ℹ️  ${FEATURE} (${FEATURE_SHA:0:8}) is already on origin/${INTEGRATION_BRANCH} as patch-equivalent commits (later edited by others, not reverted); nothing to land."
    _already_landed "$tip"
  fi
  echo "❌ Rebasing ${FEATURE} (${FEATURE_SHA:0:8}) dropped every commit as already upstream, but origin/${INTEGRATION_BRANCH} (${tip:0:8}) does not carry its change. NOT closing."
  _fail 1 "rebasing ${FEATURE_SHA:0:8} onto origin/${INTEGRATION_BRANCH} dropped every commit as already applied, but ${tip:0:8} does not contain the change (an earlier copy may have been reverted); nothing landed"
}

_rebase_onto_integration
if [ "$(git rev-parse HEAD)" = "$INT_SEEN_SHA" ]; then
  _nothing_left_to_land "$INT_SEEN_SHA"
fi
echo "ℹ️  Rebased ${FEATURE} (${FEATURE_SHA:0:8}) onto origin/${INTEGRATION_BRANCH} (${INT_SEEN_SHA:0:8}): $(git rev-list --count "${INT_SEEN_SHA}..HEAD") commit(s), tip $(git rev-parse --short=8 HEAD)."

# 2. Gate the COMBINED tree (this fix + everyone else's merged work). This is the step that
#    catches cross-fix breakage before it lands on the integration branch.
#
#    PUBLISH_BASIS is the one record of why the tree we push is allowed to land, and the
#    final success line is a case over it:
#      tested     the gate passed on exactly the tree we publish (TESTED_TREE). TESTED_TREE
#                 is HEAD's tree when the gate command ENDS, not when it starts: a gate
#                 command may commit inside its worktree by contract (regenerated files,
#                 a baseline ratchet) before its test stages, and the tree it leaves is the
#                 one its tests ran on. Reading the tree first declared every such pass an
#                 internal error after the push. The push loop compares HEAD's tree with
#                 TESTED_TREE before EVERY push and re-gates on a mismatch, so a tree the
#                 gate did not pass is never published under this basis.
#      docs-only  nothing for a test suite to verify
#      docs-resync
#                 the gate passed on TESTED_TREE; a later re-sync brought in documents
#                 only, which no test stage reads, so the published tree differs from
#                 the tested one in documents alone (DOCS_RESYNC_FILES of them)
#      disjoint   the gate passed on TESTED_TREE; a later re-sync brought in files that
#                 touch neither this change nor a global path, so the published tree is
#                 by construction not the tested one
#      red-base   the gate failed on the integrated tree AND on origin/<integration> alone
#      red-base-disjoint
#                 red-base, then a disjoint re-sync: the published tree is neither tree
#                 the gate ran on
#    Only tested and docs-only let _close_or_park close the issue; the rest park it.
TESTED_TREE=""
PUBLISH_BASIS=""
# Re-syncs a failed gate made because origin/<integration> moved past the tree's base (#375).
MOVED_BASE_REGATES=0
MOVED_BASE_REGATE_MAX="${AUTOCODER_MOVED_BASE_REGATES:-2}"
[[ "$MOVED_BASE_REGATE_MAX" =~ ^[0-9]{1,3}$ ]] || MOVED_BASE_REGATE_MAX=2
RED_INTEGRATED_TREE=""
RED_BASE_TREE=""
RED_BASE_FAILURES=""
RED_BASE_EXTRA=""   # failures the base named alone, beyond the shared ones (#326)
DOCS_RESYNC_FILES=0

# The host could not run the gate on <where> (trees <started> -> <left>; <line> decided
# it). That is no verdict about master or this change: forget any fail the cache just
# recorded for those trees, say why in the shape a train's classifier reads
# (`::error::<stage>: INFRASTRUCTURE -- ...`), and stop before anything is pushed.
_refuse_infrastructure() {
  local where="$1" started="$2" left="$3" line="$4"
  echo "::error::merge-to-integration: INFRASTRUCTURE -- the gate did not reach a verdict on ${where}: ${line}"
  echo "   That is a host condition, not a test failure, so nothing is known about origin/${INTEGRATION_BRANCH} or this change. NOT pushing."
  echo "   Branch '${FEATURE}' is untouched; relaunch the merge once the host is fixed."
  gate_cache_forget "$started" "$TEST_CMD"
  [ "$left" = "$started" ] || gate_cache_forget "$left" "$TEST_CMD"
  LANDING_CAUSE=infra   # the ledger's cause, as a train records the same verdict
  _fail 3 "INFRASTRUCTURE: the gate did not reach a verdict on ${where} (${line}). A host condition, not a test failure: nothing about this change is in doubt and nothing landed. Relaunch the merge once the host is fixed; branch \`${FEATURE}\` is intact"
}

# One line per re-run file (#298): fails on the base too (red base, not this change's) or
# passes on the base (this change's). <green> is 1 when the base run passed.
_retest_report() {  # <base-offset> <green> <files>
  local f base_failed
  [ -n "$3" ] || return 0
  base_failed=$(_gate_slice "$1" | _gate_failed_files)
  for f in $3; do
    if [ "$2" != 1 ] && printf '%s\n' "$base_failed" | grep -qxF -- "$f"; then
      echo "   ${f}: fails on origin/${INTEGRATION_BRANCH} too (red base, not this change's)"
    elif [ "$2" = 1 ] || [ -n "$base_failed" ]; then
      echo "   ${f}: passes on origin/${INTEGRATION_BRANCH} (this change's)"
    else
      echo "   ${f}: not named on origin/${INTEGRATION_BRANCH}, whose run failed without naming a test file"
    fi
  done
}

_gate_integrated_tree() {
  if [ "$DOCS_ONLY" -eq 1 ]; then
    PUBLISH_BASIS=docs-only
    return 0
  fi
  local tree head_before after base_sha base_tree base_left at base_at infra
  local -a integrated_failures base_failures
  local only_integrated only_base retest_files
  MERGE_RED_BASE=0   # a re-gate on a new tip measures the base again
  RED_BASE_EXTRA=""
  unset AUTOCODER_GATE_RETEST_FILES   # set only for the base run below (#298)
  head_before=$(git rev-parse HEAD)
  tree=$(git rev-parse "HEAD^{tree}")
  at=$(_gate_log_size)
  echo "🧪 Gating the integrated tree ${tree:0:8}: $TEST_CMD"
  : > "$GATE_LAST"
  # A gate already ran on an earlier tree: that run is thrown away by this re-gate.
  DISCARDED_S=$((DISCARDED_S + GATE_LAST_S)) GATE_LAST_S=0
  _g0=$SECONDS GATE_INFLIGHT_T0=$SECONDS
  _stage_timings_begin
  if _gate_in_slot "$WORKTREE_DIR" "$TEST_CMD" 2>&1 | tee -a "$GATE_LOG" "$GATE_LAST"; then
    _landing_gate_done $((SECONDS - _g0))
    _stage_timings_end; STAGE_ARGS="$RUN_STAGE_ARGS"
    # The tested tree is the one the command LEFT. A gate command may commit inside its
    # worktree before its test stages (regenerated files, a baseline ratchet); its tests
    # then ran on that tree, and publishing it is right. Keeping the ordering (commits
    # before the test stages) is the gate command's own contract.
    after=$(git rev-parse "HEAD^{tree}")
    if [ "$after" != "$tree" ]; then
      echo "ℹ️  The gate command committed inside its worktree (tree ${tree:0:8} -> ${after:0:8}: $(git log --format='%h %s' "${head_before}..HEAD" | paste -sd ';' - | sed 's/;/; /g')). The tested tree is the one it left, ${after:0:8}."
    fi
    TESTED_TREE="$after"
    PUBLISH_BASIS=tested
    return 0
  fi

  _landing_gate_done $((SECONDS - _g0))
  _stage_timings_end; STAGE_ARGS="$RUN_STAGE_ARGS"
  # The command may have committed inside its worktree before failing; the tree it left
  # is the one its fail record (and any refusal) is about as much as the one it started on.
  after=$(git rev-parse "HEAD^{tree}")
  if infra=$(_gate_infra_line "$at"); then
    _refuse_infrastructure "the integrated tree ${tree:0:8}" "$tree" "$after" "$infra"
  fi
  tree="$after"
  mapfile -t integrated_failures < <(_gate_named_failures "$at")
  # The test files that failed, relative to the worktree (#298). A gate command that
  # selects tests by the tree's diff selects nothing on the base, whose diff is empty, so
  # the base run is told which files to re-run. The command may honour the variable.
  retest_files=$(sed -E $'s/\e\\[[0-9;]*[A-Za-z]//g' "$GATE_LAST" | _gate_failed_files | paste -sd' ' -)
  # The base to measure is the one this tree was built on, not whatever origin/<integration>
  # points at now (#375): a sibling's fetch, or the one below, can move the ref during the
  # gate, and a fix that landed meanwhile then makes the base "pass alone" and the change is
  # blamed for a red it never had. When the tip has moved past the base, re-sync onto it and
  # gate again (at most AUTOCODER_MOVED_BASE_REGATES times) instead of judging either tree.
  local tip_sha
  git_net_long fetch origin "$INTEGRATION_BRANCH" >/dev/null 2>&1 || true   # a stale ref only skips the re-sync
  tip_sha=$(git rev-parse "origin/${INTEGRATION_BRANCH}")
  base_sha=$(git merge-base HEAD "$tip_sha" 2>/dev/null) || base_sha="$tip_sha"
  if [ "$base_sha" != "$tip_sha" ] && [ "$MOVED_BASE_REGATES" -lt "$MOVED_BASE_REGATE_MAX" ]; then
    MOVED_BASE_REGATES=$((MOVED_BASE_REGATES + 1))
    echo "❌ Tests fail on the integrated tree ${tree:0:8}, built on origin/${INTEGRATION_BRANCH} ${base_sha:0:8}; origin/${INTEGRATION_BRANCH} has since moved to ${tip_sha:0:8}."
    echo "ℹ️  Re-syncing onto ${tip_sha:0:8} and re-gating (${MOVED_BASE_REGATES}/${MOVED_BASE_REGATE_MAX}) instead of judging this change against a base it was not built on (#375)."
    # The failed run may have left tracked edits (an untested state, never published);
    # they would stop the rebase and read as a conflict. A conflict the first sync
    # resolved is still in HEAD, so the flag stays set across this clean re-sync.
    local was_resolved="$REBASE_RESOLVED"
    git reset -q --hard HEAD
    _rebase_onto_integration
    [ "$was_resolved" = 1 ] && REBASE_RESOLVED=1
    if [ "$(git rev-parse HEAD)" = "$tip_sha" ]; then
      _nothing_left_to_land "$tip_sha"
    fi
    # The push loop sets INT_SEEN_SHA to its own (older) fetch after this returns; the
    # next re-sync then measures a wider range, which can only re-gate more, not less.
    INT_SEEN_SHA="$tip_sha"
    _gate_integrated_tree
    return
  fi
  # Before judging the change against its base, ask whether the failure reproduces at all: the files
  # that failed are re-run once on the SAME tree (the gate command honours AUTOCODER_GATE_RETEST_FILES as a
  # list, so this is one targeted run, seconds to minutes). A pass means the red did not reproduce on an
  # identical tree: a flake, nobody's. It is refused as FLAKY (never landed over, never charged to the
  # change, never bisected by a train), so the flaky file is filed instead of a member being returned for it.
  # AUTOCODER_GATE_FLAKY_RETEST=0 turns the retest off (the old behaviour: straight to the base run).
  if [ -n "$retest_files" ] && [ "${AUTOCODER_GATE_FLAKY_RETEST:-1}" != 0 ]; then
    local flaky_at
    echo "❌ Tests fail on the integrated tree ${tree:0:8} (${#integrated_failures[@]} named failure(s))."
    echo "   Re-running the files that failed on the same tree first: AUTOCODER_GATE_RETEST_FILES=\"${retest_files}\" (a pass means the failure did not reproduce: flaky, nobody's)"
    export AUTOCODER_GATE_RETEST_FILES="$retest_files"
    flaky_at=$(_gate_log_size)
    _g0=$SECONDS GATE_INFLIGHT_T0=$SECONDS
    _stage_timings_begin
    if _gate_in_slot "$WORKTREE_DIR" "$TEST_CMD" 2>&1 | tee -a "$GATE_LOG"; then
      _landing_gate_done $((SECONDS - _g0))
      _stage_timings_end
      unset AUTOCODER_GATE_RETEST_FILES
      echo "merge-to-integration: FLAKY -- $(printf '%s\n' $retest_files | _join_lines) failed on the integrated tree ${tree:0:8} and passed on a second run of the same tree: the failure did not reproduce, so it is nobody's. NOT pushing."
      echo "   A flake is filed and fixed, never landed over: relaunch the merge; a train re-gates the same members once."
      gate_cache_forget "$tree" "$TEST_CMD"
      LANDING_CAUSE=flaky
      _fail 3 "FLAKY: \`$(printf '%s\n' $retest_files | _join_lines)\` failed on the integrated tree ${tree:0:8} and passed on a second run of the same tree. The failure did not reproduce, so nothing about this change is in doubt and nothing landed; file the flake, then relaunch the merge; branch \`${FEATURE}\` is intact"
    fi
    _landing_gate_done $((SECONDS - _g0))
    _stage_timings_end
    unset AUTOCODER_GATE_RETEST_FILES
    if infra=$(_gate_infra_line "$flaky_at"); then
      _refuse_infrastructure "the second run of the integrated tree ${tree:0:8}" "$tree" "$tree" "$infra"
    fi
    echo "   The failure reproduced on the same tree; judging it against origin/${INTEGRATION_BRANCH} alone."
  fi
  base_tree=$(git rev-parse "${base_sha}^{tree}")
  echo "❌ Tests fail on the integrated tree ${tree:0:8} (${#integrated_failures[@]} named failure(s))."
  echo "   Gating origin/${INTEGRATION_BRANCH} (${base_sha:0:8}, tree ${base_tree:0:8}) alone to see whether this change broke it."
  if [ -n "$retest_files" ]; then
    echo "   Re-running the files that failed: AUTOCODER_GATE_RETEST_FILES=\"${retest_files}\""
    export AUTOCODER_GATE_RETEST_FILES="$retest_files"
  fi
  _remove_worktree "$BASE_WORKTREE_DIR"
  if ! git -C "$CALLER_DIR" worktree add --detach "$BASE_WORKTREE_DIR" "$base_sha"; then
    echo "❌ Could not create a worktree for origin/${INTEGRATION_BRANCH}; cannot tell whose failure this is. NOT pushing."
    _fail 2 "tests fail on the integrated tree ${tree:0:8} (origin/${INTEGRATION_BRANCH} could not be gated alone)"
  fi
  seed_worktree_deps "$CALLER_DIR" "$BASE_WORKTREE_DIR"
  _g0=$SECONDS GATE_INFLIGHT_T0=$SECONDS
  _base_green=0
  base_at=$(_gate_log_size)
  _stage_timings_begin   # the base run's stages are its own, not the batch's
  # A cached pass on the base tree is evidence only for the selection that run made (#375):
  # a diff-scoped gate that recorded it for another change never ran the failing files.
  # Under a retest list the key is that list (#298), so its pass is this selection's; with
  # no list, the plain key could hold anyone's pass, so the base is gated again.
  if [ -z "$retest_files" ]; then export GATE_CACHE_RERUN_PASS=1; fi
  _gate_in_slot "$BASE_WORKTREE_DIR" "$TEST_CMD" 2>&1 | tee -a "$GATE_LOG" && _base_green=1
  unset GATE_CACHE_RERUN_PASS
  _landing_gate_done $((SECONDS - _g0))
  _stage_timings_end
  _retest_report "$base_at" "$_base_green" "$retest_files"
  if [ "$_base_green" -eq 1 ]; then
    unset AUTOCODER_GATE_RETEST_FILES
    echo "❌ origin/${INTEGRATION_BRANCH} passes alone, so this change broke it. NOT pushing."
    echo "   The fix remains on '${FEATURE}'; investigate the interaction with newly merged work."
    GATE_BOUNCE=1
    _fail 2 "tests fail on the integrated tree ${tree:0:8} and pass on origin/${INTEGRATION_BRANCH} alone (tree ${base_tree:0:8}), so this change broke it$([ -z "$retest_files" ] || printf ': `%s`' "$(printf '%s\n' $retest_files | _join_lines)")"
  fi
  base_left=$(git -C "$BASE_WORKTREE_DIR" rev-parse "HEAD^{tree}" 2>/dev/null || echo "$base_tree")
  _remove_worktree "$BASE_WORKTREE_DIR"
  if infra=$(_gate_infra_line "$base_at"); then
    _refuse_infrastructure "origin/${INTEGRATION_BRANCH} alone (tree ${base_tree:0:8})" "$base_tree" "$base_left" "$infra"
  fi
  unset AUTOCODER_GATE_RETEST_FILES
  # The base failed alone, as tests, on the same command: whatever follows (refused,
  # landed anyway, or charged to this change for extra failures) happened on a red base.
  MERGE_RED_BASE=1
  mapfile -t base_failures < <(_gate_named_failures "$base_at")
  # The retest files the base run named failing too: red <integration>, not this change's.
  local red_files="" base_failed_files f
  if [ -n "$retest_files" ]; then
    base_failed_files=$(_gate_slice "$base_at" | _gate_failed_files)
    for f in $retest_files; do
      grep -qxF -- "$f" <<<"$base_failed_files" && red_files="${red_files:+$red_files }$f"
    done
  fi
  local red_note=""
  [ -z "$red_files" ] || red_note=" (red ${INTEGRATION_BRANCH} in \`$(printf '%s\n' $red_files | _join_lines)\` besides)"

  # Both runs failed as tests. The base is red "independent of this change" when every
  # failure the integrated run names also fails on the base (#326): anything the integrated
  # run names alone is this change's. Extra failures on the base alone (flaky or
  # environment-dependent suites) clear nothing and blame nothing. A run that names
  # nothing proves nothing about either tree.
  if [ "${#integrated_failures[@]}" -eq 0 ] || [ "${#base_failures[@]}" -eq 0 ]; then
    echo "❌ Both trees fail, but the gate named no failing test or check on $([ "${#integrated_failures[@]}" -eq 0 ] && echo "the integrated tree" || echo "origin/${INTEGRATION_BRANCH} alone") (nothing matched AUTOCODER_GATE_FAILURE_PATTERNS), so the failures cannot be compared. NOT pushing."
    echo "   A red-base landing needs every failure the integrated tree names to fail on the base too; read the gate output and either fix the change or relaunch once origin/${INTEGRATION_BRANCH} is fixed."
    _fail 2 "tests fail on the integrated tree ${tree:0:8} and on origin/${INTEGRATION_BRANCH} alone (tree ${base_tree:0:8}), but the gate named no failing test or check on $([ "${#integrated_failures[@]}" -eq 0 ] && echo "the integrated tree" || echo "the base"), so the failures cannot be compared; not a red-base landing"
  fi
  only_integrated=$(comm -23 <(printf '%s\n' "${integrated_failures[@]}") <(printf '%s\n' "${base_failures[@]}"))
  only_base=$(comm -13 <(printf '%s\n' "${integrated_failures[@]}") <(printf '%s\n' "${base_failures[@]}"))
  if [ -n "$only_integrated" ]; then
    echo "❌ The integrated tree ${tree:0:8} names failure(s) origin/${INTEGRATION_BRANCH} alone does not, so this change broke it (at least these). NOT pushing."
    printf '   this change only: %s\n' "$only_integrated"
    [ -z "$only_base" ] || printf '   base only:        %s\n' "$only_base"
    [ -z "$red_files" ] || printf '   red %s, not this change'"'"'s: %s\n' "$INTEGRATION_BRANCH" "$red_files"
    _fail 2 "tests fail on the integrated tree ${tree:0:8} with failure(s) origin/${INTEGRATION_BRANCH} alone (tree ${base_tree:0:8}) does not have, so this change broke it: \`$(printf '%s\n' "$only_integrated" | _join_lines)\`${red_note}"
  fi
  # The integrated tree's failures are a subset of the base's. Say how they compare.
  local same_desc="the same ${#integrated_failures[@]} named failure(s)" base_extra=0
  if [ -n "$only_base" ]; then
    base_extra=$(printf '%s\n' "$only_base" | grep -c .)
    same_desc="all ${#integrated_failures[@]} of the integrated tree's named failure(s), and ${base_extra} more"
    echo "ℹ️  origin/${INTEGRATION_BRANCH} alone also fails ${base_extra} suite(s) the integrated tree passes; the integrated tree's failures are a subset of the base's (#326)."
    printf '   base only: %s\n' "$only_base"
    RED_BASE_EXTRA=$(printf '%s\n' "$only_base" | _join_lines)
  fi
  RED_BASE_FAILURES=$(printf '%s\n' "${integrated_failures[@]}" | _join_lines)
  LANDING_CAUSE=red-integration   # the base is red too: the batch is red, though not this change's fault
  # One line a close-out (a train runner, a lane) reads: the base is red in these files, not this change.
  echo "merge-to-integration: RED-BASE -- origin/${INTEGRATION_BRANCH} (${base_sha:0:8}) fails alone too with ${same_desc}${red_files:+ in ${red_files}}: red ${INTEGRATION_BRANCH}, not this change's."
  if [ "$MERGE_ON_RED_BASE" != "1" ]; then
    echo "❌ origin/${INTEGRATION_BRANCH} fails alone too (tree ${base_tree:0:8}, ${same_desc}), and ${RED_BASE_REFUSAL}. NOT pushing."
    echo "   Red ${INTEGRATION_BRANCH}, not this change: hold the branch, open or cite the issue for red ${INTEGRATION_BRANCH}, and relaunch once it is fixed."
    _fail 2 "tests fail on the integrated tree ${tree:0:8} and on origin/${INTEGRATION_BRANCH} alone (tree ${base_tree:0:8}) with ${same_desc}$([ -z "$red_files" ] || printf ' (red %s in `%s`, not this change'"'"'s)' "$INTEGRATION_BRANCH" "$(printf '%s\n' $red_files | _join_lines)"); ${RED_BASE_REFUSAL}"
  fi
  echo "⚠️  origin/${INTEGRATION_BRANCH} fails alone too (tree ${base_tree:0:8}) with ${same_desc}: the integration branch is red independent of this change."
  printf '   %s\n' "${integrated_failures[@]}"
  echo "   Pushing anyway; the post-merge sentinel owns red ${INTEGRATION_BRANCH}."
  RED_INTEGRATED_TREE="$tree"
  RED_BASE_TREE="$base_tree"
  PUBLISH_BASIS=red-base
}
_gate_integrated_tree

# rc 0 when $1 is a path the gate command runs, or lies under a directory it runs.
_path_is_gate_cmd() {
  local path="$1" k
  for k in "${!TEST_CMD_PATHS[@]}"; do
    if [[ "$path" == "$k" || "$path" == "$k"/* ]]; then
      return 0
    fi
  done
  return 1
}

# Prints why $1 obliges a re-gate whatever this change touched (rc 0), or nothing (rc 1).
_path_is_global() {
  local path="$1"
  if regate_path_is_global "$path"; then
    echo "a global path"
    return 0
  fi
  if _path_is_gate_cmd "$path"; then
    echo "a path the gate command runs"
    return 0
  fi
  return 1
}

# Prints the first incoming path that obliges a re-gate (rc 0), or nothing (rc 1) when the
# incoming files are disjoint from this change and from every global path.
_resync_overlap() {
  local old="$1" new="$2" f why
  if [ -z "$FEATURE_BASE" ]; then
    echo "every incoming file (no merge base with origin/${INTEGRATION_BRANCH})"
    return 0
  fi
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ -n "${FEATURE_FILE_SET[$f]+x}" ]; then
      echo "$f (a file this change touched)"
      return 0
    fi
    if why=$(_path_is_global "$f"); then
      echo "$f ($why)"
      return 0
    fi
  done < <(git diff --name-only --no-renames "$old" "$new")
  return 1
}

# A re-sync whose incoming files are all documents, none a file this change touched or a
# path the gate command runs: prints the incoming file count (rc 0), or nothing (rc 1).
# Needs a merge base, like the overlap test: an unknown file set is never documents-only.
_resync_docs_only() {
  local old="$1" new="$2" f n=0
  [ -n "$FEATURE_BASE" ] || return 1
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -z "${FEATURE_FILE_SET[$f]+x}" ] || return 1
    _path_is_gate_cmd "$f" && return 1
    is_docs_path "$f" || return 1
    n=$((n + 1))
  done < <(git diff --name-only --no-renames "$old" "$new")
  echo "$n"
}

# AUTOCODER_DOCS_RESYNC_CMD on the re-synced tree (a repo's cheap document checks): rc 0
# when unset or passing; on failure says so and returns 1, so the delta is re-gated as code.
_docs_resync_checks_pass() {
  [ -n "${AUTOCODER_DOCS_RESYNC_CMD:-}" ] || return 0
  echo "🧪 Documents-only re-sync: running the document checks on the re-synced tree: ${AUTOCODER_DOCS_RESYNC_CMD}"
  (cd "$WORKTREE_DIR" && bash -c "$AUTOCODER_DOCS_RESYNC_CMD") 2>&1 | tee -a "$GATE_LOG"
  if [ "${PIPESTATUS[0]}" -eq 0 ]; then
    return 0
  fi
  echo "⚠️  The document checks failed on the re-synced tree; treating the delta as code, so the ordinary re-gate rule decides"
  return 1
}

# Records a documents-only re-sync of $1 files in the publish basis. A tested tree that the
# documents left byte-identical stays tested; otherwise tested becomes docs-resync. A red
# base stays parked, as after any re-sync.
_note_docs_resync() {
  local tree
  tree=$(git rev-parse "HEAD^{tree}")
  DOCS_RESYNC_FILES=$((DOCS_RESYNC_FILES + $1))
  case "$PUBLISH_BASIS" in
    tested)   [ "$tree" = "$TESTED_TREE" ] || PUBLISH_BASIS=docs-resync ;;
    red-base) PUBLISH_BASIS=red-base-disjoint ;;
  esac
}

# 3. Push the rebased tip to the integration branch (a fast-forward). If a sibling worker
#    pushed in the meantime the push is rejected; re-sync by rebasing again and retry. A re-sync that brings in work
#    overlapping this change produces a tree nobody has tested, so it goes back through the
#    gate before the next push (and before the API fallback below, which publishes whatever
#    HEAD is). A disjoint re-sync is pushed as-is and recorded as such.
PUSH_VIA=""
for attempt in 1 2 3 4 5; do
  # Never publish a tree the gate did not pass. Under the `tested` basis HEAD's tree must
  # still be TESTED_TREE here: every re-sync below either re-gates or changes the basis,
  # so anything else moved HEAD behind the gate's back (a hook, a stage that committed
  # after the record). That tree goes through the gate again BEFORE the push, instead of
  # being pushed and then declared an internal error afterwards.
  if [ "$PUBLISH_BASIS" = tested ]; then
    HEAD_TREE=$(git rev-parse "HEAD^{tree}")
    if [ "$HEAD_TREE" != "$TESTED_TREE" ]; then
      echo "⚠️  HEAD's tree ${HEAD_TREE:0:8} is not the tested tree ${TESTED_TREE:0:8} (last commit: $(git log -1 --format='%h %s')); not pushing an untested tree. Re-gating it."
      _gate_integrated_tree
    fi
  fi
  push_rc=0
  git_net_long push origin "HEAD:${INTEGRATION_BRANCH}" || push_rc=$?
  if [ "$push_rc" -eq 0 ]; then
    PUSHED=1; PUSH_VIA=git
    break
  fi
  if git_net_timed_out "$push_rc"; then
    echo "⚠️  Push to '${INTEGRATION_BRANCH}' timed out after ${AUTOCODER_GIT_TIMEOUT_LONG:-300}s (stalled connection); re-syncing (attempt ${attempt}/5)…"
  else
    echo "⚠️  Push to '${INTEGRATION_BRANCH}' rejected (a sibling worker likely pushed first); re-syncing (attempt ${attempt}/5)…"
  fi
  PUSH_RETRIES=$attempt
  merge_event event=push-retry outcome=push-retry repo="$(_merge_repo_id)" issue="${ISSUE_NUM:-}" \
    branch="${FEATURE:-}" attempt="${AUTOCODER_MERGE_ATTEMPT:-}" push_retries="$attempt"
  git_net_long fetch origin "$INTEGRATION_BRANCH" || break
  INT_NEW_SHA=$(git rev-parse "origin/${INTEGRATION_BRANCH}")
  BEFORE_RESYNC=$(git rev-parse HEAD)
  _rebase_onto_integration
  if [ "$(git rev-parse HEAD)" = "$INT_NEW_SHA" ]; then
    # Someone else landed the same changes while we gated.
    _nothing_left_to_land "$INT_NEW_SHA"
  fi
  if [ "$REBASE_RESOLVED" -eq 1 ]; then
    echo "ℹ️  Re-sync needed a conflict resolution; re-gating the merged tree"
    _gate_integrated_tree
  elif [ "$(git rev-parse HEAD)" != "$BEFORE_RESYNC" ]; then
    if DOCS_COUNT=$(_resync_docs_only "$INT_SEEN_SHA" "$INT_NEW_SHA") && _docs_resync_checks_pass; then
      echo "ℹ️  Documents-only re-sync (${DOCS_COUNT} incoming files, all documents, none this change touched): test stages not re-run; pushing the gated work"
      _note_docs_resync "$DOCS_COUNT"
    elif [ "$SCOPED_REGATE" != "1" ]; then
      echo "ℹ️  Re-sync brought in new work and the scoped re-gate is off; re-gating the merged tree"
      _gate_integrated_tree
    elif OVERLAP=$(_resync_overlap "$INT_SEEN_SHA" "$INT_NEW_SHA"); then
      echo "ℹ️  Re-sync brings in ${OVERLAP}; re-gating the merged tree"
      _gate_integrated_tree
    else
      INCOMING_COUNT=$(git diff --name-only --no-renames "$INT_SEEN_SHA" "$INT_NEW_SHA" | wc -l | tr -d ' ')
      echo "ℹ️  Disjoint re-sync (${INCOMING_COUNT} incoming files, none overlap this change); pushing the already-gated work"
      case "$PUBLISH_BASIS" in
        tested|docs-resync) PUBLISH_BASIS=disjoint ;;
        red-base)           PUBLISH_BASIS=red-base-disjoint ;;
      esac
    fi
  fi
  INT_SEEN_SHA="$INT_NEW_SHA"
done

# 3b. If the git transport itself is blocked (e.g. a proxy rejecting
#     git-receive-pack with HTTP 403), retrying cannot help — fall back to
#     publishing through the GitHub API, which reaches api.github.com instead.
if [ "$PUSHED" -ne 1 ]; then
  echo "⚠️  git push failed after 5 attempts — trying the GitHub API fallback…"
  if python3 "${_MTI_DIR}/api-push.py" HEAD \
       --target "$INTEGRATION_BRANCH" \
       --base "origin/${INTEGRATION_BRANCH}" \
       --message "Merge issue #${ISSUE_NUM} (${FEATURE}) into ${INTEGRATION_BRANCH}

Published via the GitHub API because the git transport is blocked."; then
    PUSHED=1; PUSH_VIA=api
  fi
fi

if [ "$PUSHED" -ne 1 ]; then
  echo "❌ Could not publish to '${INTEGRATION_BRANCH}' (git push and API fallback both failed)."
  echo "   The fix is safe on '${FEATURE}'. NOT closing the issue — nothing landed."
  _fail 1 "could not publish to '${INTEGRATION_BRANCH}' (git push and the API fallback both failed)"
fi

# 3c. Trust nothing: confirm the integration ref actually contains this work.
#     A zero exit status is not proof, and `git push --dry-run` is worse than
#     useless here — it succeeds against a blocked transport because it never
#     sends the pack. Compare the trees.
git_net_long fetch origin "$INTEGRATION_BRANCH" --quiet 2>/dev/null || true
LOCAL_TREE=$(git rev-parse "HEAD^{tree}")
REMOTE_TREE=$(git rev-parse "origin/${INTEGRATION_BRANCH}^{tree}" 2>/dev/null || echo "")
if [ -z "$REMOTE_TREE" ] || [ "$LOCAL_TREE" != "$REMOTE_TREE" ]; then
  echo "❌ Publication could not be verified for '${INTEGRATION_BRANCH}'."
  echo "   local tree  ${LOCAL_TREE}"
  echo "   remote tree ${REMOTE_TREE:-<none>}"
  echo "   NOT closing the issue — the tracker must never claim work landed when it did not."
  _fail 1 "publication could not be verified: local tree ${LOCAL_TREE:0:8}, remote tree ${REMOTE_TREE:-<none>}"
fi

# The commit that is now on origin/<integration> carrying this work. A git push landed
# HEAD itself; the API fallback minted a new commit, so the fetched remote tip is it.
if [ "$PUSH_VIA" = git ]; then
  LANDED_SHA=$(git rev-parse HEAD)
else
  LANDED_SHA=$(git rev-parse "origin/${INTEGRATION_BRANCH}")
fi
# Our work is on the remote; the next job on this host can sync onto it and land.
merge_queue_release

# The word "verified" is reserved for the one case where the gate passed on the very tree
# that is now on the integration branch. PARK_NOTE explains every other basis to the
# issue when _close_or_park parks it.
RED_BASE_NOTE="The gate failed on the integrated tree \`${RED_INTEGRATED_TREE}\` and also on \`origin/${INTEGRATION_BRANCH}\` alone (tree \`${RED_BASE_TREE}\`), both naming the same failure(s): \`${RED_BASE_FAILURES}\`${RED_BASE_EXTRA:+ (the base alone also named \`${RED_BASE_EXTRA}\`)}; so the integration branch was already red independent of this change. Branch \`${FEATURE}\` was pushed anyway"
case "$PUBLISH_BASIS" in
  docs-only)
    echo "✅ Issue #${ISSUE_NUM} merged into '${INTEGRATION_BRANCH}' (documentation-only change; no tests run; tree ${LOCAL_TREE:0:8})." ;;
  tested)
    if [ -n "$TESTED_TREE" ] && [ "$TESTED_TREE" = "$LOCAL_TREE" ]; then
      echo "✅ Issue #${ISSUE_NUM} merged into '${INTEGRATION_BRANCH}' and verified: tests passed on the published tree ${LOCAL_TREE:0:8}."
    else
      echo "❌ Internal error: published tree ${LOCAL_TREE:0:8} is not the tree the tests passed on (${TESTED_TREE:0:8})." >&2
      _fail 1 "internal error: published tree ${LOCAL_TREE:0:8} is not the tested tree ${TESTED_TREE:0:8}"
    fi ;;
  docs-resync)
    echo "✅ Issue #${ISSUE_NUM} merged into '${INTEGRATION_BRANCH}': tests passed on tree ${TESTED_TREE:0:8}; a documents-only re-sync (${DOCS_RESYNC_FILES} document files) then published tree ${LOCAL_TREE:0:8} without re-running the test stages." ;;
  disjoint)
    PARK_NOTE="The gate passed on tree \`${TESTED_TREE}\`; a disjoint push-race re-sync then changed the published tree to \`${LOCAL_TREE}\`, which no gate has run on."
    echo "✅ Issue #${ISSUE_NUM} merged into '${INTEGRATION_BRANCH}' (disjoint re-sync; gated tree ${TESTED_TREE:0:8}, published tree ${LOCAL_TREE:0:8})." ;;
  red-base)
    PARK_NOTE="**Merged onto a red \`${INTEGRATION_BRANCH}\`.** ${RED_BASE_NOTE} (published tree \`${LOCAL_TREE}\`); the post-merge sentinel owns red \`${INTEGRATION_BRANCH}\`."
    echo "✅ Issue #${ISSUE_NUM} merged into '${INTEGRATION_BRANCH}' on a red base (gate failed on integrated tree ${RED_INTEGRATED_TREE:0:8} and on origin/${INTEGRATION_BRANCH} alone, tree ${RED_BASE_TREE:0:8}; published tree ${LOCAL_TREE:0:8}, which the gate did not pass)." ;;
  red-base-disjoint)
    PARK_NOTE="**Merged onto a red \`${INTEGRATION_BRANCH}\`, then re-synced.** ${RED_BASE_NOTE}, and a disjoint push-race re-sync then changed the published tree to \`${LOCAL_TREE}\`, which is neither tree the gate ran on; the post-merge sentinel owns red \`${INTEGRATION_BRANCH}\`."
    echo "✅ Issue #${ISSUE_NUM} merged into '${INTEGRATION_BRANCH}' on a red base followed by a disjoint re-sync (gate failed on integrated tree ${RED_INTEGRATED_TREE:0:8} and on origin/${INTEGRATION_BRANCH} alone, tree ${RED_BASE_TREE:0:8}; published tree ${LOCAL_TREE:0:8} is neither gated tree)." ;;
  *)
    echo "❌ Internal error: no publish basis recorded for tree ${LOCAL_TREE:0:8}." >&2
    _fail 1 "internal error: no publish basis recorded for tree ${LOCAL_TREE:0:8}" ;;
esac
# Without --own-issue nobody parks the issue, so a red-base landing still tells it.
case "$PUBLISH_BASIS" in
  red-base|red-base-disjoint)
    [ "$OWN_ISSUE" -eq 1 ] || issue_comment "$ISSUE_NUM" --body "⚠️ ${PARK_NOTE}" 2>/dev/null || true ;;
esac

# 3d. Publish the landed commit as a tip ref for the sentinel. Never fatal.
TIP_REF="refs/autocoder/tips/${INTEGRATION_BRANCH}/${LANDED_SHA}-${ISSUE_NUM}"
if git_net_long push origin "${LANDED_SHA}:${TIP_REF}" >/dev/null 2>&1; then
  echo "ℹ️  Published ${LANDED_SHA:0:8} as ${TIP_REF}."
else
  echo "⚠️  Could not publish ${TIP_REF} (not fatal; the sentinel will see the branch tip)."
fi

# 4. Clean up the feature branch now that its work is on the integration branch. Only
# while it still points at FEATURE_SHA, the feature tip this job landed (the rebased
# commits are never pushed to it, #221): a branch that moved since, or that never held
# this commit, carries work that has not landed (#143).
delete_feature_branch_if_at "$CALLER_DIR" "$FEATURE" "$FEATURE_SHA" || true
# The throwaway worktrees are removed by the EXIT trap. Any local $FEATURE branch ref
# in $CALLER_DIR is untouched by this script; the caller's own cleanup (or the next /fix
# run branching fresh from origin/<integration-branch>) handles it.

_close_or_park "$LANDED_SHA"
exit 0
