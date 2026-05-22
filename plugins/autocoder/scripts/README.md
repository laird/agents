# Autocoder Issue Backend Scripts

This directory holds the pluggable issue-tracker backend for autocoder. Each
backend is a self-contained script implementing the same 9-verb CLI. Slash
commands and other consumers call the `issue_*` shell functions (defined in
`issue-fns.sh`) and never the backend scripts directly — that's the
abstraction that makes Jira / Linear / other backends a drop-in.

See `docs/superpowers/specs/2026-05-22-issue-storage-and-backend-abstraction-design.md`
for the full design.

## A. Architecture overview

- **`issue-config.sh`** — sourced first by every entry point. Detects the
  configured `ISSUE_SOURCE` from `.autocoder.json` in the main worktree and
  exports it (plus backend-specific env like `ISSUE_DIR_PATH` for file).
- **`issue-fns.sh`** — thin dispatcher. Exposes `issue_list`, `issue_get`,
  `issue_update`, `issue_comment`, `issue_close`, `issue_create`,
  `issue_claim`, `issue_release`, `issue_any_claimable`. Each function
  shells out to the configured backend script with the verb name and the
  caller's arguments. No backend logic lives here.
- **`issues-<backend>` scripts** — self-contained implementations. One
  bug in one backend cannot affect another.

Adding a new backend (Jira, Linear, etc.) is documented in §C below.

## B. The backend contract

A backend script (e.g. `issues-<backend>.sh` or `issues-<backend>.py`)
implements these subcommands:

```
<backend> list          [--state open|working|blocked|closed|all] [--label L] [--limit N]
<backend> get           <number>
<backend> update        <number> [--add-label L] [--remove-label L] [--status S] [--assignee A]
<backend> comment       <number> --body "..."
<backend> close         <number> [--comment "..."]
<backend> create        --title "..." --body "..." [--label L ...]
<backend> claim         <number>
<backend> release       <number>
<backend> any-claimable
```

### Output schema

`list` and `get` produce JSON matching this shape (same as `gh issue view`'s
`--json number,title,body,labels,state`):

```json
{
  "number": 42,
  "title": "...",
  "body": "...",
  "state": "OPEN" | "CLOSED",
  "labels": [{"name": "P1"}, {"name": "needs-design"}],
  "comments": []
}
```

`list` returns a JSON array of these. Write commands (`update`, `comment`,
`close`, `create`, `claim`, `release`) produce no required output;
`create` may print `{"number": N}` on stdout.

### Exit-code contract

- `0` — success. For `any-claimable`: at least one claimable issue exists.
- `1` — clean negative. For `any-claimable`: no claimable issues. For
  `claim`: race lost (issue not in `open/`). For `get` / `update` /
  `comment` / `close` / `release`: issue not found.
- `2` — usage error (bad flags).
- `3` — backend error (filesystem failure, network failure, auth failure,
  parse error). Callers MUST treat this as an error condition, not a
  clean negative.

Backends must not print to stderr on the success path. The dispatcher
relays both streams unmodified.

### State semantics

The four states are `open`, `working`, `blocked`, `closed`. The file
backend partitions by bucket directory (`.issues/open/`, `working/`,
`blocked/`, `closed/`). The github backend simulates the same partition
with label-based search filters (e.g. `--state blocked` queries
`label:"needs-design" OR label:"needs-clarification" OR ...`).

The set of **blocking labels** is fixed across backends:
`{needs-design, needs-clarification, needs-feedback, needs-approval,
too-complex, future, proposal}`. Adding any of these to an open issue
moves it to `blocked/`; clearing the last one moves it back to `open/`.
The `working` label / status is set by `claim` (the *atomic* path) and
cleared by `release`. `update --add-label working` is also supported as
a legacy idempotent label-set but does NOT rename to `working/` — only
`claim` does that.

### Cross-worktree discipline

`ISSUE_DIR_PATH` is always resolved to the **main worktree's** `.issues/`
directory via `issue-config.sh`'s `git worktree list --porcelain` lookup.
All backend scripts MUST use `ISSUE_DIR_PATH` as the single source of
truth — never `pwd` or worktree-local paths — so parallel agents in
secondary worktrees share one set of bucket directories, one `.seq`
counter, and one set of flock files.

### Claim semantics — strict vs. best-effort

- **File backend**: `claim` is strictly atomic via POSIX `rename(2)`.
  Under contention, exactly one caller wins; the rest get exit 1. The
  file backend is the strict-correctness path.
- **GitHub backend**: `claim` is **best-effort**. The gh API has no
  atomic single-writer label edit, so two agents racing to claim the
  same issue may both think they succeeded. Slash commands that depend
  on strict single-winner semantics (notably `fix-loop`) should treat
  this as a known limitation and rely on the comment-scan race detector
  in `/autocoder:fix` for cross-host racers.
- **Future backends**: implementations whose native API supports atomic
  claim must pass the strict contract test; implementations with
  best-effort claim must declare so explicitly in this README and
  provide a relaxed round-trip test.

## C. Walkthrough: adding Jira

1. **Decide the mapping.** Map Jira concepts onto the contract:
   - Jira issue status (Open / In Progress / Done) ↔ open / working / closed.
   - Jira assignee ↔ used as the claim mechanism (set on claim, clear on release).
   - Jira labels ↔ labels (one-to-one).
   - Jira issue key (e.g., `PROJ-42`) ↔ issue number. The contract uses
     integer numbers today; for Jira either strip the project prefix or
     widen the contract to accept string IDs. Recommend widening + pinning
     the discussion here when someone actually builds Jira support.

2. **Write `issues-jira.py`.** Use Jira's REST API. One function per verb.
   Map error responses to the contract's exit codes (3 for network/auth,
   1 for not-found, 0 for success). Produce JSON matching the schema above.

3. **Wire up `.autocoder.json`.** New keys: `jiraBaseUrl`, `jiraProjectKey`,
   plus a pointer to where the API token is stored (env var; never commit
   tokens).

4. **Update `issue-config.sh`** to read these keys when
   `issueSource = "jira"` and export them.

5. **Update `issue-fns.sh`** with one new case:
   `jira) _ifns_BACKEND_SCRIPT="issues-jira.py" ;;`.

6. **Update `/set-issue-source`** to prompt for Jira config when the user
   picks Jira, and validate by running `issues-jira.py list --limit 1`
   against the configured project.

7. **Add `tests/test_issues_jira.sh`** that walks the contract (see §E).

8. **Run the contract tests.** Every backend passes the same suite. If a
   backend can't implement a verb cleanly (e.g., comments are an
   audit-trail feature in Jira with richer semantics), document the
   deviation in this README and provide a compatible projection.

## D. What NOT to do

- Don't add per-backend branches inside slash commands. Slash commands
  call `issue_*` functions; backends decide how.
- Don't reach past the abstraction (don't call `gh` or `python3
  issues-file.py` directly from slash commands).
- Don't bake gh-specific or file-specific label semantics into commands.
  Labels are arbitrary backend strings. The set of meaningful labels
  (`P0`–`P3`, `working`, `needs-design`, etc.) is documented in the
  slash-command layer, not the backend layer.

## E. Contract test list

Each backend should ship a `tests/test_issues_<backend>*.py` (or `.sh`)
that exercises:

- **Round-trip**: `create`, `get`, `list`, `close`, `list --state closed`.
- **Label ops**: `update --add-label`, `update --remove-label`, idempotent
  re-add.
- **Claim semantics (strict, for file/jira)**: `claim` succeeds, second
  `claim` on the same issue fails with exit 1, `release` succeeds. Single
  winner under contention is mandatory.
- **Claim semantics (best-effort, for gh)**: `claim` succeeds; `release`
  round-trips the `working` label. Single-winner under contention is not
  asserted — document deviation.
- **Comment append**: `comment` then `get` returns the comment in `body`.
- **Empty case**: fresh repo, `any-claimable` exits 1 with empty stdout.
- **Non-empty case**: with one `open` issue, `any-claimable` exits 0.

For the file backend specifically, also exercise:

- **Blocking transitions**: `update --add-label needs-design` on an
  `open/` issue renames the file to `blocked/`; `update --remove-label
  needs-design` (when it was the last blocking label) renames back to
  `open/`.
- **Parallel-claim stress**: N processes call `claim` on the same issue;
  exactly one exits 0.
- **Cross-worktree**: from a secondary worktree, all operations target
  the main worktree's `.issues/` directory.
- **fix-loop-idle**: with empty `open/`, `fix-loop` over ~30s does not
  spawn `/fix`.
