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
may use any name; tools that are not told the session adopt the manifest when
it is the only one in the directory.

This page is the contract between the autocoder scripts that write the
manifest and the tools that read it (the idle sentinel, `start-workers.sh`,
`remove-worker.sh`, and external readers such as the agents-tui village). It
covers what is written today; the code is in
`plugins/autocoder/scripts/swarm-manifest-lib.sh` and `swarm-register.sh`.

## Who writes it

| Writer | When | What it changes |
|---|---|---|
| `start-parallel-agents.sh` | every launch, live or paused, every mux | writes the whole file |
| `swarm-register.sh` | start of `/autocoder:fix-loop` (worker) and `/autocoder:monitor-loop` (`--manager`) | adds or updates this worktree's worker entry, or the manager entry; sets `state` to `running` |
| `add-worker.sh` | adding a worker | adds one worker entry (`state: paused`) |
| `start-workers.sh` | starting paused workers | worker `state`: `starting`, then `started` or `failed` |
| `restart-worker.sh` | restarting a worker | worker `state: paused` |
| `remove-worker.sh` | removing workers | deletes worker entries |
| `idle-sentinel.sh` | manager verified dead, wedged or stepped down | clears `manager` to `null`, refreshes its identity, sets `state: paused` on step-down |

## The lock

Every read-modify-write takes an exclusive `flock` on `<session>.lock`, reads
the JSON, changes it, writes a temp file in the same directory and
`os.replace`s it over the manifest. Readers therefore never see a half-written
file and need no lock to read: open, parse, done.

A writer that cannot find the manifest under the lock does nothing (it does not
create one). Only `start-parallel-agents.sh` creates a manifest.

Not every writer is locked yet: `add-worker.sh` and `restart-worker.sh` write
through `manifest_add_worker_json` / `manifest_update_worker_state` without the
lock. Their writes are still atomic (temp file + rename), so a reader never sees
a torn file, but one of them racing a locked writer can lose that writer's
change.

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
| `issueSourceOrigin` | string | Where `issueSource` was decided (informational). |
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
| `branch` | string \| null | Branch checked out at registration. Changes as the worker moves between issues; treat it as a hint. |
| `launchMode` | string | `shell`, `interactive`, or `manual` (registered itself, not launched by a script). |
| `commandMode` | string | How the loop command reaches the agent: `shell`, `argv`, `agent-input`, or `fix-loop` for a self-registered worker. |
| `agentLaunched` | bool | Whether an agent process was started in the pane. |
| `tmuxTarget` / `cmuxWorkspace` / `herdrPane` | string \| null | The worker's pane in the mux in use; the others are `null`. |
| `pid` | int \| null | The agent process, recorded at registration. Absent for a launched worker that has not registered yet. |
| `pid_start_time` | string \| null | Start token for `pid`, see [Liveness](#liveness). |
| `state` | string | `paused`, `starting`, `started` or `failed`. |
| `stateUpdatedAt` | ISO-8601 UTC | When `state` last changed. |
| `registeredAt` | ISO-8601 UTC | Last time the worker registered itself. |

A worker entry that has `starting` older than `AUTOCODER_STARTING_STALE_SECONDS`
(300 s) is treated as stale by `start-workers.sh --yes`.

## Manager entry

| Field | Type | Meaning |
|---|---|---|
| `launchMode` | string | `shell`, `interactive`, or `manual` for a self-registered manager. |
| `agentLaunched` | bool | Whether an agent was started in the manager pane. |
| `readinessMode` | string \| null | How launch readiness is signalled (`shell`). |
| `readyFile` | string \| null | Readiness file, relative to `projectRoot`. |
| `tmuxTarget` / `cmuxWorkspace` / `herdrPane` | string \| null | The manager's pane. |
| `pid` | int \| null | Manager process. `null` when the launcher could not see it within 15 s; the sentinel fills it in later. |
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
  before the agent starts, so the agent and everything it spawns carry it. The
  manager is the topmost process carrying the marker.
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
- for the manager: replaces the entry unless a different manager is still
  live, in which case it leaves it alone;
- sets the swarm `state` to `running`.

No manifest means not a swarm: it prints a note and exits 0. The main checkout
is never added as a worker unless a session is given explicitly.

## State

`state` says whether the swarm is meant to be running:

| Value | Meaning |
|---|---|
| `running` | A manager or at least one worker has registered or been started live, and the manager has not stepped down since. |
| `partial` | Some workers started and others are `starting` or `failed` (recomputed from the worker states whenever `start-workers.sh`, `restart-worker.sh` or `remove-worker.sh` changes them). |
| `paused` | Launched without starting the manager agent (paused launch) and nothing has registered since, or the manager stepped down (the sentinel saw `.autocoder/stepped-down`). |

Rules:

- Registration always sets `running`.
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
an agent CLI (`claude`, `codex`, `gemini`, `droid`, `pi`, `node`) runs at or
under that pid.

## What readers may rely on

- The file is always complete, parseable JSON (atomic replace).
- `session`, `projectRoot`, `agent`, `mux`, `state` and `workers` are present.
- Worker `number`s are unique and `workers` is sorted by them.
- An entry whose `pid` + `pid_start_time` match a running process, with an
  agent CLI at or under it, is that worker or manager.
- A process whose environment has `AUTOCODER_MANAGER=<session>` or
  `AUTOCODER_WORKER=<session>:<N>` belongs to this swarm.

## What readers must not rely on

- `state` as proof that anything is alive; check liveness.
- `pid` being set: it is `null` or absent until the process registers or the
  sentinel finds it.
- `branch` staying current.
- Pane ids being stable across mux restarts.
- Every worker carrying a marker: hand-launched workers do not.
- The manifest listing a worker that has not run `/autocoder:fix-loop` since it
  was started by hand.
- Fields being absent in older manifests meaning anything other than
  "unknown"; manifests written before registration existed lack `pid`,
  `branch` and `registeredAt` on workers.

Readers should never write the manifest. A tool that needs to change it calls
the autocoder scripts, which take the lock.
