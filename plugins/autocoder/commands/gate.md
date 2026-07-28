<!--
Slim dev-loop gate. Per spec §5.3 / §7.1.1, no `model:` frontmatter:
inherits the model from whatever invokes it (dev-loop's loop model).
A Haiku-pinned variant (`/autocoder:dispatch`) is Phase 3, not here.
-->

# Fix-Loop Gate

Pre-LLM gate that decides whether the tick has work. Idle: cheap exit. Work: dispatch.

> **MANDATORY — no inter-session messaging:** Do NOT use `SendMessage` (or any tool that contacts another session) at any point in this command — not at startup, not when idle, not after completing work. Silent execution is the correct behavior. The ONLY exception is a genuine blocker the manager must resolve before you can continue.

## Instructions

```bash
SCRIPT_DIR=$(
  if [ -d "$(pwd)/.agent/scripts" ]; then echo "$(pwd)/.agent/scripts"
  elif [ -d "$(pwd)/plugins/autocoder/scripts" ]; then echo "$(pwd)/plugins/autocoder/scripts"
  elif [ -d "$(pwd)/.claude-plugin/plugins/autocoder/scripts" ]; then echo "$(pwd)/.claude-plugin/plugins/autocoder/scripts"
  else find "$HOME/.claude/plugins/cache" -type d -name "scripts" -path "*/autocoder/*" 2>/dev/null | sort -V | tail -1
  fi
)
source "${SCRIPT_DIR}/issue-fns.sh"
WORK_JSON="${AUTOCODER_WORK_JSON:-/tmp/autocoder-work.json}"
bash "$SCRIPT_DIR/fix-loop-gate.sh"; GATE_RC=$?
```

Branch on `$GATE_RC`:

- **1 (idle):** emit exactly `IDLE_NO_WORK_AVAILABLE` and stop. No further tool calls. Do NOT use `SendMessage` or any other tool to notify another session of your idle status — silent stop is correct.
- **2 (config error):** emit `GATE_CONFIG_ERROR` and stop.
- **0 (work):** `PHASE=$(jq -r .phase "$WORK_JSON")` then act:

### phase = `triage`

For each `N` in `.issues[]`: read body via `issue_view N`, apply matrix, then:

```bash
issue_update N --add-label "<P0|P1|P2|P3>"
issue_comment N "Triage: <priority> — <one-line rationale>"
```

| Indicator | P0 | P1 | P2 | P3 |
|---|---|---|---|---|
| Impact | Down | Major | Partial | Minimal |
| Scope | All | Many | Some | Few |
| Workaround | None | Hard | Yes | Easy |
| Data risk | Loss | Possible | Unlikely | None |
| Security | Exploit | Vuln | Potential | None |
| Keywords | crash/down/urgent/security | broken/fails/blocking | issue/bug | minor/cosmetic |

Keep terse. Do not load `/autocoder:dev`. Stop after all triaged.

### phase = `fix` or `enhance`

Each issue must run in a **fresh Claude process** for a clean context window. The mechanism
depends on how the gate was invoked:

**Shell-loop mode** (when `AUTOCODER_NEXT_FIX_FILE` env var is set — i.e., running under
`claude-worker-loop.sh`): write the issue number to the handoff file and exit. The shell wrapper
will start a new `claude` process for fix automatically.

```bash
ISSUE_NUM=$(jq -r .issue "$WORK_JSON")
if [ -n "${AUTOCODER_NEXT_FIX_FILE:-}" ]; then
  echo "$ISSUE_NUM" > "$AUTOCODER_NEXT_FIX_FILE"
  exit 0
fi
```

**Inline mode** (fallback when gate is invoked standalone or via `/loop`): dispatch via Skill
tool in the current session. Context will accumulate across issues in this mode — prefer
shell-loop mode for multi-issue worker sessions.

```
Use the Skill tool to invoke: autocoder:dev
With args: <issue number from work JSON>
```
