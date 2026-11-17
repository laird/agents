#!/bin/bash
# merge-queue-fns.sh — one landing at a time per integration branch per host (#189).
#
# WHY:
#   Every fix-loop worker launches its own merge job the moment it finishes. Jobs on one
#   host used to fetch the integration tip, gate, and push all at once, so every overlap but
#   the first to push ended in `! [rejected] (non-fast-forward)`, a "Re-sync origin/<branch>
#   into <feature> (push retry N)" merge commit, often a second gate, and sometimes a
#   conflict escalation between two branches that had each gated green on their own.
#
#   merge-to-integration.sh now takes this queue's lock BEFORE it fetches the integration
#   tip and holds it until the push is verified. Jobs behind it wait, and each one syncs
#   onto the tip only when its turn comes, by which point every earlier landing on this
#   host is already on the remote. Two jobs on one host can no longer race each other's
#   push. A push from another host can still reject; the existing re-sync-and-retry loop
#   handles that case as before.
#
# KEY:
#   The lock is per (origin URL, integration branch), not per checkout, so two clones of
#   one repo on the same host share a queue, and two branches of one repo do not. Without
#   an origin URL it falls back to the repo id (repo-id-fns.sh).
#
#   ${AUTOCODER_TMP:-/tmp}/autocoder-land-<key>.lock    flock(1) target, held on fd 8
#   ${AUTOCODER_TMP:-/tmp}/autocoder-land-<key>.holder  "issue #N pid P since T" for logs
#
# The kernel drops a flock when every descriptor on it is closed, so a job that dies for
# any reason releases its place. Long-lived children (the gate) must not inherit fd 8,
# or an orphaned gate would keep the queue blocked: run them with `8>&-`.
#
# SETTINGS (environment):
#   AUTOCODER_MERGE_QUEUE       1 (default) queue landings; 0 lands immediately, as before
#   AUTOCODER_MERGE_QUEUE_WAIT  seconds to wait for the lock (default 7200; 0 = forever).
#                               On timeout the job lands unqueued and says so: a stuck
#                               holder must not strand every later merge on the host.

MERGE_QUEUE_HELD=0
MERGE_QUEUE_LOCK=""

# merge_queue_key <dir> <integration-branch>: a short stable id for the lock name.
merge_queue_key() {
  local dir="$1" branch="$2" url
  url=$(git -C "$dir" remote get-url origin 2>/dev/null || echo "")
  url="${url%/}"; url="${url%.git}"
  if [ -z "$url" ]; then
    url="repo:$(autocoder_repo_id "$dir" 2>/dev/null || echo unknown)"
  fi
  printf '%s\n%s\n' "$url" "$branch" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-16
}

# merge_queue_acquire <dir> <integration-branch> <issue>: waits for this host's landing
# lock on the branch. Always returns 0; when it could not queue it says why and carries on.
merge_queue_acquire() {
  local dir="$1" branch="$2" issue="$3" root key wait holder
  MERGE_QUEUE_HELD=0
  if [ "${AUTOCODER_MERGE_QUEUE:-1}" = "0" ]; then
    echo "ℹ️  Landing queue off (AUTOCODER_MERGE_QUEUE=0); landing without waiting for other jobs on this host."
    return 0
  fi
  if ! command -v flock >/dev/null 2>&1; then
    echo "⚠️  flock not found; landing without the host queue (a sibling push may still race this one)."
    return 0
  fi
  root="${AUTOCODER_TMP:-/tmp}"
  key=$(merge_queue_key "$dir" "$branch")
  MERGE_QUEUE_LOCK="${root}/autocoder-land-${key}.lock"
  wait="${AUTOCODER_MERGE_QUEUE_WAIT:-7200}"
  [[ "$wait" =~ ^[0-9]+$ ]] || wait=7200

  exec 8>>"$MERGE_QUEUE_LOCK" || { echo "⚠️  Could not open ${MERGE_QUEUE_LOCK}; landing without the host queue."; return 0; }
  if ! flock -n 8; then
    holder=$(cat "${MERGE_QUEUE_LOCK%.lock}.holder" 2>/dev/null || echo "another merge job")
    echo "⏳ Queued: ${holder} is landing on '${branch}' from this host; waiting for it to push ($(date +%H:%M:%S))"
    local rc
    if [ "$wait" -eq 0 ]; then flock 8; rc=$?; else flock -w "$wait" 8; rc=$?; fi
    if [ "$rc" -ne 0 ]; then
      echo "⚠️  Still queued after ${wait}s behind ${holder}; landing without the host queue (the push retry loop still guards the race)."
      exec 8>&-
      return 0
    fi
    echo "▶️  Our turn to land on '${branch}' ($(date +%H:%M:%S))"
  fi
  MERGE_QUEUE_HELD=1
  printf 'issue #%s (pid %s, since %s)\n' "$issue" "$$" "$(date +%H:%M:%S)" > "${MERGE_QUEUE_LOCK%.lock}.holder" 2>/dev/null || true
  return 0
}

# merge_queue_release: lets the next job on this host land. Safe to call more than once.
merge_queue_release() {
  [ "$MERGE_QUEUE_HELD" = "1" ] || return 0
  rm -f "${MERGE_QUEUE_LOCK%.lock}.holder" 2>/dev/null || true
  flock -u 8 2>/dev/null || true
  exec 8>&-
  MERGE_QUEUE_HELD=0
}
