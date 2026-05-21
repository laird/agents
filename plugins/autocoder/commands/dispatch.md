---
model: claude-haiku-4-5
---
<!--
Phase 3 fix-loop token-efficiency (spec §5.3, §10 Phase 3, §7.1.1 verified
2026-05-21). Haiku gate; fix work dispatched to Sonnet/Opus via Task `model=`.
`model:` is short alias; full verified id `claude-haiku-4-5-20251001`. First
repo command using `model:` frontmatter. Opt in via `LOOP_MODEL_SPLIT=1`.
-->

# Fix-Loop Dispatch (Haiku gate, Sonnet/Opus worker)

Pre-LLM gate; triage on Haiku, fix/enhance dispatched to stronger model.

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

- **1 (idle):** emit `IDLE_NO_WORK_AVAILABLE` and stop.
- **2 (config error):** emit `GATE_DISPATCH_CONFIG_ERROR` and stop.
- **0 (work):** `PHASE=$(jq -r .phase "$WORK_JSON")` then act.

### phase = `triage`

Run on Haiku here. For each `N` in `.issues[]`: `issue_view N`, apply matrix, then:

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

Do not load `/autocoder:fix`. Stop after all triaged.

### phase = `fix` or `enhance`

Dispatch via Task tool (NOT Skill — Skill inherits Haiku):

```bash
ISSUE=$(jq -r .issue "$WORK_JSON")
LABELS=$(jq -r '.labels // [] | join(",")' "$WORK_JSON")
```

Worker model (§10 escalation matrix): `$LABELS` contains `P0` → `opus`; else `sonnet`.

```
Use the Task tool with:
  model: <opus|sonnet>
  prompt: |
    You are the autocoder fix-worker for issue #<ISSUE>.
    Load and execute `/autocoder:fix <ISSUE>` via the Skill tool.
    Gate (Haiku) already classified phase=<fix|enhance>; do not re-triage.
    Complete the full skill chain (systematic-debugging → TDD →
    verification → finishing-a-development-branch). Report branch
    name and commit SHA in your final message.
```

Subagent runs in its own conversation/model; Haiku stops after dispatch (§7.1.1).
