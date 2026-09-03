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
# With AUTOCODER_STATUS=1 it additionally emits \x01-prefixed control records
# carrying the numbers a status line needs; stream-status.sh, downstream in the
# pipe, turns those into the `ctx NN% | mem N | Model | wt X | branch Y` line
# that headless workers otherwise cannot render (see stream-status.sh for why).
# Opt-in, because an unpaired control record would be pane garbage — running
# this script standalone, as the Usage line above shows, must stay unchanged.

set -uo pipefail

if ! command -v jq >/dev/null 2>&1; then
  # No jq: pass the raw stream through rather than swallowing it. Ugly beats blind.
  exec cat
fi

# Normalised to a literal 0/1 before it reaches --argjson: a stray value there
# is a jq parse error, which would kill the renderer and blank the pane over a
# cosmetic setting.
case "${AUTOCODER_STATUS:-0}" in 1|true|yes) STATUS_ON=1 ;; *) STATUS_ON=0 ;; esac

exec jq -Rr --unbuffered --argjson status "$STATUS_ON" '
  def clean: gsub("[\\r\\n\\t]+"; " ") | gsub("  +"; " ") | sub("^ +"; "");
  def trunc($n): if (. | length) > $n then (.[0:$n] + "…") else . end;
  def stamp: (now | strflocaltime("%H:%M:%S"));
  def money($c): if $c == null then "" else " · $" + (($c * 10000 | round) / 10000 | tostring) end;
  # \x01 marks a machine-readable control record for stream-status.sh. It is a
  # C0 control character, so it can never collide with rendered event text.
  def ctl: "\u0001" + .;

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
      ( "\(stamp) ▸ session \(.session_id[0:8]) · \(.model // "?") · \(.cwd)",
        # memory_paths.auto is handed over verbatim: it is keyed on the launching
        # launch directory, which for a worker is NOT its worktree cwd, so the
        # downstream filter must not try to derive it.
        (if $status == 1 then
           ("RESET\t\(.cwd // "")\t\(.model // "")\t\(.memory_paths.auto // "")" | ctl)
         else empty end) )

    elif .type == "system" and .subtype == "compact_boundary" then
      "\(stamp) ⚠ context compacted"

    elif .type == "assistant" then
      ( ( .message.content[]?
          | if .type == "text" and ((.text | clean | length) > 0) then
              "\(stamp) › \(.text | clean | trunc(200))"
            elif .type == "tool_use" then
              (tool_arg as $a
               | "\(stamp) ● \(.name)" + (if $a == "" then "" else ": \($a)" end))
            else empty end ),
        # Context used is the size of the prompt this turn sent: fresh input plus
        # everything served from cache. output_tokens is deliberately excluded --
        # it is not in the window until the NEXT turn echoes it back as input.
        #
        # parent_tool_use_id != null means a SUBAGENT turn. Its usage measures
        # the subagent, not the worker, and subagents start near
        # empty -- letting them through made the reading alternate 13%, 2%, 13%
        # and, worse, left whichever ran last as the final value the manager
        # greps. A reassuringly low number at the moment a worker is nearly
        # full is the exact failure this status line exists to prevent.
        (if $status == 1 and (.message.usage != null)
            and (.parent_tool_use_id == null) then
           (((.message.usage.input_tokens // 0)
             + (.message.usage.cache_creation_input_tokens // 0)
             + (.message.usage.cache_read_input_tokens // 0)) as $u
            | "CTX\t\($u)\t\(.message.model // "")" | ctl)
         else empty end) )

    elif .type == "user" then
      ( .message.content[]?
        | select(.type == "tool_result" and .is_error == true)
        | (.content | if type == "string" then . else tostring end) as $e
        | "\(stamp) ✗ \($e | clean | trunc(160))" )

    elif .type == "result" then
      "\(stamp) ⏹ \(.subtype // "done") · \(.num_turns // 0) turns\(money(.total_cost_usd)) · \(((.duration_api_ms // 0) / 1000) | round)s"

    else empty end
'
