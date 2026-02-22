# SRE Monitor Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add an `autocoder/sre-monitor` skill that monitors production logs and app health when fix-loop is idle, filing GitHub issues for failures/warnings.

**Architecture:** Three-phase protocol skill (discovery → observation → reporting). Saves a persistent monitoring plan to `.claude/sre-monitor-plan.md` and a last-run timestamp to `.claude/sre-monitor-last-run`. Called from `fix.md` before brainstorming proposals. Parallel implementation in both `plugins/autocoder/commands/` and `.agent/workflows/`.

**Tech Stack:** Markdown protocol documents (like fix.md), Bash, `gh` CLI, all Claude Code tools (Read, Bash, Browser, WebFetch, etc.)

---

### Task 1: Create `plugins/autocoder/commands/sre-monitor.md`

**Files:**
- Create: `plugins/autocoder/commands/sre-monitor.md`

This is the primary Claude Code command. No traditional tests — verify by reading the file back and checking required sections exist.

**Step 1: Create the skill file**

```bash
# First, verify the commands directory exists
ls plugins/autocoder/commands/
```

Expected: list of existing .md files including fix.md, fix-loop.md, etc.

**Step 2: Write the file**

Create `plugins/autocoder/commands/sre-monitor.md` with this exact content:

````markdown
# SRE Monitor

You are acting as an SRE. Observe the health of the application, look for failures and warnings, and report them as GitHub issues. If relevant issues already exist, add comments with new evidence.

## State Files

- **Monitoring plan**: `.claude/sre-monitor-plan.md` — what to check (generated once, human-editable)
- **Last-run timestamp**: `.claude/sre-monitor-last-run` — ISO timestamp of last observation (updated every run)

---

## Phase 1: Discovery

### Check for Existing Plan

```bash
if [ -f ".claude/sre-monitor-plan.md" ]; then
  # Check if CLAUDE.md has changed since plan was generated
  PLAN_CLAUDE_MTIME=$(grep '^claude_md_mtime:' .claude/sre-monitor-plan.md | sed 's/claude_md_mtime: *//')
  CURRENT_CLAUDE_MTIME=$(date -r CLAUDE.md -Iseconds 2>/dev/null || echo "")

  if [ "$PLAN_CLAUDE_MTIME" = "$CURRENT_CLAUDE_MTIME" ] || [ -z "$CURRENT_CLAUDE_MTIME" ]; then
    echo "✅ Using existing monitoring plan"
    echo "PLAN_EXISTS=true"
  else
    echo "📝 CLAUDE.md changed — regenerating monitoring plan"
    echo "PLAN_EXISTS=false"
  fi
else
  echo "📝 No monitoring plan found — running discovery"
  echo "PLAN_EXISTS=false"
fi
```

If `PLAN_EXISTS=true`, skip to Phase 2.

### Discover Monitoring Targets

Read the following sources to build a picture of the system. Use the Read tool on each file that exists:

```bash
# Identify which discovery files exist
for f in CLAUDE.md README.md README.rst docker-compose.yml docker-compose.yaml \
          docker-compose.prod.yml .env.example Makefile; do
  [ -f "$f" ] && echo "EXISTS: $f"
done

# Find health/monitoring scripts
find scripts/ -name "health*" -o -name "monitor*" -o -name "check*" 2>/dev/null || true

# Find CI config
ls .github/workflows/ 2>/dev/null || true
ls .gitlab-ci.yml 2>/dev/null || true
```

Read each file that exists. Extract:

| Source | What to Look For |
|--------|-----------------|
| CLAUDE.md | Service names, endpoints, log paths, health commands, environment info |
| docker-compose files | Service names, port mappings, volume mounts (log dirs) |
| .env.example | Service hostnames, API URLs, external dependencies |
| Makefile | Targets named `health`, `status`, `check`, `logs` |
| CI config | Test commands, health check steps, deployment targets |
| scripts/health* | Ready-made health check commands |

### Write the Monitoring Plan

After reading discovery sources, synthesize a monitoring plan. Save to `.claude/sre-monitor-plan.md`:

```bash
CLAUDE_MD_MTIME=$(date -r CLAUDE.md -Iseconds 2>/dev/null || echo "unknown")
NOW=$(date -Iseconds)

cat > .claude/sre-monitor-plan.md << PLAN
---
generated: $NOW
claude_md_mtime: $CLAUDE_MD_MTIME
---

## Services
# Format: - name: URL or description
# Example: - api: https://localhost:3000/health
# Add one entry per service discovered

## Log Sources
# Format: - /path/to/logfile  OR  - description of log aggregation tool
# Example: - /var/log/app/error.log
# Example: - CloudWatch logs group: /app/production

## Health Scripts
# Format: - path/to/script.sh
# Scripts that can be run directly to check health

## Makefile Targets
# Format: - make target-name
# Makefile targets that check health or show status

## Custom Checks
# Add any additional checks here — these are preserved across plan regeneration
PLAN

echo "✅ Monitoring plan written to .claude/sre-monitor-plan.md"
echo "💡 Review and edit the plan to add/remove checks as needed"
```

Fill in the sections based on what you discovered. Be specific — include actual paths, URLs, and commands found. Leave sections empty (with just the comment) if nothing was found for that category.

---

## Phase 2: Observation

### Read the Plan

```bash
cat .claude/sre-monitor-plan.md
```

Parse each section. For each non-empty, non-comment line, you have a check to run.

### Read Last-Run Timestamp

```bash
LAST_RUN=""
if [ -f ".claude/sre-monitor-last-run" ]; then
  LAST_RUN=$(cat .claude/sre-monitor-last-run)
  echo "Last run: $LAST_RUN"
else
  echo "First run — will read recent log entries"
fi
```

### Run Checks

For each item in the plan, use the best available tool:

#### Log Files

For each log source that is a file path:

```bash
# Read lines since last run (or last 200 lines on first run)
if [ -n "$LAST_RUN" ]; then
  # Use awk to filter by timestamp if logs have timestamps
  # Otherwise, use modification time as proxy
  tail -200 /path/to/log | grep -E "ERROR|WARN|FATAL|Exception|Traceback|panic" || true
else
  tail -200 /path/to/log | grep -E "ERROR|WARN|FATAL|Exception|Traceback|panic" || true
fi
```

Use the Read tool for log files when Bash isn't appropriate (e.g., files that need parsing).

For log aggregation tools (CloudWatch, Datadog, Splunk, etc.), use available CLI tools or APIs if credentials are present in environment. Check for `aws`, `datadog-agent`, or similar CLIs:

```bash
which aws 2>/dev/null && echo "AWS CLI available"
which gcloud 2>/dev/null && echo "gcloud available"
```

#### HTTP Health Endpoints

For each service URL:

```bash
# Check health endpoint
RESPONSE=$(curl -s -o /tmp/sre-response.txt -w "%{http_code}" \
  --max-time 10 "https://service-url/health" 2>/dev/null || echo "FAILED")

if [ "$RESPONSE" = "FAILED" ]; then
  echo "ERROR: Could not reach service-url (connection failed)"
elif [ "$RESPONSE" -ge 500 ]; then
  echo "ERROR: service-url returned HTTP $RESPONSE"
  echo "Response: $(cat /tmp/sre-response.txt | head -20)"
elif [ "$RESPONSE" -ge 400 ]; then
  echo "WARN: service-url returned HTTP $RESPONSE"
elif [ "$RESPONSE" -ge 200 ] && [ "$RESPONSE" -lt 300 ]; then
  echo "OK: service-url ($RESPONSE)"
fi
```

Use WebFetch or browser tools for web UIs and dashboards if URLs are known. For browser-based checks, use mcp__claude-in-chrome or Playwright tools if available.

#### Health Scripts

```bash
# Run health script and capture output
SCRIPT_OUTPUT=$(bash scripts/health-check.sh 2>&1)
SCRIPT_EXIT=$?

if [ $SCRIPT_EXIT -ne 0 ]; then
  echo "ERROR: health script exited $SCRIPT_EXIT"
  echo "$SCRIPT_OUTPUT"
else
  # Check output for warning patterns even if exit code is 0
  if echo "$SCRIPT_OUTPUT" | grep -qiE "warn|degraded|slow|timeout"; then
    echo "WARN: health script output contains warnings"
    echo "$SCRIPT_OUTPUT"
  else
    echo "OK: health script passed"
  fi
fi
```

#### Makefile Targets

```bash
make status 2>&1 | head -50 || true
```

### What to Look For

**Good SRE instincts to apply:**

- **Errors**: Crashes, 5xx responses, non-zero exit codes, FATAL/ERROR log entries, stack traces
- **Warnings**: 4xx spikes, WARN log entries, slow responses (>2s), retries, degraded health check responses
- **Trends**: The same error appearing repeatedly in logs (even if each instance seems minor, a pattern is significant)
- **Silent failures**: Services that return 200 but with error content in the body, health checks that pass but report partial failure

**Be conservative with severity:**
- P1 (Error): Something is demonstrably broken — users are affected now
- P2 (Warning): Something is degraded, trending bad, or will cause P1 if not addressed

**Don't report:**
- Expected errors (404s for missing resources that should 404, health check noise)
- Single isolated occurrences of known-noisy logs unless clearly impactful
- Anything that looks like a test environment artifact when in a test environment

### Collect Findings

Maintain a list of findings as you observe:

```
FINDINGS:
- [ERROR] api: HTTP 503 from /health — service unreachable (3 attempts)
  Evidence: curl output showing connection refused
- [WARN] app/error.log: 47 occurrences of "database retry" in last 15 min
  Evidence: grep output showing timestamps clustering
```

---

## Phase 3: Reporting

### Update Last-Run Timestamp

```bash
date -Iseconds > .claude/sre-monitor-last-run
echo "✅ Updated last-run timestamp"
```

### For Each Finding

#### Step 1: Search for Existing Issue

```bash
# Search for existing issue about this service/symptom
# Use keywords from the finding — service name + symptom keyword
gh issue list \
  --state open \
  --search "SRE api unreachable" \
  --json number,title,labels \
  --limit 5
```

Inspect results. If a matching issue exists (same service, same symptom), add a comment:

```bash
gh issue comment <ISSUE_NUMBER> --body "$(cat <<'COMMENT'
## 🔍 SRE Observation — $(date -Iseconds)

**Status**: [Same / Worsening / Improving]

**Evidence**:
\`\`\`
[paste raw log lines / curl output / script output]
\`\`\`

**Change since last observation**: [describe any trend]

🤖 SRE monitor
COMMENT
)"
```

#### Step 2: Create New Issue (if no match)

**For errors (P1):**

```bash
gh issue create \
  --label "bug,sre,P1" \
  --title "[SRE] <service>: <symptom>" \
  --body "$(cat <<'BODY'
## Observed Failure

**Service**: <service name>
**First observed**: $(date -Iseconds)

## Evidence

\`\`\`
[paste raw log lines / curl output / script output]
\`\`\`

## Impact

[What is broken from a user perspective, if determinable]

## Suggested Investigation

1. [First thing to check]
2. [Second thing to check]
3. Check recent deployments: \`git log --oneline -10\`

---

🤖 Filed by SRE monitor
BODY
)"
```

**For warnings (P2):**

Same format but with label `sre,P2` and title prefix `[SRE]`. Adjust "Observed Failure" to "Observed Warning" and focus on the degradation trend.

### If Nothing Found

```bash
echo "✅ SRE monitor: no issues detected"
echo "   Checked: $(date -Iseconds)"
echo "   Sources: [list of what was checked]"
echo "SRE_MONITOR_CLEAN"
```

Output `SRE_MONITOR_CLEAN` so the caller (fix-loop) knows to continue to proposal brainstorming.

---

## Summary

After completing all phases:

- If issues were created or comments added → the fix-loop will pick up the new issues on its next iteration
- If nothing found → output `SRE_MONITOR_CLEAN` and return

**Do not loop** — the fix-loop handles iteration. Run once and return.
````

**Step 3: Verify the file was written**

```bash
wc -l plugins/autocoder/commands/sre-monitor.md
grep -c "Phase" plugins/autocoder/commands/sre-monitor.md
```

Expected: file exists with multiple lines, at least 3 Phase sections.

**Step 4: Commit**

```bash
git add plugins/autocoder/commands/sre-monitor.md
git commit -m "feat: Add autocoder/sre-monitor skill (Claude Code)

SRE monitor that discovers monitoring targets from CLAUDE.md and
repo structure, observes app health using all available tools,
and files GH issues for errors/warnings.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 2: Create `.agent/workflows/sre-monitor.md` (Antigravity parallel)

**Files:**
- Create: `.agent/workflows/sre-monitor.md`

Per CLAUDE.md parallel maintenance requirement, Antigravity needs a matching implementation. Content is identical in functionality but adapted for Antigravity (no Claude Code tool references, simpler structure).

**Step 1: Check existing Antigravity workflows for format reference**

```bash
head -5 .agent/workflows/fix-loop.md
head -5 .agent/workflows/fix.md
```

Note the frontmatter format used.

**Step 2: Create the Antigravity parallel**

Create `.agent/workflows/sre-monitor.md` with this content:

````markdown
---
description: SRE monitor - observe app health and file GH issues for failures/warnings
---

# SRE Monitor

You are acting as an SRE. Observe the health of the application, look for failures and warnings, and report them as GitHub issues. If relevant issues already exist, add comments with new evidence.

## State Files

- **Monitoring plan**: `.claude/sre-monitor-plan.md` — what to check (generated once, human-editable)
- **Last-run timestamp**: `.claude/sre-monitor-last-run` — ISO timestamp of last observation (updated every run)

## Instructions

Follow the same three-phase protocol as the Claude Code version:

### Phase 1: Discovery

Check if `.claude/sre-monitor-plan.md` exists:

```bash
if [ -f ".claude/sre-monitor-plan.md" ]; then
  PLAN_CLAUDE_MTIME=$(grep '^claude_md_mtime:' .claude/sre-monitor-plan.md | sed 's/claude_md_mtime: *//')
  CURRENT_CLAUDE_MTIME=$(date -r CLAUDE.md -Iseconds 2>/dev/null || echo "")
  if [ "$PLAN_CLAUDE_MTIME" = "$CURRENT_CLAUDE_MTIME" ] || [ -z "$CURRENT_CLAUDE_MTIME" ]; then
    echo "PLAN_EXISTS=true"
  else
    echo "PLAN_EXISTS=false"
  fi
else
  echo "PLAN_EXISTS=false"
fi
```

If `PLAN_EXISTS=false`, read CLAUDE.md, README, docker-compose files, .env.example, Makefile, and `scripts/health*` to discover services, log paths, health scripts, and endpoints. Write the plan to `.claude/sre-monitor-plan.md`.

### Phase 2: Observation

Read `.claude/sre-monitor-plan.md` and check each item:

- **Log files**: Read recent entries (since `.claude/sre-monitor-last-run` timestamp if available, else last 200 lines). Grep for `ERROR|WARN|FATAL|Exception|Traceback|panic`.
- **HTTP endpoints**: Use curl to check status codes. 5xx = error, 4xx spike = warning.
- **Health scripts**: Run them, check exit codes and output for warning patterns.
- **Makefile targets**: Run `make status` or similar if present.

Look for: errors, warnings, trends, silent failures. Be conservative — only P1 for clear breakage, P2 for degradation.

Update last-run timestamp:
```bash
date -Iseconds > .claude/sre-monitor-last-run
```

### Phase 3: Reporting

For each finding, search for existing issues:
```bash
gh issue list --state open --search "SRE <service> <symptom>" --json number,title --limit 5
```

- **Match found**: Comment with new evidence and timestamp.
- **No match**: Create issue with label `bug,sre,P1` (error) or `sre,P2` (warning), title `[SRE] <service>: <symptom>`.

If nothing found:
```bash
echo "SRE_MONITOR_CLEAN"
```

Do not loop — run once and return.
````

**Step 3: Verify**

```bash
wc -l .agent/workflows/sre-monitor.md
head -5 .agent/workflows/sre-monitor.md
```

Expected: frontmatter present, file has content.

**Step 4: Commit**

```bash
git add .agent/workflows/sre-monitor.md
git commit -m "feat: Add sre-monitor workflow (Antigravity parallel)

Mirrors plugins/autocoder/commands/sre-monitor.md for Antigravity.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 3: Update `plugins/autocoder/commands/fix.md` to call sre-monitor

**Files:**
- Modify: `plugins/autocoder/commands/fix.md`

The integration point is in the idle state handling — when there are no bugs, no approved enhancements, and no pending proposals. Currently fix.md falls straight to brainstorming proposals. We insert the SRE monitor call before that.

**Step 1: Find the exact insertion point**

```bash
grep -n "No pending proposals or blocked issues" plugins/autocoder/commands/fix.md
grep -n "Will brainstorm new proposals" plugins/autocoder/commands/fix.md
```

Note the line numbers of the section that reads:
```
echo "No pending proposals or blocked issues. Will brainstorm new proposals..."
# Run /full-regression-test first if not recently run
# Then brainstorm proposals using superpowers:brainstorming
# After creating proposals, output IDLE_NO_WORK_AVAILABLE
```

**Step 2: Replace that section**

Find this text in `plugins/autocoder/commands/fix.md`:

```
    echo "No pending proposals or blocked issues. Will brainstorm new proposals..."
    # Run /full-regression-test first if not recently run
    # Then brainstorm proposals using superpowers:brainstorming
    # After creating proposals, output IDLE_NO_WORK_AVAILABLE
```

Replace with:

```
    echo "No pending proposals or blocked issues."
    echo "🔍 Running SRE monitor before brainstorming proposals..."
    echo ""
```

Then after the closing `fi` of the outer `if/elif/else` block (the one checking `PRIORITY_ISSUES` / `APPROVED_ENHANCEMENTS`), add the SRE monitor invocation section. Find the line containing:

```
### Never Stop
```

And insert immediately before it:

```markdown
### SRE Monitor (when idle)

When no bugs, enhancements, or proposals exist, run the SRE monitor before brainstorming:

```
Use the Skill tool to invoke: autocoder:sre-monitor
```

If the SRE monitor creates issues (does NOT output `SRE_MONITOR_CLEAN`), the fix-loop will pick them up on the next iteration — continue the loop.

If the SRE monitor outputs `SRE_MONITOR_CLEAN` (nothing found), proceed to brainstorm new proposals using superpowers:brainstorming, then output `IDLE_NO_WORK_AVAILABLE`.

```

**Step 3: Verify the change looks right**

```bash
grep -n "SRE" plugins/autocoder/commands/fix.md
grep -n "sre-monitor" plugins/autocoder/commands/fix.md
```

Expected: lines referencing the SRE monitor skill invocation.

**Step 4: Commit**

```bash
git add plugins/autocoder/commands/fix.md
git commit -m "feat: Call sre-monitor when fix-loop is idle

When no bugs/enhancements/proposals exist, run the SRE monitor
before brainstorming proposals. Issues it files are picked up
on the next fix-loop iteration.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 4: Update `.agent/workflows/fix.md` (Antigravity parallel)

**Files:**
- Modify: `.agent/workflows/fix.md`

Mirror the same change in the Antigravity parallel.

**Step 1: Find the insertion point**

```bash
grep -n "brainstorm\|proposals\|IDLE_NO_WORK" .agent/workflows/fix.md | tail -20
```

Locate the equivalent idle-state section where fix.md falls through to proposal brainstorming when nothing is found.

**Step 2: Insert SRE monitor call**

Find the section where Antigravity's fix.md handles the "nothing to do" state and add before brainstorming:

```markdown
**Before brainstorming new proposals, run the SRE monitor:**

Execute the `/sre-monitor` workflow. If it creates issues (does not output `SRE_MONITOR_CLEAN`), loop back to pick them up. If `SRE_MONITOR_CLEAN`, proceed to brainstorm proposals then sleep.
```

**Step 3: Verify**

```bash
grep -n "sre-monitor\|SRE" .agent/workflows/fix.md
```

Expected: reference to sre-monitor added.

**Step 4: Commit**

```bash
git add .agent/workflows/fix.md
git commit -m "feat: Call sre-monitor when idle (Antigravity parallel)

Mirrors the fix.md change for Claude Code.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

## Verification

After all tasks complete:

```bash
# All four files exist or are modified
ls -la plugins/autocoder/commands/sre-monitor.md
ls -la .agent/workflows/sre-monitor.md
grep -c "sre-monitor" plugins/autocoder/commands/fix.md
grep -c "sre-monitor" .agent/workflows/fix.md

# Commit log shows 4 commits
git log --oneline -6
```

Expected: 2 new files, 2 modified files, 4 new commits.
