# Autocoder History Logging and `/retro` Command

**Date:** 2026-05-29
**PR:** #12

---

## What Was Added

### History logging for the fix workflow

Autocoder agents now record what they do. After every issue resolution — fixed, PR created, blocked, or skipped — the agent appends a structured entry to a project-level log. The same logging fires at the end of every regression test run.

This fills a gap: agents ran autonomously and accumulated experience, but none of it was recorded. There was no way to ask "what has this agent been doing, and where does it struggle?"

### The shared `append-to-history.sh` script

`scripts/append-to-history.sh` (canonical source, also in `plugins/autocoder/scripts/`, `plugins/modernize/scripts/`, and `.agent/scripts/`) was extended with two new flags:

```bash
# Write to a specific file using the file backend
append-to-history.sh --backend file --history-file HISTORY.md \
  "Fix #42: Auth timeout" \
  "Resolved by bumping token TTL in config.ts" \
  "Issue body: users being logged out after 5 minutes" \
  "Tests: 187 passing. Merged to main."

# Auto-detect backend from $ISSUE_SOURCE env var
append-to-history.sh --backend auto --history-file HISTORY.md \
  "Blocked #67: Dashboard rewrite" \
  "Added label: needs-design" \
  "Multiple valid approaches, unclear which to use" \
  "Requires human review before proceeding."
```

**`--backend [file|github|auto]`**
- `file` — appends to a local markdown file
- `github` — creates (or reuses) a GitHub issue labeled `history-log` and posts each entry as a comment
- `auto` (default) — reads `$ISSUE_SOURCE` from the environment, falls back to `file`

**`--history-file PATH`**
- Overrides the default path (`docs/HISTORY.md`, preserved for backward compatibility with modernize)
- Bare filenames (no `/`) auto-resolve to the main git worktree root, so parallel fix-loop workers all write to one file even when running in isolated git worktrees

The old 4-argument call style (no flags) still works unchanged — modernize is unaffected.

### Where logging happens

**`fix.md`** — 5 insertion points:
| Event | Logged as |
|---|---|
| Issue fixed, PR created | `PR #N: title` + approach + awaiting review |
| Issue fixed, auto-merged | `Fix #N: title` + branch + test result |
| Complex fix, PR created | same PR format |
| Complex fix, auto-merged | same Fix format |
| Issue blocked | `Blocked #N: title` + label + reason |

**`full-regression-test.md`** — 2 insertion points:
- After `exit 0` (all tests pass): logs build + unit + E2E counts
- After `exit 1` (failures): logs same counts + "issues created for failures"

Both commands also gained SCRIPT_DIR enforcement at the top of their Instructions block, so the issue source is always configured before any work begins.

All changes are mirrored to `.agent/workflows/` (the Antigravity platform copies).

---

## The `/retro` Command

```bash
/retro                        # analyze last 12 months
/retro --since 2026-01-01     # scope to a date range
```

`/retro` reads the accumulated history and produces `IMPROVEMENTS.md` — a structured set of 3–5 evidence-backed recommendations for improving the autocoder workflow.

### What it analyzes

| Source | What it looks for |
|---|---|
| `HISTORY.md` (file backend) or `history-log` issue (GitHub backend) | Fix/block/regression counts, recurring failure areas |
| Git log | Reverts, correction keywords, issues with multiple fix attempts |
| Issue tracker | Breakdown of blocked issues by label (needs-design, too-complex, needs-clarification), proposal approval rates |
| History log entries | Repeated test failures across regression runs |

### What it produces

`IMPROVEMENTS.md` in the project root, structured as:

```markdown
# Autocoder Process Improvement Recommendations

**Date**: 2026-05-29
**Status**: Proposed
**Issue Source**: file

## Context
Following 23 fixes, 4 PRs, 11 blocked issues, and 3 regression test runs...

## Recommendations

### Recommendation 1: Improve needs-clarification detection
**Problem**: 8 of 11 blocked issues were labeled needs-clarification...
**Evidence**: Issues #34, #41, #58 — all lacked reproduction steps...
**Proposed Change**: Add a reproduction-steps check to fix.md §"Detection Process"...
```

### Recommended cadence

Run after every 20–30 issues processed. Review `IMPROVEMENTS.md`, apply approved changes manually to `plugins/autocoder/commands/`, then run `/retro` again after the next batch to measure improvement.

---

## File Changes

| File | Change |
|---|---|
| `scripts/append-to-history.sh` | Extended (canonical source) |
| `plugins/autocoder/scripts/append-to-history.sh` | New (copy) |
| `plugins/modernize/scripts/append-to-history.sh` | New (copy) |
| `.agent/scripts/append-to-history.sh` | Updated (copy) |
| `plugins/modernize/protocols/protocols-overview.md` | SYNC NOTE added to inline heredoc |
| `plugins/autocoder/commands/fix.md` | 5 logging calls added |
| `plugins/autocoder/commands/full-regression-test.md` | SCRIPT_DIR enforcement + 2 logging calls |
| `plugins/autocoder/commands/retro.md` | **New** |
| `.agent/workflows/fix.md` | Mirror of fix.md changes |
| `.agent/workflows/full-regression-test.md` | Mirror of full-regression-test.md changes |
| `.agent/workflows/retro.md` | Mirror of retro.md |
| `.claude-plugin/marketplace.json` | autocoder 4.0.0 → 4.1.0; marketplace 3.19.0 → 3.20.0; `retro` registered |
| `CLAUDE.md` | `/retro` documented |

---

## Known Caveats

- **`${ISSUE_BODY:0:150}` flows into an unquoted heredoc** in the file backend. Issue bodies containing backtick sequences would be shell-expanded during the file write. Affects only the file backend; sanitize `ISSUE_BODY` if issues in your tracker routinely contain shell syntax.
- **Test count variables** (`UNIT_PASS`, `UNIT_TOTAL`, etc.) are referenced in the `full-regression-test.md` logging calls but not yet wired to the test runner output — entries will show `?/?` until connected.
