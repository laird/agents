# Paused swarm startup and per-run issue source

**Status:** draft spec, pre-implementation
**Date:** 2026-06-15
**Author:** Laird Popkin (assisted)
**Related:** `2026-05-19-pluggable-issue-source-implementation-plan.md`,
`2026-05-21-fix-loop-token-efficiency-design.md`

---

## 1. Problem

`start-parallel-agents.sh` currently creates a full autocoder swarm and
immediately sends each worker the continuous issue-resolution command
(`/fix-loop`, `/autocoder:fix-loop`, a Codex `/goal`, or the shell loop
fallback). That is correct for fully autonomous startup, but it gives the
operator no chance to:

1. Start the worker fleet without claiming issues yet.
2. Inspect or prioritize the queue from the manager session first.
3. Explicitly choose the issue backend for that swarm invocation.

This is especially awkward for GitHub Issues: an operator may want to run
several parallel Codex workers against GitHub issues, but start them paused
so the manager can review the queue, unblock issues, or start only selected
workers.

## 2. Goals

1. Add a paused swarm mode that creates the normal swarm layout but does
   not start worker or manager loops.
2. Allow `start-parallel-agents.sh` callers to choose the issue source for
   this run without mutating persistent `.autocoder.json` configuration.
3. Start the manager session in paused mode, but do not run
   `/monitor-loop` or equivalent manager loops automatically.
4. Give the manager clear readiness instructions that tell the operator the
   swarm is paused and give concrete commands for reviewing issues and
   starting workers.
5. Add a command-line control surface for starting paused workers later.
6. Preserve existing default behavior when new flags are absent.

## 3. Non-goals

- Persistently changing issue source configuration. `/set-issue-source`
  remains the persistent setup path.
- Adding a rich scheduler or dispatch policy. This spec only starts all
  workers or a selected worker.
- Changing issue claim semantics, `start-issue-work.sh`, or fix-loop
  priority rules.
- Adding a separate manager-only mode.
- Solving cross-host coordination. Existing backend locking and labels
  remain the source of truth.

## 4. Proposed CLI

### 4.1 Start swarm options

Add these options to `plugins/autocoder/scripts/start-parallel-agents.sh`:

```bash
--paused
--no-start                  # alias for --paused
--issue-source file|github
--issue-dir PATH            # valid only with --issue-source file
```

Examples:

```bash
start-parallel 5 --mux tmux --agent codex --issue-source github --paused
start-parallel 5 --mux tmux --agent claude --issue-source github --paused
start-parallel 3 --mux cmux --agent gemini --issue-source file --issue-dir .issues --paused
```

### 4.2 Start or add workers later

Use `add-worker` as the single manager-facing command:

```bash
add-worker [count] [--mux tmux|cmux] [--agent claude|gemini|codex|droid] [--no-worktrees]
```

Examples:

```bash
add-worker                 # starts one idle worker, or adds/starts one worker
add-worker 2               # starts or adds/starts two workers
```

When a manifest-backed swarm has idle paused workers, `add-worker` starts
those workers first. It creates new workers only when the requested count
exceeds idle capacity.

`plugins/autocoder/scripts/start-workers.sh` may remain as an internal
delivery helper used by `add-worker`, but it is not a user-facing command
or installer surface.

Use `remove-worker` as the matching manager-facing shutdown command:

```bash
remove-worker WORKER_NUMBER [WORKER_NUMBER ...] [--mux tmux|cmux] [--agent claude|gemini|codex|droid] [--session SESSION] [--remove-worktree]
```

`remove-worker` must close the selected manifest-backed tmux panes or cmux
workspaces and remove those worker entries from the swarm manifest. It
preserves worktrees by default; `--remove-worktree` removes the worker
worktree only after the pane/workspace is closed successfully.

## 5. Supported agent technologies

The launcher supports four agent technologies today. The paused-swarm
feature must preserve each path rather than optimizing only for Codex.

| Agent option | Technology | Worker launch | Worker start command | Manager start command | Paused-mode expectation |
|---|---|---|---|---|---|
| `--agent claude` | Claude Code | `claude --dangerously-skip-permissions` | `/autocoder:fix-loop` | `/autocoder:monitor-loop` | Launch Claude in workers; launch manager only when readiness can be shown without submission. |
| `--agent gemini` | Gemini CLI / Antigravity | `gemini --sandbox=false` | `/fix-loop` | `/monitor-loop` | Launch Gemini in workers; launch manager only when readiness can be shown without submission. |
| `--agent codex` | Codex CLI | `codex` | Native Codex `/goal` when available, otherwise `scripts/codex-fix-loop.sh` | Native manager `/goal` when available, otherwise `scripts/codex-manage-workers-loop.sh` | Launch Codex in workers; launch manager only with no-submit readiness, never `/goal`. |
| `--agent droid` | Factory Droid CLI | no interactive worker launch today | `scripts/droid-fix-loop.sh` | `scripts/droid-manage-workers-loop.sh` | Create workspaces/panes and manager context; do not launch worker processes until `add-worker` starts an idle worker or adds new capacity. |

Auto-detection order remains unchanged:

```text
claude -> gemini -> codex -> droid
```

This order is existing behavior, not a recommendation about preferred
agent technology.

`add-worker` and its internal delivery helper must support the same
`--agent` values. They should reuse `worker-launch-lib.sh` for worker
command resolution so Claude, Gemini, Codex, and Droid stay consistent
with `restart-worker.sh`.

`worker-launch-lib.sh` should become the single source of truth for launch
and command modes. It must resolve and export:

```bash
AGENT_LAUNCH_CMD        # command that starts an agent REPL, or empty
WORKER_CMD              # command that starts issue work
WORKER_LAUNCH_MODE      # interactive|shell
WORKER_COMMAND_MODE     # agent-input|shell
MANAGER_LAUNCH_CMD      # command that starts a manager REPL, or empty
MANAGER_CMD             # command that starts manager monitoring
MANAGER_LAUNCH_MODE     # interactive|shell
```

`start-parallel-agents.sh`, `add-worker.sh`, the internal worker delivery
helper, and `restart-worker.sh` must use those resolved mode values
instead of deriving them independently.

Add or extract a read-only issue-source resolver for launchers and
lifecycle scripts. It may share parsing code with `issue-config.sh`, but
it must not take `issue-config.sh`'s interactive setup path and must not
write `.autocoder.json`. It should expose deterministic dry-run output for
tests, for example:

```bash
resolve_effective_issue_source "$CLI_ISSUE_SOURCE" "$CLI_ISSUE_DIR"
# -> ISSUE_SOURCE, ISSUE_DIR_PATH, ISSUE_SOURCE_ORIGIN
```

When no CLI issue source is supplied, the resolver's default is the
project's last-used issue source from the main worktree `.autocoder.json`.
Exported `ISSUE_SOURCE` is only a compatibility fallback when the project
has no persisted issue source; it must not silently override the
project's last-used source.

## 6. Runtime semantics

### 6.1 Issue source

`--issue-source` is a swarm-scoped override. The launcher must resolve one
effective issue source before creating any sessions, panes, workspaces, or
worktrees:

1. If `--issue-source` is supplied, use that value.
2. Else read the configured `.autocoder.json` value from the main worktree;
   this is the project's last-used issue source.
3. Else if `ISSUE_SOURCE` is already exported in the launcher's
   environment, use that value as a compatibility fallback.
4. If no source can be resolved without prompting or writing config, fail
   before creating swarm resources and tell the operator to run
   `/set-issue-source` or pass `--issue-source`.

The launcher exports environment variables for the effective source into
every worker pane/workspace and the manager pane/workspace:

For GitHub:

```bash
export ISSUE_SOURCE=github
```

For file-backed issues:

```bash
export ISSUE_SOURCE=file
export ISSUE_DIR_PATH=/absolute/path/to/.issues
```

For a project configured with a custom backend, such as a future Jira
backend, the resolver must preserve the last-used `.autocoder.json`
configuration by exporting `ISSUE_SOURCE=<custom>` and any configured
backend dispatch value such as `ISSUE_BACKEND`. The `--issue-source` CLI
flag remains limited to `file|github` in v1; custom backends are reused
only from project configuration or explicit environment fallback.

The launcher must not write `.autocoder.json` while resolving these CLI
options. In paused mode, it must persist the effective issue source and
its origin in the swarm manifest described in §6.2 so later paused-swarm
lifecycle commands (`add-worker.sh`, the internal worker delivery helper,
and `restart-worker.sh`) use the same backend as the swarm startup
command.

For v1, issue-source continuity for later `add-worker.sh` /
`restart-worker.sh` calls is guaranteed only for paused swarms with a
manifest. A normal non-paused swarm started with a per-run issue-source
override exports the override to initially launched workers and manager,
but does not preserve it for later lifecycle commands.

If `--issue-source file` is used without `--issue-dir`, default
`ISSUE_DIR_PATH` to the main worktree's `.issues` directory. If the
effective source is `file`, `ISSUE_DIR_PATH` must be resolved to an
absolute path before it is exported or written to the manifest.

If the effective source is `file` because `ISSUE_SOURCE=file` was already
exported, the resolver must use exported `ISSUE_DIR_PATH` when present,
otherwise read configured `issueDir` from `.autocoder.json`, otherwise
default to the main worktree's `.issues` directory. The resolver must fail
if the resulting file issue directory cannot be represented as an
absolute path.

If `--issue-dir` is passed without `--issue-source file`, fail fast with a
usage error.

### 6.2 Swarm manifest

At startup, write a small manifest under the main worktree:

```text
.autocoder/swarm/<session-name>.json
```

The manifest is required for paused swarms. For v1, normal non-paused
startup does not write a manifest; adding normal-swarm manifests is
deferred until there is a lifecycle command that consumes them. The
manifest should contain enough state for later commands to avoid guessing
from tmux/cmux layout alone:

```json
{
  "version": 1,
  "session": "codex-myproject",
  "projectRoot": "/Users/me/src/myproject",
  "projectName": "myproject",
  "agent": "codex",
  "mux": "tmux",
  "state": "paused",
  "issueSource": "github",
  "issueSourceOrigin": "cli",
  "issueBackend": null,
  "issueDir": null,
  "taskListId": "parallel-20260615-120000",
  "integrationBranch": "main",
  "workers": [
    {
      "number": 1,
      "worktree": "/Users/me/src/myproject-wt-1",
      "launchMode": "interactive",
      "commandMode": "agent-input",
      "agentLaunched": true,
      "tmuxTarget": "%12",
      "cmuxWorkspace": null,
      "state": "paused",
      "stateUpdatedAt": "2026-06-15T12:00:00Z"
    }
  ],
  "manager": {
    "launchMode": "shell",
    "agentLaunched": false,
    "readinessMode": "shell",
    "readyFile": ".autocoder/swarm/codex-myproject.ready.txt",
    "tmuxTarget": "%13",
    "cmuxWorkspace": null
  }
}
```

State values:

- Swarm `state`: `paused`, `running`, `partial`, or `stopped`.
- `issueSourceOrigin`: `cli`, `configured`, or `environment`, indicating
  how the effective source was selected. This is for operator visibility
  and diagnostics only; lifecycle commands must use `issueSource` /
  `issueDir` from the manifest regardless of origin.
- `issueBackend`: optional backend dispatch script name from
  `.autocoder.json` / `ISSUE_BACKEND` for configured custom issue sources.
  It is `null` for built-in `file` and `github` sources.
- Worker `state`: `paused`, `starting`, `started`, `failed`, or `unknown`.
  `starting` is a transient state used under the manifest lock to prevent
  concurrent start attempts from sending duplicate worker commands.
- Worker `stateUpdatedAt`: ISO-8601 timestamp for the latest worker state
  transition. It is required when setting `starting` and recommended for
  all worker state updates.
- Worker `launchMode`: `interactive` when an agent REPL is launched during
  paused startup; `shell` when the worker process is started later by a
  shell command.
- Worker `commandMode`: `agent-input` when the later worker-start command
  must be sent to an already-launched agent REPL; `shell` when the later
  worker-start command must be sent to a shell. `commandMode`, not
  `launchMode`, controls whether shell `export` commands are safe.
- Worker `agentLaunched`: `true` when the interactive agent process is
  already running in the pane/workspace.
- Manager `launchMode`: `interactive` when a manager agent REPL is
  launched; `shell` when the manager pane/workspace remains at a shell.
- Manager `agentLaunched`: `true` when the interactive manager process is
  already running in the pane/workspace.
- Manager `readinessMode`: `agent-no-submit` when readiness instructions
  are displayed inside the agent UI without submission; `shell` when the
  readiness file is shown in the shell.
- Manager `readyFile`: path to the generated readiness instruction file.

The manifest is not the issue-locking source of truth. It is only local
swarm control metadata: how to target workers, which issue source was
selected for the swarm, and whether bulk start is expected to be safe.

The internal delivery helper must use the manifest for target lookup. For
v1, if the manifest is missing, invalid, or does not contain the requested
worker, the helper must fail with a clear repair instruction instead of
guessing from tmux pane indices or cmux workspace names.

`add-worker.sh` and `restart-worker.sh` should read the manifest when one
exists for the active session, inherit `issueSource` / `issueDir`, update
worker entries as needed, and preserve the same swarm-scoped issue
backend. If they cannot update the manifest, they must at least export the
manifest's issue-source environment before launching the worker.

When `add-worker.sh` is run against a manifest-backed swarm, it is treated
as the user's explicit instruction to the manager to add and start one or
more workers. It must create each new worktree/pane/workspace, inherit the
manifest issue source, record the worker as `state: "paused"` first, and
then start the newly added worker through the same manifest-backed
delivery path used for idle worker starts.

When `add-worker.sh` is run without a manifest, it keeps existing
behavior and starts the worker immediately after launch.

When `restart-worker.sh` is run against a paused worker, it should
recreate/relaunch only the paused shell or agent REPL context needed for
that worker's `launchMode`; it must not send `WORKER_CMD` for a paused
worker. If the operator wants that worker to begin work after restart,
they should run `add-worker`. If the worker state was already
`started`, `restart-worker.sh` may preserve current behavior and send
`WORKER_CMD` after recreating the worker context.

Manifest updates must be serialized and atomic:

1. Acquire an exclusive `flock` on
   `.autocoder/swarm/<session-name>.lock` before any read-modify-write.
   Use a file descriptor lock, not "create lockfile and delete it"
   semantics, so the lock is released automatically if the process exits.
2. Re-read the manifest after acquiring the lock.
3. Write the new JSON to a temporary file in `.autocoder/swarm/`.
4. Validate the JSON.
5. Rename it over the old manifest.
6. Release the lock.

Lifecycle scripts should not leave partially written JSON behind.

### 6.3 Normal startup

Without `--paused`, behavior remains unchanged except that the effective
issue source environment is exported before worker and manager commands
are sent. For v1, normal startup does not write a swarm manifest.

### 6.4 Paused startup

With `--paused`, the launcher still does the setup work:

1. Validate mux and agent.
2. Create worker worktrees unless `--no-worktrees` is set.
3. Replicate `.agent` symlink where applicable.
4. Create worker panes/workspaces.
5. Export coordination environment variables.
6. Export issue source environment variables.
7. Launch the selected agent CLI in each worker when the selected agent has
   an interactive launch command.
8. Create the manager pane/workspace.
9. Launch the manager agent session only when the selected agent has an
   interactive launch command and the launcher has a no-submit way to show
   readiness instructions inside that agent UI.
10. Write or update the swarm manifest with state `paused`.

The launcher must not send the worker command:

- Claude: `/autocoder:fix-loop`
- Gemini: `/fix-loop`
- Codex: Codex issue-queue `/goal` or shell fallback
- Droid: `droid-fix-loop.sh`

The launcher must not send the manager command:

- Claude: `/autocoder:monitor-loop`
- Gemini: `/monitor-loop`
- Codex: manager `/goal` or shell fallback
- Droid: `droid-manage-workers-loop.sh`

### 6.5 Manager readiness instructions

In paused mode, the manager pane/workspace must show durable readiness
instructions without triggering autonomous work. The preferred behavior is:

1. Write the readiness instructions to
   `.autocoder/swarm/<session-name>.ready.txt`.
2. If a CLI supports no-submit paste or comment text, use that mode to
   display the agent-mode instructions inside the manager UI, set
   `manager.launchMode` to `interactive`, set `manager.agentLaunched` to
   `true`, and set `manager.readinessMode` to `agent-no-submit`.
3. If no no-submit display mechanism exists, leave the manager shell at a
   visible `cat .autocoder/swarm/<session-name>.ready.txt` command/output
   instead of launching the interactive manager agent immediately, set
   `manager.launchMode` to `shell`, set `manager.agentLaunched` to
   `false`, and set `manager.readinessMode` to `shell`.
4. Do not submit the readiness text as an ordinary chat prompt in paused
   mode. If no no-submit mechanism exists, leave the instructions visible
   in the manager shell instead.

No-submit display support must be resolved through a testable helper, not
hard-coded at call sites. The helper should expose a deterministic dry-run
result such as:

```bash
resolve_manager_readiness_mode "$AGENT"
# -> MANAGER_READINESS_MODE=agent-no-submit|shell
```

Initial v1 defaults may conservatively return `shell` for every agent
until a reliable no-submit mechanism is implemented and tested for that
CLI.

Agent-mode instructions should be:

```text
The autocoder swarm is ready and paused.

Workers have been launched and configured, but they are not pulling issues
yet.

Issue source: github
Session: codex-myproject

You can review issues, adjust priorities, unblock issues, or start workers.
Useful commands:
- /list-issues
- /review-blocked
- add-worker
- add-worker 2

When ready for continuous manager monitoring:
- /monitor-loop
```

Shell-mode instructions should be:

```text
The autocoder swarm is ready and paused.

Workers have been configured, but they are not pulling issues yet.
The manager agent was not launched because this CLI has no no-submit
readiness display mode.

Issue source: github
Session: codex-myproject
Readiness file: .autocoder/swarm/codex-myproject.ready.txt

From this shell you can start workers:
- add-worker
- add-worker 2

To review issues or run manager slash commands, launch the manager agent
manually in this pane, then use:
- /list-issues
- /review-blocked
- /monitor-loop
```

Agent-specific command names may vary, but the instructions must avoid starting
autonomous work.

For Codex, the readiness text must not use `/goal` so it does not create a
persistent objective that could be confused with worker dispatch.

For Droid, there is no interactive manager launch command in the current
shared launcher. Paused mode should still create the manager workspace or
pane and leave the readiness text visible in the shell. Starting Droid manager
automation later remains explicit via `droid-manage-workers-loop.sh` or
the existing monitor commands.

## 7. Worker-control command semantics

`add-worker` is the only user-facing command for starting or adding worker
capacity. It resolves the worker command using the same logic as
`worker-launch-lib.sh`, so the command sent to a pane/workspace stays
consistent with `restart-worker.sh` and the main launcher.

The command must load `.autocoder/swarm/<session-name>.json` when present.
If `--session` is omitted, infer the session from `--agent` and current
project name, matching the launcher convention `<agent>-<project>`.

The internal delivery helper must respect the worker's manifest
`commandMode`:

- For `commandMode: "agent-input"` workers, the issue-source environment
  must already have been exported before the agent REPL was launched
  during paused startup. The helper must not send shell `export` commands
  into these panes/workspaces because they would be typed into the agent
  UI.
- For `commandMode: "shell"` workers, the helper must send the
  manifest's issue-source environment before sending the worker command:

```bash
export ISSUE_SOURCE=github
```

or:

```bash
export ISSUE_SOURCE=file
export ISSUE_DIR_PATH=/absolute/path/to/.issues
```

or, for a configured custom backend:

```bash
export ISSUE_SOURCE=<custom>
export ISSUE_BACKEND=issues-<custom>.sh
```

This requirement applies even if the variables were exported during
paused startup for shell-mode workers. It makes later starts robust for
Droid and shell-loop fallbacks where `add-worker` may be the first command
that actually launches the worker process.

If an agent framework resolves to a shell worker command, such as a Codex
shell-loop fallback, the worker must be recorded as `launchMode: "shell"`,
`commandMode: "shell"`, and `agentLaunched: false`; the launcher must not
start the interactive agent REPL in that worker during paused startup.

For tmux:

- Identify the swarm session.
- Prefer the worker's `tmuxTarget` from the manifest.
- Do not infer worker targets from pane index when the manifest is missing.

For cmux:

- Prefer the worker's `cmuxWorkspace` from the manifest.
- Do not infer worker targets from workspace names when the manifest is
  missing.

The script should print exactly which workers it sent commands to and
update the manifest worker state based on command delivery. For v1,
`started` means the command was successfully sent to the target
pane/workspace; it does not prove that the agent accepted the command,
claimed an issue, or began useful work. Deeper health checks remain the
responsibility of existing worker-monitoring commands.

`add-worker` start safety:

- If the manifest exists and has paused workers, `add-worker [count]`
  starts up to `count` paused workers before creating any new workers.
- If the manifest is missing or invalid, fail with a clear repair
  instruction only for the internal helper; `add-worker` without a
  manifest preserves existing add-and-start behavior.
- If all idle workers have already been started, `add-worker [count]`
  creates and starts enough additional workers to satisfy the requested
  count.

Partial failure handling:

- Update each worker state independently after command delivery succeeds
  or fails.
- Set swarm state to `running` only if the command is successfully sent to
  every targeted worker.
- Set swarm state to `partial` if command delivery succeeds for at least
  one targeted worker and fails for at least one targeted worker.
- Leave swarm state `paused` if no targeted worker receives the command.
- Print failed worker numbers and the failing target identifiers.

## 8. Installation and documentation

Update installers to link the user-facing command:

```bash
~/.local/bin/add-worker -> plugins/autocoder/scripts/add-worker.sh
```

Update:

- `plugins/autocoder/scripts/start-parallel-agents.sh --help`
- `plugins/autocoder/README.md`
- `plugins/autocoder/commands/autocoder-help.md`
- Codex and Droid install scripts
- Claude plugin install command docs
- Agent-specific command docs for Claude, Gemini, Codex, and Droid

## 9. Acceptance criteria

1. `start-parallel-agents.sh --help` documents `--paused`,
   `--no-start`, `--issue-source`, and `--issue-dir`.
2. `start-parallel 3 --issue-source github --paused` creates the normal
   swarm layout and exports `ISSUE_SOURCE=github`.
3. In paused mode, worker panes/workspaces launch the agent CLI when the
   selected agent has an interactive launch command, but do not receive the
   worker loop command.
4. In paused mode, the manager pane/workspace is created, does not receive
   the monitor loop command, and launches the manager agent only for
   agents with an interactive launch command when readiness instructions
   can be displayed without submitting a chat prompt.
5. In paused mode, the manager pane/workspace displays readiness
   instructions without submitting them as an autonomous chat prompt.
6. `add-worker` starts existing idle worker panes/workspaces before
   creating new worker capacity.
7. `add-worker 2` starts or adds/starts two workers.
8. Existing non-paused loop delivery behavior is unchanged when an effective
   issue source can be resolved; if no CLI, configured, or fallback
   environment source exists, startup fails before creating swarm resources.
9. `--issue-dir` without `--issue-source file` fails with a usage error.
10. `--issue-source file` resolves `ISSUE_DIR_PATH` to an absolute path.
11. Paused startup is verified for `--agent claude`, `--agent gemini`,
    `--agent codex`, and `--agent droid`.
12. `add-worker` supports `--agent claude`, `--agent gemini`,
    `--agent codex`, and `--agent droid`.
13. Codex paused startup never sends a `/goal` prompt to the manager.
14. Droid paused startup does not accidentally start
    `droid-fix-loop.sh`.
15. A paused swarm writes a manifest with session, mux, agent, issue
    source, manager target, and worker targets.
16. `add-worker.sh` and `restart-worker.sh` preserve the manifest's issue
    source when operating on a swarm with a manifest.
17. The internal delivery helper fails when no paused manifest exists.
18. The internal delivery helper records partial failures by setting workers with
    successful command delivery to `started`, failed deliveries to
    `failed`, and swarm state to `partial`.
19. Paused manager readiness instructions are written to
    `.autocoder/swarm/<session-name>.ready.txt` and remain visible without
    submitting a manager chat prompt.
20. Manifest read-modify-write operations are serialized with a
    per-session `flock` file descriptor lock.
21. The manifest records worker `launchMode`, `commandMode`, and
    `agentLaunched`, and the internal helper uses `commandMode` to decide
    whether shell env exports are safe.
22. The manifest records manager `launchMode`, `agentLaunched`, and
    `readinessMode`.
23. Shell-mode and agent-mode readiness instructions are distinct, and
    shell-mode instructions do not present slash commands as directly
    runnable shell commands.
24. `started` worker state means command delivery succeeded, not that the
    agent accepted the command or claimed work.
25. The internal helper fails instead of guessing targets when the paused
    swarm manifest is missing or invalid.
26. Normal non-paused startup does not write a swarm manifest in v1.
27. The manifest records `manager.readyFile`.
28. `worker-launch-lib.sh` resolves `WORKER_LAUNCH_MODE`,
    `WORKER_COMMAND_MODE`, and `MANAGER_LAUNCH_MODE`, and all lifecycle
    scripts use those values.
29. Normal non-paused swarms document that per-run issue-source continuity
    is not preserved for later add/restart lifecycle commands in v1.
30. `add-worker.sh` starts existing paused workers first; it creates and
    starts new worker capacity only when requested count exceeds idle
    capacity.
31. Manager readiness mode is resolved by a testable helper and can be
    dry-run without launching an agent.
32. Effective issue-source resolution is read-only: launcher option
    parsing never creates or mutates `.autocoder.json`.
33. The manifest records `issueSourceOrigin` as `cli`, `configured`, or
    `environment`.
34. `restart-worker.sh` does not send `WORKER_CMD` for a worker whose
    manifest state is `paused`; the operator starts that worker later with
    `add-worker`.
35. `ISSUE_SOURCE=file` from the environment still resolves an absolute
    `ISSUE_DIR_PATH` before any swarm resources are created.
36. When `--issue-source` is omitted, the launcher uses the main worktree
    `.autocoder.json` issue source as the project's last-used source before
    consulting exported environment variables.
37. The internal helper uses a locked `starting` transition so concurrent
    invocations cannot double-send `WORKER_CMD` to the same worker.
38. tmux manifest targets use stable pane IDs, not pane indexes.
39. Configured custom issue backends remain usable when `--issue-source` is
    omitted; the resolver carries `ISSUE_BACKEND` into worker and manager
    contexts and records it in the manifest.

## 10. Test plan

Add focused tests around argument parsing and generated commands where
possible. Because tmux and cmux integration is host-dependent, the first
implementation can use shell-level dry-run seams if the launcher is
factored enough to test without creating real sessions.

Minimum automated checks:

1. Help text includes the new options.
2. Invalid issue-source values fail.
3. `--issue-dir` without file issue source fails.
4. Paused mode skips sending worker and manager loop commands.
5. Non-paused mode still sends worker and manager loop commands.
6. Issue-source env exports are produced for workers and manager.
7. Agent matrix tests verify launch/start commands for Claude, Gemini,
   Codex, and Droid.
8. Manifest creation records worker targets and issue-source settings.
9. `add-worker` starts idle manifest workers before creating new workers,
   and its internal helper reads worker targets, `commandMode`, and
   issue-source settings from the manifest.
10. `add-worker.sh` and `restart-worker.sh` inherit issue-source settings
    from the manifest.
11. The internal helper refuses unsafe duplicate starts without `--yes`.
12. The internal helper sends manifest issue-source exports before worker
    start commands only for `commandMode: "shell"` workers.
13. Manifest updates are atomic and represent partial worker-start
    failures accurately.
14. Paused manager readiness writes and displays the `.ready.txt` file
    without submitting it as a chat prompt.
15. Concurrent lifecycle script invocations do not lose manifest updates
    because they serialize on the per-session lock.
16. Manifest locking uses `flock` on a file descriptor.
17. Manager manifest fields record shell-mode vs agent-no-submit readiness.
18. Tests assert that worker `started` state is driven by successful command
    delivery and that failed command delivery records worker `failed`.
19. Tests assert that `add-worker` without a manifest preserves existing
    add-and-start behavior.
20. Tests assert normal non-paused startup does not write a manifest.
21. Tests assert `worker-launch-lib.sh` returns launch and command modes
    for Claude, Gemini, Codex, and Droid, including Codex shell fallback.
22. Tests assert `add-worker.sh` adds a paused worker without sending
    `WORKER_CMD` when the swarm manifest state is `paused`.
23. Tests assert manager readiness mode resolution can be dry-run and
    defaults to `shell` when no no-submit support is known.
24. Tests assert issue-source resolution precedence:
    CLI option > configured `.autocoder.json` > exported environment.
25. Tests assert issue-source resolution fails before resource creation
    when no source exists and does not write `.autocoder.json`.
26. Tests assert `restart-worker.sh` recreates paused worker context
    without sending `WORKER_CMD`.
27. Tests assert environment-origin `ISSUE_SOURCE=file` resolves
    `ISSUE_DIR_PATH` from the environment, configured `issueDir`, or the
    main worktree default in that order.
28. Tests assert concurrent start attempts do not double-send
    `WORKER_CMD`.
29. Tests assert tmux manifests record stable pane IDs.
30. Tests assert configured custom issue sources preserve `ISSUE_BACKEND`.
31. Tests assert tmux/cmux send-helper timeouts become delivery failures and
    do not block manifest-lock progress indefinitely.
32. Tests assert stale `starting` recovery uses the 5-minute default
    threshold and requires `--yes`.

Manual smoke tests:

```bash
start-parallel 2 --mux tmux --agent claude --issue-source github --paused
start-parallel 2 --mux tmux --agent gemini --issue-source github --paused
start-parallel 2 --mux tmux --agent codex --issue-source github --paused
start-parallel 2 --mux tmux --agent droid --issue-source github --paused
MANIFEST=".autocoder/swarm/codex-$(basename "$PWD").json"
WORKER1=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["workers"][0]["tmuxTarget"])' "$MANIFEST")
MANAGER=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["manager"]["tmuxTarget"])' "$MANIFEST")
tmux capture-pane -t "$WORKER1" -p
tmux capture-pane -t "$MANAGER" -p
add-worker --mux tmux --agent codex
add-worker 2 --mux tmux --agent codex
```

## 11. Implementation plans

### Plan A: Shared resolution and state libraries

Purpose: build the low-risk foundation before touching mux delivery logic.

Files:

- `plugins/autocoder/scripts/worker-launch-lib.sh`
- New `plugins/autocoder/scripts/issue-source-lib.sh`
- New `plugins/autocoder/scripts/swarm-manifest-lib.sh`

Work:

1. Extend `worker-launch-lib.sh` to resolve worker launch mode, worker
   command mode, manager launch command, manager command, and manager launch
   mode for Claude, Gemini, Codex, and Droid.
2. Add a read-only issue-source resolver with this precedence:
   `--issue-source` / `--issue-dir`, configured `.autocoder.json` from the
   main worktree, then exported environment as a compatibility fallback.
   This makes omitted `--issue-source` mean "use whatever issue source this
   project used last."
3. Add manifest helpers for path resolution, JSON validation, atomic writes,
   and file-descriptor `flock` locking.
4. Keep helpers shell-callable and dry-run friendly so tests can assert
   resolved variables without creating tmux/cmux sessions.
5. Define launcher dry-run seams before refactoring mux code. At minimum,
   command delivery should pass through wrapper functions such as
   `send_tmux_command`, `send_cmux_command`, and `create_manifest`, so tests
   can capture intended commands without starting real sessions.
6. Keep helper APIs backward-compatible for existing callers: preserve
   `AGENT_LAUNCH_CMD` and `WORKER_CMD`, return nonzero on unknown agents,
   and avoid unexpected stdout in helper resolution paths.
7. Send helpers must be timeout-wrapped. Use a default 15-second timeout for
   each tmux/cmux send or target-validation operation, expose
   `AUTOCODER_MUX_TIMEOUT_SECONDS` as the single override, and record a
   timeout as command-delivery failure instead of blocking while holding a
   manifest lock. Do not depend on GNU `timeout`, which is not guaranteed on
   macOS; implement the timeout in portable shell/Python or detect and use
   `gtimeout` only as an optional acceleration.
8. Add a portable stale-state age helper for `stateUpdatedAt`. It should use
   Python timestamp parsing or another repo-supported portable path, not
   platform-specific `date -d` / `date -j` branches at call sites.

Exit criteria:

- Helper tests cover all four agent technologies.
- Helper tests cover CLI, environment, configured, and missing issue-source
  cases, including configured project source taking precedence over exported
  `ISSUE_SOURCE`.
- Manifest helper tests prove invalid JSON is rejected and atomic writes
  do not leave partial files.
- Send-helper tests prove timeout exits are treated as delivery failures.
- Stale-age helper tests cover the 5-minute threshold without depending on
  GNU date behavior.

Rollback:

- These helpers are additive until callers are migrated. If a regression is
  found, callers can remain on their existing inline logic while helper
  behavior is fixed.

### Plan B: Paused startup in `start-parallel`

Purpose: add `--paused`, `--no-start`, `--issue-source`, and `--issue-dir`
without changing normal worker and manager loop delivery once startup has
resolved the effective issue source.

Files:

- `plugins/autocoder/scripts/start-parallel-agents.sh`
- New helper files from Plan A

Work:

1. Parse the new flags and resolve the effective issue source before any
   worktrees, sessions, panes, or workspaces are created. If no CLI source
   is supplied, use the main worktree `.autocoder.json` last-used source.
2. Refactor agent command resolution to call `worker-launch-lib.sh`.
3. Export coordination and issue-source environment into all worker and
   manager contexts.
4. In non-paused mode, preserve existing behavior and send worker and
   manager loop commands.
5. In paused mode, create the same layout, launch worker agent REPLs only
   when `WORKER_LAUNCH_MODE=interactive`, skip all worker loop commands,
   create the manager context, write `.ready.txt`, and avoid submitting any
   manager prompt.
6. For tmux, record stable pane IDs from `tmux display-message -p
   '#{pane_id}'` or `tmux list-panes -F '#{pane_id}'` after each worker and
   manager pane is created; do not record pane-index targets as the durable
   identity.
7. Write the paused swarm manifest only after targets are known. If a
   later setup step fails, record no successful paused manifest unless it
   accurately describes the resources that exist.

Exit criteria:

- Existing non-paused dry-run expectations remain unchanged for projects
  with a configured or otherwise resolvable issue source.
- Paused dry-run output shows no worker loop command and no manager loop
  command.
- Paused manifest contains session, mux, agent, issue source, target refs,
  launch modes, command modes, manager readiness fields, and worker states.
- Omitting `--issue-source` uses the project's configured last-used source
  and does not mutate `.autocoder.json`.

Rollback:

- The new flags and the new issue-source preflight can be disabled by
  failing fast at parse time and returning to the previous startup path while
  leaving non-paused loop delivery untouched.

### Plan C: Delayed worker start commands

Purpose: provide the explicit operator control surface for starting paused
workers.

Files:

- Internal `plugins/autocoder/scripts/start-workers.sh`
- `plugins/autocoder/scripts/add-worker.sh`

Work:

1. Keep manifest-safe command delivery in the internal helper.
2. Require a valid paused-swarm manifest for all v1 targeting. Do not infer
   targets from tmux pane indices or cmux workspace names.
3. Acquire the per-session manifest lock before selecting target workers,
   and hold it through state transition and command delivery. Mark selected
   workers `starting` with a `stateUpdatedAt` timestamp before sending any
   command so concurrent start attempts cannot double-send
   `WORKER_CMD`.
4. Validate recorded tmux/cmux targets before sending commands.
5. For `commandMode=agent-input`, send only `WORKER_CMD`.
6. For `commandMode=shell`, send manifest issue-source exports before
   `WORKER_CMD`.
7. Update worker states independently and set swarm state to `running`,
   `partial`, or leave it `paused` according to delivery results.
8. On a later invocation, treat an existing `starting` worker as in-flight
   and refuse to start it unless the operator passes `--yes` and the
   `stateUpdatedAt` timestamp is older than 5 minutes. Stale recovery should
   mark the old attempt `failed` before retrying. Expose
   `AUTOCODER_STARTING_STALE_SECONDS` as an override, defaulting to `300`.
9. Never hold the manifest lock across an unbounded external command. Every
   tmux/cmux send and validation operation must use the send-helper timeout
   from Plan A.

Exit criteria:

- `add-worker` starts one idle worker before adding new capacity.
- `add-worker 2` starts two idle workers when available; if fewer than two
  are idle, it adds and starts the remainder.
- Missing, invalid, stale, or mismatched manifests fail closed with a repair
  message.
- Concurrent start attempts do not double-start the same
  worker.
- Interrupted start attempts leave recoverable `starting`
  state rather than permanently blocking the worker.
- Hung tmux/cmux sends time out and mark affected workers `failed` or leave
  them recoverable, without blocking other lifecycle commands indefinitely.

Rollback:

- The command can refuse to start workers if manifest validation is too
  strict; this is preferable to sending work commands to the wrong pane.

### Plan D: Lifecycle integration

Purpose: keep added and restarted workers consistent with the paused swarm
contract.

Files:

- `plugins/autocoder/scripts/add-worker.sh`
- `plugins/autocoder/scripts/restart-worker.sh`
- New helper files from Plan A

Work:

1. Define active-manifest lookup exactly: resolve the main worktree with
   `git worktree list --porcelain`, derive the project name from that main
   worktree, derive or accept `--session`, and look for
   `.autocoder/swarm/<session>.json` in the main worktree.
2. Make `add-worker.sh` read the active manifest when present and inherit
   issue source, mux, agent, task list, and integration branch.
3. When the swarm manifest has paused workers, start them before creating
   new worker capacity.
4. When new capacity is needed, add the new worker as `state=paused` and
   immediately start it through the internal manifest-backed helper.
5. Make `restart-worker.sh` update or preserve the manifest entry for the
   restarted worker.
6. When a worker manifest state is `paused`, recreate only the shell or
   agent REPL context and do not send `WORKER_CMD`.
7. When a worker manifest state is `started`, preserve existing restart
   behavior and resume the worker loop.

Exit criteria:

- Adding workers to a paused swarm starts existing idle workers first.
- Restarting a paused worker never starts issue work.
- Added/restarted workers preserve the manifest issue source.
- Lifecycle scripts behave the same whether invoked from the main worktree
  or a worker worktree.

Rollback:

- If lifecycle manifest updates are risky, keep the existing non-manifest
  behavior for swarms without a paused manifest and fail closed for paused
  manifests until the update path is fixed.

### Plan E: Installation, help, and documentation

Purpose: expose the feature through installed commands and keep user-facing
docs aligned with the `start-parallel` surface.

Files:

- Installer scripts for Codex/Droid and plugin install docs
- `plugins/autocoder/scripts/start-parallel-agents.sh --help`
- `plugins/autocoder/commands/autocoder-help.md`
- `plugins/autocoder/README.md`

Work:

1. Link `add-worker` to `add-worker.sh` in every installer path:
   `/install`, `scripts/install-codex.sh`, `scripts/install-droid.sh`,
   and any plugin install command docs.
2. Update installer "already installed" checks so an older installation
   missing `add-worker` is treated as incomplete and relinked.
3. Document `start-parallel [num_workers] [options]` as the primary entry
   point.
4. Document `--paused`, `--no-start`, `--issue-source`, `--issue-dir`,
   `--mux`, `--agent`, and `--no-worktrees`.
5. Keep aliases out of the primary README flow; users can define their own
   aliases locally.
6. Update `autocoder-help.md` to present `start-parallel` and `add-worker`
   first; aliases may be mentioned only as optional user-created
   conveniences.
7. Mention that `--paused`, `--issue-source`, and `--issue-dir` are
   unavailable until the implementation lands if docs are published before
   code.

Exit criteria:

- Help text and README agree on command names and supported options.
- No user-facing docs direct operators to legacy alias names as the primary
  workflow.
- Fresh and previously installed environments receive the `add-worker`
  symlink.

Rollback:

- Documentation for planned flags can be marked "planned" if code delivery
  is delayed.

### Plan F: Validation sequence

Purpose: keep implementation testable despite tmux/cmux integration being
host-dependent.

Stages:

1. After Plan A: unit-style shell tests for helpers, option parsing,
   launch-mode resolution, issue-source precedence, and manifest atomicity.
2. After Plan B: dry-run integration tests for generated tmux/cmux commands,
   including paused and non-paused startup.
3. After Plan C: manifest locking, concurrent internal starts, stale
   `starting` recovery at the 5-minute threshold, send timeout handling,
   target validation, large-enough multi-worker batches to exercise bounded
   lock duration, and partial-delivery tests.
4. After Plan D: lifecycle tests for `add-worker.sh` and
   `restart-worker.sh` from both main and worker worktrees.
5. After Plan E: installer/help/docs checks that verify command links and
   command names. Installer tests should use isolated temporary `HOME`,
   `PATH`, and install directories so they can verify fresh and stale
   installations without mutating the operator's real shell config.
6. Manual smoke tests for Claude, Gemini, Codex, and Droid across tmux;
   cmux smoke tests where cmux is available.
7. Full regression with `bash plugins/autocoder/scripts/regression-test.sh`
   before marking implementation complete.

Exit criteria:

- Automated checks cover the spec's no-start invariant: paused startup,
  paused add-worker, and paused restart never send `WORKER_CMD`.
- Manual smoke confirms the manager readiness file is visible and no
  monitor loop starts automatically.
- Each implementation plan has an automated test gate before proceeding to
  the next plan.

## 12. Critical design review

### Finding 1: Environment-only issue source may be too invisible

Per-run env overrides avoid mutating `.autocoder.json`, which is the right
default. The downside is observability: once a pane has launched, the
operator may not know whether it is using the configured backend or an
override.

**Mitigation:** The launcher and manager readiness instructions must print
the active issue source. The swarm manifest must record `issueSource`,
`issueSourceOrigin`, and `issueDir`, and lifecycle scripts must inherit
those values for added, restarted, or later-started workers.

### Finding 2: Submitted manager text might still trigger agent action

Some agents may interpret a descriptive prompt as something to act on. The
manager instructions explicitly say the swarm is paused, but they also mention
review commands and `/monitor-loop`.

**Mitigation:** Keep the text informational and avoid imperatives like
"review issues now." Prefer shell-visible instructions before launching
the manager agent, or a no-submit paste/comment mechanism if the CLI
supports one. For Codex, do not use `/goal`.

### Finding 3: `start-workers` can accidentally double-start active workers

If a user runs `start-workers` against an already active swarm, sending a
second `/fix-loop` or `/goal` into an agent may create confusing nested
work. The control script cannot reliably infer whether every agent is idle
from terminal contents.

**Mitigation:** `start-workers` should use the manifest's paused/running
state. Bulk start is allowed without confirmation only when the manifest
says the swarm is paused. Otherwise require `--yes`.

### Finding 4: tmux pane index is a weak worker identity

The current launcher maps worker N to pane index N-1. That holds at
initial creation time, but users can split, kill, or reorder panes. A
later `start-worker 2` may target the wrong pane if the session was
manually modified.

**Mitigation:** Store tmux pane targets in the swarm manifest at startup.
For paused worker start, do not fall back to pane-index targeting when the
manifest is missing or invalid. Print target pane IDs before sending
commands.

### Finding 5: cmux workspace discovery depends on names

cmux control relies on workspace names like `wt2-<project>`. Users can
rename workspaces, and duplicate project names can collide.

**Mitigation:** Store cmux workspace refs in the swarm manifest at
startup. For paused worker start, do not fall back to name-based discovery
when the manifest is missing or invalid. Print discovered targets and fail
if no exact match is found.

### Finding 6: Agent command resolution is duplicated today

`start-parallel-agents.sh` has its own agent command resolution, while
`add-worker.sh` and `restart-worker.sh` use `worker-launch-lib.sh`.
Adding `start-workers` increases the cost of duplication if the main
launcher is not refactored.

**Mitigation:** `start-workers` must use `worker-launch-lib.sh`. The main
launcher should either reuse the same helper or be refactored in a small
follow-up. Do not add a third copy of the Codex worker `/goal` string.

### Finding 7: Paused mode is ambiguous for Droid

The Droid path currently has an empty `AGENT_LAUNCH_CMD` and starts work
through shell scripts. If paused mode skips the worker command, there may
be no interactive agent process in worker workspaces.

**Mitigation:** Document that Droid paused mode creates workspaces and
manager context but does not launch a worker process until `start-worker`
or `start-workers` is run. Generic paused-startup and acceptance criteria
must say "launch the agent CLI when the selected agent has an interactive
launch command." This preserves the "do not pull tickets" contract.

### Finding 8: "Manager session" does not mean the same thing for all agents

Claude, Gemini, and Codex have interactive manager sessions in the current
launcher. Droid's launcher path is script-based and does not currently
start an interactive `droid` REPL. A requirement that "the manager session
should be created" is therefore technology-dependent.

**Mitigation:** Define the portable requirement as: create the manager
pane/workspace and make paused-swarm readiness visible there. For agents
with interactive launch commands, launch the agent and show readiness
instructions. For Droid, leave the manager workspace ready with shell-visible
instructions unless a future Droid interactive mode is added.

### Finding 9: The manager may not have shell command access

The spec says the manager has commands such as `start-workers`. In some
agent CLIs, the manager may not automatically execute shell commands from
inside the chat without user confirmation or tool support.

**Mitigation:** The commands are terminal commands available in the same
environment, not slash commands. The instructions should phrase them as shell
commands. Users can run them from the manager session if their agent
supports shell execution, or from another terminal.

### Finding 10: Manifest adds local state that can drift

The design now relies on a local manifest for issue-source continuity,
worker targeting, and paused/running state. That state can drift if users
manually kill panes, rename cmux workspaces, or edit worktrees.

**Mitigation:** Treat the manifest as control metadata, not truth about
issue ownership. Before sending commands, validate that the recorded
tmux/cmux target still exists. If validation fails, fail closed with a
clear repair instruction rather than rediscovering a target that may not
have the same agent state or issue-source environment. Serialize manifest
updates with a per-session lock, write them atomically, and model partial
worker-start failures explicitly with swarm state `partial` and worker
state `failed`.

### Finding 11: Adjacent lifecycle scripts may not cover all agents equally

`start-parallel-agents.sh` accepts `claude`, `gemini`, `codex`, and
`droid`, but older helper scripts and documentation are less uniform. For
example, join/stop helpers historically focused on Claude and Gemini
first, with Codex/Droid added later in some places.

**Mitigation:** The implementation must treat the four-agent matrix as an
acceptance target. Where the paused-swarm feature touches installation,
help text, or worker-control scripts, update all four agent paths or call
out the remaining gap explicitly.

### Finding 12: Reusing `issue-config.sh` directly can mutate configuration

`issue-config.sh` is designed to bootstrap missing issue configuration,
including interactive prompts that can write `.autocoder.json`. That is
correct for setup, but wrong for a per-run launcher option whose contract
is not to mutate persistent configuration.

**Mitigation:** Use a read-only resolver for launcher and lifecycle
scripts. It may reuse config parsing, but it must never enter interactive
setup and must fail before resource creation when no effective issue
source can be resolved.

### Finding 13: Restarting a paused worker can accidentally start work

The earlier wording allowed a paused worker restart to send `WORKER_CMD`
when the operator "explicitly asks to resume work," but did not define a
flag or command path. That creates an implementation trap where
`restart-worker.sh` grows an implicit second start surface.

**Mitigation:** Keep `restart-worker.sh` scoped to recreation. Paused
workers remain paused after restart; `start-worker <number>` is the only
v1 command that starts a paused worker.

### Finding 14: Environment-origin file backends can be incomplete

An exported `ISSUE_SOURCE=file` without `ISSUE_DIR_PATH` is not enough for
workers, because file-backed issue commands require the directory path. If
paused startup writes that incomplete state to the manifest, later
`start-worker(s)` could send a command that fails after the swarm has
already been created.

**Mitigation:** Treat file issue directory resolution as part of effective
source resolution. Resolve it from exported `ISSUE_DIR_PATH`, configured
`issueDir`, or the main worktree `.issues` default before creating
resources, then write only the absolute result to the manifest.

### Finding 15: Manifest locks can become command-delivery bottlenecks

`start-worker(s)` needs to hold the manifest lock long enough to prevent
duplicate starts. If the implementation also waits indefinitely on tmux or
cmux while holding that lock, one hung mux operation can block every later
lifecycle command for the session.

**Mitigation:** Route every tmux/cmux send and target validation through
timeout-wrapped helpers. Default each mux operation timeout to 15 seconds,
allow `AUTOCODER_MUX_TIMEOUT_SECONDS` as the single override, and record
timeout as command-delivery failure.

### Finding 16: `starting` state needs deterministic recovery

Adding `starting` prevents duplicate worker starts, but a process that dies
after writing `starting` and before writing `started` or `failed` can leave
a worker apparently in flight forever.

**Mitigation:** Require `stateUpdatedAt` on `starting`; treat it as in
flight until it is older than 5 minutes; allow `--yes` to recover stale
`starting` workers by first marking the old attempt `failed`, then retrying.
Expose `AUTOCODER_STARTING_STALE_SECONDS` only as an override.

### Finding 17: Rollback must cover source preflight, not only new flags

The feature now resolves an effective issue source before creating swarm
resources. That is desired because omitted `--issue-source` should reuse
the project's last-used backend, but it is broader than just accepting new
CLI flags.

**Mitigation:** The rollback plan must explicitly allow disabling the
issue-source preflight path and returning to the previous startup path,
while keeping normal non-paused worker and manager loop delivery intact.

### Finding 18: Timeout and stale-age helpers can become nonportable

The repo targets macOS-heavy workflows through cmux and local shell
installers. GNU `timeout` and GNU `date -d` are not guaranteed there, so a
plan that relies on them would make the most important safety checks
fragile on the primary operator platform.

**Mitigation:** Implement timeout wrapping and stale-age calculations in a
portable helper layer. Prefer repo-supported shell/Python helpers, avoid
platform-specific date parsing at call sites, and use `gtimeout` only as an
optional acceleration when present.

## 13. Recommended implementation stance

Proceed with a conservative v1:

1. Add CLI parsing and env exports to the existing launcher.
2. Add a read-only issue-source resolver with deterministic precedence:
   CLI option, configured `.autocoder.json` from the main worktree, then
   exported environment as a compatibility fallback.
3. Add a minimal swarm manifest for session, targets, issue source, and
   paused/running state.
4. Add paused-mode branching that skips worker and manager loop commands.
5. Display manager readiness instructions without triggering autonomous
   work.
6. Add an internal `start-workers.sh` helper using `worker-launch-lib.sh`
   and the manifest.
7. Record each worker's `launchMode`, `commandMode`, and `agentLaunched`
   state, and have the internal helper export manifest issue-source settings
   only when `commandMode` is `shell`.
8. Extend `worker-launch-lib.sh` so all lifecycle scripts share launch
   and command mode resolution.
9. Update `add-worker.sh` and `restart-worker.sh` to inherit manifest
   issue-source settings.
10. Link `add-worker` in installers.
11. Update docs and help text.

Do not add a scheduling layer in the first implementation. The manifest is
small local control metadata, not a broader orchestration system.
