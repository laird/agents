#!/bin/bash
# worker-health.sh — report the process health of every worker in the fleet.
#
# Read-only. For each worker worktree it reports:
#   - branch, last-commit age (minutes), uncommitted (dirty) file count
#   - resident memory (RSS, MB) of the agent process tree in that worktree
#   - a verdict: HEALTHY | STALLED | HIGHMEM | UNHEALTHY
#
# A worker is UNHEALTHY (the manager should restart it) only when it is BOTH
# stalled AND over the memory threshold — the conservative "both signals"
# trigger, so a busy-but-large worker or an idle-but-lean worker is left alone.
#
# Memory is measured by matching processes whose current working directory IS
# the worktree path. That cwd is the shared key across tmux AND cmux (the agent
# is launched after `cd <worktree>`), so this works regardless of multiplexer.
#
# Usage:
#   worker-health.sh [--mem-threshold-mb N] [--stall-min N] [--json]
#
# Defaults: --mem-threshold-mb 6000, --stall-min 60
# Override defaults with env: WORKER_MEM_THRESHOLD_MB, WORKER_STALL_MIN.
#
# Exit status: 0 always (reporting tool). Restart decisions are driven by the
# emitted "RESTART <worktree>" recommendation lines, not the exit code.

set -e

MEM_THRESHOLD_MB="${WORKER_MEM_THRESHOLD_MB:-6000}"
STALL_MIN="${WORKER_STALL_MIN:-60}"
JSON=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --mem-threshold-mb) MEM_THRESHOLD_MB="$2"; shift 2 ;;
    --stall-min)        STALL_MIN="$2";        shift 2 ;;
    --json)             JSON=true;             shift ;;
    -h|--help)
      echo "Usage: worker-health.sh [--mem-threshold-mb N] [--stall-min N] [--json]"
      exit 0
      ;;
    *) echo "❌ Unknown argument: $1" >&2; exit 1 ;;
  esac
done

now_epoch=$(date +%s)
MAIN_ROOT=$(pwd)

# ── Sum RSS (MB) of all processes whose cwd is the given worktree ────────────
# Returns -1 when memory cannot be determined (no tooling / no match), which the
# caller treats as "unknown" — and therefore never UNHEALTHY (needs high mem).
worker_rss_mb() {
  local wt="$1"
  local total_kb=0
  local matched=false
  local pid cwd rss

  if [ -d /proc ]; then
    # Linux: read cwd straight from /proc.
    for d in /proc/[0-9]*; do
      pid="${d#/proc/}"
      cwd=$(readlink "$d/cwd" 2>/dev/null) || continue
      [ "$cwd" = "$wt" ] || continue
      rss=$(awk '/^VmRSS:/{print $2}' "$d/status" 2>/dev/null)
      [ -n "$rss" ] && { total_kb=$((total_kb + rss)); matched=true; }
    done
  elif command -v lsof >/dev/null 2>&1; then
    # macOS / BSD: lsof maps each process's cwd file descriptor.
    local pids
    pids=$(lsof -a -d cwd -- "$wt" 2>/dev/null | awk 'NR>1 {print $2}' | sort -u)
    for pid in $pids; do
      rss=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')
      [ -n "$rss" ] && { total_kb=$((total_kb + rss)); matched=true; }
    done
  fi

  if [ "$matched" = true ]; then
    echo $((total_kb / 1024))
  else
    echo "-1"
  fi
}

worktrees=$(git worktree list --porcelain 2>/dev/null \
  | grep "^worktree " | sed 's/^worktree //' | grep -v "^${MAIN_ROOT}$" || true)

if [ -z "$worktrees" ]; then
  echo "No worker worktrees found (run start-parallel-agents.sh first)."
  exit 0
fi

restart_list=""
json_entries=""

if [ "$JSON" != true ]; then
  printf '%-22s %-20s %6s %6s %9s  %s\n' "WORKTREE" "BRANCH" "AGE(m)" "DIRTY" "RSS(MB)" "VERDICT"
  printf '%-22s %-20s %6s %6s %9s  %s\n' "--------" "------" "------" "-----" "-------" "-------"
fi

while IFS= read -r wt_dir; do
  [ -z "$wt_dir" ] && continue
  name=$(basename "$wt_dir")
  branch=$(cd "$wt_dir" && git branch --show-current 2>/dev/null || echo "?")
  last_epoch=$(cd "$wt_dir" && git log -1 --format=%ct 2>/dev/null || echo "$now_epoch")
  age_min=$(( (now_epoch - last_epoch) / 60 ))
  dirty=$(cd "$wt_dir" && git status --short 2>/dev/null | wc -l | tr -d ' ')
  rss_mb=$(worker_rss_mb "$wt_dir")

  # Stalled: no commit progress for >= STALL_MIN minutes.
  stalled=false
  [ "$age_min" -ge "$STALL_MIN" ] && stalled=true

  # High memory: RSS at/above threshold (only when memory is known).
  highmem=false
  [ "$rss_mb" -ge "$MEM_THRESHOLD_MB" ] 2>/dev/null && [ "$rss_mb" -ge 0 ] && highmem=true

  if [ "$rss_mb" -lt 0 ] 2>/dev/null; then
    rss_disp="?"
  else
    rss_disp="$rss_mb"
  fi

  if [ "$stalled" = true ] && [ "$highmem" = true ]; then
    verdict="UNHEALTHY"
    restart_list="${restart_list}${wt_dir}\n"
  elif [ "$stalled" = true ]; then
    verdict="STALLED"
  elif [ "$highmem" = true ]; then
    verdict="HIGHMEM"
  else
    verdict="HEALTHY"
  fi

  if [ "$JSON" = true ]; then
    json_entries="${json_entries}{\"worktree\":\"$wt_dir\",\"name\":\"$name\",\"branch\":\"$branch\",\"age_min\":$age_min,\"dirty\":$dirty,\"rss_mb\":$rss_mb,\"verdict\":\"$verdict\"},"
  else
    printf '%-22s %-20s %6s %6s %9s  %s\n' "$name" "$branch" "$age_min" "$dirty" "$rss_disp" "$verdict"
  fi
done <<EOF
$worktrees
EOF

if [ "$JSON" = true ]; then
  printf '{"mem_threshold_mb":%s,"stall_min":%s,"workers":[%s]}\n' \
    "$MEM_THRESHOLD_MB" "$STALL_MIN" "${json_entries%,}"
  exit 0
fi

echo ""
echo "Thresholds: stall >= ${STALL_MIN} min AND RSS >= ${MEM_THRESHOLD_MB} MB  (RSS '?' = unknown, never auto-restarted)"

if [ -n "$restart_list" ]; then
  echo ""
  echo "⚠️  UNHEALTHY workers (stalled AND high memory) — restart recommended:"
  printf "%b" "$restart_list" | while IFS= read -r wt; do
    [ -z "$wt" ] && continue
    echo "   RESTART $wt"
    echo "      → restart-worker --worktree '$wt'"
  done
fi
