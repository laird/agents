# Start Infinite Fix-GitHub Loop

Wrapper around `/fix` that runs it in a loop forever.

Uses the `/loop` command (CronCreate-based) if available in this Antigravity version; falls back to the stop hook mechanism for older versions.

## Optional skill enhancements

<!-- BEGIN optional-skills-prelude v2 — keep in sync across all command files; see plugins/shared/optional-skills-prelude.md -->

If a named skill appears in your available skills list (delivered in the session-start system-reminder), invoke it via the `Skill` tool at the indicated step. Otherwise, follow the inline protocol below — it remains the source of truth and is unchanged by this section.

Platform note: in Gemini CLI / Antigravity, skills activate via `activate_skill` instead of the `Skill` tool; in Codex they activate as `$<skill>`; in Factory Droid they load from the skills tree. The mapping is otherwise identical on all four platforms.

**Skill-name matching.** Match each table entry as an exact string. Mapping tables use fully-qualified names (`<plugin>:<skill>`) for plugin-installed skills and bare names for personal toolkit skills. Compound Engineering skills are the exception: match them in **either** form — fully-qualified `compound-engineering:ce-<name>` (how Claude Code lists them) or bare `ce-<name>` (how Codex, Factory Droid, and Antigravity list them).

**Notation.** `A → B → C` means sequence (invoke in order). `A + B + C` means independent facets (all apply, order irrelevant). `A (primary)` means A is the orchestration spine. A leading `→` on a row indicates "next in sequence if applicable."

**Compound Engineering precedence.** If a skill from the `compound-engineering` plugin covers a role in the table below and appears in your available-skills list, invoke it *in place of* the skill named in the mapping tables for that role. Compound Engineering outranks both `superpowers:*` and personal toolkit skills. Roles with no entry below are unaffected.

| Role | Use when installed | In place of |
|---|---|---|
| design exploration / requirements | `ce-brainstorm` | `thorough-brainstorming`, `superpowers:brainstorming` |
| implementation planning | `ce-plan` | `thorough-writing-plans`, `superpowers:writing-plans` |
| executing a plan | `ce-work` | `superpowers:executing-plans` |
| debugging a defect | `ce-debug` | `superpowers:systematic-debugging` |
| reviewing a spec or plan document | `ce-doc-review` | `critical-design-review`, `critical-implementation-review`, `update-design-doc`, `update-implementation-plan` |
| reviewing written code | `ce-code-review` | `completion-review`, `superpowers:requesting-code-review` |
| acting on review feedback | `ce-resolve-pr-feedback` | `superpowers:receiving-code-review` |
| session handoff | `ce-handoff` | `create-handoff`, `resume-handoff` |

Worktree provisioning and branch finishing are **not** substituted: `superpowers:using-git-worktrees` and `superpowers:finishing-a-development-branch` remain in force, because the inline protocol owns worktree naming, the issue-claim sequence, and the configured Merge Mode.

**Failure semantics.** Not-installed: silent fallback. Mid-run failure or interruption of an installed skill: surface the failure message, fall back to the inline protocol for the rest of that step, no retry. Self-skip (e.g., `<SUBAGENT-STOP>`): silent fallback, not treated as failure. If at least one `superpowers:*` skill named in this command's mapping table is missing from your available-skills list **and no installed Compound Engineering skill covers its role**, emit one consolidated recommendation line at command entry: *Tip: this command works best with the `superpowers` plugin (https://github.com/obra/superpowers) — install via `/plugin install superpowers@claude-plugins-official`.* Never emit such notices for Compound Engineering or personal toolkit skills.

**Skills are advisory, not gating.** A command's completion criteria are defined by its inline protocol. Optional skill outcomes are surfaced and considered, but do not override inline success criteria. "Always applied" in a mapping table means the skill is invoked when installed; outcomes remain advisory. When a command claims success while an advisory skill earlier in the run surfaced a failure, the success summary acknowledges the advisory finding.

**Version trust.** Skills are matched by name; the integration does not pin or verify versions. If a tracked skill's contract changes in a way that breaks the chain, the integration is stale and must be updated.

<!-- END optional-skills-prelude v2 -->

<!-- BEGIN optional-skills-mapping fix-loop v1 — keep in sync between Claude/Antigravity mirrors of this command -->

`/fix-loop` is a dispatcher coordinating parallel workers. The dispatcher and workers have distinct skill mappings.

**Dispatcher level (runs in the host workspace, not a worktree).**

| Step | Skill mapping |
|---|---|
| Plan and dispatch parallel workers | `superpowers:subagent-driven-development` + `superpowers:dispatching-parallel-agents` |
| Provision isolated worktrees for workers | `superpowers:using-git-worktrees` (for workers only; dispatcher runs in host workspace) |

**Per-worker level** (each worker in its own worktree; workers receive the dispatcher's manifest and apply the full `/fix` mapping above to their assigned issue, including the same composition rule and ordering-across-steps rule), plus:

| Step | Skill mapping |
|---|---|
| Each worker finishes its branch (PR / merge) | `superpowers:finishing-a-development-branch` |

**Worker dispatch.** Prepend the `optional-skills-manifest v1` block (from `plugins/shared/optional-skills-prelude.md` / `.agent/shared/optional-skills-prelude.md`) as the **first paragraph** of each worker's prompt. Generate the bullet list as the intersection of your available skills × the per-worker skill set: `superpowers:systematic-debugging`, `superpowers:test-driven-development`, `superpowers:using-git-worktrees`, `superpowers:verification-before-completion`, `superpowers:requesting-code-review`, `superpowers:receiving-code-review`, `superpowers:finishing-a-development-branch`, `thorough-brainstorming`, `thorough-writing-plans`, `superpowers:brainstorming`, `superpowers:writing-plans`, `autocoder:improve-test-coverage`, `critical-design-review`, `critical-implementation-review`, `completion-review`.

<!-- END optional-skills-mapping fix-loop v1 -->

## Usage

```bash
# Start infinite loop
/fix-loop

# Limit to 100 iterations (stop hook mode only)
/fix-loop 100

# Custom idle sleep time (default: 4 minutes — stays inside the 5-min prompt cache TTL)
/fix-loop --sleep 30

# Phase 3 opt-in: route loop through /dispatch (Haiku gate,
# Sonnet/Opus worker via Task model= handoff). Default unset → uses
# /gate (same-model, Phase 2). Acceptance criteria in spec §13.4.
LOOP_MODEL_SPLIT=1 /fix-loop

# Multi-agent coordination with deployment
/fix-loop --branch main --deploy "deploy.sh staging ."

# Or set via environment
export ANTIGRAVITY_INTEGRATION_BRANCH="main"
export ANTIGRAVITY_DEPLOY_COMMAND="deploy.sh staging ."
/fix-loop
```

## How It Works

**Mode 1: `/loop` command (preferred, when CronCreate tool is available)**

1. Parses arguments and reads config from GEMINI.md
2. Uses the `loop` skill to schedule `/fix` every `IDLE_SLEEP_MINUTES` minutes
3. No settings.json modification needed — cleaner and more reliable
4. Loop runs until manually cancelled (CronDelete)

**Mode 2: Stop hook (fallback for older Antigravity versions)**

1. Installs stop hook in `.agent/settings.json` (if not present)
2. Creates state file `.agent/fix-loop.local.md`
3. Runs `/fix`
4. When Antigravity tries to exit, stop hook feeds `/fix` back as input
5. Loop continues until manually stopped or max iterations reached

## Multi-Agent Coordination (Automatic)

When `ANTIGRAVITY_TASK_LIST_ID` is set, `/fix-loop` automatically coordinates with other agents:

**Setup:**
```bash
# 1. Configure deployment in your GEMINI.md:
cat >> GEMINI.md << 'EOF'

## Deployment

Integration branch: main
Deploy to staging: deploy.sh staging .
EOF

# 2. Set shared task list ID in all worktrees
export ANTIGRAVITY_TASK_LIST_ID="project-$(date +%Y%m%d)"

# 3. Run /fix-loop in each worktree (same command everywhere)
# Main worktree
cd /path/to/project
/fix-loop  # → Auto-detects: "I'm coordinator, will deploy when ready"

# Feature worktree 1
cd /path/to/project-wt-auth
/fix-loop  # → Auto-detects: "I'm worker, will complete tasks"

# Feature worktree 2
cd /path/to/project-wt-api
/fix-loop  # → Auto-detects: "I'm worker, will complete tasks"
```

**Configuration Options:**

The integration branch and deploy command can be specified:

1. **In GEMINI.md** (recommended):
   ```markdown
   ## Deployment
   Integration branch: main
   Deploy to staging: deploy.sh staging .
   ```

2. **Via environment**:
   ```bash
   export ANTIGRAVITY_INTEGRATION_BRANCH="main"
   export ANTIGRAVITY_DEPLOY_COMMAND="deploy.sh staging ."
   ```

3. **Via command line**:
   ```bash
   /fix-loop --branch main --deploy "deploy.sh staging ."
   ```

4. **Auto-detection**: Defaults to `main` branch and looks for:
   - `scripts/deploy-staging.sh`
   - `deploy.sh staging`
   - Deployment commands in GEMINI.md

**Automatic Deployment Trigger:**

When ALL these conditions are met:
- ✅ All agents idle (no pending/in_progress tasks)
- ✅ Integration branch ready (clean working tree, all pushed)
- ✅ I'm in main worktree (not a feature worktree)
- ✅ New changes to deploy (current commit not already deployed)
- ✅ Deploy command configured

Then: Main worktree automatically:
1. Switches to integration branch
2. Commits any uncommitted changes
3. Pushes integration branch (if needed)
4. Pulls latest integration branch
5. Merges all feature branches from worktrees
6. Pushes merged integration branch
7. Executes deployment command

**Benefits:**
- Zero manual coordination needed
- Same `/fix-loop` command everywhere
- Automatic role detection (coordinator vs worker)
- Safe deployment (only when all work complete and pushed)
- Project-specific deployment via GEMINI.md

## Stopping the Loop

**`/loop` mode:**
- **CronDelete** - Remove the scheduled cron job
- **Ctrl+C** - Manual interrupt of current run

**Stop hook mode:**
- **Ctrl+C** - Manual interrupt
- **Output `STOP_FIX_GITHUB_LOOP`** - Explicit stop signal
- **Max iterations** - If set, stops when reached
- **Delete state file** - `rm .agent/fix-loop.local.md`

## Instructions

```bash
# Parse arguments
MAX_ITERATIONS="${1:-0}"  # 0 = unlimited
# Default 4 min keeps consecutive ticks inside the 5-min prompt cache TTL —
# see docs/specs/2026-05-21-fix-loop-token-efficiency-design.md §6 for the analysis.
IDLE_SLEEP_MINUTES="4"
INTEGRATION_BRANCH="${ANTIGRAVITY_INTEGRATION_BRANCH:-}"
DEPLOY_COMMAND="${ANTIGRAVITY_DEPLOY_COMMAND:-}"

args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  case ${args[i]} in
    --sleep)
      IDLE_SLEEP_MINUTES="${args[i+1]}"
      ((i++))
      ;;
    --branch)
      INTEGRATION_BRANCH="${args[i+1]}"
      ((i++))
      ;;
    --deploy)
      DEPLOY_COMMAND="${args[i+1]}"
      ((i++))
      ;;
    [0-9]*)
      MAX_ITERATIONS="${args[i]}"
      ;;
  esac
done

# If not set, try to extract from GEMINI.md
if [[ -z "$INTEGRATION_BRANCH" ]]; then
  for claude_file in GEMINI.md GEMINI.md README.md; do
    if [[ -f "$claude_file" ]]; then
      INTEGRATION_BRANCH=$(grep -i "integration.*branch\|main.*branch\|merge.*into" "$claude_file" | \
        grep -Eo '\b(main|master|develop|integration)\b' | head -1)
      [[ -n "$INTEGRATION_BRANCH" ]] && break
    fi
  done
fi

# Default to main if still not found
INTEGRATION_BRANCH="${INTEGRATION_BRANCH:-main}"

# If not set, try to extract deploy command from GEMINI.md
if [[ -z "$DEPLOY_COMMAND" ]]; then
  for claude_file in GEMINI.md GEMINI.md README.md; do
    if [[ -f "$claude_file" ]]; then
      DEPLOY_COMMAND=$(grep -i "deploy.*staging\|staging.*deploy" "$claude_file" | \
        grep -Eo '(\.?/)?[a-zA-Z0-9_/-]+\.sh\s+[a-zA-Z0-9_. /-]*' | head -1)
      [[ -n "$DEPLOY_COMMAND" ]] && break
    fi
  done
fi

export ANTIGRAVITY_INTEGRATION_BRANCH="$INTEGRATION_BRANCH"
export ANTIGRAVITY_DEPLOY_COMMAND="$DEPLOY_COMMAND"

# Phase 3 opt-in: LOOP_MODEL_SPLIT=1 routes to /dispatch
# (Haiku gate + Sonnet/Opus worker via Task model=). Default → /gate.
# See docs/specs/2026-05-21-fix-loop-token-efficiency-design.md §5.3, §10 Phase 3.
if [[ "${LOOP_MODEL_SPLIT:-0}" = "1" ]]; then
  LOOP_TARGET="/dispatch"
else
  LOOP_TARGET="/gate"
fi

mkdir -p .claude
```

### Detect /loop availability and choose mode

**Check whether the `CronCreate` tool is available** (it appears in the available deferred tools list when Antigravity supports the `/loop` command).

**If CronCreate IS available → Use `/loop` mode (preferred):**

```bash
# Remove the stop hook if it was previously installed, since /loop replaces it
if [ -f ".agent/settings.json" ] && grep -q "autocoder/hooks/stop-hook.sh" .agent/settings.json 2>/dev/null; then
  echo "🔄 Removing stop hook (replaced by /loop command)..."
  python3 << 'PYTHON_SCRIPT'
import json
with open(".agent/settings.json", 'r') as f:
    settings = json.load(f)
if "hooks" in settings and "Stop" in settings["hooks"]:
    settings["hooks"]["Stop"] = [h for h in settings["hooks"]["Stop"] if "stop-hook" not in str(h)]
    if not settings["hooks"]["Stop"]:
        del settings["hooks"]["Stop"]
    if not settings["hooks"]:
        del settings["hooks"]
with open(".agent/settings.json", 'w') as f:
    json.dump(settings, f, indent=2)
PYTHON_SCRIPT
  echo "✅ Stop hook removed"
fi

echo ""
echo "🔄 Starting fix loop using /loop command"
echo "   Interval: ${IDLE_SLEEP_MINUTES}m"
if [[ -n "$ANTIGRAVITY_TASK_LIST_ID" ]]; then
  echo "   Coordination: Enabled (task list: ${ANTIGRAVITY_TASK_LIST_ID:0:20}...)"
  echo "   Integration branch: $INTEGRATION_BRANCH"
  [[ -n "$DEPLOY_COMMAND" ]] && echo "   Deploy command: $DEPLOY_COMMAND"
fi
echo ""
echo "To stop: use CronDelete to remove the scheduled job, or Ctrl+C"
echo ""
```

**Then invoke the loop skill:**

```
Use the Skill tool to invoke: loop
With args: ${IDLE_SLEEP_MINUTES}m ${LOOP_TARGET}
```

This schedules `${LOOP_TARGET}` (the slim pre-LLM gate, per spec §5.4; `/dispatch` when `LOOP_MODEL_SPLIT=1`) to run every `IDLE_SLEEP_MINUTES` minutes using the native CronCreate mechanism. The gate dispatches to `/fix` only when there is actual work to do; idle ticks exit cheaply. No stop hook or settings.json modification needed.

---

**If CronCreate is NOT available → Use stop hook mode (fallback):**

```bash
# ============================================================
# Install stop hook if not configured
# ============================================================
if [ -f ".agent/settings.json" ] && grep -q "autocoder/hooks/stop-hook.sh" .agent/settings.json 2>/dev/null; then
  echo "✅ Stop hook already configured"
else
  echo "📝 Installing stop hook..."

  if [ -f ".agent/settings.json" ]; then
    python3 << 'PYTHON_SCRIPT'
import json
with open(".agent/settings.json", 'r') as f:
    settings = json.load(f)
stop_hook = {"matcher": "", "hooks": [{"type": "command", "command": "bash ~/.agent/plugins/autocoder/hooks/stop-hook.sh"}]}
if "hooks" not in settings:
    settings["hooks"] = {}
if "Stop" not in settings["hooks"]:
    settings["hooks"]["Stop"] = []
CURRENT_PATH = "autocoder/hooks/stop-hook.sh"
# Remove stale/legacy stop hooks (e.g. stop-hook-wrapper.sh) that aren't the current autocoder hook
settings["hooks"]["Stop"] = [h for h in settings["hooks"]["Stop"] if "stop-hook" not in str(h) or CURRENT_PATH in str(h)]
if not any(CURRENT_PATH in str(h) for h in settings["hooks"]["Stop"]):
    settings["hooks"]["Stop"].append(stop_hook)
with open(".agent/settings.json", 'w') as f:
    json.dump(settings, f, indent=2)
PYTHON_SCRIPT
  else
    cat > .agent/settings.json << 'EOF'
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.agent/plugins/autocoder/hooks/stop-hook.sh"
          }
        ]
      }
    ]
  }
}
EOF
  fi
  echo "✅ Stop hook installed"
fi

# Create loop state file
cat > .agent/fix-loop.local.md << EOF
---
iteration: 0
max_iterations: $MAX_ITERATIONS
idle_sleep_minutes: $IDLE_SLEEP_MINUTES
integration_branch: $INTEGRATION_BRANCH
deploy_command: $DEPLOY_COMMAND
started: $(date -Iseconds)
---

${LOOP_TARGET}
EOF

echo ""
echo "🔄 Loop initialized (stop hook mode)"
echo "   Max iterations: $([ "$MAX_ITERATIONS" = "0" ] && echo "unlimited" || echo "$MAX_ITERATIONS")"
echo "   Idle sleep: $IDLE_SLEEP_MINUTES minutes"
if [[ -n "$ANTIGRAVITY_TASK_LIST_ID" ]]; then
  echo "   Coordination: Enabled (task list: ${ANTIGRAVITY_TASK_LIST_ID:0:20}...)"
  echo "   Integration branch: $INTEGRATION_BRANCH"
  [[ -n "$DEPLOY_COMMAND" ]] && echo "   Deploy command: $DEPLOY_COMMAND"
fi
echo ""
```

**Then execute `/gate` using the Skill tool:**

```
Use the Skill tool to invoke: autocoder:${LOOP_TARGET#/}
```

The stop hook will automatically re-invoke `${LOOP_TARGET}` when Antigravity exits, creating an infinite loop. The gate dispatches to `/fix` only when there is work to do (spec §5.4).
