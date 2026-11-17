# Autocoder Issue Backend Scripts

This directory holds the pluggable issue-tracker backend for autocoder. Each
backend is a self-contained script implementing the same 9-verb CLI. Slash
commands and other consumers call the `issue_*` shell functions (defined in
`issue-fns.sh`) and never the backend scripts directly — that's the
abstraction that makes Jira / Linear / other backends a drop-in.

See `docs/superpowers/specs/2026-05-22-issue-storage-and-backend-abstraction-design.md`
for the full design.

<a id="script-dir"></a>
## Resolving `SCRIPT_DIR` in command files

Commands that source `issue-fns.sh` resolve `SCRIPT_DIR` with the same loop, marked
`# Resolve SCRIPT_DIR — see scripts/README.md#script-dir`. It tries, in order,
`$(pwd)/.agent/scripts`, `$(pwd)/plugins/autocoder/scripts` and
`$(pwd)/.claude-plugin/plugins/autocoder/scripts`, then falls back to the newest
installed plugin under `~/.claude/plugins/cache`.

A project-local tree only wins if it is a COMPLETE override, i.e. it actually
contains the file the command is about to source (`issue-fns.sh`; `/spot-check`
also requires `fix-loop-gate.sh`). Testing for the directory alone let a stale
vendored `.agent/` or `plugins/autocoder/` tree, left behind by an old project
import, shadow the installed plugin: the `source` then failed and every
`issue_*` call silently used the wrong backend.

Keep the loop byte-for-byte identical across commands; edit it everywhere at
once, in both `plugins/autocoder/commands/` and `.agent/workflows/`.

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

### Dependencies: work issues in the order they allow

The claimable queue (`issue_list --state open`, and `list` with no `--state`)
leaves out any issue whose dependencies are not closed yet. That policy lives
in `issue-deps.sh`, sourced by `issue-fns.sh`, so it holds for every backend
and every caller: the fix-loop gate, `/fix`, the manager's dispatch and
scaling, and `issue_any_claimable` (which the idle sentinel relies on).

- **Declared in the body**: every `#N` on a line that says `Depends on` or
  `Blocked by` (the decomposition template's `## Dependencies` section writes
  these). `Sub-task of #N` is the parent, not a dependency.
- **Native on GitHub**: open "blocked by" relationships, read for all open
  issues in one GraphQL query; skipped when there is no `origin` or the server
  has no issue dependencies.
- **Met** means the dependency's state is closed (`closed`, `done`, `resolved`,
  `completed`, `removed`). A dependency that can't be read counts as met, so a
  typo never wedges the queue.
- Waiting issues are named on stderr (`⏳ #350 waits on #347, #348`).
  `issue_unmet_dependencies <n>` prints what one issue waits on; `/fix <n>`
  refuses an issue that still waits, before claiming it.
- `AUTOCODER_IGNORE_DEPENDENCIES=1` turns the filter off.

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

**A claim the session declines (#248).** `fix-loop-gate.sh` claims before the
session that ran it reads the work plan. When that session declines the issue
(for example it must compact first), it runs `release-gate-claim.sh <N> "<reason>"`,
which drops `working`, posts a `🔓` release comment and clears the worker-state
record. It touches only the issue this worktree's gate recorded, and refuses once
`feature/issue-<N>` exists, because then `/fix` owns the claim.

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

> **`<tmp-root>`** below is where the merge job, sentinel and landing queue keep
> their host-local state: `$AUTOCODER_TMP` if set, else a private per-user
> `/tmp/autocoder-<uid>` (0700), else `~/.local/state/autocoder/tmp`
> (`autocoder_tmp_root` in `repo-id-fns.sh`, #213). If you set `AUTOCODER_TMP`,
> point it at a directory only you can write: anything there may be executed.

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
   (`<tmp-root>/autocoder-sentinel-<repo-id>-<integration>/<pid>`,
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
   `review-corpus.py harvest` turns each of these reverts into a review test
   case (`tests/review_corpus/`, #167), so a change to the pre-landing reviewer
   can be scored against the pushes it should have stopped.
6. Red otherwise: files the P0 (or comments on the still-open one, found by title
   when the state file lost its number) and exits 3.
7. Hand-offs: for each open issue labelled `merging` (or `awaiting-integration`
   with a job file, the older shape): a live job is left alone; a dead job whose
   push has a tip ref is closed or parked; a dead job with no exit file re-runs
   its `run.sh` once (`setsid`, idempotent: a landed sha is not merged twice) or,
   failing that, is re-queued. Job files are
   `autocoder-merge-<repo-id>-<issue>.{pid,exit,run.sh,log}` under
   `<tmp-root>` (the older `autocoder-merge-<issue>.*` names are read
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

## H. `deploy.sh` and `release.sh` — what an environment runs (#200)

`promote.sh` decides which commit an environment *may* run; `deploy.sh` records
which one it *does*. It installs the checkout with the environment's own
`deploy`, `restart` and `check` commands from `.autocoder.json`, wrapped in a
GitHub Deployment (`in_progress`, then `success` or `failure`), after refusing a
dirty tree, an unlanded HEAD or a failing `preflight`. With `release: true` (or a
top-level `releaseOnDeploy`) a successful deploy runs `release.sh`, which cuts a
GitHub Release under the next `vYYYY.MM.DD.N` tag (`"tagScheme": "semver"` for
`vX.Y.Z`) and records it as a Deployment to `release`. `install-release-hook.sh`
adds a pre-push hook (`release-pre-push.sh`) that releases each push of the
integration branch from the main checkout. Exit codes: deploy 0 / 1 refused /
2 failed (recorded) / 3 deployed but the release failed. Kept portable to macOS
(bash 3.2, BSD tools). Full how-to: [docs/environments.md](../../../docs/environments.md#deploy-and-release).

## Hermetic merge gate: `gate.hermetic` (#223)

By default a gate runs the test command in the host environment, so a test that
quietly depends on the host (a tool on `PATH`, a file under `~/.config`, a newer
runtime) passes the gate and fails CI. A project opts in through its committed
`.autocoder.json`:

```json
"gate": {"hermetic": true,
         "path": ["~/.cargo/bin", "/usr/local/bin"],
         "env":  ["RUSTUP_HOME", "CARGO_HOME"]}
```

Every gate (merge job, sentinel, `promote.sh`) then runs the command under
`env -i` (`gate-env-fns.sh`): `PATH` is the declared `path` dirs (`~` is the
host home) plus `/usr/bin:/bin`; `HOME` is a fresh temporary directory, with
`XDG_*` under it, removed afterwards; `LANG=C.UTF-8`; and the variables named in
`env` are passed through. `PATH`, `HOME`, `XDG_*` and `LANG` cannot be overridden
by a declared name. Host tools (`omarchy`, `hyprctl`, user systemd) are absent
unless their directory is declared. The gate log prints `gate-env: hermetic …`
or `gate-env: host environment`.

The mode is read from the `.autocoder.json` committed in the tree being gated,
not from a working copy, so an uncommitted config does not switch it on. The
gate cache key includes a hash of the hermetic config, so a host-mode pass never
satisfies a hermetic gate, and changing `path` or `env` re-runs the gate. Off by
default: projects without `gate.hermetic: true` keep the same behaviour and
cache keys.

## Merge history: per-attempt logs and `merge-events.jsonl` (#184)

Every merge attempt keeps its own log. `merge-launch.sh` archives the previous attempt's
files as `<tmp-root>/autocoder-merge-<repo-id>-<issue>.<n>.log` and `.<n>.exit`.
The current attempt keeps the plain `.log` / `.exit` / `.pid` names, which `merge-poll.sh` reads.

`merge-to-integration.sh` appends one JSON line per event to
`${AUTOCODER_MERGE_EVENTS:-${XDG_STATE_HOME:-~/.local/state}/autocoder/merge-events.jsonl}`
(`merge-events-lib.sh`):

```json
{"ts":"2026-11-17T02:43:44Z","event":"attempt","outcome":"conflict","repo":"agents-5ea0ca80",
 "issue":184,"branch":"feature/issue-184","attempt":2,"escalated":false,
 "files":["src/a.sh"],"gate_tests_failed":[],"duration_s":41,"landed":null,
 "push_retries":0,"exit":1,"reason":null}
```

- `event`: `attempt` (one per job, its final outcome) or `push-retry` (one per rejected push).
- `outcome`: `landed`, `parked` (landed but not closed), `skipped` (nothing to do: the issue
  was already closed, or the commit was already landed and parked), `conflict`, `gate-failed`,
  `escalated` (to needs-clarification), `failed` (any other exit), or `push-retry`.
- `escalated`: true when the attempt went to a human rather than back to the worker (#207).
- `files`: conflicting files. `gate_tests_failed`: failing suites. Both are sorted and may be empty.
- `landed`: the commit pushed to the integration branch, when one was.

Lines older than `AUTOCODER_MERGE_EVENTS_DAYS` (default 30) are dropped once the file
passes 1 MiB. The file is created 0600. Recording is best effort and never fails a merge.
After a day, the post-merge sentinel archives a finished job's current log as the next
numbered attempt instead of deleting it. Archived attempts are pruned after
`AUTOCODER_MERGE_ARCHIVE_DAYS` (default 14). `tests/run-shell-suite.sh`
points the file at a temp path, so test runs never write to the real one.

### Flaky tests: same tree fails, then passes (#191)

A gate result is cached per `<tree, command>` (`gate-cache-fns.sh`), and a fail record also
keeps the failing test names and an excerpt of each failure. When the gate runs a tree it
has already seen fail and a test named in that record now passes, nothing changed but the
run, so the test is flaky. The merge job appends one `flaky` line per such test:

```json
{"ts":"2026-11-17T09:12:03Z","event":"flaky","outcome":"flaky","repo":"agents-5ea0ca80",
 "issue":191,"branch":"feature/issue-191","tree":"<tree sha>","test":"test_x.sh",
 "first_failure_excerpt":"FAIL  test_x.sh\n      | ..."}
```

`test` is null when the earlier record named no test (the gate as a whole flipped).

Set `AUTOCODER_GATE_FLAKE_RERUN=1` in the merge job's environment to re-run a failing gate
once on the same tree before calling it red. A clean re-run records the sightings and the
branch lands; a second failure is a real failure. By default the whole command re-runs.
`AUTOCODER_GATE_RERUN_CMD` re-runs only the failed tests: `{tests}` is replaced by their
names, e.g. `bash tests/run-shell-suite.sh {tests}` (the suite runner takes test names).
The narrowed re-run is used only when the first run's `Tests: N failed` summary counts
exactly the named tests (so no unnamed failure can hide behind a narrowed pass) and every
name is a plain word: characters in `[A-Za-z0-9._/:+-]`, no leading `-`, no `..`. Otherwise
the whole command re-runs. The count is read from the last `Tests: N failed` line in the
gate's output, so set `AUTOCODER_GATE_RERUN_CMD` only for a runner that prints that summary
last (as `tests/run-shell-suite.sh` does). At most 50 failing tests are recorded per run.
Without a `Failing suites:` line, only file-shaped names whose basename contains `test` or
`spec` are read from `FAIL` lines; free-text assertion messages are not test names.

`flaky-report.sh [--days N] [--repo ID] [--json]` lists the tests seen flaky in the last N
days (default 14), most sightings first, with the issues whose gates saw them.

## Issue lifecycle: `issue-events.jsonl` (#190)

The verbs that move an issue through its life append one JSON line each, at the moment
they act, to
`${AUTOCODER_ISSUE_EVENTS:-${XDG_STATE_HOME:-~/.local/state}/autocoder/issue-events.jsonl}`
(`issue-events-lib.sh`). It sits next to `merge-events.jsonl`, which keeps each merge
attempt's detail (conflicting files, failing suites, push retries). A UI builds an
issue's timeline from this file and the time between its events, without scraping
comments, labels or the merge job's temp files.

```json
{"v":1,"ts":"2026-11-17T03:10:02Z","repo":"agents-5ea0ca80","issue":190,"worker":"agents-wt-1",
 "branch":"feature/issue-190","event":"gate-end","detail":{"outcome":"conflict","attempt":1,
 "duration_s":41,"exit":1,"reason":"..."}}
```

This is a contract. Field set **version 1**:

- `v`: the field-set version. A reader skips lines whose `v` it does not know.
- `ts`: ISO-8601 UTC, when the event happened. Order a timeline by `ts`, not by line:
  `first-commit` is written once per issue, when its work first goes to the gate, but
  stamped with the commit's own time.
- `repo`: the repo id (`autocoder_repo_id`, shared by every worktree of a checkout).
- `issue`: the issue number, or `null` for the repo-wide `deployed` and `released-tag`.
- `worker`: `AUTOCODER_WORKER` (`<session>:<n>` in a swarm), else the worktree's dir name.
- `branch`: the issue branch, else the current branch.
- `event` and its `detail` keys:

| `event` | written by | `detail` |
|---|---|---|
| `claimed` | `issue_claim` | — |
| `released` | `issue_release`, `issue_requeue`, or `issue_update --remove-label working` without a hand-off label (`issue_handoff` and `issue_park` are hand-offs and record nothing) | `via` (`requeue`, when that) |
| `first-commit` | `merge-launch.sh`, once per issue | `sha` |
| `gate-queued` | `merge-launch.sh` | `attempt`, `sha` (the commit sent to the gate) |
| `gate-start` | `merge-to-integration.sh`, once it holds the landing queue | `attempt` |
| `gate-end` | `merge-to-integration.sh`, on every exit | `outcome` (as `merge-events.jsonl`), `attempt`, `duration_s`, `exit`, `reason` |
| `landed` | `merge-to-integration.sh` | `sha`, `integration` |
| `escalated` | `issue_escalate`, or `issue_update --add-label` of a blocking label (`add-blocking-label.sh`) | `label`, `reason` (first 200 characters) |
| `decomposed` | `issue_update --add-label decomposed` | `children` (from `AUTOCODER_EVENT_CHILDREN`) |
| `deployed` | `deploy.sh`, after the check passes | `environment`, `sha`, `deployment` |
| `released-tag` | `release.sh` | `tag`, `sha`, `environment` |

An issue counts as deployed or released once its `landed` sha is an ancestor of the
event's `sha`. A step can be recorded twice (a release by label and by `issue_release`);
a reader takes the first after each `claimed`. A merge job's own label cleanup is not
recorded as `released`. New events or detail keys may be added
within version 1; renaming or removing one bumps `v`.

Lines older than `AUTOCODER_ISSUE_EVENTS_DAYS` (default 30) are dropped once the file
passes 1 MiB. The file is created 0600. Recording is best effort and never fails the verb.
`tests/run-shell-suite.sh` points the file at a temp path.
