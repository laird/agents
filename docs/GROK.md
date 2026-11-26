# Grok

Grok CLI (`grok`, verified on 1.0.92) installs this repository's **Claude Code**
marketplace. Codex, Pi, Droid, and Antigravity keep their own packages. There
is no second copy of the plugins.

Source: Grok's marketplace loader checks `.grok-plugin/marketplace.json` first
and then `.claude-plugin/marketplace.json`
(`xai-grok-plugin-marketplace` `load_index`). This repo ships only the Claude
file, which is the catalog below.

## Install

```bash
grok plugin marketplace add laird/agents
grok plugin install autocoder --trust
grok plugin install modernize --trust
```

`--trust` is required. It enables the plugin and allows its hooks to run.
Start a new session afterwards. In that session:

| Command | What it is |
|---|---|
| `/fix`, `/fix-loop`, `/stop-loop`, `/monitor-loop`, `/monitor-workers` | autocoder |
| `/assess`, `/plan`, `/modernize` | modernize |

`/plan` is also a Grok builtin, so modernize's plan command is `/modernize:plan`.
`/retro` exists on both plugins, so it is `/autocoder:retro` or `/modernize:retro`.

Each plugin has `plugins/<name>/.grok-plugin/plugin.json`. That file is what
makes the install name `autocoder` instead of `autocoder-<hash>`. Grok reads
it; Claude Code does not. The version matches the Claude marketplace entry.

## Loops

`/fix-loop` and `/monitor-loop` do not use a Stop hook on Grok.

Grok's `/loop` is the `scheduler_create` tool. Each fire is a detached
background subagent. `/fix-loop` schedules `${LOOP_TARGET}` (`/autocoder:gate`,
or `/autocoder:dispatch` when model split is on) with `durable: true`.
`/monitor-loop` runs one check in the current session, then schedules
`/autocoder:monitor-workers`. `/stop-loop` calls `scheduler_delete` on those
jobs and removes `.grok/autocoder-loops.json`.

A Stop hook is the wrong loop here. Grok will keep a turn going for at most
8 Stop-hook continuations, then it ends the turn
([Stop Decision Control](https://docs.x.ai/build/features/hooks)). An idle
sleep inside the hook is also cut off at the hook timeout (600 seconds unless
set higher). Recurring Grok tasks themselves expire after 7 days; run
`/fix-loop` again to renew.

The plugin does not ship `hooks/hooks.json`. Claude Code loads that file for
an enabled plugin, and `plugins/autocoder/settings.json` already defines the
same Stop hook, so a second file would run the hook twice on Claude Code.
Grok does not read `settings.json`. Its loops use `scheduler_create` instead.

## Where the scripts are

An installed plugin is copied to `~/.grok/installed-plugins/<name>-<hash>/`.
Commands look there when `~/.claude/plugins/cache` has no complete script tree.
The idle-sentinel shim does the same.

## What was checked

Against `grok` 1.0.92, in a throwaway `HOME`:

- `grok plugin marketplace add` of this repo lists the Claude marketplace.
- `grok plugin install autocoder --trust` and `modernize` install under those
  names, not `name-<hash>`.
- `grok inspect` lists `/fix`, `/fix-loop`, `/monitor-loop`, `/stop-loop`,
  `/assess`, and the subagent `modernize:architect`.

`tests/test_grok_marketplace.sh` repeats the manifest and loop checks, and the
live install when `grok` is on `PATH`.

## Gaps

- Swarm launch (`start-parallel --agent`) still takes `claude`, `gemini`,
  `codex`, `droid`, or `pi`. It does not start `grok` workers.
- Grok runs a scheduled prompt in a background subagent, not as the next turn
  of the session that called `/fix-loop`. The subagent must have the plugin
  enabled, which a `--trust` install does.
- Modernize agents are spawnable only when their frontmatter has `description`.
  That field is set. `model` in a command's frontmatter is ignored by Grok.
- Grok does not load `plugins/autocoder/settings.json`, and this repo does not
  add `hooks/hooks.json`. A Stop hook is not installed for Grok. `/fix-loop`
  uses `scheduler_create` instead.
