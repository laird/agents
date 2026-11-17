#!/bin/bash
# merge-conflict-claude.sh — the bundled conflict resolver (#164): one short, headless
# Claude session that edits the conflicted files in the merge job's worktree.
#
# Run by merge-conflict-fns.sh when .autocoder.json "conflictResolver" (or
# AUTOCODER_CONFLICT_RESOLVER) is "claude". The caller bounds it with a timeout, checks
# the result itself (no markers, no unmerged paths, HEAD unmoved) and gates the tree, so
# this script only has to make the edit and say whether it did.
#
# Environment (set by the caller): AUTOCODER_CONFLICT_FILES, AUTOCODER_CONFLICT_CONTEXT,
# AUTOCODER_INTEGRATION_BRANCH, AUTOCODER_ISSUE. AUTOCODER_CONFLICT_MODEL picks the model
# (default: the CLI's default). The session may read anything in the worktree but may
# only edit files; it cannot run commands, so it cannot commit, push or touch other
# checkouts.
#
# Exit: 0 when the session ends with a line "RESOLVED", 1 otherwise (declined, no CLI).

set -uo pipefail

command -v claude >/dev/null 2>&1 || { echo "merge-conflict-claude: no claude CLI on PATH" >&2; exit 1; }
[ -n "${AUTOCODER_CONFLICT_FILES:-}" ] || { echo "merge-conflict-claude: no conflicted files given" >&2; exit 1; }

PROMPT="You are resolving a git merge conflict inside a throwaway worktree used by an automated merge job for issue #${AUTOCODER_ISSUE:-?}. A rebase of a feature branch onto ${AUTOCODER_INTEGRATION_BRANCH:-the integration branch} stopped on a conflict.

Conflicted files (they contain <<<<<<< / ======= / >>>>>>> markers):
${AUTOCODER_CONFLICT_FILES}

Both sides' commit messages are in: ${AUTOCODER_CONFLICT_CONTEXT:-(none)}
In the markers, the upper side (HEAD / \"ours\") is the integration branch and the lower side (\"theirs\") is the feature commit being replayed.

Do this:
1. Read the context file and each conflicted file, and whatever nearby code you need to understand both changes.
2. Edit each conflicted file so it keeps BOTH sides' intended behaviour and has no conflict markers left. Edit only the listed files.
3. If the two changes genuinely contradict each other, or you are not confident the merged result is correct, do not guess: leave the files as they are.

Finish with exactly one line: RESOLVED if you resolved every listed file, or DECLINED: <one-line reason> otherwise."

ARGS=(-p "$PROMPT" --permission-mode acceptEdits --allowedTools "Read" "Edit" "Write" "Glob" "Grep")
[ -n "${AUTOCODER_CONFLICT_MODEL:-}" ] && ARGS+=(--model "$AUTOCODER_CONFLICT_MODEL")

OUT=$(claude "${ARGS[@]}" 2>&1)
RC=$?
printf '%s\n' "$OUT" | tail -n 20
[ "$RC" -eq 0 ] || exit 1
printf '%s\n' "$OUT" | grep -qx 'RESOLVED' && exit 0
exit 1
