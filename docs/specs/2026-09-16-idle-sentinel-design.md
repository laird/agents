# Idle Sentinel — zero-spend monitoring between work waves

**Status:** approved for implementation (operator, 2026-09-16); CDR round 1 applied
(12 findings — 3 blockers, 6 major, 3 minor — all incorporated below)
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
idle spend: ~$0/hour, at the cost of ≤ one poll interval of wake latency.

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
  SENTINEL ─────────────────────────▶ MANAGER (LLM, monitor loop)
     ▲                                    │
     └────────────────────────────────────┘
             quiescence handoff
```

**Ownership invariants (CDR #2, #5):**
- The **swarm manifest** (`.autocoder/swarm/<session>.json`, with its existing
  lock via `swarm-manifest-lib.sh`) is the single source of truth for "who is
  the manager." The sentinel reads and writes the manager entry under that
  lock; `sentinel-state.json` holds only sentinel-local bookkeeping (last tick,
  scheduler mode, wake-reason history) and never pane ownership.
- Every sentinel tick runs its entire body under `flock` on a dedicated lock
  file — concurrent ticks (cron overlap, cron + loop, manual run) serialize or
  skip. Check-then-spawn is atomic within the lock.
- Manager identity is verified by **marker, never bare pane id** (CDR #5, #6):
  the spawn sets an env var / pane title marker (`AUTOCODER_MANAGER=<session>`)
  and liveness means "marker-bearing agent process alive," probed per-mux.
  Pane ids recycle across reboots; ids alone are meaningless.

### 1. The sentinel (`scripts/idle-sentinel.sh`)

Runs as **either** a cron/systemd `--once` entry (preferred: survives reboots,
no long-lived process) **or** a `--loop` process — never both: the state file
records the installed scheduler mode, and `--ensure` inspects crontab/systemd
units before ever starting a loop (CDR #2). Cron entries source an explicit
environment file (PATH with gh/tmux/cmux/herdr, `AUTOCODER_*` vars); each tick
self-checks required tools before trusting any negative probe (CDR #7).

Every `AUTOCODER_SENTINEL_INTERVAL` (default 15m), under the tick lock:

**Wake predicate** — wake the manager if ANY of:
1. **Claimable work exists**: `issue_list --state open` (via `issue-fns.sh`,
   same backend the manager uses) returns ≥ 1 issue.
2. **Un-merged banked work**: any open issue labeled `awaiting-integration` —
   minus **standing conditions** (below).
3. **Stale claim**: any `working`-labeled issue older than the stall threshold
   with no matching recent branch activity.
4. **In-flight state**: a merge gate, deploy, or project-declared run is
   executing. Process checks MUST use self-match-proof bracketed patterns AND
   verify `/proc/PID/cwd` is inside this checkout before counting
   (`pgrep -f 'merge-to-integratio[n].sh'`, `pgrep -f 'upgrade-deplo[y]'`) —
   unscoped `-f` patterns self-match through `bash -c` wrappers and match
   other tenants' processes on a shared host (CDR #10).
5. **Health escalation** (project hook): the mechanical health probe fails.
   Green-path health checks run in the sentinel for free; only red wakes the
   LLM.
6. **Scheduled duty wake** (CDR #3a): at most every
   `AUTOCODER_SENTINEL_DUTY_INTERVAL` (default 6h), wake regardless, so the
   manager performs the duties no mechanical predicate covers — `/review-blocked`
   triage of needs-clarification/needs-design/proposal issues (which
   `issue_list --state open` deliberately excludes), comment-driven state
   changes, and general housekeeping. Without this, blocked issues rot
   invisibly.
7. **Operator wake file**: `touch .autocoder/wake` forces a wake next tick
   (manual escape hatch; also the webhook integration point).

**Predicate error semantics (CDR #7):** the issue backend distinguishes clean
negatives from errors (`issues-gh.sh` exit 3 = backend/auth failure). Any
probe error is **never** treated as quiescence: after
`AUTOCODER_SENTINEL_ERROR_TOLERANCE` (default 2) consecutive errored ticks,
wake the manager (it can diagnose) and fire the notify hook. Credentials are
pinned per tick (`GH_TOKEN="$(gh auth token --user "$AUTOCODER_GH_USER")"`
when configured) so a co-tenant flipping the active gh account cannot silently
blind the sentinel.

**Wake-reason dedup and backoff (CDR #3b):** the sentinel records the
normalized wake reason. If the same reason wakes N consecutive managers
(default 3) with no observable state change (same issue set hash), it enters
backoff for that reason (doubling, capped at 12h), fires the notify hook, and
logs loudly. The manager's step-down handoff can also declare **standing
conditions** (e.g. "awaiting-integration #2020 = cross-repo PR, human-gated,
ignore") which the sentinel subtracts from predicates 2–3 until they change.

**Project hooks**: if `.autocoder/sentinel-hooks.sh` exists, source it for
`sentinel_extra_wake_conditions` (exit 0 = wake), `sentinel_health_probe`
(exit 0 = green), and optional `sentinel_notify <message>` (page/Slack/email).

**Observe mode (CDR #11):** while a manager is alive, the sentinel keeps
ticking but only (a) runs the health probe — on red it does NOT spawn a second
manager; it writes the red result where the manager will see it
(`.autocoder/health-alert`) and fires the notify hook — and (b) monitors the
manager heartbeat (below). No wake-spawning while a verified manager lives.

**Logging**: one line per tick to `.autocoder/sentinel.log` (timestamp,
predicate results, action, lock/scheduler mode). Truncate above 1 MB.

### 2. Wake: spawn a real manager

On predicate true (and no verified live manager per the manifest + marker
probe), the sentinel:

1. Ensures the mux session exists (tmux/cmux/herdr auto-detect; `AUTOCODER_MUX`
   wins). If no server is running (host reboot), bootstrap via
   `start-parallel-agents.sh --manager-only` — **a new flag this spec adds**
   (CDR #4): manifest with a manager entry only, zero worker worktrees, and
   crucially **no auto-dispatch** (today the script both creates 3 workers by
   default and dispatches `/monitor-loop` itself; `--manager-only` suppresses
   both so exactly one party — the sentinel — dispatches). This makes the
   swarm self-starting after reboots.
2. Spawns the manager pane: fresh `claude --dangerously-skip-permissions`
   (never `--resume`) with the identity marker set. Records the manager entry
   in the **swarm manifest** under its lock (CDR #5).
3. Dispatches `/autocoder:manager-resume --non-interactive` and **waits for
   completion** (prompt-idle detection, not a marker grep) before dispatching
   the monitor loop (CDR #9) — `manager-resume` currently asks an interactive
   archive question mid-run; text sent while that prompt is open is consumed
   as its answer. The `--non-interactive` mode (new, this spec) skips all
   questions and does NOT archive `MANAGER-STATE.md` (CDR #12 — archival only
   happens when a successful step-down handoff replaces it, so a crashed
   manager never destroys the state the next wake needs).
4. Verifies the manager actually **started working**: activity marker
   (spinner/token meter) within ~60s, per the delivery-verification rule. On
   failure: retry the dispatch once; if still dead, **kill the pane the
   sentinel itself created** (cwd/marker-verified), clear its manifest entry,
   log loudly, fire the notify hook, and resume polling (CDR #1). A failed
   wake must never leave a zombie pane that blocks all future wakes.

**Manager heartbeat (CDR #1):** each monitor iteration, the manager touches
`.autocoder/manager-heartbeat`. In observe mode the sentinel treats a
heartbeat older than 3× the monitor interval as a wedged manager (the
100%-context wedge is a real incident class): notify, then kill the
marker-verified manager process and respawn fresh (committed work is safe; a
wedged manager has nothing else to lose). The heartbeat touch is added to the
`monitor-workers` command as a first step alongside the context check.

### 3. Quiescence handoff: manager steps down

The step-down check lives in **`monitor-workers`** (executed every iteration),
NOT `monitor-loop` (which runs once to schedule the loop — CDR #8). Each
iteration that finds **all** of — zero claimable issues, zero `working`
labels, zero non-standing `awaiting-integration`, zero live workers, no gate
or deploy in flight (same scoped process checks as the sentinel), and no
project in-flight state — increments a **file-persisted** counter
(`.autocoder/quiescent-iterations`; each iteration is a separate invocation,
so no in-session state survives); any non-quiescent iteration resets it. At
counter ≥ 2 (mirrors the two-idle-cycles worker-retirement rule), the manager:

1. Runs `/autocoder:manager-handoff`, recording the step-down reason and any
   **standing conditions** for the sentinel to subtract.
2. Ensures the sentinel is scheduled (`idle-sentinel.sh --ensure` — which, per
   the scheduler-mode rules above, will not double-install).
3. Deletes its own loop job (CronDelete / kills the sleep loop), clears its
   manifest manager entry under the lock, and exits the agent process —
   verified by process exit, not by `/exit` echo; an `/exit` that leaves the
   TUI alive is the zombie-pane failure of CDR #1.

Rule: **the manager only retires into a verified-scheduled sentinel; the
sentinel only stands down its wake-spawning when a marker-verified manager is
alive and heartbeating.** No gap, no overlap.

### 4. Mux support

All three multiplexers, by construction:
- Idle: no mux needed at all (cron/systemd/nohup).
- Wake: tmux (`new-window` + send-keys with the separate-Enter paste dance),
  cmux (`create-workspace` + `send`/`send-key`), herdr (`workspace create` +
  `pane send-text`/`send-keys Enter`, prompts via `agent prompt`) — all via the
  existing shared library.
- **Two-manager guard is manifest/lock + marker-probe based on every mux**
  (CDR #6). The earlier "cwd = main checkout" heuristic is dropped: cmux
  exposes no pane-cwd query, and screen-scraping a `❯` prompt is documented
  non-evidence. Liveness = the manifest's marker-bearing agent process exists
  (`pgrep` + `/proc/PID/environ` contains the marker, cwd-verified), which
  works identically regardless of mux.

## Configuration

| Variable / file | Default | Meaning |
|---|---|---|
| `AUTOCODER_SENTINEL_INTERVAL` | `15m` | poll cadence |
| `AUTOCODER_SENTINEL_DUTY_INTERVAL` | `6h` | scheduled duty wake (review-blocked etc.) |
| `AUTOCODER_SENTINEL_ERROR_TOLERANCE` | `2` | consecutive probe errors before escalation wake |
| `AUTOCODER_GH_USER` | unset | pin gh credentials per tick on shared hosts |
| `AUTOCODER_MAX_WORKERS` | `5` | (existing) fleet ceiling the woken manager honors |
| `.autocoder/sentinel-env` | — | environment file sourced by cron ticks |
| `.autocoder/sentinel-hooks.sh` | absent | project wake/health/notify hooks |
| `.autocoder/wake` | absent | manual/external force-wake |
| `.autocoder/manager-heartbeat` | — | touched by manager each iteration |
| `.autocoder/quiescent-iterations` | — | persisted step-down counter |
| `.autocoder/sentinel-state.json` | — | sentinel-local bookkeeping (never ownership) |

## Spend model (honest version — CDR #11)

- Idle: 0 LLM calls (vs ~4–6 full-context manager ticks + watchdog ticks/hour).
- Each wake costs a cold start: `manager-resume` (full state + live GitHub
  read) + ≥2 iterations before any possible step-down + a handoff — roughly
  3–4 warm-tick equivalents. **Break-even:** the sentinel wins when idle
  stretches exceed ~1 hour; bursty overnight arrivals (an issue every
  ~45 min) can cost MORE than a warm loop. The wake-reason backoff and duty
  interval bound the pathological cases; operators with steady trickle load
  should keep the classic warm loop (this feature is opt-in, not default).
- Standing unactionable conditions (e.g. a human-gated cross-repo PR holding
  `awaiting-integration` for days) are the flap risk — handled by standing
  conditions + backoff, not by pretending they won't happen.

## Risks and mitigations

- **Zombie pane / wedged manager blocks all wakes** → sentinel kills its own
  failed spawns; heartbeat monitoring kills+respawns wedged managers (CDR #1).
- **Sentinel dies silently** → cron/systemd as scheduler (self-healing per
  tick) + the manager's `--ensure` re-establishing it every step-down.
- **Concurrent sentinels / TOCTOU spawn race** → flock around the tick,
  scheduler-mode recording, manifest-lock spawn (CDR #2).
- **Predicate blind spots** → duty wake for review-blocked (CDR #3a), error
  escalation instead of error-as-quiescence (CDR #7), wake file for humans.
- **Wake flapping on standing conditions** → dedup + backoff + handoff-declared
  standing conditions (CDR #3b).
- **Two managers** → manifest + marker liveness across all muxes (CDR #6).
- **Cold-start blindness** → `MANAGER-STATE.md` preserved until a successful
  step-down handoff replaces it (CDR #12).

## Implementation plan

1. `scripts/idle-sentinel.sh` (+ platform mirrors per the parity rule): tick
   lock, predicate with error semantics, dedup/backoff, observe mode +
   heartbeat monitor, wake with spawn-verify-or-kill, `--ensure`, `--once`,
   `--loop`, `--dry-run` (prints spawn commands per mux), state file, hooks,
   env file for cron.
2. `start-parallel-agents.sh --manager-only`: zero workers, manifest
   manager-entry only, no auto-dispatch (CDR #4).
3. `manager-resume.md --non-interactive`: skip questions, never archive
   MANAGER-STATE.md (CDR #9, #12).
4. `monitor-workers.md`: heartbeat touch (first step), quiescence check +
   file-persisted two-iteration counter + step-down protocol (CDR #8);
   `monitor-loop.md` documents the loop-job deletion on step-down.
5. `manager-handoff.md`: step-down reason + standing-conditions block.
6. `install.sh`: optional cron install prompt (writes sentinel-env).
7. Tests: predicate units (mock backend incl. exit-3 errors), tick-lock
   concurrency, two-manager guard (manifest + marker), spawn-failure cleanup,
   heartbeat-wedge respawn, `--dry-run` per mux, `--manager-only` manifest
   shape.
8. Version bump + HISTORY entry.
