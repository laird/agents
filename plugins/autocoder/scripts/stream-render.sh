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

set -uo pipefail

if ! command -v jq >/dev/null 2>&1; then
  # No jq: pass the raw stream through rather than swallowing it. Ugly beats blind.
  exec cat
fi

exec jq -Rr --unbuffered '
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

  (fromjson? // {type: "__raw", line: .})

  | if .type == "__raw" then
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

    else empty end
'
