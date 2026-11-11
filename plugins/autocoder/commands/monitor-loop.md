# Start Monitor Workers Loop

Run `/monitor-workers` in a continuous loop. This is the default command for the **manager session** in a parallel agent swarm.

## Usage

```bash
# Start with default 15-minute interval
/monitor-loop

# Custom interval
/monitor-loop 5
```

## What This Does

Schedules `/autocoder:monitor-workers` to run on a recurring interval using the `/loop` command. Each iteration:

1. Checks worker status via the swarm's multiplexer (tmux, cmux, or herdr)
2. Watches gate efficiency: every live or recent merge gate's duration, passes and re-gates, test-selection size and stage, with a warning and remedy for each threshold crossed (monitor-workers Step 2b)
3. Detects stale "working" labels
4. Dispatches idle workers to unblocked issues
5. Runs `/autocoder:review-blocked` when all issues are blocked
6. Deploys when all work is complete

`/autocoder:monitor-workers` detects the hosting multiplexer itself from live state
(its "Multiplexer detection" section) and carries the tmux, cmux, **and herdr**
read/dispatch forms natively — including herdr-aware `worker-idle`, `worker-health`,
and `restart-worker`. Schedule it **bare**; do not append per-multiplexer
instructions to the loop prompt. An appended note goes stale (e.g. one claiming the
helpers are tmux-only) and then overrides the newer, correct protocol on every tick.

## Gate efficiency, every tick

The loop is where a slow or churning gate gets noticed while it still runs. Each
`/autocoder:monitor-workers` iteration runs the project's gate monitor
(athena2: `scripts/mgr-gate-health.sh --since 6h`; elsewhere the plugin's generic read
of `/tmp/autocoder-merge-*.log`) and acts on its warnings. The thresholds, which the
project overrides through its own environment:

- a gate pass over **20 minutes** (`MGR_GATE_SLOW_PASS_MIN`): read the three largest stages;
- a targeted selection over **150 backend or 100 dashboard** test files
  (`MGR_GATE_WIDE_SELECTION`, `MGR_GATE_WIDE_SELECTION_DASHBOARD`): the train or diff is too wide;
- **two or more re-gates** in one gate (the integration branch moved under it): land waiting
  hotfixes before the next train, or ask the other swarm to hold landings while it gates;
- a live gate with **no log write for 15 minutes** (`MGR_GATE_STALL_MIN`): a wedge, check it;
- **READY branches waiting with no gate or train live**: launch one.

The interval sets how late a warning can be: at the default 15 minutes a 20-minute pass is
seen at most one tick after it crossed the line, which is the point of the loop. A tick that
skips the gate read because nothing else changed has skipped the one thing the operator asked
the loop to watch.

## Routing mode (self vs manager)

`start-parallel-agents.sh` records the swarm's issue-routing mode in the
`AUTOCODER_ROUTE` environment variable exported into this manager session:

- **`AUTOCODER_ROUTE=self`** (default) — workers run their own `/autocoder:fix-loop`
  and self-claim issues. This manager loop co-monitors: it cleans up stale labels,
  restarts unhealthy workers, deploys, and dispatches *supplementary* work only.
- **`AUTOCODER_ROUTE=manager`** — workers were launched **without** the self-claim
  fix-loop; they idle at a ready prompt. **This manager is the SINGLE assigner.**
  On each `/autocoder:monitor-workers` iteration it must:
  1. Read open/claimable issues and prioritize them (P0 > P1 > … > unlabeled).
  2. Pick **distinct** issues — never route the same issue to two workers.
  3. Add the `working` label **before** dispatching, so the assignment is durable.
  4. Dispatch exactly one `/autocoder:fix <N>` (or the codex wrapper) per idle worker.

  Because no worker ever selects its own issue, manager routing structurally
  eliminates the worker-vs-worker claim races that the best-effort self-claim path
  can hit. When `AUTOCODER_ROUTE` is unset, treat it as `self`.

## Relationship to the Idle Sentinel

- **Step-down deletes this loop's job.** When `/autocoder:monitor-workers` detects
  sustained quiescence (its Step 6b), it hands off, schedules the idle sentinel
  (`idle-sentinel.sh --ensure`), deletes the loop job this command created
  (CronDelete in `/loop` mode; killing the sleep loop in fallback mode), and exits
  the manager session. A loop job that disappears this way is the normal end of a
  work wave, not a failure.
- **Sentinel-woken managers run this loop unattended.** A manager spawned by the
  idle sentinel carries `AUTOCODER_UNATTENDED=1` in its environment (its spawn
  prompt runs `/autocoder:manager-resume --non-interactive`, then this command);
  every monitor-workers iteration then applies its "Unattended Mode" policy —
  autonomous defaults plus durable records instead of AskUserQuestion. See
  `docs/specs/2026-09-16-idle-sentinel-design.md`.

## How It Works

**Mode 1: `/loop` command (preferred, when CronCreate tool is available)**

Uses the native CronCreate mechanism to schedule recurring `/autocoder:monitor-workers` calls. No stop hook or settings.json modification needed.

**Mode 2: Manual loop (fallback for older Claude Code versions)**

Runs `/autocoder:monitor-workers` in a bash sleep loop, polling at the configured interval.

## Instructions

```bash
# Parse arguments
INTERVAL_MINUTES="${1:-15}"

echo ""
echo "🔄 Starting monitor-workers loop"
echo "   Interval: ${INTERVAL_MINUTES}m"
echo ""
echo "This will:"
echo "  • Check worker status every ${INTERVAL_MINUTES} minutes"
echo "  • Watch gate efficiency (duration, re-gates, test selection) every tick"
echo "  • Dispatch idle workers to unblocked issues"
echo "  • Run /review-blocked when all issues need human review"
echo "  • Deploy to ey-staging when all work completes"
echo ""
```

### Detect /loop availability and choose mode

**Check whether the `CronCreate` tool is available** (it appears in the available deferred tools list when Claude Code supports the `/loop` command).

**If CronCreate IS available → Use `/loop` mode (preferred):**

```bash
echo "✅ Using /loop command (CronCreate available)"
echo "To stop: use CronDelete to remove the scheduled job"
echo ""
```

**Run the first iteration immediately, then schedule the loop:**

First, invoke the monitor-workers skill directly (using the Skill tool) to do an immediate check. Then use the loop skill to schedule recurring checks:

```
Use the Skill tool to invoke: monitor-workers
```

After the first iteration completes:

```
Use the Skill tool to invoke: loop
With args: ${INTERVAL_MINUTES}m /autocoder:monitor-workers
```

This schedules `/autocoder:monitor-workers` to run every `INTERVAL_MINUTES` minutes using CronCreate.

---

**If CronCreate is NOT available → Use manual loop (fallback):**

```bash
echo "⚠️  /loop command not available — using manual sleep loop"
echo "To stop: Ctrl+C"
echo ""
```

Run the first iteration immediately, then loop with sleep:

```
Use the Skill tool to invoke: monitor-workers
```

After each iteration, sleep and repeat:

```bash
INTERVAL_SECONDS=$((INTERVAL_MINUTES * 60))
echo ""
echo "💤 Next check in ${INTERVAL_MINUTES} minutes..."
sleep "$INTERVAL_SECONDS"
```

Then invoke monitor-workers again via the Skill tool. Repeat until manually stopped (Ctrl+C) or all work is complete and deployed.
