# Monitor Workers

Monitor worker agents in worktrees, detect stale work, assign unblocked issues to idle workers via the swarm's multiplexer (tmux, cmux, or herdr), and deploy when all work is complete.

**This command is designed for the manager session** — run it in the main project directory (not a worktree) alongside `/review-blocked`.

## Multiplexer detection — do this once, first

Every read/dispatch step below has a per-multiplexer form. Detect which one hosts the
swarm before Step 0 and use that form consistently for the whole run:

```bash
# herdr wins if its server is running AND it hosts agents in this project's worktrees
herdr agent list 2>/dev/null | grep -q '"agents"' && echo herdr
tmux list-panes -a -F '#{pane_current_path}' 2>/dev/null | grep -q "$(basename "$(pwd)")" && echo tmux
cmux tree --all >/dev/null 2>&1 && echo cmux
```

herdr identifies workers by **cwd**, not by naming conventions: `herdr agent list`
returns one JSON entry per agent with `cwd`, `pane_id` (e.g. `w6:p1`), `agent_status`,
and optional `name` (`wt<N>-<project>` / `manager-<project>` when launched by
`start-parallel-agents.sh`). A worker pane is any agent whose `cwd` is one of this
repo's worktrees; the manager is the entry whose `cwd` is the main checkout — skip it.
Note: a swarm can outlive its launch environment (`$AUTOCODER_MUX` may be unset in a
resumed manager session), so detect from live state, never from env alone.

Both monitoring helpers work here: `worker-idle` supports herdr natively (`--mux herdr`,
auto-detected — uses `agent_status` as a BUSY fast path plus the same double-sample), and
`worker-health` is multiplexer-agnostic by construction (it matches processes by cwd).

## Usage

```bash
# One-shot status check
/monitor-workers

# Continuous monitoring until all work complete
/monitor-workers --watch
```

## What This Does

1. **Check worktree status** — For each worker worktree, report branch, last commit time, and whether actively working
2. **Read worker screens** — Use the multiplexer (tmux/cmux/herdr) to check if agents are idle or active
3. **Detect stale "working" labels** — Find issues tagged "working" with no agent activity in the last hour; ask to remove
4. **Restart unhealthy workers** — Detect workers that are stalled AND consuming high memory (e.g. a wedged agent that ran out of context), and restart them in place on the same worktree/issue
5. **Find unblocked issues** — List open issues without blocking labels
6. **Dispatch idle workers** — Send `/fix <issue_number>` to idle workers via the multiplexer (tmux/cmux/herdr)
7. **Scale the fleet dynamically** — Create workers+worktrees (`add-worker`) when the claimable queue outgrows the fleet, and retire idle workers (`remove-worker --remove-worktree`) once their work is banked, so capacity tracks the queue in both directions
8. **Review blocked issues** — When all open issues are blocked and workers are idle, automatically run `/review-blocked` to surface issues for human review
9. **Deploy when ready** — When all workers complete all unblocked issues and integration has new commits, deploy
10. **Step down when quiescent** — After two consecutive iterations with nothing to do, hand off to the zero-cost idle sentinel and exit (Step 6b)

## Unattended Mode (`AUTOCODER_UNATTENDED=1`)

A sentinel-woken manager has no human present: the idle sentinel exports
`AUTOCODER_UNATTENDED=1` into every manager it spawns (R2-F5,
`docs/specs/2026-09-16-idle-sentinel-design.md`). When that variable is set, EVERY
AskUserQuestion in this command converts to its autonomous default **plus a durable
record** — an issue comment, and where genuinely human-gated, a standing condition
declared at the next handoff and a notify-hook call (`sentinel_notify` in
`.autocoder/sentinel-hooks.sh`, if defined) — never a blocking question nobody will
answer. The specific conversions:

- **Step 4 (stale `working` labels):** do not ask — post an explanatory comment on the
  issue, then `issue_release <number>`, exactly as the Step 4 approved path does.
- **Step 4b (unhealthy-worker restarts):** do not ask — restart flagged `UNHEALTHY`
  workers automatically, the same behavior `--watch` mode already prescribes.
- **Anything genuinely requiring a human** (exceeding the worker ceiling, teardown
  safety checks that keep failing, a consent/permission dialog): do NOT act on it.
  Record it as a standing condition at the next handoff, fire the notify hook, and
  continue with what can be done autonomously.

When `AUTOCODER_UNATTENDED` is unset, this section does not apply — the interactive
ask-the-human behavior written into each step below is unchanged. This section
overrides those asks only under the environment variable; it does not replace them.

## Instructions

### Step 0b: Read the Sentinel Health Alert (if present)

The idle sentinel keeps running the project's mechanical health probe even while a
manager is alive. On a red result it does NOT spawn a second manager — it writes the
probe output to `.autocoder/health-alert` for THIS command to handle (R2-F10,
`docs/specs/2026-09-16-idle-sentinel-design.md`).

```bash
cat .autocoder/health-alert 2>/dev/null
```

If the file exists:

1. **Read it** — it records the timestamp and the failing health probe's output.
2. **Act on it now**, before normal monitoring: diagnose the failure it describes,
   take the recovery the project's runbooks prescribe, and file or update an issue if
   the failure needs work a worker should pick up.
3. **Delete it**: `rm -f .autocoder/health-alert`. This step is the alert's only
   reader — a stale alert file must never survive into a later manager's context.

If the file is absent, continue to Step 1.

### Step 1: Discover Workers

```bash
# Find worktrees
git worktree list

# Find cmux workspaces (if cmux available)
cmux tree --all 2>/dev/null

# Find tmux sessions (if tmux available)
tmux list-sessions 2>/dev/null
tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} #{pane_current_path}' 2>/dev/null

# Find herdr agents (if herdr available) — one line per agent: pane_id, status, cwd
herdr agent list 2>/dev/null | python3 -c "
import sys, json
for a in json.load(sys.stdin)['result']['agents']:
    print(a['pane_id'], a.get('name') or '-', a['agent_status'], a['cwd'])"
```

Map each worktree directory to its cmux workspace, tmux pane, or herdr pane. Naming conventions:
- **cmux**: Workspaces named `claude-<project>-worker-N` or `wt<N>-<project>`
- **tmux**: Session named `claude-<project>`, workers in window 0 panes
- **herdr**: match on `cwd` (authoritative); names like `wt<N>-<project>` are a hint, not a contract — panes relaunched by hand lose them

### Step 2: Gather Status

For each worktree:

```bash
for wt_dir in $(git worktree list --porcelain | grep "^worktree " | sed 's/^worktree //' | grep -v "$(pwd)$"); do
  name=$(basename "$wt_dir")
  branch=$(cd "$wt_dir" && git branch --show-current)
  last_commit=$(cd "$wt_dir" && git log --oneline -1)
  last_time=$(cd "$wt_dir" && git log -1 --format=%cr)
  last_epoch=$(cd "$wt_dir" && git log -1 --format=%ct)
  now_epoch=$(date +%s)
  age_min=$(( (now_epoch - last_epoch) / 60 ))
  dirty=$(cd "$wt_dir" && git status --short | wc -l | tr -d ' ')

  echo "$name | branch=$branch | dirty=$dirty | last=$last_time ($age_min min ago)"
  echo "  $last_commit"
done
```

Also check GitHub state:

```bash
# Resolve the autocoder script directory. A project-local tree only wins if it is
# a COMPLETE override — i.e. it actually contains the file we are about to source.
# Testing for the directory alone let a stale vendored .agent/ or plugins/autocoder/
# tree, left behind by an old project import, shadow the installed plugin: the
# source below then failed and every issue_* call silently used the wrong backend.
SCRIPT_DIR=$(
  for d in "$(pwd)/.agent/scripts" \
           "$(pwd)/plugins/autocoder/scripts" \
           "$(pwd)/.claude-plugin/plugins/autocoder/scripts"; do
    if [ -f "$d/issue-fns.sh" ]; then echo "$d"; exit 0; fi
  done
  find "$HOME/.agent/plugins/cache" -type d -name "scripts" -path "*/autocoder/*" 2>/dev/null | sort -V | tail -1
)
if [ ! -f "${SCRIPT_DIR}/issue-fns.sh" ]; then
  echo "autocoder: cannot locate issue-fns.sh (resolved SCRIPT_DIR='${SCRIPT_DIR}')" >&2
  exit 1
fi
source "${SCRIPT_DIR}/issue-fns.sh"

# Open unblocked issues (--state open returns only the open/ bucket;
# blocked-labeled issues live in blocked/ and are excluded by directory).
issue_list --state open | jq -r '.[] | "#\(.number): \(.title)"'

# Issues currently being worked (lives in working/ bucket)
issue_list --state working | jq -r '.[] | "#\(.number): \(.title)"'
```

### Step 3: Decide Which Workers Are Idle

Run the idle check. Do **not** eyeball a pane capture and judge for yourself —
that is how this step used to work, and it dispatched over live work:

```bash
worker-idle --all
# or a single pane, exit 0 = idle, 1 = busy:
worker-idle --pane <pane-id>
```

It samples each pane twice a few seconds apart and calls it BUSY on any change,
so a worker mid-`npm run build` — printing nothing for minutes — still reads as
busy. It marks the manager's own pane `SELF` and excludes it. Panes reported
`IDLE` with "verify before dispatch" were merely static: read those before
sending, since a worker stopped at a permission prompt looks identical.

**Never treat any of these as evidence of idleness:**

| Looks idle | Why it isn't |
|---|---|
| Bare `❯` prompt with no visible tool call | The TUI renders an empty input box at all times, including mid-turn. It says nothing about state. |
| No output in the last few lines | `tail -15` scrolls past the status line. Anchor on the status line or use the two-sample check. |
| A capture taken earlier in this iteration | Panes change by the second. Re-sample at the moment you dispatch, not before deliberating. |

The only positive idle signals are `IDLE_NO_WORK_AVAILABLE`, `Brewed for Xm`,
and "no pane change across the settle window" — which is what `worker-idle`
tests.

**Corroborate before dispatching.** A worker whose worktree has commits in the
last few minutes, or that already appears in the `working` list for the issue
you were about to assign, is not idle no matter what the pane looks like:

```bash
git -C <worktree> log -1 --format='%cr %s'
```

Two of the three panes that triggered this rule were already working the exact
PRs the manager then "assigned" them. Duplicate assignment is the loudest
symptom of a bad idle read — if the work you are about to hand out is already
in flight, your idle detection is wrong, not the worker.

If a dispatch does land on a busy worker, send a short correction to that pane
immediately ("disregard my previous message, continue what you were doing")
rather than leaving it to reconcile two conflicting instructions.

**cmux equivalent** (no two-sample helper yet — capture twice by hand):
```bash
cmux read-screen --workspace <ref> --lines 40 > /tmp/s1; sleep 4
cmux read-screen --workspace <ref> --lines 40 > /tmp/s2
diff -q /tmp/s1 /tmp/s2 >/dev/null && echo IDLE || echo BUSY
```

**herdr** — `worker-idle --all` works here too (auto-detects herdr; force with
`--mux herdr`). It uses herdr's native `agent_status` as a BUSY fast path and keeps the
double-sample as the load-bearing IDLE check. For reference, the native states mean:

- `working` → busy, never dispatch
- `idle` / `done` → dispatch candidate, but corroborate first (below): a worker parked
  at a permission prompt or waiting on a long background shell can read `idle`
- `blocked` → read the screen; usually an approval prompt that needs the human
- missing/`unknown` → treat as busy, investigate by reading the screen

Corroborate an `idle`/`done` reading with one screen read
(`herdr agent read <pane_id> --lines 25 --format text`): a genuinely finished worker
shows a completed final message (e.g. "✻ Cogitated for Xm") with no spinner and no
`Running…` tool call. Then apply the same git/working-label corroboration as tmux.

### Step 4: Detect Stale "working" Labels

For each issue with the "working" label, check if work is actually happening:

1. **Check worktree match**: Is there a worktree with a branch containing the issue number? If so, has it had commits in the last 60 minutes?
2. **Check screen**: Can you find an agent actively working on this issue via the multiplexer screen read (tmux/cmux/herdr)?
3. **Check issue timestamps**: Is the issue's most recent comment/update older than 60 minutes?

**A "working" label is stale if ALL of these are true:**
- No worktree has committed changes for this issue in the last 60 minutes
- No agent screen shows active work on this issue
- The issue's most recent update is older than 60 minutes

**When a stale "working" label is detected**, use AskUserQuestion to ask:
> "Issue #N has the 'working' label but no agent appears to be actively working on it (no commits or file changes in the last hour). Remove the 'working' label so it can be picked up by another worker?"

If approved:
```bash
issue_release <number>
```

**Unattended mode:** skip the question — comment then release automatically (see
"Unattended Mode" above):

```bash
issue_comment <number> --body "Releasing stale 'working' label: no commits, no active screen, no issue update in >60 minutes (auto-released — unattended manager)."
issue_release <number>
```

### Step 4b: Restart Unhealthy Workers (High Memory + Stalled)

A long-running worker can wedge — most commonly it exhausts its context window
and stops making progress while still holding a large resident memory footprint.
The manager detects this and restarts the worker **in place**: it kills the
wedged agent process and relaunches a fresh agent in the **same worktree** on the
**same branch**, so the worker resumes its assigned issue via the existing
"working" label. Committed progress is preserved; only uncommitted in-memory
state (already lost on a hung process) is discarded.

Run the health report (read-only). It measures each worker's resident memory by
matching processes whose working directory is the worktree — that cwd is the
shared key across both tmux and cmux, so it works regardless of multiplexer:

```bash
worker-health
# or, to tune thresholds:
worker-health --mem-threshold-mb 6000 --stall-min 60
```

A worker is flagged **UNHEALTHY** only when **BOTH** are true (conservative — a
busy-but-large worker or an idle-but-lean worker is left alone):
- **Stalled**: no commits for `--stall-min` minutes (default 60), and its screen
  shows no active work (reuse the Step 3 screen read to confirm)
- **High memory**: agent RSS at/above `--mem-threshold-mb` (default 6000 MB)

When memory cannot be measured (RSS shown as `?`), the worker is **never**
auto-restarted — surface it for manual review instead.

For each worker the report flags `UNHEALTHY`, confirm it is genuinely wedged
(re-read its screen), then restart it in place:

```bash
restart-worker --worktree <worktree_path>
# with explicit options:
restart-worker --worktree <worktree_path> --mux cmux --agent codex
```

`restart-worker` finds the worker's pane/workspace by its worktree path,
kills the hung process (`tmux respawn-pane -k` / `cmux close-workspace`), and
relaunches the agent's fix-loop in the same worktree. After restarting, re-read
the worker's screen after a few seconds to confirm it came back up.

**herdr:** `worker-health` works unchanged (its memory/stall detection is cwd-based,
no multiplexer calls), and `restart-worker --worktree <path>` auto-detects herdr
(closes the wedged workspace, reopens one at the same cwd) — use them; do not
hand-roll the kill/relaunch. Manual fallback ONLY if the scripts are unavailable
in this checkout (NEVER kill by command-line pattern on a shared host):

```bash
# 1. find + kill the wedged agent (cwd-verified PID; kill and relaunch in SEPARATE calls)
for p in $(pgrep -x claude); do
  [ "$(readlink /proc/$p/cwd)" = "<worktree>" ] && kill "$p"
done
# 2. the pane drops to its shell; relaunch a FRESH agent — never `claude --resume`
#    (herdr helpfully prints a --resume hint on exit; resuming restores the very
#    session that wedged, 100%-full context and all)
herdr pane send-text <pane_id> "claude --dangerously-skip-permissions --model <model>"
herdr pane send-keys <pane_id> Enter          # separate call
# 3. wait ~10s for the TUI, confirm the status line rendered, then dispatch via
herdr agent prompt <pane_id> "/fix <issue_number>"   # or /fix-loop
```

**When to restart automatically vs. ask:** during `--watch`, restart `UNHEALTHY`
workers automatically (they are both wedged and bloated, so there is no progress
to lose). For one-shot runs, prefer confirming with the human first via
AskUserQuestion unless they have asked you to keep the fleet healthy unattended.
Under `AUTOCODER_UNATTENDED=1` there is no one to confirm with — restart
automatically, exactly as in `--watch` (see "Unattended Mode" above).

### Step 4c: Hand off workers approaching the context limit (≥95%)

**Every tick, read each worker's context percentage off its status line and hand off any
worker at ≥95% context — do NOT let it keep working up to 100% and wedge.** Distinct from Step 4b (which
restarts an *already*-wedged worker): Step 4c is **proactive**, triggered by context %, and
**preserves** the worker's in-flight task via a handoff rather than discarding uncommitted work.

Read each worker's context percentage from its pane. Claude workers get a status line
installed at launch (`install-statusline.sh`) that renders one line per pane:

```
ctx 47% of 1M | mem 12 | Sonnet 5 | wt athena2-wt-3 | branch feature/issue-264
```

That line is the intended read for this step — it also shows, in the same glance, which
worktree and branch the pane is on, which is how you catch two workers drifted onto the
same branch.

```bash
# the status line is the ONLY reliable source
tmux capture-pane -t <session>:<window>.<pane> -p | grep -oE 'ctx [0-9]+%' | tail -1

# herdr form of the same read
herdr agent read <pane_id> --lines 6 --format text | grep -oE 'ctx [0-9]+%' | tail -1
```

**Do not fall back to the built-in footer.** Its context text is not a stable contract: it
varies by version and session state, it is suppressed when a custom status line is
configured, and **some forms report context REMAINING rather than USED**. Accepting
whichever pattern matches will eventually invert the reading — and an inverted context
alarm is worse than none, since it reads reassuringly right when the worker is about to
wedge. `ctx NN%` always means used. A pane with no `ctx` reading is **unknown**, not
healthy: install the status line there and report it as unknown until then.

For **any worker at ≥95% context**, orchestrate handoff → clear → resume:

1. **Handoff** — preserve state before clearing. Prompt the worker to run its
   session-handoff skill — `ce-handoff` if installed, else `create-handoff` (the same
   substitution the `/fix` optional-skills mapping makes for the "session handoff" role) —
   and in the same prompt require the durable, skill-independent records: commit WIP to
   the branch (even partial, WIP-tagged) **and** post a handoff note (plan, key findings,
   next steps) as a comment on the GitHub issue the worker is on, so it survives the
   clear. If neither skill is installed the inline commit + note IS the handoff. If the
   worker can't self-handoff (near 100%/jammed), the manager writes the handoff note on
   its behalf.
2. **Reset** — `/clear` keeps the session (`tmux send-keys -t <pane> "/clear"
sleep 0.4          # let the TUI leave paste mode
tmux send-keys -t <pane> Enter    # separate call, or it never submits`); exiting and
   relaunching the agent fresh is often **faster** at very high context and also picks up
   plugin updates installed since launch — either works. Never resume the retired session.
3. **Resume** — `tmux send-keys -t <pane> "/autocoder:fix <issue_number>"
sleep 0.4          # let the TUI leave paste mode
tmux send-keys -t <pane> Enter    # separate call, or it never submits` (fresh
   context re-reads the issue + branch + handoff note and continues; if step 1 wrote a
   skill handoff doc, resume it via the matching skill — `ce-handoff` resumes its own,
   `resume-handoff` pairs with `create-handoff`).

**Why 95%, not 100%:** at 100% the worker wedges and the built-in `/clear` is often
un-submittable via tmux (jammed) — forcing the heavier `restart-worker`, which discards
uncommitted work. Handing off at 95% avoids the wedge and loses nothing.

**The jam is the whole reason for the threshold.** At roughly **≥97%** context the worker's
input stops accepting submissions: text sent via `tmux send-keys` queues as
`❯ Press up to edit queued messages` and **Enter does not submit it**. So `/clear` — and any
"do a handoff" instruction — cannot be driven via send-keys once the worker is that full.
Firing at 95% keeps you on the clean self-handoff path, *before* the jam.

#### Fallback: worker input is already jammed (≥~97%)

Do **not** keep retrying `/clear`; it fails silently and the worker wedges at 100% anyway.
The **manager captures the handoff on the worker's behalf** — nothing is lost, since the
worker's earlier commits are already safe on its branch and step 1 rescues the rest:

1. **Preserve uncommitted edits:**
   `git -C <worktree> add -A && git -C <worktree> commit -m 'WIP: manager-preserved handoff snapshot'`
2. **Post the handoff note** (state done + next steps) as a comment on the issue:
   `issue_comment <issue_number> --body "Handoff (manager-captured): ..."`
3. **Release the claim:** `issue_release <issue_number>` (drops the `working` label) so the
   resumed worker re-claims cleanly.
4. **Hard restart** — a kill, **not** send-keys `/clear`, which is what is jammed:
   `bash plugins/autocoder/scripts/restart-worker.sh --worktree <worktree>`
5. **Resume** — text and Enter in separate `send-keys` calls, or the TUI treats the
   trailing newline as pasted content and never submits:
   ```bash
   tmux send-keys -t <pane> "/autocoder:fix <issue_number>"
   sleep 0.4
   tmux send-keys -t <pane> Enter
   ```

Confirm the pane actually came back up before reporting recovery — `restart-worker.sh` kills
first, so a failed relaunch leaves a bare shell and a dead worker.

**Prefer prevention:** this fallback is manual and loses in-flight reasoning, so treat ≥95%
as a hard trigger. A worker loop that watches its own context and self-hands-off before the
jam is more reliable than the manager catching it on a monitor tick.

**Never `/clear` a mid-task worker without a handoff first** (only a *completed*-task worker
takes a bare `/clear` + `/autocoder:fix-loop`).

### Step 5: Dispatch Work to Idle Workers

Find unblocked claimable issues sorted by priority (the `--state open`
bucket already excludes blocked and working issues by directory):

```bash
issue_list --state open | jq -r 'sort_by(.labels | map(select(.name | test("^P[0-3]$"))) | .[0].name // "P9") | .[].number'
```

For each idle worker with an unworked issue available, send the fix command.

**The Enter must be its own `send-keys` call.** `send-keys "$text" Enter` in one
call reliably leaves the text UNSUBMITTED in the agent's input box: the TUI takes
the burst as one paste and treats the trailing newline as content, not submit.
The `sleep` lets the TUI leave paste mode. Scripts should use
`send_tmux_text_enter` from `mux-send-lib.sh`.

**A marker grep does not prove delivery** — unsubmitted text appears in
`capture-pane` just like received text. Confirm the pane submitted: prompt clear
plus an activity marker. If your prompt is still visible with no activity marker,
send a bare `tmux send-keys -t <pane> Enter` and re-check.

**cmux:**
```bash
cmux send --workspace <ref> "/fix <issue_number>"
cmux send-key --workspace <ref> Enter
```

**tmux:**
```bash
tmux send-keys -t <session>:<window>.<pane> "/fix <issue_number>"
sleep 0.4          # let the TUI leave paste mode
tmux send-keys -t <session>:<window>.<pane> Enter    # separate call, or it never submits
```

**herdr:** `agent prompt` performs the submit itself — one call, no paste-mode sleep,
no separate Enter:
```bash
herdr agent prompt <pane_id> "/fix <issue_number>"
```
The same delivery verification applies: re-read the pane after ~8s and require an
activity marker (spinner / token meter), not just your text appearing. If a pane holds
a bare shell instead of a running agent (e.g. after a manual kill), `agent prompt` has
no agent to talk to — launch one first via `herdr pane send-text` + `herdr pane
send-keys <pane_id> Enter` (Enter as its own call, same rule as tmux).

**Codex workers:** send the shell wrapper instead of the Antigravity slash command.
The wrapper runs the issue-start handshake before launching Codex:
```bash
cmux send --workspace <ref> "bash scripts/codex-autocoder.sh fix <issue_number>"
cmux send-key --workspace <ref> Enter

tmux send-keys -t <session>:<window>.<pane> "bash scripts/codex-autocoder.sh fix <issue_number>"
sleep 0.4          # let the TUI leave paste mode
tmux send-keys -t <session>:<window>.<pane> Enter    # separate call, or it never submits
```

After dispatching, verify the worker started by reading its screen again after a few seconds.

### Step 5b: Scale the Fleet Up and Down (dynamic workers)

Match fleet size to the dispatchable queue on every iteration — workers and their
worktrees are disposable capacity, not fixtures. A standing idle worker costs a
multi-GB worktree (node_modules), a resident agent session, and recycle churn; a
missing worker costs queue latency. Target: every dispatchable issue has a worker
within one monitoring cycle, and no worker sits idle across two consecutive cycles
with nothing it could claim.

**Scale UP** when dispatchable issues (open, unblocked, unclaimed) outnumber live
workers:

```bash
add-worker                  # creates worktree + pane/workspace + fresh agent
add-worker --agent claude   # or gemini, codex, droid
```

- Add workers **one at a time**, waiting ~60s and confirming the new worker claimed
  a DISTINCT issue before adding the next — simultaneous launches all claim the same
  top issue.
- Respect a ceiling: `AUTOCODER_MAX_WORKERS` if set, else 5. Stop below the ceiling
  when the host is resource-constrained (e.g. <10G disk free or heavy load) even if
  the queue is deeper.
- Size against the CLAIMABLE queue only — blocked/needs-*/already-working issues do
  not justify capacity.

**Scale DOWN** when a worker has been idle for two consecutive monitoring cycles
with no dispatchable issue for it:

```bash
remove-worker <N> --remove-worktree     # manifest-backed swarms
```

Pre-teardown safety checks — ALL must pass (banked-work-only rule):

1. Worktree clean: `git -C <worktree> status --short` empty (untracked scratch like
   `.upgrade-journal/` is fine)
2. Nothing unpushed: `git -C <worktree> log --branches --not --remotes --oneline` empty
3. Its issue(s) carry a READY/banked comment or are closed — never tear down a claim
   without a durable record on the issue
4. No merge gate or long-running job is executing from that worktree

If any check fails, keep the worker (or finish banking first). If the swarm has no
manifest (`remove-worker` refuses to run), tear down manually: cwd-verified kill of
the agent process, close its pane/workspace, then `git worktree remove <path>` and
`git worktree prune` — never `rm -rf` a registered worktree.

- Scaling to **zero** workers between work waves is normal — the manager alone is a
  valid fleet; recreate capacity when the next dispatchable issue appears.
- Never scale down a mid-task worker, never remove the manager's own checkout, and
  never touch panes that are not swarm workers.

**Ask the human instead of acting** when: a worker's safety checks keep failing
(suggests stuck work that needs triage, not deletion), or the queue calls for
exceeding the ceiling.

### Step 5c: Run Review-Blocked When All Issues Are Blocked

If there are **no unblocked issues available** for workers (all open issues have blocking labels like needs-design, needs-clarification, too-complex, etc.) AND there are **blocked issues that need review**, automatically invoke `/review-blocked` using the Skill tool.

This lets the human manager approve, reject, or skip blocked issues — potentially unblocking work for idle workers on the next monitoring cycle.

**Conditions to trigger review-blocked:**
- Zero unblocked issues available (no work for workers to pick up)
- At least one blocked issue exists (something to review)
- Workers are idle (not actively working on anything)

**Do NOT trigger review-blocked if:**
- There are unblocked issues available (workers have work to do)
- Workers are actively working (let them finish — new issues may appear)

When triggered, use the Skill tool:
```
Use the Skill tool to invoke: autocoder:review-blocked
```

### Step 6: Check Deploy Readiness

All conditions must be true:
1. No issues with "working" label (all work complete)
2. No open unblocked issues remaining
3. Integration branch has commits newer than the last deploy

```bash
# Check integration branch for new commits
git fetch origin --quiet
git log origin/integration --oneline -5
```

If ready, deploy:
```bash
./deploy.sh ey-staging
```

### Step 6b: Quiescence Step-Down (retire into the idle sentinel)

An idle swarm should not keep an LLM manager ticking — each "nothing to do" iteration
replays a full context for zero decisions. When the swarm stays quiescent, the manager
steps down and the zero-cost idle sentinel takes over polling (§3 of
`docs/specs/2026-09-16-idle-sentinel-design.md`). Evaluate this on EVERY iteration,
after Step 6.

**An iteration is quiescent only when ALL of these hold:**

1. Zero claimable issues — `issue_list --state open` returns `[]`
2. Zero `working` labels — `issue_list --state working` returns `[]`
3. Zero non-standing `awaiting-integration` issues — subtract issues declared as
   standing conditions in the ```` ```sentinel-standing ```` block of
   `MANAGER-STATE.md` (written by `/manager-handoff`)
4. Zero live workers — the fleet has scaled to zero (Step 5b)
5. No merge gate or deploy in flight from this checkout — bracketed, cwd-scoped
   process check only (unscoped `-f` patterns self-match and hit other tenants on a
   shared host):

```bash
INFLIGHT=no
for pat in 'merge-to-integratio[n].sh' 'upgrade-deplo[y]'; do
  for pid in $(pgrep -f "$pat" 2>/dev/null); do
    case "$(readlink /proc/$pid/cwd 2>/dev/null)" in
      "$(pwd)"|"$(pwd)"/*) INFLIGHT=yes ;;
    esac
  done
done
echo "inflight=$INFLIGHT"
```

**Track the streak in a file-persisted counter** — each iteration is a separate
invocation, so no in-session state survives between them:

```bash
# Quiescent iteration → increment
count=$(( $(cat .autocoder/quiescent-iterations 2>/dev/null || echo 0) + 1 ))
echo "$count" > .autocoder/quiescent-iterations

# NON-quiescent iteration → reset by deleting
rm -f .autocoder/quiescent-iterations
```

**At counter ≥ 2** (mirrors the two-idle-cycles worker-retirement rule in Step 5b),
step down — in this exact order:

1. **Handoff**: run `/manager-handoff`. Record the step-down reason ("quiescence —
   N consecutive quiescent iterations") and declare any standing conditions (its
   standing-conditions step), so the sentinel does not immediately re-wake a
   manager over work nobody can action.
2. **Ensure the sentinel is scheduled**: run `idle-sentinel.sh --ensure` (from the
   same resolved `SCRIPT_DIR` as Step 2). It is idempotent — it inspects
   crontab/systemd/running loops and never double-installs.
3. **Delete the counter**: `rm -f .autocoder/quiescent-iterations` (R2-F8 — a
   surviving counter would let the NEXT woken manager step down after a single
   iteration).
4. **Stop the monitor loop**: end the `/monitor-loop` sleep loop this session is
   running (there is nothing left to schedule).
5. **Do NOT clear the swarm manifest's manager entry** (R2-F6): exit verification
   cannot be performed by the exiting process itself. The sentinel's next tick
   observes the recorded pid dead, clears the entry under the manifest lock, and
   enters wake-spawning mode. Only the sentinel clears manager entries.
6. **Exit the session**. This iteration writes no heartbeat and no report — the
   step-down IS the outcome, and the sentinel detects the exit by the dead pid.

If the counter is below 2, or the iteration was not quiescent, continue to Step 7.

### Step 7: Write Structured Status (for agents-tui)

If `/tmp/agents-ui/` exists (indicating agents-tui is running), write a JSON summary file so the TUI can update its display without polling GitHub:

```bash
if [ -d /tmp/agents-ui ]; then
  SESSION_NAME=$(tmux display-message -p '#{session_name}' 2>/dev/null || echo "unknown")

  # Build JSON with worker statuses — use the data gathered in Steps 2-5
  # Each worker entry should include pane, status, issue number, and title
  # Example:
  cat > "/tmp/agents-ui/${SESSION_NAME}-monitor.json" << MONITOR_EOF
  {
    "timestamp": "$(date -Iseconds)",
    "session": "${SESSION_NAME}",
    "workers": [WORKER_ENTRIES_HERE],
    "open_issues": OPEN_COUNT,
    "working_issues": WORKING_COUNT,
    "blocked_issues": BLOCKED_COUNT,
    "idle_workers": IDLE_COUNT,
    "actions": [ACTIONS_LIST_HERE]
  }
  MONITOR_EOF
fi
```

Construct the `workers` array from the status gathered in Steps 2-3. Each entry:
```json
{"pane": "claude-agents-ui:2.0", "worktree": "wt-2", "status": "working", "issue": 100, "title": "Issue detail view"}
```

Also update individual worker status files for each worker discovered:
```bash
if [ -d /tmp/agents-ui ]; then
  # For each worker, write/update its status file
  # This ensures the TUI sees fresh data even between monitor-workers runs
  for each worker pane:
    echo "{\"status\": \"${WORKER_STATUS}\", \"issue\": ${ISSUE_NUM:-null}, \"title\": \"${ISSUE_TITLE:-}\"}" > "/tmp/agents-ui/${PANE_ID}.json"
  done
fi
```

### Step 8: Report Summary

Present a clear summary table:

```markdown
| Worker | Status | Branch/Issue | Last Activity |
|--------|--------|--------------|---------------|
| wt-1   | idle   | fix/issue-X  | 2 hours ago   |
| wt-2   | active | fix/issue-Y  | 5 min ago     |
| wt-3   | idle   | fix/issue-Z  | 1 hour ago    |

Open unblocked issues: N
Currently being worked: M
Idle workers available: K
Stale "working" labels: S

Actions taken:
- Sent `/fix 1234` to wt-1
- Sent `/fix 5678` to wt-3
- Removed stale "working" label from #9999

Deploy status: 21 commits since last deploy, waiting for workers to complete
```

### Step 9: Write the Manager Heartbeat (LAST action, every iteration)

As the very last action of every monitor-workers run — after the Step 8 report — write
`.autocoder/manager-heartbeat` with an ISO timestamp and a one-line outcome summary:

```bash
printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "<one-line outcome summary>" > .autocoder/manager-heartbeat
```

The summary is this iteration's outcome, e.g. `dispatched #123 to wt-2, released 1
stale label` or `quiescent (1/2)`. The idle sentinel monitors this file in observe
mode: a heartbeat older than 3× the monitor interval — with no gate/deploy in flight
and a static pane — marks this manager as wedged, to be killed and respawned (R2-F3).

**Write it at the END of the iteration, not the start.** A touch-first heartbeat is
satisfied by exactly the alive-but-unproductive loop it exists to catch; only a
completed iteration proves the manager is still doing useful work.

Exception: an iteration that steps down in Step 6b exits the session instead of
writing a heartbeat — the sentinel detects that exit by the dead pid, not by
heartbeat age.

## Continuous Monitoring Mode (`--watch`)

When `--watch` is passed, poll every 3 minutes until all work is done:

```bash
for i in $(seq 1 60); do
  sleep 180

  git fetch origin --quiet 2>/dev/null
  WORKING=$(issue_list --state working | jq 'length')
  UNBLOCKED=$(issue_list --state open | jq 'length')
  INT_HEAD=$(git rev-parse --short origin/integration)

  echo "[$(date +%H:%M:%S)] working=$WORKING unblocked=$UNBLOCKED integration=$INT_HEAD"

  # Check for stale working labels, restart unhealthy workers, and dispatch to
  # idle workers on each iteration (repeat Steps 3, 4, 4b, 5). Auto-restart any
  # UNHEALTHY worker (stalled AND high memory) via:
  #   worker-health
  #   restart-worker --worktree <path>   # for each flagged worktree
  # Each iteration also evaluates the Step 6b quiescence counter and ends by
  # writing the Step 9 heartbeat.

  # All done? Deploy.
  if [ "$WORKING" -eq 0 ] && [ "$UNBLOCKED" -eq 0 ]; then
    echo "All work complete. Deploying..."
    break
  fi
done
```

## Key Principles

- **Use the multiplexer to dispatch** — Send commands directly to idle workers via tmux/cmux/herdr, don't just report
- **Detect stale locks** — Ask before removing "working" labels that appear abandoned (unattended mode auto-releases with an explanatory comment instead)
- **Restart wedged workers in place** — A worker that is stalled AND holding high memory has run out of headroom; kill and relaunch it on the same worktree/issue rather than letting it hang
- **Priority order** — Assign highest priority issues first (P0 > P1 > P2 > P3)
- **Don't double-assign** — Check "working" label before dispatching
- **Scale capacity to the queue** — add workers when claimable issues outnumber the fleet; retire idle workers (worktree included) once their work is banked; zero workers between waves is fine
- **Deploy only when ready** — All workers idle + no unblocked issues + new commits
- **Deploy to staging only** — Never deploy to production without explicit user request
- **Step down when quiescent** — Two consecutive empty iterations hand the watch to the idle sentinel (Step 6b); only the sentinel clears the manifest manager entry
- **Heartbeat last** — End every iteration by writing `.autocoder/manager-heartbeat` (Step 9); a start-of-iteration heartbeat defeats the wedge detection it feeds
