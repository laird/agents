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
<backend> handoff       <number>
<backend> park          <number> [--comment "..."]
<backend> escalate      <number> --label <blocking-label> [--comment "..."]
<backend> requeue       <number> [--comment "..."]
```

The last four are the lifecycle a detached merge job drives after a worker's
`claim`. They exist so that no caller ever writes a label pair by hand: each
backend implements the bucket or label consequences once.

| verb | from | to | file backend bucket |
|---|---|---|---|
| `handoff` | `working` | `merging` | stays in `working/` (never claimable) |
| `park` | `working` / `merging` | `awaiting-integration` | `working/` |
| `escalate --label L` | any lock label | `L` (a blocking label) | `blocked/` |
| `requeue` | any lock label | none | `open/` (`blocked/` if another blocking label remains) |

Every verb converges: run twice, the second run changes nothing. A closed
issue has left the lifecycle, so each verb exits 1 on it and changes nothing.

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
`close`, `create`, `claim`, `release`, `handoff`, `park`, `escalate`,
`requeue`) produce no required output; `create` may print `{"number": N}`
on stdout.

### Exit-code contract

- `0` — success. For `any-claimable`: at least one claimable issue exists.
- `1` — clean negative. For `any-claimable`: no claimable issues. For
  `claim`: race lost (issue not in `open/`). For `get` / `update` /
  `comment` / `close` / `release`: issue not found. For `handoff` / `park` /
  `escalate` / `requeue`: issue not found or already closed.
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

Three **lock labels** say who owns an issue right now and keep it out of
the claimable queue without making it "blocked": `working` (a worker),
`merging` (a detached merge job), `awaiting-integration` (landed, waiting
for the sentinel's green tip or a human merge). `list --state blocked`
never shows them. The file backend keeps all three in `working/`; `close`
strips all three.

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

## F. `main-sentinel.sh` — post-merge gate for the integration branch

`merge-to-integration.sh` may push a push-race re-sync without re-gating it and may
push onto an integration branch that is already red. The sentinel is what makes
both safe: it tests the integration tip after merges land, and when the tip is
red it finds the push that broke it and files the regression against the issue
that made it. By default it stops there (report-only) and the fix rolls forward
through a normal gated change; with `--auto-revert` it also reverts exactly that
push, which is only appropriate when every party pushing to the branch agrees.

One invocation is one idempotent tick. Run it beside the swarm:

```bash
plugins/autocoder/scripts/main-sentinel.sh --repo "$MAIN_WORKTREE" --integration main --loop 300
```

`--test-cmd` defaults to the `### Regression Test Suite` block of `AGENTS.md`
or `CLAUDE.md`; the script refuses to run without one. The green ref defaults to
`AUTOCODER_GREEN_REF`, then `<integration>-green`; `--green-ref` overrides both.
Exit 0 means idle, green, or repaired; 1 a setup error; 3 red and not repaired
(a P0 is filed). A tick holds `flock` on `<state file>.lock`; a second invocation
prints that another tick is running and exits 0.

### Tip refs: the record the sentinel bisects

Workers merge the integration branch *into* their feature and push the feature
tip as the new integration tip, so consecutive tips are joined by second-parent
links or plain fast-forwards. `git bisect --first-parent` only ever visits the
newest push's own commits, so a break from an earlier push got the newest push
reverted. Instead, every verified push records itself:

```
refs/autocoder/tips/<integration>/<landed-sha>-<issue>
```

`merge-to-integration.sh` pushes one after each verified push; the sentinel
pushes one for each revert it lands, with the P0 number as the issue. The
sentinel bisects over that ordered list, never over commits.

Each tick:

1. Fetches `origin/<integration>`, `origin/<green-ref>` and the tip refs. Finishes
   the bookkeeping of a revert an earlier tick pushed but did not record
   (`pending_revert` in the state file), drops one that never reached origin.
2. Reconciles hand-offs (below). An unmoved tip is then an idle tick.
3. Gates the tip in a throwaway worktree
   (`${AUTOCODER_TMP:-/tmp}/autocoder-sentinel-<repo-id>-<integration>/<pid>`,
   seeded with `node_modules`/`dist` by `worktree-deps-fns.sh`, removed on exit)
   through `gate-cache-fns.sh`, so a tree a worker already gated costs nothing.
4. Green: fast-forwards `origin/<green-ref>` to the tip, closes the red P0 if one
   was open ("green again at"), and closes every open issue labelled
   `awaiting-integration` whose tip ref is on the tip and whose commit
   `verify-shipped.sh` accepts. Issues without a tip ref (PR mode) are not touched.
   Then `promote.sh --auto`.
5. Red with a green ancestor: binary-searches the recorded tips strictly after
   `last_green` (the tip itself is a synthetic tip with issue `unknown` when
   nobody recorded it). Probes read the shared gate cache and write to a
   per-repair cache that is deleted afterwards. With the first bad push `B`, its
   issue `I` and the previous good tip `P`, the repair is
   `git diff --binary P B | git apply -R --3way --index` on the current tip,
   committed as `Revert autocoder push <B> (issue #I)` with trailers
   `Autocoder-Reverts: <B>` and `Autocoder-Reverts-Issue: <I>`. A conflict stops
   the repair. The revert tree is gated; the P0 (`P0,test-failure`, one per
   culprit) is filed first so its number can be recorded as intent; the push
   retries up to 8 times, rebuilding the revert on whatever tip wins the race and
   re-gating only when the incoming files overlap the revert's files or a global
   path (`regate-fns.sh`). Only after the revert is verified on origin does the
   sentinel publish its tip ref, move `<green-ref>`, comment the revert sha and
   the re-land steps on the P0 and on issue `I`, and clear the pending state.
   Issue `I`, if parked, goes back in the queue. A reverted push's issue is never
   closed as landed: the revert's trailer is the record step 4 checks.
6. Red otherwise: files the P0 (or comments on the still-open one, found by title
   when the state file lost its number) and exits 3.
7. Hand-offs: for each open issue labelled `merging` (or `awaiting-integration`
   with a job file, the older shape): a live job is left alone; a dead job whose
   push has a tip ref is closed or parked; a dead job with no exit file re-runs
   its `run.sh` once (`setsid`, idempotent: a landed sha is not merged twice) or,
   failing that, is re-queued. Job files are
   `autocoder-merge-<repo-id>-<issue>.{pid,exit,run.sh,log}` under
   `${AUTOCODER_TMP:-/tmp}` (the older `autocoder-merge-<issue>.*` names are read
   for one release); finished sets older than a day are reaped.
8. Prunes tip refs more than 200 commits behind the green tip (keeping those a
   parked issue still needs) and gate-cache records older than 30 days.

State lives in one file,
`${AUTOCODER_SENTINEL_STATE_DIR:-$XDG_STATE_HOME/autocoder/sentinel}/<repo-id>-<integration>`,
with `last_tested`, `last_green`, `red_issue`, and the `pending_*` fields
(tmp+rename). `last_green` is re-read from `origin/<green-ref>` whenever that ref
exists; the file only carries what git has no home for. `cat` it to see the
sentinel's last tick. `push_green` returns non-zero when the ref will not
fast-forward; `AUTOCODER_GREEN_FORCE=1` allows a lease-protected force, only for a
sha that passed the gate this tick and is not an ancestor of the current green
ref. Tests point `AUTOCODER_TMP`, `AUTOCODER_SENTINEL_STATE_DIR`, and
`AUTOCODER_GATE_CACHE_DIR` at a scratch directory. The repo id comes from
`repo-id-fns.sh`: `<repo dir>-<8 hex of the common git dir>`, the same from every
worktree of a clone.

## G. `promote.sh` — environments, gated on the sentinel's proof

`main` may be red between sentinel ticks; a release may not. An environment is a
branch on origin (`env/staging`, `env/uat`, `env/prod`) that a deploy reads, and
`promote.sh` is the only thing that moves it. It moves it only to a commit with
proof of a full-regression pass: `origin/<green-ref>` (default
`<integration>-green`, `--integration main` unless told otherwise, or
`AUTOCODER_GREEN_REF`), the previous environment's tip, or a tree the gate cache
records as passing. A commit that is merely on `main` is refused.

```bash
plugins/autocoder/scripts/promote.sh --to staging            # to origin/<integration>-green
plugins/autocoder/scripts/promote.sh --to uat                # to staging's tip
plugins/autocoder/scripts/promote.sh --to prod --dry-run     # every check, no push
plugins/autocoder/scripts/promote.sh --list                  # tips, proof, what is releasable
plugins/autocoder/scripts/promote.sh --to prod --commit <sha> --allow-rollback
```

The pipeline is the ordered `environments` array of `.autocoder.json` (`name`,
`ref`, `requires`, optional `test` and `auto`). An environment's `test` runs on
the candidate tree in a throwaway worktree through `gate-cache-fns.sh`, so a
repeat on the same tree is free. With `auto: true` the sentinel calls
`promote.sh --auto` after every green tick; a refused promotion never changes
the tick's exit code. Exit 0 moved or already there, 1 config error, 2 refused
with a one-line reason. Full how-to: [docs/environments.md](../../../docs/environments.md).
