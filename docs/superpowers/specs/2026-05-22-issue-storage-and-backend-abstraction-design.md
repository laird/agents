# Issue Storage Layout and Backend Abstraction

**Status:** Draft
**Date:** 2026-05-22
**Owner:** Autocoder plugin
**Supersedes (partially):** [2026-05-19 pluggable-issue-source design](2026-05-19-pluggable-issue-source-design.md) — keeps the pluggable-source goal, replaces the file storage layout and tightens the backend contract.

## Goals

1. Make `fix-loop`'s repeated scans for claimable issues cheap and constant-factor independent of closed-issue volume.
2. Make the "no work to do" path near-zero LLM token cost.
3. Make the gh and file backends *structurally parallel* so adding a new backend (Jira, Linear, …) is a drop-in, not a refactor.
4. Keep race-free concurrent claiming across parallel agents.

## Non-goals

- Backwards compatibility with the current flat `.issues/*.md` layout (one-shot migration only).
- Sharding closed issues by year or any other partition (flagged as a possible future change if closed-count goes to thousands).
- Cross-backend issue sync (e.g., mirroring gh into file). Out of scope; the existing `import-from-gh` / `export-to-gh` commands stay as-is.

## Design summary

Six structural changes, kept in one design because they are interlocking and migration must land together:

1. File backend layout becomes three buckets: `.issues/open/`, `.issues/working/`, `.issues/closed/`.
2. Claiming an issue (taking the work) is implemented as an atomic POSIX `rename(2)` between buckets — replacing the flock + `--if-unset` exit-9 contract.
3. One-shot migration script moves existing flat-layout files into the right buckets. No fallback path.
4. Each backend is a self-contained script implementing a uniform 8-verb CLI. `issue-fns.sh` becomes a pure dispatcher. The inline `_ifns_gh_*` functions are extracted into `issues-gh.sh`.
5. A new `any-claimable` verb returns boolean via exit code with empty stdout. `fix.md` and `fix-loop.md` use it as a preflight so idle ticks never invoke the heavy command body.
6. A new `plugins/autocoder/scripts/README.md` documents the backend contract and walks through adding a Jira backend.

## 1. File storage layout

```
.issues/
├── open/         <NNN>.md  — claimable
├── working/      <NNN>.md  — claimed by some agent
├── closed/       <NNN>.md  — archival
└── .seq                    — authoritative monotonic counter (existing file, now the source of truth for issue numbers)
```

Each `<NNN>.md` retains today's frontmatter-plus-body shape (`number`, `title`, `labels`, `status`, `assignee`, `body`).

The `status` frontmatter field is still written for backward-readability of the file, but the directory location is authoritative. If the two disagree (e.g., a hand edit), the directory wins.

### Listing semantics

| Flag | Walks |
|---|---|
| `--state open` (default) | `open/*.md` only |
| `--state working` | `working/*.md` only |
| `--state closed` | `closed/*.md` only |
| `--state all` | all three dirs |

This is a behavior change from today: `--state open` used to include `working` issues. Callers that need both must say `--state open` and `--state working` (or `--state all` and filter), or use `--state active` if we choose to add it (we won't, to keep the verb count down — explicitness is cheap and the user opted for simplicity over compat).

### Reading and modifying

A helper `resolve_path(number)` probes `open/`, `working/`, `closed/` in that order and returns the first hit. Used by `get`, `update`, `comment`. Returns an error if the number does not exist in any bucket.

`resolve_path` is followed by `open(path)`, which can race with a concurrent rename and fail with `ENOENT` (the file moved buckets between the probe and the open). Callers must retry: `resolve_path` then `open` in a bounded loop (e.g., 3 attempts). After the bound, raise an error. Three attempts is sufficient in practice — a sustained rename storm on the same issue is itself a bug.

All read-modify-write paths continue to take `flock` on the file. `flock` covers contents; `rename` covers location. They compose safely (see §2).

### Number allocation

`create` reads `.seq`, increments, writes back — all under `flock` on `.seq`. The result is the new issue number. The new file is always written to `open/`. No directory globbing during `create`.

`.seq` is initialized by the migration step to `max(all existing numbers across all dirs, 0)`. Once initialized, no scan is ever performed for number allocation.

## 2. Atomic claim and release

Claim:

```python
src = issues_dir / "open" / f"{n:03d}.md"
dst = issues_dir / "working" / f"{n:03d}.md"
try:
    os.rename(src, dst)
except FileNotFoundError:
    sys.exit(1)  # already claimed, or closed, or never existed
# Winner: open the file under flock and update frontmatter
# (status: working, labels gets "working" appended).
```

Release (inverse):

```python
src = issues_dir / "working" / f"{n:03d}.md"
dst = issues_dir / "open"    / f"{n:03d}.md"
try:
    os.rename(src, dst)
except FileNotFoundError:
    sys.exit(1)
# Then: open under flock, clear the "working" label and status.
```

### Concurrency analysis

POSIX `rename(2)` is atomic within a single filesystem. `.issues/` and its subdirs are always on one filesystem, so atomicity holds. Two agents racing to claim the same file: exactly one wins; the other gets `FileNotFoundError`.

Three race patterns to reason about:

1. **Concurrent claim attempts.** First rename succeeds, second fails. Cleanly resolved by exit code. No flock involved.
2. **Comment during rename.** Agent A opens `open/042.md`, takes flock, starts an rmw. Agent B renames `open/042.md` → `working/042.md`. A's file descriptor still points to the inode (now at the new path); A's writes land at the new location. A's flock blocks no one because the inode is the same. Result: A's bytes are preserved, B's directory change is preserved. Safe.
3. **Close during comment.** Same shape as (2) but the rename target is `closed/`. Same outcome: A's comment is preserved.

The benign-race property requires that the inode is not unlinked. We never `unlink` during state transitions — only `rename`. A future change that unlinks would break this and must be revisited.

### The `--if-unset` flag retires

Today `issue_update --add-label working --if-unset` exits 9 on a lost race. Under the new design the claim verb is `claim`, not `update --add-label working`. The `--if-unset` flag and its exit-9 contract are removed. Callers that used it (`fix-loop-gate.sh` and any sibling scripts) are rewritten to use `issue_claim N` and check its exit code.

## 3. Migration

A new subcommand: `issues-file.py migrate-layout`.

Steps:
1. Refuse to run if any of `open/`, `working/`, `closed/` already contain `.md` files (already migrated).
2. `mkdir -p open/ working/ closed/`.
3. For each `*.md` at the top level of `.issues/`: parse frontmatter, move to the bucket matching `status` (`closed` → `closed/`, `working` → `working/`, anything else → `open/`).
4. Initialize `.seq` to `max(existing numbers, 0)` if `.seq` is missing or below that value.
5. Print a one-line summary.

No fallback: after migration, top-level `*.md` files in `.issues/` are not read. If `migrate-layout` is interrupted, partial state is recoverable by re-running it (only one direction; idempotent re-runs are blocked by step 1 — so partial state requires either manual completion or `rm -rf` on the empty bucket dirs).

A new slash command `/migrate-issues-layout` exposes the subcommand. `/set-issue-source` is updated to detect the old layout and run migration when `issueSource=file` is selected against a flat-layout directory.

## 4. Backend abstraction

### Uniform CLI contract

Every backend script (`issues-file.py`, `issues-gh.sh`, future `issues-jira.py`) implements:

```
<backend> list          [--state open|working|closed|all] [--label L] [--limit N]
<backend> get            <number>
<backend> update         <number> [--add-label L] [--remove-label L] [--status S] [--assignee A]
<backend> comment        <number> --body "..."
<backend> close          <number> [--comment "..."]
<backend> create         --title "..." --body "..." [--label L ...]
<backend> claim          <number>
<backend> release        <number>
<backend> any-claimable
```

### Output schema

All read commands (`list`, `get`) produce JSON matching today's `to_gh_json` shape:

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

`list` produces a JSON array of these. Write commands (`update`, `comment`, `close`, `create`, `claim`, `release`) produce no required output; `create` may print `{"number": N}` on stdout.

### Exit-code contract

- `0` — success. For `any-claimable`: at least one claimable issue exists.
- `1` — generic failure (issue not found, claim lost, etc.). For `any-claimable`: no claimable issues.
- `2` — usage error (bad flags).

Backends must never print to stderr on the success path. The dispatcher relays both streams unmodified.

### Backend-native semantics for `claim` / `release` / `any-claimable`

| Backend | `claim N` | `release N` | `any-claimable` |
|---|---|---|---|
| file | `rename open/NNN.md → working/NNN.md` then flocked frontmatter update | `rename working/NNN.md → open/NNN.md` then flocked frontmatter update | `find open/ -maxdepth 1 -name '*.md' -print -quit` (pure shell) |
| github | `gh issue edit N --add-label working` then `gh issue view N --json labels` to confirm we set it (best-effort; see note below) | `gh issue edit N --remove-label working` | `gh issue list --state open --search 'no:label "working"' -L 1 --json number --jq 'length \| . > 0'` |
| jira (future) | `POST /rest/api/3/issue/N/transitions` to "In Progress", set assignee | Transition to "Open", clear assignee | JQL `status=Open AND assignee is EMPTY` with `maxResults=1` |

The abstraction is at the verb level; each backend picks its own mechanism. The file backend's `claim` is atomic by rename — exactly one winner under concurrent contention. The github backend's `claim` is **best-effort**: there is no atomic single-writer label edit in the gh API, so two agents racing to claim the same issue can both think they succeeded. This is a known limitation of label-based locking on GitHub and matches today's behavior. The proposed mitigation in `issues-gh.sh` is to re-read the issue immediately after adding the label and check whether the comment timestamp suggests another agent claimed concurrently — but this is heuristic, not atomic. Slash commands that depend on strict single-winner semantics (notably `fix-loop`) should treat the file backend as the strict-correctness path and document that the github backend may occasionally double-assign. A follow-up design for strict gh claim (using issue-comment tokens or a separate lock issue) is out of scope here.

### File layout

```
plugins/autocoder/scripts/
├── issue-config.sh     unchanged: detects ISSUE_SOURCE, exports env
├── issue-fns.sh        thin dispatcher (no inline backend logic)
├── issues-file.py      file backend (three-bucket layout)
├── issues-gh.sh        NEW: gh backend extracted from issue-fns.sh
├── issues-file.py-tests.sh    contract tests for file backend
├── issues-gh.sh-tests.sh      contract tests for gh backend
└── README.md           NEW: backend contract and "how to add Jira"
```

The same `.agent/scripts/` parallel files mirror this (per the parallel-maintenance rule in `CLAUDE.md`).

### `issue-fns.sh` after the change

```bash
_ifns_BACKEND_SCRIPT=$(case "$ISSUE_SOURCE" in
  github) echo "issues-gh.sh"   ;;
  file)   echo "issues-file.py" ;;
  *)      echo "$ISSUE_BACKEND" ;;
esac)
_ifns_BACKEND_BIN="${_ifns_DIR}/${_ifns_BACKEND_SCRIPT}"

issue_list()          { "$_ifns_BACKEND_BIN" list          "$@"; }
issue_get()           { "$_ifns_BACKEND_BIN" get           "$@"; }
issue_update()        { "$_ifns_BACKEND_BIN" update        "$@"; }
issue_comment()       { "$_ifns_BACKEND_BIN" comment       "$@"; }
issue_close()         { "$_ifns_BACKEND_BIN" close         "$@"; }
issue_create()        { "$_ifns_BACKEND_BIN" create        "$@"; }
issue_claim()         { "$_ifns_BACKEND_BIN" claim         "$@"; }
issue_release()       { "$_ifns_BACKEND_BIN" release       "$@"; }
issue_any_claimable() { "$_ifns_BACKEND_BIN" any-claimable; }
```

The `_ifns_gh_list`, `_ifns_gh_update`, `_ifns_gh_close`, `_ifns_gh_create` helper functions are moved into `issues-gh.sh` as subcommand bodies. All `case "$ISSUE_SOURCE"` blocks inside `issue_*` functions go away.

## 5. Zero-cost idle check

### `fix.md` preflight

The first executable block in `fix.md` becomes:

```bash
if ! issue_any_claimable; then
  echo "No claimable issues. Nothing to do."
  exit 0
fi
```

This runs *before* the GitHub-only setup (priority labels, identity switch) — those blocks move below the preflight. When there's no work, the LLM:

1. Reads the slash command (one-time cost per invocation).
2. Runs the preflight (one bash call, no python on the file backend).
3. Prints one line and exits.

No sub-agent dispatch, no triage, no plugin detection. The heavy logic of `fix.md` is skipped entirely.

### `fix-loop.md` outer loop

```bash
while [ -f "$LOOP_STATE_FILE" ]; do
  if issue_any_claimable; then
    /fix
  else
    echo "[$(date +%H:%M:%S)] idle"
  fi
  sleep "$INTERVAL"
done
```

Idle iterations cost a `find` plus a `sleep`. Active iterations pay the full `/fix` LLM cost only when there's work. The loop body is bash; no LLM context is re-loaded between idle ticks.

### Why this works given the new layout

The file backend's `any-claimable` is implemented as `find "${ISSUE_DIR_PATH}/open" -maxdepth 1 -name '*.md' -print -quit`. With three buckets, this:

- Touches only `open/`, not `working/` or `closed/`.
- Stops at the first match (`-print -quit`).
- Spawns no python interpreter.
- Reads zero file contents.

On an idle repo (everything in `closed/`), `find` returns immediately with empty output. On a busy repo with hundreds of `closed/` files, the cost is unchanged — closed files are not in the search path.

## 6. README: how to add a new issue tracker

`plugins/autocoder/scripts/README.md` (new file) contains:

### Section A — Architecture overview

- `issue-config.sh` detects the configured `ISSUE_SOURCE` and exports it (and any backend-specific env, e.g., `ISSUE_DIR_PATH` for file).
- `issue-fns.sh` exposes the `issue_*` shell functions and dispatches each to the appropriate backend script.
- `issues-<backend>` scripts implement the 8-verb CLI. They are independent — one backend's bugs cannot affect another.

### Section B — The backend contract

A backend is a script that:
- Implements all 9 subcommands (8 verbs + `any-claimable`).
- Honors the exit-code contract.
- Produces the standard JSON schema on read paths.
- Is idempotent where the verb is idempotent (e.g., adding a label that's already present; closing an already-closed issue).
- Documents its config requirements (env vars, config-file keys).

### Section C — Walkthrough: adding Jira

1. **Decide the mapping.** Jira concepts ↔ contract concepts:
   - Jira issue status (Open / In Progress / Done) ↔ open / working / closed.
   - Jira assignee ↔ used as the claim mechanism (set on claim, clear on release).
   - Jira labels ↔ labels.
   - Jira issue key (e.g., `PROJ-42`) ↔ issue number. Since the contract uses integer numbers, decide whether to strip the project prefix or to widen the contract to accept arbitrary string IDs. (Recommendation: widen the contract; document the constraint that backends must round-trip identifiers as strings.)

2. **Write `issues-jira.py`.** Use Jira's REST API. One function per verb. Map error responses to the contract's exit codes.

3. **Wire up `.autocoder.json`.** New keys: `jiraBaseUrl`, `jiraProjectKey`, plus a pointer to where the API token is stored (env var; never commit tokens).

4. **Update `issue-config.sh`** to read these keys when `issueSource = "jira"` and export them.

5. **Update `issue-fns.sh`** with one new case: `jira) echo "issues-jira.py" ;;`.

6. **Update `/set-issue-source`** to prompt for Jira config when the user picks Jira, and validate by running `issues-jira.py list --limit 1` against the configured project.

7. **Add `issues-jira.py-tests.sh`** that walks the contract: create / get / update / comment / list / claim / release / close / any-claimable, asserting standard JSON shape and exit codes.

8. **Run the contract tests.** Every backend passes the same suite. If a backend can't implement a verb cleanly (e.g., comments are an audit-trail feature in Jira and have richer semantics), document the deviation in this README and provide a compatible projection.

### Section D — What NOT to do

- Don't add per-backend branches inside slash commands. Slash commands call `issue_*` functions; backends decide how.
- Don't reach past the abstraction (don't call `gh` or `python3 issues-file.py` directly from slash commands).
- Don't bake gh-specific label semantics into commands. Labels are arbitrary backend strings. The set of meaningful labels (`P0`–`P3`, `working`, `needs-design`, etc.) is documented in the slash-command layer, not the backend layer.

### Section E — Contract test list

Each backend ships a `<backend>-tests.sh` that exercises:

- Round-trip: `create`, `get`, `list`, `close`, `list --state closed`.
- Label ops: `update --add-label`, `update --remove-label`, idempotent add.
- Claim semantics: `claim` succeeds, second `claim` fails with exit 1, `release` succeeds.
- Comment append: `comment` then `get` returns the comment in `body`.
- Empty case: fresh repo, `any-claimable` exits 1 with empty stdout.
- Non-empty case: with one `open` issue, `any-claimable` exits 0.

## Migration plan (summary)

1. Land the three-bucket layout and `migrate-layout` subcommand. Existing user repos with flat `.issues/` are migrated by running the new command (or by invoking `/set-issue-source file` which detects and prompts).
2. Land `issues-gh.sh` extracted from `issue-fns.sh`. `issue-fns.sh` shrinks to dispatcher-only.
3. Land `any-claimable` and update `fix.md` / `fix-loop.md` preflight.
4. Land `README.md` with the contract and Jira walkthrough.
5. Rewrite `fix-loop-gate.sh` and any other `--if-unset` callers to use `issue_claim`.
6. Update `monitor-workers.md` to use `--state working` and `issue_release` rather than `--remove-label working`.
7. Mirror all script changes to `.agent/scripts/` per `CLAUDE.md`.

## Testing plan

- Unit-level: the `<backend>-tests.sh` contract suites, run once per backend in CI.
- Concurrency: a parallel-claim stress test for the file backend — N processes attempt to claim the same issue; assert exactly one succeeds and the others exit 1.
- Race shape (3): a comment-during-rename test that asserts the comment ends up in the post-rename file.
- Migration: a fixture with mixed open/working/closed flat-layout files; run `migrate-layout`; assert the bucket placement.
- End-to-end: `fix-loop` over an empty `open/` for 30 seconds — assert no LLM invocations occurred (i.e., no `/fix` sub-process was spawned).

## Open questions for review

- Does the `--state open` semantics change (now excludes `working`) break any caller other than `monitor-workers`? Audit needed during implementation.
- For Jira: is the integer-vs-string issue-key question worth resolving in this design, or deferred until someone actually builds Jira support? (Default: defer; pin a placeholder in the README so the discussion happens at that time.)
- Should `any-claimable` accept filters (e.g., `--label P0`)? Probably yes for symmetry with `list`, but the simple boolean is what `fix.md` needs. Default: simple boolean now; extend if a need arises.

## Cross-references

- `plugins/autocoder/scripts/issues-file.py` — implementation target.
- `plugins/autocoder/scripts/issue-fns.sh` — dispatcher target.
- `plugins/autocoder/commands/fix.md`, `fix-loop.md`, `monitor-workers.md` — primary callers.
- `docs/superpowers/specs/2026-05-19-pluggable-issue-source-design.md` — predecessor design; partially superseded.
