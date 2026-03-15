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
