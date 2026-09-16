# Idle Sentinel — zero-spend monitoring between work waves

**Status:** approved for implementation (operator, 2026-09-16); CDR rounds 1 and 2
applied (round 1: 12 findings; round 2: 10 findings, led by the manifest-gap blocker —
all incorporated below)
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

**Ownership invariants (CDR #2, #5; R2-F1, R2-F4, R2-F7):**
- The **swarm manifest** (`.autocoder/swarm/<session>.json`, with its existing
  lock via `swarm-manifest-lib.sh`) is the single source of truth for "who is
  the manager." The sentinel reads and writes the manager entry under that
  lock; `sentinel-state.json` holds only sentinel-local bookkeeping (last tick,
  scheduler mode, wake-reason history) and never pane ownership.
- **R2-F1 (blocker): today the manifest is only written on PAUSED launches.**
  This spec makes EVERY launch path — live and paused, all three muxes,
  `start-parallel-agents.sh` and the sentinel's own spawns — write/refresh a
  manifest manager entry, and extends the schema with `pid`, `pid_start_time`,
  `marker`, and `spawned_at`. An installed sentinel next to a hand-launched
  live swarm must see that swarm's manager; without this, the two-manager
  guard fails open on the most common launch path.
- Every sentinel tick runs its entire body under **`flock -n`** on a dedicated
  lock file (R2-F7): a contended tick SKIPS (logged, counted toward the
  error-tolerance escalation) rather than queueing — a blocking flock would
  let one hung wake permanently freeze the sentinel behind a held lock while
  cron reports green.
- Manager identity = **PID + process start time** recorded in the manifest at
  spawn (start-time match defeats PID recycling), corroborated on Linux by
  `/proc/PID/environ` containing the spawn marker (`AUTOCODER_MANAGER=<session>`;
  environ is null-delimited — probe with `grep -z`/`tr '\0'`) and cwd, and on
  darwin (cmux is macOS-only, no `/proc`) by `ps -E`/`lsof -p` (R2-F4). Pane
  ids and pane titles are never identity: ids recycle across reboots and agent
  TUIs rewrite titles.

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
ignore") which the sentinel subtracts from predicates 2–3. "Until they change"
is mechanical (R2-F9): each condition records the issue's `updatedAt` at
declaration; the sentinel drops the condition on any live `updatedAt` change
(one `gh issue view --json updatedAt` per condition per tick) and ALL
conditions expire at each duty wake unless the next handoff re-declares them —
stale conditions must not mask real work across manager generations.

**Project hooks**: if `.autocoder/sentinel-hooks.sh` exists, source it for
`sentinel_extra_wake_conditions` (exit 0 = wake), `sentinel_health_probe`
(exit 0 = green), and optional `sentinel_notify <message>` (page/Slack/email).

**Observe mode (CDR #11):** while a manager is alive, the sentinel keeps
ticking but only (a) runs the health probe — on red it does NOT spawn a second
manager; it writes the red result to `.autocoder/health-alert` and fires the
notify hook — and (b) monitors the manager heartbeat (below). No wake-spawning
while a verified manager lives. `health-alert` has a defined READER (R2-F10):
an early `monitor-workers` step reads it, acts on it, and deletes it; a stale
alert file never survives into a later manager's context. The sentinel also
sweeps each tick for marker-bearing, cwd-verified agent processes that do NOT
match the manifest entry and kills them (R2-F6) — orphaned zombie managers
from failed exits must not accumulate or shadow later probes.

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
2. Spawns the manager via **argv mode** (R2-F2), the consent-dialog-safe path
   `start-parallel-agents.sh` already uses (`MANAGER_COMMAND_MODE=argv`): a
   fresh `claude --dangerously-skip-permissions` (never `--resume`) carrying a
   SINGLE argv prompt that itself sequences the two commands — "run
   `/autocoder:manager-resume --non-interactive`, then start
   `/autocoder:monitor-loop <interval>`" — preserving CDR #9's ordering inside
   the prompt instead of via send-keys (text sent after spawn can be eaten by
   the `--dangerously-skip-permissions` consent dialog, which defaults to
   "No, exit"; that failure mode is documented in start-parallel-agents.sh and
   would otherwise make every unattended fresh-host wake fail). Spawn env sets
   the identity marker and `AUTOCODER_UNATTENDED=1` (R2-F5). Truncates
   `.autocoder/quiescent-iterations` before dispatch (R2-F8). Records the
   manager entry (pid, pid_start_time, marker, spawned_at) in the **swarm
   manifest** under its lock (CDR #5).
3. `manager-resume --non-interactive` (new, this spec) skips all questions and
   does NOT archive `MANAGER-STATE.md` (CDR #12 — archival only happens when a
   successful step-down handoff replaces it, so a crashed manager never
   destroys the state the next wake needs).
4. Verifies the manager actually **started working**: activity marker
   (spinner/token meter) within ~60s, per the delivery-verification rule, with
   an explicit check that distinguishes a visible CONSENT DIALOG from a
   working agent — a dialog is a bootstrap-configuration failure (notify,
   don't blindly retry; retrying re-answers the dialog) (R2-F2). The whole
   wake has a hard ceiling (default 10 min, R2-F7); on timeout or dead-agent:
   retry the dispatch once; if still dead, **kill the pane/process the
   sentinel itself created** (marker+pid verified), clear its manifest entry,
   log loudly, fire the notify hook, and resume polling (CDR #1). A failed
   wake must never leave a zombie pane that blocks all future wakes.

**Manager heartbeat (CDR #1; R2-F3):** at the END of each monitor iteration
the manager writes `.autocoder/manager-heartbeat` with an outcome token
(iteration timestamp + one-line summary) — end-of-iteration, not start,
because a touch-first heartbeat is satisfied by exactly the alive-but-
unproductive loop it exists to catch. In observe mode the sentinel treats a
heartbeat older than 3× the monitor interval as a POSSIBLY wedged manager and
kills only when ALL hold: stale heartbeat, AND no gate/deploy in flight from
this checkout (same scoped process checks as wake predicate 4 — one iteration
legitimately blocks >45 min when it runs a merge gate), AND the pane is static
across a settle window (two captures, no change). On kill: notify, kill the
marker+pid-verified process, sweep age-verified stale `.git/*.lock` files in
the checkout (a kill mid-git-operation leaves locks the respawned manager
trips over), then respawn fresh.

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
3. Deletes its own loop job (CronDelete / kills the sleep loop), deletes
   `.autocoder/quiescent-iterations` (R2-F8 — a surviving counter would let
   the NEXT manager step down after a single iteration), and exits the agent
   process. It does **NOT** clear its manifest entry (R2-F6): exit
   verification cannot be performed by the exiting process itself. The
   **sentinel's next tick** observes the manifest's marker+pid process dead
   (or alive with dead loop + stale heartbeat → kills it), clears the entry
   under the lock, and enters wake-spawning mode. Combined with the per-tick
   orphan sweep, a failed `/exit` becomes a bounded one-tick cleanup instead
   of an invisible zombie.

Rule: **the manager only retires into a verified-scheduled sentinel; the
sentinel only stands down its wake-spawning when a marker-verified manager is
alive and heartbeating; only the sentinel clears manifest manager entries.**
No gap, no overlap, no self-verified exits.

### 3b. Unattended policy for sentinel-woken managers (R2-F5)

A sentinel-woken manager has no human present, but `monitor-workers` and
`manager-resume` carry AskUserQuestion gates (stale-claim release, one-shot
restarts, archive prompts). Under `AUTOCODER_UNATTENDED=1` (set by the spawn
env) these convert to autonomous defaults: stale `working` claims past
threshold are auto-released WITH an explanatory issue comment; UNHEALTHY
workers are auto-restarted (the `--watch` behavior); anything genuinely
requiring a human becomes a standing condition + notify-hook call instead of
a blocking question. Without this, a wake on predicate 3 (stale claim) blocks
on a question nobody will answer, the heartbeat goes stale, the sentinel
kills/respawns, and the fresh manager asks the same question — a flap loop in
which the stale claim is never released.

### 4. Mux support

All three multiplexers, by construction:
- Idle: no mux needed at all (cron/systemd/nohup).
- Wake: tmux (`new-window` + send-keys with the separate-Enter paste dance),
  cmux (`create-workspace` + `send`/`send-key`), herdr (`workspace create` +
  `pane send-text`/`send-keys Enter`, prompts via `agent prompt`) — all via the
  existing shared library.
- **Two-manager guard is manifest/lock + pid-identity based on every mux**
  (CDR #6; R2-F4). The earlier "cwd = main checkout" heuristic is dropped:
  cmux exposes no pane-cwd query, and screen-scraping a `❯` prompt is
  documented non-evidence. Liveness = the manifest's recorded PID exists with
  a matching process start time; corroborated per-OS (Linux: `/proc` environ
  marker + cwd; darwin, the only cmux platform: `ps -E`/`lsof -p`). This works
  on every mux because it never asks the mux anything.

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
| `.autocoder/health-alert` | — | red-probe result; read+acted+deleted by monitor-workers |
| `AUTOCODER_UNATTENDED` | set by sentinel spawns | converts human gates to autonomous defaults + notify |

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
2. **Manifest on every launch path** (R2-F1): schema gains `pid`,
   `pid_start_time`, `marker`, `spawned_at`; `start-parallel-agents.sh`
   writes/refreshes the manager entry on LIVE launches (all muxes), not just
   paused ones; plus the new `--manager-only` mode: zero workers, manifest
   manager-entry only, no auto-dispatch (CDR #4).
3. `manager-resume.md --non-interactive`: skip questions, never archive
   MANAGER-STATE.md (CDR #9, #12); `AUTOCODER_UNATTENDED=1` policy in
   monitor-workers/resume (R2-F5).
4. `monitor-workers.md`: end-of-iteration heartbeat with outcome token
   (R2-F3), health-alert read/act/delete early step (R2-F10), quiescence
   check + file-persisted two-iteration counter + step-down protocol with
   counter deletion and manifest-entry retention (CDR #8; R2-F6, R2-F8);
   `monitor-loop.md` documents the loop-job deletion on step-down.
5. `manager-handoff.md`: step-down reason + standing-conditions block with
   per-condition `updatedAt` capture (R2-F9).
6. `install.sh`: optional cron install prompt (writes sentinel-env).
7. Tests: predicate units (mock backend incl. exit-3 errors), tick-lock
   `flock -n` skip behavior, two-manager guard (manifest + pid/start-time on
   Linux and darwin probe paths), spawn-failure cleanup incl. consent-dialog
   detection, heartbeat-wedge respawn gated on no-in-flight + git-lock sweep,
   orphan-marker sweep, stale-counter reset, standing-condition expiry on
   `updatedAt` change, `--dry-run` per mux, `--manager-only` manifest shape.
8. Version bump + HISTORY entry.
