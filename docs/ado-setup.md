# Azure DevOps issue backend — setup & testing

The autocoder can use an Azure DevOps project's **work items** as its issue
source, on equal footing with the `file`, `github`, and `jira` backends.

Everything here talks to the Azure DevOps **Work Item Tracking REST API** over
HTTPS, so it must run somewhere with outbound network access to
`dev.azure.com`. (Sandboxed CI / web sessions with a restrictive egress policy
cannot reach it; run these steps on a machine that can.)

## 1. Have an Azure DevOps org + project

If you don't have one, create a free org at <https://dev.azure.com> and a
project inside it. You need:

- the **org URL**, e.g. `https://dev.azure.com/myorg`
- the **project** name (or id)

## 2. Create a Personal Access Token (PAT)

1. In Azure DevOps: **User settings ⚙ → Personal access tokens → New Token**.
2. Scope it to **Work Items → Read & write** (Read alone is enough for
   `list`/`get`/`any-claimable`; write is needed for create/update/comment/
   close/claim/release).
3. Copy the token — you only see it once.

> **The PAT is a secret.** It is read only from the environment (`ADO_PAT`) and
> is never written to `.autocoder.json` or committed. If it is ever exposed,
> revoke it in the same PAT screen.

## 3. Configure the backend

Non-secret connection settings — run `/set-issue-source` and choose `ado`, or
write them directly:

```jsonc
// .autocoder.json
{
  "issueSource": "ado",
  "ado": { "orgUrl": "https://dev.azure.com/myorg", "project": "MyProject" }
}
```

The PAT goes in the environment (never committed):

```bash
export ADO_PAT="<personal access token>"
```

Optional overrides (defaults suit the standard processes):

| Env var | Default | Purpose |
|---------|---------|---------|
| `ADO_WORKITEM_TYPE` | `Task` | work-item type `create` makes (present in every default process) |
| `ADO_CLOSED_STATE`  | `Closed` | state `close` transitions to (use `Done` for Basic/Scrum) |
| `ADO_OPEN_STATE`    | `Active` | state `update --status open` transitions to |

Configuration precedence: environment variables override `.autocoder.json`; the
PAT is only ever read from the environment.

## 4. Verify

```bash
BE=plugins/autocoder/scripts/issues-ado.sh
"$BE" any-claimable; echo "exit=$?"        # 0 = claimable work exists, 1 = none
"$BE" list --state open --limit 5          # gh-shaped JSON: number,title,body,labels,state
"$BE" create --title "hello" --body "from the ado backend" --label smoke
```

## Model mapping

| Contract concept | Azure DevOps |
|------------------|--------------|
| issue `number`   | work item **id** (integer, used directly) |
| `title` / `body` | `System.Title` / `System.Description` |
| `labels`         | work-item **Tags** (`System.Tags`, `"; "`-joined) |
| `state` OPEN/CLOSED | `System.State`, CLOSED when it is a done state (`Closed`/`Done`/`Resolved`/`Removed`/`Completed`) |
| `comment`        | work-item comments (preview API) |

`list --state open` selects work items that are **not** in a done state and
carry **no** blocking tag. Because WIQL's `[System.Tags] NOT CONTAINS 'x'`
already matches tag-less items, untagged work stays claimable — no special
"empty" clause is needed (unlike GitHub's `no:label` / Jira's `labels is
EMPTY`).

## Automated tests (no network required)

Two hermetic tests run in CI on every push — neither needs a real Azure DevOps:

| Test | What it covers |
|------|----------------|
| `tests/test_issues_ado.sh` | stubs `curl`; asserts WIQL + JSON-patch shape, output schema, exit codes |
| `tests/test_issues_ado_integration.sh` | drives real HTTP against an in-process stateful fake (`tests/fixtures/fake_ado.py`) through the full create → get → claim/release → comment → update → close lifecycle |

## The 9-verb contract

`issues-ado.sh` implements the same uniform backend contract as `issues-gh.sh`,
`issues-file.py`, and `issues-jira.sh`:

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
