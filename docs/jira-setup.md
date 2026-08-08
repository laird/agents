# Jira issue backend — setup & testing

The autocoder can use a Jira project as its issue source, on equal footing with
the `file` and `github` backends. This guide sets that up and verifies it.

Everything here talks to Jira's **REST API v2** over HTTPS, so it must run
somewhere with outbound network access to your Atlassian site. (Sandboxed CI /
web sessions with a restrictive egress policy cannot reach `*.atlassian.net`;
run these steps on a machine that can.)

## 1. Create a free Jira Cloud site

1. Sign up at <https://www.atlassian.com/software/jira/free> (free tier: up to
   10 users, no card).
2. Pick a site name → you get `https://YOURSITE.atlassian.net`. This is your
   **base URL**.

## 2. Create a project

**Projects → Create project** (any template). Note the project **key** Jira
assigns (e.g. `ENG`) — issues become `ENG-1`, `ENG-2`, …. The backend exposes
the numeric suffix as the issue `number`, so identifiers stay integer-compatible
with the rest of the workflow.

## 3. Create an API token

1. Go to <https://id.atlassian.com/manage-profile/security/api-tokens>.
2. **Create API token**, label it (e.g. `autocoder`), and copy it — you only see
   it once.
3. For Jira **Cloud**, the token authenticates as HTTP Basic together with the
   **email address of the account that created it**.

> **Secrets never go in the repo.** The base URL and project key are non-secret
> and live in `.autocoder.json`; the email + token are read from the
> environment at runtime and must not be committed. If a token is ever pasted
> somewhere shared, rotate it.

## 4. Configure the backend

Non-secret connection settings — either run `/set-issue-source` and choose
`jira`, or write them directly:

```jsonc
// .autocoder.json
{
  "issueSource": "jira",
  "jira": { "baseUrl": "https://YOURSITE.atlassian.net", "project": "ENG" }
}
```

Credentials go in the environment (never committed):

```bash
export JIRA_EMAIL="you@example.com"
export JIRA_API_TOKEN="<token from step 3>"
```

**Jira Server / Data Center** instead of Cloud? Skip the email/token pair and use
a personal access token as a bearer header:

```bash
export JIRA_AUTH_HEADER="Bearer <your-PAT>"
```

Configuration precedence: environment variables override `.autocoder.json`;
secrets are only ever read from the environment.

## 5. Verify

A one-command live check that exercises the full lifecycle against your real
instance and cleans up the throwaway issue it creates:

```bash
bash plugins/autocoder/scripts/jira-smoke-test.sh
```

Or drive the backend directly:

```bash
BE=plugins/autocoder/scripts/issues-jira.sh
"$BE" any-claimable; echo "exit=$?"        # 0 = claimable work exists, 1 = none
"$BE" list --state open --limit 5          # gh-shaped JSON: number,title,body,labels,state
"$BE" create --title "hello" --body "from the jira backend" --label smoke
```

## Automated tests (no network required)

Two hermetic tests run in CI on every push — neither needs a real Jira:

| Test | What it covers |
|------|----------------|
| `tests/test_issues_jira.sh` | stubs `curl`; asserts request/JQL shape, output schema, exit codes |
| `tests/test_issues_jira_integration.sh` | drives real HTTP against an in-process stateful fake (`tests/fixtures/fake_jira.py`) through the full create → get → claim/release → comment → update → close lifecycle |

The live `jira-smoke-test.sh` is deliberately **not** in `tests/`, so CI never
needs egress.

## The 9-verb contract

`issues-jira.sh` implements the same uniform backend contract as `issues-gh.sh`
and `issues-file.py`:

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

State mapping: `open` = not-Done and not carrying a blocking label (claimable);
`working` = has the `working` label; `blocked` = carries a human-decision label
(`needs-design`, `needs-approval`, …); `closed` = statusCategory Done. The
claimable query explicitly includes label-less issues (`labels is EMPTY OR
labels not in (...)`) so unlabeled work is never silently dropped.
