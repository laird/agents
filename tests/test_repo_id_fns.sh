#!/bin/bash
# tests/test_repo_id_fns.sh — autocoder_repo_id names one repository one way.
#
# merge-launch.sh, merge-poll.sh, merge-to-integration.sh and the sentinel key their
# shared scratch files on it, so: every worktree and subdirectory of a repo gets the
# same id, two same-named repos get different ids, the format is <basename>-<8 hex>,
# and a directory outside any repo still gets a stable id.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../plugins/autocoder/scripts/repo-id-fns.sh
source "$ROOT/plugins/autocoder/scripts/repo-id-fns.sh"

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap 'git -C "$TMP/a/proj" worktree prune 2>/dev/null; rm -rf "$TMP"' EXIT

mkdir -p "$TMP/a" "$TMP/b" "$TMP/plain/sub"
export GIT_AUTHOR_NAME=T GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=T GIT_COMMITTER_EMAIL=t@example.com
git init -q "$TMP/a/proj"; git -C "$TMP/a/proj" commit -q --allow-empty -m init
git init -q "$TMP/b/proj"; git -C "$TMP/b/proj" commit -q --allow-empty -m init
mkdir -p "$TMP/a/proj/src/deep"
git -C "$TMP/a/proj" worktree add -q "$TMP/a/proj-wt-1" -b wt1 >/dev/null 2>&1

A=$(autocoder_repo_id "$TMP/a/proj")
echo "$A" | grep -Eq '^proj-[0-9a-f]{8}$' && ok "format is <basename>-<8 hex> ($A)" || bad "format wrong: $A"
[ "$(autocoder_repo_id "$TMP/a/proj/src/deep")" = "$A" ] && ok "a subdirectory shares the repo's id" || bad "subdirectory id differs"
[ "$(autocoder_repo_id "$TMP/a/proj-wt-1")" = "$A" ] && ok "a linked worktree shares the repo's id" || bad "worktree id differs: $(autocoder_repo_id "$TMP/a/proj-wt-1")"
[ "$(cd "$TMP/a/proj-wt-1" && autocoder_repo_id)" = "$A" ] && ok "with no argument the cwd's repo is used" || bad "no-arg form differs"
B=$(autocoder_repo_id "$TMP/b/proj")
[ "$B" != "$A" ] && [ "${B%-*}" = proj ] && ok "a same-named repo elsewhere gets a different id ($B)" || bad "same-named repos collide: $A vs $B"
P=$(autocoder_repo_id "$TMP/plain/sub")
echo "$P" | grep -Eq '^sub-[0-9a-f]{8}$' && [ "$(autocoder_repo_id "$TMP/plain/sub")" = "$P" ] && ok "outside a repo the directory itself is the id, stably ($P)" || bad "non-git id wrong: $P"
[ "$(autocoder_repo_id "$TMP/plain")" != "$P" ] && ok "two non-git directories differ" || bad "non-git directories collide"

TOTAL=$((PASS + FAIL))
echo "$PASS passed / $FAIL failed / $TOTAL total"
[ "$FAIL" -eq 0 ]
