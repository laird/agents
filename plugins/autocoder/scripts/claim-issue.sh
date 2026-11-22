#!/usr/bin/env bash
# claim-issue.sh — /fix's claim, selection and branch setup (#289, step 2 of #242).
#
# Picks the issue /fix works next, locks it, puts the worktree on its
# feature/issue-<N> branch and posts the work-started comment. This was inline
# bash in commands/fix.md; it moved here unchanged so the protocol stays short
# and the claim path can be tested.
#
# Usage:
#   claim-issue.sh --out FILE [--base integration|parent] [ISSUE_NUMBER]
#
#   ISSUE_NUMBER  work this issue ("/fix 350"); empty or absent = pick the
#                 highest-priority claimable issue.
#   --out FILE    where to write the hand-back variables (required).
#   --base        integration (default): branch from origin/$INTEGRATION_BRANCH.
#                 parent: pull the current branch from origin and branch from it
#                 (the Antigravity local-merge flow; sets PARENT_BRANCH).
#
# Environment in: INTEGRATION_BRANCH (falls back to origin/HEAD, then main),
#   AUTOCODER_IGNORE_DEPENDENCIES=1 to start an issue whose dependencies are open.
#   The issue backend comes from .autocoder.json via issue-fns.sh.
#
# Hand-back: FILE is a bash fragment of `NAME=value` lines quoted with
# printf %q, so titles and bodies with quotes or newlines survive. The caller
# runs `source FILE`. Written on every exit. Variables:
#   CLAIM_STATUS      claimed | idle | refused | conflict
#   ISSUE_NUM ISSUE_TITLE ISSUE_BODY ISSUE_PRIORITY
#   RESUMING          true when this worktree resumed its own claim (#182)
#   FIX_BRANCH        feature/issue-<N>
#   INTEGRATION_BRANCH  the resolved integration branch
#   PARENT_BRANCH     the branch the work started from (--base parent only)
#
# Exit codes (and stdout messages) are the ones the inline block had:
#   0  claimed: on FIX_BRANCH, `working` held, start comment posted
#   0  idle: nothing claimable; prints IDLE_NO_WORK_AVAILABLE (CLAIM_STATUS=idle)
#   1  refused or failed: not found, dependencies open, another agent's lock,
#      lost race, fetch/branch failure. Any claim this run took is released.
#   2  resumed claim whose rebase onto the integration branch conflicts: the
#      worktree is mid-rebase on FIX_BRANCH, `working` is kept; resolve and go on.

OUT=""
BASE_MODE="integration"
SPECIFIED_ISSUE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --out|--base)
      [ $# -ge 2 ] || { echo "claim-issue.sh: $1 needs a value" >&2; exit 1; }
      if [ "$1" = --out ]; then OUT="$2"; else BASE_MODE="$2"; fi
      shift 2 ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    -*) echo "claim-issue.sh: unknown option $1" >&2; exit 1 ;;
    *) SPECIFIED_ISSUE="$1"; shift ;;
  esac
done
if [ -z "$OUT" ]; then
  echo "claim-issue.sh: --out FILE is required" >&2
  exit 1
fi
case "$BASE_MODE" in integration|parent) ;; *)
  echo "claim-issue.sh: --base must be integration or parent" >&2; exit 1 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=issue-fns.sh
source "${SCRIPT_DIR}/issue-fns.sh"

CLAIM_STATUS="refused"
ISSUE_NUM="" ISSUE_TITLE="" ISSUE_BODY="" ISSUE_PRIORITY="" RESUMING=false FIX_BRANCH="" PARENT_BRANCH=""
WORK=$(mktemp -d "${TMPDIR:-/tmp}/claim-issue.XXXXXX") || { echo "claim-issue.sh: cannot create a temp dir" >&2; exit 1; }
write_handback() {
  local rc=$? v
  {
    for v in CLAIM_STATUS ISSUE_NUM ISSUE_TITLE ISSUE_BODY ISSUE_PRIORITY RESUMING FIX_BRANCH INTEGRATION_BRANCH PARENT_BRANCH; do
      printf '%s=%q\n' "$v" "${!v}"
    done
  } > "$OUT"
  rm -rf "$WORK"
  exit "$rc"
}
trap write_handback EXIT

# Race check for the GitHub backend (#309). Counts only the claim evidence after the
# last release or block, anchored on this run's own marker (claim-window.sh), so a
# start comment or marker left by an abandoned run cannot refuse the issue forever.
# Sets CLAIM_MARKER_COUNT and PRIOR_STARTED.
CLAIM_ID="claim-id=$$-$(date +%s%N)"
post_claim_marker() {
  issue_comment "$1" --body "🔒 [autocoder-claim] Starting fix for issue #${1} — lock established (${CLAIM_ID})" 2>/dev/null || true
}
count_claim_window() {
  local counts
  counts=$(issue_get "$1" 2>/dev/null | "${SCRIPT_DIR}/claim-window.sh" --own "$CLAIM_ID")
  read -r CLAIM_MARKER_COUNT PRIOR_STARTED <<< "${counts:-0 0}"
}

if [ -n "$SPECIFIED_ISSUE" ]; then
  # Specific issue provided - fetch it directly
  echo "🎯 Targeting specific issue #$SPECIFIED_ISSUE"
  issue_get "$SPECIFIED_ISSUE" > "$WORK/top-issue.json" 2>/dev/null

  if [ $? -ne 0 ] || [ ! -s "$WORK/top-issue.json" ]; then
    echo "❌ Error: Issue #$SPECIFIED_ISSUE not found or not accessible"
    exit 1
  fi

  ISSUE_NUM=$(jq -r '.number' "$WORK/top-issue.json")
  ISSUE_TITLE=$(jq -r '.title' "$WORK/top-issue.json")
  ISSUE_BODY=$(jq -r '.body // ""' "$WORK/top-issue.json")

  # Dependencies first: an issue whose "Depends on" / "Blocked by" issues (or
  # GitHub's native blocked-by) are still open is not ready, even when named
  # explicitly. Refuse before claiming, so no `working` label is left behind.
  # AUTOCODER_IGNORE_DEPENDENCIES=1 overrides it on purpose.
  if UNMET_DEPS=$(issue_unmet_dependencies "$ISSUE_NUM"); then :; else
    echo "⏳ Issue #$ISSUE_NUM waits on $UNMET_DEPS, still open. Not starting it."
    echo "   Work those first, or set AUTOCODER_IGNORE_DEPENDENCIES=1 to override."
    exit 1
  fi

  # #182: this worktree's own claim, resumed after compaction or a restart. The gate
  # resumes only an issue it recorded for this worktree, still `working` and still
  # ours, and switches to its branch first (or finds none locally or on origin: compacted
  # before the branch was made). Its pushed branch, start comment and claim marker are then ours,
  # so none of the lock checks below may read them as a rival's.
  RESUMING=false
  if { [ "$(git branch --show-current 2>/dev/null)" = "feature/issue-${ISSUE_NUM}" ] || \
       { ! git show-ref --verify -q "refs/heads/feature/issue-${ISSUE_NUM}" && \
         [ -z "$(git ls-remote --heads origin "feature/issue-${ISSUE_NUM}" 2>/dev/null)" ]; }; } && \
     [ "$(cut -d' ' -f1 "$(git rev-parse --absolute-git-dir 2>/dev/null)/autocoder-worker-state" 2>/dev/null)" = "$ISSUE_NUM" ] && \
     jq -e '[.labels[]?.name] | index("working") != null' "$WORK/top-issue.json" >/dev/null 2>&1; then
    RESUMING=true
    echo "🔁 Resuming this worktree's own claim on #$ISSUE_NUM. Re-read the issue's comments and the branch (git log origin/<integration>..HEAD) before continuing; do not redo finished work."
  fi

  # Remote branch is the strongest lock — check it before the working label.
  # A peer may have pushed the branch before the label propagated, or a manager
  # may have cleared a stale label without realising work was still in flight.
  REMOTE_BRANCH_SPEC=$(git ls-remote --heads origin "feature/issue-${ISSUE_NUM}" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$RESUMING" != "true" ] && [ "$REMOTE_BRANCH_SPEC" -gt "0" ]; then
    echo "⚠️  Remote branch feature/issue-${ISSUE_NUM} already exists — another agent owns this issue."
    echo "    To take over an abandoned branch, delete it from origin first."
    exit 1
  fi

  # Check if issue already has 'working' label (being worked on by another agent)
  IS_WORKING=$(jq -r '.labels | map(.name) | any(. == "working")' "$WORK/top-issue.json")
  if [ "$IS_WORKING" = "true" ]; then
    TARGET_BRANCH="feature/issue-${ISSUE_NUM}"
    CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "")
    # Only start markers since the last release or block count (#309): an abandoned
    # run's start comment, ended by a 🔓 or a 🚫/🎨 block, is not a live lock.
    START_MARKERS=$(issue_get "$ISSUE_NUM" 2>/dev/null | "${SCRIPT_DIR}/claim-window.sh" --branch "$TARGET_BRANCH" | cut -d' ' -f2)
    START_MARKERS="${START_MARKERS:-0}"
    if [ "$RESUMING" != "true" ] && [ "$START_MARKERS" -gt 0 ] && [ "$CURRENT_BRANCH" != "$TARGET_BRANCH" ]; then
      echo "⚠️  Issue #$SPECIFIED_ISSUE already has a start marker on $TARGET_BRANCH - another agent is working on it"
      echo "Use '/update-issue $SPECIFIED_ISSUE --remove-label working' only after confirming the lock is stale"
      exit 1
    fi
    echo "ℹ️  Issue #$SPECIFIED_ISSUE already has 'working' label; treating it as a pre-claimed handoff"
  else
    issue_claim "$ISSUE_NUM" 2>/dev/null || {
      echo "⚠️  Could not claim issue #$ISSUE_NUM - another agent may have claimed it first"
      exit 1
    }
  fi

  # Extract priority from labels (default to P2 if no priority label)
  ISSUE_PRIORITY=$(jq -r '
    if (.labels | map(.name) | any(. == "P0")) then 0
    elif (.labels | map(.name) | any(. == "P1")) then 1
    elif (.labels | map(.name) | any(. == "P2")) then 2
    elif (.labels | map(.name) | any(. == "P3")) then 3
    else 2
    end
  ' "$WORK/top-issue.json")

  echo "✅ Found issue #$ISSUE_NUM: $ISSUE_TITLE"

  # Claim-then-verify: the claim above (issue_claim or pre-claimed handoff check) is the
  # primary lock. For GitHub backend (non-atomic), post an early marker comment and wait
  # for competing workers to surface before proceeding. A resumed own claim (#182) has
  # no race to settle: its earlier start comment is its own.
  if [ "$RESUMING" = "true" ]; then
    :
  elif [ "${ISSUE_SOURCE:-}" = "github" ]; then
    post_claim_marker "$ISSUE_NUM"
    sleep 3
    count_claim_window "$ISSUE_NUM"
    if [ "$CLAIM_MARKER_COUNT" -gt 1 ] || [ "$PRIOR_STARTED" -gt 0 ]; then
      echo "⚠️  Race: another agent claimed issue #$ISSUE_NUM (markers: $CLAIM_MARKER_COUNT, started: $PRIOR_STARTED since the last release). Releasing and aborting."
      issue_update "$ISSUE_NUM" --remove-label "working" 2>/dev/null || true
      exit 1
    fi
  else
    # File backend: check for orphaned start comments from prior abandoned runs.
    sleep 1
    PRIOR_STARTED=$(issue_get "$ISSUE_NUM" 2>/dev/null | jq \
      '[.comments[] | select(.body | test("Automated Fix Started|Implementation Started|Enhancement Implementation Started"))] | length' \
      2>/dev/null || echo "0")
    if [ "$PRIOR_STARTED" -gt 0 ]; then
      echo "⚠️  Issue #$ISSUE_NUM has a prior work-started comment — may be an abandoned run. Releasing and aborting."
      issue_release "$ISSUE_NUM" 2>/dev/null || issue_update "$ISSUE_NUM" --remove-label "working" 2>/dev/null || true
      exit 1
    fi
  fi
else
  # No specific issue - get highest priority issue (using labels only)
  issue_list --state open --limit 100 > "$WORK/all-issues.json"

  # Branch-evidence exclusion (#48): a pushed branch is a claim that survives a lost label.
  CLAIMED_BY_BRANCH=$("${SCRIPT_DIR}/claimed-issue-numbers.sh" origin)
  [ -n "$CLAIMED_BY_BRANCH" ] || CLAIMED_BY_BRANCH="[]"
  echo "ℹ️  Issues with a live remote branch (excluded from claiming): $CLAIMED_BY_BRANCH"

  # Ranked list of every candidate (retried in order on a race conflict).
  # issue_list --state open has already left out issues whose dependencies
  # ("Depends on: #N" lines, GitHub blocked-by) are not closed (issue-deps.sh).
  # Filter out issues with 'working' label (being worked on by another agent)
  # Also filter out issues with blocking labels (needs human review)
  # Also filter out decomposed parent issues (work on their sub-tasks instead)
  jq -r --argjson claimed "$CLAIMED_BY_BRANCH" '
    [.[] |
    select(
      (.labels | map(.name) | any(. == "P0" or . == "P1" or . == "P2" or . == "P3"))
      and (.labels | map(.name) | any(. == "working") | not)
      and (.labels | map(.name) | any(. == "needs-approval" or . == "needs-design" or . == "needs-clarification" or . == "too-complex" or . == "future" or . == "decomposed" or . == "awaiting-integration" or . == "merging") | not)
      and ((.number | IN($claimed[])) | not)
    ) |
    {
      number: .number,
      title: .title,
      body: (.body // ""),
      priority: (
        if (.labels | map(.name) | any(. == "P0")) then 0
        elif (.labels | map(.name) | any(. == "P1")) then 1
        elif (.labels | map(.name) | any(. == "P2")) then 2
        elif (.labels | map(.name) | any(. == "P3")) then 3
        else 4
        end
      )
    }] | sort_by(.priority)
  ' "$WORK/all-issues.json" > "$WORK/candidate-issues.json"

  CANDIDATE_COUNT=$(jq 'length' "$WORK/candidate-issues.json" 2>/dev/null || echo 0)

  # Try each candidate issue in priority order until we successfully claim one
  ISSUE_CLAIMED=false
  for idx in $(seq 0 $((CANDIDATE_COUNT - 1))); do
    ISSUE_NUM=$(jq -r ".[$idx].number" "$WORK/candidate-issues.json")
    ISSUE_TITLE=$(jq -r ".[$idx].title" "$WORK/candidate-issues.json")
    ISSUE_BODY=$(jq -r ".[$idx].body" "$WORK/candidate-issues.json")
    ISSUE_PRIORITY=$(jq -r ".[$idx].priority" "$WORK/candidate-issues.json")

    if [ "$ISSUE_NUM" = "null" ] || [ -z "$ISSUE_NUM" ]; then
      continue
    fi

    # Remote branch is a stronger lock than the working label: a worker may have pushed
    # the branch before the label propagated, or the label may have been cleaned by a
    # manager who thought the issue was stale. Skip immediately if the branch exists.
    REMOTE_BRANCH_EXISTS=$(git ls-remote --heads origin "feature/issue-${ISSUE_NUM}" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$REMOTE_BRANCH_EXISTS" -gt "0" ]; then
      echo "⚠️  Remote branch feature/issue-${ISSUE_NUM} already exists — skipping issue #$ISSUE_NUM"
      continue
    fi

    # Claim-then-verify: claim IMMEDIATELY, then check for race
    issue_claim "$ISSUE_NUM" 2>/dev/null
    claim_rc=$?
    if [ "$claim_rc" -ne 0 ]; then
      echo "⚠️  Lost claim race on issue #$ISSUE_NUM (file backend: atomic rename lost). Trying next issue..."
      continue
    fi

    # For file backend: the atomic rename above is the definitive lock — skip the
    # extended race check. For GitHub backend (non-atomic label add), post an early
    # marker comment NOW so concurrent workers can detect the collision within the
    # settlement window, then sleep long enough for their markers to appear.
    if [ "${ISSUE_SOURCE:-}" = "github" ]; then
      post_claim_marker "$ISSUE_NUM"
      sleep 3

      # Count autocoder-claim markers and work-started comments since the last
      # release (#309). A second marker means two workers raced: both back off and
      # the issue is claimed cleanly next tick. A start comment means a live claim.
      count_claim_window "$ISSUE_NUM"

      if [ "$CLAIM_MARKER_COUNT" -gt 1 ] || [ "$PRIOR_STARTED" -gt 0 ]; then
        echo "⚠️  Race condition on issue #$ISSUE_NUM (markers: $CLAIM_MARKER_COUNT, prior: $PRIOR_STARTED since the last release). Releasing and trying next..."
        issue_update "$ISSUE_NUM" --remove-label "working" 2>/dev/null || true
        continue
      fi
    else
      # File backend: brief pause to detect orphaned start comments from prior abandoned runs.
      sleep 1
      PRIOR_STARTED=$(issue_get "$ISSUE_NUM" 2>/dev/null | jq \
        '[.comments[] | select(.body | test("Automated Fix Started|Implementation Started|Enhancement Implementation Started"))] | length' \
        2>/dev/null || echo "0")
      if [ "$PRIOR_STARTED" -gt 0 ]; then
        echo "⚠️  Issue #$ISSUE_NUM has a prior work-started comment — may be an abandoned run. Releasing and trying next..."
        # File backend: release moves the file back from working/ to open/
        issue_release "$ISSUE_NUM" 2>/dev/null || issue_update "$ISSUE_NUM" --remove-label "working" 2>/dev/null || true
        continue
      fi
    fi

    ISSUE_CLAIMED=true
    break
  done

  if [ "$ISSUE_CLAIMED" != "true" ]; then
    ISSUE_NUM="" ISSUE_TITLE="" ISSUE_BODY="" ISSUE_PRIORITY=""
    echo "ℹ️  No available priority issues found"
    echo "   All issues may be: claimed by other agents, or blocked (needs human review)"
    echo "   Use '/review-blocked' to review and approve blocked issues"

    echo "IDLE_NO_WORK_AVAILABLE"
    CLAIM_STATUS="idle"
    exit 0
  fi
fi

# ── Branch setup ─────────────────────────────────────────────────────────────
# Never start work on the parent branch: a 'working' label with no matching
# feature/issue-N branch looks like a stale/abandoned lock to peers and to
# /monitor-workers, which then try to reclaim the issue out from under you.
FIX_BRANCH="feature/issue-${ISSUE_NUM}"
INTEGRATION_BRANCH="${INTEGRATION_BRANCH:-$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')}"
INTEGRATION_BRANCH="${INTEGRATION_BRANCH:-main}"
if [ "$BASE_MODE" = "parent" ]; then
  # Local-merge flow: branch from the branch this worktree is on, pulled first,
  # and record it — the landing section merges back into PARENT_BRANCH.
  PARENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
  git pull origin "$PARENT_BRANCH" || {
    echo "❌ Cannot pull from origin/${PARENT_BRANCH} — refusing to start work from stale state."
    issue_update "$ISSUE_NUM" --remove-label "working" 2>/dev/null || true
    exit 1
  }
  BASE_REF="$PARENT_BRANCH"; BASE_DESC="$PARENT_BRANCH"; REBASE_ONTO="$PARENT_BRANCH"
else
  # Branch from the latest shared integration branch (NOT the worktree's current branch).
  # In a parallel-worktree swarm each worktree sits on its own main-wt-N; basing the fix
  # branch on origin/<integration> instead means every fix starts from — and merges back
  # to — the same shared branch, so work converges on main instead of stranding on main-wt-N.
  git fetch origin "$INTEGRATION_BRANCH" || {
    echo "❌ Cannot fetch origin/${INTEGRATION_BRANCH} — refusing to start work from stale state."
    issue_update "$ISSUE_NUM" --remove-label "working" 2>/dev/null || true
    exit 1
  }
  BASE_REF="origin/${INTEGRATION_BRANCH}"; BASE_DESC="origin/${INTEGRATION_BRANCH}"; REBASE_ONTO="$INTEGRATION_BRANCH"
fi

# Create (or switch to) the fix branch, then pull the latest base into it.
if git checkout -b "$FIX_BRANCH" "$BASE_REF" 2>/dev/null; then
  echo "✅ Created $FIX_BRANCH from ${BASE_DESC}"
elif git checkout "$FIX_BRANCH" 2>/dev/null; then
  # Branch already exists — pull latest integration changes into it before resuming
  echo "ℹ️  Branch $FIX_BRANCH already exists; pulling latest from origin/${REBASE_ONTO}..."
  git pull --rebase origin "$REBASE_ONTO" || {
    if [ "${RESUMING:-false}" = "true" ]; then
      # A resumed claim keeps its lock through a conflict. After a merge job bounced
      # it back (#207/#208) the conflict IS the work: resolve it here, keeping both
      # sides' behaviour, `git rebase --continue`, re-run the tests, and carry on to
      # the review gate and relaunch. Releasing would strand the live branch.
      echo "⚠️  Rebase of $FIX_BRANCH conflicts (resumed claim #${ISSUE_NUM}). Conflicting files:"
      git diff --name-only --diff-filter=U
      echo "   Resolve them keeping both sides' behaviour, run 'git rebase --continue', then continue this issue. Keeping 'working'."
      CLAIM_STATUS="conflict"
      exit 2
    fi
    echo "❌ Rebase of $FIX_BRANCH onto origin/${REBASE_ONTO} failed — resolve conflicts manually."
    issue_update "$ISSUE_NUM" --remove-label "working" 2>/dev/null || true
    exit 1
  }
else
  echo "❌ Could not create or switch to $FIX_BRANCH."
  issue_update "$ISSUE_NUM" --remove-label "working" 2>/dev/null || true
  exit 1
fi
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ "$CURRENT_BRANCH" != "$FIX_BRANCH" ]; then
  echo "❌ Branch switch verification failed (still on $CURRENT_BRANCH)."
  issue_update "$ISSUE_NUM" --remove-label "working" 2>/dev/null || true
  exit 1
fi

# 'working' label was already added during claim-then-verify above

# Post the work-started comment. Together with the branch above, this is the durable
# proof the lock is live — peers and /monitor-workers key off the branch + this comment
# to tell an active lock apart from a stale one. Do not skip it for any issue type.
issue_comment "$ISSUE_NUM" --body "🤖 **Automated Fix Started**

Starting automated fix for this issue.

**Branch**: \`feature/issue-${ISSUE_NUM}\`
**Implementation Started**: $(date)

Fix in progress..." 2>/dev/null || true

echo "✅ Created branch: feature/issue-${ISSUE_NUM}"
echo "✅ Added 'working' label (concurrency lock)"
echo "✅ Posted GitHub comment"
echo ""
# The claim is recorded for this worktree the way the fix-loop gate records its own
# (worker-state-fns.sh), so a fix loop started later in this worktree, after a `/clear`,
# a restart or a reboot, resumes this issue instead of claiming over it and stranding
# the branch. A record the gate already wrote for this issue (its claim time settles
# races) is kept as it is.
if [ -f "${SCRIPT_DIR}/worker-state-fns.sh" ]; then
  # shellcheck source=worker-state-fns.sh
  source "${SCRIPT_DIR}/worker-state-fns.sh"
  if ! { _f=$(worker_state_file 2>/dev/null) && [ -f "$_f" ] && [ "$(cut -d' ' -f1 "$_f")" = "$ISSUE_NUM" ]; }; then
    worker_state_set "$ISSUE_NUM" "" "$(_worker_session_id)"
  fi
fi
CLAIM_STATUS="claimed"
exit 0
