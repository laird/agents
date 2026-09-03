# Worker status line + idle detection — remaining design

Status: `stream-status.sh` (this branch) fixes **Step 4c**. It does **not** fix
Step 3 false-positive idles. Three changes remain.

## Root cause of false-positive idles

`worker-idle.sh` proves BUSY from these patterns:

```
\([0-9]+m [0-9]+s·    ↓ 25.8k tokens    esc to interrupt    ✽ Determining…
```

Every one is a Claude Code **TUI** artifact. The fleet runs `claude -p` headless
via `claude-worker-loop.sh` — no TUI — so none can ever appear. The only
remaining BUSY evidence is "pane changed within the 4s settle window", and a
worker polling a 25-minute merge gate prints nothing for minutes. It reads IDLE
every time.

`stream-status.sh` does not close this. `paint()` returns early unless ctx%
moved or `FORCE_EVERY` (120s) elapsed, and the line carries no ticking element:

```bash
if [ "$pct" -eq "$last_pct" ] && [ $((now - last_paint)) -lt "$FORCE_EVERY" ]; then return; fi
```

Across a 4-second sample the pane is still static.

## 1. Invert the default in `worker-idle.sh` — highest value, no status line needed

Today absence of evidence resolves to IDLE. The costs are asymmetric: a missed
dispatch wastes minutes; a wrong dispatch corrupts live work. Ambiguity must
resolve to BUSY/UNKNOWN, and **only an explicit sentinel may prove IDLE**.

Currently the fallthrough is:

```bash
printf 'IDLE\tno output for %ss and no activity markers (verify before dispatch)\n' "$SETTLE_SECONDS"
```

It should be UNKNOWN, and `--all` should not offer UNKNOWN panes for dispatch.

**Dependency, verify before flipping:** `claude-worker-loop.sh` must emit
`IDLE_NO_WORK_AVAILABLE` on *every* genuinely-idle route, or the fleet stalls —
no pane would ever prove idle. The sentinel is already in `IDLE_PATTERNS`, so
the path exists; confirm it fires on all of them.

## 2. Add a ticking activity segment to `stream-status.sh`

```
── ⣾ Bash·merge-poll 4m12s | ctx 26% of 1M | wt athena2-wt-2 | branch feature/issue-1823
```

Two payoffs from one change:

- a human can see what all N workers are doing at a glance (the original ask)
- a per-second elapsed timer means the pane always changes inside any settle
  window, giving `worker-idle` **positive** BUSY evidence instead of inference

`stream-render.sh` already parses `tool_use` (line ~75), so the tool name is in
hand. Needs a control record on tool start/end, and a repaint tick decoupled
from `FORCE_EVERY` — the timer must advance even when ctx% is flat.

Keep the `ctx NN%` segment byte-compatible: monitor-workers Step 4c greps
`ctx [0-9]+%` and must keep matching.

## 3. Make the sentinels symmetric

IDLE has an explicit marker; BUSY does not, and is inferred from
absence-of-absence. Add the BUSY counterpart so detection is a lookup rather
than pattern-sniffing that breaks on every TUI restyle.

## Ordering

1 and 3 stop the false positives even if 2 never ships. 2 additionally gives the
fleet dashboard.

## Deployment note

The fleet executes `~/.claude/plugins/cache/plugin-marketplace/autocoder/<ver>/scripts/`,
not this repo. Merging changes nothing until that cache is refreshed — make it
the last step or the fix will look like it did not work.

## Provenance

Root-cause analysis from a manager session that hit four false-positive idles in
two monitor ticks (2026-09-03): `worker-idle` reported panes %0/%1/%2 IDLE while
all three were alive and printing "the --changed gate stage can take 25-30
minutes, continuing to poll."
