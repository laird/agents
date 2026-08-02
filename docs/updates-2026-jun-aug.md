# Autocoder Updates: June – August 2026

Changes from June 1 through August 2, 2026 (v4.1 → v4.9.1).

---

## New Issue Backends: Jira and Azure DevOps

Two new issue backends bring the same 9-verb contract (`list`, `get`, `update`, `comment`, `close`, `create`, `claim`, `release`, `any-claimable`) to Jira Cloud/Server and Azure DevOps Boards.

**Jira** (`--issue-source jira`):
- Connection settings (`baseUrl`, `project`) live in `.autocoder.json`; credentials come from `JIRA_EMAIL` + `JIRA_API_TOKEN` (or `JIRA_AUTH_HEADER` for Server/DC PATs)
- Claimable JQL ORs in `labels is EMPTY` so label-less issues are not silently dropped
- Backed by a stateful fake Jira server (`tests/fixtures/fake_jira.py`) for hermetic integration tests — no network required in CI
- Setup guide: `docs/jira-setup.md`

**Azure DevOps** (`--issue-source ado`):
- Connection settings (`orgUrl`, `project`) in `.autocoder.json`; credentials via `ADO_PAT`
- Labels map to work-item Tags
- Same stateful-fake integration test pattern (`tests/fixtures/fake_ado.py`)
- Setup guide: `docs/ado-setup.md`

Both backends register in all dispatchers and are selectable via `/set-issue-source`.

---

## Swarm Fleet Management

### Dynamic worker scaling

`add-worker.sh` joins an already-running parallel session: creates a new git worktree and pane, attaches to the existing tmux/cmux session, and focuses the new worker immediately. The manager can invoke it autonomously (Step 5b in `monitor-workers.md`) or a human can call it from the command line.

### Worker health monitoring and in-place restart

`worker-health.sh` reports per-worker RSS and stall age, flagging any process that is both stalled and high-memory as UNHEALTHY. `restart-worker.sh` kills a wedged worker and relaunches it in the same worktree and branch so it resumes its issue via the working label — no manual cleanup needed.

### Paused swarm mode

`start-parallel --paused` (also `--idle`) creates the full tmux session layout and worktrees without sending the self-claim loop command to workers. Workers sit at a ready prompt and can be started later with `start-workers.sh`. Useful for dry runs, staged rollouts, or manager-routed setups.

### Manager routing mode

`start-parallel --route manager` puts the manager in sole-assigner mode: workers launch their agent REPL but receive no self-claim command. The manager (`/autocoder:monitor-workers`) becomes the single dispatcher, issuing `/fix <N>` to idle workers one at a time. This structurally eliminates worker-vs-worker claim races. The routing mode is threaded to the manager window via `AUTOCODER_ROUTE`. Previous behavior (`--route self`) is unchanged.

---

## Robust Claiming and Scope Gate

### Race-safe claiming

- **File backend**: atomic rename — no TOCTOU between check and acquire
- **GitHub backend**: posts an `[autocoder-claim]` marker comment, waits 3 seconds, then verifies no competing markers before proceeding; all back-off paths call `issue_release` to fully undo the claim
- Specified-issue path (`/fix 42`) now uses `issue_claim`, matching the loop path

### Task scope gate

Before branch creation, the agent checks two conditions:

1. **CONTEXT FIT** — does the issue fit in a single agent context window?
2. **WORKTREE INDEPENDENCE** — does it touch files not being edited by other active workers?

If either fails, the issue is decomposed into sub-tasks. Sub-tasks include a "Files Affected" field so the swarm can verify no two parallel sub-tasks conflict.

### Fresh context per issue

`claude-worker-loop.sh` restarts the `claude` process as a new subprocess for each gate+fix cycle. Workers remain visible in their tmux panes (not hidden subagents) and each fix starts with a clean context window. Gemini workers switched to the same shell-mode pattern (`gemini -p` subprocess per issue).

### Model tiers

Manager defaults to `claude-opus-5`; workers default to `claude-sonnet-5`. Both are overridable via `MANAGER_MODEL` / `WORKER_MODEL` environment variables.

---

## Manager Improvements

### Proactive context handoff

`monitor-workers.md` Step 4c: when a worker reports ≥95% context used, the manager proactively triggers a handoff to a fresh worker rather than waiting for the worker to stall or error.

### Manager handoff and resume

Two new commands:

- `/manager-handoff` — saves current swarm state (active issues, worktrees, worker assignments) and exits cleanly so a new manager session can pick up
- `/manager-resume` — reads the handoff state and resumes monitoring with full context about what each worker was doing

### SRE monitor workflow

A new `sre-monitor` workflow watches a running tmux session, collects log output from worker panes, and surfaces errors and anomalies to the manager. Fully generic — no project-specific assumptions. The README includes a log-collection extension example.

---

## Git Workflow Hardening

Every fix now starts by creating a feature branch (`feature/issue-N`) from `origin/<integration-branch>`, or rebasing the existing branch if the worker was interrupted. On completion the branch is merged back to the integration branch via `merge-to-integration.sh`, pushed, and deleted locally.

The integration branch is auto-detected from `git symbolic-ref` (supports `main`, `master`, `integration`, etc.) rather than being hardcoded to `main`. Fixed a subtle bug where `sed` on empty input exits 0, causing the fallback to never fire.

These changes were propagated to the Codex, Droid, and Antigravity/Gemini platforms.

---

## Bug Fixes (July 28 batch)

- **#19** — `.autocoder.json` is now authoritative over a stale exported `ISSUE_SOURCE` environment variable. Previously, a cached `ISSUE_SOURCE=file` in the shell would silently override the repo's config, making the swarm appear idle with a live issue queue. A disagreeing inherited value is now reported on stderr instead of winning silently.
- **#20** — Portable `test-stat` parsing; a broken test suite no longer reads as green.
- **#18** — cmux liveness probe in multiplexer auto-detect; stale cmux socket no longer matches as a valid session.
- **#23/#26** — API push fallback when branch push fails; never close an issue that has no published PR yet.
- **#29** — `--idle` accepted as an alias for `--paused`.
- **#36** — Label reconciliation runs every cycle; one bad label can no longer void the edit.
- **#57** — GitHub backend uses `-label:` exclusion in blocking-label search (was missing the negation).
- **#58** — `test_issue_fns.sh` runs against its own repo rather than filing real issues against external projects.
- **#63** — `start-issue-work.sh` no longer exits 128 when `origin/HEAD` is absent.
- **#66** — Issues that already have an open PR are suppressed from the claimable queue.
- **#68** — Shell test suite now runs in CI.
- Fixed autocoder install failure caused by an unsupported `commands` key in the marketplace manifest.
- Fixed CI `cache: pip` directive that prevented the pytest job from running.

---

## Codex Platform Support

- Added Codex marketplace manifest
- Skills (`autocoder`, `modernize`) bundled inside their respective Codex plugin directories so the installed plugin cache is self-contained
- `merge-to-integration.sh` and Codex-specific `start-issue-work.sh` bring Codex workers to parity with the Claude Code workflow

---

## Antigravity / Gemini Branding Corrections

`.agent/` workflows and scripts updated to use correct Antigravity-specific paths (`.agent/` not `.claude/`), environment variable prefixes (`ANTIGRAVITY_` not `CLAUDE_CODE_`), and Gemini CLI invocation flags (`-p`, `-y`). Prose references updated throughout.

---

## Documentation

### Swarm quickstart guides

Four new per-platform quickstart docs (`docs/swarm-quickstart-{claude,gemini,codex,droid}.md`), each covering:

- Prerequisites and install steps (with "In your terminal" / "Inside a Claude Code session" labels)
- Correct `start-parallel <count> --agent <platform> --issue-source github` syntax
- ASCII art of the two-window tmux layout (window 0: worker panes, window 1: manager)
- tmux navigation table and link to the full cheat sheet
- Reattach, stop, and model-override instructions
- macOS cmux alternative note

### Issue backend documentation

`docs/jira-setup.md` and `docs/ado-setup.md` cover credentials, `.autocoder.json` configuration, test layers (unit stubs, stateful fake integration, optional real-instance smoke test), and common troubleshooting.

---

## Version History

| Version | Date | Highlights |
|---------|------|------------|
| 4.9.1 | 2026-08-02 | Fix quickstart doc syntax (`start-parallel` positional count) |
| 4.9.0 | 2026-08-02 | Swarm quickstart docs; SRE monitor; manager handoff/resume |
| 4.8.0 | 2026-07-31 | Gemini shell-mode workers; 95%-context proactive handoff |
| 4.6.0 | 2026-07-28 | Jira backend; hermetic integration tests |
| 4.5.2 | 2026-07-28 | Azure DevOps backend; full bug-fix batch |
| 4.5.1 | 2026-07-28 | `.autocoder.json` beats stale `ISSUE_SOURCE` env var |
| 4.5.0 | 2026-07-24 | Robust claiming; scope gate; fresh context per issue; model tiers |
| 4.4.0 | 2026-07-23 | `--route manager` mode |
| 4.3.0 | 2026-06-20 | Hardened git workflow with feature branches; Antigravity branding |
| 4.2.0 | 2026-06-05 | Worker health + restart; manager-driven scaling |
| 4.1.0 | 2026-06-03 | `add-worker`; paused swarm lifecycle; Codex platform support |
