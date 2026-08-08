# Autocoder Model Configuration

Autocoder agents inherit credentials from the running agentic session — no separate
API keys are needed. The tier names below are shorthand the platform resolves internally.

## Default model tiers

| Tier | Claude Code | Gemini/Antigravity | Used for |
|------|------------|-------------------|---------|
| **Deep** (`$MANAGER_MODEL`) | `opus` | `pro` | Complex issues (P0/P1), root cause investigation, improvement proposals |
| **Balanced** (`$WORKER_MODEL`) | `sonnet` | `flash` | Standard fixes (P2/P3), regression analysis, plan execution |
| **Fast** (`$FAST_MODEL`) | `haiku` | `flash` | Labeling, status comments, commit messages, mechanical tasks |

## Overriding defaults

Via env vars (highest precedence):

```bash
export WORKER_MODEL="sonnet"   # balanced tier used by workers
export MANAGER_MODEL="opus"    # deep tier used by the coordinator
export FAST_MODEL="haiku"      # fast tier for mechanical ops
```

Via `.autocoder.json` (persisted, lower precedence than env):

```json
{
  "workerModel": "sonnet",
  "managerModel": "opus",
  "fastModel": "haiku"
}
```

Precedence: env vars → `.autocoder.json` → built-in defaults above.

## Auto-escalation rule

Workers start at Balanced and escalate to Deep when:
- Fix attempt fails after 2 tries with the same approach
- Root cause spans 5+ files requiring coordinated changes
- Issue is explicitly labelled P0 or P1

## Extending to other plugins

This tier system is defined for `autocoder`. Other plugins (modernize, improve)
will adopt the same env vars and `.autocoder.json` keys in a future update.
