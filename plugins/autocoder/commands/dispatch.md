---
model: haiku
---
<!--
Phase 3 dev-loop token-efficiency (spec §5.3, §10 Phase 3, §7.1.1 verified
2026-05-21). Haiku gate; fix work dispatched to Sonnet/Opus via Task `model=`.

`model:` frontmatter convention verified 2026-05-21 against the official
Claude Code slash-commands docs (code.claude.com/docs/en/slash-commands —
"Frontmatter reference") and the bundled plugin-dev `command-development`
skill: valid values are the short aliases `haiku`, `sonnet`, `opus`, or
`inherit`. Dated model IDs like `claude-haiku-4-5-20251001` are NOT a
documented value here. The Task-tool `model="haiku"` call inside the body
is the actually-load-bearing routing path (§7.1.1); this frontmatter is a
belt-and-braces pin for the slash-command invocation itself.

First repo command using `model:` frontmatter. Opt in via `LOOP_MODEL_SPLIT=1`.
See docs/notes/2026-05-21-frontmatter-model-convention.md.
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

Do not load `/autocoder:dev`. Stop after all triaged.

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
    Load and execute `/autocoder:dev <ISSUE>` via the Skill tool.
    Gate (Haiku) already classified phase=<fix|enhance>; do not re-triage.
    Complete the full skill chain (peters-toolkit:bugfix if installed,
    else systematic-debugging → TDD; then verification →
    finishing-a-development-branch). Run unattended: never ask a
    question or wait for approval — resolve bugfix's G1/G2/G4/G5/G8
    gates per /autocoder:dev's autonomous gate policy, escalating via
    blocking labels instead of pausing. Report branch name and commit
    SHA in your final message.
```

Subagent runs in its own conversation/model; Haiku stops after dispatch (§7.1.1).
