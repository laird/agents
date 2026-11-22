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

Repeats `/monitor-workers` on a recurring interval. Each iteration:

1. Checks worker status via the swarm's multiplexer (tmux, cmux, or herdr)
2. Detects stale `working` labels
3. Dispatches idle workers to unblocked issues (a worker that runs its own fix loop, the default, takes a dispatch file written by `dispatch-issue.sh`, an override of its next pick, never a typed `/clear` + `/fix <N>` that would end its loop)
4. Runs `/review-blocked` when all remaining issues are blocked

`/monitor-workers` detects the hosting multiplexer itself from live state
(its "Multiplexer detection" section) and carries the tmux, cmux, **and herdr**
read/dispatch forms natively — including herdr-aware `worker-idle`, `worker-health`,
and `restart-worker`. Run it **bare**; do not append per-multiplexer instructions
to the loop prompt. An appended note goes stale (e.g. one claiming the helpers are
tmux-only) and then overrides the newer, correct protocol on every tick.

## Relationship to the Idle Sentinel

- **Step-down ends this loop.** When `/monitor-workers` detects sustained
  quiescence (its Step 6b), it hands off, schedules the idle sentinel
  (`idle-sentinel.sh --ensure`), stops the sleep loop this command runs, and exits
  the manager session. A loop that disappears this way is the normal end of a
  work wave, not a failure.
- **Sentinel-woken managers run this loop unattended.** A manager spawned by the
  idle sentinel carries `AUTOCODER_UNATTENDED=1` in its environment (its spawn
  prompt runs `/manager-resume --non-interactive`, then this command);
  every monitor-workers iteration then applies its "Unattended Mode" policy —
  autonomous defaults plus durable records instead of blocking questions. See
  `docs/specs/2026-09-16-idle-sentinel-design.md`.

## Instructions

```bash
INTERVAL_MINUTES="${1:-15}"

echo ""
echo "🔄 Starting monitor-workers loop"
echo "   Interval: ${INTERVAL_MINUTES}m"
echo ""
echo "This will:"
echo "  • Check worker status every ${INTERVAL_MINUTES} minutes"
echo "  • Dispatch idle workers to unblocked issues"
echo "  • Run /review-blocked when all issues need human review"
echo ""
```

### Register in the swarm manifest

```bash
# Record the manager in the swarm manifest (#217, part of #178), so the manifest names the live manager pane and pid, even when this
# session was started by hand rather than by start-parallel-agents.sh.
# Outside a swarm (no manifest) swarm-register.sh prints a note and exits 0.
# Never fatal: a failed registration must not stop the loop.
REGISTER_SH=$(
  for d in "$(pwd)/.agent/scripts" \
           "$(pwd)/plugins/autocoder/scripts" \
           "$(pwd)/.claude-plugin/plugins/autocoder/scripts"; do
    if [ -f "$d/swarm-register.sh" ]; then echo "$d/swarm-register.sh"; exit 0; fi
  done
  find "$HOME/.agent/plugins/cache" -type f -name swarm-register.sh -path "*/autocoder/*" -not -path "*/skills/*" 2>/dev/null \
    | awk -F/ '{print $(NF-2) "\t" $0}' | sort -V -t$'\t' -k1,1 | tail -1 | cut -f2-
)
if [ -n "$REGISTER_SH" ]; then
  bash "$REGISTER_SH" --manager || echo "⚠️  swarm-register.sh failed; continuing without updating the manifest" >&2
fi
```

Start by running `/monitor-workers` immediately.

After each iteration:

```bash
INTERVAL_SECONDS=$((INTERVAL_MINUTES * 60))
echo ""
echo "💤 Next check in ${INTERVAL_MINUTES} minutes..."
sleep "$INTERVAL_SECONDS"
```

Then run `/monitor-workers` again. Continue until interrupted.
