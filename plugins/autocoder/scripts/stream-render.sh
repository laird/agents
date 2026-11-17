#!/bin/bash
# stream-render.sh — turn `claude --output-format stream-json` into one readable
# line per event, for a worker pane a human can actually watch.
#
# Headless Claude (`-p`) is what lets the worker loop drive gate and fix as
# separate processes, but plain `-p` prints only a final blob: a worker that is
# thinking, looping, or wedged all look identical from the outside. That opacity
# is exactly how three workers sat blocked for four hours without anyone
# noticing. stream-json restores visibility; this filter makes it legible —
# a trivial two-tool task emits ~130 `thinking_tokens` heartbeat events, so the
# raw stream is unwatchable without one.
#
# Usage:  claude -p --output-format stream-json --verbose ... | stream-render.sh
#
# Reads JSONL on stdin, writes plain text on stdout. Lines that are not JSON
# (a crash message, a wrapper warning) pass through verbatim rather than
# breaking the pipe.
#
# STATUS LINE (#132): headless `-p` has no TUI, so the statusline.sh hook never
# runs and a worker pane shows no `ctx NN%` for monitor-workers to read. This
# renders the same line from the stream instead, whenever the context percentage
# moves by a whole point (a fix session emits ~300 assistant events):
#   ── ctx 26% of 1M | Sonnet 5.5 | wt agents-wt-2 | branch feature/issue-132
# Context used = input + cache_creation + cache_read tokens of the latest request.
# The stream does not carry the window size: AUTOCODER_CTX_WINDOW sets it,
# otherwise 1M for a `[1m]` model id and 200k for anything else.

set -uo pipefail

if ! command -v jq >/dev/null 2>&1; then
  # No jq: pass the raw stream through rather than swallowing it. Ugly beats blind.
  exec cat
fi

CTX_WINDOW="${AUTOCODER_CTX_WINDOW:-0}"
[[ "$CTX_WINDOW" =~ ^[0-9]+$ ]] || CTX_WINDOW=0

# status_line <pct> <window> <model-id> <cwd> — the statusline.sh segments a stream
# can supply; worktree and branch are read live, so they follow the worker.
status_line() {
  local pct="$1" win="$2" model="$3" cwd="$4" parts=() name fam ver wt branch gitdir common
  if [ "$win" -ge 1000000 ] 2>/dev/null; then parts+=("ctx ${pct}% of 1M"); else parts+=("ctx ${pct}%"); fi
  name="${model#claude-}"; name="${name%%\[*}"; name=$(printf '%s' "$name" | sed -E 's/-[0-9]{8}$//')
  if [[ "$name" =~ ^([a-z]+)-([0-9]+)(-([0-9]+))?$ ]]; then
    fam="${BASH_REMATCH[1]}"; ver="${BASH_REMATCH[2]}${BASH_REMATCH[4]:+.${BASH_REMATCH[4]}}"
    parts+=("${fam^} ${ver}")
  elif [ -n "$name" ]; then
    parts+=("$name")
  fi
  if [ -n "$cwd" ] && [ -d "$cwd" ]; then
    gitdir=$(git -C "$cwd" --no-optional-locks rev-parse --git-dir 2>/dev/null)
    common=$(git -C "$cwd" --no-optional-locks rev-parse --git-common-dir 2>/dev/null)
    if [ -n "$gitdir" ] && [ -n "$common" ] && [ "$gitdir" != "$common" ]; then
      wt=$(basename "$(git -C "$cwd" --no-optional-locks rev-parse --show-toplevel 2>/dev/null)")
      [ -n "$wt" ] && parts+=("wt $wt")
    fi
    branch=$(git -C "$cwd" --no-optional-locks branch --show-current 2>/dev/null)
    [ -n "$branch" ] && parts+=("branch $branch")
  fi
  local out; printf -v out '%s | ' "${parts[@]}"
  printf '── %s\n' "${out% | }"
}

jq -nRr --unbuffered --argjson win "$CTX_WINDOW" '
  def clean: gsub("[\\r\\n\\t]+"; " ") | gsub("  +"; " ") | sub("^ +"; "");
  def trunc($n): if (. | length) > $n then (.[0:$n] + "…") else . end;
  def stamp: (now | strflocaltime("%H:%M:%S"));
  def money($c): if $c == null then "" else " · $" + (($c * 10000 | round) / 10000 | tostring) end;

  # A tool call is only worth a line if you can see what it acted on.
  def tool_arg:
    (.input.command // .input.file_path // .input.pattern // .input.description
      // .input.skill // .input.url // .input.prompt // .input.subject // "")
    | if type == "string" then . else tostring end
    | clean | trunc(110);

  def window($m):
    if $win > 0 then $win
    elif (($m // "") | test("\\[1m\\]")) then 1000000
    else 200000 end;

  def render:
    if .type == "__raw" then
      (if (.line | length) == 0 then empty else .line end)

    elif .type == "system" and .subtype == "init" then
      "\(stamp) ▸ session \(.session_id[0:8]) · \(.model // "?") · \(.cwd)"

    elif .type == "system" and .subtype == "compact_boundary" then
      "\(stamp) ⚠ context compacted"

    elif .type == "assistant" then
      ( .message.content[]?
        | if .type == "text" and ((.text | clean | length) > 0) then
            "\(stamp) › \(.text | clean | trunc(200))"
          elif .type == "tool_use" then
            (tool_arg as $a
             | "\(stamp) ● \(.name)" + (if $a == "" then "" else ": \($a)" end))
          else empty end )

    elif .type == "user" then
      ( .message.content[]?
        | select(.type == "tool_result" and .is_error == true)
        | (.content | if type == "string" then . else tostring end) as $e
        | "\(stamp) ✗ \($e | clean | trunc(160))" )

    elif .type == "result" then
      "\(stamp) ⏹ \(.subtype // "done") · \(.num_turns // 0) turns\(money(.total_cost_usd)) · \(((.duration_api_ms // 0) / 1000) | round)s"

    else empty end;

  # One pass with running state: the model and cwd from init, the context % from
  # each assistant request. A STATUS record (\u001f-prefixed) goes out only when
  # the whole-point percentage changes; the shell below renders it.
  foreach (inputs | (fromjson? // {type: "__raw", line: .})) as $e
    ({pct: null, model: null, cwd: null, out: []};
     .out = [$e | render]
     | if $e.type == "system" and $e.subtype == "init" then
         .model = ($e.model // .model) | .cwd = ($e.cwd // .cwd)
       else . end
     | if $e.type == "assistant" and ($e.message.usage? | type) == "object" then
         ($e.message.usage
           | (.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0)) as $used
         | .model = ($e.message.model // .model)
         | window(.model) as $w
         | ((100 * $used / $w) | floor) as $p
         | if $used > 0 and $p != .pct then
             .pct = $p
             | .out += ["\u001fSTATUS\t\($p)\t\($w)\t\(.model // "")\t\(.cwd // "")"]
           else . end
       else . end;
     .out[])
' | while IFS= read -r line; do
  if [[ "$line" == $'\x1f'STATUS$'\t'* ]]; then
    IFS=$'\t' read -r _ pct win model cwd <<< "$line"
    status_line "$pct" "$win" "$model" "$cwd"
  else
    printf '%s\n' "$line"
  fi
done
