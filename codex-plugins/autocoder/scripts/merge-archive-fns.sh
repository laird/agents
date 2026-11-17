#!/usr/bin/env bash
# merge-archive-fns.sh — keep every merge attempt's log (#184).
#
# A merge job's files are <base>.{log,exit,pid,run.sh} with
# <base> = ${AUTOCODER_TMP:-/tmp}/autocoder-merge-<repo-id>-<issue>. They used to be
# overwritten by every relaunch and deleted a day after the job finished, so an
# issue's earlier bounces, retries and conflicts were lost. Instead, a finished
# attempt's log and exit status are archived as <base>.<n>.log / .<n>.exit:
#   - merge-launch.sh archives the previous attempt before starting the next;
#   - main-sentinel.sh archives a day-old finished attempt instead of deleting it,
#     and prunes archives after AUTOCODER_MERGE_ARCHIVE_DAYS (default 14).
# Both use these functions, so attempt numbers never repeat for an issue.

# merge_last_archived <base> → the highest archived attempt number, 0 if none.
merge_last_archived() {
  local base="$1" f n max=0
  for f in "$base".[0-9]*.log "$base".[0-9]*.exit; do
    [ -e "$f" ] || continue
    n="${f%.*}"; n="${n##*.}"
    [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -gt "$max" ] && max="$n"
  done
  echo "$max"
}

# merge_archive_attempt <base> → archive <base>.log/.exit (if any) as the next number.
merge_archive_attempt() {
  local base="$1" n
  [ -s "$base.log" ] || [ -f "$base.exit" ] || return 0
  n=$(( $(merge_last_archived "$base") + 1 ))
  [ -f "$base.log" ] && mv -f "$base.log" "$base.$n.log"
  [ -f "$base.exit" ] && mv -f "$base.exit" "$base.$n.exit"
  # mv keeps the old mtime; retention counts from archiving, not from the job's end.
  touch "$base.$n.log" "$base.$n.exit" 2>/dev/null || true
  return 0
}

# merge_next_attempt <base> → the attempt number a job starting now will have.
merge_next_attempt() {
  echo $(( $(merge_last_archived "$1") + 1 ))
}

# merge_reap_finished <tmp-root> [is-live-fn]
# Archive each finished job (exit file older than a day, not live) and drop its control
# files; then prune archives older than AUTOCODER_MERGE_ARCHIVE_DAYS (default 14).
merge_reap_finished() {
  local root="$1" live="${2:-}" pf base
  for pf in "$root"/autocoder-merge-*.exit; do
    [ -f "$pf" ] || continue
    [[ "${pf##*/}" =~ \.[0-9]+\.exit$ ]] && continue   # already an archived attempt
    base="${pf%.exit}"
    if [ -n "$live" ] && "$live" "$base"; then continue; fi
    [ -n "$(find "$pf" -mmin +1440 2>/dev/null)" ] || continue
    merge_archive_attempt "$base"
    rm -f "$base".{pid,run.sh,rerun}
  done
  # Prune archives only: <base>.<digits>.log/.exit. A glob like *.[0-9]*.log would also
  # catch a current log whose repo id contains ".<digit>" (e.g. my.2app).
  local days="${AUTOCODER_MERGE_ARCHIVE_DAYS:-14}" f
  [[ "$days" =~ ^[0-9]+$ ]] || days=14
  for f in "$root"/autocoder-merge-*.log "$root"/autocoder-merge-*.exit; do
    [ -f "$f" ] || continue
    [[ "${f##*/}" =~ \.[0-9]+\.(log|exit)$ ]] || continue
    [ -n "$(find "$f" -mtime +"$days" 2>/dev/null)" ] && rm -f "$f"
  done
  return 0
}
