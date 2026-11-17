#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255: never write the real event logs
# tests/test_agent_prompt_consent.sh — a launcher must not answer an agent's
# consent or trust dialog with the first prompt's Enter (#253).
#
# Launch paths start an agent, wait a fixed time, then type the first prompt and
# Enter. If the agent is showing a folder-trust or consent dialog then, the Enter
# picks the dialog's default (claude's consent defaults to "No, exit").
# send_agent_prompt (mux-send-lib.sh) checks the pane before typing and again
# before Enter, and returns 3 without submitting when a dialog shows.
#
# Most checks run against a stub multiplexer that logs calls and plays back
# scripted screens; one runs a real tmux on a private server (-L), never the
# user's.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/plugins/autocoder/scripts/mux-send-lib.sh"
TMP=$(mktemp -d)
trap 'tmux -L "$SOCK" kill-server 2>/dev/null; rm -rf "$TMP"' EXIT
SOCK="autocoder-test-consent-$$"

ok()   { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad()  { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
check() { [ "$2" = "$3" ] && ok "$1" || bad "$1 — want '$3', got '$2'"; }

# ── stub multiplexer ──────────────────────────────────────────────────────────
# Each capture/read prints the next file in $SCREENS (screen.1, screen.2, ...),
# repeating the last; every call is appended to $CALLS.
STUB="$TMP/bin"; mkdir -p "$STUB"
for cmd in tmux cmux herdr; do
  cat > "$STUB/$cmd" <<'EOF'
#!/bin/bash
name=$(basename "$0")
printf '%s %s\n' "$name" "$*" >> "$CALLS"
case "$name $1 $2" in
  "tmux capture-pane"*|"cmux read-screen"*|"herdr pane read")
    n=$(cat "$SCREENS/n" 2>/dev/null || echo 0); n=$((n + 1))
    if [ -f "$SCREENS/screen.$n" ]; then echo "$n" > "$SCREENS/n"; else n=$((n - 1)); fi
    [ -f "$SCREENS/screen.$n" ] && cat "$SCREENS/screen.$n"
    ;;
  "herdr agent prompt") [ -n "$HERDR_PROMPT_FAILS" ] && exit 1 ;;
esac
exit 0
EOF
  chmod +x "$STUB/$cmd"
done

# run_stub <mux> <screen...> — fresh call log and screen script, then one
# send_agent_prompt; sets RC, and SENT_TEXT / SENT_ENTER from the call log.
run_stub() {
  local mux="$1"; shift
  export CALLS="$TMP/calls" SCREENS="$TMP/screens"
  rm -rf "$SCREENS" "$CALLS"; mkdir -p "$SCREENS"; : > "$CALLS"
  local i=0 s
  for s in "$@"; do i=$((i + 1)); printf '%s\n' "$s" > "$SCREENS/screen.$i"; done
  RC=$( (PATH="$STUB:$PATH" AUTOCODER_MUX_SUBMIT_DELAY=0
         source "$LIB"
         send_agent_prompt "$mux" T1 "/fix-loop" 2>"$TMP/err"; echo $?) )
  SENT_TEXT=$(grep -cE '^tmux send-keys -t T1 /fix-loop$|^cmux send --workspace T1 /fix-loop$|^herdr (agent prompt|pane send-text) T1 /fix-loop$' "$CALLS")
  SENT_ENTER=$(grep -cE '^tmux send-keys -t T1 Enter$|^cmux send-key --workspace T1 enter$|^herdr agent prompt T1|^herdr pane send-keys T1 enter$' "$CALLS")
}

READY='> '
for mux in tmux cmux herdr; do
  run_stub "$mux" "$READY"
  check "$mux: no dialog → sent (rc)" "$RC" 0
  check "$mux: no dialog → text typed" "$SENT_TEXT" 1
  check "$mux: no dialog → submitted" "$SENT_ENTER" 1

  run_stub "$mux" "Do you trust this folder?"
  check "$mux: dialog before typing → rc 3" "$RC" 3
  check "$mux: dialog before typing → nothing typed" "$SENT_TEXT" 0
  check "$mux: dialog before typing → no Enter" "$SENT_ENTER" 0
  grep -q "consent or trust dialog" "$TMP/err" \
    && ok "$mux: dialog → says why on stderr" || bad "$mux: dialog → no stderr notice"
done

# A dialog that draws while the text is being typed still gets no Enter.
for mux in tmux cmux; do
  run_stub "$mux" "$READY" "│ Bypass Permissions mode   1. No, exit   2. Yes, I accept"
  check "$mux: dialog after typing → rc 3" "$RC" 3
  check "$mux: dialog after typing → no Enter" "$SENT_ENTER" 0
done

# claude --dangerously-skip-permissions shows "bypass permissions on" in its
# footer the whole time it runs; that is a ready agent, not a dialog.
FOOTER="> 
  ⏵⏵ bypass permissions on (shift+tab to cycle)"
for mux in tmux cmux herdr; do
  run_stub "$mux" "$FOOTER"
  check "$mux: claude's bypass footer is not a dialog → sent" "$RC" 0
  check "$mux: claude's bypass footer → submitted" "$SENT_ENTER" 1
done

# herdr: a dialog drawn while the agent surface was tried stops the fallback.
HERDR_PROMPT_FAILS=1 run_stub herdr "$READY" "Do you trust this folder?"
check "herdr: dialog before typed fallback → rc 3" "$RC" 3
grep -q '^herdr pane send-text' "$CALLS" && bad "herdr: fallback typed into a dialog" \
  || ok "herdr: fallback held back from a dialog"

# herdr: the agent surface failing falls back to typing into the pane.
HERDR_PROMPT_FAILS=1 run_stub herdr "$READY"
check "herdr: agent prompt fails → typed fallback (rc)" "$RC" 0
grep -q '^herdr pane send-text T1 /fix-loop$' "$CALLS" \
  && ok "herdr: agent prompt fails → typed into the pane" || bad "herdr: no typed fallback"

# An unreadable pane is not a dialog: the send goes ahead and reports itself.
run_stub tmux   # no screens at all: capture prints nothing
check "tmux: blank capture → sent" "$RC" 0

# ── only the bottom of the pane is a dialog (#260) ───────────────────────────
# An open dialog is the last thing drawn on the pane. Dialog words higher up (a
# shell banner, scrollback, a transcript quoting "No, exit") are not a dialog.
# The fixtures end in blank rows, as a tmux capture of a taller pane does.
PAD=$'\n\n\n\n\n\n'
QUOTED="\$ cat notes.md
claude asks: Do you trust the files in this folder?
  ❯ 1. Yes, proceed
    2. No, exit
\$ claude
╭───────────────────────────────────────────╮
│ ✻ Welcome to Claude Code!                 │
│   cwd: /home/u/src/project                │
╰───────────────────────────────────────────╯
 Tips for getting started:
 1. Run /init to create a CLAUDE.md file
 2. Use Claude to help with file analysis
╭───────────────────────────────────────────╮
│ >                                         │
╰───────────────────────────────────────────╯
  ? for shortcuts${PAD}"
for mux in tmux cmux herdr; do
  run_stub "$mux" "$QUOTED"
  check "$mux: dialog text above a ready agent → sent" "$RC" 0
  check "$mux: dialog text above a ready agent → submitted" "$SENT_ENTER" 1
done

# Whole dialogs as each agent draws them, wrapped at a narrow width and padded:
# the lines that identify them must fall inside the checked tail.
CLAUDE_TRUST=" Do you trust the files in this folder?

 /home/u/src/a-project-with-a-rather-long-directory-name/and/a/subdirectory

 Claude Code may read, write, or execute files contained in
 this directory. This can pose security risks, so only use
 files from trusted sources.

 Learn more

 ❯ 1. Yes, proceed
   2. No, exit

 Enter to confirm · Esc to exit${PAD}"
CLAUDE_BYPASS="╭──────────────────────────────────────────────────╮
│                                                  │
│ WARNING: Claude Code running in Bypass           │
│ Permissions mode                                 │
│                                                  │
│ In Bypass Permissions mode, Claude Code will not │
│ ask for your approval before running potentially │
│ dangerous commands.                              │
│ This mode should only be used in a sandboxed     │
│ container/VM that has restricted internet access │
│ and can easily be restored if damaged.           │
│                                                  │
│ By proceeding, you accept all responsibility for │
│ actions taken while running in Bypass            │
│ Permissions mode.                                │
│                                                  │
│ https://docs.anthropic.com/s/claude-code-security│
│                                                  │
│ ❯ 1. No, exit                                    │
│   2. Yes, I accept                               │
│                                                  │
╰──────────────────────────────────────────────────╯
   Enter to confirm · Esc to exit${PAD}"
CLAUDE_TRUST_NEW=" Accessing workspace:

 /home/u/src/project

 Quick safety check: Is this a project you created or one you
 trust? (Like your own code, a well-known open source project,
 or work from your team). If not, take a moment to review
 what's in this folder first.

 Claude Code'll be able to read, edit, and execute files here.

 Security guide

 ❯ 1. Yes, I trust this folder
   2. No, exit

 Enter to confirm · Esc to cancel${PAD}"
GEMINI_TRUST="╭──────────────────────────────────────────────────╮
│ Do you trust this folder?                        │
│                                                  │
│ Trusting a folder allows Gemini to execute       │
│ commands it suggests. This is a security feature │
│ to prevent accidental execution in untrusted     │
│ directories.                                     │
│                                                  │
│ ● 1. Trust folder (project)                      │
│   2. Trust parent folder (src)                   │
│   3. Don't trust (esc)                           │
╰──────────────────────────────────────────────────╯${PAD}"
CODEX_TRUST="> You are running Codex in /home/u/src/project

  Since this folder is version controlled, you may wish to allow
  Codex to work in this folder without asking for approval.

› 1. Yes, allow Codex to work in this folder without asking for
     approval
  2. No, ask me to approve edits and commands

  Press enter to continue${PAD}"
# Older codex: only the question matches ("No, quit" does not), drawn above its
# wrapped warning in a narrow pane.
CODEX_TRUST_OLD="> You are running Codex in
  /home/u/src/project

  Since this folder is not version
  controlled, we recommend requiring
  approval of all edits and commands.

  Do you trust the contents of this
  directory? Working with untrusted
  contents comes with higher risk of
  prompt injection.

› 1. Yes, continue
  2. No, quit

  Press enter to continue${PAD}"
for d in CLAUDE_TRUST CLAUDE_BYPASS CLAUDE_TRUST_NEW GEMINI_TRUST CODEX_TRUST CODEX_TRUST_OLD; do
  run_stub tmux "${!d}"
  check "tmux: whole $d dialog → rc 3" "$RC" 3
  check "tmux: whole $d dialog → nothing typed" "$SENT_TEXT" 0
done
# The same dialog under quoted dialog text above it is still a dialog.
run_stub tmux "$QUOTED
$CLAUDE_BYPASS"
check "tmux: dialog below quoted dialog text → rc 3" "$RC" 3

# AUTOCODER_CONSENT_TAIL_LINES widens or narrows the checked tail.
check "AUTOCODER_CONSENT_TAIL_LINES=40 also sees the quoted text" \
  "$( (export AUTOCODER_CONSENT_TAIL_LINES=40; run_stub tmux "$QUOTED"; echo "$RC") )" 3

# ── the pattern ───────────────────────────────────────────────────────────────
match() { (source "$LIB"; printf '%s\n' "$1" | grep -Eq "$AUTOCODER_CONSENT_PATTERN") && echo yes || echo no; }
for dialog in \
  "Do you trust the files in this folder?" \
  "Is this a project you created or one you trust?" \
  "❯ 1. Yes, I trust this folder" \
  "Do you trust this folder?" \
  "● 1. Trust folder (agents)" \
  "Do you trust the contents of this directory?" \
  "Yes, allow Codex to work in this folder without asking for approval" \
  "1. No, exit" \
  "WARNING: Claude Code running in Bypass Permissions mode"; do
  check "pattern matches: $dialog" "$(match "$dialog")" yes
done
for screen in \
  "> /autocoder:fix-loop" \
  "╭─ Welcome to Claude Code ─╮" \
  "Type your message or @path/to/file" \
  "gemini-2.5-pro (99% context left)" \
  "  ⏵⏵ bypass permissions on (shift+tab to cycle)"; do
  check "pattern ignores: $screen" "$(match "$screen")" no
done
# The prompt is on screen for the check before Enter, so no prompt a launcher
# sends may itself match the pattern: it would withhold its own Enter.
for agent in claude gemini codex pi droid; do
  for mux in tmux herdr; do
    out=$( (source "$LIB"; source "$ROOT/plugins/autocoder/scripts/worker-launch-lib.sh"
            resolve_worker_launch "$agent" "$ROOT" "$mux" >/dev/null 2>&1 \
              && [ -n "$WORKER_CMD" ] || { echo "no launch prompts resolved"; exit 0; }
            for c in "$WORKER_CMD" "$MANAGER_CMD"; do
              printf '%s\n' "$c" | grep -Eq "$AUTOCODER_CONSENT_PATTERN" && echo "$c"
            done) )
    check "$agent/$mux: no launch prompt matches the pattern" "$out" ""
  done
done
check "AUTOCODER_CONSENT_PATTERN overrides the default" \
  "$( (AUTOCODER_CONSENT_PATTERN='Custom gate'; source "$LIB"; printf 'Custom gate here\n' | grep -Eq "$AUTOCODER_CONSENT_PATTERN") && echo yes || echo no)" yes

# ── real tmux on a private server ─────────────────────────────────────────────
if command -v tmux >/dev/null 2>&1; then
  mkdir -p "$TMP/realbin"
  printf '#!/bin/bash\nexec %q -L %q "$@"\n' "$(command -v tmux)" "$SOCK" > "$TMP/realbin/tmux"
  chmod +x "$TMP/realbin/tmux"
  # A fake agent: shows a dialog, records whatever line it is given.
  cat > "$TMP/agent.sh" <<'EOF'
#!/bin/bash
[ "$1" = dialog ] && echo "Do you trust this folder?" || echo "ready"
IFS= read -r line; printf '%s\n' "$line" > "$2"
sleep 30
EOF
  chmod +x "$TMP/agent.sh"
  for mode in dialog ready; do
    PATH="$TMP/realbin:$PATH" tmux new-session -d -s "s-$mode" -x 120 -y 20 \
      "bash $TMP/agent.sh $mode $TMP/got.$mode"
  done
  sleep 1
  for mode in dialog ready; do
    target=$(PATH="$TMP/realbin:$PATH" tmux display-message -p -t "s-$mode" '#{pane_id}')
    rc=$( (PATH="$TMP/realbin:$PATH"; source "$LIB"; send_agent_prompt tmux "$target" "/fix-loop" 2>/dev/null; echo $?) )
    sleep 1
    if [ "$mode" = dialog ]; then
      check "real tmux: dialog → rc 3" "$rc" 3
      [ -f "$TMP/got.dialog" ] && bad "real tmux: dialog answered with '$(cat "$TMP/got.dialog")'" \
        || ok "real tmux: dialog left unanswered"
    else
      check "real tmux: ready → rc 0" "$rc" 0
      check "real tmux: ready → agent got the prompt" "$(cat "$TMP/got.ready" 2>/dev/null)" "/fix-loop"
    fi
  done
else
  echo "SKIP: tmux not installed; real-pane checks not run"
fi

# ── every launch path that types a first prompt goes through the guard ───────
S="$ROOT/plugins/autocoder/scripts"
check "start-parallel-agents.sh: post-launch prompts use send_agent_prompt" \
  "$(grep -cE '^ *send_agent_prompt ' "$S/start-parallel-agents.sh")" 6
for f in add-worker.sh restart-worker.sh; do
  check "$f: agent-input prompts use send_agent_prompt" "$(grep -cE '^ *send_agent_prompt ' "$S/$f")" 3
done
grep -q 'send_agent_prompt "\$1" "\$2" "\$WORKER_CMD"' "$S/start-workers.sh" \
  && ok "start-workers.sh: agent-input prompts use send_agent_prompt" \
  || bad "start-workers.sh: agent-input prompts bypass send_agent_prompt"
for f in start-parallel-agents.sh add-worker.sh restart-worker.sh start-workers.sh; do
  check "$f: no unguarded prompt_herdr_agent" "$(grep -c 'prompt_herdr_agent' "$S/$f")" 0
done
# Antigravity's launcher is hand-maintained (not generated), so it is checked
# on its own; its mux-send-lib.sh is the generated mirror.
A="$ROOT/.agent/scripts"
check ".agent start-parallel-agents.sh: post-launch prompts use send_agent_prompt" \
  "$(grep -cE '^ *send_agent_prompt ' "$A/start-parallel-agents.sh")" 6
check ".agent start-parallel-agents.sh: no unguarded prompt_herdr_agent" \
  "$(grep -c 'prompt_herdr_agent' "$A/start-parallel-agents.sh")" 0
grep -q '^send_agent_prompt()' "$A/mux-send-lib.sh" \
  && ok ".agent mux-send-lib.sh defines send_agent_prompt" || bad ".agent mux-send-lib.sh lacks send_agent_prompt"

TOTAL=$((PASS + FAIL))
echo "$PASS passed / $FAIL failed / $TOTAL total"
[ "$FAIL" -eq 0 ]
