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

- **Declared in the body**: every `#N` on a line that **starts** with
  `Depends on` or `Blocked by`, after any heading, list marker, checkbox, `[`,
  quote or bold (`Depends on: #N, #M`, `- **Blocked by #N**`; the decomposition
  template's `## Dependencies` section writes these). The words mid-sentence
  are prose and declare nothing (#181).
- **Never self-gating**: an issue never waits on itself, its parent
  (a line that starts with `Sub-task of #N`) or its own sub-tasks (issues whose body names it as their
  parent).
- **Native on GitHub**: open "blocked by" relationships, read for all open
  issues in one GraphQL query; skipped when there is no `origin` or the server
  has no issue dependencies.
- **Met** means the dependency's state is closed (`closed`, `done`, `resolved`,
  `completed`, `removed`). A dependency that can't be read counts as met, so a
  typo never wedges the queue.
- Waiting issues are named on stderr (`⏳ #350 waits on #347, #348`), and so
  are issues that wait on each other (`⚠ cycle: #367 ↔ #387`, or
  `⚠ cycle: #1 → #2 → #3 → #1`). They stay gated until a human breaks the
  cycle; prefer native "blocked by" links, which no wording can create.
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
> `${XDG_STATE_HOME:-~/.local/state}/autocoder/merge` (0700), else
> `/tmp/autocoder-<uid>` (0700) when the state dir cannot be made safe
> (`autocoder_tmp_root` in `repo-id-fns.sh`, #213, #272). The state dir is the
> default because it survives a reboot: on a tmpfs `/tmp` a reboot mid-merge used
> to delete the job's `.pid`/`.exit`/`.run.sh`, so a waiting worker never saw an
> exit code and the sentinel could not re-run the job. A candidate that is a
> symlink, is not ours, or is group/other-accessible and cannot be tightened is
> skipped, never used; falling back to `/tmp` prints one stderr line naming the reason.
> Nothing assumes the host (tmpfs or not, GNU or BSD `stat`, `sha1sum` or `shasum`). If you set `AUTOCODER_TMP`, point it at a directory only you
> can write: anything there may be executed. Upgrading moves the default root, so
> let in-flight merges finish first (or keep `AUTOCODER_TMP=/tmp/autocoder-<uid>`
> until they do): a job launched under the old root is not seen under the new one.
> The default depends on `$HOME`/`$XDG_STATE_HOME`, so a sentinel started from
> cron or systemd with a different environment than the workers must be given the
> same `AUTOCODER_TMP` (or the same `XDG_STATE_HOME`) to see their jobs.

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
`AUTOCODER_MERGE_ARCHIVE_DAYS` (default 14). Test runs never write to the real
file; see "Tests and the per-user state dir" below.

### Tests and the per-user state dir (#282)

Everything under `${XDG_STATE_HOME:-~/.local/state}/autocoder` (event logs,
landing timings, gate cache and `gate.jsonl`, merge and sentinel state, the
auth watchdog) is real data that `/retro`, `flaky-report.sh` and UIs read, so
the tests keep out of it two ways:

- `tests/lib/private-event-logs.sh`, sourced by every test, points each
  script-specific override and `XDG_STATE_HOME` itself at fresh private paths.
- `tests/run-shell-suite.sh` runs the suite under a scratch `HOME` (with the
  real `.gitconfig`, `.config`, `.cache` and `.local/{share,lib,bin}` symlinked
  in) and a private `XDG_STATE_HOME`. Anything written under the scratch
  `HOME`'s `.local/state` came from code that ignores `XDG_STATE_HOME`. It is
  listed and counted as a failed suite named `state-isolation`. The check uses
  a scratch home instead of a before/after diff of the real directory, because
  live workers on the same host keep appending to the real logs during a run.

Records an older suite left in the real logs can be removed with
`prune-test-events.sh`. It keeps a record only when its `repo` is the repo id
of a root in the swarm-roots registry, a `--root`, or a `--keep-repo`, and it
drops records with no repo. It dry-runs by default. `--apply` keeps a
`.bak-<stamp>` copy of each file and leaves alone any file that grows while it
runs. `landing-timings.jsonl` has no repo field, so it is not touched. Nothing
runs the script automatically.

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

## Revert rate: `revert-rate.sh` (#250)

`revert-rate.sh [--last N | --since DATE] [--ref REV] [--json]` reports how many landed
issues the sentinel reverted. A revert is a commit carrying the sentinel's
`Autocoder-Reverts:` trailer, and its issue comes from `Autocoder-Reverts-Issue:`. A
commit that only says "revert" in its message is not counted. A landed issue is a
non-merge commit whose subject starts `#N`, `Issue #N` or `Fix #N`, counted once however
many commits it has. The window is the newest N landed issues (default 50), ending at the
oldest commit of the oldest one, or every commit since DATE. With `--last`, a revert
counts only when the issue it names is one of the N; with `--since`, every sentinel revert
made in the window counts, so the rate can exceed 1. `--json` prints
`{window, landed, reverts, rate, reverted_issues}`; `rate` is `null` when nothing landed.
The ref defaults to `origin/HEAD`, else `HEAD`.

## Revert circuit breaker: `revert-breaker.sh` (#252)

When the sentinel has to revert too much of what lands, the breaker stops merging and
sends work to human review instead. After every revert it pushes, `main-sentinel.sh` runs
`revert-breaker.sh --ref origin/<integration>`. That reads `revert-rate.sh --last <window>`
and trips when at least `minReverts` of the newest `window` landed issues were reverted
and the rate is at or above `threshold`. Tripping opens one tracking issue labelled
`revert-breaker` and `needs-approval`, naming the window, the rate and the reverted
issues. While one is open, a later trip opens no other.

The open issue is the switch. While it is open, `merge-launch.sh` does not start a merge
job: it runs `revert-breaker.sh --land-as-pr`, which pushes the branch, opens a PR
(`gh pr create`, with the summary file as its body) and, with `--own-issue`, parks the
issue under `awaiting-integration`. Without `gh` (a repo not on GitHub) the pushed branch is
the review copy: the issue is parked with a note to merge it by hand. If the push or the
PR fails it exits 1 and changes no label. No merge job starts, so `merge-poll.sh` has
nothing to watch, and a PR needs no test command since a human reviews it. The check runs
after merge-launch's duplicate-job check, so a re-launch never opens a PR for work a
running job is already landing. A human closes the breaker issue to restore `merge`; no commit is needed, and
every worktree sees the change at its next launch. The breaker is checked only after a
revert, so if the window is still bad when it is closed, the next revert trips it again.
If the tracker cannot be read, the launch treats the breaker as closed rather than
stalling; a bad setting is reported on stderr and treated the same way.

Settings are in the main checkout's `.autocoder.json`:

```json
"revertBreaker": {"window": 20, "threshold": 0.15, "minReverts": 2}
```

Those are the defaults. `"revertBreaker": "off"` disables the breaker: it never trips,
and an issue left open from before no longer switches landing. `revert-breaker.sh
--active` exits 0 and prints the open issue's number, or exits 1 when none is open or
the breaker is off.

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
- `issue`: the issue number, or `null` for the repo-wide `deployed` and `released-tag`, and
  for a `ctl` command whose target is not an issue.
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
| `ctl` | `autocoder-ctl.sh`, after each command's result (not `help` or `status`); `issue` is the target when that is an issue number, else `null` | `action`, `target`, `ok` (boolean), `exit`, `actor`, `summary` (the result's `detail`, first 200 characters) |

An issue counts as deployed or released once its `landed` sha is an ancestor of the
event's `sha`. A step can be recorded twice (a release by label and by `issue_release`);
a reader takes the first after each `claimed`. A merge job's own label cleanup is not
recorded as `released`. New events or detail keys may be added
within version 1; renaming or removing one bumps `v`.

Lines older than `AUTOCODER_ISSUE_EVENTS_DAYS` (default 30) are dropped once the file
passes 1 MiB. The file is created 0600. Recording is best effort and never fails the verb.
`tests/run-shell-suite.sh` points the file at a temp path.

## Status for UIs (#193)

autocoder writes no files laid out for any particular UI. A UI, dashboard or monitor
reads the state that scripts publish, which comes out the same on every run:

| Question | Read |
|---|---|
| Which workers exist, what is each on, is it busy or idle? | `autocoder-ctl.sh status --json` ([docs/autocoder-ctl.md](../../../docs/autocoder-ctl.md#status)) |
| What happened to an issue, and when? | `issue-events.jsonl` (*Issue lifecycle*, above) |
| How did each merge attempt go? | `merge-events.jsonl` (*Merge history*, above) |
| What can the UI do to a worker or issue? | `autocoder-ctl.sh` verbs ([docs/autocoder-ctl.md](../../../docs/autocoder-ctl.md)) |

The commands themselves (`/fix`, `/monitor-workers`) write no status files. They
used to have the model write per-session JSON files for one UI; nothing updates
those any more, so a UI that still reads them should move to the sources above.

## Merge trains (`merge-train.py`, `train_lib.py`)

A merge train lands several READY branches as ONE tree: it is merged onto the integration branch,
gated once through `merge-to-integration.sh`, and the integration branch moves once. This is the
queue and planner half; it changes nothing on the remote and writes only its scratch worktree.

```
merge-train.py [--repo DIR] [--config FILE] [--no-fetch] queue [--in-flight N,N] [--status-line]
merge-train.py ...                                           plan  [--size N] [--in-flight N,N]
merge-train.py ...                                           reopen --issue N --member-branch B --landed SHA [--launched TS]
```

**READY pickup** goes through the issue-source abstraction (`issue_list`, `issue_get`), so every
backend works. An item is an open issue carrying every `readyLabels` label whose comments say READY
(`readyPattern`). The branch is the first backticked branch-shaped name of the newest READY comment that
exists on the remote; a later comment naming no branch never shadows it. Comment timestamps are used when
the backend reports them (GitHub) and are `None` otherwise (ADO and Jira report only a body; the file
backend keeps comments as blockquotes in the issue body, which are read back with their time). The queue
orders by `first` overrides, then lane labels (`laneLabels`), then priority (`priorityLabels`), then age
(the tracker's `createdAt` when `list` reports it, else the issue number), then number.

**Overrides file** (`overridesFile`, default under the train state dir), one row each:
`hold <issue> [reason]` never plan it; `first <issue>` plan it ahead of the order; `retry <issue>`
plan it although its tip was already launched. `#` lines and blank lines are ignored.

**Item states** printed by `queue`: `queue` (launchable), `launched` (this tip already launched), `hold`,
`in-flight` (`--in-flight`), `in-train`, `train-dropped` (a train dropped this tip; re-bank to offer it
again), `stale` (`staleDays`), `on-master` (the integration branch carries the branch's work: an ancestor, a patch-equivalent rebase, or the content itself after a squash landing; the note names the proof),
`conflict` (the merge-tree prefilter, or a real merge),
`driver-fault` / `generator-failed` (only when a `mergeFault` hook classifies the merge), `unchecked`
(`classifyLimit` launchable items were already found), `no-branch` (the READY names nothing on the remote).

**The planner** (`plan`) takes the next `size` launchable items, each merged for real into a scratch
worktree onto the integration branch plus the train so far, so the output is a train that assembles:

- the merge-tree prefilter decides first: a conflict in a path no merge driver owns skips the candidate at
  once, with no merge attempted;
- the planner then goes on to the NEXT candidate (a conflict never ends the plan);
- a branch already contained in the train so far (the lower slice of a stack whose tip is a member) rides
  as a member without a merge: stacks land at their tip;
- one real merge both judges and accepts a candidate; a failed merge is cleared before the next candidate;
  a conflict from a prefilter-clean candidate is the planner's fault, not the branch's (exit 2, `fault` row);
- every merge the planner (and the assembly) makes runs with the repository's HOOKS OFF
  (`git -c core.hooksPath=/dev/null`): a candidate's merge yields the verdict and the driver-resolved tree,
  nothing else. A post-merge hook that regenerates the tree runs ONCE, on the assembled tree, through
  `hooks.regenerate` (merge-train-run.py), never per candidate: measured on one project, the hook ran per
  accepted merge and a size-6 plan over 17 candidates took 27 minutes. Merge drivers are not hooks and still run;
- each candidate's probe is timed: `plan` prints `# plan: #<issue> <kind> <seconds>s` on stderr, and a cycle
  (merge-train-run.py) writes a `plan` row per candidate through the landing-timings writer, so the landing
  report shows planning time beside gate time.

Rows: `train <issue> <branch> <tip> <note>`, `skip <issue> <branch> <reason>`,
`drop <issue> <branch> <tip> <reason>`, and a final `fault <reason>` with exit 2 when the plan cannot be
trusted (nothing blames a branch for a fault of the scratch).

**`reopen`** reopens (state open, ready labels back, a comment saying why) an issue a landing closed while its
newest READY names a branch that landing did not carry; it prints `reopened` or `not reopened`.

**Configuration**: the `train` object of the main worktree's `.autocoder.json` (environment:
`AUTOCODER_TRAIN_SIZE`, `_STATE`, `_SCRATCH`, `_REMOTE`, `_INTEGRATION`):

```json
{ "train": { "readyLabels": ["ready-for-review"], "priorityLabels": ["P0","P1","P2","P3"],
             "laneLabels": ["hotfix"], "size": 4, "staleDays": 0, "classifyLimit": 0,
             "notePattern": "^\\[coordinator\\]", "preflightPattern": "=== preflight \\(enqueue\\.sh\\): PASS ===",
             "seedDirs": ["app/node_modules"], "seedMarker": ".package-lock.json",
             "hooks": { "prepareScratch": "make toolchain", "mergeFault": "./classify-merge.sh" } } }
```

`seedDirs` are hardlink-copied (never symlinked) from the repo into the scratch, and re-copied when the
marker file's inode changed (a reinstall). `hooks.prepareScratch` runs in the scratch before any candidate is
judged, because a merge driver whose generator cannot run falls back to a textual merge that reads as a
conflict: a failing hook stops the plan with a named fault. `hooks.mergeFault` receives the unmerged paths
on the first stdin line and the merge output after it, and may print `driver-fault<TAB>detail` (the
scratch's fault: stop) or `generator-failed<TAB>detail` (this candidate's merge: drop it for this plan).

Tests: `tests/test_merge_train.py` (a real git fixture repo and the file backend).

### Enqueue from a host that does not gate (`enqueue.sh`)

A worker on a host that cannot run the project's pre-check or gate (missing tools, a supervisor that
stops child processes, no test database) banks with `enqueue.sh --issue N` instead of the pre-check:

```
enqueue.sh --issue N [--branch B] [--repo DIR] [--remote NAME] [--integration BRANCH]
           [--preflight-cmd CMD] [--build-cmd CMD] [--test-cmd CMD] [--test-pattern REGEX]
           [--add-label L]... [--remove-label L]... [--note TEXT]... [--no-fetch] [--no-push] [--no-post] [--block-only]
```

The PREFLIGHT, in order, stopping at the first FAIL (the rest print SKIP): `fetch`; `rebase` (a clean
working tree, HEAD rebased onto `<remote>/<integration>` when behind; a conflict is aborted and FAILS
naming the files); `merge-tree` (clean, and the changed-file list is taken); then EITHER the project's
`preflight` command (its own rows, its exit status) OR the generic `build` (the configured
build-or-typecheck command) and `tests` rows (the configured test command with `{files}` replaced by the
changed files that match the test pattern; no matching file is a named SKIP); `push`
(`--force-with-lease`, since the rebase moved the tip). On PASS it posts the READY comment the queue reads
(`READY \`<branch>\` @ <tip>`, the block in a fence, the project preflight's last lines, every `--note`
line, such as a flag lifecycle line), adds the ready labels (`train.readyLabels`) and any `--add-label`,
removes the working label (`working`, or `train.enqueue.workingLabel`) and any `--remove-label`, and
records a `ready` landing-timings row. On FAIL nothing is pushed or posted (exit 1). `--block-only`
prints the block and stops; `--no-post` prints the comment instead of posting it.

Commands run through `bash -c` in the repository root with `AUTOCODER_ENQUEUE_BASE` (the integration tip
sha), `AUTOCODER_ENQUEUE_INTEGRATION`, `AUTOCODER_ENQUEUE_CHANGED_FILE` (one changed path per line) and,
for the tests row, `AUTOCODER_ENQUEUE_TEST_FILES`. Configuration, lowest precedence first: the
`train.enqueue` object of `.autocoder.json`, the environment (`AUTOCODER_ENQUEUE_PREFLIGHT_CMD`,
`_BUILD_CMD`, `_TEST_CMD`, `_TEST_PATTERN`, `_WORKING_LABEL`), the flags:

```json
{ "train": { "enqueue": { "preflightCmd": "scripts/preflight.sh",
                          "buildCmd": "make typecheck", "testCmd": "npm test -- {files}",
                          "testPattern": "\\.test\\.[a-z]+$", "workingLabel": "working" } } }
```

**How the queue takes it.** `pick_ready` reads the block (`preflightPattern`, default the
`=== preflight (enqueue.sh): PASS ===` header) and sets the item's `basis`: `preflight` for such a READY,
`ready` otherwise. The row is launchable like any other (the batch gate is its first full test), its note
says so when nothing else does, the status line counts `N preflight`, and `queue` prints `basis` as its
last column. Nothing in the planner or the train treats it differently: that is the point, a branch from a
non-gating host lands through the same gate as every other.

Tests: `tests/test_enqueue.sh` (every path against a fixture origin and the file backend, ending with the
queue planning the enqueued branch) and the preflight cases of `tests/test_merge_train.py`.

## Parallel gate stages (#7016)

A gate command that is one `&&` chain runs stages that do not depend on each other one after
another. `stage-runner.py` reads the stages from a JSON manifest in the project, runs the
independent ones at the same time inside a concurrency and a memory budget, and keeps what a chain
gave: each stage's bounded output, a failing stage's block before the verdict, the verdict as the
last line, and a timings summary. The project's doctrine file keeps its `### Regression Test Suite`
block as ONE command, now an invocation of the runner:

```bash
python3 "${AUTOCODER_SCRIPTS_DIR}/stage-runner.py" --manifest ci/gate-stages.json
```

`merge-to-integration.sh` exports `AUTOCODER_SCRIPTS_DIR` to the gate (a hermetic gate lists it in
`gate.env`), and it reads a `.json` manifest named in the gate command, so the scripts the manifest
runs still count as gate paths for the scoped re-gate. Full manifest reference: the docstring of
`stage-runner.py` (`--help` shows the CLI).

```json
{"version": 1, "concurrency": 4, "memory_budget_mib": 10000, "tree_guard": true,
 "stages": [
  {"name": "disk",    "cmd": "scripts/check-disk-space.sh",  "exclusive": true},
  {"name": "install", "cmd": "scripts/install-deps.sh",      "exclusive": true},
  {"name": "build",   "cmd": "npm run build",    "tail": 5,  "memory_mib": 6000, "est_s": 70},
  {"name": "lint",    "cmd": "scripts/check-lint.sh",        "est_s": 60},
  {"name": "types",   "cmd": "scripts/check-types.sh",       "memory_mib": 8000, "est_s": 120},
  {"name": "tests",   "wrapper": "scripts/with-test-db.sh {inner}",
   "stages": [{"name": "unit", "cmd": "npm test"}, {"name": "journey", "cmd": "scripts/journey.sh"}]}
 ]}
```

- **Ordering is declared.** `needs` names prerequisites; nothing is inferred. An `exclusive` stage
  is a barrier: it waits for every stage declared before it, runs alone, and every later stage waits
  for it. Mutating stages (regeneration, a baseline ratchet, the dependency install) are exclusive
  and declared before the stages that read the tree.
- **The tree guard** (`"tree_guard": true`) records HEAD's tree and the tracked-file diff after the
  last exclusive stage and fails the run if they differ when it ends, naming both. A group's
  `wrapper` can carry a guard or shared state of its own (an isolated database created once): the
  wrapper receives the group's inner schedule as one quoted argument.
- **Memory.** A stage's `memory_mib` counts against the budget (default: this process's cgroup
  `memory.max` minus 1 GiB) and is exported as `AUTOCODER_STAGE_MEMORY_MIB` for sizing a heap. A
  stage bigger than the budget still runs, alone.
- **Failure.** By default the first failure cancels the running stages and skips dependents
  (`"on_failure": "finish"` lets running ones end). Exit 1; a manifest error exits 2 before anything
  runs. `--serial` runs the same manifest one stage at a time, the chain's behaviour, for comparison.
- **Output is printed in manifest order**, so the log reads the same whatever finished first, and a
  heartbeat line keeps a no-output watchdog fed while an earlier stage is still running.
- **Timings.** `--timings out.json` (or `AUTOCODER_STAGE_TIMINGS_FILE`) records seconds, status and
  start offset per stage; `stage-runner.py --stage-args out.json` prints the `--stage name=secs`
  words `landing-timings-lib.sh`'s `landing_batch` takes.

Tests: `tests/test_stage_runner.py` (scripted stages) and the manifest case of
`tests/test_merge_scoped_regate.sh`.

## Reboot recovery: `reboot-recover.sh` and `worktree-issue.sh` (#274)

After a host reboot herdr restores panes and resumes each agent's session, but no
turn restarts. tmux restores nothing. The worktrees, their branches and their
uncommitted edits are still on disk. Recovery is split in two:

- `reboot-recover.sh [--project DIR]... [--dry-run]` starts **one manager per
  swarm**, and nothing else. A swarm is a repo main checkout with at least one
  `<repo>-wt-*` worktree. Swarms are found from `--project` and from the working
  directories of herdr's panes and workspaces. A swarm whose manifests all say
  `paused` is skipped. A restored manager pane in the repo root is prompted with
  the sentinel's wake prompt. Two or more such panes are reported, and none is
  prompted. With none, the script writes `.autocoder/wake` and runs
  `idle-sentinel.sh --once` for that root, so the sentinel does the spawn: it
  detects the multiplexer, checks no manager is alive, and records the manager in
  the manifest. The run prints what it detected (`host os=... scheduler=... mux=... boot_id=... state=...`). The sentinel's
  `reboot` wake calls it (#275), and it marks the nested sentinel run with
  `AUTOCODER_REBOOT_RECOVER=1` so that wake does not recurse.
- The manager does the worktrees (`manager-resume`, Step 4b). `worktree-issue.sh`
  prints, per `<repo>-wt-*` worktree, the issue its branch names
  (`feature/issue-N`, `enhancement/issue-N-auto`), whether it is open and claimed,
  and the command its worker should get: `/autocoder:fix N`, or
  `/autocoder:fix-loop` when the issue is closed or the branch names none.
  `--orphan-claims` lists the `working` claims whose worktree is gone; only those
  are released.

## Once per boot: boot triggers, the boot stamp and the swarm-roots registry (#275)

Nothing ran `reboot-recover.sh` at boot. Now two triggers can, and a shared
per-user stamp makes sure recovery runs once per boot, from whichever fires first.
`reboot-lib.sh` holds the shared state and the host detection:

- **Boot identity.** Linux `/proc/sys/kernel/random/boot_id`, else macOS
  `sysctl -n kern.boottime`, else none (the boot check is skipped with a log
  line). `AUTOCODER_BOOT_ID_FILE` overrides the file for tests.
- **State directory.** `${AUTOCODER_REBOOT_STATE_DIR:-${XDG_STATE_HOME:-~/.local/state}/autocoder}`
  holds `last-boot-id` (the boot last recovered) and `swarm-roots` (one swarm root
  per line, deduplicated). `start-parallel-agents.sh`, `add-worker.sh`,
  `swarm-register.sh` and `idle-sentinel.sh --ensure` add their root. On a tmux
  host, or with no multiplexer, the registry is the only thing that names the
  swarms after a reboot; herdr's panes stay an additional source.

`reboot-recover.sh --boot` (implies `--all`, which adds the registry's roots)
does nothing when the stamp matches this boot. Otherwise, under a per-user lock,
it waits for herdr when herdr is an enabled user service (`AUTOCODER_REBOOT_MUX_WAIT`,
90s; it never starts herdr itself), recovers every swarm, and only then writes
the stamp, so a crash mid-recovery is retried by the next trigger. No stamp yet
means a first run: it records the boot and recovers nothing.

The triggers:

1. **The host boot trigger**, installed by `reboot-recover.sh --install` (and by
   `idle-sentinel.sh --ensure` once the sentinel is scheduled). It detects the
   host and picks the first that works: a launchd agent with `RunAtLoad` on
   macOS; a systemd user unit `autocoder-reboot-recover.service` (`Type=oneshot`,
   `After=network-online.target`, `WantedBy=default.target`, with a warning
   and the `loginctl enable-linger` command when lingering is off). The unit is
   ordered on no unit autocoder does not own (#280): a host `herdr.service`
   with `After=default.target` would close a cycle through `WantedBy=`, and
   systemd breaks it by silently deleting the boot job. `--boot` waits for
   herdr itself. `--install` enables the unit, then runs
   `systemd-analyze --user verify default.target` and fails, disabling the unit
   again, when it reports an ordering cycle through it. `--dry-run` prints the
   ordering;
   a cron `@reboot` line; or none, which it says. Each runs
   `~/.local/bin/autocoder-reboot-recover --boot`: the same version-independent
   shim as the sentinel's (#273), which resolves `reboot-recover.sh` from the
   newest installed plugin when installed under that name. The PATH is the one
   `--install` ran with. `--install` records the current boot, so the next boot
   counts as a change.
2. **The sentinel's boot wake**, a backstop on hosts without the trigger. Before
   each tick (outside the tick lock) the sentinel compares the boot id with the
   same stamp; on a change it runs one `reboot` wake (a duty wake, exempt from
   dedup): `reboot-recover.sh --boot --project <root>`. A tick that
   `reboot-recover.sh` itself started (`AUTOCODER_REBOOT_RECOVER=1`) skips it.
   When it finds the stamp still old although the systemd boot unit is enabled
   and user-manager startup has finished, the unit did not do its job: it never
   started (its job was dropped) or it failed. The sentinel notifies once per
   boot, naming which (#280). On cron and launchd hosts it cannot tell "missed"
   from "not run yet", so it says nothing.

Tests: `tests/test_reboot_boot.sh` runs every path against fakes: systemd user,
cron only, launchd, no scheduler, no boot id, macOS `kern.boottime`, a tmux-only
host with registered roots, and herdr roots.

