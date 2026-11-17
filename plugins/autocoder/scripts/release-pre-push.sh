#!/usr/bin/env bash
# release-pre-push.sh — the pre-push hook that releases each push of the
# integration branch made from the main checkout. Installed by
# install-release-hook.sh; git runs it as `pre-push <remote> <url>` with the
# pushed refs on stdin.
#
# Every checkout of a repo shares one hooks directory: the main checkout, the
# swarm's worktrees (<repo>-wt-N) and the merge jobs' throwaway worktrees. They
# also all push as the same GitHub account. What tells the user's (or the
# manager's) push apart is where it is pushed from, so only a push from the main
# checkout releases.
#
# A pre-push hook runs before the push and cannot know whether it succeeds. So it
# hands off to a background job that waits until the remote's branch is at the
# pushed commit, then runs release.sh for it (which skips a commit that already
# is the newest release). If the push fails, the branch never gets there and the
# job gives up. It logs to ${XDG_STATE_HOME:-~/.local/state}/autocoder/release.log
# (AUTOCODER_RELEASE_LOG overrides).
#
# Why not a reference-transaction hook on refs/remotes/origin/<integration>: a
# plain `git fetch` in the main checkout moves that ref too, so every merge the
# swarm landed would be released as if the user had pushed it.
#
# The push itself is never held up or refused: this always exits 0.
#   AUTOCODER_NO_RELEASE=1 git push ...   pushes without releasing (AGENTS_UI_NO_RELEASE=1 too)
#   AUTOCODER_RELEASE_WAIT=<seconds>      how long to wait for the push (default 120)

[ "${AUTOCODER_NO_RELEASE:-${AGENTS_UI_NO_RELEASE:-}}" = 1 ] && exit 0

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || exit 0
top=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
common=$(cd "$top" && cd "$(git rev-parse --git-common-dir)" && pwd -P) || exit 0
# The main checkout is the one whose .git is the common dir.
[ "$(basename "$common")" = .git ] || exit 0
main=$(cd "$common/.." && pwd -P)
[ "$(cd "$top" && pwd -P)" = "$main" ] || exit 0

# A timestamp from plain date formats: macOS's date has no ISO-8601 flag.
now() { date +%Y-%m-%dT%H:%M:%S%z; }
remote="${1:-origin}"
integration=$(git symbolic-ref --short "refs/remotes/$remote/HEAD" 2>/dev/null | sed "s@^$remote/@@")
integration="${integration:-main}"

while read -r _local_ref local_sha remote_ref _remote_sha; do
  [ "$remote_ref" = "refs/heads/$integration" ] || continue
  case "$local_sha" in *[!0]*) ;; *) continue ;; esac   # a delete, not a push
  log="${AUTOCODER_RELEASE_LOG:-${XDG_STATE_HOME:-$HOME/.local/state}/autocoder/release.log}"
  mkdir -p "$(dirname "$log")" 2>/dev/null || continue
  wait_s="${AUTOCODER_RELEASE_WAIT:-${AGENTS_UI_RELEASE_WAIT:-120}}"
  (
    cd "$main" || exit 0
    echo "$(now) pushed ${local_sha:0:12} to $remote/$integration; releasing once it lands"
    deadline=$((SECONDS + wait_s))
    until [ "$(git ls-remote "$remote" "refs/heads/$integration" 2>/dev/null | cut -f1)" = "$local_sha" ]; do
      [ "$SECONDS" -lt "$deadline" ] || { echo "$(now) ${local_sha:0:12} never reached $remote/$integration; not releasing"; exit 0; }
      sleep 2
    done
    bash "$here/release.sh" --integration "$integration" --commit "$local_sha" \
      || echo "$(now) release of ${local_sha:0:12} failed; the next push or deploy releases it"
  ) >> "$log" 2>&1 < /dev/null &
  disown 2>/dev/null || true
done
exit 0
