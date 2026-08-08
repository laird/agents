# Autocoder Model Configuration

## Default model tiers

| Tier | Claude Code | Gemini/Antigravity | Used for |
|------|------------|-------------------|---------|
| **Deep** | `claude-opus-5` | `gemini-2.5-pro` | Complex issues (P0/P1), root cause investigation, improvement proposals |
| **Balanced** | `claude-sonnet-5` | `gemini-2.0-flash` | Standard fixes (P2/P3), regression analysis, plan execution |
| **Fast** | `claude-haiku-4-5` | `gemini-2.0-flash` | Labeling, status comments, commit messages, mechanical tasks |

## Env vars (highest precedence)

```bash
export WORKER_MODEL="claude-sonnet-5"   # balanced tier used by workers
export MANAGER_MODEL="claude-opus-5"    # deep tier used by the coordinator
export FAST_MODEL="claude-haiku-4-5"    # fast tier for mechanical ops
```

## .autocoder.json (persistent, lower precedence than env)

```json
{
  "workerModel": "claude-sonnet-5",
  "managerModel": "claude-opus-5",
  "fastModel": "claude-haiku-4-5"
}
```

Precedence order: `env vars` → `.autocoder.json` → built-in defaults above.

## Auto-escalation rule

Workers start at Balanced and escalate to Deep when:
- Fix attempt fails after 2 tries with the same approach
- Root cause spans 5+ files requiring coordinated changes
- Issue is explicitly labelled P0 or P1

## Startup confirmation

When `/fix` or `/fix-loop` runs and no model config is found, the agent
presents the defaults above and asks the user to confirm or override them
before proceeding. This happens once per session; the confirmed values are
exported as env vars for the duration of the run.

## Extending to other plugins

This tier system is defined for `autocoder`. Other plugins (modernize, improve)
will adopt the same env vars and `.autocoder.json` keys in a future update.
