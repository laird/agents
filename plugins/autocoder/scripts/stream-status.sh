#!/usr/bin/env bash
# stream-status.sh — render a worker-pane status line from the stream-json
# events a headless worker is already emitting.
#
#   ── ctx 26% of 1M | mem 56 | Sonnet 5 | wt athena2-wt-2 | branch feature/issue-1688
#
# WHY THIS EXISTS:
#   statusline.sh is a Claude Code *status line hook*: the TUI feeds it session
#   JSON on stdin and paints its output at the bottom of the screen. Workers run
#   headless (`claude -p`, see claude-worker-loop.sh), which has no TUI, so the
#   hook is never invoked and the pane renders no status line at all — no matter
#   what settings.json says. install-statusline.sh cannot fix that; there is
#   nothing to install into.
#
#   That left monitor-workers Step 4c inoperative for every worker in the fleet:
#   `capture-pane | grep -oE 'ctx [0-9]+%'` returned nothing, so the proactive
#   >=95% handoff never fired and context exhaustion was only ever caught after
#   the fact by the lossy restart path. This renders the same line from the
#   stream instead, so the manager's existing grep works unchanged.
#
# CONTRACT WITH stream-render.sh:
#   stream-render.sh emits control records ONLY when AUTOCODER_STATUS=1, as
#       \x01RESET<TAB>cwd<TAB>model_id<TAB>memory_dir   (session/init)
#       \x01CTX<TAB>prompt_tokens<TAB>model_id          (each assistant turn)
#   Everything else passes through byte-for-byte. A control record that arrives
#   without this filter in the pipe would be pane garbage, which is why emission
#   is opt-in rather than always-on; and this filter drops any \x01 record it
#   does not recognise, so a version skew degrades to a missing status line
#   rather than to noise.
#
# Usage:  ... | stream-render.sh | stream-status.sh
#
# Environment:
#   AUTOCODER_CTX_WINDOW   Override the assumed context window, in tokens.
#   AUTOCODER_STATUS_EVERY Seconds between forced repaints (default 120).

set -uo pipefail

FORCE_EVERY="${AUTOCODER_STATUS_EVERY:-120}"

cwd=""
memdir=""
model=""
window=""
last_pct=-1
last_paint=0
# Refreshed on a cadence rather than per event: branch is the segment that
# actually moves mid-session (the worker cuts feature/issue-N), but shelling out
# to git on every one of ~300 assistant turns is pure overhead.
enrich_at=0
seg_mem=""
seg_wt=""
seg_branch=""

# Tokens the model can hold. The stream never states this, so it is inferred and
# then ratcheted: an underestimate would render as ">100% used", which reads as
# alarming nonsense, so an observation that exceeds the assumption promotes the
# assumption instead of printing an impossible number.
window_for() {
  case "$1" in
    *opus-5*|*sonnet-5*) echo 1000000 ;;
    *haiku*)             echo 200000 ;;
    *)                   echo 200000 ;;
  esac
}

display_model() {
  case "$1" in
    *opus-5*)   echo "Opus 5" ;;
    *sonnet-5*) echo "Sonnet 5" ;;
    *fable-5*)  echo "Fable 5" ;;
    *haiku-4-5*|*haiku-4.5*) echo "Haiku 4.5" ;;
    "")         echo "" ;;
    *)          echo "$1" ;;
  esac
}

# One file per memory; MEMORY.md is the index, not a memory. Mirrors statusline.sh.
count_memories() {
  [ -n "$memdir" ] && [ -d "$memdir" ] || return 0
  find "$memdir" -maxdepth 1 -type f -name '*.md' ! -name 'MEMORY.md' 2>/dev/null | wc -l
}

refresh_enrichment() {
  local now="$1"
  [ "$now" -lt "$enrich_at" ] && return 0
  enrich_at=$((now + 20))

  local n; n=$(count_memories)
  seg_mem=""; [ -n "$n" ] && seg_mem="mem $n"

  seg_wt=""; seg_branch=""
  [ -n "$cwd" ] || return 0
  local gitdir common
  gitdir=$(git -C "$cwd" --no-optional-locks rev-parse --git-dir 2>/dev/null)
  common=$(git -C "$cwd" --no-optional-locks rev-parse --git-common-dir 2>/dev/null)
  # A linked worktree has a git-dir distinct from the common dir. Naming the
  # plain main checkout "wt <repo>" would be a lie the manager acts on.
  if [ -n "$gitdir" ] && [ -n "$common" ] && [ "$gitdir" != "$common" ]; then
    local top; top=$(git -C "$cwd" --no-optional-locks rev-parse --show-toplevel 2>/dev/null)
    [ -n "$top" ] && seg_wt="wt $(basename "$top")"
  fi
  local br; br=$(git -C "$cwd" --no-optional-locks branch --show-current 2>/dev/null)
  [ -n "$br" ] && seg_branch="branch $br"
}

paint() {
  local used="$1" now="$2"
  [ "$window" -gt 0 ] 2>/dev/null || return 0

  # Ratchet before computing, so the promotion shows up in this very line.
  if [ "$used" -gt "$window" ] 2>/dev/null; then window=1000000; fi

  local pct=$(( (used * 100 + window / 2) / window ))
  [ "$pct" -gt 100 ] && pct=100

  # Repaint on movement, or on a timer so a long quiet stretch does not leave a
  # stale number as the pane's most recent status.
  if [ "$pct" -eq "$last_pct" ] && [ $((now - last_paint)) -lt "$FORCE_EVERY" ]; then
    return 0
  fi
  last_pct="$pct"; last_paint="$now"

  refresh_enrichment "$now"

  local ctx="ctx ${pct}%"
  [ "$window" -ge 1000000 ] && ctx="$ctx of 1M"

  local out="$ctx"
  local dm; dm=$(display_model "$model")
  # Bash joins "${a[*]}" on IFS's FIRST character only, so a multi-char
  # separator cannot come from IFS -- append explicitly.
  for seg in "$seg_mem" "$dm" "$seg_wt" "$seg_branch"; do
    [ -n "$seg" ] && out="$out | $seg"
  done

  printf '── %s\n' "$out"
}

while IFS= read -r line; do
  case "$line" in
    $'\001'*)
      IFS=$'\t' read -r kind a b c <<<"${line#$'\001'}"
      case "$kind" in
        RESET)
          # New headless session = fresh context window. Carrying the previous
          # session's percentage across would report a worker as nearly full at
          # the exact moment it just got a clean slate.
          cwd="$a"; model="$b"
          # memory_paths.auto, straight from the init event. It is keyed on the
          # session's LAUNCH dir, not the worktree cwd, so deriving it from cwd
          # yields a directory that does not exist and a silently absent segment.
          memdir="$c"
          window=$(window_for "$model")
          last_pct=-1; last_paint=0; enrich_at=0
          ;;
        CTX)
          [ -n "$model" ] || { model="$b"; window=$(window_for "$model"); }
          case "$a" in (*[!0-9]*|"") ;; (*) paint "$a" "$(printf '%(%s)T' -1)" ;; esac
          ;;
      esac
      ;;
    *)
      printf '%s\n' "$line"
      ;;
  esac
done
