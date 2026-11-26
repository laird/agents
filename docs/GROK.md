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

## Swarm launch

`--agent grok` and `AUTOCODER_AGENT=grok` are accepted everywhere the other
agents are: `start-parallel-agents.sh`, `add-worker.sh`, `start-workers.sh`,
`restart-worker.sh`, `remove-worker.sh`, `autocoder-ctl start`, and the herdr
path (`herdr agent start <name> --kind grok --pane <id> -- --trust`).

The binary is started as an interactive TUI, the same shape as Gemini, so
herdr can list the pane:

```bash
grok --trust --always-approve
```

Then the launcher types a bare command. `grok inspect` lists this plugin's
user-invocable commands without the `autocoder:` prefix:

| Role | Command |
|---|---|
| Worker loop | `/fix-loop` |
| One issue | `/fix N` |
| Manager loop | `/monitor-loop` |
| Manager after a reset or reboot | `/manager-resume --non-interactive`, then `/monitor-loop` |

Claude is still `/autocoder:fix` and `/autocoder:fix-loop`. `worktree-issue.sh`,
the idle sentinel, and `reboot-recover.sh` already switch on
`AUTOCODER_AGENT`: anything other than `claude` gets the bare names.

### Folder trust and tool approval

Launchers do not type an answer into a dialog (`send_agent_prompt` returns 3
and leaves the pane alone). Two flags do the agreeing instead.

[docs.x.ai hooks](https://docs.x.ai/build/features/hooks) says project hooks
require trust, granted with `/hooks-trust` or by launching with `--trust`.
The decision is stored in `~/.grok/trusted_folders.toml` and covers project
hooks, project MCP, and LSP.

`--always-approve` accepts tool-permission prompts so a swarm pane does not
stall. `--yolo` is not the flag this launcher passes. A usage-limit dialog is
not a tool prompt: the quota watchdog restarts the pane, and "Add funds" is
never chosen.

### Fail a pane over

`quota-failover.sh` does this for whichever agent is out of usage, not only
Claude and not only onto Grok. It reads the pane, skips platforms that are
exhausted or not authenticated, and restarts the same worktree through
`restart-worker.sh`. Preference defaults to `claude`, `codex`, `grok`, then
the others. The manual form is the same restart, with the agent named:

```bash
restart-worker.sh --worktree /path/to/repo-wt-2 --mux herdr --agent grok
```

A new swarm on the same tracker:

```bash
start-parallel-agents.sh 3 --mux herdr --agent grok
```

Auto-detect still prefers `claude`, then `gemini`, `codex`, `droid`, `pi`,
and only then `grok`. The quota watchdog uses its own preference list
(`AUTOCODER_AGENT_PREFERENCE` or `.autocoder.json` `agentPreference`).

### What was not verified here

- `grok --trust` is documented on docs.x.ai (hooks). The short CLI reference's
  common-flags table does not list it. This checkout did not re-run
  `grok 1.0.92 --help`, so the flag was not confirmed against that binary.
- The exact wording of Grok's folder-trust dialog was not captured. If
  `--trust` does not suppress it, the launcher still will not type "yes".
- `--permission-mode` (`default`, `acceptEdits`, `auto`, `dontAsk`,
  `bypassPermissions`, `plan`) is described in the enterprise and permissions
  docs. The launcher does not set it.
- `/monitor-loop`'s Claude text still shows `/autocoder:fix` in its dispatch
  examples. On Grok, send `/fix`. The routing section of that command says so.

## Other gaps

- Grok runs a scheduled prompt in a background subagent, not as the next turn
  of the session that called `/fix-loop`. The subagent must have the plugin
  enabled, which a `--trust` install does.
- Modernize agents are spawnable only when their frontmatter has `description`.
  That field is set. `model` in a command's frontmatter is ignored by Grok.
- Grok does not load `plugins/autocoder/settings.json`, and this repo does not
  add `hooks/hooks.json`. A Stop hook is not installed for Grok. `/fix-loop`
  uses `scheduler_create` instead.
