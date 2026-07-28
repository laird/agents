<!--
Slim dev-loop gate. Per spec §5.3 / §7.1.1, no `model:` frontmatter:
inherits the model from whatever invokes it (dev-loop's loop model).
A Haiku-pinned variant (`/autocoder:dispatch`) is Phase 3, not here.
-->

# Fix-Loop Gate

Pre-LLM gate that decides whether the tick has work. Idle: cheap exit. Work: dispatch.

## Instructions

```bash
SCRIPT_DIR=$(
  if [ -d "$(pwd)/plugins/autocoder/scripts" ]; then echo "$(pwd)/plugins/autocoder/scripts"
  elif [ -d "$(pwd)/.claude-plugin/plugins/autocoder/scripts" ]; then echo "$(pwd)/.claude-plugin/plugins/autocoder/scripts"
  else find "$HOME/.claude/plugins/cache" -type d -name "scripts" -path "*/autocoder/*" 2>/dev/null | sort -V | tail -1
  fi
)
source "${SCRIPT_DIR}/issue-fns.sh"
WORK_JSON="${AUTOCODER_WORK_JSON:-/tmp/autocoder-work.json}"
bash "$SCRIPT_DIR/fix-loop-gate.sh"; GATE_RC=$?
```

Branch on `$GATE_RC`:

- **1 (idle):** emit exactly `IDLE_NO_WORK_AVAILABLE` and stop. No further tool calls.
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

Invoke the worker via Skill tool (same-model chain, inherits loop model):

```
Use the Skill tool to invoke: autocoder:dev
With args: <issue number from work JSON>
```

Worker takes over.
