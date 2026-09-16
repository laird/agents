# Idle Sentinel — zero-spend monitoring between work waves

**Status:** approved for implementation (operator, 2026-09-16)
**Owner:** autocoder plugin
**Companion change:** dynamic fleet scaling (monitor-workers Step 5b, shipped in 4.27.0) —
this spec extends the same idea from workers to the manager itself.

## Problem

A swarm with no work still burns money. The manager session re-runs
`/autocoder:monitor-workers` every 10–15 minutes; each tick replays a large
context through an LLM to conclude "nothing to do." Health watchdog ticks do the
same for a check that is purely mechanical on the green path (curl + port codes
+ df). Over an idle night that is dozens of full-context LLM calls producing
zero decisions. Workers were fixed by dynamic scaling (scale to zero between
waves); the manager is now the last standing idle cost.

## Goal

When the system is quiescent, replace the LLM manager with a **shell script**
that polls for work every ~15 minutes at zero token cost, and spin up a real
LLM manager only when there is something for it to decide. Target steady-state
idle spend: $0/hour, at the cost of ≤ one poll interval of wake latency.

## Non-goals

- Replacing the manager while work is in flight. The sentinel never manages
  work; it only detects that work exists.
- Judgment on the green path. The sentinel evaluates a mechanical predicate;
  anything requiring interpretation is grounds to wake the manager.
- New multiplexer abstractions — the wake path reuses `mux-send-lib.sh` /
  `start-parallel-agents.sh`, which already handle tmux, cmux, and herdr.

## Architecture

Two states, one transition each way:

```
             wake predicate true
  SENTINEL ─────────────────────────▶ MANAGER (LLM, /monitor-loop)
     ▲                                    │
     └────────────────────────────────────┘
             quiescence handoff
```

### 1. The sentinel (`scripts/idle-sentinel.sh`)

A dependency-light shell loop (also installable as a cron entry / systemd timer
— preferred, since it survives reboots and needs no mux while idle). Every
`AUTOCODER_SENTINEL_INTERVAL` (default 15m):

**Wake predicate** — wake the manager if ANY of:
1. **Claimable work exists**: `issue_list --state open` (via `issue-fns.sh`,
   same backend the manager uses) returns ≥ 1 issue.
2. **Un-merged banked work**: any open issue labeled `awaiting-integration`
   (a READY branch is waiting for a manager-run merge gate).
3. **Stale claim**: any `working`-labeled issue older than the stall threshold
   with no matching recent branch activity.
4. **In-flight state** (quiescence was mis-declared or externally disturbed):
   a merge gate, deploy, or experiment/engagement is running. Cheap checks:
   `pgrep -f 'merge-to-integratio[n].sh'`, `pgrep -f upgrade-deploy`, plus an
   optional project-provided hook (below).
5. **Health escalation** (optional, project-configurable): the mechanical
   health probe fails. Green-path health checks run in the sentinel for free;
   only a red result wakes the LLM to diagnose/remediate.
6. **Operator wake file**: `touch .autocoder/wake` forces a wake on the next
   tick (manual escape hatch, also usable by external automation/webhooks).

**Project hooks** (optional, keep the core generic): if
`.autocoder/sentinel-hooks.sh` exists, source it for two functions —
`sentinel_extra_wake_conditions` (exit 0 = wake) and `sentinel_health_probe`
(exit 0 = green). This is where a project wires app-specific checks (e.g.
Athena's /health endpoints and disk threshold) without the plugin knowing
about them.

**Logging**: one line per tick to `.autocoder/sentinel.log` (timestamp,
predicate results, action). Log rotation: truncate above 1 MB.

### 2. Wake: spawn a real manager

On predicate true, the sentinel:
1. Ensures the mux session exists (any of tmux/cmux/herdr; auto-detect like
   the rest of the plugin; if no server is running — e.g. after a host reboot —
   bootstrap via `start-parallel-agents.sh --manager-only`). This makes the
   swarm **self-starting after reboots**, which today requires a human.
2. Spawns the manager pane: fresh `claude --dangerously-skip-permissions`
   (never `--resume`), then dispatches `/autocoder:manager-resume` followed by
   `/autocoder:monitor-loop <interval>` using the per-mux send forms already in
   `mux-send-lib.sh`.
3. Verifies the manager actually started (activity marker on the pane within
   ~30s, per the delivery-verification rule); on failure, retries once, then
   writes a loud failure line to the log and — if a notify hook is configured —
   calls it. The sentinel keeps polling regardless: a failed wake must not
   silence future wakes.
4. Records the manager pane id in `.autocoder/sentinel-state.json` and pauses
   its own wake-spawning (it keeps ticking in observe mode) until the manager
   exits — exactly one manager at a time.

`manager-resume` already gives a cold-started manager full situational
awareness from `MANAGER-STATE.md` + live GitHub state; no new state mechanism
is needed.

### 3. Quiescence handoff: manager steps down

New final step in `/monitor-loop` (and documented in `monitor-workers`): when a
full monitoring iteration finds **all** of — zero claimable issues, zero
`working` labels, zero `awaiting-integration`, zero live workers, no gate or
deploy in flight, and no project in-flight state — the manager:
1. Runs `/autocoder:manager-handoff` (writes `MANAGER-STATE.md`).
2. Confirms the sentinel is running (starts it if not — `idle-sentinel.sh
   --ensure`), so the watch is never dropped.
3. Notes the step-down time in the handoff, then exits the session (`/exit`).

Rule of thumb: **the manager only retires into a running sentinel; the sentinel
only stands down when a manager it spawned is verified alive.** No gap, no
overlap.

Guard against flapping: the manager requires quiescence across **two
consecutive iterations** before stepping down (mirrors the two-idle-cycles
rule for retiring workers).

### 4. Mux support

All three multiplexers, by construction:
- Idle: no mux needed at all (cron/systemd/nohup).
- Wake: tmux (`new-window` + send-keys with the separate-Enter paste dance),
  cmux (`create-workspace` + `send`/`send-key`), herdr (`workspace create` +
  `pane send-text`/`send-keys Enter`, prompts via `agent prompt`) — all via the
  existing shared library. `AUTOCODER_MUX` wins when set; otherwise live-state
  detection identical to monitor-workers.

## Configuration

| Variable / file | Default | Meaning |
|---|---|---|
| `AUTOCODER_SENTINEL_INTERVAL` | `15m` | poll cadence |
| `AUTOCODER_MAX_WORKERS` | `5` | (existing) fleet ceiling the woken manager honors |
| `.autocoder/sentinel-hooks.sh` | absent | project wake/health hooks |
| `.autocoder/wake` | absent | manual/external force-wake |
| `.autocoder/sentinel-state.json` | — | sentinel bookkeeping (manager pane, last tick) |

## Spend model

Idle: 0 LLM calls (vs ~4–6 full-context manager ticks + watchdog ticks per
hour today). Active: unchanged — the woken manager costs what a manager
costs, and it earns it by having decisions to make. Worst-case added latency:
one poll interval (15m) from issue-filed to manager-awake; operators who need
faster pickup lower the interval (each tick is a few `gh` calls) or touch the
wake file from a webhook.

## Risks and mitigations

- **Sentinel dies silently → nothing ever wakes.** Mitigate: cron/systemd as
  the scheduler (self-healing per tick, no long-lived process), plus the
  manager's step-down step 2 (`--ensure`) re-establishing it every cycle.
- **Wake predicate too narrow → work sits invisible.** The predicate covers
  issues, banked branches, stale claims, in-flight processes, health, and a
  manual override; anything else, by definition, arrives as one of those
  (comments alone don't need a manager until they change issue state).
- **Two managers (operator starts one by hand while sentinel spawns one).**
  Sentinel checks for an existing live manager pane (cwd = main checkout,
  agent running) before spawning, and records/locks via sentinel-state.json.
- **Cold-start blindness.** `manager-resume` + `MANAGER-STATE.md` is the
  existing, proven answer; the step-down handoff keeps it fresh.

## Implementation plan

1. `scripts/idle-sentinel.sh` (+ mirrors per the parity rule) — loop, predicate,
   wake, `--ensure`, `--once` (for cron), state file, hooks.
2. `monitor-loop.md` / `monitor-workers.md`: quiescence step-down protocol
   (two-cycle rule, handoff, ensure-sentinel, exit).
3. `manager-handoff.md`: record step-down reason + sentinel status.
4. `install.sh`: optional cron install prompt.
5. Tests: predicate unit tests (mock `gh` via issue-source fixtures), wake
   dry-run (`--dry-run` prints the spawn commands per mux), two-manager guard.
6. Version bump + HISTORY entry.
