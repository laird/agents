#!/usr/bin/env bash
# publisher.sh — the ONE writer of the integration branch.
#
# A queue, a merge train, a single-change gate and a person all land a gated tree by calling
# `publisher.sh publish`; nothing else should push the integration branch. The publisher owns
# four things so its callers do not:
#
#   1. Ordering. It holds a HOST LEASE (a kernel flock, so it dies with its holder) and, for two
#      hosts that share one remote, a REF LEASE (a ref on the remote created only if absent, with
#      an expiry so a dead host's lease is stolen). Pushes are serialised behind the leases, so a
#      second landing starts from a branch that already carries the first instead of being
#      rejected and re-synced.
#   2. The landing itself, by the project's mode: `ff` pushes the gated commit when it
#      fast-forwards the branch and otherwise returns it as stale; `merge` also accepts a branch
#      that moved under the gate when everything that arrived is a document and the document
#      checks pass (the tested-tree rule: code that arrived untested forces a re-gate).
#   3. The FAST LANE. A documents-only or mechanical change is enqueued with `enqueue`, rides in
#      the next publish, or lands at once when no batch is in flight, with the document checks
#      and no test stages.
#   4. The record. Every publish and rejection goes to the landing-timings writer.
#
# Commands (all take --repo DIR, default the current directory, and --remote NAME, default origin):
#   publish   --sha SHA --branch B [--mode ff|merge] [--batch ID] [--issues 1,2] [--no-fastlane]
#   enqueue   --sha REF --issue N [--branch B] [--no-wait] [--timeout SECS]
#   drain     [--branch B]          land the pending fast-lane entries now (the manual path)
#   batch-begin --pid PID [--batch ID]   a batch is in flight until PID exits (or batch-end)
#   batch-end [--force]
#   status    list the fast lane           health     check the publisher; exit 1 on a problem
#   lease-break [--force]           remove an expired ref lease (any ref lease with --force)
#
# Exit codes: 0 done; 1 failed (enqueue: the entry failed; health: a problem); 2 usage;
# 3 stale (not landable on the branch as it is now; re-gate on the new tip); 4 push refused after
# retries; 5 a lease was not taken in time; 6 not eligible for the fast lane.
#
# Configuration (environment):
#   AUTOCODER_PUBLISH_STATE      state dir (default ${XDG_STATE_HOME:-~/.local/state}/autocoder/publisher)
#   AUTOCODER_LANDING_LEASE      host lease file (default <state>/landing.lease). A pre-push hook that
#                                takes the same lease must skip when AUTOCODER_LANDING_LEASE_HELD=1,
#                                which the publisher exports around its own push.
#   AUTOCODER_LANDING_WAIT_SECONDS  wait for the leases (default 3600; queue wait is never a failure)
#   AUTOCODER_REF_LEASE          on|off (default off): the second lease, on the remote
#   AUTOCODER_REF_LEASE_TTL      seconds before a ref lease may be stolen (default 3600)
#   AUTOCODER_PUBLISH_MODE       ff|merge (default ff)
#   AUTOCODER_DOCS_PATHS, AUTOCODER_DOCS_CODE_PATHS   the project's documents overrides, the same
#                                values merge-to-integration.sh's documents re-sync reads
#   AUTOCODER_FASTLANE_PATHS     globs of MECHANICAL paths (regenerated files) that may ride the
#                                fast lane beside documents
#   AUTOCODER_FASTLANE_CHECK_CMD cheap checks run on the tree a fast lane change lands in
#                                (default AUTOCODER_DOCS_RESYNC_CMD; none when both are unset)
#   AUTOCODER_FASTLANE_MAX_AGE   health: a pending entry older than this (default 3600) with no
#                                batch in flight means the queue is down
#   AUTOCODER_LANDING_TIMINGS    the timings file (see landing-timings.py)

_PUB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=test-cmd-fns.sh
source "${_PUB_DIR}/test-cmd-fns.sh"
landing_change() { :; }
landing_batch() { :; }
# shellcheck source=landing-timings-lib.sh
[ -f "${_PUB_DIR}/landing-timings-lib.sh" ] && source "${_PUB_DIR}/landing-timings-lib.sh"

STATE="${AUTOCODER_PUBLISH_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/autocoder/publisher}"
LEASE_FILE="${AUTOCODER_LANDING_LEASE:-$STATE/landing.lease}"
LEASE_WAIT="${AUTOCODER_LANDING_WAIT_SECONDS:-3600}"
REF_LEASE="${AUTOCODER_REF_LEASE:-off}"
REF_TTL="${AUTOCODER_REF_LEASE_TTL:-3600}"
FASTLANE_CHECK="${AUTOCODER_FASTLANE_CHECK_CMD-${AUTOCODER_DOCS_RESYNC_CMD:-}}"
EMPTY_TREE=4b825dc642cb6eb9a060e54bf8d69288fbee4904

REPO="." REMOTE=origin BRANCH="${CLAUDE_CODE_SHIP_BRANCH:-}" MODE="${AUTOCODER_PUBLISH_MODE:-ff}"
SCRATCH="" REF_LEASE_SHA="" REF_NAME=""

die() { echo "publisher: $*" >&2; exit "${2:-1}"; }
now() { date +%s; }
g() { git -C "$REPO" "$@"; }

_ident() {  # a scratch merge or cherry-pick needs an identity on a host that has none
  g config user.email >/dev/null 2>&1 || { export GIT_AUTHOR_NAME=publisher GIT_AUTHOR_EMAIL=publisher@localhost GIT_COMMITTER_NAME=publisher GIT_COMMITTER_EMAIL=publisher@localhost; }
}

_fetch_tip() {  # print the remote branch tip, fetched into a remote-tracking ref
  g fetch -q "$REMOTE" "+refs/heads/$BRANCH:refs/remotes/$REMOTE/$BRANCH" 2>/dev/null \
    && g rev-parse --verify "refs/remotes/$REMOTE/$BRANCH^{commit}"
}

_cleanup() {
  [ -n "$SCRATCH" ] && { g worktree remove --force "$SCRATCH" >/dev/null 2>&1; rm -rf "$SCRATCH"; SCRATCH=""; }
  _ref_lease_release
}
trap _cleanup EXIT

# ── leases ────────────────────────────────────────────────────────────────────

_host_lease_take() {
  command -v flock >/dev/null 2>&1 || die "flock(1) is required to publish (install util-linux)" 5
  mkdir -p "$(dirname "$LEASE_FILE")" || die "cannot create the lease directory for $LEASE_FILE" 5
  exec 9>>"$LEASE_FILE" || die "cannot open the host lease $LEASE_FILE" 5
  flock -w "$LEASE_WAIT" 9 || die "host lease $LEASE_FILE not free within ${LEASE_WAIT}s (AUTOCODER_LANDING_WAIT_SECONDS)" 5
  export AUTOCODER_LANDING_LEASE_HELD=1
}

_lease_ref() { REF_NAME="refs/autocoder/landing-lease/$BRANCH"; }

_ref_lease_expiry() {  # <sha>: the expiry epoch recorded in the lease commit
  g fetch -q "$REMOTE" "$REF_NAME" 2>/dev/null || return 1
  g log -1 --format=%B "$1" 2>/dev/null | sed -n 's/^expires=//p' | head -1
}

_ref_lease_take() {
  [ "$REF_LEASE" = on ] || return 0
  _lease_ref; _ident
  local deadline=$(( $(now) + LEASE_WAIT )) cur new exp
  while :; do
    cur=$(g ls-remote "$REMOTE" "$REF_NAME" 2>/dev/null | awk '{print $1}')
    new=$(printf 'holder=%s:%s\nexpires=%s\n' "$(hostname)" "$$" $(( $(now) + REF_TTL )) | g commit-tree "$EMPTY_TREE") || die "cannot create the ref lease commit" 5
    if [ -z "$cur" ]; then
      if g push -q "$REMOTE" "$new:$REF_NAME" --force-with-lease="$REF_NAME:" 2>/dev/null; then REF_LEASE_SHA=$new; return 0; fi
    else
      exp=$(_ref_lease_expiry "$cur")
      if [ -n "$exp" ] && [ "$(now)" -gt "$exp" ]; then
        echo "publisher: ref lease $REF_NAME expired at $exp; taking it over" >&2
        if g push -q "$REMOTE" "$new:$REF_NAME" --force-with-lease="$REF_NAME:$cur" 2>/dev/null; then REF_LEASE_SHA=$new; return 0; fi
      fi
    fi
    [ "$(now)" -lt "$deadline" ] || die "ref lease $REF_NAME on $REMOTE not free within ${LEASE_WAIT}s (held: ${cur:-unknown})" 5
    sleep 1
  done
}

_ref_lease_release() {
  [ -n "$REF_LEASE_SHA" ] || return 0
  g push -q "$REMOTE" ":$REF_NAME" --force-with-lease="$REF_NAME:$REF_LEASE_SHA" >/dev/null 2>&1 || true
  REF_LEASE_SHA=""
}

# ── classification ────────────────────────────────────────────────────────────

_fastlane_path() {  # rc 0 when the path may ride the fast lane
  is_docs_path "$1" || _docs_glob_match "$1" "${AUTOCODER_FASTLANE_PATHS:-}"
}

# <base> <sha>: print the files that keep a change off the fast lane; rc 0 iff there are none and
# the change touches at least one file.
_ineligible_files() {
  local base files f bad=""
  base=$(g merge-base "$1" "$2" 2>/dev/null) || { echo "(no merge base with the branch)"; return 1; }
  files=$(g diff --name-only "$base" "$2") || { echo "(diff failed)"; return 1; }
  [ -n "$files" ] || { echo "(empty change)"; return 1; }
  while IFS= read -r f; do _fastlane_path "$f" || bad="$bad $f"; done <<<"$files"
  [ -z "$bad" ] || { echo "${bad# }"; return 1; }
  return 0
}

# ── fast lane entries ─────────────────────────────────────────────────────────
# One file per entry: KEY=value lines. status: pending | landed | failed.

_entry_get() { sed -n "s/^$2=//p" "$1" | head -1; }
_entry_set() {  # <file> <key> <value>
  local tmp; tmp=$(mktemp "$1.XXXXXX") || return 1
  { grep -v "^$2=" "$1"; printf '%s=%s\n' "$2" "$3"; } >"$tmp"; mv "$tmp" "$1"
}
_pending_entries() { local f; for f in "$STATE/fastlane"/*.entry; do [ -f "$f" ] && [ "$(_entry_get "$f" status)" = pending ] && echo "$f"; done; }

_run_checks() {  # <dir>
  [ -n "$FASTLANE_CHECK" ] || return 0
  (cd "$1" && bash -c "$FASTLANE_CHECK") >&2
}

# Apply one entry on the scratch worktree's HEAD. rc 0 applied (or already there), 1 conflict.
_apply_entry() {
  local sha base
  sha=$(_entry_get "$1" sha)
  g cat-file -e "$sha^{commit}" 2>/dev/null || { echo "commit $sha is not in this repository"; return 1; }
  base=$(git -C "$SCRATCH" merge-base HEAD "$sha" 2>/dev/null) || { echo "no merge base with the landing tree"; return 1; }
  [ "$base" = "$sha" ] && return 0
  if [ -z "$(git -C "$SCRATCH" rev-list --merges "$base..$sha")" ]; then
    git -C "$SCRATCH" cherry-pick --allow-empty --keep-redundant-commits "$base..$sha" >/dev/null 2>&1 \
      || { echo "conflict: $(git -C "$SCRATCH" diff --name-only --diff-filter=U | tr '\n' ' ')"; git -C "$SCRATCH" cherry-pick --abort >/dev/null 2>&1; return 1; }
  else
    git -C "$SCRATCH" merge --no-edit "$sha" >/dev/null 2>&1 \
      || { echo "conflict: $(git -C "$SCRATCH" diff --name-only --diff-filter=U | tr '\n' ' ')"; git -C "$SCRATCH" merge --abort >/dev/null 2>&1; return 1; }
  fi
}

# Apply every pending entry onto the scratch HEAD, checks on the result; on a failed check retry
# one by one so a bad document costs only itself. Sets FL_LANDED (entry files) and FL_FAILED.
_apply_fastlane() {
  FL_LANDED=() FL_FAILED=()
  local entries f why start prev
  mapfile -t entries < <(_pending_entries)
  [ "${#entries[@]}" -gt 0 ] || return 0
  start=$(git -C "$SCRATCH" rev-parse HEAD)
  _try_all() {
    local f why
    for f in "${entries[@]}"; do
      if why=$(_apply_entry "$f"); then FL_LANDED+=("$f"); else FL_FAILED+=("$f|$why"); fi
    done
    [ "${#FL_LANDED[@]}" -eq 0 ] || _run_checks "$SCRATCH"
  }
  if _try_all; then return 0; fi
  # The checks failed on the combined tree: start over, one entry at a time.
  git -C "$SCRATCH" reset -q --hard "$start"; FL_LANDED=() FL_FAILED=()
  for f in "${entries[@]}"; do
    prev=$(git -C "$SCRATCH" rev-parse HEAD)
    if ! why=$(_apply_entry "$f"); then FL_FAILED+=("$f|$why"); continue; fi
    if _run_checks "$SCRATCH"; then FL_LANDED+=("$f")
    else git -C "$SCRATCH" reset -q --hard "$prev"; FL_FAILED+=("$f|document checks failed"); fi
  done
  return 0
}

# ── publish ───────────────────────────────────────────────────────────────────

# One attempt: fetch the tip, decide the candidate, apply the fast lane, push. rc 0 landed,
# 3 stale, 10 push rejected (retry), 11 nothing to publish.
_attempt() {
  local tip cand base want="$SHA"
  tip=$(_fetch_tip) || die "cannot fetch $BRANCH from $REMOTE" 4
  # Already on the branch (an earlier publish, or the other host): nothing of it left to land.
  if [ -n "$want" ] && g merge-base --is-ancestor "$want" "$tip"; then want=""; fi
  SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/publisher.XXXXXX") || die "cannot create a scratch directory" 4
  rm -rf "$SCRATCH"
  cand=${want:-$tip}
  g worktree add -q --detach "$SCRATCH" "$cand" || die "cannot create the scratch worktree at $cand" 4
  if [ -n "$want" ] && ! g merge-base --is-ancestor "$tip" "$want"; then
    local incoming f
    if [ "$MODE" != merge ]; then ATTEMPT_WHY="$BRANCH moved to ${tip:0:10}; $want is not a fast-forward of it (mode ff)"; return 3; fi
    base=$(g merge-base "$tip" "$want") || { ATTEMPT_WHY="no merge base between ${tip:0:10} and ${want:0:10}"; return 3; }
    incoming=$(g diff --name-only "$base" "$tip")
    while IFS= read -r f; do
      [ -z "$f" ] || is_docs_path "$f" || { ATTEMPT_WHY="$BRANCH moved to ${tip:0:10} with code ($f) the gate never saw; re-gate"; return 3; }
    done <<<"$incoming"
    git -C "$SCRATCH" merge --no-edit "$tip" >/dev/null 2>&1 \
      || { git -C "$SCRATCH" merge --abort >/dev/null 2>&1; ATTEMPT_WHY="conflict merging ${tip:0:10} into ${want:0:10}"; ATTEMPT_CAUSE=conflict; return 3; }
    _run_checks "$SCRATCH" || { ATTEMPT_WHY="document checks failed on the merged tree"; return 3; }
    PUBLISH_BASIS=docs-resync
  fi
  FL_LANDED=() FL_FAILED=()
  [ "$NO_FASTLANE" -eq 1 ] || _apply_fastlane
  cand=$(git -C "$SCRATCH" rev-parse HEAD)
  [ "$cand" != "$tip" ] || return 11
  if g push -q "$REMOTE" "$cand:refs/heads/$BRANCH" 2>"$STATE/push.err"; then LANDED_SHA=$cand; return 0; fi
  ATTEMPT_WHY=$(tr '\n' ' ' <"$STATE/push.err"); return 10
}

cmd_publish() {
  local t0 rejected=0 attempts=0 rc=0 f entry
  t0=$(now); ATTEMPT_WHY="" ATTEMPT_CAUSE=stale-base PUBLISH_BASIS=tested LANDED_SHA=""
  [ -n "$BRANCH" ] || die "--branch is required (or CLAUDE_CODE_SHIP_BRANCH)" 2
  case "$MODE" in ff|merge) ;; *) die "--mode must be ff or merge, got '$MODE'" 2 ;; esac
  if [ -n "$SHA" ]; then SHA=$(g rev-parse --verify "$SHA^{commit}" 2>/dev/null) || die "$SHA is not a commit in $REPO" 2; fi
  [ -n "$SHA" ] || [ "$FASTLANE_ONLY" -eq 1 ] || die "--sha is required" 2
  mkdir -p "$STATE/fastlane" || die "cannot create $STATE" 4
  _ident; _host_lease_take; _ref_lease_take
  while [ "$attempts" -lt 4 ]; do
    attempts=$((attempts + 1))
    _attempt; rc=$?
    [ -z "$SCRATCH" ] || { g worktree remove --force "$SCRATCH" >/dev/null 2>&1; rm -rf "$SCRATCH"; SCRATCH=""; }
    [ "$rc" -eq 10 ] || break
    rejected=$((rejected + 1))
    echo "publisher: push of $BRANCH rejected (attempt $attempts): $ATTEMPT_WHY" >&2
  done
  local secs=$(( $(now) - t0 )) bid="${BATCH:-}" solo=0 members
  [ -n "$bid" ] || { solo=1; bid="pub-$(date +%s)-$$"; }
  members="$ISSUES"
  for f in "${FL_LANDED[@]}"; do entry=${f%%|*}; members="${members:+$members,}$(_entry_get "$entry" issue)"; done
  case "$rc" in
    0)
      for f in "${FL_LANDED[@]}"; do _entry_set "$f" status landed; _entry_set "$f" landed_sha "$LANDED_SHA"; _entry_set "$f" landed_at "$(now)"; done
      for f in "${FL_FAILED[@]}"; do _fail_entry "${f%%|*}" "${f#*|}"; done
      [ -z "$members" ] || [ "$solo" -eq 0 ] || landing_batch --batch "$bid" --members "$members" --publish-s "$secs" \
        --verdict green --resyncs "$rejected" --push-rejected "$rejected"
      local i; for i in ${ISSUES//,/ }; do landing_change "$i" landed ${BATCH:+--batch "$BATCH"}; done
      for f in "${FL_LANDED[@]}"; do landing_change "$(_entry_get "$f" issue)" landed --batch "$bid"; done
      echo "landed $LANDED_SHA"
      echo "publish-result landed=1 sha=$LANDED_SHA basis=$PUBLISH_BASIS publish_s=$secs push_rejected=$rejected resyncs=$rejected fastlane=${#FL_LANDED[@]} fastlane_failed=${#FL_FAILED[@]}"
      return 0 ;;
    11)
      for f in "${FL_FAILED[@]}"; do _fail_entry "${f%%|*}" "${f#*|}"; done
      local i; for i in ${ISSUES//,/ }; do landing_change "$i" landed ${BATCH:+--batch "$BATCH"}; done
      echo "nothing to publish: $BRANCH already has everything"
      echo "publish-result landed=0 sha= basis=none publish_s=$secs push_rejected=$rejected resyncs=$rejected fastlane=0 fastlane_failed=0"
      return 0 ;;
    3)
      local i; for i in ${ISSUES//,/ }; do landing_change "$i" returned --cause "$ATTEMPT_CAUSE"; done
      [ "$solo" -eq 0 ] || [ -z "$ISSUES" ] || landing_batch --batch "$bid" --members "$ISSUES" --publish-s "$secs" --verdict aborted --cause "$ATTEMPT_CAUSE" --push-rejected "$rejected"
      echo "stale: $ATTEMPT_WHY" >&2
      echo "publish-result landed=0 sha= basis=stale publish_s=$secs push_rejected=$rejected resyncs=$rejected fastlane=0 fastlane_failed=0 cause=$ATTEMPT_CAUSE"
      return 3 ;;
    *)
      local i; for i in ${ISSUES//,/ }; do landing_change "$i" returned --cause other; done
      [ "$solo" -eq 0 ] || [ -z "$ISSUES" ] || landing_batch --batch "$bid" --members "$ISSUES" --publish-s "$secs" --verdict aborted --cause other --push-rejected "$rejected"
      echo "push refused $rejected times for $BRANCH on $REMOTE: $ATTEMPT_WHY" >&2
      echo "publish-result landed=0 sha= basis=refused publish_s=$secs push_rejected=$rejected resyncs=$rejected fastlane=0 fastlane_failed=0 cause=other"
      return 4 ;;
  esac
}

_fail_entry() {  # <entry file> <reason>
  _entry_set "$1" status failed; _entry_set "$1" reason "$2"
  landing_change "$(_entry_get "$1" issue)" returned --cause "$([[ "$2" == conflict* ]] && echo conflict || echo other)"
}

# ── fast lane commands ────────────────────────────────────────────────────────

_inflight_live() {  # rc 0 when a batch marker names a live pid
  local f="$STATE/inflight" pid
  [ -f "$f" ] || return 1
  pid=$(sed -n 's/^pid=//p' "$f" | head -1)
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

cmd_enqueue() {
  local resolved tip bad id file waited=0 st
  [ -n "$SHA" ] && [ -n "$ISSUE" ] || die "enqueue needs --sha REF and --issue N" 2
  [[ "$ISSUE" =~ ^[0-9]+$ ]] || die "--issue must be a number, got '$ISSUE'" 2
  [ -n "$BRANCH" ] || die "--branch is required (or CLAUDE_CODE_SHIP_BRANCH)" 2
  resolved=$(g rev-parse --verify "$SHA^{commit}" 2>/dev/null) || die "$SHA is not a commit in $REPO" 2
  tip=$(_fetch_tip) || die "cannot fetch $BRANCH from $REMOTE" 4
  [ -n "$(g branch -r --contains "$resolved" 2>/dev/null)" ] || die "$resolved is on no remote branch of $REMOTE; push the branch first so the lane can reach it" 6
  if bad=$(_ineligible_files "$tip" "$resolved"); then :; else
    echo "not eligible for the fast lane: $bad" >&2
    echo "  (documents by the plugin's rule and AUTOCODER_DOCS_PATHS/AUTOCODER_DOCS_CODE_PATHS; mechanical paths by AUTOCODER_FASTLANE_PATHS)" >&2
    return 6
  fi
  mkdir -p "$STATE/fastlane" || die "cannot create $STATE" 4
  id="$(now)-$ISSUE-${resolved:0:8}"; file="$STATE/fastlane/$id.entry"
  printf 'issue=%s\nsha=%s\nbranch=%s\nstatus=pending\nenqueued_at=%s\n' "$ISSUE" "$resolved" "$BRANCH" "$(now)" >"$file.tmp" && mv "$file.tmp" "$file"
  landing_change "$ISSUE" ready
  echo "enqueued #$ISSUE (${resolved:0:10}) on the fast lane for $BRANCH"
  while :; do
    if ! _inflight_live; then bash "$0" drain --repo "$REPO" --remote "$REMOTE" --branch "$BRANCH" >&2 || true; fi
    st=$(_entry_get "$file" status)
    case "$st" in
      landed) echo "landed $(_entry_get "$file" landed_sha)"; return 0 ;;
      failed) echo "failed: $(_entry_get "$file" reason)" >&2; return 1 ;;
    esac
    [ "$NO_WAIT" -eq 0 ] || { echo "pending: rides with the next batch"; return 0; }
    [ "$waited" -lt "$WAIT_TIMEOUT" ] || { echo "still pending after ${WAIT_TIMEOUT}s; it will land with the next publish or by 'drain'" >&2; return 1; }
    sleep 2; waited=$((waited + 2))
  done
}

cmd_drain() {
  # An empty lane is the usual case at a batch end: say so and take no lease, no fetch, no scratch.
  [ -n "$(_pending_entries)" ] || { echo "fast lane empty: nothing to drain for $BRANCH"; return 0; }
  FASTLANE_ONLY=1 cmd_publish
}

cmd_batch_begin() {
  [ -n "$PID" ] || die "batch-begin needs --pid" 2
  mkdir -p "$STATE" || die "cannot create $STATE" 4
  printf 'pid=%s\nbatch=%s\nstarted=%s\n' "$PID" "${BATCH:-}" "$(now)" >"$STATE/inflight.tmp" && mv "$STATE/inflight.tmp" "$STATE/inflight"
}

cmd_batch_end() {
  [ -f "$STATE/inflight" ] || return 0
  if [ "$FORCE" -eq 0 ] && _inflight_live; then die "a batch is in flight (pid $(sed -n 's/^pid=//p' "$STATE/inflight")); --force to clear it anyway" 1; fi
  rm -f "$STATE/inflight"
}

cmd_status() {
  local f
  for f in "$STATE/fastlane"/*.entry; do
    [ -f "$f" ] || continue
    printf '#%s %s %s%s\n' "$(_entry_get "$f" issue)" "$(_entry_get "$f" status)" "$(_entry_get "$f" sha | cut -c1-10)" "$(r=$(_entry_get "$f" reason); [ -n "$r" ] && echo " ($r)")"
  done
  _inflight_live && echo "batch in flight: $(cat "$STATE/inflight" | tr '\n' ' ')" || echo "no batch in flight"
  return 0
}

cmd_lease_break() {
  [ -n "$BRANCH" ] || die "--branch is required" 2
  _lease_ref
  local cur exp
  cur=$(g ls-remote "$REMOTE" "$REF_NAME" 2>/dev/null | awk '{print $1}')
  [ -n "$cur" ] || { echo "no ref lease on $REMOTE for $BRANCH"; return 0; }
  exp=$(_ref_lease_expiry "$cur")
  if [ "$FORCE" -eq 0 ] && { [ -z "$exp" ] || [ "$(now)" -le "$exp" ]; }; then
    die "ref lease $REF_NAME is held until ${exp:-unknown}; --force to break it" 1
  fi
  g push -q "$REMOTE" ":$REF_NAME" --force-with-lease="$REF_NAME:$cur" || die "could not delete $REF_NAME on $REMOTE" 1
  echo "ref lease $REF_NAME removed"
}

cmd_health() {
  local bad=0 f n=0 oldest="" age cur exp
  ok()   { echo "ok    $1"; }
  warn() { echo "warn  $1"; }
  fail() { echo "FAIL  $1"; bad=1; }
  [ -n "$BRANCH" ] || { fail "no --branch (or CLAUDE_CODE_SHIP_BRANCH)"; return 1; }
  command -v flock >/dev/null 2>&1 && ok "flock available" || fail "flock(1) missing: the publisher cannot take its host lease"
  mkdir -p "$STATE" 2>/dev/null && [ -w "$STATE" ] && ok "state dir $STATE writable" || fail "state dir $STATE is not writable"
  if g ls-remote --exit-code "$REMOTE" "refs/heads/$BRANCH" >/dev/null 2>&1; then ok "$REMOTE/$BRANCH reachable"; else fail "cannot read $BRANCH on $REMOTE"; fi
  if ( exec 8>>"$LEASE_FILE" && flock -n 8 ) 2>/dev/null; then ok "host lease free ($LEASE_FILE)"; else warn "host lease held now: a landing is in progress, or hung (holder: $(fuser "$LEASE_FILE" 2>/dev/null | tr -s ' ' | head -c 80))"; fi
  if [ "$REF_LEASE" = on ]; then
    _lease_ref; cur=$(g ls-remote "$REMOTE" "$REF_NAME" 2>/dev/null | awk '{print $1}')
    if [ -z "$cur" ]; then ok "ref lease free"
    else exp=$(_ref_lease_expiry "$cur"); if [ -n "$exp" ] && [ "$(now)" -gt "$exp" ]; then fail "ref lease expired at $exp and not released: 'lease-break' removes it (the next publish would take it over)"; else ok "ref lease held until ${exp:-unknown}"; fi; fi
  fi
  if [ -f "$STATE/inflight" ]; then
    if _inflight_live; then ok "batch in flight ($(tr '\n' ' ' <"$STATE/inflight"))"; else fail "batch marker names a dead pid: 'batch-end --force' clears it"; fi
  else ok "no batch marker"; fi
  for f in $(_pending_entries); do
    n=$((n + 1)); age=$(( $(now) - $(_entry_get "$f" enqueued_at) )); [ -n "$oldest" ] && [ "$age" -le "$oldest" ] || oldest=$age
  done
  if [ "$n" -eq 0 ]; then ok "fast lane empty"
  elif [ "$oldest" -gt "${AUTOCODER_FASTLANE_MAX_AGE:-3600}" ] && ! _inflight_live; then fail "fast lane: $n pending, oldest ${oldest}s with no batch in flight: the queue is down; run 'drain'"
  else ok "fast lane: $n pending, oldest ${oldest}s"; fi
  n=$(grep -l '^status=failed' "$STATE/fastlane"/*.entry 2>/dev/null | wc -l)
  [ "$n" -eq 0 ] && ok "no failed fast lane entries" || warn "$n failed fast lane entries (see 'status')"
  return "$bad"
}

# ── argument parsing ──────────────────────────────────────────────────────────

CMD="${1:-}"; [ $# -gt 0 ] && shift
SHA="" ISSUES="" ISSUE="" BATCH="" PID="" NO_FASTLANE=0 NO_WAIT=0 FORCE=0 FASTLANE_ONLY=0 WAIT_TIMEOUT=21600
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:?--repo needs a value}"; shift 2 ;;
    --remote) REMOTE="${2:?--remote needs a value}"; shift 2 ;;
    --branch) BRANCH="${2:?--branch needs a value}"; shift 2 ;;
    --mode) MODE="${2:?--mode needs a value}"; shift 2 ;;
    --sha) SHA="${2:?--sha needs a value}"; shift 2 ;;
    --issues) ISSUES="${2:?--issues needs a value}"; shift 2 ;;
    --issue) ISSUE="${2:?--issue needs a value}"; shift 2 ;;
    --batch) BATCH="${2:?--batch needs a value}"; shift 2 ;;
    --pid) PID="${2:?--pid needs a value}"; shift 2 ;;
    --timeout) WAIT_TIMEOUT="${2:?--timeout needs a value}"; shift 2 ;;
    --no-fastlane) NO_FASTLANE=1; shift ;;
    --no-wait) NO_WAIT=1; shift ;;
    --force) FORCE=1; shift ;;
    *) die "unknown argument '$1' (see the header of $0)" 2 ;;
  esac
done
[ -z "$ISSUES" ] || [[ "$ISSUES" =~ ^[0-9]+(,[0-9]+)*$ ]] || die "--issues must be comma-separated numbers, got '$ISSUES'" 2
case "$CMD" in
  publish) cmd_publish ;;
  enqueue) cmd_enqueue ;;
  drain) cmd_drain ;;
  batch-begin) cmd_batch_begin ;;
  batch-end) cmd_batch_end ;;
  status) cmd_status ;;
  health) cmd_health ;;
  lease-break) cmd_lease_break ;;
  *) die "usage: publisher.sh publish|enqueue|drain|batch-begin|batch-end|status|health|lease-break [options] (see the header of $0)" 2 ;;
esac
