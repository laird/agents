# Issue backends

The autocoder's issue tracker is pluggable. All agents share one issue source,
selected per-repo in `.autocoder.json` and resolved at runtime by
`issue-config.sh`. Four backends ship built-in, and any executable honoring the
same contract can be added as a custom backend.

| Backend | `issueSource` | Store | Setup |
|---------|---------------|-------|-------|
| File    | `file`   | `.issues/` directory in the repo | zero-config |
| GitHub  | `github` | GitHub Issues (via `gh`) | `gh auth login` |
| Jira    | `jira`   | Jira project (REST API v2) | [`docs/jira-setup.md`](jira-setup.md) |
| Azure DevOps | `ado` | Azure DevOps work items (WIT REST API) | [`docs/ado-setup.md`](ado-setup.md) |

Switch backends with `/set-issue-source` (it writes `.autocoder.json` and, for
Jira/ADO, prompts for the non-secret connection settings).

## The 9-verb contract

Every backend is a self-contained script exposing the same verbs. The thin
dispatcher `issue-fns.sh` routes `issue_*` calls to the configured backend;
no backend logic lives in the dispatcher.

```
list [--state open|working|blocked|closed|all] [--label L] [--limit N]
get <number>
update <number> [--add-label L] [--remove-label L] [--status S] [--assignee A]
comment <number> --body "..."
close <number> [--comment "..."]
create --title "..." --body "..." [--label L ...]
claim <number>
release <number>
any-claimable
```

**Uniform output.** `list` and `get` emit the same JSON shape as
`gh issue list --json number,title,body,labels,state` (and `get` adds
`comments`). Every backend maps its native model onto this shape, so the rest
of the workflow never branches on which tracker is in use.

**Uniform exit codes.** `0` success / work exists · `1` clean negative (no
claimable work, race lost, not found) · `2` usage error · `3` backend error
(network/auth/parse/config).

**States.** `open` = actionable and unclaimed (not done, carrying no blocking
label); `working` = claimed (`working` label/tag); `blocked` = gated on a human
decision (`needs-design`, `needs-approval`, …); `closed` = done. `claim` /
`release` toggle the `working` marker; `any-claimable` is the cheap "is there
anything to do?" probe the loop polls.

## Backends

### File (`file`)

Issues are Markdown files bucketed by state under `.issues/`
(`open/`, `working/`, `blocked/`, `closed/`). `claim` is an **atomic
`os.rename`**, so exactly one worker can win a race — the strongest locking of
any backend. Zero external dependencies; ideal for offline or single-repo use.
Backend: `issues-file.py`.

### GitHub (`github`)

Wraps the `gh` CLI. Labels are GitHub labels; `open`/`working`/`blocked` are
derived by label search (GitHub has no bucket partitioning), and the claimable
query excludes each blocking label with `-label:"X"` — **not** the valueless
`no:label`, which matches only unlabeled issues and would hide everything
(bug #57). `claim` is best-effort (no atomic single-writer label edit): it adds
`working`, posts an `[autocoder-claim]` marker, waits briefly, and backs off if
it sees a competing marker. Requires `gh auth login`. Backend: `issues-gh.sh`.

### Jira (`jira`)

Talks to the Jira Cloud/Server REST API v2. Issue keys `PROJ-N` map to the
numeric suffix as `number`; **labels ↔ Jira labels**; state via `statusCategory`
(and transitions for close/reopen). The claimable JQL ORs in `labels is EMPTY`
so **unlabeled issues are not silently dropped** (the Jira analogue of #57).
Non-secret `baseUrl`/`project` live in the `jira` object of `.autocoder.json`;
credentials are env-only (`JIRA_EMAIL` + `JIRA_API_TOKEN`, or `JIRA_AUTH_HEADER`
for a Server/DC PAT). Backend: `issues-jira.sh`. Full guide:
[`docs/jira-setup.md`](jira-setup.md).

### Azure DevOps (`ado`)

Talks to the Azure DevOps Work Item Tracking REST API. Work-item **IDs are
integers**, so `number` is the id directly; **labels ↔ work-item Tags**
(`System.Tags`); state via `System.State` (done-state set covers the default
Agile/Basic/Scrum/CMMI processes). Uses WIQL for `list`/`any-claimable`,
`workitemsbatch` for details, and JSON-patch for create/update. WIQL's
`[System.Tags] NOT CONTAINS 'x'` already matches tag-less items, so untagged
work stays claimable with no special clause. Non-secret `orgUrl`/`project` live
in the `ado` object; the PAT is env-only (`ADO_PAT`). Backend: `issues-ado.sh`.
Full guide: [`docs/ado-setup.md`](ado-setup.md).

## Secrets

Non-secret connection settings (URLs, project keys) are safe to commit in
`.autocoder.json`. **Credentials are read only from the environment and never
written to the repo:**

| Backend | Env credentials |
|---------|-----------------|
| GitHub  | `gh` auth (keychain / `GH_TOKEN`) |
| Jira    | `JIRA_EMAIL` + `JIRA_API_TOKEN`, or `JIRA_AUTH_HEADER` |
| Azure DevOps | `ADO_PAT` |

If a token is ever exposed (pasted into chat, committed by accident), revoke and
rotate it at the provider.

## Configuration precedence

For a given repo, `issue-config.sh` resolves the source as: explicit
`--issue-source` flag → `.autocoder.json` `issueSource` → inherited
`ISSUE_SOURCE` env var. The repo config is authoritative over a stale inherited
value (a mismatched export only warns). Per-backend connection settings follow
the same rule: environment overrides `.autocoder.json`; secrets are env-only.

## Testing

Each network backend has two hermetic tests that run in CI on every push — no
real service or network required:

| Backend | curl-stub (request shape) | in-process fake (lifecycle) |
|---------|---------------------------|-----------------------------|
| Jira | `tests/test_issues_jira.sh` | `tests/test_issues_jira_integration.sh` + `tests/fixtures/fake_jira.py` |
| Azure DevOps | `tests/test_issues_ado.sh` | `tests/test_issues_ado_integration.sh` + `tests/fixtures/fake_ado.py` |

The integration fakes maintain state and evaluate the query language (JQL /
WIQL), so the full `create → get → claim/release → comment → update → close`
lifecycle and the state filters are exercised over real HTTP.

For a check against a **real** Jira instance (needs egress to your site), run
`plugins/autocoder/scripts/jira-smoke-test.sh` with the `JIRA_*` env vars set.
It is deliberately not part of the CI suite.

## Adding a custom backend

Any executable implementing the 9 verbs above can be a backend. Point
`.autocoder.json` at it:

```json
{ "issueSource": "linear", "issueBackend": "./scripts/backends/linear.sh" }
```

`issue-fns.sh` routes unknown `issueSource` values through `$issueBackend`.
Implement `list --state open` to return only claimable work, and give `claim`
the strongest single-writer semantics your store allows (see the file backend's
atomic rename for the reference behavior).
