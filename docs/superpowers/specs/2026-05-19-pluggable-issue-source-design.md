# Pluggable Issue Source Design

**Date:** 2026-05-19
**Status:** Draft

## Summary

Add support for a file-based issue list (`ISSUES.md`) as an alternative to GitHub Issues, with an extensible backend system so additional sources (Jira, Linear, etc.) can be added by implementing a standard contract. The system auto-detects the available source, confirms with the user, and caches the choice. A `/set-issue-source` command allows switching at any time, with optional migration of existing issues.

All existing commands (`/fix`, `/fix-loop`, `/review-blocked`, etc.) work unchanged against any backend — they route through a shared shell function layer (`issue_list`, `issue_get`, `issue_update`, `issue_comment`, `issue_close`, `issue_create`) that dispatches to the configured backend. No command file knows or cares which backend is active.

New user-facing commands provide explicit issue management: `/record-issue` to create, `/update-issue` to modify labels/status, `/close-issue` to resolve, `/list-issues` to browse — all backend-transparent.

The system works across all supported agent frameworks: Claude Code, Antigravity, Factory.ai/Droid, and OpenAI/Codex. The shell function layer and backend contract are framework-agnostic; framework-specific wiring is limited to command registration.

### Terminology

**Issue** (this document): a large developer-facing work item — equivalent to a GitHub Issue, Jira ticket, or Linear task. These are the units of work a dev team plans and tracks: "Add dark mode," "Fix login bug." Managed by this system.

**Task** (agent-internal): the fine-grained coordination primitives Claude Code and other agent frameworks use internally while executing a single issue (e.g., `TaskCreate`, `TaskUpdate`). Tasks are ephemeral, scoped to one agent session, and are not persisted by this system.

These two concepts are distinct and should not be conflated in code, documentation, or conversation.

---

## Section 1: Detection & Confirmation Flow

When `/fix`, `/fix-loop`, or any issue-consuming command starts, it runs a detection step before doing any issue work.

### Detection Order

1. **Check `.autocoder.json`** — if present and contains `issueSource`, skip detection entirely and use the cached choice.

2. **Check for a local issues file** — look for `ISSUES.md` (case-insensitive) in the main worktree root (`git worktree list --porcelain | grep -m1 "^worktree" | cut -d' ' -f2`), or at the path specified by `issueFile` in `.autocoder.json` if present.
   - If found: inform the user (`"Found ISSUES.md — using it as the issue source"`) and ask for confirmation.
   - On confirmation: cache to `.autocoder.json` (with `issueSource: "file"` and `issueFile: "<path>"`) and proceed.

3. **Check for a GitHub remote** — only if no local file found. Check if the repo has a `github.com` remote.
   - If found: inform the user (`"No local issues file found. This repo is on GitHub — using gh issues"`) and confirm.
   - On confirmation: cache to `.autocoder.json` and proceed.

4. **Neither found** — ask the user to choose:
   - Brainstorm what to work on and create issues in a new `ISSUES.md`
   - Brainstorm and push issues to GitHub (only offered if repo has a `github.com` remote)

### Non-Interactive Behavior

If `issue-config.sh` is invoked with no TTY (e.g., `/fix-loop` running autonomously in a tmux pane) and no cached config exists in `.autocoder.json`, it **fails immediately** with a clear error:

```
Error: No issue source configured.
Run /set-issue-source to choose an issue source before running autonomous commands.
```

Detection and user confirmation are interactive-only. Autonomous agents always require prior configuration.

### Caching

After the user confirms a source, the choice is saved to `.autocoder.json` at the repo root. Future invocations skip detection. The user can re-trigger detection by running `/set-issue-source` or deleting `.autocoder.json`.

---

## Section 2: ISSUES.md Format

Each issue is wrapped in `<!-- issue -->` / `<!-- /issue -->` HTML comment tags. Inside, a YAML frontmatter block (delimited by `---`) is followed by a Markdown body. The HTML comment tags are the unambiguous issue boundary; `---` appears only as the YAML frontmatter delimiter within that boundary and cannot be confused with a body thematic break. The file is human-readable and hand-editable.

### Example

```markdown
<!-- issue -->
---
number: 1
title: Fix the login bug
priority: P1
labels: [bug]
status: open
---
Users report they can't log in when using SSO. Steps to reproduce: ...

---

This horizontal rule is part of the body — the parser ignores it because only `<!-- /issue -->` ends the issue.
<!-- /issue -->

<!-- issue -->
---
number: 2
title: Add dark mode
priority: P2
labels: [enhancement]
status: working
assignee: feat-darkmode
---
We need dark mode support across all UI components.

> **2026-05-19 14:32** 🤖 Automated Fix Started — working on dark mode
<!-- /issue -->

<!-- issue -->
---
number: 3
title: Refactor auth module
priority: P3
labels: [needs-design]
status: closed
---
Completed: extracted auth into standalone package.
<!-- /issue -->
```

### Field Reference

| Field | Values | Purpose |
|-------|--------|---------|
| `number` | integer | Unique ID; auto-incremented on create |
| `title` | string | Issue title |
| `priority` | `P0`–`P3` | Priority, same semantics as GitHub labels |
| `labels` | YAML list | Same label names as GitHub (`needs-design`, `needs-approval`, `bug`, etc.) |
| `status` | `open` \| `working` \| `closed` | Distributed lock; agents only claim `open` issues |
| `assignee` | worktree name | Set when `status: working`; identifies which worktree holds the issue |

### Comments

Comments (equivalents of `gh issue comment`) are appended as Markdown blockquotes at the end of the issue body, with a timestamp:

```markdown
> **2026-05-19 14:32** 🤖 Automated Fix Started — working on P1 bug in login flow
```

### Worktree Coordination

- `ISSUES.md` lives at the **main worktree root** (found via `git worktree list --porcelain | grep -m1 "^worktree" | cut -d' ' -f2`). Every branch worktree resolves this path at startup and operates on the single shared file — never a local copy.
- All read-modify-write operations inside `issues-file.py` use `fcntl.flock(fd, fcntl.LOCK_EX)` for atomic access. This is part of Python's standard library on both macOS and Linux — no external tools required. The shell scripts never write to `ISSUES.md` directly; all writes go through `issues-file.py`.
- Setting `status: working` + `assignee: <worktree-name>` is done atomically under the lock, claiming an issue for one agent at a time — equivalent to the GitHub `working` label.
- Multiple worktrees running simultaneously all resolve the same absolute path (the main worktree's `ISSUES.md`) and coordinate through file locking on that single file. No branch worktree ever has its own copy of the issue list.

---

## Section 3: Script Architecture

### New Scripts

#### `scripts/issue-config.sh`

Runs the detection flow described in Section 1. Sources by all issue-consuming scripts at startup. Exports:

- `ISSUE_SOURCE` — `github`, `file`, or custom backend name
- `ISSUE_FILE_PATH` — resolved absolute path to `ISSUES.md` (file mode only)
- `ISSUE_BACKEND` — path to the backend script

#### `scripts/issues-file.py`

Python script implementing all ISSUES.md read/write operations. Uses Python's `fcntl.flock(fd, fcntl.LOCK_EX)` for safe concurrent access across worktrees — no external tools required.

Subcommands:

| Subcommand | Description |
|-----------|-------------|
| `list [--label L] [--state open\|closed]` | Output JSON array |
| `get <number>` | Output JSON object |
| `update <number> [--add-label L] [--remove-label L] [--status S] [--assignee A]` | Modify issue in-place |
| `comment <number> --body "..."` | Append blockquote comment |
| `close <number> [--comment "..."]` | Set `status: closed`, append comment |
| `create --title "..." --body "..." [--label L]` | Append new issue, output `{"number": N}` (priority arrives pre-translated as `--label P1` by `issue-fns.sh`) |
| `find-main-worktree` | Print absolute path to main worktree |
| `import-from-gh` | Pull open GH issues and append as ISSUES.md entries |
| `export-to-gh` | Create GH issues from open ISSUES.md entries |

All `list`/`get` output uses the same JSON schema as `gh issue list/view` so downstream parsing is backend-agnostic.

### Migration Scope

**All** files in `plugins/autocoder/commands/` and `plugins/autocoder/scripts/` that contain `gh issue` calls are in scope. Every such call is replaced with the corresponding `issue_*` function from `issue-fns.sh`. The complete list:

| File | Approximate call count | Primary change |
|------|----------------------|----------------|
| `commands/fix.md` | 46 | Replace all `gh issue` calls with `issue_*` functions |
| `commands/approve-proposal.md` | 3 | Same |
| `commands/brainstorm-issue.md` | 5 | Same |
| `commands/full-regression-test.md` | 10 | Same |
| `commands/list-needs-design.md` | 7 | Becomes thin wrapper over `issue_list --label needs-design` |
| `commands/list-needs-feedback.md` | 9 | Becomes thin wrapper over `issue_list --label needs-feedback` |
| `commands/list-proposals.md` | 7 | Becomes thin wrapper over `issue_list --label proposal` |
| `commands/monitor-workers.md` | 6 | Same |
| `scripts/fetch-blocked-issues.sh` | — | Replace `gh issue list` with `issue_list` dispatch |
| `scripts/add-blocking-label.sh` | — | Replace `gh issue edit` / `gh issue comment` |
| `scripts/approve-blocked-issue.sh` | — | Same |
| `scripts/reject-blocked-issue.sh` | — | Same |
| `scripts/regression-test.sh` | 3 | Same |

Each file sources `issue-fns.sh` (which in turn sources `issue-config.sh`) at entry. All `.agent/` mirrors receive identical changes.

### Shell Function Layer (`scripts/issue-fns.sh`)

A shared shell library sourced by all command files and scripts. Defines six functions that dispatch to the configured backend, replacing all raw `gh issue` call sites:

| Function | Equivalent `gh` call | Description |
|----------|----------------------|-------------|
| `issue_list [--label L] [--state S] [--limit N]` | `gh issue list` | List issues, output JSON array |
| `issue_get <number>` | `gh issue view` | Get one issue, output JSON object |
| `issue_update <number> [--add-label L] [--remove-label L] [--status S] [--assignee A]` | `gh issue edit` | Modify issue metadata |
| `issue_comment <number> --body "..."` | `gh issue comment` | Append a comment |
| `issue_close <number> [--comment "..."]` | `gh issue close` | Close/resolve an issue |
| `issue_create --title "..." --body "..." [--label L] [--priority P]` | `gh issue create` | Create a new issue, returns number |

**`--priority` translation:** `issue-fns.sh` translates `--priority P` to `--label P` before dispatching to any backend. The GitHub backend never receives a `--priority` flag (which `gh issue create` does not support); backends only see `--label`. The `file` and custom backends may use either; `issue-fns.sh` normalizes both.

Every command file and script sources `issue-fns.sh` at entry. No command file contains any direct `gh issue` calls after this migration — the functions are the only call site.

### Command Files (`fix.md` etc.)

All raw `gh issue` calls in existing command files are replaced with the corresponding `issue_*` function from `issue-fns.sh`. The command files are otherwise unchanged — they do not know or care which backend is active.

### New User-Facing Issue Management Commands

These commands provide explicit issue management that works transparently against any configured backend:

#### `commands/record-issue.md`

Creates a new issue in the configured backend:

```
/record-issue
/record-issue "Fix the login bug"
/record-issue --priority P1 --label bug
```

- Prompts for title, body, priority, and labels if not supplied
- Calls `issue_create` and reports the new issue number
- Works identically whether the backend is GitHub, ISSUES.md, or Jira

#### `commands/update-issue.md`

Modifies an existing issue's labels, status, or priority:

```
/update-issue 42 --add-label needs-design
/update-issue 42 --remove-label working --add-label needs-approval
/update-issue 42 --priority P0
```

- Calls `issue_update` with the specified changes
- Label names are backend-agnostic (same names used in GitHub mode)

#### `commands/close-issue.md`

Resolves and closes an issue with an optional comment:

```
/close-issue 42
/close-issue 42 "Fixed in PR #87 by extracting auth module"
```

- Calls `issue_close`; appends comment if provided

#### `commands/list-issues.md`

Lists open issues, optionally filtered:

```
/list-issues
/list-issues --label needs-design
/list-issues --priority P0
```

- Calls `issue_list`, formats output for readability
- Consolidates and replaces the existing `/list-needs-design` and `/list-needs-feedback` commands (those become thin wrappers: `/list-needs-design` = `/list-issues --label needs-design`)

### New Command: `commands/set-issue-source.md`

Interactive command to switch sources at any time:

1. Show the current source (from `.autocoder.json` or auto-detected)
2. List available sources — `github` only shown if repo has a `github.com` remote
3. If the user selects a different source:
   - Offer to migrate existing issues to the new source
     - `gh → file`: runs `issues-file.py import-from-gh`
     - `file → gh`: runs `issues-file.py export-to-gh`
   - Update `.autocoder.json` with the new source
4. Confirm the switch is complete

Mirrored to `.agent/workflows/set-issue-source.md`.

### Mirroring

Per repository convention, all new scripts and commands must be mirrored:

| Claude Code | Antigravity |
|-------------|-------------|
| `plugins/autocoder/scripts/issue-config.sh` | `.agent/scripts/issue-config.sh` |
| `plugins/autocoder/scripts/issue-fns.sh` | `.agent/scripts/issue-fns.sh` |
| `plugins/autocoder/scripts/issues-file.py` | `.agent/scripts/issues-file.py` |
| `plugins/autocoder/commands/record-issue.md` | `.agent/workflows/record-issue.md` |
| `plugins/autocoder/commands/update-issue.md` | `.agent/workflows/update-issue.md` |
| `plugins/autocoder/commands/close-issue.md` | `.agent/workflows/close-issue.md` |
| `plugins/autocoder/commands/list-issues.md` | `.agent/workflows/list-issues.md` |
| `plugins/autocoder/commands/set-issue-source.md` | `.agent/workflows/set-issue-source.md` |

---

## Section 4: Extensibility

The backend system is pluggable. New sources can be added by implementing the backend contract — no changes to command files or existing scripts required.

### Backend Contract

A backend is any executable (shell script, Python, binary) that accepts the following subcommands and adheres to the JSON output schema:

| Subcommand | Args | Output |
|-----------|------|--------|
| `list` | `[--label L] [--state open\|closed] [--limit N]` | JSON array — gh `issue list` schema |
| `get` | `<number>` | JSON object — gh `issue view` schema |
| `update` | `<number> --add-label L \| --remove-label L \| --status S \| --assignee A` | exit code only |
| `comment` | `<number> --body "..."` | exit code only |
| `close` | `<number> [--comment "..."]` | exit code only |
| `create` | `--title "..." --body "..." [--label L]` | `{"number": N}` |

**Output schema** for `list` and `get` matches `gh issue list --json number,title,body,labels,state` and `gh issue view --json number,title,body,labels,state,comments` respectively. This ensures all downstream parsing works unchanged.

### Registering a Custom Backend

In `.autocoder.json`:

```json
{
  "issueSource": "jira",
  "issueBackend": "./scripts/backends/jira-backend.sh"
}
```

Built-in backends (`github`, `file`) are resolved automatically; custom backends are referenced by path relative to the repo root.

### Minimal Backend Template

```bash
#!/bin/bash
# Minimal backend template — implement each subcommand
SUBCOMMAND="$1"; shift

case "$SUBCOMMAND" in
  list)
    # Output JSON array matching gh issue list schema
    echo "[]"
    ;;
  get)
    ISSUE_NUMBER="$1"
    # Output JSON object matching gh issue view schema
    echo "{}"
    ;;
  update)
    ISSUE_NUMBER="$1"; shift
    # Apply label/status/assignee changes; exit 0 on success
    ;;
  comment)
    ISSUE_NUMBER="$1"; shift
    # Parse --body from remaining args; append comment
    ;;
  close)
    ISSUE_NUMBER="$1"; shift
    # Close issue; optionally parse --comment
    ;;
  create)
    # Parse --title, --body, --label; output {"number": N}
    # Note: --priority is translated to --label by issue-fns.sh before reaching backends
    echo '{"number": 1}'
    ;;
  *)
    echo "Unknown subcommand: $SUBCOMMAND" >&2
    exit 1
    ;;
esac
```

### README Documentation

`README.md` gets an "Adding a Custom Issue Backend" section covering:

- The full backend contract (subcommands, args, output schema)
- The minimal shell template above
- A Jira example showing how to wrap the Jira REST API (`curl` to `/rest/api/3/issue`, mapping Jira fields to the gh JSON schema)
- A note on the `assignee` / distributed-lock pattern for sources that support concurrency natively

---

## Section 5: Multi-Framework Support

The shell function layer and backend contract are framework-agnostic. All agent frameworks invoke shell scripts the same way; the only framework-specific work is command registration.

### Worktree Coordination Across Many Agents

When `start-parallel-agents.sh` launches N agents across N git worktrees, all N agents share a single `ISSUES.md` located in the main worktree. The coordination sequence for each agent is:

1. Agent starts in its branch worktree (e.g., `/repo-feat-login`)
2. Sources `issue-fns.sh`, which sources `issue-config.sh`
3. `issue-config.sh` resolves the main worktree path via `git worktree list --porcelain | grep -m1 "^worktree" | cut -d' ' -f2` → e.g., `/repo`
4. `ISSUE_FILE_PATH` is set to `/repo/ISSUES.md` — the same absolute path for every agent regardless of which worktree it runs in
5. When the agent calls `issue_list`, `issues-file.py` acquires `fcntl.LOCK_EX` on `/repo/ISSUES.md`, reads open issues, and returns them
6. When the agent claims an issue, `issues-file.py` acquires the lock, atomically sets `status: working` + `assignee: <worktree-name>`, and releases the lock
7. Other agents that call `issue_list` concurrently block on the lock, then receive the already-updated file — they skip the claimed issue because `status != open`

There is one shared task list regardless of how many agents or worktrees are active.

### Supported Frameworks

| Framework | Command registration | Notes |
|-----------|---------------------|-------|
| **Claude Code** | `plugins/autocoder/commands/*.md` | Current location; no change |
| **Antigravity** | `.agent/workflows/*.md` | Mirrored per existing convention |
| **Factory.ai / Droid** | `.agent/workflows/*.md` or framework-specific dir | Uses same shell scripts; command file format may differ — mirror with any needed syntax adaptation |
| **OpenAI / Codex** | `.agent/workflows/*.md` or `AGENTS.md` task definitions | Same shell scripts; Codex invokes shell commands directly so `issue_*` functions work as-is |

**Framework-agnostic contract:** Every framework invokes the same shell scripts (`issue-fns.sh`, `issues-file.py`). No framework-specific logic lives below the command registration layer. Adding support for a new framework means registering the commands in that framework's format and ensuring it can invoke bash — no backend changes required.

### `AGENTS.md` / `GEMINI.md` Documentation

Each framework's root instruction file (`CLAUDE.md`, `GEMINI.md`, `AGENTS.md`) gets a short note explaining the issue source system:

```
## Issue Management
This project uses a pluggable issue source. Run /set-issue-source (or equivalent)
before running autonomous agents for the first time. Issue state is shared across
all agents via ISSUES.md at the repo root.
```

---

## Out of Scope

- Real-time sync between backends (e.g., keeping ISSUES.md in sync with GitHub continuously)
- Authentication management for external backends (each backend manages its own auth)
- GUI or web interface for issue management
