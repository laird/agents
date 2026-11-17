# autocoder-ctl: the command surface for UIs

`plugins/autocoder/scripts/autocoder-ctl.sh` is the one entry point a UI, a bot or
a script calls to act on a swarm (#192). It saves the caller from typing into panes
and from parsing a dozen scripts' output: every verb takes plain arguments and
answers in the same JSON shape.

```bash
autocoder-ctl.sh <verb> [args]
autocoder-ctl.sh help          # {"ok": true, ..., "detail": {"verbs": [...]}}
```

## Result contract

Every invocation prints **exactly one JSON object on stdout, and nothing else**.
Diagnostics go to stderr.

```json
{"ok": true, "action": "release", "target": "17", "detail": {"issue": "17", "released": true, ...}}
```

| Key | Type | Meaning |
|---|---|---|
| `ok` | bool | The action did what was asked. |
| `action` | string | The verb as given (also for an unknown verb). `help` when no verb was given. |
| `target` | string \| null | What the verb acted on: an issue number, a worktree, or the repository root. `null` when it never got that far (usage errors, verbs not installed). |
| `detail` | string \| object | A sentence on failure; on success, the verb's data (see each verb). |

### Exit codes

| Code | Meaning | `ok` |
|---|---|---|
| 0 | done | `true` |
| 1 | the action failed (backend error, issue not claimed, no such session) | `false` |
| 2 | usage: no verb, unknown verb, missing or bad argument | `false` |
| 3 | the verb exists but its module is not installed in this version; `detail` is `"not implemented"` | `false` |

A UI can therefore tell "this version cannot do that yet" (3) from "you called it
wrong" (2), and grey out a button instead of showing an error.

### Actor

Verbs that write to the issue tracker say who acted, taken from
`AUTOCODER_CTL_ACTOR`, else `USER`. A UI should set `AUTOCODER_CTL_ACTOR` to the
person (or bot) using it, so the comment on the issue names them rather than the
account the UI runs under.

### Events

After the result is printed, every command except the read-only `help` and `status`
appends one `ctl` event to the issue lifecycle log, `issue-events.jsonl` (#190, format
in [scripts/README.md](../plugins/autocoder/scripts/README.md#issue-lifecycle-issue-eventsjsonl-190)).
Failures are recorded too, usage errors included:

```json
{"v":1,"ts":"2026-11-17T05:02:11Z","repo":"agents-5ea0ca80","issue":17,"worker":"agents",
 "branch":"master","event":"ctl","detail":{"action":"release","target":"17","ok":true,
 "exit":0,"actor":"dashboard-ui","summary":"{\"issue\":\"17\",\"released\":true,...}"}}
```

`issue` is the target when the target is an issue number, else `null`. `summary` is the
first 200 characters of `detail` (compact JSON when `detail` is an object). `worker` and
`branch` are the caller's checkout, so `actor` is what names who acted.

Recording is best effort. A missing events library, an unwritable log or an error while
writing changes neither the result nor the exit code. `status` is left out because a UI
polls it every few seconds, and those lines would bury the lifecycle log.
`AUTOCODER_ISSUE_EVENTS` points the log elsewhere; the tests use a private one.

## Verbs

Verbs are grouped into modules (`ctl-<group>.sh` beside the dispatcher). The
dispatcher sources only the module of the verb being run.

| Group | Module | Verbs | Reference |
|---|---|---|---|
| core | `ctl-core.sh` | `release`, `status` | below |
| workers | `ctl-workers.sh` | `nudge`, `stop`, `restart` | [autocoder-ctl/workers.md](autocoder-ctl/workers.md) |
| issues | `ctl-issues.sh` | `approve`, `reject`, `request-changes`, `file` | [autocoder-ctl/issues.md](autocoder-ctl/issues.md) |
| swarm | `ctl-swarm.sh` | `start`, `add-worker`, `remove-worker`, `stop-swarm` | [autocoder-ctl/swarm.md](autocoder-ctl/swarm.md) |

A verb whose module is not installed (an older or partial plugin copy) answers
exit 3, `"not implemented"`.

### release

```bash
autocoder-ctl.sh release <issue> [--reason <text>]
```

Drops the claim on `<issue>` through `issue_release`, so it works on every issue
backend, then comments on the issue naming the actor and the reason. The issue is
claimable again afterwards.

`detail` on success:

```json
{"issue": "17", "released": true, "commented": true, "actor": "dashboard-ui", "reason": "worker crashed"}
```

`commented` is `false` when the release worked but the comment could not be
posted. `reason` is `null` when none was given. Releasing an issue that is not
claimed fails with exit 1 on backends that track claims as a state (the file
backend); on GitHub, where the claim is a label, it succeeds.

### status

```bash
autocoder-ctl.sh status [--json] [--session <name>]
```

Lists the workers of every swarm whose manifest is in the main worktree
(`.autocoder/swarm/<session>.json`, see [swarm-manifest.md](swarm-manifest.md)),
or of one session with `--session`. Output is always JSON; `--json` is accepted
for callers that pass it. A named session with no manifest, or an unreadable one, fails with exit 1 (a name with `/` or a leading `.` is a usage error); when listing every session, an unreadable manifest is skipped with a note on stderr.
No swarm at all is not an error: `{"swarms": 0, "workers": []}`.

Each worker:

```json
{"session": "agents", "number": 2, "worktree": "/src/agents-wt-2", "pane": "%12",
 "state": "running", "branch": "feature/issue-41", "issue": 41,
 "activity": "busy", "reason": "activity marker in pane (timer/spinner/token meter)"}
```

| Key | Meaning |
|---|---|
| `state` | The worker's state in the manifest (`running`, `paused`, ...). |
| `branch`, `issue` | The worktree's current branch, and the issue it works on when the branch is `feature/issue-N`, `fix/issue-N` or `enhancement/issue-N-auto`; `null` otherwise. |
| `activity` | `busy`, `idle` or `unknown`, from `worker-idle.sh --pane` (a double sample of the pane, so a call takes its settle window, about 4 s; panes are probed in parallel). `unknown` when the manifest has no pane for the worker or the mux is one worker-idle cannot read. |
| `reason` | worker-idle's reason for the verdict. An idle verdict with no explicit idle sentinel is the weaker inference: read the pane before acting on it. |

`AUTOCODER_IDLE_SETTLE_SECONDS` shortens the settle window. `AUTOCODER_CTL_PROJECT_ROOT`
points `status` at another checkout.

## Adding a verb

1. Add the verb to `ctl_module_for` and `CTL_VERBS` in `autocoder-ctl.sh` if it is
   new to #192's list.
2. In the group's module, define `ctl_verb_<verb>` (dashes become underscores).
   Parse its arguments, act, and report once with `ctl_ok <target> <detail> [--json]`,
   `ctl_fail <target> <detail> [--json]` or `ctl_usage <message>`. Do not print to
   stdout: the dispatcher points stdout at stderr while the verb runs, and a verb
   that reports nothing is answered as a failure.
3. Every result leaves through `ctl_emit`, so anything that should happen once per
   action goes there: it records the action's event (`ctl_record`, #247).
4. Run `python3 scripts/package-plugin-scripts.py` and add the cases to
   `tests/test_autocoder_ctl.sh` or a test of the module's own.
