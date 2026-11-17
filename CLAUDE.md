# CLAUDE.md

Guidance for agents working in this repository. Keep it short: it is loaded into
every agent turn and every review. Detail lives in the docs linked below.

## What this repo is

Two plugins, shipped for several agent platforms:

- **autocoder** (`plugins/autocoder/`): autonomous issue resolution. `/fix`,
  `/fix-loop`, `/monitor-workers`, parallel worktree swarms, a detached merge
  pipeline, and pluggable issue backends (GitHub, file, Jira, Azure DevOps).
- **modernize** (`plugins/modernize/`): assess → plan → modernize → retro for
  migration projects, with specialist agents.

## Layout

| Path | What |
|---|---|
| `plugins/autocoder/commands/`, `plugins/modernize/commands/` | Slash commands. Each command file is a protocol the agent follows. |
| `plugins/modernize/agents/` | Specialist agent definitions |
| `plugins/autocoder/scripts/` | Shell/Python the commands run: issue backends (`issues-*.sh`, `issues-file.py`, `issue-fns.sh`), gate, merge, sentinel and swarm scripts |
| `.agent/` | Antigravity copies: `workflows/` (commands), `rules/` (agents), `scripts/` (generated mirror) |
| `codex-plugins/`, `.factory*/`, `.pi/`, `skills/` | Codex, Droid, pi and Gemini packaging |
| `scripts/` | Repo tooling and per-runtime loop drivers; `package-plugin-scripts.py` mirrors scripts to every platform |
| `tests/` | `test_*.sh` shell tests (plus a few pytest files) |
| `docs/` | Setup guides, specs, plans; see `docs/STRUCTURE.md` for the full tree |

## Rules when changing things

- **Keep the Claude and Antigravity copies in step.** An edit to
  `plugins/autocoder/commands/X.md` needs the same edit in `.agent/workflows/X.md`
  (modernize agents ↔ `.agent/rules/`).
- **Edit scripts in `plugins/autocoder/scripts/`, then run
  `python3 scripts/package-plugin-scripts.py`.** The other platforms' script
  trees are generated; `tests/test_script_packaging.sh` fails on drift. A few
  Antigravity scripts are hand-synced exceptions.
- **Skills:** `skills/` is the source; mirror each into the plugin that ships it
  (`tests/test_skill_packaging.sh` checks the Claude copy only).
- **Versions:** never bump in an issue branch (see Landing work below). A release
  bumps every manifest together; `tests/test_manifest_versions.sh` checks them.
- **Tests that touch the issue layer** must run in a private temp repo with its own
  `.autocoder.json`: from inside this checkout, `issueSource: github` wins over
  `ISSUE_SOURCE=file` and the test acts on the real tracker.

Details, mapping tables and the reasons behind each rule: `docs/maintaining.md`.

## Issue tracking

Issues come from the backend named in `.autocoder.json` (here: GitHub). Each
backend implements the same verbs (list, get, update, comment, close, create,
claim, release, any-claimable). Credentials come from the environment, never the
repo. Setup: `docs/issue-backends.md`, `docs/jira-setup.md`, `docs/ado-setup.md`.

## Code review

The `/fix` pre-landing review gives `REVIEW.md` (repo root) to every reviewer.
Put review rules there, not here.

## Automated Testing & Issue Management

This section configures the `/fix` command for autonomous issue resolution.

### Regression Test Suite
```bash
bash tests/run-shell-suite.sh
```
The merge gate uses this, not `plugins/autocoder/scripts/regression-test.sh`:
that script prints "All tests passed" and exits 0 even when a suite fails, so a
gate on it passes anything.

### Unit Tests Only
```bash
bash tests/run-shell-suite.sh
```

### Build Verification
```bash
bash -n plugins/autocoder/scripts/*.sh && python3 -m py_compile plugins/autocoder/scripts/*.py
```

### Test Framework Details

**Unit Tests**:
- Framework: plain `bash` assertion scripts, plus `pytest` for the Python backend
- Location: `tests/test_*.sh` (shell), `tests/test_*.py` (Python)
- Run all shell tests: `bash tests/run-shell-suite.sh` — runs every `tests/test_*.sh`
  and prints a single parseable summary. `regression-test.sh` reads its unit-test
  command from the `### Unit Tests Only` section above; a bare `for` loop emits one
  summary per file and the report then quotes a single test's numbers as the suite's.
- Every `tests/test_*.sh` sources `tests/lib/private-event-logs.sh` on line 2, so a
  test run on its own never appends to the real issue/merge event logs that `/retro`
  reads. `test_private_event_logs.sh` fails for a test file without it.
- Note: the Python tests require `pytest`, which is not installed in all environments.
- The Jira and Azure DevOps backends each have two complementary shell tests,
  all hermetic (no network): `test_issues_jira.sh` / `test_issues_ado.sh` stub
  `curl` to assert request (JQL / WIQL + JSON-patch) shape, and
  `test_issues_jira_integration.sh` / `test_issues_ado_integration.sh` drive real
  HTTP against in-process stateful fakes (`tests/fixtures/fake_jira.py`,
  `tests/fixtures/fake_ado.py`) for full lifecycle coverage. For a check against
  a **real** Jira, run `plugins/autocoder/scripts/jira-smoke-test.sh` with
  `JIRA_*` env vars set (needs egress to your Atlassian site; not part of CI).

**E2E Tests**:
- Not configured for this repository.

**Test Reports**:
- Location: `docs/test/regression-reports/`

### Merge Mode
```
merge
```
Options: `merge` (auto-merge to parent branch and push) or `pr` (push feature branch and create a pull request, then stop).

Workers merge tested work straight to `master` and push (laird, 2026-11-16). Do
not open pull requests for swarm work: an open PR leaves the issue looking
unworked, and another worker picks it up again.

### Integration Branch
```
master
```

### Landing work

- **Rebase before you merge.** Immediately before `merge-launch.sh`, run
  `git fetch origin && git rebase origin/master`, resolve conflicts yourself
  keeping both sides' behaviour, re-run the regression suite, then launch.
- **A conflict or a rejected push is not a `needs-clarification` question.**
  If the merge job reports one, rebase again, re-test and relaunch, and put the
  issue's label back to `working`. Escalate only if the same conflict comes back twice.
- **Don't bump plugin versions in an issue branch.** Every manifest version is
  a line all branches would edit, so parallel bumps always conflict. Note the
  change under `## [Unreleased]` in the plugin's CHANGELOG, if there is one, and
  leave the version alone. The manager bumps every manifest once (Version
  Management in `docs/maintaining.md`) when it releases a batch.
