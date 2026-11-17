#!/bin/bash
# scaffold-review-md.sh — write a starter REVIEW.md at a repo's root (#169).
#
# REVIEW.md is the per-repo rulebook the Pre-Landing Review Gate in /fix hands
# to every reviewer: what failure looks like here, a cap on nits, paths to skip,
# findings cite file:line, and a summary that leads with a count. CLAUDE.md is
# loaded into every agent turn, so review rules belong here instead.
#
# Usage: scaffold-review-md.sh [REPO_DIR]     (default: the current git checkout)
# Never overwrites: an existing REVIEW.md is left alone and reported (exit 0).
# Exit 1 when REPO_DIR is not a git checkout or the file cannot be written.

set -u
DIR="${1:-.}"
ROOT=$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null) \
  || { echo "scaffold-review-md: $DIR is not a git checkout" >&2; exit 1; }
TARGET="$ROOT/REVIEW.md"
if [ -e "$TARGET" ] || [ -L "$TARGET" ]; then
  echo "REVIEW.md already exists at $TARGET; left unchanged"
  exit 0
fi

cat > "$TARGET" <<'REVIEW_MD' || { echo "scaffold-review-md: cannot write $TARGET" >&2; exit 1; }
# REVIEW.md

Rules for reviewing changes to this repository. The autocoder pre-landing review
(`/fix`) gives this file to every reviewer. Keep it short; edit it to fit the repo.

## What failure looks like here

<!-- Replace with this repo's real risks: the bugs that hurt users or wake people up. -->
- Behaviour the issue asked for is missing, or something it did not ask for changed.
- A test that would pass even if the change were reverted.
- Errors swallowed or a failure reported as success.
- Secrets, credentials or personal data logged, committed or sent anywhere new.

## Severity

- **Important**: a real defect, scope violation or security problem introduced by
  this diff. Blocks landing until fixed or answered.
- **Nit**: style or preference. Report **at most 3**; never blocks.
- **Pre-existing**: real but older than this diff. Report it to be filed separately;
  do not fix it in this change.

## Skip

<!-- Paths reviewers should not comment on: generated, vendored or lock files. -->
- Generated files, vendored code and lockfiles, unless the diff edits them by hand.

## How to write findings

- Cite every finding as `path:line` and say what goes wrong, with a concrete input or
  scenario. No finding without a location.
- Do not repeat a finding already raised in an earlier round.
- Start the summary with a count, e.g. `2 Important, 1 Nit`. When nothing needs
  fixing, say so plainly: `0 Important. Nothing to fix.`

## Recurring findings

When reviewers keep flagging the same thing, stop finding it by hand: add the rule
here, make it a lint or test check, or put it in a skill.
REVIEW_MD

echo "Wrote starter REVIEW.md at $TARGET; edit it to fit the repo"
