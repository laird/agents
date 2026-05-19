# Critical Design Review: 2026-05-19-pluggable-issue-source-design (Round 1)

**Spec:** `docs/superpowers/specs/2026-05-19-pluggable-issue-source-design.md`
**Verified Assumptions section:** MISSING

> ⚠️ This spec lacks a `Verified assumptions` section. Reviewer cannot distinguish verified facts from unverified assumptions; treat findings accordingly.

---

## 1. Verified-assumptions cross-check

Section omitted — spec has no `Verified assumptions` section.

---

## 2. Literal-wrongness findings

### 2.1 `flock` is not available on macOS

**Description:** The spec relies on `flock -x "$ISSUE_FILE_PATH.lock"` as the exclusive locking primitive for all worktree coordination. `flock` is part of Linux's `util-linux` package and is not installed on macOS by default.

**Evidence:** Running `which flock` on the target macOS system (Darwin 25.4.0) returns nothing — `flock` is not found. Without it, every read-modify-write on `ISSUES.md` runs without any lock, and the core guarantee ("setting `status: working` + `assignee` atomically claims an issue") literally does not hold. Parallel worktrees will race.

**Proposed fix:** Replace `flock` with a Python `fcntl.flock()` call inside `issues-file.py` (available on both macOS and Linux via the standard library), or use a `mkdir`-based advisory lock (atomic on all POSIX systems: `mkdir "$LOCK_DIR" 2>/dev/null` succeeds for exactly one caller). Since `issues-file.py` is already the write path, moving the lock entirely inside Python is the lowest-friction fix.

---

### 2.2 ISSUES.md separator `---` is ambiguous with Markdown thematic breaks in issue bodies

**Description:** The format uses `---` as both the YAML frontmatter delimiter (open/close) and the between-issue separator. Issue bodies are Markdown, and `---` is a valid Markdown thematic break (horizontal rule). A parser reading the file cannot distinguish a thematic break inside a body from the start of the next issue's frontmatter.

**Evidence:** The spec gives no escaping mechanism and no disambiguation rule. A body like:

```
Steps to reproduce:
1. Do X
---
Expected behavior: ...
```

would cause `issues-file.py` to misparse: it would treat `---` as ending the current issue and starting a new one with `Expected behavior:` as malformed frontmatter. Any issue body containing a horizontal rule would corrupt the file on the next write.

**Proposed fix:** Choose one of:
- Use an unambiguous section delimiter that cannot appear in Markdown body text, such as `<!-- issue -->` / `<!-- /issue -->` HTML comment tags.
- Store body as an explicit YAML string field (`body: |`) and use a single-document-per-file YAML or JSON format, eliminating the freeform Markdown body entirely.
- Require parsers to only recognize `---` as a separator when it appears at the very start of a line AND is immediately followed by `number:` — a heuristic that holds for well-formed files but is fragile for hand-edited ones.

---

### 2.3 Migration scope is understated — eight files with `gh issue` calls are not listed

**Description:** The spec states: "No command file contains any direct `gh issue` calls after this migration." The "Updated Scripts" table lists four files. The actual count of files containing `gh issue` calls in `plugins/autocoder/` is at least twelve.

**Evidence (grep results):**

| File | `gh issue` call count |
|------|-----------------------|
| `commands/approve-proposal.md` | 3 |
| `commands/brainstorm-issue.md` | 5 |
| `commands/full-regression-test.md` | 10 |
| `commands/list-needs-design.md` | 7 |
| `commands/list-needs-feedback.md` | 9 |
| `commands/list-proposals.md` | 7 |
| `commands/monitor-workers.md` | 6 |
| `scripts/regression-test.sh` | 3 |

None of these appear in the spec's "Updated Scripts" table or anywhere else in the migration scope. Shipping the spec's listed changes leaves all eight files with hardcoded `gh issue` calls, directly contradicting the "no command file knows or cares which backend is active" guarantee.

**Proposed fix:** Replace the enumerated table with an explicit scope statement: "All files under `plugins/autocoder/commands/` and `plugins/autocoder/scripts/` that contain `gh issue` calls are in scope for migration to `issue_*` functions." Add the eight files above to the table, or remove the table and use the rule.

---

### 2.4 Inconsistent `git worktree list` command produces wrong path in Section 2

**Description:** Section 1 correctly extracts the main worktree path with `git worktree list --porcelain | grep -m1 "^worktree" | cut -d' ' -f2`. Section 2's Worktree Coordination sub-section uses `git worktree list --porcelain | head -1` for the same purpose. `head -1` returns the entire first line — `worktree /path/to/repo` — not just the path.

**Evidence:** Running `git worktree list --porcelain | head -1` on this repo produces `worktree /Users/Laird.Popkin/src/agents`. Using that as a directory path would make every file operation target a path beginning with `worktree ` (the literal string), causing all of them to fail with "no such file."

**Proposed fix:** Use Section 1's form everywhere: `git worktree list --porcelain | grep -m1 "^worktree" | cut -d' ' -f2`. Update Section 2's prose to match.

---

### 2.5 `--priority` flag in the backend contract is unhandled by the GitHub backend

**Description:** The backend contract specifies `create --title "..." --body "..." [--label L] [--priority P]` as a valid call. The `gh issue create` command has no `--priority` flag — GitHub tracks priority as a label (e.g., `--label P1`). The spec does not describe where this translation happens.

**Evidence:** `gh issue create --priority P1` fails with `unknown flag: --priority`. If `issue_create` in `issue-fns.sh` passes `--priority` through to the GitHub backend without translation, every `issue_create` call with a priority in GitHub mode fails.

**Proposed fix:** Pick one translation point and name it explicitly:
- `issue-fns.sh` translates `--priority P` to `--label P` before dispatching to any backend (keeps the contract clean but adds logic to the dispatch layer).
- The GitHub backend wrapper translates it (keeps `issue-fns.sh` thin but requires every backend to handle `--priority` explicitly).
- Remove `--priority` from the contract entirely; callers always use `--label P1` (simplest, no hidden translation).

---

## 3. Forced decisions

### 3.1 Detection flow behavior in non-interactive contexts

**Description:** The detection flow in Section 1 requires user confirmation before caching the source. Commands like `/fix-loop` run autonomously — often in tmux panes started by `start-parallel-agents.sh` with no human watching. If `.autocoder.json` is absent when `/fix-loop` starts in such a context, `issue-config.sh` will block indefinitely waiting for a confirmation that will never come.

**The choice:** Should `issue-config.sh` detect whether it has a TTY and behave differently?

**Options:**
- A) Fail fast with a clear error if no TTY and no cached config: "No issue source configured. Run `/set-issue-source` first." Autonomous agents never trigger detection — they require prior configuration.
- B) Apply a silent default in non-interactive mode: try `gh` if a GitHub remote exists, else fail with an error.
- C) Require `.autocoder.json` to exist before any issue-consuming command runs; detection is only triggered by `/set-issue-source` explicitly.

The spec must pick one. Option A is the safest: it makes the absence of configuration a hard failure that surfaces immediately rather than a silent hang.

---

## 4. Previously addressed

n/a (first round)

---

## 5. Recommendation

🛑 **Surface forced decisions to user** — §3 is non-empty; user input on the non-interactive detection behavior (§3.1) is needed before the plan can be written. §2 findings (2.1–2.5) must also be addressed; they are all fixable with targeted spec edits.
