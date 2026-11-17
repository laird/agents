# REVIEW.md

Rules for reviewing changes to laird/agents. The autocoder pre-landing review
(`/fix`) gives this file to every reviewer. Keep it short.

## What failure looks like here

- **A gate that passes anything.** A script or test that reports success and exits 0
  when something failed (`regression-test.sh` once did; pipes that lose the exit
  status; a test whose assertion can never fail).
- **A lock dropped or leaked.** `working` / `merging` / `awaiting-integration` labels
  removed while the issue is still open and owned, or left on a closed issue.
- **Real side effects from tests.** A test that sources `issue-fns.sh` inside this
  checkout files real GitHub issues (`.autocoder.json` beats `ISSUE_SOURCE=file`).
  Tests must use a private temp repo, a `gh` stub, and `mktemp`, never a fixed `/tmp` path.
- **Platform drift.** A command edited in `plugins/` but not `.agent/workflows/`, or a
  script edited without re-running `scripts/package-plugin-scripts.py`.
- **Protocol text an agent will misread.** Placeholders that look filled in, shell
  blocks that fail under `set -u` or with an unset variable, `Fix #N` in a commit
  template (GitHub auto-closes the issue on push).
- **Secrets or personal data** in logs, comments, issue bodies or committed files.

## Severity

- **Important**: a real defect, scope violation or security problem introduced by
  this diff. Blocks landing until fixed or answered.
- **Nit**: style or preference. Report **at most 3**; never blocks.
- **Pre-existing**: real but older than this diff. Report it to be filed separately;
  do not fix it in this change.

## Skip

- Generated script mirrors (`.agent/scripts/`, `.pi/`, `codex-plugins/*/scripts/`,
  `.factory-plugin/plugins/*/scripts/`, `skills/autocoder/scripts/`): review the
  `plugins/autocoder/scripts/` source instead.
- `docs/plans/`, `docs/specs/`, `docs/reports/`, `handoffs/`: historical records.

## How to write findings

- Cite every finding as `path:line` and say what goes wrong, with a concrete input or
  scenario. No finding without a location.
- Do not repeat a finding already raised in an earlier round.
- Start the summary with a count, e.g. `2 Important, 1 Nit`. When nothing needs
  fixing, say so plainly: `0 Important. Nothing to fix.`

## Recurring findings

When reviewers keep flagging the same thing, stop finding it by hand: add the rule
here, make it a lint or test check, or put it in a skill.
