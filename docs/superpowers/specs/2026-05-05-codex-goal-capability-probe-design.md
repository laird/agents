# Codex /goal Capability Probe Design

**Version:** 1.0
**Status:** Approved

## Overview

Codex 0.128.0 introduced `/goal` (persistent long-horizon agent loops) but ships with the feature disabled by default (`goals: under development  false`). Issue #20591 reports the slash command fails to initialize in this state. This design adds a runtime capability probe so our scripts and TUI automatically use `/goal` when available and fall back to the shell loop when not.

## Requirements & Goals

- Workers and managers use `/goal` when `codex features list` shows `goals` as `true`
- Fall back to `codex-fix-loop.sh` / `codex-manage-workers-loop.sh` when `goals` is `false`
- Probe runs once per Codex version per machine (cached), not on every agent launch
- No manual configuration — self-corrects when OpenAI ships the fix and `goals` flips to `true`
- Both `start-parallel-agents.sh` (shell) and `agents-ui` (Rust TUI) use the same probe logic

## Out of Scope

- Fixing the upstream Codex bug (OpenAI's responsibility, already reported)
- Workaround for issue #20792 (sessions not in resume list) — agents-ui manages sessions via tmux targets, not Codex's resume picker, so this bug does not affect our use case
- Supporting Codex versions below 0.128.0 (no `/goal` command at all)

## Proposed Architecture

### Probe Script: `scripts/probe-codex-goals.sh`

A standalone shell script that:
1. Runs `codex features list`
2. Greps for `^goals` and checks whether the third field is `true`
3. Caches the result in `/tmp/codex-goals-probe-<version>` where `<version>` is the output of `codex --version`
4. Exits 0 if `/goal` is available, 1 if not

Cache key includes the Codex version so the probe re-runs automatically after `codex update`.

### `start-parallel-agents.sh` change

In the `codex)` branch, after setting `AGENT_LAUNCH_CMD="codex"`, call the probe:

```bash
if bash "$AGENTS_REPO_ROOT/scripts/probe-codex-goals.sh"; then
  WORKER_CMD="/goal Work the issue queue: ..."
  MANAGER_CMD="/goal Monitor and coordinate workers: ..."
else
  echo "⚠️  Codex /goal not available — using shell loop fallback"
  WORKER_CMD="bash '$AGENTS_REPO_ROOT/scripts/codex-fix-loop.sh'"
  MANAGER_CMD="bash '$AGENTS_REPO_ROOT/scripts/codex-manage-workers-loop.sh'"
fi
```

### `agents-ui` change

**`Swarm` struct** (`src/model/swarm.rs`): add `codex_goal_supported: bool` field, defaulting to `false`. Populated at launch time.

**`ClaudeAdapter::launch()`** (`src/adapter/claude.rs`): before sending the worker loop command, run the probe via `Command::output` on `probe-codex-goals.sh`. Store result in `swarm.codex_goal_supported`.

**`ClaudeAdapter::start_worker_loop()`**: check `swarm.codex_goal_supported` (looked up from the swarm the agent belongs to). If true, send `agent_type.worker_loop_cmd()` (the `/goal` string). If false, send the shell loop fallback command.

The `worker_loop_cmd()` and `manager_cmd()` methods on `AgentType` remain unchanged — they return the canonical `/goal` strings. The adapter decides whether to use them.

## Key Trade-offs

- **Probe cost**: `codex features list` is fast (local config read, no network). With caching, only one invocation per version per machine.
- **Cache staleness**: Cache key is the Codex version string, so updating Codex invalidates the cache automatically. No manual cache clearing needed.
- **Probe script as shared dependency**: Both shell and Rust paths call the same script. This means agents-ui requires the probe script to be on disk at a known path. The script is resolved via the same `launcher.rs` path-resolution logic already used for `start-parallel-agents.sh`.

## Files Changed

| File | Change |
|---|---|
| `scripts/probe-codex-goals.sh` | New — probe script with caching |
| `plugins/autocoder/scripts/start-parallel-agents.sh` | Call probe, set WORKER_CMD/MANAGER_CMD conditionally |
| `src/model/swarm.rs` | Add `codex_goal_supported: bool` to `Swarm` |
| `src/adapter/claude.rs` | Run probe at launch, use result in `start_worker_loop` |

## Success Criteria

- `startcc 2` in a repo with Codex 0.128.0 (goals=false) launches workers using the shell loop
- After `codex features enable goals` (or a future patch flips it), `startcc 2` uses `/goal` without any code change
- agents-ui swarm launch behaves identically to the script
- Probe result is cached: running `startcc` twice in a row only calls `codex features list` once
