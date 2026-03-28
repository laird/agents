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

1. Checks worker status via cmux/tmux
2. Detects stale "working" labels
3. Dispatches idle workers to unblocked issues
4. Runs `/autocoder:review-blocked` when all issues are blocked
5. Deploys when all work is complete

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
