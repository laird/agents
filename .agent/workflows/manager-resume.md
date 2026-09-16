# Manager Resume — Restore Context After Reset

Load a fresh manager session with full situational awareness. Reads `MANAGER-STATE.md` (saved by `/manager-handoff`), then queries live GitHub state and worker screens to show the delta since the save.

**Run this at the start of a new manager session, after `/clear` or a fresh agent launch.**

## Usage

```bash
/manager-resume
/manager-resume --non-interactive
```

## Non-Interactive Mode

Treat this command as non-interactive when EITHER holds:

- it was invoked as `/manager-resume --non-interactive`, or
- `AUTOCODER_UNATTENDED=1` is set in the environment (the idle sentinel exports it into
  every manager it spawns — see `docs/specs/2026-09-16-idle-sentinel-design.md`).

In this mode there is no human to answer questions. Skip ALL AskUserQuestion steps and
apply the autonomous defaults instead:

- **Step 5 (stale working labels):** do not ask — post an explanatory comment on the
  issue, then release the label (exact commands in Step 5).
- **Step 6 (archive prompt):** do not ask, and NEVER archive `MANAGER-STATE.md`.
  Archival happens only when a successful step-down handoff replaces the file (CDR #12
  in the idle-sentinel spec): a crashed or killed manager must never destroy the state
  the next wake needs.

Everything else — state read, live queries, delta computation, the Step 4 report — is
unchanged; the resume brief lands in the session transcript.

## What This Does

1. Reads `MANAGER-STATE.md` from the project root
2. Queries live GitHub state (working issues, open PRs, unblocked issues)
3. Reads current worker screens
4. Shows delta: what completed, what changed, what new PRs appeared since the save
5. Emits a ready-to-act summary so the manager can pick up immediately

## Instructions

### Step 1: Read saved state

```bash
cat MANAGER-STATE.md 2>/dev/null || echo "NO_STATE_FILE"
```

If no file exists: print `No MANAGER-STATE.md found — starting fresh.` and skip to Step 2 (skip the delta comparison; treat everything as new).

Also check for a skill-written handoff from the previous session: if
`compound-engineering:ce-handoff` or `peters-toolkit:resume-handoff` is in your
available-skills list, invoke it now (`ce-handoff` resumes its own handoffs;
`resume-handoff` pairs with `create-handoff`). It restores the conversational context —
in-flight reasoning, half-formed plans — that `MANAGER-STATE.md`'s fixed template
doesn't carry. If the skill reports no handoff to resume, continue; `MANAGER-STATE.md`
plus live GitHub state is the complete picture.

Parse the saved file for:
- Save timestamp (to calculate staleness)
- Worker topology table (pane→worktree→branch→issue)
- Active work list (working issues at save time)
- Open PRs at save time
- Known holds / flags

Calculate how stale the state is:
```bash
# Parse the "Saved:" line from MANAGER-STATE.md
SAVED_TS=$(grep "^_Saved:" MANAGER-STATE.md | sed 's/_Saved: //' | tr -d '_')
echo "State age: saved at $SAVED_TS"
```

If the state is older than 4 hours, print a warning:
```
⚠️  State is >4 hours old — treat GitHub as authoritative, not the saved snapshot.
```

### Step 2: Collect live state

Run all of these in parallel:

```bash
# Git state
git fetch origin --quiet 2>/dev/null
git rev-parse --short HEAD
git rev-parse --short origin/main 2>/dev/null || echo "(no remote)"

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

# GitHub: open PRs (live)
gh pr list --state open --json number,title,mergeable,headRefName \
  --jq '.[] | "#\(.number) [\(.mergeable)]: \(.title) (\(.headRefName))"'

# Worktree state
git worktree list --porcelain | grep -E "^worktree |^branch " | paste - -
```

For each worktree (excluding main), collect branch/dirty/age:

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

Classify each known worker's pane from the saved topology:

```bash
worker-idle --all --json
```

This resolves pane IDs itself, so it also catches workers the saved topology
does not know about. A bare `❯` prompt is **not** idle — the TUI shows an empty
input box mid-turn too — so do not substitute a `capture-pane | tail` for this
check. Panes reported `SELF` are this manager session and are never workers.

### Step 3: Compute delta

Compare live state to saved state. Identify:

**Completed since save** — issues that had "working" at save time but no longer do, and have no open PR with that branch:
- Check each issue from the saved "Active Work" list against current "working" issues
- If no longer working + no open PR → likely merged/closed (check: `gh issue view N --json state`)

**New PRs** — PRs open now that weren't in the saved PR list:
- Compare current PR list to saved PR list by number

**New issues merged** — issues closed since save:
```bash
# Recent merges since saved timestamp
git log origin/main --oneline --after="<saved_timestamp>" 2>/dev/null | head -20
```

**Stale "working" labels** — issues still marked working but with no recent worktree activity (age > 60 min):
- For each current "working" issue, check the matching worktree's age_min
- Flag if age > 60 and pane shows idle

### Step 4: Report

Present a structured resume brief:

```markdown
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Manager Resume — <current timestamp>
State age: <N> minutes (saved <saved_ts>)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## Session Notes (from save)
<notes from MANAGER-STATE.md, or "(none)">

## Known Holds / Flags (from save)
<holds from MANAGER-STATE.md, or "(none)">

## Delta Since Save
<if no state file: "(fresh start — no prior state)">
<if nothing changed: "(no changes detected)">

Completed:
  - #N: <title> — closed/merged
  (or "(none)")

New PRs:
  - #N [MERGEABLE]: <title>
  (or "(none)")

New merges to origin/main:
  - <sha> <commit message>
  (or "(none)")

Stale "working" labels (>60min, no activity):
  - #N: <title> (wt-X idle for <M>min)
  (or "(none)")

## Current Status

Workers:
  | Worker | Pane | Branch | Age | Status | Issue |
  |--------|------|--------|-----|--------|-------|
  | wt-1   | ...  | ...    | ...  | idle/active | #N |
  ...

Active Work (working label, live):
  <list or "(none)">

Open PRs (live):
  <list or "(none)">

Unblocked Issues (ready to assign):
  <list or "(none)">

origin/main: <sha>

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Ready. Run /monitor-workers to dispatch work.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

### Step 5: Handle stale working labels

If any stale "working" labels were found (issue marked working but worker idle >60min), ask the manager:

> "Issue #N has the 'working' label but the worker appears idle for >60 minutes. Remove the 'working' label so it can be reassigned?"

```bash
gh issue edit <number> --remove-label "working"
```

This is the same check monitor-workers does, but doing it at resume time avoids silent lock-outs.

**Non-interactive mode:** skip the question and auto-release, leaving an explanatory
comment on the issue first so the release is durable and attributable:

```bash
gh issue comment <number> --body "Releasing stale 'working' label: no worker activity for >60 minutes at manager resume (auto-released — unattended session)."
gh issue edit <number> --remove-label "working"
```

### Step 6: Clean up state file (optional)

After the manager confirms the resume is complete, offer:

> "Archive MANAGER-STATE.md? (It's been loaded — archiving avoids confusion if you run /manager-handoff again this session.)"

If yes:
```bash
git mv MANAGER-STATE.md MANAGER-STATE.archived.md 2>/dev/null || \
  mv MANAGER-STATE.md MANAGER-STATE.archived.md
```

If no, leave it as-is.

**Non-interactive mode:** skip this step entirely. NEVER archive `MANAGER-STATE.md` in
an unattended session — archival happens only when a successful step-down handoff
(`/manager-handoff`) replaces the file (CDR #12). The idle sentinel's standing
conditions also live in this file; archiving it out from under the sentinel would erase
them mid-flight.

## Key Behaviors

- **Always re-query GitHub** — saved state is a hint, not the truth; GitHub is authoritative
- **Delta is the primary value** — the manager needs to know what changed, not just current state
- **Stale lock detection** — catches issues that were "working" but the worker crashed/quit
- **No-state-file graceful** — if there's no MANAGER-STATE.md, just report live state as a fresh start
- **Non-destructive** — never removes labels or closes issues without asking; non-interactive
  mode substitutes the documented autonomous default and leaves an explanatory comment
  instead of acting silently

## Relationship to Other Commands

- Run after `/manager-handoff` + `/clear` or session restart
- After resume, the manager's typical next step is `/monitor-workers`
- If all issues are blocked, `/review-blocked` surfaces them for human decision
- A sentinel-woken manager runs `/manager-resume --non-interactive` first, then
  starts `/monitor-loop` (the sentinel sequences both in its spawn prompt)
