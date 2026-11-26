# autocoder-ctl: issue decisions

`approve`, `reject`, `request-changes` and `file` record a person's decision
about an issue (#245). They live in `plugins/autocoder/scripts/ctl-issues.sh`,
which [`autocoder-ctl.sh`](../autocoder-ctl.md) sources when one of these verbs
is called.

Every verb goes through the configured issue backend (`issue-fns.sh`), so it
works the same on GitHub, Jira, Azure DevOps and the local `.issues/` store. A UI
calls these verbs and does not need its own `gh` calls or label rules.
A UI's proposal and new-issue screens, for example, may call `gh` directly today.

Each call prints one result object and exits 0 / 1 / 2, as the
[result contract](../autocoder-ctl.md#result-contract) describes:

- 2 is a usage error: an argument is missing, an issue number is not a number,
  or the text is empty. Nothing was written.
- 1 means the action failed: the issue does not exist, it is closed, it is not
  a proposal (`approve`), or the backend failed.

Every write names the actor. That is `AUTOCODER_CTL_ACTOR` if set, otherwise
`USER`, and it appears in the comment on the issue (in the body, for `file`) and
in `detail.actor`.

## approve

```bash
autocoder-ctl.sh approve <issue>
```

Approves a proposal. It removes the `proposal` label, then comments
"Proposal approved by <actor>". This is what `/update-issue <n> --remove-label proposal` does. The fix loop implements the issue on a later tick.

It fails (exit 1) if the issue is closed or does not have the `proposal` label,
so a second click on the same button does not post a second comment.

```json
{"ok": true, "action": "approve", "target": "17",
 "detail": {"issue": "17", "approved": true, "commented": true, "actor": "example-actor"}}
```

`commented` is `false` if the label was removed but the comment could not be
posted.

## reject

```bash
autocoder-ctl.sh reject <issue> [reason]
```

Closes the issue with the comment "Rejected by <actor>" and the reason. The
comment is sent with the close, so a rejection is never recorded without its
reason. Rejecting an issue that is already closed fails (exit 1).

```json
{"ok": true, "action": "reject", "target": "17",
 "detail": {"issue": "17", "closed": true, "actor": "example-actor", "reason": "Out of scope"}}
```

`reason` is `null` if none was given. Quote a reason that contains spaces: it is
one argument.

## request-changes

```bash
autocoder-ctl.sh request-changes <issue> <text>
```

Comments "Changes requested by <actor>" followed by the text. The `proposal`
label stays, so `/refine-proposal <issue>` revises the proposal from the comment.
The verb also works on an issue that is not a proposal, where it is just a
comment, without the `/refine-proposal` hint; `detail.proposal` tells the two
cases apart. An empty or blank text is
a usage error (exit 2), and a closed issue fails (exit 1).

```json
{"ok": true, "action": "request-changes", "target": "17",
 "detail": {"issue": "17", "commented": true, "actor": "example-actor", "proposal": true}}
```

## file

```bash
autocoder-ctl.sh file --title <title> [--body <body>] [--label <label>]...
```

Creates an issue. Its body ends with the line "Filed by <actor> via
autocoder-ctl" (after a `---` rule when there is a body). `--label` can be repeated. On GitHub every label must already
exist in the repository, or the create fails (exit 1). The `target` is the new
issue's number:

```json
{"ok": true, "action": "file", "target": "42",
 "detail": {"number": 42, "title": "Add a dark mode", "labels": ["enhancement", "P3"], "actor": "example-actor"}}
```

A missing or blank `--title`, a flag with no value, or an unknown argument is a
usage error (exit 2).
