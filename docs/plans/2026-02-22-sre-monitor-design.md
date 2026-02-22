# SRE Monitor Skill Design

**Date**: 2026-02-22
**Skill**: `autocoder/sre-monitor`

## Overview

An autonomous SRE monitor skill for the autocoder plugin. When the fix-loop has no bugs, enhancements, or proposals to work on, it runs the SRE monitor before going idle. The monitor discovers how to observe the application from CLAUDE.md and repo structure, checks system health using all available tools, and reports findings as GitHub issues (or comments on existing ones).

## Architecture

### When It Runs

Called from `fix.md` in the idle state — after all priority bugs and enhancements are resolved, before brainstorming new proposals. If it creates issues, fix-loop picks them up immediately on the next iteration. If it finds nothing, fix-loop falls through to proposal brainstorming.

### Three Phases

1. **Discovery** — Build a monitoring plan from CLAUDE.md, README, scripts, configs
2. **Observation** — Use all available tools to check system health
3. **Reporting** — File GitHub issues or add comments to existing ones

---

## Phase 1: Discovery

### Primary Sources

- **CLAUDE.md** — Service names, endpoints, log paths, health commands, deployment/environment info
- **README** — Architecture overview, service descriptions, setup instructions
- **`.env.example`** — Service names, port numbers, external dependencies

### Repo Exploration

- `scripts/health*`, `scripts/monitor*`, `scripts/check*` — health check scripts
- `Makefile` — monitoring-related targets
- `docker-compose*.yml` — services, ports, volumes
- CI config (`.github/workflows/`, `.gitlab-ci.yml`) — test and deploy pipeline structure

### Output

A monitoring plan saved to `.claude/sre-monitor-plan.md`. Generated once. Only regenerated if CLAUDE.md has been modified since the plan was created (checked via mtime). Human-editable — users can add custom checks or remove irrelevant ones.

Plan format:

```markdown
---
generated: <ISO timestamp>
claude_md_mtime: <ISO timestamp>
---

## Services
- <name>: <health URL or description>

## Log Sources
- <path or description>

## Health Scripts
- <script path>

## Custom Checks
(add your own here)
```

---

## Phase 2: Observation

Works through each item in the monitoring plan using the most appropriate available tool:

| Target Type | Tool |
|-------------|------|
| Log files | Read recent entries since last-run timestamp; scan for ERROR/WARN/FATAL/exception/stack trace patterns |
| HTTP health endpoints | `curl` via Bash or browser fetch; check status codes and response body |
| Health scripts | Run directly, capture stdout/stderr and exit code |
| Web UIs / dashboards | Browser navigation if URLs are known |
| System state | Process status, queue depths, resource usage if tooling exists |

### Last-Run Timestamp

Stored separately in `.claude/sre-monitor-last-run` (plain ISO timestamp, one line). Updated after every observation run. Used to limit log reading to new entries only — avoids re-reporting the same events.

### Good SRE Behavior

- Check the **4 golden signals**: errors, latency, traffic, saturation — plus **warnings** (degraded but not broken)
- Look for **trends** not just point-in-time snapshots (e.g., error rate climbing over last N entries)
- Focus on **user-visible symptoms** rather than implementation details
- Be **conservative with severity** — don't cry wolf on P0/P1; reserve for genuine breakage

---

## Phase 3: Reporting

For each finding, search existing open GH issues first:

```bash
gh issue list --state open --search "<service> <symptom>"
```

**If a matching issue exists** → add a comment with:
- New observation data and timestamp
- Any change in severity (better or worse)
- New log evidence or context

**If no matching issue** → create a new one:

| Finding | Priority | Labels |
|---------|----------|--------|
| Error (broken, failing) | P1 | `bug`, `sre` |
| Warning (degraded, trending bad) | P2 | `sre` |

Issue title format: `[SRE] <service>: <symptom>`

Issue body includes: what was observed, raw evidence (log lines, response bodies), timestamp, and suggested investigation steps.

**If nothing found** → output a one-line summary and exit cleanly. Fix-loop continues to proposal brainstorming.

---

## State Files

| File | Purpose | Updated |
|------|---------|---------|
| `.claude/sre-monitor-plan.md` | Monitoring plan (human-editable) | Once, or when CLAUDE.md changes |
| `.claude/sre-monitor-last-run` | ISO timestamp of last observation run | After every run |

---

## Integration: fix.md Changes

In the idle state handling of `fix.md`, before brainstorming new proposals:

```
When truly idle (no bugs, no enhancements, no proposals):
  1. Run autocoder:sre-monitor
  2. If it created issues → loop picks them up (continue)
  3. If nothing found → brainstorm proposals → IDLE_NO_WORK_AVAILABLE
```

---

## Parallel Implementation

Both `plugins/autocoder/commands/sre-monitor.md` (Claude Code) and `.agent/workflows/sre-monitor.md` (Antigravity) must be created and kept in sync per CLAUDE.md parallel maintenance requirements.
