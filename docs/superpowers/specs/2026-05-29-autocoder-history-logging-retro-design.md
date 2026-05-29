# Autocoder History Logging + Retro Command Design

**Date**: 2026-05-29  
**Status**: Approved  
**Scope**: History logging across autocoder (and shared with modernize), issue-source enforcement, and new `/retro` command

---

## Verified Assumptions

- `fix.md` and `fix-loop.md` already source `issue-fns.sh`; `full-regression-test.md` does not.
- `gh issue create --label <name>` fails if the label does not pre-exist on the repo.
- `fix-loop.md` dispatches parallel agents in isolated git worktrees; each worktree is a separate directory on disk.
- `git worktree list --porcelain` reliably identifies the main worktree path from any worktree.
- `gh issue comment` is atomic server-side; parallel agents can post to the same issue without conflict.

---

## Problem Statement

Autocoder agents run autonomously and accumulate experience — fixed issues, blocked patterns, test failures, user corrections — but none of this is recorded. There is no way to review what happened and improve the agents' behavior over time. The `/retro` command in modernize solves this for migration projects; autocoder needs the same capability.

Two prerequisites must be in place before a useful retro is possible:
1. **Issue source must be configured** before any autonomous command runs
2. **History must be recorded** as work happens, so the retro has data to analyze

---

## Part 1: Shared `append-to-history.sh`

### Current state

`scripts/append-to-history.sh` is a simple 4-argument script that appends to `docs/HISTORY.md`. It is used by modernize (creates it in the target project via `protocols-overview.md`). It does not know about backends.

### Extended interface

```bash
append-to-history.sh [--backend file|github|auto] [--history-file PATH] TITLE WHAT WHY IMPACT
```

**Flags:**
- `--backend auto` (default) — reads `$ISSUE_SOURCE` env var; falls back to `file`
- `--backend file` — always write to history file
- `--backend github` — always post to GitHub history-log issue
- `--history-file PATH` — override default path (default: `docs/HISTORY.md`, preserved for modernize compat)

**GitHub backend behavior:**
1. Ensures the `history-log` label exists: `gh label create history-log --description "Autocoder history log" --color "0075ca" 2>/dev/null || true`
2. Looks for an open issue labeled `history-log`: `gh issue list --label history-log --state open --limit 1`
3. If none exists, creates one: `gh issue create --label history-log --title "Autocoder History Log" --body "Auto-created by autocoder to track agent activity. Each comment is one history entry."`
4. Posts a comment with the structured entry

**Backward compat:** calling the script with no flags behaves exactly as today — writes to `docs/HISTORY.md`.

### Distribution

One canonical file, copied to three locations (kept in sync manually or via a future sync script):

| Location | Used by |
|---|---|
| `scripts/append-to-history.sh` | Canonical source |
| `plugins/autocoder/scripts/append-to-history.sh` | Autocoder commands (via `SCRIPT_DIR`) |
| `plugins/modernize/scripts/append-to-history.sh` | Modernize plugin copy |
| `.agent/scripts/append-to-history.sh` | Antigravity mirror |

**Modernize deployment:** `protocols-overview.md` continues to create `./scripts/append-to-history.sh` in target projects via its existing inline heredoc — no runtime change. `plugins/modernize/scripts/append-to-history.sh` serves as the maintainer's canonical source; the heredoc in `protocols-overview.md` must be kept in sync with it manually whenever the script changes. A sync reminder comment is added to both files.

---

## Part 2: Issue Source Enforcement

### Current state

`issue-config.sh` already exits with a clear error in non-interactive mode when no source is configured. The gap: some autocoder commands don't source `issue-fns.sh` early enough.

### Fix

Every major autocoder command that interacts with issues must include the standard source block **as its first action**, before any other work:

```bash
SCRIPT_DIR=$(
  if [ -d "$(pwd)/plugins/autocoder/scripts" ]; then echo "$(pwd)/plugins/autocoder/scripts"
  elif [ -d "$(pwd)/.claude-plugin/plugins/autocoder/scripts" ]; then echo "$(pwd)/.claude-plugin/plugins/autocoder/scripts"
  else find "$HOME/.claude/plugins/cache" -type d -name "scripts" -path "*/autocoder/*" 2>/dev/null | sort -V | tail -1
  fi
)
source "${SCRIPT_DIR}/issue-fns.sh"
# ISSUE_SOURCE is now exported (or script has exited with a clear error)
```

Commands that need this added (currently missing it):
- `full-regression-test.md`
- `retro.md` (new)
- Any other command that creates/reads issues

`fix.md` and `fix-loop.md` already source `issue-fns.sh`; no change needed there.

---

## Part 3: Logging in `fix.md`

### Logging call signature for autocoder

```bash
"${SCRIPT_DIR}/append-to-history.sh" \
  --history-file "HISTORY.md" \
  --backend auto \
  "TITLE" "WHAT" "WHY" "IMPACT"
```

### Events and their entries

| Event | TITLE | WHAT | WHY | IMPACT |
|---|---|---|---|---|
| Issue fixed + merged | `Fix #N: <title>` | `Resolved on branch feature/issue-N. Approach: <1-line summary>` | `Issue: <first 100 chars of body>` | `Tests: X passing. Merged to <branch>` |
| Issue fixed + PR | `PR #N: <title>` | `PR created on branch feature/issue-N. Approach: <1-line summary>` | `Issue: <first 100 chars of body>` | `Awaiting review` |
| Issue blocked | `Blocked #N: <title>` | `Added label: <blocking-label>` | `<blocking reason, first 200 chars>` | `Requires human review before proceeding` |
| Issue skipped | `Skipped #N: <title>` | `Skipped: <reason>` | `Not actionable autonomously` | `Moving to next issue` |

These calls are inserted at the **end** of each resolution path, just before moving to the next issue — after the `issue_update --remove-label "working"` call.

### History collection in git worktrees (`fix-loop`)

`fix-loop.md` runs each issue fix in an isolated git worktree. Each worker writes to its own `HISTORY.md` (relative path resolves to that worktree's root). Before the worktree is cleaned up — immediately after the branch merge or PR creation and before `git branch -d` — the worker appends its `HISTORY.md` to the main worktree's `HISTORY.md`:

```bash
MAIN_WT=$(git worktree list --porcelain | grep -m1 '^worktree' | cut -d' ' -f2)
if [ -f "HISTORY.md" ] && [ "$(pwd)" != "$MAIN_WT" ]; then
  cat HISTORY.md >> "${MAIN_WT}/HISTORY.md"
fi
```

By the time each fix-loop iteration completes, all worker history is consolidated in the main worktree's `HISTORY.md`. The retro always reads from one place.

For the GitHub backend, no merge step is needed — `gh issue comment` is atomic server-side and parallel agents can post to the same `history-log` issue concurrently without conflict.

### Logging in `full-regression-test.md`

One entry after the test run completes:

```bash
"${SCRIPT_DIR}/append-to-history.sh" \
  --history-file "HISTORY.md" \
  --backend auto \
  "Regression Test Run" \
  "Build: <pass/fail>. Unit tests: <X>/<Y> passing. E2E: <X>/<Y> passing. New issues created: <N>" \
  "Scheduled regression run" \
  "<N> new issues opened for failures"
```

---

## Part 4: `/retro` Command

### Purpose

Analyze accumulated history to produce 3–5 specific, evidence-backed recommendations for improving the autocoder workflow. Output: `IMPROVEMENTS.md` in ADR format.

### Data sources analyzed

1. **History log** — `HISTORY.md` (file backend) or `history-log` issue comments (GitHub backend). Primary source of what happened.
2. **Git log** — User corrections (commits with "fix", "actually", "revert", "correction" in message), reverted commits, multiple fix attempts on same branch.
3. **Issue tracker patterns** — Blocked issues by label type (needs-design / too-complex / needs-clarification), reopened issues, proposal approval rates.
4. **Test failure patterns** — Recurring failures across multiple regression runs, tests that were fixed then broke again.

### Analysis phases

**Phase 1: History collection** (~15 min)
- Read HISTORY.md or history-log issue
- Run git log analysis
- Query issue tracker for blocking/reopened patterns
- Extract test failure patterns from regression run entries

**Phase 2: Pattern identification** (~10 min)
- Cluster findings by type: agent behavior, protocol gaps, automation opportunities, recurring failures
- Score each pattern: frequency × impact

**Phase 3: Recommendation development** (~15 min)
- Select top 3–5 patterns
- Develop specific, actionable recommendations using the modernize retro template
- Each recommendation: Problem, Evidence, Proposed Change, Expected Impact, Affected Components

**Phase 4: IMPROVEMENTS.md generation** (~5 min)
- Write in ADR format (same structure as modernize retro output)
- Include summary table with priority and estimated savings

### Recommendation targets

Unlike modernize retro (which targets migration protocols), autocoder retro recommendations target:
- `plugins/autocoder/commands/fix.md` — blocking detection, fix strategy, logging
- `plugins/autocoder/commands/full-regression-test.md` — test analysis, issue creation
- Agent behavior patterns — what agents should do differently
- New scripts or automation to add to `plugins/autocoder/scripts/`

### Usage

```
/retro
```

Optional: `/retro --since 2026-01-01` to scope analysis to a date range (reads from git log `--after`).

---

## Files Changed

### New files
- `plugins/autocoder/commands/retro.md`
- `plugins/autocoder/scripts/append-to-history.sh` (copy of extended shared script)
- `plugins/modernize/scripts/append-to-history.sh` (copy of extended shared script)
- `.agent/workflows/retro.md` (mirror)

### Modified files
- `scripts/append-to-history.sh` — add `--backend` and `--history-file` flags
- `.agent/scripts/append-to-history.sh` — mirror
- `plugins/autocoder/commands/fix.md` — add logging at each resolution point
- `plugins/autocoder/commands/full-regression-test.md` — add issue-source enforcement + logging
- `plugins/modernize/protocols/protocols-overview.md` — reference `scripts/append-to-history.sh` from plugin instead of creating inline
- `.agent/workflows/fix.md` — mirror
- `.agent/workflows/full-regression-test.md` — mirror
- `.claude-plugin/marketplace.json` — register new `/retro` command, bump versions
- `CLAUDE.md` — document new `/retro` command

---

## Out of scope

- `/retro-apply` for autocoder (can be added later; initial retro just produces IMPROVEMENTS.md for human review)
- Automated application of improvements
- History for commands other than `fix` and `full-regression-test` (can extend later)
