# autocoder-ctl: worker verbs

`nudge`, `stop` and `restart` act on one worker of a swarm. They live in
`plugins/autocoder/scripts/ctl-workers.sh` and answer through the
[autocoder-ctl result contract](../autocoder-ctl.md#result-contract): one JSON object
on stdout, exit 0 done, 1 failed, 2 bad arguments.

A UI calls these verbs; it does not type into panes, find panes by directory or run
`restart-worker.sh` itself.

```bash
autocoder-ctl.sh nudge   <worktree> [text] [--session <name>]
autocoder-ctl.sh stop    <worktree> [--session <name>]
autocoder-ctl.sh restart <worktree> [--session <name>]
```

## Finding the worker

A worker is named by its worktree path. The verb looks the path up in the swarm
manifests in the main worktree (`.autocoder/swarm/<session>.json`, see
[swarm-manifest.md](../swarm-manifest.md)). Symlinks are resolved on both sides.
The manifest gives the multiplexer (`mux`), the agent, and the worker's pane:
`tmuxTarget`, `cmuxWorkspace` or `herdrPane`.

All of these fail with exit 1:

- the path does not exist;
- no manifest lists it;
- more than one manifest lists it (pass `--session` to pick one);
- `--session` names a session that has no manifest;
- the manifest records no pane for the worker (`nudge`, `stop`).

A `--session` value containing `/` or starting with `.` is a usage error (exit 2).
`AUTOCODER_CTL_PROJECT_ROOT` points the lookup at another checkout.

The `target` of every result that got past argument parsing is the resolved worktree path.

## nudge

Types text into the worker and submits it. With no text, the worker gets
`AUTOCODER_CTL_NUDGE_TEXT`, which by default tells it to carry on with its claimed
issue, or take the next one. Text that starts with a dash goes after `--`:
`nudge <worktree> -- "-v please"`. Empty text is a usage error.

Each multiplexer needs its own way to submit, and the verb uses the one from `mux-send-lib.sh`:

| mux | How the text is sent |
|---|---|
| tmux | `send-keys -l -t <pane> -- <text>`, then a separate `send-keys Enter`. `-l` types the text literally (a text of `C-c` is typed, not pressed) and `--` stops a leading-dash text being read as options. A trailing Enter in the same call is read as part of a paste and never submits. |
| cmux | `cmux send --workspace`, then `cmux send-key --workspace … enter`. Text starting with `-` is refused (exit 1), since cmux might read it as an option. |
| herdr | `herdr agent prompt` for an `agent-input` worker (one ordered write of text and enter). If that fails, and for `shell`-mode workers, the verb uses `pane send-text` followed by `pane send-keys enter`. |

The verb refuses (exit 1, nothing typed):

- a worker whose manifest state is `paused`. A paused swarm was stepped down on
  purpose, so resume the swarm instead.
- a tmux or herdr pane whose working directory is no longer the worktree. tmux
  targets like `session:1.2` are positions and shift when a pane closes. cmux
  cannot report a directory, so a cmux nudge goes to the recorded workspace without this check.

```json
{"ok": true, "action": "nudge", "target": "/src/agents-wt-2",
 "detail": {"worktree": "/src/agents-wt-2", "session": "claude-agents", "worker": 2,
            "mux": "tmux", "pane": "claude-agents:1.2", "sent": true,
            "via": "tmux send-keys -l, then Enter", "text": "Resume the autocoder fix loop: …"}}
```

A send that fails returns `"sent": false` with the multiplexer's `exit` code.

## stop

Stops the worker's agent. Before it kills anything, it checks that the pane's working
directory is the worktree, and it refuses (exit 1) when:

- the pane is in another directory (the detail says which);
- the pane is gone;
- the multiplexer cannot report a directory. That means every cmux worker: use
  `remove-worker.sh` there.

| mux | What stop does | What is left |
|---|---|---|
| tmux | `respawn-pane -k -c <worktree>`: the agent is killed, and a fresh shell starts in the same pane and directory | `"pane_left": "shell"` |
| herdr | `herdr pane close` on the verified pane (herdr cannot respawn a pane) | `"pane_left": "closed"` |

`stop` leaves the worktree, the branch, the issue's `working` claim and the
worker's manifest entry untouched. Afterwards:

- `restart` relaunches the worker. Under tmux it finds the shell by its directory;
  under herdr it opens a fresh workspace.
- `remove-worker.sh` removes it for good. It treats a pane that is already gone as
  closed.
- `release <issue>` gives the claim back, if nobody should resume it.

```json
{"ok": true, "action": "stop", "target": "/src/agents-wt-2",
 "detail": {"worktree": "/src/agents-wt-2", "session": "claude-agents", "worker": 2,
            "mux": "tmux", "pane": "claude-agents:1.2", "stopped": true,
            "cwd": "/src/agents-wt-2", "pane_left": "shell",
            "worktree_kept": true, "claim_kept": true}}
```

## restart

Runs `restart-worker.sh --worktree <worktree> --mux <mux> --agent <agent>` from
inside the worktree, with the mux and agent from the manifest. The agent is killed
and relaunched in the same worktree on the same branch. It picks its issue back up
through the `working` label. A paused worker is relaunched without its loop command,
as `restart-worker.sh` does.

The script's output goes to stderr. Its last line is the result's `output`:

```json
{"ok": true, "action": "restart", "target": "/src/agents-wt-2",
 "detail": {"worktree": "/src/agents-wt-2", "session": "claude-agents", "worker": 2,
            "mux": "tmux", "pane": "claude-agents:1.2", "restarted": true,
            "agent": "claude", "output": "✅ Worker restarted in tmux pane claude-agents:1.2 (worktree: /src/agents-wt-2)"}}
```

If the script fails, the result has `"restarted": false`, with its `exit` code and
last line.

`restart` runs the relaunch in the foreground, so a call takes several seconds.

`AUTOCODER_CTL_RESTART_CMD` replaces the script, which the tests use.

## For agents-ui

| Button | Call |
|---|---|
| Nudge | `autocoder-ctl.sh nudge <worktree>` |
| Send message | `autocoder-ctl.sh nudge <worktree> -- "<text>"` |
| Stop | `autocoder-ctl.sh stop <worktree>` |
| Restart | `autocoder-ctl.sh restart <worktree>` |

Read `ok` and `detail`, not the exit code alone. Exit 1 with a refusal in `detail`
(a moved pane, a paused worker) is the verb being careful. It is not a crash.
