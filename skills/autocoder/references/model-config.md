# Autocoder Model Configuration

## Default model tiers

| Tier | Claude Code | Gemini/Antigravity | Used for |
|------|------------|-------------------|---------|
| **Deep** | claude-opus-5 | gemini-2.5-pro | Complex issues (P0/P1), root cause investigation, improvement proposals |
| **Balanced** | claude-sonnet-5 | gemini-2.0-flash | Standard fixes (P2/P3), regression analysis, plan execution |
| **Fast** | claude-haiku-4-5 | gemini-2.0-flash | Labeling, status comments, commit messages, mechanical tasks |

## Overriding defaults

Set environment variables before starting workers:

```bash
# Claude Code workers
export WORKER_MODEL="claude-sonnet-5"     # balanced tier for all workers
export MANAGER_MODEL="claude-opus-5"      # deep tier for manager

# Gemini/Antigravity workers
export WORKER_MODEL="gemini-2.0-flash"
export MANAGER_MODEL="gemini-2.5-pro"
```

Or set in `.autocoder.json`:
```json
{
  "workerModel": "claude-sonnet-5",
  "managerModel": "claude-opus-5"
}
```

Or per-run via `start-parallel-agents.sh`:
```bash
WORKER_MODEL=claude-sonnet-5 bash plugins/autocoder/scripts/start-parallel-agents.sh 3
```

## Which commands use which tier

| Command | Default tier | Override env var |
|---------|-------------|-----------------|
| `/fix` — per-task model | Balanced (Sonnet/flash) | `WORKER_MODEL` |
| `/fix` — complex P0/P1 issue | Deep (Opus/pro) | n/a (auto-escalation) |
| `/fix` — labels/comments | Fast (Haiku/flash) | n/a |
| Manager (`/monitor-workers`) | Deep (Opus/pro) | `MANAGER_MODEL` |
| Swarm workers | Balanced | `WORKER_MODEL` |

## Auto-escalation rule

Workers start at Balanced and escalate to Deep when:
- Fix attempt fails after 2 tries with the same approach
- Root cause spans 5+ files requiring coordinated changes
- Issue explicitly labeled P0 or P1
