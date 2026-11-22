#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255: never write the real event logs
# tests/test_merge_worktree_prune.sh — merge worktrees cost disk only while they are used (#144).
#
# 1. A job waiting in the landing queue (#189) holds no checkout: merge-to-integration.sh
#    creates its worktree only once the queue lets it in. The test holds the queue lock,
#    starts a job, and checks that no worktree exists for it until the lock is let go.
# 2. A job removes this repo's merge worktrees whose owner is dead: a dead pid in the
#    .owner file, or (a worktree from before #144) no owner file and no live merge-launch.sh
#    pidfile. A live owner's worktree and another repo's worktree are left alone.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$ROOT/plugins/autocoder/scripts"
MTI="$SCRIPT_DIR/merge-to-integration.sh"

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
LIVE=""
trap '[ -n "$LIVE" ] && kill "$LIVE" 2>/dev/null; rm -rf "$TMP"' EXIT
export ISSUE_SOURCE=file
export AUTOCODER_TMP="$TMP/tmp"; mkdir -p "$AUTOCODER_TMP"
export AUTOCODER_GATE_CACHE_DIR="$TMP/gate-cache"
# shellcheck source=../plugins/autocoder/scripts/repo-id-fns.sh
source "$SCRIPT_DIR/repo-id-fns.sh"
# shellcheck source=../plugins/autocoder/scripts/merge-queue-fns.sh
source "$SCRIPT_DIR/merge-queue-fns.sh"

git init --bare -q "$TMP/origin.git"
git init -q "$TMP/w"
git -C "$TMP/w" config user.email t@example.com; git -C "$TMP/w" config user.name T
git -C "$TMP/w" remote add origin "$TMP/origin.git"
echo base > "$TMP/w/README.md"
git -C "$TMP/w" add -A; git -C "$TMP/w" commit -q -m init; git -C "$TMP/w" branch -M master
git -C "$TMP/w" push -q origin master
new_feature() {  # <name>: a feature branch off master adding <name>.txt
  git -C "$TMP/w" checkout -q -B "feature/$1" master
  echo "$1" > "$TMP/w/$1.txt"; git -C "$TMP/w" add -A; git -C "$TMP/w" commit -q -m "add $1"
  git -C "$TMP/w" checkout -q master
}
REPO_ID=$(autocoder_repo_id "$TMP/w")
WT="$AUTOCODER_TMP/autocoder-merge-worktree-${REPO_ID}"

# ── 1. a queued job holds no checkout ───────────────────────────────────────
new_feature a
KEY=$(merge_queue_key "$TMP/w" master)
echo "issue #999 (pid 1, since 00:00:00)" > "$AUTOCODER_TMP/autocoder-land-${KEY}.holder"
flock "$AUTOCODER_TMP/autocoder-land-${KEY}.lock" sleep 30 &
HOLDER=$!
for _ in $(seq 1 50); do flock -n "$AUTOCODER_TMP/autocoder-land-${KEY}.lock" true || break; sleep 0.1; done
(cd "$TMP/w" && AUTOCODER_MERGE_QUEUE_WAIT=0 bash "$MTI" --feature feature/a --issue 301 \
  --integration master --test-cmd "true" > "$TMP/q.log" 2>&1) &
JOB=$!
for _ in $(seq 1 40); do grep -q "Queued: issue #999" "$TMP/q.log" 2>/dev/null && break; sleep 0.1; done
grep -q "Queued: issue #999" "$TMP/q.log" && ok "the job is waiting in the landing queue" || bad "the job never queued: $(cat "$TMP/q.log")"
[ ! -e "${WT}-301" ] && ok "a queued job has no worktree yet" || bad "a queued job already holds ${WT}-301"
git -C "$TMP/w" worktree list | grep -q "worktree-${REPO_ID}-301" && bad "a queued job registered a worktree" || ok "a queued job registered no worktree"
pkill -P "$HOLDER" 2>/dev/null; kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
wait "$JOB"
grep -q "merged into 'master'" "$TMP/q.log" && ok "once let in, the job merges" || bad "the job did not merge: $(cat "$TMP/q.log")"
[ ! -e "${WT}-301" ] && [ ! -e "${WT}-301.owner" ] && ok "the job removes its worktree and owner file" || bad "leftovers: $(ls "$AUTOCODER_TMP")"

# ── 2. a later job prunes the dead jobs' worktrees ──────────────────────────
sleep 0 & DEAD=$!; wait "$DEAD"
sleep 120 & LIVE=$!
add_wt() { git -C "$TMP/w" worktree add -q --detach "$1" master; }
add_wt "${WT}-500"; echo "$DEAD" > "${WT}-500.owner"            # owner dead
add_wt "${WT}-501"; echo "$LIVE" > "${WT}-501.owner"            # owner alive
add_wt "${WT}-502"                                             # pre-#144, no launcher pidfile
add_wt "${WT}-503-base"                                        # pre-#144, launcher alive
echo "$LIVE" > "$AUTOCODER_TMP/autocoder-merge-${REPO_ID}-503.pid"
add_wt "${WT}-504"; echo "$DEAD" > "$AUTOCODER_TMP/autocoder-merge-${REPO_ID}-504.pid"  # launcher dead
echo "$DEAD" > "${WT}-505.owner"                               # owner file with no worktree
OTHER="$AUTOCODER_TMP/autocoder-merge-worktree-otherrepo-abc123-600"
mkdir -p "$OTHER"; echo "$DEAD" > "${OTHER}.owner"              # another repo's, dead
PREFIXED="${WT}-foo-5e6f7a8b-12"; mkdir -p "$PREFIXED"            # a repo whose id starts with ours

new_feature b
(cd "$TMP/w" && bash "$MTI" --feature feature/b --issue 302 --integration master --test-cmd "true" > "$TMP/p.log" 2>&1)
grep -q "merged into 'master'" "$TMP/p.log" && ok "the pruning job still merges" || bad "the pruning job did not merge: $(cat "$TMP/p.log")"
[ ! -e "${WT}-500" ] && [ ! -e "${WT}-500.owner" ] && ok "a dead owner's worktree and owner file are removed" || bad "dead owner's worktree kept"
grep -q "left by a dead job for issue #500" "$TMP/p.log" && ok "the removal is logged" || bad "no removal line: $(cat "$TMP/p.log")"
[ -d "${WT}-501" ] && [ -f "${WT}-501.owner" ] && ok "a live owner's worktree is kept" || bad "a live owner's worktree was removed"
[ ! -e "${WT}-502" ] && ok "an ownerless worktree with no launcher pidfile is removed" || bad "ownerless worktree kept"
[ -d "${WT}-503-base" ] && ok "an ownerless -base worktree whose launcher is alive is kept" || bad "a live launcher's -base worktree was removed"
[ ! -e "${WT}-504" ] && ok "an ownerless worktree whose launcher is dead is removed" || bad "dead launcher's worktree kept"
[ ! -e "${WT}-505.owner" ] && ok "a dead owner file with no worktree is removed" || bad "litter owner file kept"
[ -d "$OTHER" ] && [ -f "${OTHER}.owner" ] && ok "another repo's worktree is left alone" || bad "another repo's worktree was touched"
[ -d "$PREFIXED" ] && ok "a repo whose id has ours as a prefix is left alone" || bad "a prefixed repo's worktree was pruned"
LIST=$(git -C "$TMP/w" worktree list)
printf '%s\n' "$LIST" | grep -qE -- "-(500|502|504) " && bad "git still lists a pruned worktree: $LIST" || ok "git's worktree list drops the pruned worktrees"
printf '%s\n' "$LIST" | grep -q -- "-501 " && ok "git still lists the live worktree" || bad "the live worktree lost its registration: $LIST"

# ── 3. the prune function on its own: never fails, never touches its caller's issue ──
# shellcheck source=../plugins/autocoder/scripts/merge-worktree-fns.sh
source "$SCRIPT_DIR/merge-worktree-fns.sh"
mkdir -p "${WT}-700"
merge_worktree_prune_stale "$AUTOCODER_TMP" "$REPO_ID" "$TMP/w" 700 >/dev/null
[ -d "${WT}-700" ] && ok "the caller's own issue is skipped" || bad "the caller's own worktree was pruned"
merge_worktree_prune_stale "$TMP/does-not-exist" "$REPO_ID" "$TMP/w" 1 && ok "an empty root prunes nothing and returns 0" || bad "prune failed on an empty root"
ln -s "$TMP/w" "${WT}-701"
merge_worktree_prune_stale "$AUTOCODER_TMP" "$REPO_ID" "$TMP/w" 1 >/dev/null
[ -f "$TMP/w/README.md" ] && [ -L "${WT}-701" ] && ok "a symlink at a worktree name is not followed" || bad "the prune followed a symlink"

TOTAL=$((PASS + FAIL))
echo "$PASS passed / $FAIL failed / $TOTAL total"
[ "$FAIL" -eq 0 ]
