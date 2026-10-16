#!/usr/bin/env bash
# verify-shipped.sh — is this commit actually on the branch that ships?
#
# WHY THIS EXISTS (issue #35):
#   #26 added a PUSH_OK guard: don't close an issue if the push failed. That
#   catches "no code anywhere". It does NOT catch the quieter case: the push
#   succeeded, the branch is real, the code is good — but it landed on a branch
#   that never reaches the shipping branch. Every signal is green (push ok, PR
#   merged, tests pass) and the issue closes as COMPLETED while the fix is not
#   in the product.
#
# WHY NOT CHECK THE INTEGRATION BRANCH:
#   Issue #35 proposed testing ancestry of "$INTEGRATION_BRANCH". That does not
#   work, and provably fails on the issue's own example. In a swarm whose
#   INTEGRATION_BRANCH is itself a feature line, a commit merged to that line IS
#   an ancestor of it — so the check passes and the issue closes, which is
#   exactly the bug: the tracker says COMPLETED while the shipping branch still
#   lacks the fix.
#
#   Shipping is therefore defined against the branch that actually ships — the
#   repo's default branch by default, overridable with CLAUDE_CODE_SHIP_BRANCH.
#
# THE DEFAULT BRANCH ALWAYS SHIPS (issue #76):
#   verify-shipped.sh resolves the ship branch from the local worktree's CLAUDE.md.
#   Two worktrees on different branches (one with a Ship branch designation, one
#   without) return different verdicts for the same commit — a worker on an
#   integration line reports master commits as NOT_SHIPPED.
#
#   Fix: a commit is shipped if it reached the designated ship branch OR the
#   repo's default branch. The default branch is computed independently (not from
#   CLAUDE.md), so the verdict is the same regardless of which worktree runs this.
#   This cannot re-introduce the #35 bug: that bug closed work that reached only
#   a feature line, and a feature line is neither the ship branch nor the default.
#
# Usage:   verify-shipped.sh <commit-ish> [ship-branch]
# Exit:    0 = commit is an ancestor of the ship branch or the default branch
#          1 = commit exists but has reached neither (do not close)
#          2 = usage error, or the commit/ship branch could not be resolved
#
# On exit 1 the script prints the ship branch and, when it can determine one,
# the intermediate branch the work is parked on, so the caller can say something
# useful instead of "not shipped".

set -uo pipefail

# Resolve the repo default branch independently of any local CLAUDE.md.
# Returns empty when it cannot be determined (bare repo, no origin, gh unavailable).
resolve_default_branch() {
    local d=""
    d=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null \
        | sed 's@^refs/remotes/origin/@@')
    if [ -z "$d" ]; then
        d=$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name \
            2>/dev/null || echo "")
    fi
    printf '%s' "$d"
}

COMMIT="${1:-}"
if [ -z "$COMMIT" ]; then
    echo "usage: verify-shipped.sh <commit-ish> [ship-branch]" >&2
    exit 2
fi

# Resolve the shipping branch:
#   explicit arg > CLAUDE_CODE_SHIP_BRANCH > CLAUDE.md > repo default > main
#
# The CLAUDE.md step matters because headless workers (cron, tmux panes started
# without direnv) never source .envrc, so the env var alone is not fleet-wide.
# The regex accepts any branch name — the older extractor in fix-loop.md matches
# only \b(main|master|develop|integration)\b, which cannot express an arbitrary
# feature-line branch name.
SHIP_BRANCH="${2:-${CLAUDE_CODE_SHIP_BRANCH:-}}"

if [ -z "$SHIP_BRANCH" ]; then
    for cfg in CLAUDE.md claude.md AGENTS.md; do
        [ -f "$cfg" ] || continue
        SHIP_BRANCH=$(grep -iE '^\*\*Ship branch\*\*:' "$cfg" 2>/dev/null \
            | head -1 | sed -E 's/.*`([^`]+)`.*/\1/')
        [ -n "$SHIP_BRANCH" ] && break
    done
fi

DEFAULT_BRANCH=$(resolve_default_branch)

if [ -z "$SHIP_BRANCH" ]; then
    SHIP_BRANCH="${DEFAULT_BRANCH:-}"
fi
SHIP_BRANCH="${SHIP_BRANCH:-main}"

if ! git rev-parse --verify --quiet "${COMMIT}^{commit}" >/dev/null; then
    echo "verify-shipped: cannot resolve commit '$COMMIT'" >&2
    exit 2
fi

git fetch origin "$SHIP_BRANCH" --quiet 2>/dev/null || true

SHIP_REF=""
for candidate in "origin/$SHIP_BRANCH" "$SHIP_BRANCH"; do
    if git rev-parse --verify --quiet "${candidate}^{commit}" >/dev/null; then
        SHIP_REF="$candidate"
        break
    fi
done

# Also treat the repo default branch as a ship target (issue #76).
# This makes the verdict identical regardless of which worktree runs the check.
# It also handles stale designations: if the named ship branch no longer exists
# (merged away) but the commit IS on the default branch, report SHIPPED.
DEFAULT_REF=""
if [ -n "${DEFAULT_BRANCH:-}" ] && [ "$DEFAULT_BRANCH" != "${SHIP_BRANCH:-}" ]; then
    git fetch origin "$DEFAULT_BRANCH" --quiet 2>/dev/null || true
    for candidate in "origin/$DEFAULT_BRANCH" "$DEFAULT_BRANCH"; do
        if git rev-parse --verify --quiet "${candidate}^{commit}" >/dev/null; then
            DEFAULT_REF="$candidate"
            break
        fi
    done
fi

if [ -z "$SHIP_REF" ]; then
    # Named ship branch doesn't exist. If the commit is on the default branch,
    # it's shipped. Otherwise this is an unresolvable configuration error.
    if [ -n "$DEFAULT_REF" ] && git merge-base --is-ancestor "$COMMIT" "$DEFAULT_REF" 2>/dev/null; then
        echo "SHIPPED: $(git rev-parse --short "$COMMIT") is on ${DEFAULT_REF} (default branch; named ship branch '${SHIP_BRANCH}' unresolvable)"
        exit 0
    fi
    echo "verify-shipped: cannot resolve ship branch '$SHIP_BRANCH'" >&2
    exit 2
fi

if git merge-base --is-ancestor "$COMMIT" "$SHIP_REF" 2>/dev/null; then
    echo "SHIPPED: $(git rev-parse --short "$COMMIT") is on ${SHIP_REF}"
    exit 0
fi

if [ -n "$DEFAULT_REF" ] && git merge-base --is-ancestor "$COMMIT" "$DEFAULT_REF" 2>/dev/null; then
    echo "SHIPPED: $(git rev-parse --short "$COMMIT") is on ${DEFAULT_REF} (default branch)"
    exit 0
fi

echo "NOT_SHIPPED: $(git rev-parse --short "$COMMIT") has not reached ${SHIP_REF}"

# Best-effort: name where it IS, so the caller can explain the gap.
PARKED=$(git branch -r --contains "$COMMIT" 2>/dev/null \
    | sed 's/^[ *]*//' \
    | grep -v -- '->' \
    | grep -v "^${SHIP_REF}$" \
    | head -3 | tr '\n' ' ')
[ -n "$PARKED" ] && echo "PARKED_ON:$PARKED"

exit 1
