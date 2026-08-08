# Manager Handoff — Save State & Prepare for Context Reset

Snapshot manager session state to `MANAGER-STATE.md` in the project root, then guide the manager through a clean context reset. Run `/autocoder:manager-resume` in the fresh session to reload.

**Run this when the manager session is approaching context limits or needs a clean restart.**

## Usage

```bash
/autocoder:manager-handoff
```

## What This Does

1. Captures GitHub state (working issues, open PRs, blocked issues)
2. Captures worker topology (tmux/cmux panes → worktrees → branches)
3. Prompts for any session notes not yet filed as issues
4. Writes `MANAGER-STATE.md` to the project root
5. Commits the state file
6. Prints the resume command and context-reset instructions

## Instructions

### Step 1: Collect live state

Run all of these in parallel:

```bash
# Git state
git rev-parse --short HEAD
git rev-parse --short origin/main 2>/dev/null || echo "(no remote)"
git branch --show-current

# GitHub: working issues
gh issue list --state open --label "working" --json number,title \
  --jq '.[] | "#\(.number): \(.title)"'

# GitHub: open unblocked issues (no blocking labels, no working)
gh issue list --state open --json number,title,labels \
  --jq '[.[] | select(.labels | map(.name) | (
      contains(["needs-design"]) or contains(["needs-clarification"]) or
      contains(["future"]) or contains(["proposal"]) or
      contains(["needs-approval"]) or contains(["too-complex"]) or
      contains(["working"])) | not)]
    | sort_by(.labels | map(select(.name | test("^P[0-3]$"))) | .[0].name // "P9")
    | .[] | "#\(.number) [\(.labels | map(.name) | join(","))]: \(.title)"'

# GitHub: open PRs
gh pr list --state open --json number,title,mergeable,headRefName \
  --jq '.[] | "#\(.number) [\(.mergeable)]: \(.title) (\(.headRefName))"'

# GitHub: blocked issues (summary)
gh issue list --state open --json number,title,labels \
  --jq '[.[] | select(.labels | map(.name) | (
      contains(["needs-design"]) or contains(["needs-clarification"]) or
      contains(["future"]) or contains(["proposal"]) or
      contains(["needs-approval"]) or contains(["too-complex"])))]
    | .[] | "#\(.number) [\(.labels | map(.name) | join(","))]: \(.title)"'

# Worker topology (tmux)
tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} #{pane_current_path}' 2>/dev/null

# Worktree state
git worktree list --porcelain | grep -E "^worktree |^branch " | paste - -
```

For each worktree (excluding the main one), also collect:

```bash
for wt_dir in $(git worktree list --porcelain | grep "^worktree " | sed 's/^worktree //' | grep -v "$(pwd)$"); do
  name=$(basename "$wt_dir")
  branch=$(git -C "$wt_dir" branch --show-current 2>/dev/null)
  last_epoch=$(git -C "$wt_dir" log -1 --format=%ct 2>/dev/null)
  age_min=$(( ($(date +%s) - ${last_epoch:-0}) / 60 ))
  dirty=$(git -C "$wt_dir" status -s 2>/dev/null | wc -l | tr -d ' ')
  last_msg=$(git -C "$wt_dir" log --oneline -1 2>/dev/null)
  echo "$name | branch=$branch | dirty=$dirty | age=${age_min}min | $last_msg"
done
```

Read each worker's screen to determine idle vs. active:

```bash
# tmux — read pane matching each worktree path
tmux capture-pane -t <pane_id> -p | tail -5
```

Look for: `IDLE_NO_WORK_AVAILABLE`, bare `❯` prompt, `Brewed for Xm`.

### Step 2: Prompt for session notes

Ask the manager (using AskUserQuestion or plain text prompt):

> "Any pending decisions, design notes, or context from this session that isn't captured in GitHub issues? (These will be saved to MANAGER-STATE.md for the next session.)"

Accept free-form text. If the manager says "none" or similar, use empty string.

### Step 3: Write MANAGER-STATE.md

Write to `MANAGER-STATE.md` in the project root. Use this template — fill every section from the data collected above:

```markdown
# Manager State
_Saved: <ISO timestamp>_

## Session Notes
<manager's notes, or "(none)">

## Git State
- Working directory: <pwd>
- Branch: <current branch>
- HEAD: <short sha>
- origin/main: <short sha> (<"in sync" | "N commits ahead" | "N commits behind">)

## Worker Topology
| Worker | Path | Pane | Branch | Status | Issue |
|--------|------|------|--------|--------|-------|
| wt-1   | ~/src/<project>-wt-1 | <session>:0.0 | <branch> | idle/active | #N or — |
| wt-2   | ...  | ...  | ...    | ...    | ...   |
| wt-3   | ...  | ...  | ...    | ...    | ...   |

## Active Work (working label)
<list of #N: title, or "(none)">

## Open PRs
<list of #N [MERGEABLE/CONFLICTING]: title, or "(none)">

## Unblocked Issues (ready to assign)
<list or "(none)">

## Blocked Issues (needs-design / proposal / future / etc.)
<list — these need human decision before workers can pick them up>

## Known Holds / Flags
<anything the manager noted manually — e.g. "PR #980 held: wrong impl, wt-2 revising">

## Resume Command
Run `/autocoder:manager-resume` at the start of the next session.
```

### Step 4: Commit the state file

```bash
git add MANAGER-STATE.md
git commit -m "chore: save manager handoff state"
```

If the commit fails (nothing to stage, etc.), that's fine — continue.

### Step 5: Print resume instructions

Output exactly:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Manager state saved → MANAGER-STATE.md

To reset context:
  1. Type /clear  (clears conversation history, keeps this session)
     OR exit and relaunch Claude Code in this directory

To restore after reset:
  2. Run: /autocoder:manager-resume

Workers continue running in their tmux panes — no action needed.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

Stop here. Do not run `/clear` — the manager does that manually.

## Key Notes

- **Workers are unaffected** — they run in separate tmux panes and keep working through any manager restart
- **GitHub is the source of truth** — `working` labels, PRs, and issue state are always re-checked on resume
- **MANAGER-STATE.md is ephemeral context glue** — it captures what GitHub can't: worker-to-pane mapping, in-session decisions, known holds that aren't filed as issues
- **Commit is optional** — if the project has no open commit, the file is still written and readable; the commit just makes it visible in git log
