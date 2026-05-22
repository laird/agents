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
5. Operate correctly when multiple agents work across multiple git worktrees of the same repository. All agents must coordinate against a single shared `.issues/` directory located in the main (primary) worktree, regardless of which worktree each agent runs in.

## Non-goals

- Backwards compatibility with the current flat `.issues/*.md` layout (one-shot migration only).
- Sharding closed issues by year or any other partition (flagged as a possible future change if closed-count goes to thousands).
- Cross-backend issue sync (e.g., mirroring gh into file). Out of scope; the existing `import-from-gh` / `export-to-gh` commands stay as-is.

## Design summary

Six structural changes, kept in one design because they are interlocking and migration must land together:

1. File backend layout becomes four buckets: `.issues/open/`, `.issues/working/`, `.issues/blocked/`, `.issues/closed/`. Blocked issues live in their own bucket so the `any-claimable` preflight remains O(1) even when most open work is gated on human input.
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
├── blocked/      <NNN>.md  — open but carries a blocking label (needs-design, needs-clarification, needs-feedback, needs-approval, too-complex, future, proposal)
├── closed/       <NNN>.md  — archival
└── .seq                    — authoritative monotonic counter (existing file, now the source of truth for issue numbers)
```

**Cross-worktree coordination.** `.issues/` always lives in the **main worktree** of the repository, never inside a secondary worktree's checkout. Agents working in secondary worktrees must resolve `ISSUE_DIR_PATH` to the main worktree's `.issues/` so that every agent — regardless of which worktree it runs in — shares a single set of bucket directories, a single `.seq` counter, and a single set of flock files.

`issue-config.sh` resolves the main worktree via `git worktree list --porcelain | head -1` and exports the resulting absolute path as `ISSUE_DIR_PATH`. All backend scripts (`issues-file.py`, `issues-gh.sh`, future `issues-jira.py`) MUST treat `ISSUE_DIR_PATH` as the single source of truth for the issue store. They MUST NOT construct alternate paths from `pwd`, the calling agent's worktree, or any environment variable other than `ISSUE_DIR_PATH`. The atomic-rename and flock invariants in §2 compose across worktrees only because every agent references the same on-disk paths; an agent that opened a worktree-local `.issues/` would silently fork the issue store and break claim atomicity for the whole fleet.

Each `<NNN>.md` retains today's frontmatter-plus-body shape (`number`, `title`, `labels`, `status`, `assignee`, `body`).

The `status` frontmatter field is still written for backward-readability of the file, but the directory location is authoritative. If the two disagree (e.g., a hand edit), the directory wins.

### Listing semantics

| Flag | Walks |
|---|---|
| `--state open` (default) | `open/*.md` only |
| `--state working` | `working/*.md` only |
| `--state blocked` | `blocked/*.md` only |
| `--state closed` | `closed/*.md` only |
| `--state all` | all four dirs |

This is a behavior change from today: `--state open` used to include `working` and blocked-labeled issues. Each is now its own state. Callers that need a combined view enumerate the states they want (e.g., `--state open` plus `--state blocked` for "all not-working, not-closed issues"), or use `--state all` and filter. We do not add `--state active` or other meta-states — explicitness is cheap and the user opted for simplicity over compat.

### Reading and modifying

A helper `resolve_path(number)` probes `open/`, `working/`, `blocked/`, `closed/` in that order and returns the first hit. Used by `get`, `update`, `comment`. Returns an error if the number does not exist in any bucket.

`resolve_path` is followed by `open(path)`, which can race with a concurrent rename and fail with `ENOENT` (the file moved buckets between the probe and the open). Callers must retry: `resolve_path` then `open` in a bounded loop (e.g., 3 attempts). After the bound, raise an error. Three attempts is sufficient in practice — a sustained rename storm on the same issue is itself a bug.

All read-modify-write paths continue to take `flock` on the file. `flock` covers contents; `rename` covers location.

**Normative requirement: all I/O inside a flock must use the locked file descriptor, never re-open the path.** Reads use `f.seek(0); f.read()`; writes use `f.seek(0); f.truncate(); f.write(...)`. The existing helpers `parse_issue_file(path)` and `write_issue_file(path, data)` open by path and must be refactored to take a file object (e.g., `parse_issue_file_fd(f)` / `write_issue_file_fd(f, data)`) or be inlined into the locked block. Call sites in `cmd_update`, `cmd_comment`, and `cmd_close` all change.

Without this, a concurrent `rename` between the outer `open()` and a path-based re-open inside the lock causes either a `FileNotFoundError` on read or — worse — a `mode="w"` re-create of the file at the now-empty source path, producing two files for the same issue number in different buckets. This refactor is part of this design, not a follow-up.

### Number allocation

`create` reads `.seq`, increments, writes back — all under `flock` on `.seq`. The result is the new issue number. The new file is always written to `open/`. No directory globbing during `create`.

`.seq` is initialized by the migration step to `max(all existing numbers across all four buckets, 0)`. Once initialized, no scan is ever performed for number allocation.

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

Release (target depends on labels, so flock-update precedes rename):

```python
src = issues_dir / "working" / f"{n:03d}.md"
with open(src, "r+") as f:
    lock_ex(f.fileno())
    try:
        data = parse_issue_file_fd(f)
        labels = data.get("labels") or []
        target_bucket = "blocked" if any(l in BLOCKING_LABELS for l in labels) else "open"
        # Clear the working label/status before renaming, via fd-based I/O.
        data["labels"] = [l for l in labels if l != "working"]
        data["status"] = "blocked" if target_bucket == "blocked" else "open"
        write_issue_file_fd(f, data)
    finally:
        unlock(f.fileno())
dst = issues_dir / target_bucket / f"{n:03d}.md"
try:
    os.rename(src, dst)
except FileNotFoundError:
    sys.exit(1)  # another agent already released; not racing for single-winner
```

`claim` is rename-first because it must enforce atomic single-winner under contention (§4 file row). `release` is flock-update-then-rename because the destination depends on labels that must be read under lock, and there is no single-winner contention to resolve at this step — `FileNotFoundError` on `os.rename` simply means another agent already released.

### Concurrency analysis

POSIX `rename(2)` is atomic within a single filesystem. `.issues/` and its subdirs are always on one filesystem, so atomicity holds. Two agents racing to claim the same file: exactly one wins; the other gets `FileNotFoundError`.

Three race patterns to reason about:

1. **Concurrent claim attempts.** First rename succeeds, second fails. Cleanly resolved by exit code. No flock involved.
2. **Comment during rename.** Agent A opens `open/042.md`, takes flock, starts an rmw using fd-based I/O (per §1's normative requirement). Agent B renames `open/042.md` → `working/042.md`. A's file descriptor still points to the inode (now at the new path); A's reads and writes go through the fd, so they land at the new location. A's flock and B's rename do not contend (rename operates on the directory entry, flock on the inode). Result: A's bytes are preserved, B's directory change is preserved.

   **This safety property is contingent on the §1 fd-based I/O requirement.** Any future change that re-opens by path inside the lock reintroduces a duplicate-file race and breaks the directory-is-authoritative invariant.
3. **Close during comment.** Same shape as (2) but the rename target is `closed/`. Same outcome: A's comment is preserved.

The benign-race property requires that the inode is not unlinked. We never `unlink` during state transitions — only `rename`. A future change that unlinks would break this and must be revisited.

### The `--if-unset` flag retires

Today `issue_update --add-label working --if-unset` exits 9 on a lost race. Under the new design the claim verb is `claim`, not `update --add-label working`. The `--if-unset` flag and its exit-9 contract are removed. Callers that used it (`fix-loop-gate.sh` and any sibling scripts) are rewritten to use `issue_claim N` and check its exit code.

### Blocking-label state transitions

The `blocked/` bucket is entered and exited via `update`. The blocking label set is exactly: `{needs-design, needs-clarification, needs-feedback, needs-approval, too-complex, future, proposal}`.

Transition rules:

- `update N --add-label X` where X is in the blocking set and `N` is in `open/`: take flock on `open/N.md`, update frontmatter (label appended), then `rename open/N.md → blocked/N.md`. The rename is the last step inside the lock release.
- `update N --remove-label X` where X was the last blocking label and `N` is in `blocked/`: take flock, update frontmatter (label removed), then `rename blocked/N.md → open/N.md`.
- `update N --add-label X` where `N` is in `working/`: the file stays in `working/` (an active claim takes priority over a blocking label). The frontmatter records the label. When the agent later releases the claim, `release` chooses the target bucket based on labels (see below).
- `release N` from `working/`: if frontmatter contains any blocking label, target is `blocked/`; otherwise `open/`. Either way it is a single `rename`.
- `claim N` only succeeds from `open/`. Claiming a `blocked/` issue is a usage error — blocked issues are not claimable by definition.

These transitions preserve the rename-based discipline: each state change is one POSIX `rename` (after frontmatter is settled under flock). The blocking-label set is hardcoded in the backend script (file and gh) and documented in the README so that the slash-command layer and the backend layer share a single source of truth.

## 3. Migration

A new subcommand: `issues-file.py migrate-layout`.

Steps:
1. Refuse to run if any of `open/`, `working/`, `blocked/`, `closed/` already contain `.md` files (already migrated).
2. `mkdir -p open/ working/ blocked/ closed/`.
3. For each `*.md` at the top level of `.issues/`: parse frontmatter, classify by precedence — `status: closed` → `closed/`; `status: working` → `working/`; any blocking label present (in the set defined in §2) → `blocked/`; otherwise → `open/`.
4. Initialize `.seq` to `max(existing numbers, 0)` if `.seq` is missing or below that value.
5. Print a one-line summary (counts per bucket).

No fallback: after migration, top-level `*.md` files in `.issues/` are not read. If `migrate-layout` is interrupted, partial state is recoverable by re-running it (only one direction; idempotent re-runs are blocked by step 1 — so partial state requires either manual completion or `rm -rf` on the empty bucket dirs).

A new slash command `/migrate-issues-layout` exposes the subcommand. `/set-issue-source` is updated to detect the old layout and run migration when `issueSource=file` is selected against a flat-layout directory.

## 4. Backend abstraction

### Uniform CLI contract

Every backend script (`issues-file.py`, `issues-gh.sh`, future `issues-jira.py`) implements:

```
<backend> list          [--state open|working|blocked|closed|all] [--label L] [--limit N]
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
- `1` — clean negative result. For `any-claimable`: no claimable issues. For `claim`: race lost (file not in `open/`). For `get` / `update` / `comment` / `close` / `release`: issue not found.
- `2` — usage error (bad flags).
- `3` — backend error (filesystem error, network failure, auth failure, parse error, etc.). Callers must treat this as an error condition, not a clean negative.

Backends must never print to stderr on the success path. The dispatcher relays both streams unmodified.

### Backend-native semantics for `claim` / `release` / `any-claimable`

| Backend | `claim N` | `release N` | `any-claimable` |
|---|---|---|---|
| file | `rename open/NNN.md → working/NNN.md` (atomic; on `FileNotFoundError`, exit 1 — race lost). On success, flock the file at its new path and update frontmatter (set `status: working`, append `working` label) via fd-based I/O. | Flock `working/NNN.md`, read labels via fd-based I/O, choose target (`blocked/` if any blocking label is set, else `open/`), clear `working` label and status in frontmatter, write via fd, unlock. Then `rename working/NNN.md → <target>/NNN.md`. `release` is not racing for atomic single-winner — `FileNotFoundError` here means another agent already released; exit 1. | `[ -d "${ISSUE_DIR_PATH}/open" ] \|\| exit 3; find "${ISSUE_DIR_PATH}/open" -maxdepth 1 -name '*.md' -print -quit \| grep -q .` (exit 0 if any file was printed, 1 if not, 3 if `open/` is missing). |
| github | `gh issue edit N --add-label working` then `gh issue view N --json labels` to confirm we set it (best-effort; see note below) | `gh issue edit N --remove-label working` | See block below. |
| jira (future) | `POST /rest/api/3/issue/N/transitions` to "In Progress", set assignee | Transition to "Open" (or to the project's blocked-equivalent status if any blocking label is set), clear assignee | JQL `status=Open AND assignee is EMPTY AND labels not in (needs-design, …)` with `maxResults=1` |

The github `any-claimable` implementation:

```bash
count=$(gh issue list --state open \
  --search 'no:label "working" no:label "needs-design" no:label "needs-clarification" no:label "needs-feedback" no:label "needs-approval" no:label "too-complex" no:label "future" no:label "proposal"' \
  -L 1 --json number --jq 'length') || exit 3
[ "$count" -gt 0 ]
```

The trailing bracket test produces the exit code the dispatcher relays: `0` if at least one claimable issue exists, `1` otherwise. A `gh` failure short-circuits to exit `3` (backend error), per the contract above. The file-backend command in the same table row already produces the right exit code natively (`0` if a file was printed, `1` if not); only the github row needs the explicit count-and-bracket form.

The same blocking-label exclusion applies to `list --state open` on the github backend: since gh has no bucket directories, `issues-gh.sh list --state open` filters out the blocking-label set in the search query to match the file backend's semantics. `list --state blocked` queries with `label:"needs-design" OR label:"needs-clarification" OR …`.

The abstraction is at the verb level; each backend picks its own mechanism. The file backend's `claim` is atomic by rename — exactly one winner under concurrent contention. The github backend's `claim` is **best-effort**: there is no atomic single-writer label edit in the gh API, so two agents racing to claim the same issue can both think they succeeded. This is a known limitation of label-based locking on GitHub and matches today's behavior. The proposed mitigation in `issues-gh.sh` is to re-read the issue immediately after adding the label and check whether the comment timestamp suggests another agent claimed concurrently — but this is heuristic, not atomic. Slash commands that depend on strict single-winner semantics (notably `fix-loop`) should treat the file backend as the strict-correctness path and document that the github backend may occasionally double-assign. A follow-up design for strict gh claim (using issue-comment tokens or a separate lock issue) is out of scope here.

### File layout

```
plugins/autocoder/scripts/
├── issue-config.sh     unchanged: detects ISSUE_SOURCE, exports env
├── issue-fns.sh        thin dispatcher (no inline backend logic)
├── issues-file.py      file backend (four-bucket layout)
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
issue_any_claimable
case $? in
  0) ;;  # work exists; fall through
  1) echo "No claimable issues. Nothing to do."; exit 0 ;;
  *) echo "Backend error while checking for claimable issues"; exit 1 ;;
esac
```

This runs *before* the GitHub-only setup (priority labels, identity switch) — those blocks move below the preflight. When there's no work, the LLM:

1. Reads the slash command (one-time cost per invocation).
2. Runs the preflight (one bash call, no python on the file backend).
3. Prints one line and exits.

No sub-agent dispatch, no triage, no plugin detection. The heavy logic of `fix.md` is skipped entirely.

### `fix-loop.md` outer loop

```bash
while [ -f "$LOOP_STATE_FILE" ]; do
  issue_any_claimable
  case $? in
    0) /fix ;;
    1) echo "[$(date +%H:%M:%S)] idle" ;;
    *) echo "[$(date +%H:%M:%S)] backend error — see above; will retry next tick" ;;
  esac
  sleep "$INTERVAL"
done
```

Idle iterations cost a `find` plus a `sleep`. Active iterations pay the full `/fix` LLM cost only when there's work. The loop body is bash; no LLM context is re-loaded between idle ticks.

### Why this works given the new layout

The file backend's `any-claimable` is implemented as the guarded form shown in §4 (`[ -d "${ISSUE_DIR_PATH}/open" ] || exit 3; find ... -print -quit | grep -q .`). With four buckets, this:

- Touches only `open/`, not `working/`, `blocked/`, or `closed/`.
- Stops at the first match (`-print -quit`).
- Spawns no python interpreter.
- Reads zero file contents.

On an idle repo (everything in `closed/` or `blocked/`), `find` returns immediately with empty output. On a busy repo with hundreds of `closed/` or `blocked/` files, the cost is unchanged — those buckets are not in the search path. The `blocked/` bucket exists precisely so this preflight stays O(1) even when most open work is gated on human input.

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
- Claim semantics (file backend, strict): `claim` succeeds, second `claim` on the same issue fails with exit 1, `release` succeeds. Single-winner is mandatory.
- Claim semantics (github backend, best-effort): `claim` succeeds; `release` round-trips the `working` label. Single-winner under concurrent contention is not asserted — see §4 ("github backend's `claim` is best-effort") for rationale. Any future backend whose native API supports atomic claim must pass the strict variant; a backend documenting a best-effort claim (like gh) passes only the round-trip variant.
- Comment append: `comment` then `get` returns the comment in `body`.
- Empty case: fresh repo, `any-claimable` exits 1 with empty stdout.
- Non-empty case: with one `open` issue, `any-claimable` exits 0.

## Migration plan (summary)

1. Land the four-bucket layout (`open/`, `working/`, `blocked/`, `closed/`) and `migrate-layout` subcommand. Existing user repos with flat `.issues/` are migrated by running the new command (or by invoking `/set-issue-source file` which detects and prompts).
2. Land `issues-gh.sh` extracted from `issue-fns.sh`. `issue-fns.sh` shrinks to dispatcher-only.
3. Land `any-claimable` and update `fix.md` / `fix-loop.md` preflight.
4. Land `README.md` with the contract and Jira walkthrough.
5. Rewrite `fix-loop-gate.sh` and any other `--if-unset` callers to use `issue_claim`.
6. Update every slash command that queried `--state open --label X` where X is in the blocking set, since those issues now live in `blocked/`:
   - `list-needs-design.md`, `list-needs-feedback.md`, `list-proposals.md`: change `--state open --label "<blocking>"` to `--state blocked --label "<blocking>"` (the `--label` filter remains in case multiple blocking labels are stacked on one issue).
   - `monitor-workers.md`: the blocking-label-exclusion jq filters (lines 130, 262 in the current file) become unnecessary — `--state open` already excludes blocked issues by directory. The `--state open --label "working"` queries (lines 82, 261) become `--state working`. The `issue_update --remove-label working` recovery step becomes `issue_release`.
   - Audit every other slash command for `--state open` queries that implicitly relied on blocked-labeled issues appearing there, and update accordingly.
7. Mirror all script and command changes to `.agent/workflows/` and `.agent/scripts/` per `CLAUDE.md`.

## Testing plan

- Unit-level: the `<backend>-tests.sh` contract suites, run once per backend in CI.
- Concurrency: a parallel-claim stress test for the file backend — N processes attempt to claim the same issue; assert exactly one succeeds and the others exit 1.
- Race shape (3): a comment-during-rename test that asserts the comment ends up in the post-rename file.
- Migration: a fixture with mixed open / working / blocked-labeled / closed flat-layout files; run `migrate-layout`; assert the bucket placement.
- Blocking transitions: starting from an `open/` issue, `update --add-label needs-design` ⇒ file is in `blocked/`; subsequent `update --remove-label needs-design` ⇒ file is back in `open/`. Same sequence from `working/` keeps the file in `working/` until `release`, then `release` lands it in `blocked/` because the label is still set.
- End-to-end: `fix-loop` over an empty `open/` for 30 seconds — assert no LLM invocations occurred (i.e., no `/fix` sub-process was spawned).
- Cross-worktree: create a secondary worktree via `git worktree add`, then from inside it invoke `issue_list --state open`, `issue_claim`, `issue_release`, and `issue_close`. Assert every operation targets the main worktree's `.issues/` directory (e.g., file appears in the main worktree's `.issues/working/`, not in the secondary worktree's pwd). Assert `ISSUE_DIR_PATH` resolves identically from both worktrees.

## Open questions for review

- Does the `--state open` semantics change (now excludes `working`) break any caller other than `monitor-workers`? Audit needed during implementation.
- For Jira: is the integer-vs-string issue-key question worth resolving in this design, or deferred until someone actually builds Jira support? (Default: defer; pin a placeholder in the README so the discussion happens at that time.)
- Should `any-claimable` accept filters (e.g., `--label P0`)? Probably yes for symmetry with `list`, but the simple boolean is what `fix.md` needs. Default: simple boolean now; extend if a need arises.

## Cross-references

- `plugins/autocoder/scripts/issues-file.py` — implementation target.
- `plugins/autocoder/scripts/issue-fns.sh` — dispatcher target.
- `plugins/autocoder/commands/fix.md`, `fix-loop.md`, `monitor-workers.md` — primary callers.
- `docs/superpowers/specs/2026-05-19-pluggable-issue-source-design.md` — predecessor design; partially superseded.
