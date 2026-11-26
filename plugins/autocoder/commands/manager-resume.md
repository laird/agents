# Manager Resume — Restore Context After Reset

Load a fresh manager session with full situational awareness. Reads `MANAGER-STATE.md` (saved by `/autocoder:manager-handoff`), then queries live GitHub state and worker screens to show the delta since the save.

**Run this at the start of a new manager session, after `/clear` or a fresh Claude Code launch.**

## Usage

```bash
/autocoder:manager-resume
/autocoder:manager-resume --non-interactive
```

## Non-Interactive Mode

Treat this command as non-interactive when EITHER holds:

- it was invoked as `/autocoder:manager-resume --non-interactive`, or
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

### Step 0: Register as the manager

Record this session's pane as the swarm's manager before anything else (#291). After a
reboot, `reboot-recover.sh` prompts the pane the manifest names as the manager, so a
manager that never registered can be passed over for a person's own session in the same
repo root.

```bash
# Outside a swarm (no manifest) swarm-register.sh prints a note and exits 0. A live
# manager already recorded is left in place. Never fatal.
REGISTER_SH=$(
  for d in "$(pwd)/.agent/scripts" \
           "$(pwd)/plugins/autocoder/scripts" \
           "$(pwd)/.claude-plugin/plugins/autocoder/scripts"; do
    if [ -f "$d/swarm-register.sh" ]; then echo "$d/swarm-register.sh"; exit 0; fi
  done
  found=$(
  find "$HOME/.claude/plugins/cache" -type f -name swarm-register.sh -path "*/autocoder/*" -not -path "*/skills/*" 2>/dev/null \
    | awk -F/ '{print $(NF-2) "\t" $0}' | sort -V -t$'\t' -k1,1 | tail -1 | cut -f2-
  )
  if [ -n "$found" ]; then echo "$found"; exit 0; fi
  # Grok installs to ~/.grok/installed-plugins/<name>-<hash>/. The hash is in
  # the directory name, so the Claude cache glob */autocoder/* does not match.
  find "$HOME/.grok/installed-plugins" -type f -name swarm-register.sh -path "*/autocoder-*/*" -not -path "*/skills/*" 2>/dev/null \
    | awk -F/ '{print $(NF-2) "\t" $0}' | sort -V -t$'\t' -k1,1 | tail -1 | cut -f2-
)
if [ -n "$REGISTER_SH" ]; then
  bash "$REGISTER_SH" --manager || echo "⚠️  swarm-register.sh failed; continuing without updating the manifest" >&2
fi
```

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
Ready. Run /autocoder:monitor-workers to dispatch work.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

### Step 4b: Reboot recovery (one worker per worktree, on its own issue)

Run this step when you were woken with `reason: reboot` (sent by `reboot-recover.sh`,
#274), or when any `<repo>-wt-*` worktree has no live worker agent. After a reboot every
worktree still has its branch, its commits and its uncommitted edits. The goal is one
worker per worktree, continuing the issue that worktree already holds, not re-triaging
the queue.

```bash
# Resolve SCRIPT_DIR — see scripts/README.md#script-dir
SCRIPT_DIR=$(
  for d in "$(pwd)/.agent/scripts" \
           "$(pwd)/plugins/autocoder/scripts" \
           "$(pwd)/.claude-plugin/plugins/autocoder/scripts"; do
    if [ -f "$d/issue-fns.sh" ] && [ -f "$d/fix-loop-gate.sh" ]; then echo "$d"; exit 0; fi
  done
  # Fallback: the installed plugin. Only <ver>/scripts is a complete tree;
  # <ver>/skills/autocoder/scripts is a subset that sorts after it (#142).
  # Rank by the <ver> directory alone, not the whole path: with two marketplaces
  # in the cache, a whole-path sort lets the marketplace name decide (#201).
  found=$(
  find "$HOME/.claude/plugins/cache" -type d -name "scripts" -path "*/autocoder/*" -not -path "*/skills/*" 2>/dev/null \
    | while read -r d; do if [ -f "$d/issue-fns.sh" ] && [ -f "$d/fix-loop-gate.sh" ]; then echo "$d"; fi; done \
    | awk -F/ '{print $(NF-1) "\t" $0}' | sort -V -t$'\t' -k1,1 | tail -1 | cut -f2-
  )
  if [ -n "$found" ]; then echo "$found"; exit 0; fi
  # Grok installs to ~/.grok/installed-plugins/<name>-<hash>/. The hash is in
  # the directory name, so the Claude cache glob */autocoder/* does not match.
  find "$HOME/.grok/installed-plugins" -type d -name "scripts" -path "*/autocoder-*/*" -not -path "*/skills/*" 2>/dev/null \
    | while read -r d; do if [ -f "$d/issue-fns.sh" ] && [ -f "$d/fix-loop-gate.sh" ]; then echo "$d"; fi; done \
    | awk -F/ '{print $(NF-1) "\t" $0}' | sort -V -t$'\t' -k1,1 | tail -1 | cut -f2-
)
bash "$SCRIPT_DIR/worktree-issue.sh"              # <path> <branch> <issue> <state> <command>
bash "$SCRIPT_DIR/worktree-issue.sh" --orphan-claims   # claims whose worktree is gone
```

For each worktree row:

1. **Exactly one worker.** Find the agents whose working directory is in that worktree
   (herdr: `herdr agent list` plus `herdr pane get <pane>`; tmux and cmux: the pane's
   current path). Never adopt tmux panes after a reboot, because tmux restores none.
   - One agent → adopt it. If its status line shows `ctx` at or above 85%, send `/clear`
     first.
   - Two or more → keep one and close the others (herdr: `herdr pane close <pane>`).
   - None → spawn one with `bash "$SCRIPT_DIR/restart-worker.sh" --worktree <path>`. It
     opens the pane or workspace and starts the worker on that worktree's branch.
2. **Send its command** (the row's last column) to the adopted worker:
   `/autocoder:fix-loop` when the state is `claimed`: first write the worktree's own issue
   back to it as a dispatch (`bash "$SCRIPT_DIR/dispatch-issue.sh" <N> --worktree <path>`,
   accepted because the worktree is on that issue's branch), so the loop's first tick
   resumes that issue on its branch with its edits whether or not the worktree's claim
   record survived, and the worker keeps looping when it is done. `/autocoder:fix <N>` when
   the state is `open` or `unknown` (no `working` claim for the loop to resume, or an
   unanswered backend: /fix re-claims it). `/autocoder:fix-loop` when the issue is `closed`
   or the branch names none (`none`). A spawned worker's loop resumes its own claim by
   itself, so it needs no prompt.
3. **Claims.** Release a `working` claim only when its worktree is gone, i.e. a row from
   `--orphan-claims`. On a shared tracker (GitHub, Jira, ADO) that means a claim this host
   made whose `wt=` worktree no longer exists; claims from other hosts or other clones are
   never listed, and must never be released here. Comment first, then remove the label. In this step do NOT release
   claims for worktrees that still exist, even if they look stale; Step 5's 60-minute
   rule does not apply to them after a reboot.
4. **Housekeeping.** Run `git worktree prune`. For each
   `<state-dir>/autocoder-merge-<repo-id>-<N>.pid` (the root `autocoder_tmp_root`
   prints) whose process is dead and that has no `.exit`, the merge job died with the
   host. Rebase that issue's branch and launch `merge-launch.sh` again, or report it if
   the branch is gone.

**Non-interactive mode:** do all of the above without asking; it changes no issue except
the orphaned claims' labels.

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
(`/autocoder:manager-handoff`) replaces the file (CDR #12). The idle sentinel's standing
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

- Run after `/autocoder:manager-handoff` + `/clear` or session restart
- After resume, the manager's typical next step is `/autocoder:monitor-workers`
- If all issues are blocked, `/autocoder:review-blocked` surfaces them for human decision
- A sentinel-woken manager runs `/autocoder:manager-resume --non-interactive` first, then
  starts `/autocoder:monitor-loop` (the sentinel sequences both in its spawn prompt)
