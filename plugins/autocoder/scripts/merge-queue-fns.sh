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
#   ${AUTOCODER_TMP:-/tmp}/autocoder-land-<key>.lock    flock(1) target
#   ${AUTOCODER_TMP:-/tmp}/autocoder-land-<key>.holder  "issue #N pid P since T" for logs
#
# WHO HOLDS THE LOCK:
#   Not the job. A small holder subshell opens the lock file, flocks it, and then only
#   watches the job's pid; the job never has the descriptor, so nothing it spawns (the gate,
#   git's auto-gc, an ssh ControlPersist master, a credential daemon, a hook that forks) can
#   inherit the lock and keep the queue blocked after the job is gone. Release kills the
#   holder; if the job dies any other way, the holder notices within a second and exits,
#   and the kernel drops the flock with it.
#
# The holder file is a label for logs only, and may be stale after a crash or written by
# someone else; it is read as one sanitised line and never trusted, and written by
# mktemp + mv so a symlink planted at its predictable name is replaced, not followed.
#
# SETTINGS (environment):
#   AUTOCODER_MERGE_QUEUE       1 (default) queue landings; 0 lands immediately, as before
#   AUTOCODER_MERGE_QUEUE_WAIT  seconds to wait for the lock (default 7200; 0 = forever).
#                               On timeout the job lands unqueued and says so: a stuck
#                               holder must not strand every later merge on the host.

MERGE_QUEUE_HELD=0
MERGE_QUEUE_LOCK=""
MERGE_QUEUE_PID=""
MERGE_QUEUE_DIR=""

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

# _merge_queue_holder_name: who holds the lock, as one sanitised printable line.
_merge_queue_holder_name() {
  local h
  h=$(head -n1 "${MERGE_QUEUE_LOCK%.lock}.holder" 2>/dev/null | tr -cd '[:print:]' | cut -c1-80)
  printf '%s' "${h:-another merge job}"
}

# merge_queue_acquire <dir> <integration-branch> <issue>: waits for this host's landing
# lock on the branch. Always returns 0; when it could not queue it says why and carries on.
merge_queue_acquire() {
  local dir="$1" branch="$2" issue="$3" root key wait owner announced=0 tmp rc polls=0
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
  # Private 0700 dir for the holder's handshake files.
  if ! MERGE_QUEUE_DIR=$(mktemp -d "${root}/autocoder-land-${key}.XXXXXX" 2>/dev/null); then
    echo "⚠️  Could not create a queue scratch dir under ${root}; landing without the host queue."
    MERGE_QUEUE_DIR=""; return 0
  fi
  owner="${BASHPID:-$$}"

  (
    exec 8>>"$MERGE_QUEUE_LOCK" || exit 3
    if ! flock -n 8; then
      : > "$MERGE_QUEUE_DIR/waiting"
      if [ "$wait" -eq 0 ]; then flock 8 || exit 1; else flock -w "$wait" 8 || exit 1; fi
    fi
    # Name ourselves before anything else, so a waiter that arrives now can say whom it waits on.
    if tmp=$(mktemp "${MERGE_QUEUE_LOCK%.lock}.holder.XXXXXX" 2>/dev/null); then
      { printf 'issue #%s (pid %s, since %s)\n' "$issue" "$owner" "$(date +%H:%M:%S)" > "$tmp" \
        && mv -f "$tmp" "${MERGE_QUEUE_LOCK%.lock}.holder"; } 2>/dev/null || rm -f "$tmp"
    fi
    : > "$MERGE_QUEUE_DIR/held"
    while kill -0 "$owner" 2>/dev/null; do sleep 1 8>&-; done
    # The owner died without releasing (SIGKILL): tidy what it would have removed.
    rm -f "${MERGE_QUEUE_LOCK%.lock}.holder"; rm -rf "$MERGE_QUEUE_DIR"
  ) </dev/null >/dev/null 2>&1 &
  MERGE_QUEUE_PID=$!

  while kill -0 "$MERGE_QUEUE_PID" 2>/dev/null && [ ! -e "$MERGE_QUEUE_DIR/held" ]; do
    # Announce once we know we wait; give the holder a moment to name itself first.
    if [ "$announced" -eq 0 ] && [ -e "$MERGE_QUEUE_DIR/waiting" ] \
       && { [ -s "${MERGE_QUEUE_LOCK%.lock}.holder" ] || [ "$polls" -ge 10 ]; }; then
      echo "⏳ Queued: $(_merge_queue_holder_name) is landing on '${branch}' from this host; waiting for it to push ($(date +%H:%M:%S))"
      announced=1
    fi
    polls=$((polls + 1))
    sleep 0.2
  done

  if [ ! -e "$MERGE_QUEUE_DIR/held" ]; then
    wait "$MERGE_QUEUE_PID" 2>/dev/null; rc=$?
    if [ "$rc" -eq 3 ]; then
      echo "⚠️  Could not open ${MERGE_QUEUE_LOCK}; landing without the host queue."
    else
      echo "⚠️  Still queued after ${wait}s behind $(_merge_queue_holder_name); landing without the host queue (the push retry loop still guards the race)."
    fi
    rm -rf "$MERGE_QUEUE_DIR"; MERGE_QUEUE_DIR=""; MERGE_QUEUE_PID=""
    return 0
  fi
  [ "$announced" -eq 1 ] && echo "▶️  Our turn to land on '${branch}' ($(date +%H:%M:%S))"
  MERGE_QUEUE_HELD=1
  return 0
}

# merge_queue_release: lets the next job on this host land. Safe to call more than once,
# and from an EXIT trap.
merge_queue_release() {
  [ "$MERGE_QUEUE_HELD" = "1" ] || return 0
  MERGE_QUEUE_HELD=0
  rm -f "${MERGE_QUEUE_LOCK%.lock}.holder" 2>/dev/null || true
  if [ -n "$MERGE_QUEUE_PID" ]; then
    kill "$MERGE_QUEUE_PID" 2>/dev/null || true
    wait "$MERGE_QUEUE_PID" 2>/dev/null || true
  fi
  [ -n "$MERGE_QUEUE_DIR" ] && rm -rf "$MERGE_QUEUE_DIR"
  MERGE_QUEUE_PID=""; MERGE_QUEUE_DIR=""
}
