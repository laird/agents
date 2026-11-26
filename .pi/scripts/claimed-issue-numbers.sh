#!/usr/bin/env bash
# claimed-issue-numbers.sh — issue numbers that have a live remote branch.
#
# WHY THIS EXISTS (issue #48):
#   /fix builds its candidate list by filtering on labels alone. When a
#   `working` label is dropped while work is genuinely in flight (issue #14,
#   still live in workers running older code) the issue re-enters the claimable
#   pool. The post-selection arbitration from #15 then catches it, but only
#   AFTER a worker has claimed and had to back off — and the window between
#   claim and back-off is exactly where a second worker can also claim. That is
#   how #30 ended up with two workers on an 11-file structural merge.
#
#   A pushed branch is evidence that does not depend on a label surviving.
#   Workers push early, so this catches the observed cases at near-zero cost:
#   ONE ls-remote per pass, not one API call per candidate.
#
# Observed cases this excludes (all had no `working` label):
#   #20 -> feature/issue-20, fix/issue-20   #18 -> fix/issue-18
#   #36 -> feature/issue-36                 #25 -> feature/issue-25
#   #7177 -> hotfix/7177-retry-args-engagement-id (athena2#7185: a hotfix lane's
#   branch names its issue first, without `issue-`; the gate re-claimed it twice)
#
# LIMITATION, stated plainly: this cannot see claims whose branch is not yet
# pushed, and it cannot see branches whose name does not encode an issue number
# (e.g. `merge/fix-line-to-master`, the wt-2 claim on #30). It narrows the race
# window; it does not close it. The post-selection arbitration must stay.
#
# Usage:  claimed-issue-numbers.sh [remote]
# Output: JSON array of integers on stdout, e.g. [18,20,25,36]
#         Empty array if the remote is unreachable — fail open, because failing
#         closed would stall the whole swarm on a network blip.
# Exit:   0 always (see above). Diagnostics go to stderr.

set -uo pipefail

REMOTE="${1:-origin}"
# shellcheck source=git-net-fns.sh
source "$(dirname "${BASH_SOURCE[0]}")/git-net-fns.sh"   # bounded: a stall fails open (#220)

BRANCHES=$(git_net ls-remote --heads "$REMOTE" 2>/dev/null | sed 's#.*refs/heads/##')
if [ -z "$BRANCHES" ]; then
    echo "claimed-issue-numbers: no branches from '$REMOTE' (unreachable?) — failing open" >&2
    echo "[]"
    exit 0
fi

# Match issue-<N> anywhere in the branch name. This deliberately accepts
# feature/, fix/, enhancement/ and any future prefix, and tolerates trailing
# text (fix/issue-8-rename-... -> 8). A hotfix branch names its issue first:
# hotfix/<N>-<slug> and hotfix/<N> count too (athena2#7185). Branches with no
# number are skipped, and a shape with no match is an empty list, not an exit.
{
    printf '%s\n' "$BRANCHES" | grep -oE 'issue-[0-9]+' | grep -oE '[0-9]+' || true
    printf '%s\n' "$BRANCHES" | grep -oE '(^|/)hotfix/[0-9]+([-/]|$)' | grep -oE '[0-9]+' || true
} \
    | sort -un \
    | python3 -c 'import sys,json; print(json.dumps([int(n) for n in sys.stdin.read().split()]))'
