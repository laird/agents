# Swarm manifest contract

A swarm (one manager plus N workers, each in its own worktree) is described by
one JSON file in the **main checkout**:

```
<project-root>/.autocoder/swarm/<session>.json   # the manifest
<project-root>/.autocoder/swarm/<session>.lock   # its lock (empty file)
<project-root>/.autocoder/swarm/<session>.ready.txt  # manager readiness file, when used
```

`<session>` defaults to `<agent>-<project-name>` (e.g. `claude-agents`), the
name `start-parallel-agents.sh` gives the mux session. A swarm launched by hand
may use any name; `swarm-register.sh`, the idle sentinel, `start-workers.sh` and
`remove-worker.sh`, when not told the session, adopt the manifest when it is
the only one in the directory.

This page is the contract between the autocoder scripts that write the
manifest and the tools that read it (the idle sentinel, `start-workers.sh`,
`remove-worker.sh`, and external readers such as the agents-tui village). It
covers what is written today; the code is in
`plugins/autocoder/scripts/swarm-manifest-lib.sh` and `swarm-register.sh`.

## Who writes it

| Writer | When | What it changes |
|---|---|---|
| `start-parallel-agents.sh` | every launch, live or paused, every mux | writes the whole file (`write_swarm_manifest`, locked) |
| `swarm-register.sh` | start of `/autocoder:fix-loop` (worker) and `/autocoder:monitor-loop` (`--manager`) | adds or updates this worktree's worker entry, or the manager entry; sets the swarm `state` to `running` when it registers |
| `add-worker.sh` | adding a worker | adds one worker entry (`state: paused`) |
| `start-workers.sh` | starting paused workers | worker `state`: `starting`, then `started` or `failed` |
| `restart-worker.sh` | restarting a worker | worker `state: paused` |
| `remove-worker.sh` | removing workers | deletes worker entries |
| `idle-sentinel.sh` | manager verified dead, wedged, stepped down, found, or respawned | clears `manager` to `null`; refreshes its `pid`; writes a new manager entry after a respawn; sets `state: paused` on step-down; creates a minimal manifest if it must wake a manager and none exists |

## The lock

Writers take an exclusive `flock` on `<session>.lock`, read
the JSON, change it, write a temp file in the same directory and
`os.replace` it over the manifest. Every write is atomic, so readers therefore never see a half-written
file and need no lock to read: open, parse, done.

In `swarm-manifest-lib.sh`, every writer locks for itself: `write_swarm_manifest`,
`manifest_set_manager`, `manifest_set_state`, `manifest_add_worker_json`,
`manifest_update_worker_state` and `manifest_remove_workers`. `start-workers.sh`
and `remove-worker.sh` hold the lock for their whole run, so after taking it they
set `SWARM_MANIFEST_LOCK_HELD` to the lock's path and the helpers do not lock again
(a second `flock` on the same file blocks even within one process).

A writer that cannot find the manifest does nothing. Manifests are created by
`start-parallel-agents.sh`, and by the idle sentinel as a fallback when it
wakes a manager for a session that has none (`issueSourceOrigin: "sentinel"`,
`workers: []`, `state: paused`).

## Top-level fields

| Field | Type | Meaning |
|---|---|---|
| `version` | int | Schema version, `1`. Readers should ignore fields they do not know and refuse a version they do not know. |
| `session` | string | The session name; matches the file name. |
| `projectRoot` | path | Absolute path of the main checkout. |
| `projectName` | string | `basename` of `projectRoot`. |
| `agent` | string | `claude`, `codex`, `gemini`, `droid`, `pi`, … |
| `mux` | string | `tmux`, `cmux` or `herdr`. |
| `state` | string | Swarm state, see [State](#state). |
| `issueSource` | string | Issue backend in use (`github`, `file`, `jira`, `ado`). |
| `issueSourceOrigin` | string | Where `issueSource` was decided (informational; `sentinel` for a manifest the sentinel created). |
| `issueBackend` | string \| null | Backend detail, when there is one. |
| `issueDir` | path \| null | Issue directory for the `file` backend. |
| `taskListId` | string | Shared task-list id given to the agents. |
| `integrationBranch` | string | Branch the main checkout was on at launch. |
| `workers` | array | Worker entries, sorted by `number`. May be empty. |
| `manager` | object \| null | Manager entry; `null` once the sentinel has retired a dead manager. |

## Worker entries

| Field | Type | Meaning |
|---|---|---|
| `number` | int | Worker number N; unique in the manifest. The worktree is normally `<project-root>-wt-N`. |
| `worktree` | path | Absolute path of the worker's checkout. This, not the number, is what `swarm-register.sh` matches on. |
| `branch` | string \| null | Branch checked out at registration; absent until the worker registers. Changes as the worker moves between issues; treat it as a hint. |
| `launchMode` | string | `shell`, `interactive`, or `manual` (registered itself, not launched by a script). |
| `commandMode` | string | How the loop command reaches the agent: `shell`, `agent-input`, or `fix-loop` for a self-registered worker. |
| `agentLaunched` | bool | Whether an agent process was started in the pane. |
| `tmuxTarget` / `cmuxWorkspace` / `herdrPane` | string \| null | The worker's pane in the mux in use; the others are `null`. |
| `pid` | int \| null | The agent process, recorded at registration. Absent until the worker registers: launchers do not record worker pids. |
| `pid_start_time` | string \| null | Start token for `pid`, see [Liveness](#liveness). |
| `state` | string | `paused`, `starting`, `started` or `failed` (or whatever `swarm-register.sh --state` was given). Registering into an existing entry does **not** change it, so a hand-started worker in a `paused` entry still reads `paused`; check liveness. |
| `stateUpdatedAt` | ISO-8601 UTC | When `state` last changed. |
| `registeredAt` | ISO-8601 UTC | Last time the worker registered itself; absent until then. |

A worker entry that has `starting` older than `AUTOCODER_STARTING_STALE_SECONDS`
(300 s) is treated as stale by `start-workers.sh --yes`.

## Manager entry

| Field | Type | Meaning |
|---|---|---|
| `launchMode` | string | `shell`, `interactive`, or `manual` when `swarm-register.sh --manager` created the entry because `manager` was `null`. |
| `agentLaunched` | bool | Whether an agent was started in the manager pane. |
| `readinessMode` | string \| null | How launch readiness is signalled (always `shell` today). |
| `readyFile` | string \| null | Readiness file, relative to `projectRoot`. |
| `tmuxTarget` / `cmuxWorkspace` / `herdrPane` | string \| null | The manager's pane. |
| `pid` | int \| null | Manager process: the topmost process carrying the marker, which is often the **pane shell**, not the agent (see [Liveness](#liveness)). `null` when no agent was launched (paused launch, sentinel fallback manifest) or the launcher could not see it within `AUTOCODER_MANAGER_PID_WAIT` (15 s); the sentinel and registration fill it in later. |
| `pid_start_time` | string \| null | Start token for `pid`. |
| `marker` | string \| null | The environment assignment that identifies the manager, `AUTOCODER_MANAGER=<session>`. |
| `spawned_at` | ISO-8601 UTC | When the entry was first written. |
| `registeredAt` | ISO-8601 UTC | Last time `/autocoder:monitor-loop` registered. |

The manager and worker identity fields are snake_case (`pid_start_time`,
`spawned_at`) while the rest of the file is camelCase. The difference is
historical and fixed; readers must use the names as written.

## Markers

Identity comes from a process's **environment**, not from pane names, window
titles or command lines, which agents rewrite and anything can imitate.

- **Manager**: `AUTOCODER_MANAGER=<session>`. Exported in the manager pane
  before the agent starts, so the pane shell, the agent and everything it
  spawns carry it. The recorded manager is the topmost process carrying the
  marker, usually the pane shell.
- **Worker**: `AUTOCODER_WORKER=<session>:<N>`. Exported by
  `start-parallel-agents.sh` and `add-worker.sh` in each worker pane before
  the agent starts. `N` is the worker's `number`.

On Linux the marker is read from `/proc/<pid>/environ`; on macOS from
`ps -E`. Only processes owned by the same user can be read.

A worker started by hand (create a worktree, run the agent, send
`/autocoder:fix-loop`) has no marker. It is identified by its manifest entry
instead, which `swarm-register.sh` writes when the loop starts.

## Registration

`swarm-register.sh` runs at the start of `/autocoder:fix-loop` and, with
`--manager`, of `/autocoder:monitor-loop`. Under the lock it:

- finds the manifest from `AUTOCODER_WORKER` / `AUTOCODER_MANAGER`, else the
  manifest that already lists this worktree, else the only manifest;
- for a worker: updates the entry whose `worktree` is this checkout, or adds a
  new one numbered from the marker, the `-wt-N` suffix, or the next free
  number. Mux fields are only overwritten when the matching variable
  (`TMUX_PANE`, `HERDR_PANE_ID`, `CMUX_WORKSPACE_ID`) is set;
- for the manager: updates the entry's mux fields, `pid`, `pid_start_time` and
  `registeredAt`, keeping the rest (or creates one if `manager` is `null`),
  unless a different manager is still live, in which case it changes nothing;
- sets the swarm `state` to `running`, when it registered something. An existing
  worker entry's own `state` is left as it was (a new entry gets `started`,
  and `--state` overrides both).

No manifest means not a swarm: it prints a note and exits 0. The main checkout
is never added as a worker unless a session is given explicitly.

## State

`state` says whether the swarm is meant to be running:

| Value | Meaning |
|---|---|
| `running` | A manager or at least one worker has registered or been started live, and the manager has not stepped down since. |
| `partial` | Some worker is `started`, `starting` or `failed`, but not every worker is `started` (recomputed from the worker states whenever `start-workers.sh`, `restart-worker.sh` or `remove-worker.sh` changes them). |
| `paused` | Launched without starting the manager agent (paused launch) and nothing has registered since, or the manager stepped down (the sentinel saw `.autocoder/stepped-down`). |

Rules:

- Registration sets `running` whenever it writes an entry. Recomputing from
  worker states sets `running` when every worker is `started`, even after a
  step-down.
- Only a launch that does not start the manager agent, or an explicit step-down, writes `paused`.
  Recomputing from worker states never demotes a swarm to `paused`; with no
  started workers it keeps the current value.
- `partial` can outlive the condition that set it until the next registration
  or worker-state change rewrites it.

`state` records intent, not proof. A crashed swarm can still say `running`.

## Liveness

A `pid` alone does not prove anything: PIDs are recycled. A process is the one
the manifest describes only when **the PID exists and its start token equals
`pid_start_time`**.

The token comes from `process_start_time` in `swarm-manifest-lib.sh`:

- Linux: field 22 of `/proc/<pid>/stat`, the start time in clock ticks since
  boot.
- other: the `ps -o lstart=` string.

Tokens are only comparable with tokens made by the same helper on the same
host since the same boot. Compare them for equality; do not parse them.

A live shell at `pid` is not a live agent: the pane shell can outlive the
agent it ran. `swarm-register.sh` counts a recorded manager as live only when
an agent CLI (`claude`, `codex`, `gemini`, `droid`, `pi`, `node`, `claude-*`)
runs at or under that pid. Readers should apply the same test.

## What readers may rely on

- The file is always complete, parseable JSON (atomic replace).
- `session`, `projectRoot`, `agent`, `mux`, `state` and `workers` are present.
- Worker `number`s are unique and `workers` is sorted by them.
- An entry whose `pid` + `pid_start_time` match a running process, with an
  agent CLI at or under it, is that worker or manager.
- A process whose environment has `AUTOCODER_MANAGER=<session>` or
  `AUTOCODER_WORKER=<session>:<N>` was started for a swarm of that session
  name. A leftover from an earlier swarm with the same name carries it too, so
  corroborate against the entry's `pid` + `pid_start_time`.

## What readers must not rely on

- `state` as proof that anything is alive; check liveness.
- `pid` being set: it is `null` or absent until the process registers or the
  sentinel finds it.
- `branch` staying current.
- Pane ids being stable across mux restarts.
- Every worker carrying a marker: hand-launched workers do not.
- The manifest listing a worker that has not run `/autocoder:fix-loop` since it
  was started by hand.
- A missing field meaning anything other than "unknown". Worker entries lack
  `pid`, `pid_start_time`, `branch` and `registeredAt` until the worker
  registers, and manifests written before registration existed lack them
  entirely.
- A worker's `state` showing whether it runs: registration does not update it.

Readers should never write the manifest. A tool that needs to change it calls
the autocoder scripts, which take the lock.
