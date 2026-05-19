# Pluggable Issue Source Design

**Date:** 2026-05-19
**Status:** Draft

## Summary

Add support for a file-based issue list (`ISSUES.md`) as an alternative to GitHub Issues, with an extensible backend system so additional sources (Jira, Linear, etc.) can be added by implementing a standard contract. The system auto-detects the available source, confirms with the user, and caches the choice. A `/set-issue-source` command allows switching at any time, with optional migration of existing issues.

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

### Caching

After the user confirms a source, the choice is saved to `.autocoder.json` at the repo root. Future invocations skip detection. The user can re-trigger detection by running `/set-issue-source` or deleting `.autocoder.json`.

---

## Section 2: ISSUES.md Format

Each issue is a YAML frontmatter block followed by a Markdown body. Issues are separated by `---` dividers. The file is human-readable and hand-editable.

### Example

```markdown
---
number: 1
title: Fix the login bug
priority: P1
labels: [bug]
status: open
---
Users report they can't log in when using SSO. Steps to reproduce: ...

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

---
number: 3
title: Refactor auth module
priority: P3
labels: [needs-design]
status: closed
---
Completed: extracted auth into standalone package.
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

- `ISSUES.md` lives at the **main worktree root** (found via `git worktree list --porcelain | head -1`).
- All read-modify-write operations use `flock -x "$ISSUE_FILE_PATH.lock"` for atomic access.
- Setting `status: working` + `assignee: <worktree-name>` atomically claims an issue, equivalent to the GitHub `working` label.
- Multiple worktrees share the single file via the main worktree path; no issue is ever stored inside a branch worktree.

---

## Section 3: Script Architecture

### New Scripts

#### `scripts/issue-config.sh`

Runs the detection flow described in Section 1. Sources by all issue-consuming scripts at startup. Exports:

- `ISSUE_SOURCE` — `github`, `file`, or custom backend name
- `ISSUE_FILE_PATH` — resolved absolute path to `ISSUES.md` (file mode only)
- `ISSUE_BACKEND` — path to the backend script

#### `scripts/issues-file.py`

Python script implementing all ISSUES.md read/write operations. Uses `flock` for safe concurrent access across worktrees.

Subcommands:

| Subcommand | Description |
|-----------|-------------|
| `list [--label L] [--state open\|closed]` | Output JSON array |
| `get <number>` | Output JSON object |
| `update <number> [--add-label L] [--remove-label L] [--status S] [--assignee A]` | Modify issue in-place |
| `comment <number> --body "..."` | Append blockquote comment |
| `close <number> [--comment "..."]` | Set `status: closed`, append comment |
| `create --title "..." --body "..." [--label L] [--priority P]` | Append new issue, output `{"number": N}` |
| `find-main-worktree` | Print absolute path to main worktree |
| `import-from-gh` | Pull open GH issues and append as ISSUES.md entries |
| `export-to-gh` | Create GH issues from open ISSUES.md entries |

All `list`/`get` output uses the same JSON schema as `gh issue list/view` so downstream parsing is backend-agnostic.

### Updated Scripts

Each of the following sources `issue-config.sh` and branches on `$ISSUE_SOURCE`:

| Script | Change |
|--------|--------|
| `fetch-blocked-issues.sh` | Replace `gh issue list` call with backend dispatch |
| `add-blocking-label.sh` | Dispatch to `issues-file.py update` or `gh issue edit` |
| `approve-blocked-issue.sh` | Same dispatch pattern |
| `reject-blocked-issue.sh` | Same dispatch pattern |

### Command Files (`fix.md` etc.)

Commands that contain raw `gh issue` calls get a small set of backend-aware shell functions defined at entry (e.g., `issue_list`, `issue_get`, `issue_update`, `issue_comment`, `issue_close`, `issue_create`). These functions source `issue-config.sh` and dispatch accordingly, replacing the raw `gh issue` call sites.

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
| `plugins/autocoder/scripts/issues-file.py` | `.agent/scripts/issues-file.py` |
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
| `create` | `--title "..." --body "..." [--label L] [--priority P]` | `{"number": N}` |

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
    # Parse --title, --body, --label, --priority; output {"number": N}
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

## Out of Scope

- Real-time sync between backends (e.g., keeping ISSUES.md in sync with GitHub continuously)
- Authentication management for external backends (each backend manages its own auth)
- GUI or web interface for issue management
