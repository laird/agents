# autocoder-ctl: swarm verbs

`start`, `add-worker`, `remove-worker` and `stop-swarm` start a swarm, change its
size and stop it. They live in `plugins/autocoder/scripts/ctl-swarm.sh` and answer
through the [autocoder-ctl result contract](../autocoder-ctl.md#result-contract):
one JSON object on stdout, exit 0 done, 1 failed, 2 bad arguments.

A UI calls these verbs. It does not create worktrees, lay out panes or launch
agents itself. Each verb runs the script that already does that job:

| Verb | Wraps |
|---|---|
| `start` | `start-parallel-agents.sh` (and installs the autocoder plugin first) |
| `add-worker` | `add-worker.sh` |
| `remove-worker` | `remove-worker.sh` |
| `stop-swarm` | `stop-parallel-agents.sh` |

```bash
autocoder-ctl.sh start <repo> [--workers N] [--agent claude|codex|gemini|droid|pi]
                       [--mux tmux|cmux|herdr] [--route self|manager] [--paused]
                       [--no-plugin-install] [--prompt-wait S]
autocoder-ctl.sh add-worker [count] [--repo <path>] [--session <name>] [--prompt-wait S]
autocoder-ctl.sh remove-worker <N> [<N>...] [--repo <path>] [--session <name>] [--remove-worktree]
autocoder-ctl.sh stop-swarm [--repo <path>] [--mux tmux|cmux|herdr]
```

The wrapped script runs with stdin from `/dev/null`, and its output goes to stderr.
The result carries the script's exit code (`exit`) and its last line of output
(`output`). A script that would attach to tmux is told not to (`--no-attach`): a
UI has no terminal to attach.

## Which repo and which swarm

`start` takes the repo as its argument. The other verbs act on `--repo`, else
`$AUTOCODER_CTL_PROJECT_ROOT`, else the current directory. Either way they use that
repo's main worktree, where the swarm manifests live, so a linked worktree works too.

`add-worker` and `remove-worker` act on one swarm, found from its manifest
(`.autocoder/swarm/<session>.json`, see [swarm-manifest.md](../swarm-manifest.md)).
If the repo has one manifest, that is the swarm. If it has several, pass
`--session`. If it has none, the verb fails (exit 1) and says to start one first.
`add-worker` passes the manifest's own `agent` and `mux` to `add-worker.sh`, so
the new worker matches the swarm rather than whichever agent CLI is found first.

## Trust and consent prompts

An agent can stop at a prompt before it does any work. For example, Claude asks
"Do you trust the files in this folder?" in a new worktree. With
`--dangerously-skip-permissions` it also shows a Bypass Permissions consent
screen. These are the user's decisions, so **no verb ever answers them**.

After launching, `start` waits `--prompt-wait` seconds (default
`$AUTOCODER_CTL_PROMPT_WAIT`, 8), then reads the screen of every pane in the
manifest: the manager and each worker. `add-worker` does the same for the workers
it added or started. These verbs only read the panes; they never type into them.
A prompt they find comes back in `detail.prompts`. `detail.prompts_pending` is
`true` when there is at least one:

```json
"prompts": [
  {"role": "worker", "worker": 1, "pane": "claude-agents:1.1", "kind": "trust",
   "text": "Do you trust the files in this folder?"},
  {"role": "manager", "worker": null, "pane": "claude-agents:2.1", "kind": "consent",
   "text": "WARNING: Claude Code running in Bypass Permissions mode"}
],
"prompts_pending": true
```

`kind` is `trust` or `consent`, and `text` is the matching line of the screen. The
text is untrusted: an agent that prints a README line reading "Do you trust this
folder?" produces an entry too, so a UI should display it, never act on it. The UI
should show this to the user and let them answer it in that pane, for example
through the multiplexer or with `nudge`. The verb still succeeds (exit 0): the
swarm started, and it is waiting on the user.

autocoder-ctl itself never answers. Some launch paths in the wrapped scripts do
type a prompt and Enter a few seconds after starting the agent (a manager whose
command mode is not `argv`, and gemini or codex workers in `agent-input` mode).
If that agent is showing a trust dialog by then, the Enter answers it with the
dialog's default.

Pane targets are read from the manifest. A target that could be taken for an
option (for example, one starting with `-`) is skipped rather than passed to the
multiplexer.

The patterns are `$AUTOCODER_CTL_TRUST_PATTERN` and `$AUTOCODER_CTL_CONSENT_PATTERN`
(extended regular expressions). Trust is checked first, because Claude's trust
dialog also offers "No, exit". A prompt that shows up after the wait is not caught;
`--prompt-wait 0` reads the panes straight away.

## start

1. **Plugin install.** For `claude` and `droid`, if `<agent> plugin list` (run in
   the repo, so project-scoped installs count) does not show
   `autocoder@plugin-marketplace`, `start` runs `<agent> plugin install
   autocoder@plugin-marketplace` (set `$AUTOCODER_CTL_PLUGIN_REF` to install another
   ref). Gemini reads the workflows from the repo and needs no install. Codex skills
   come from `scripts/install-codex.sh`, which is not per swarm. Both report
   `skipped`. If the install fails, `start` fails (exit 1) and launches nothing.
   `--no-plugin-install` skips this step.
2. **Launch.** `start-parallel-agents.sh [N] --agent A --no-attach [--mux M]
   [--route R] [--paused]`, run in `<repo>`. With no `--agent`, `start` picks the
   first of claude, gemini, codex, droid and pi that is on PATH. The same agent is
   then used for the plugin install and the swarm.
3. **Prompts.** As above.

`start` fails (exit 1) when:

- the repo does not exist or is not a git repository;
- the plugin install fails (`detail.plugin.status` is `failed`);
- `start-parallel-agents.sh` exits non-zero;
- it exits 0 without starting a swarm. `start` looks for the manifest of the
  session it asked for, `<agent>-<repo directory>`, and checks that its
  `taskListId` is new, since every launch writes a fresh one. Another swarm's
  manifest changing in the meantime does not count. If that session is already
  running (tmux), the reason says so: use `add-worker` instead, or `stop-swarm`
  first.

```json
{"ok": true, "action": "start", "target": "/src/agents",
 "detail": {"repo": "/src/agents", "started": true, "session": "claude-agents",
            "manifest": "/src/agents/.autocoder/swarm/claude-agents.json",
            "agent": "claude", "mux": "tmux", "state": "running", "workers": [1, 2, 3],
            "plugin": {"agent": "claude", "status": "present", "plugin": "autocoder@plugin-marketplace"},
            "prompts": [], "prompts_pending": false,
            "output": "tmux attach -t claude-agents"}}
```

`plugin.status` is `present`, `installed`, `skipped` or `failed`.

## add-worker

Adds `count` workers (default 1). `add-worker.sh` first starts any worker the
manifest lists as `paused`, then adds new ones. The result reports both, as
worker numbers taken from the manifest before and after:

```json
{"ok": true, "action": "add-worker", "target": "/src/agents",
 "detail": {"session": "claude-agents", "agent": "claude", "mux": "tmux",
            "added": [4], "started": [2], "prompts": [], "prompts_pending": false,
            "output": "✅ Worker 4 added to tmux session 'claude-agents' (pane 4)"}}
```

## remove-worker

Runs `remove-worker.sh <N>... --session <session> [--remove-worktree]`. It closes
those workers' panes and drops them from the manifest. Worktrees are kept unless
you pass `--remove-worktree`.
`detail.removed` lists the requested workers that were in the manifest and are now
gone. `detail.remaining` lists the workers still there. A number that was never in
the swarm makes `remove-worker.sh` exit 1, so the verb fails, and the result shows
which workers were removed.

## stop-swarm

Runs `stop-parallel-agents.sh` in the main worktree, which closes the repo's swarm
sessions or workspaces. Without `--mux`, the verb passes the multiplexer the
repo's manifests agree on. If there is no manifest, or the manifests disagree, the
script detects the multiplexer itself. Manifests are left in place, so a UI can
still show what ran.

`stop-parallel-agents.sh` only knows tmux sessions named `claude-` and `gemini-`.
So the verb then checks each tmux manifest's session by exact name and kills any
that is still up, such as `codex-<repo>`. These are listed in
`sessions_closed`. A session it fails to kill is listed in
`sessions_still_running`, and the verb then fails (exit 1).

Nothing to stop is not a failure: the result is `ok` with `"stopped": false`.

```json
{"ok": true, "action": "stop-swarm", "target": "/src/agents",
 "detail": {"repo": "/src/agents", "mux": "tmux", "stopped": true, "sessions_closed": [],
            "sessions_still_running": [], "exit": 0, "output": "✅ Done"}}
```

## Testing

`tests/test_autocoder_ctl_swarm.sh` covers every verb, with the wrapped scripts,
the agent CLI and tmux all stubbed.
