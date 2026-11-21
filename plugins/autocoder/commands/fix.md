# Start Autonomous Fix of GitHub Issues

Analyze all open GitHub issues, prioritize them, and begin systematically fixing or implementing them starting with the highest priority.

## Optional skill enhancements

<!-- BEGIN optional-skills-prelude v3 — keep in sync across all command files; see plugins/shared/optional-skills-prelude.md -->

If a named skill appears in your available skills list (delivered in the session-start system-reminder), invoke it via the `Skill` tool at the indicated step. Otherwise, follow the inline protocol below — it remains the source of truth and is unchanged by this section.

Platform note: in Gemini CLI / Antigravity, skills activate via `activate_skill` instead of the `Skill` tool; in Codex they activate as `$<skill>`; in Factory Droid they load from the skills tree. The mapping is otherwise identical on all four platforms.

**Skill-name matching.** Match each table entry as an exact string. Mapping tables use fully-qualified names (`<plugin>:<skill>`) for plugin-installed skills and bare names for personal toolkit skills. Compound Engineering skills are the exception: match them in **either** form — fully-qualified `compound-engineering:ce-<name>` (how Claude Code lists them) or bare `ce-<name>` (how Codex, Factory Droid, and Antigravity list them). pstack skills match as fully-qualified `pstack:<name>` (how Claude Code and Codex list them). A bare `<name>` counts as pstack only when bare `poteto-mode` is also in your available-skills list, which marks a skills-only pstack install; otherwise a bare `tdd` or `how` is a personal toolkit skill and gets no pstack precedence.

**Notation.** `A → B → C` means sequence (invoke in order). `A + B + C` means independent facets (all apply, order irrelevant). `A (primary)` means A is the orchestration spine. A leading `→` on a row indicates "next in sequence if applicable."

**pstack precedence.** pstack (https://github.com/michael-denyer/pstack-claude) outranks Compound Engineering, `superpowers:*`, and personal toolkit skills for the role below. If the listed `pstack:*` skill appears in your available-skills list, invoke it *in place of* every skill in the "In place of" column, including a Compound Engineering skill that would otherwise substitute for it. Roles pstack does not cover fall through to the Compound Engineering table. In an unattended run, take `pstack:interrogate`'s intent statement from the issue or plan instead of asking the user.

| Role | Use when installed | In place of |
|---|---|---|
| reviewing written code | `pstack:interrogate` | `ce-code-review`, `superpowers:requesting-code-review` |

Mapping tables also name pstack skills directly where no other plugin covers the step: `pstack:tdd` (bug regression test), `pstack:how` (understand unfamiliar code), `pstack:deslop` (clean the diff), `pstack:blast-radius` (what a change breaks beyond its diff), and `pstack:unslop` / `pstack:technical-writing` (prose this command authors). Run `pstack:blast-radius` without its `arena` escalation, and write its proof scripts outside the working tree so they are never committed.

**pstack orchestrators are not invoked.** This command's inline protocol is the spine. Do not enter `pstack:poteto-mode`, `pstack:figure-it-out`, `pstack:swarm`, `pstack:arena`, `pstack:architect`, `pstack:babysit`, or `pstack:make-pr-easy-to-review`, including when another pstack skill's steps tell you to run one. Each owns its own playbook, dispatch, implementation, or PR tail and would bypass worktree naming, the issue-claim sequence, and the configured Merge Mode. pstack's SessionStart hook injects "Invoke the `pstack:poteto-mode` skill ... when a task touches more than one file" at startup and after every compaction. Ignore that instruction while this command runs, every time it reappears. The hook defers only to CLAUDE.md, AGENTS.md, and direct requests, so for unattended workers also set `session hook: off` in `pstack-models.md` (see `docs/PSTACK.md`).

**Compound Engineering precedence.** If a skill from the `compound-engineering` plugin covers a role in the table below and appears in your available-skills list, invoke it *in place of* the skill named in the mapping tables for that role. Compound Engineering outranks both `superpowers:*` and personal toolkit skills (pstack outranks it, per the table above), and this rule overrides any "(preferred)" annotation a mapping table places on a substituted skill. Roles with no entry below are unaffected.

| Role | Use when installed | In place of |
|---|---|---|
| design exploration / requirements | `ce-brainstorm` | `thorough-brainstorming`, `superpowers:brainstorming` |
| implementation planning | `ce-plan` | `thorough-writing-plans`, `superpowers:writing-plans` |
| executing a plan | `ce-work`, invoked as `mode:return-to-caller <plan path>` | `superpowers:executing-plans` |
| debugging a defect | `ce-debug` | `superpowers:systematic-debugging` |
| reviewing a spec, plan, or report document | `ce-doc-review` | `critical-design-review`, `critical-implementation-review`, `update-design-doc`, `update-implementation-plan` |
| reviewing written code | `ce-code-review` | `superpowers:requesting-code-review` |
| acting on review feedback **on an existing PR** | `ce-resolve-pr-feedback` | `superpowers:receiving-code-review` |
| session handoff | `ce-handoff` | `create-handoff`, `resume-handoff` |

Three deliberate exclusions:

- **Worktree provisioning and branch finishing are not substituted.** `superpowers:using-git-worktrees` and `superpowers:finishing-a-development-branch` remain in force — do **not** substitute `ce-worktree`, `ce-commit-push-pr`, `ce-commit`, or `lfg` for them — because the inline protocol owns worktree naming, the issue-claim sequence, and the configured Merge Mode. `ce-work` is substituted for plan execution only, which is why the table requires `mode:return-to-caller`: bare `ce-work` owns its own shipping tail and would bypass all three.
- **`completion-review` is never substituted.** It is a plan-vs-delivery audit, not a diff review, and it runs on Document deliverables (`/retro`, `/fix`'s Document row) where a code reviewer has nothing to read. Run it as the mapping tables specify, alongside the code reviewer (`pstack:interrogate` or `ce-code-review`) rather than replaced by it.
- **Review feedback with no PR open.** When findings came from an in-session reviewer (`pstack:interrogate` or `ce-code-review`) and no PR exists yet, act on them via the inline protocol or `superpowers:receiving-code-review`; `ce-resolve-pr-feedback` requires GitHub PR threads.

**Failure semantics.** Not-installed: silent fallback. Mid-run failure or interruption of an installed skill: surface the failure message, fall back to the inline protocol for the rest of that step, no retry. Self-skip (e.g., `<SUBAGENT-STOP>`): silent fallback, not treated as failure. If at least one `superpowers:*` skill named in this command's mapping table is missing from your available-skills list **and no installed pstack or Compound Engineering skill covers its role**, emit one consolidated recommendation line at command entry: *Tip: this command works best with the `superpowers` plugin (https://github.com/obra/superpowers) — install via `/plugin install superpowers@claude-plugins-official`.* Never emit such notices for pstack, Compound Engineering, or personal toolkit skills.

**Skills are advisory, not gating.** A command's completion criteria are defined by its inline protocol. Optional skill outcomes are surfaced and considered, but do not override inline success criteria. "Always applied" in a mapping table means the skill is invoked when installed; outcomes remain advisory. When a command claims success while an advisory skill earlier in the run surfaced a failure, the success summary acknowledges the advisory finding.

**Version trust.** Skills are matched by name; the integration does not pin or verify versions. If a tracked skill's contract changes in a way that breaks the chain, the integration is stale and must be updated.

<!-- END optional-skills-prelude v3 -->

<!-- BEGIN optional-skills-mapping fix v2 — keep in sync between Claude/Antigravity mirrors of this command -->

`/fix` accepts heterogeneous work — bug fixes, feature implementation, refactoring, increasing test coverage, docs/config/chore, or proposing new tasks. The agent classifies the work after reading the issue and applies the matching skills along two axes: deliverable type and kind of work.

**Composition rule.** Step 2 and Step 3 compose by **union**: apply every skill named in either step. Where both steps name the same skill, apply it once. Where the two steps disagree on whether a skill is required vs. optional, the **stronger requirement wins** (a skill marked required in one step is required overall). Step 1 (deliverable classification) is purely a routing input to Step 2 and produces no skills of its own.

**Ordering across steps.** When Step 3 contributes a sequence (`A → B → C`), that sequence defines the spine. Step 2 facets attach at conventional points:
- **Provisioning facets** (e.g., `superpowers:using-git-worktrees`) attach at spine entry — before the first sequence step runs.
- **Verification facets** (e.g., `superpowers:verification-before-completion`, `pstack:blast-radius`) attach at spine exit — after the last sequence step. `pstack:deslop` edits code, so it runs first, on `git diff $INTEGRATION_BRANCH...HEAD` (not `main`), and verification runs after it: `pstack:deslop` → `superpowers:verification-before-completion`.
- **Wrap-up facets** (e.g., `completion-review`, `superpowers:requesting-code-review` → `superpowers:receiving-code-review`) attach after spine exit and after verification.

Where Step 3 contributes only a single skill or no sequence, treat it as a one-step spine and apply the same attachment points. Where a facet has no obvious attachment category, attach at spine exit.

**Step 1: classify the deliverable.**

| Deliverable type | Examples |
|---|---|
| **Branch** (code merged to main) | bug fix, new feature, refactor, increasing test coverage, docs/config/chore committed to the repo |
| **Document** (proposal, report, analysis) | proposing new tasks, investigation findings |
| **Throwaway** (spike, experiment) | rare; ad-hoc evaluation work that won't be merged |

**Step 2: apply the matching skills based on deliverable type.** "Always" below means the skill is invoked when installed; outcomes remain advisory.

| Applies when deliverable is... | Skill mapping |
|---|---|
| **Branch** | `superpowers:using-git-worktrees` + `pstack:deslop` → `superpowers:verification-before-completion` + `completion-review` (always); `pstack:blast-radius` (when the change alters a signature, contract, or behavior other code depends on); `superpowers:requesting-code-review` → `superpowers:receiving-code-review` (when seeking merge) |
| **Document** | `completion-review` + `pstack:unslop` (on text this issue authors, not on existing files it edits) |
| **Throwaway** | none of the above are required |

**Step 3: apply the matching skills based on kind of work.**

| If the work is... | Use these skills |
|---|---|
| Bug / unexpected behavior | `pstack:how` (only when the affected code is unfamiliar) → `superpowers:systematic-debugging` → `pstack:tdd` (preferred) or `superpowers:test-driven-development` |
| New feature / unclear requirement | `thorough-brainstorming` → `thorough-writing-plans` → `superpowers:test-driven-development` (fallback: `superpowers:brainstorming` → `superpowers:writing-plans`; optional `critical-design-review` after brainstorming, `critical-implementation-review` after writing-plans) |
| Refactor / restructuring | `pstack:how` (only when the code is unfamiliar) → `superpowers:test-driven-development` (characterization tests) → refactor under green |
| Increasing test coverage | `autocoder:improve-test-coverage` → `superpowers:test-driven-development` for new tests |
| Proposing new tasks | `thorough-brainstorming` (preferred) or `superpowers:brainstorming` → `critical-design-review` |
| Docs / config / chore | TDD optional |

<!-- END optional-skills-mapping fix v2 -->

## Usage

```bash
# Automatic priority-based selection (processes all issues in priority order)
/fix

# Target a specific issue directly (skips priority selection)
/fix 223
```

**With issue number**: Skips the priority selection process and immediately starts working on the specified issue, regardless of its priority label.

**Without issue number**: Fetches all open issues with priority labels (P0-P3) and processes them in priority order.

## What This Does

### Bug Fixing Phase (Priority)
1. Creates priority labels (P0, P1, P2, P3) if they don't exist
2. Fetches all open GitHub issues with priority labels
3. Identifies the highest priority issue (P0 > P1 > P2 > P3)
4. **For simple issues**: Directly troubleshoot and fix
5. **For complex issues**: Use superpowers skills to plan and execute
6. After fixing, moves to the next issue
7. Continues until all bug issues are resolved

### Regression Testing Phase
8. **When no priority bugs exist**: Run full regression test suite
9. Analyze regression test results and create GitHub issues for failures
10. Loop back to bug fixing if new issues are created

### Enhancement Phase (when no bugs)
11. Check for existing enhancement issues
12. **If enhancements exist**: Use superpowers to design, plan, and implement each one
13. Run tests after implementation
14. **If tests pass**: Commit, merge, and close enhancement
15. **If tests fail**: Create bug issues for failures, pause enhancement, fix bugs first
16. Repeat until all existing enhancements are implemented

### Propose New Enhancements (lowest priority)
17. **Only when no bugs AND no existing enhancements**: Propose new improvements
18. Use `thorough-brainstorming` (preferred) or `superpowers:brainstorming` to identify valuable enhancements
19. Create enhancement issue with detailed implementation plan
20. Loop back to Enhancement Phase to implement

Never stop, just keep looking for issues to address. Priority: Triage Unprioritized > Bugs > Existing Enhancements > Proposing New Enhancements.

**Note**: This command automatically reviews and prioritizes any open issues that lack priority labels (P0-P3) before processing the issue queue.

## Unprioritized Issue Triage

Moved to `autocoder:references/fix-triage.md` (#240). Read it when the configuration block prints `UNPRIORITIZED_ISSUES_FOUND=true`.

## Issue Complexity Detection

**Simple Issues** (direct fix):
- Single file changes
- Configuration tweaks
- Small bug fixes
- UI visibility issues
- Test timeout adjustments
- Removing deprecated code

**Complex Issues** (use superpowers if available):
- Multiple failing tests (>10 failures)
- Feature implementations
- Architecture changes
- Multi-file refactoring
- New functionality requiring design
- System integration issues

**Ultra-Complex Issues** (use quint if available):
- Major architecture decisions with significant trade-offs
- Issues requiring human judgment on business/product direction
- Problems too large for autonomous resolution (>100 test failures)
- Cross-cutting concerns affecting multiple systems
- Decisions with irreversible consequences
- When superpowers approaches have failed twice

## Model Selection

Model tiers are resolved from env vars → `.autocoder.json` → built-in defaults.
Agents inherit credentials from the running Claude Code session — no separate API keys needed.
See `autocoder:references/model-config.md` for full reference and override instructions.

| Tier | Default (Claude Code) | Used for |
|------|-----------------------|---------|
| **Deep** (`$MANAGER_MODEL`) | `opus` | P0/P1 issues, root cause, proposals |
| **Balanced** (`$WORKER_MODEL`) | `sonnet` | P2/P3 fixes, plan execution, analysis |
| **Fast** (`$FAST_MODEL`) | `haiku` | Labels, comments, commit messages |

### Escalation Triggers

Start at `$WORKER_MODEL`; escalate to `$MANAGER_MODEL` when:
- Fix attempt fails after 2 tries with the same approach
- Root cause spans 5+ files requiring coordinated changes
- Issue is labelled P0 or P1

### Example Task Tool Usage

```javascript
// Standard fix — use $WORKER_MODEL
Task("coder", "Fix dependency conflict in package.json...", model=WORKER_MODEL)

// Complex root cause — use $MANAGER_MODEL
Task("debugger", "Investigate why 15 tests fail with timeout...", model=MANAGER_MODEL)

// Mechanical task — use $FAST_MODEL
Task("labeler", "Add P2 label to issue #${ISSUE_NUM}...", model=FAST_MODEL)
```

## Context Management (MANDATORY — NON-NEGOTIABLE)

> ⛔ **STOP. Before you touch ANY new issue, you MUST compact your context. Every issue. Every time. No exceptions.**
>
> - **Claude Code:** run `/compact`.
> - **Codex / Gemini / other sessions:** clear or compact the session context using your session controls (the equivalent of `/compact`).
>
> This is not optional and not a suggestion. A long-running fix-loop **WILL** exhaust the context window and crash the agent mid-issue if you skip this. Compacting between issues is the single most important thing keeping the loop alive — treat skipping it as a defect.

**Rules — follow exactly:**

1. **Compact BEFORE fetching or starting every new issue.** Every iteration, without exception.
2. **Each issue starts from a fresh, compacted context.**
3. **NEVER carry over detailed investigation notes** from a previous issue — the compacted summary is sufficient.
4. **If you ever notice you've started a new issue without compacting, compact immediately** before doing anything else.

## Instructions

Start working on GitHub issues now:

```bash
# Source issue function layer (routes to GitHub or file backend)
# Resolve SCRIPT_DIR — see scripts/README.md#script-dir
SCRIPT_DIR=$(
  for d in "$(pwd)/.agent/scripts" \
           "$(pwd)/plugins/autocoder/scripts" \
           "$(pwd)/.claude-plugin/plugins/autocoder/scripts"; do
    if [ -f "$d/issue-fns.sh" ] && [ -f "$d/fix-loop-gate.sh" ]; then echo "$d"; exit 0; fi
  done
  # Fallback: the installed plugin. Only <ver>/scripts is a complete tree;
  # <ver>/skills/autocoder/scripts is a subset that sorts after it (#142).
  # Rank by the <ver> directory alone, not the whole path: with two marketplaces
  # in the cache, a whole-path sort lets the marketplace name decide (#201).
  find "$HOME/.claude/plugins/cache" -type d -name "scripts" -path "*/autocoder/*" -not -path "*/skills/*" 2>/dev/null \
    | while read -r d; do if [ -f "$d/issue-fns.sh" ] && [ -f "$d/fix-loop-gate.sh" ]; then echo "$d"; fi; done \
    | awk -F/ '{print $(NF-1) "\t" $0}' | sort -V -t$'\t' -k1,1 | tail -1 | cut -f2-
)
if [ ! -f "${SCRIPT_DIR}/issue-fns.sh" ]; then
  echo "autocoder: cannot locate issue-fns.sh (resolved SCRIPT_DIR='${SCRIPT_DIR}')" >&2
  exit 1
fi
source "${SCRIPT_DIR}/issue-fns.sh"
```

```bash
# Preflight: cheap check whether there's any claimable work before paying
# the LLM cost of the full /fix flow. See spec §5.
issue_any_claimable
case $? in
  0) ;;  # work exists; fall through
  1) echo "No claimable issues. Nothing to do."; exit 0 ;;
  *) echo "Backend error while checking for claimable issues"; exit 1 ;;
esac
```

```bash
# Load project-specific configuration from CLAUDE.md
if [ -f "CLAUDE.md" ]; then
  echo "📋 Reading project configuration from CLAUDE.md"

  # Check if autocoder configuration exists
  if ! grep -q "## Automated Testing & Issue Management" CLAUDE.md; then
    echo "⚠️  No autocoder configuration found in CLAUDE.md"
    echo "📝 Adding autocoder configuration section to CLAUDE.md..."

    # Auto-detect the repo's default branch (works for main, master, integration, etc.)
    DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
    DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"

    # Append autocoder configuration to CLAUDE.md
    cat >> CLAUDE.md << 'AUTOCODER_CONFIG'

## Automated Testing & Issue Management

This section configures the `/fix` command for autonomous issue resolution.

### Regression Test Suite
```bash
npm test
```

### Build Verification
```bash
npm run build
```

### Test Framework Details

**Unit Tests**:
- Framework: (Configure your test framework)
- Location: (Configure test file locations)

**E2E Tests**:
- Framework: (Configure E2E test framework)
- Location: (Configure E2E test locations)

**Test Reports**:
- Location: `docs/test/regression-reports/`

### Merge Mode
```
merge
```
Options: `merge` (auto-merge to the integration branch and push) or `pr` (push feature branch and create a pull request, then stop).

### Integration Branch
```
AUTOCODER_CONFIG
    echo "${DEFAULT_BRANCH}" >> CLAUDE.md
    cat >> CLAUDE.md << 'AUTOCODER_CONFIG'
```
The shared branch all completed work is merged into. In a parallel-worktree swarm this MUST be the real shared branch (e.g. `main`), never a per-worktree branch — otherwise fixes strand on `main-wt-N` and never converge.

AUTOCODER_CONFIG

    echo "✅ Added autocoder configuration to CLAUDE.md - please update with project-specific details"
  fi

  # Extract test command
  if grep -q "### Regression Test Suite" CLAUDE.md; then
    TEST_COMMAND=$(sed -n "/### Regression Test Suite/,/^###/{/^\`\`\`bash$/n;p;}" CLAUDE.md | grep -v "^#" | grep -v "^\`\`\`" | grep -v "^$" | head -1)
    echo "✅ Regression test command: $TEST_COMMAND"
  else
    TEST_COMMAND="npm test"
    echo "⚠️  No regression test command found, using default: $TEST_COMMAND"
  fi

  # Extract build command
  if grep -q "### Build Verification" CLAUDE.md; then
    BUILD_COMMAND=$(sed -n "/### Build Verification/,/^###/{/^\`\`\`bash$/n;p;}" CLAUDE.md | grep -v "^#" | grep -v "^\`\`\`" | grep -v "^$" | head -1)
    echo "✅ Build command: $BUILD_COMMAND"
  else
    BUILD_COMMAND="npm run build"
    echo "⚠️  No build command found, using default: $BUILD_COMMAND"
  fi
  # Extract merge mode (merge or pr)
  if grep -q "### Merge Mode" CLAUDE.md; then
    MERGE_MODE=$(sed -n "/### Merge Mode/,/^###/{/^\`\`\`$/n;p;}" CLAUDE.md | grep -v "^#" | grep -v "^\`\`\`" | grep -v "^$" | head -1)
    echo "✅ Merge mode: $MERGE_MODE"
  else
    MERGE_MODE=""
    echo "MERGE_MODE_NOT_CONFIGURED=true"
  fi
  # Extract the integration branch (the shared branch all work merges into).
  # Falls back to auto-detecting the repo default branch (supports main, master, integration, etc.)
  if grep -q "### Integration Branch" CLAUDE.md; then
    INTEGRATION_BRANCH=$(sed -n "/### Integration Branch/,/^###/{/^\`\`\`$/n;p;}" CLAUDE.md | grep -v "^#" | grep -v "^\`\`\`" | grep -v "^$" | head -1)
  fi
  INTEGRATION_BRANCH="${INTEGRATION_BRANCH:-$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')}"
  INTEGRATION_BRANCH="${INTEGRATION_BRANCH:-main}"
  echo "✅ Integration branch: $INTEGRATION_BRANCH"
else
  echo "⚠️  No CLAUDE.md found in project, using defaults"
  TEST_COMMAND="npm test"
  BUILD_COMMAND="npm run build"
  MERGE_MODE="merge"
  INTEGRATION_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
  INTEGRATION_BRANCH="${INTEGRATION_BRANCH:-main}"
fi

# Ensure gh is authenticated as the correct user for this repo (GitHub backend only)
if [ "$ISSUE_SOURCE" = "github" ]; then
  REPO_OWNER=$(gh repo view --json owner --jq '.owner.login' 2>/dev/null || echo "")
  if [ -n "$REPO_OWNER" ]; then
    CURRENT_GH_USER=$(gh api user --jq '.login' 2>/dev/null || echo "")
    if [ -n "$CURRENT_GH_USER" ] && [ "$CURRENT_GH_USER" != "$REPO_OWNER" ]; then
      echo "🔄 Switching gh identity to match repo owner ($REPO_OWNER)..."
      gh auth switch --user "$REPO_OWNER" 2>/dev/null || echo "⚠️  Could not switch to $REPO_OWNER — ensure 'gh auth login' has been run for this account"
    fi
  fi
fi

# ── Model configuration ──────────────────────────────────────────────────────
# Resolve model tiers: env vars → .autocoder.json → built-in defaults.
# If nothing is configured, ask the user to confirm defaults before proceeding.
_DEFAULT_MANAGER_MODEL="opus"
_DEFAULT_WORKER_MODEL="sonnet"
_DEFAULT_FAST_MODEL="haiku"

# Load from .autocoder.json if present and not already set via env
if [ -f ".autocoder.json" ] && command -v python3 >/dev/null 2>&1; then
  _JSON_MANAGER=$(python3 -c "import json,sys; d=json.load(open('.autocoder.json')); print(d.get('managerModel',''))" 2>/dev/null || echo "")
  _JSON_WORKER=$(python3 -c "import json,sys; d=json.load(open('.autocoder.json')); print(d.get('workerModel',''))" 2>/dev/null || echo "")
  _JSON_FAST=$(python3 -c "import json,sys; d=json.load(open('.autocoder.json')); print(d.get('fastModel',''))" 2>/dev/null || echo "")
  MANAGER_MODEL="${MANAGER_MODEL:-${_JSON_MANAGER:-$_DEFAULT_MANAGER_MODEL}}"
  WORKER_MODEL="${WORKER_MODEL:-${_JSON_WORKER:-$_DEFAULT_WORKER_MODEL}}"
  FAST_MODEL="${FAST_MODEL:-${_JSON_FAST:-$_DEFAULT_FAST_MODEL}}"
else
  MANAGER_MODEL="${MANAGER_MODEL:-$_DEFAULT_MANAGER_MODEL}"
  WORKER_MODEL="${WORKER_MODEL:-$_DEFAULT_WORKER_MODEL}"
  FAST_MODEL="${FAST_MODEL:-$_DEFAULT_FAST_MODEL}"
fi

# Detect whether this is the first run (no models were pre-configured)
_MODELS_PRECONFIGURED=false
if [ -n "${MANAGER_MODEL_PRECONFIG:-}" ] || [ -n "${WORKER_MODEL_PRECONFIG:-}" ]; then
  _MODELS_PRECONFIGURED=true
elif grep -q '"managerModel"\|"workerModel"\|"fastModel"' .autocoder.json 2>/dev/null; then
  _MODELS_PRECONFIGURED=true
fi

if [ "$_MODELS_PRECONFIGURED" = "false" ]; then
  echo ""
  echo "⚙️  Model configuration — no custom models detected."
  echo ""
  echo "   Default tiers:"
  echo "     Deep (manager/complex): $MANAGER_MODEL"
  echo "     Balanced (worker/standard): $WORKER_MODEL"
  echo "     Fast (labels/comments): $FAST_MODEL"
  echo ""
  echo "   To keep these defaults, reply: confirm"
  echo "   To override, set env vars before running /fix:"
  echo "     export MANAGER_MODEL=\"opus\""
  echo "     export WORKER_MODEL=\"sonnet\""
  echo "     export FAST_MODEL=\"haiku\""
  echo "   Or add to .autocoder.json:"
  echo "     {\"managerModel\": \"opus\", \"workerModel\": \"sonnet\", \"fastModel\": \"haiku\"}"
  echo ""
  # Ask the user to confirm or override using AskUserQuestion.
  # Present this as a blocking confirmation — do NOT proceed until the user responds.
  echo "ACTION_REQUIRED: Ask the user now using AskUserQuestion:"
  echo "  Question: 'Autocoder will use these model tiers — confirm or override?'"
  echo "  Options:"
  echo "    1. Use defaults ($MANAGER_MODEL / $WORKER_MODEL / $FAST_MODEL)"
  echo "    2. Override — I will set MANAGER_MODEL / WORKER_MODEL / FAST_MODEL env vars"
  echo "       (use tier shorthand: opus/sonnet/haiku for Claude Code, pro/flash for Gemini)"
  echo "    3. Save defaults to .autocoder.json (so this prompt doesn't appear again)"
  echo ""
  echo "  Agents inherit credentials from the running session — no API keys needed."
  echo ""
  echo "  If the user chooses option 3, write the following to .autocoder.json (merging"
  echo "  with any existing keys):"
  echo "    managerModel: $MANAGER_MODEL"
  echo "    workerModel:  $WORKER_MODEL"
  echo "    fastModel:    $FAST_MODEL"
  echo "  Then continue."
  echo "  If the user overrides, update MANAGER_MODEL / WORKER_MODEL / FAST_MODEL to"
  echo "  the values they provide before continuing."
fi

export MANAGER_MODEL WORKER_MODEL FAST_MODEL
echo "✅ Models: manager=$MANAGER_MODEL  worker=$WORKER_MODEL  fast=$FAST_MODEL"

# Detect available plugins for enhanced capabilities
echo "🔌 Detecting available plugins..."

# Check for superpowers plugin (structured problem-solving skills)
SUPERPOWERS_AVAILABLE=false
if claude plugins list 2>/dev/null | grep -q "superpowers"; then
  SUPERPOWERS_AVAILABLE=true
  echo "✅ superpowers plugin detected - will use for complex issues"
else
  echo "ℹ️  superpowers plugin not installed - will use direct problem-solving"
fi

# Check for quint plugin (structured reasoning for ultra-complex decisions)
QUINT_AVAILABLE=false
if claude plugins list 2>/dev/null | grep -q "quint"; then
  QUINT_AVAILABLE=true
  echo "✅ quint plugin detected - will use for ultra-complex decisions requiring human guidance"
else
  echo "ℹ️  quint plugin not installed - will escalate ultra-complex issues for manual review"
fi

# Ensure the labels this workflow relies on exist (GitHub backend only — the file
# backend creates labels on demand).
#
# This reconciles against `gh label list` on EVERY run rather than gating on a
# marker file. A marker was used here previously and it was committed to git, so
# `[ ! -f .github/.priority-labels-configured ]` was false in every clone,
# worktree and fork — the block had not run for anyone since 2026-02-02, and
# this repo was missing all seven blocking labels as a result. Reconciling
# against reality costs one API call, is idempotent, and cannot be defeated by
# a file landing in the repo.
if [ "$ISSUE_SOURCE" = "github" ]; then
  EXISTING_LABELS=$(gh label list --limit 200 --json name --jq '.[].name' 2>/dev/null || echo "")

  for label in "P0:Critical priority issue:d73a4a" "P1:High priority issue:ff9800" "P2:Medium priority issue:ffeb3b" "P3:Low priority issue:4caf50" "proposal:AI-generated proposal awaiting human approval:c5def5" "working:Issue currently being worked on by an agent:1d76db" "needs-approval:Architectural decisions, major changes, security implications:e99695" "needs-design:Requirements unclear, multiple approaches, needs design:fbca04" "needs-clarification:Incomplete information, missing context, questions needed:d4c5f9" "too-complex:Beyond autonomous capability, requires deep expertise:b60205" "future:Idea for future consideration, not ready for implementation:bfd4f2" "decomposed:Complex issue broken into sub-tasks:9c27b0" "subtask:Part of a larger decomposed issue:ba68c8" "awaiting-integration:Work is complete but has not reached the integration branch:0e8a16" "needs-review-focus:Larger than the review-fit limit; the digest names every hunk to read:fef2c0" "merging:A detached merge job is landing this issue on the integration branch:5319e7" "spot-check:Closed merge-mode work sampled for human review (see /spot-check):c2e0c6"; do
    IFS=':' read -r name desc color <<< "$label"
    if ! echo "$EXISTING_LABELS" | grep -qFx "$name"; then
      echo "Creating label: $name"
      gh label create "$name" --description "$desc" --color "$color" 2>/dev/null || true
    fi
  done
fi

# Step 0: Review and prioritize any unprioritized issues
echo "🔍 Checking for unprioritized issues..."
issue_list --state open --limit 100 > /tmp/all-open-issues.json

# Find issues without any priority label (P0-P3), excluding issues already being worked on
UNPRIORITIZED=$(cat /tmp/all-open-issues.json | python3 -c "
import json, sys
issues = json.load(sys.stdin)
unprioritized = [i for i in issues
                 if not any(l['name'] in ['P0','P1','P2','P3'] for l in i.get('labels',[]))
                 and not any(l['name'] == 'working' for l in i.get('labels',[]))]
for issue in unprioritized:
    print(f\"{issue['number']}|{issue['title']}|{issue.get('body', '')[:500]}\")
")

if [ -n "$UNPRIORITIZED" ]; then
  UNPRIORITIZED_COUNT=$(echo "$UNPRIORITIZED" | grep -c "^" || echo "0")
  echo "⚠️  Found $UNPRIORITIZED_COUNT unprioritized issue(s). Reviewing and assigning priorities..."
  echo ""
  echo "UNPRIORITIZED_ISSUES_FOUND=true"
  echo "UNPRIORITIZED_DATA<<EOF"
  echo "$UNPRIORITIZED"
  echo "EOF"
else
  echo "✅ All open issues have priority labels assigned"
fi

# Check if a specific issue number was provided as argument
# Usage: /fix [issue_number]
SPECIFIED_ISSUE="${1:-}"

if [ -n "$SPECIFIED_ISSUE" ]; then
  # Specific issue provided - fetch it directly
  echo "🎯 Targeting specific issue #$SPECIFIED_ISSUE"
  issue_get "$SPECIFIED_ISSUE" > /tmp/top-issue.json 2>/dev/null

  if [ $? -ne 0 ] || [ ! -s /tmp/top-issue.json ]; then
    echo "❌ Error: Issue #$SPECIFIED_ISSUE not found or not accessible"
    exit 1
  fi

  ISSUE_NUM=$(cat /tmp/top-issue.json | jq -r '.number')
  ISSUE_TITLE=$(cat /tmp/top-issue.json | jq -r '.title')
  ISSUE_BODY=$(cat /tmp/top-issue.json | jq -r '.body // ""')

  # Dependencies first: an issue whose "Depends on" / "Blocked by" issues (or
  # GitHub's native blocked-by) are still open is not ready, even when named
  # explicitly. Refuse before claiming, so no `working` label is left behind.
  # AUTOCODER_IGNORE_DEPENDENCIES=1 overrides it on purpose.
  if UNMET_DEPS=$(issue_unmet_dependencies "$ISSUE_NUM"); then :; else
    echo "⏳ Issue #$ISSUE_NUM waits on $UNMET_DEPS, still open. Not starting it."
    echo "   Work those first, or set AUTOCODER_IGNORE_DEPENDENCIES=1 to override."
    exit 1
  fi

  # #182: this worktree's own claim, resumed after compaction or a restart. The gate
  # resumes only an issue it recorded for this worktree, still `working` and still
  # ours, and switches to its branch first (or finds none locally or on origin: compacted
  # before the branch was made). Its pushed branch, start comment and claim marker are then ours,
  # so none of the lock checks below may read them as a rival's.
  RESUMING=false
  if { [ "$(git branch --show-current 2>/dev/null)" = "feature/issue-${ISSUE_NUM}" ] || \
       { ! git show-ref --verify -q "refs/heads/feature/issue-${ISSUE_NUM}" && \
         [ -z "$(git ls-remote --heads origin "feature/issue-${ISSUE_NUM}" 2>/dev/null)" ]; }; } && \
     [ "$(cut -d' ' -f1 "$(git rev-parse --absolute-git-dir 2>/dev/null)/autocoder-worker-state" 2>/dev/null)" = "$ISSUE_NUM" ] && \
     jq -e '[.labels[]?.name] | index("working") != null' /tmp/top-issue.json >/dev/null 2>&1; then
    RESUMING=true
    echo "🔁 Resuming this worktree's own claim on #$ISSUE_NUM. Re-read the issue's comments and the branch (git log origin/<integration>..HEAD) before continuing; do not redo finished work."
  fi

  # Remote branch is the strongest lock — check it before the working label.
  # A peer may have pushed the branch before the label propagated, or a manager
  # may have cleared a stale label without realising work was still in flight.
  REMOTE_BRANCH_SPEC=$(git ls-remote --heads origin "feature/issue-${ISSUE_NUM}" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$RESUMING" != "true" ] && [ "$REMOTE_BRANCH_SPEC" -gt "0" ]; then
    echo "⚠️  Remote branch feature/issue-${ISSUE_NUM} already exists — another agent owns this issue."
    echo "    To take over an abandoned branch, delete it from origin first."
    exit 1
  fi

  # Check if issue already has 'working' label (being worked on by another agent)
  IS_WORKING=$(cat /tmp/top-issue.json | jq -r '.labels | map(.name) | any(. == "working")')
  if [ "$IS_WORKING" = "true" ]; then
    TARGET_BRANCH="feature/issue-${ISSUE_NUM}"
    CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "")
    START_MARKERS=$(issue_get "$ISSUE_NUM" 2>/dev/null | jq --arg branch "$TARGET_BRANCH" '[.comments[]? | select(((.body // "") | test("Automated Fix Started|Implementation Started|Enhancement Implementation Started")) and ((.body // "") | contains($branch)))] | length' 2>/dev/null || echo "0")
    if [ "$RESUMING" != "true" ] && [ "$START_MARKERS" -gt 0 ] && [ "$CURRENT_BRANCH" != "$TARGET_BRANCH" ]; then
      echo "⚠️  Issue #$SPECIFIED_ISSUE already has a start marker on $TARGET_BRANCH - another agent is working on it"
      echo "Use '/update-issue $SPECIFIED_ISSUE --remove-label working' only after confirming the lock is stale"
      exit 1
    fi
    echo "ℹ️  Issue #$SPECIFIED_ISSUE already has 'working' label; treating it as a pre-claimed handoff"
  else
    issue_claim "$ISSUE_NUM" 2>/dev/null || {
      echo "⚠️  Could not claim issue #$ISSUE_NUM - another agent may have claimed it first"
      exit 1
    }
  fi

  # Extract priority from labels (default to P2 if no priority label)
  ISSUE_PRIORITY=$(cat /tmp/top-issue.json | jq -r '
    if (.labels | map(.name) | any(. == "P0")) then 0
    elif (.labels | map(.name) | any(. == "P1")) then 1
    elif (.labels | map(.name) | any(. == "P2")) then 2
    elif (.labels | map(.name) | any(. == "P3")) then 3
    else 2
    end
  ')

  echo "✅ Found issue #$ISSUE_NUM: $ISSUE_TITLE"

  # Claim-then-verify: the claim above (issue_claim or pre-claimed handoff check) is the
  # primary lock. For GitHub backend (non-atomic), post an early marker comment and wait
  # for competing workers to surface before proceeding. A resumed own claim (#182) has
  # no race to settle: its earlier start comment is its own.
  if [ "$RESUMING" = "true" ]; then
    :
  elif [ "${ISSUE_SOURCE:-}" = "github" ]; then
    issue_comment "$ISSUE_NUM" --body "🔒 [autocoder-claim] Starting fix for issue #${ISSUE_NUM} — lock established" 2>/dev/null || true
    sleep 3
    CLAIM_MARKER_COUNT=$(issue_get "$ISSUE_NUM" 2>/dev/null | jq \
      '[.comments[] | select(.body | test("\\[autocoder-claim\\]"))] | length' \
      2>/dev/null || echo "0")
    PRIOR_STARTED=$(issue_get "$ISSUE_NUM" 2>/dev/null | jq \
      '[.comments[] | select(.body | test("Automated Fix Started|Implementation Started|Enhancement Implementation Started")) | select(.body | test("\\[autocoder-claim\\]") | not)] | length' \
      2>/dev/null || echo "0")
    if [ "$CLAIM_MARKER_COUNT" -gt 1 ] || [ "$PRIOR_STARTED" -gt 0 ]; then
      echo "⚠️  Race: another agent claimed issue #$ISSUE_NUM. Releasing and aborting."
      issue_update "$ISSUE_NUM" --remove-label "working" 2>/dev/null || true
      exit 1
    fi
  else
    # File backend: check for orphaned start comments from prior abandoned runs.
    sleep 1
    PRIOR_STARTED=$(issue_get "$ISSUE_NUM" 2>/dev/null | jq \
      '[.comments[] | select(.body | test("Automated Fix Started|Implementation Started|Enhancement Implementation Started"))] | length' \
      2>/dev/null || echo "0")
    if [ "$PRIOR_STARTED" -gt 0 ]; then
      echo "⚠️  Issue #$ISSUE_NUM has a prior work-started comment — may be an abandoned run. Releasing and aborting."
      issue_release "$ISSUE_NUM" 2>/dev/null || issue_update "$ISSUE_NUM" --remove-label "working" 2>/dev/null || true
      exit 1
    fi
  fi
else
  # No specific issue - get highest priority issue (using labels only)
  issue_list --state open --limit 100 > /tmp/all-issues.json

  # Branch-evidence exclusion (#48): a pushed branch is a claim that survives a lost label.
  CLAIMED_BY_BRANCH=$("${SCRIPT_DIR}/claimed-issue-numbers.sh" origin)
  [ -n "$CLAIMED_BY_BRANCH" ] || CLAIMED_BY_BRANCH="[]"
  echo "ℹ️  Issues with a live remote branch (excluded from claiming): $CLAIMED_BY_BRANCH"

  # issue_list --state open has already left out issues whose dependencies
  # ("Depends on: #N" lines, GitHub blocked-by) are not closed (issue-deps.sh).
  # Filter out issues with 'working' label (being worked on by another agent)
  # Also filter out issues with blocking labels (needs human review)
  # Also filter out decomposed parent issues (work on their sub-tasks instead)
  cat /tmp/all-issues.json | jq -r --argjson claimed "$CLAIMED_BY_BRANCH" '
    .[] |
    select(
      (.labels | map(.name) | any(. == "P0" or . == "P1" or . == "P2" or . == "P3"))
      and (.labels | map(.name) | any(. == "working") | not)
      and (.labels | map(.name) | any(. == "needs-approval" or . == "needs-design" or . == "needs-clarification" or . == "too-complex" or . == "future" or . == "decomposed" or . == "awaiting-integration" or . == "merging") | not)
      and ((.number | IN($claimed[])) | not)
    ) |
    {
      number: .number,
      title: .title,
      body: (.body // ""),
      priority: (
        if (.labels | map(.name) | any(. == "P0")) then 0
        elif (.labels | map(.name) | any(. == "P1")) then 1
        elif (.labels | map(.name) | any(. == "P2")) then 2
        elif (.labels | map(.name) | any(. == "P3")) then 3
        else 4
        end
      )
    }
  ' | jq -s 'sort_by(.priority) | .[0]' > /tmp/top-issue.json

  # Build ranked list of all candidate issues (for retry on race conflict)
  cat /tmp/top-issue.json > /tmp/top-issue-single.json
  cat /tmp/all-issues.json | jq -r --argjson claimed "$CLAIMED_BY_BRANCH" '
    [.[] |
    select(
      (.labels | map(.name) | any(. == "P0" or . == "P1" or . == "P2" or . == "P3"))
      and (.labels | map(.name) | any(. == "working") | not)
      and (.labels | map(.name) | any(. == "needs-approval" or . == "needs-design" or . == "needs-clarification" or . == "too-complex" or . == "future" or . == "decomposed" or . == "awaiting-integration" or . == "merging") | not)
      and ((.number | IN($claimed[])) | not)
    ) |
    {
      number: .number,
      title: .title,
      body: (.body // ""),
      priority: (
        if (.labels | map(.name) | any(. == "P0")) then 0
        elif (.labels | map(.name) | any(. == "P1")) then 1
        elif (.labels | map(.name) | any(. == "P2")) then 2
        elif (.labels | map(.name) | any(. == "P3")) then 3
        else 4
        end
      )
    }] | sort_by(.priority)
  ' > /tmp/candidate-issues.json

  CANDIDATE_COUNT=$(cat /tmp/candidate-issues.json | jq 'length')

  # Try each candidate issue in priority order until we successfully claim one
  ISSUE_CLAIMED=false
  for idx in $(seq 0 $((CANDIDATE_COUNT - 1))); do
    ISSUE_NUM=$(cat /tmp/candidate-issues.json | jq -r ".[$idx].number")
    ISSUE_TITLE=$(cat /tmp/candidate-issues.json | jq -r ".[$idx].title")
    ISSUE_BODY=$(cat /tmp/candidate-issues.json | jq -r ".[$idx].body")
    ISSUE_PRIORITY=$(cat /tmp/candidate-issues.json | jq -r ".[$idx].priority")

    if [ "$ISSUE_NUM" = "null" ] || [ -z "$ISSUE_NUM" ]; then
      continue
    fi

    # Remote branch is a stronger lock than the working label: a worker may have pushed
    # the branch before the label propagated, or the label may have been cleaned by a
    # manager who thought the issue was stale. Skip immediately if the branch exists.
    REMOTE_BRANCH_EXISTS=$(git ls-remote --heads origin "feature/issue-${ISSUE_NUM}" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$REMOTE_BRANCH_EXISTS" -gt "0" ]; then
      echo "⚠️  Remote branch feature/issue-${ISSUE_NUM} already exists — skipping issue #$ISSUE_NUM"
      continue
    fi

    # Claim-then-verify: claim IMMEDIATELY, then check for race
    issue_claim "$ISSUE_NUM" 2>/dev/null
    claim_rc=$?
    if [ "$claim_rc" -ne 0 ]; then
      echo "⚠️  Lost claim race on issue #$ISSUE_NUM (file backend: atomic rename lost). Trying next issue..."
      continue
    fi

    # For file backend: the atomic rename above is the definitive lock — skip the
    # extended race check. For GitHub backend (non-atomic label add), post an early
    # marker comment NOW so concurrent workers can detect the collision within the
    # settlement window, then sleep long enough for their markers to appear.
    if [ "${ISSUE_SOURCE:-}" = "github" ]; then
      issue_comment "$ISSUE_NUM" --body "🔒 [autocoder-claim] Starting fix for issue #${ISSUE_NUM} — lock established" 2>/dev/null || true
      sleep 3

      # Count autocoder-claim markers. If more than one exists, two workers raced.
      # Both back off — the issue returns to open/ and gets claimed cleanly next tick.
      CLAIM_MARKER_COUNT=$(issue_get "$ISSUE_NUM" 2>/dev/null | jq \
        '[.comments[] | select(.body | test("\\[autocoder-claim\\]"))] | length' \
        2>/dev/null || echo "0")
      # Also check for existing work-started comments from a prior abandoned run.
      PRIOR_STARTED=$(issue_get "$ISSUE_NUM" 2>/dev/null | jq \
        '[.comments[] | select(.body | test("Automated Fix Started|Implementation Started|Enhancement Implementation Started")) | select(.body | test("\\[autocoder-claim\\]") | not)] | length' \
        2>/dev/null || echo "0")

      if [ "$CLAIM_MARKER_COUNT" -gt 1 ] || [ "$PRIOR_STARTED" -gt 0 ]; then
        echo "⚠️  Race condition on issue #$ISSUE_NUM (markers: $CLAIM_MARKER_COUNT, prior: $PRIOR_STARTED). Releasing and trying next..."
        issue_update "$ISSUE_NUM" --remove-label "working" 2>/dev/null || true
        continue
      fi
    else
      # File backend: brief pause to detect orphaned start comments from prior abandoned runs.
      sleep 1
      PRIOR_STARTED=$(issue_get "$ISSUE_NUM" 2>/dev/null | jq \
        '[.comments[] | select(.body | test("Automated Fix Started|Implementation Started|Enhancement Implementation Started"))] | length' \
        2>/dev/null || echo "0")
      if [ "$PRIOR_STARTED" -gt 0 ]; then
        echo "⚠️  Issue #$ISSUE_NUM has a prior work-started comment — may be an abandoned run. Releasing and trying next..."
        # File backend: release moves the file back from working/ to open/
        issue_release "$ISSUE_NUM" 2>/dev/null || issue_update "$ISSUE_NUM" --remove-label "working" 2>/dev/null || true
        continue
      fi
    fi

    ISSUE_CLAIMED=true
    break
  done

  if [ "$ISSUE_CLAIMED" != "true" ]; then
    echo "ℹ️  No available priority issues found"
    echo "   All issues may be: claimed by other agents, or blocked (needs human review)"
    echo "   Use '/review-blocked' to review and approve blocked issues"

    echo "IDLE_NO_WORK_AVAILABLE"
    exit 0
  fi
fi

echo ""
echo "🎯 Highest Priority Issue to Fix"
echo "════════════════════════════════════════"
echo "Issue: #$ISSUE_NUM"
echo "Priority: P$ISSUE_PRIORITY"
echo "Title: $ISSUE_TITLE"
echo ""
# The spec is the body plus the comment thread (#134); print all of it.
ISSUE_SPEC=$("${SCRIPT_DIR}/issue-spec.sh" "$ISSUE_NUM") || {
  echo "⚠️  Could not read the comment thread for #$ISSUE_NUM — showing the body only. Read the comments yourself before writing code."
  ISSUE_SPEC="$ISSUE_BODY"
}
echo "Specification (body, then comments — a later comment overrides the body):"
echo "$ISSUE_SPEC"
echo ""
echo "════════════════════════════════════════"
echo ""
echo "📋 Starting work on issue #$ISSUE_NUM..."
echo ""

# ── Task scope gate ──────────────────────────────────────────────────────────
# MANDATORY: Before creating the branch, assess whether this task fits in one
# agent context window and whether it can run safely in a worktree swarm.
#
# Ask yourself:
#   1. CONTEXT FIT: Can all required reading, reasoning, and implementation
#      complete in a single conversation without hitting context limits?
#      Red flags: "rewrite the authentication system", "migrate all API calls",
#      "audit every file in src/", tasks described in >1000 chars with no
#      clear single deliverable.
#
#   2. WORKTREE INDEPENDENCE: Can this work in an isolated worktree without
#      conflicting with other parallel worktrees working other issues?
#      Red flags: changes to shared config files (tsconfig.json, package.json,
#      migrations, schema files) that other agents might also need to change;
#      or changes that require knowing the final state of another in-flight issue.
#      A sub-task that touches the same file as a sibling sub-task is NOT
#      independent — it must be sequenced, not parallelized.
#
#   3. REVIEW FIT: Can a human review the result? Estimate the change, NOT
#      counting parity mirrors (.agent/, plugins/*/skills/, codex-plugins/,
#      .factory/). If it is likely to exceed reviewFit.maxChangedLines (default
#      400 changed lines) or reviewFit.maxFiles (default 10) in .autocoder.json,
#      it fails this test. This is the ONLY point where work is split for size:
#      finished work over the limit is published anyway, labelled
#      `needs-review-focus` (see "Review Digest" below), never split after the fact.
#
# If this issue FAILS any test → DECOMPOSE IT NOW (before branch creation):
#   - Decompose into 3-8 sub-tasks, each satisfying all three criteria above
#   - Create each sub-task as a new issue with `subtask` label and a
#     "Sub-task of #${ISSUE_NUM}" line in the body
#   - Add the `decomposed` label to this parent issue and release the claim
#   - Exit; workers will pick up the independent sub-tasks on the next tick
#
# If this issue PASSES all three tests → proceed to branch creation immediately.
#
# See autocoder:references/fix-decomposition.md ("Ultra-Complex Issues - Decompose into Sub-Tasks")
# for the full decomposition protocol including sub-task body template.
# ────────────────────────────────────────────────────────────────────────────

# Branch from the latest shared integration branch (NOT the worktree's current branch).
# In a parallel-worktree swarm each worktree sits on its own main-wt-N; basing the fix
# branch on origin/<integration> instead means every fix starts from — and merges back
# to — the same shared branch, so work converges on main instead of stranding on main-wt-N.
INTEGRATION_BRANCH="${INTEGRATION_BRANCH:-$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')}"
INTEGRATION_BRANCH="${INTEGRATION_BRANCH:-main}"
git fetch origin "$INTEGRATION_BRANCH" || {
  echo "❌ Cannot fetch origin/${INTEGRATION_BRANCH} — refusing to start work from stale state."
  issue_update "$ISSUE_NUM" --remove-label "working" 2>/dev/null || true
  exit 1
}

# Create (or switch to) the fix branch, then pull the latest integration state into it.
# Never start work on the parent branch: a 'working' label with no matching
# feature/issue-N branch looks like a stale/abandoned lock to peers and to
# /monitor-workers, which then try to reclaim the issue out from under you.
FIX_BRANCH="feature/issue-${ISSUE_NUM}"
if git checkout -b "$FIX_BRANCH" "origin/${INTEGRATION_BRANCH}" 2>/dev/null; then
  echo "✅ Created $FIX_BRANCH from origin/${INTEGRATION_BRANCH}"
elif git checkout "$FIX_BRANCH" 2>/dev/null; then
  # Branch already exists — pull latest integration changes into it before resuming
  echo "ℹ️  Branch $FIX_BRANCH already exists; pulling latest from origin/${INTEGRATION_BRANCH}..."
  git pull --rebase origin "$INTEGRATION_BRANCH" || {
    if [ "${RESUMING:-false}" = "true" ]; then
      # A resumed claim keeps its lock through a conflict. After a merge job bounced
      # it back (#207/#208) the conflict IS the work: resolve it here, keeping both
      # sides' behaviour, `git rebase --continue`, re-run the tests, and carry on to
      # the review gate and relaunch. Releasing would strand the live branch.
      echo "⚠️  Rebase of $FIX_BRANCH conflicts (resumed claim #${ISSUE_NUM}). Conflicting files:"
      git diff --name-only --diff-filter=U
      echo "   Resolve them keeping both sides' behaviour, run 'git rebase --continue', then continue this issue. Keeping 'working'."
      exit 2
    fi
    echo "❌ Rebase of $FIX_BRANCH onto origin/${INTEGRATION_BRANCH} failed — resolve conflicts manually."
    issue_update "$ISSUE_NUM" --remove-label "working" 2>/dev/null || true
    exit 1
  }
else
  echo "❌ Could not create or switch to $FIX_BRANCH."
  issue_update "$ISSUE_NUM" --remove-label "working" 2>/dev/null || true
  exit 1
fi
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ "$CURRENT_BRANCH" != "$FIX_BRANCH" ]; then
  echo "❌ Branch switch verification failed (still on $CURRENT_BRANCH)."
  issue_update "$ISSUE_NUM" --remove-label "working" 2>/dev/null || true
  exit 1
fi

# 'working' label was already added during claim-then-verify above

# Post the work-started comment. Together with the branch above, this is the durable
# proof the lock is live — peers and /monitor-workers key off the branch + this comment
# to tell an active lock apart from a stale one. Do not skip it for any issue type.
issue_comment "$ISSUE_NUM" --body "🤖 **Automated Fix Started**

Starting automated fix for this issue.

**Branch**: \`feature/issue-${ISSUE_NUM}\`
**Implementation Started**: $(date)

Fix in progress..." 2>/dev/null || true

echo "✅ Created branch: feature/issue-${ISSUE_NUM}"
echo "✅ Added 'working' label (concurrency lock)"
echo "✅ Posted GitHub comment"
echo ""

```

**⚠️ The claim sequence above (working label → `feature/issue-<N>` branch → work-started comment) is mandatory and runs FIRST for every issue — bug OR enhancement.** Do not begin triage analysis, brainstorming, or implementation until all three exist. Priority-labeled enhancements (P0–P3) are handled by this standard path, **not** by the "No Priority Issues Found → 5C" flow (that flow only applies when there are no priority issues left). If you ever notice you are editing files while still on the parent branch (`main`, `main-wt-N`, etc.), stop immediately and run the claim sequence — committing on the parent branch strands the `working` lock with no matching branch and makes peers treat it as stale.

**Build from the body *and* the comments — a later comment overrides the body.** The specification printed above (`issue-spec.sh`) is the issue body followed by every comment, oldest first, with autocoder's claim and work-started markers filtered out. Review deltas, corrected API contracts, narrowed scope and "that earlier instruction was wrong" all arrive as comments, so the body alone is the stalest spec on the page (#134). Read the whole thread before writing code, and re-read it (`issue-spec.sh "$ISSUE_NUM"`) immediately before launching the merge, in case a correction landed while you worked. In the merge summary or PR body, name the comment you built to (e.g. "built to comment 3 by `<author>`, which supersedes the body's `onConflict` default"), or say "body only — no correcting comments" — so a worker that missed a correction is caught in review, not after merge.

## First-Run: Configure Merge Mode

Moved to `autocoder:references/fix-first-run.md` (#240). Read it when the configuration block prints `MERGE_MODE_NOT_CONFIGURED=true`.

## CRITICAL: Release the 'working' Label Only on a Terminal Outcome

The `working` label is the concurrency lock. It is held for the **whole life of
the claim**, not per commit. An open issue with no `working` label is, by
definition, claimable — so dropping the lock while the issue is still open and
still yours re-exposes it to the pool and invites a peer to duplicate your work.

**Release the lock ONLY when the claim has actually ended:**

| Terminal outcome | Release? | Also required |
|---|---|---|
| Issue closed (merged / resolved) | ✅ yes | — |
| PR opened (`pr` merge mode) | ✅ yes — as a hand-off | swap `working` for `awaiting-integration` in the same step, so the issue stays out of the claimable pool until the merge closes it |
| Merge launched (`merge` merge mode) | ✅ yes — as a hand-off | the detached job (`merge-launch.sh --own-issue`) swaps `working` for `merging` itself as its first act; this worker writes NO label after the launch returns. The job retires `merging` when it closes the issue, parks it under `awaiting-integration` (landed but not provably green, or not yet shipped), or escalates it to `needs-clarification`; the sentinel re-queues it if the job dies |
| Blocked (`needs-design`, `needs-clarification`, `needs-approval`, `too-complex`, `future`) | ✅ yes | post a release comment in the same step |
| Deliberately skipped or abandoned | ✅ yes | post a release comment in the same step |
| Could not switch to the feature branch (claim never started) | ✅ yes | — |

**NEVER release the lock for any of these:**

- After a **partial** commit, or a commit titled `#N (partial): …`
- Between batches of an implementation plan
- Because you are compacting context, pausing, or handing off mid-issue
- Because you *think* you are done — "done" means the issue is **CLOSED**, not
  "the last commit landed"
- Because you are moving on to another issue while this one is still open —
  that is an abandonment, so release it via the explicit-release path below
  (with a comment), not silently

```bash
# Correct: terminal outcome only, and only after the publication gate
# (PUSH_OK / merge-to-integration.sh) has passed. Pair the release with the close.
issue_close "$ISSUE_NUM" --comment "✅ Resolved — <summary>"
issue_update "$ISSUE_NUM" --remove-label "working" 2>/dev/null || true
```

```bash
# WRONG — this is issue #14. The issue is still OPEN, so removing the lock
# hands it straight back to the claimable pool while you still hold the branch.
git commit -m "#${ISSUE_NUM} (partial): first half of the refactor"
issue_update "$ISSUE_NUM" --remove-label "working" 2>/dev/null || true
```

### Explicit release (blocked, skipped, or abandoned)

A release that is not a close must be **visible**, so peers and
`/monitor-workers` can tell a deliberate hand-off from a crashed worker. Always
comment first, then drop the label:

```bash
issue_comment "$ISSUE_NUM" --body "🔓 **Releasing claim**

**Reason**: <blocked on X | skipped because Y | abandoning, see below>
**Branch**: \`feature/issue-${ISSUE_NUM}\` (<pushed | discarded>)
**State left behind**: <what is done, what remains>

Releasing the \`working\` lock so another agent can pick this up."
issue_update "$ISSUE_NUM" --remove-label "working" 2>/dev/null || true
```

**Never add a blocking label without also releasing the lock.** `add-blocking-label.sh`
does both for you; if you add `needs-design`, `too-complex`, `needs-clarification`,
`needs-approval`, or `future` directly via `issue_update` or `/update-issue`, you
must remove `working` and post the release comment in the same step.

### Holding the lock across a pause

If you are still working the issue — mid-plan, compacting context, resuming next
iteration — **keep the label**. The `feature/issue-<N>` branch plus the
work-started comment are the proof the lock is live. An abandoned lock is not
your problem to clean up mid-flight: `/monitor-workers` detects locks with no
agent activity and reclaims them with human confirmation.

## Pre-Landing Review Gate (MANDATORY)

**Order: trial-rebase first, then review (#222).** The shared landing section ("Landing the Work") rebases onto
the integration branch before its review check. A rebase that moves HEAD invalidates the
review record, so run that trial rebase *before* this gate. Reviewing first and rebasing
after means reviewing twice.

Tests prove the change does what its tests check; they say nothing about whether
it does what the issue asked, stays in scope, or opens a hole. Every landing
site below runs this gate **after the final commit and before the push** — so
before `merge-launch.sh` in `merge` mode and before `gh pr create` in `pr` mode
(#147). The landing code refuses to publish unless the review record for the
**current `HEAD`** says `Verdict: pass`. The record is a file inside `.git/`,
not a shell variable, so it survives across tool calls, is per-repo, and goes
stale the moment another commit lands on the branch.

**Setting.** `.autocoder.json` `"review"`: `"always"` (default — both modes),
`"merge-only"` (skip in `pr` mode, where a human reviews), or `"off"`. A skipped
review still writes a record saying so, so the trail shows it was skipped and
not forgotten.

**Risk tiers (#165).** `.autocoder.json` may list high-risk path globs:
`"risk": {"high": [".github/workflows/**", "**/install*.sh"]}`. Each landing
block asks `landing-mode.sh` how to land: a diff that touches any of those paths
lands as a pull request (and parks under `awaiting-integration`) even when Merge
Mode is `merge`; every other diff lands as configured. The globs are read from
the integration branch, not the working tree, so a branch cannot lower its own
tier, and `.autocoder.json` itself counts as high-risk while any are set. `*`
stays within one path segment and `**` spans directories. With no `risk` key,
nothing changes. This review never counts as the human approval a high-risk
change needs.

```bash
# The issue being landed: ISSUE_NUM, or ENHANCE_NUM in the enhancement flow.
REVIEW_ISSUE="${REVIEW_ISSUE:?set REVIEW_ISSUE to the issue being landed (ISSUE_NUM, or ENHANCE_NUM for an enhancement)}"
REVIEW_FILE="$(git rev-parse --git-common-dir)/autocoder-review-${REVIEW_ISSUE}.md"
REVIEW_SETTING=$(python3 -c "import json; print(str(json.load(open('.autocoder.json')).get('review','always')).lower())" 2>/dev/null || echo always)
git fetch -q origin "${INTEGRATION_BRANCH:?INTEGRATION_BRANCH unset — re-run the configuration block above}"
REVIEW_BASE=$(git merge-base HEAD "origin/${INTEGRATION_BRANCH}") \
  || { echo "❌ cannot find the merge base with origin/${INTEGRATION_BRANCH} — nothing to review against"; exit 1; }
rm -f "$REVIEW_FILE"   # never inherit an earlier attempt's verdict
# Same reading as the landing code: only an exact "pr" takes the PR path, so only
# "pr" may skip under merge-only. An unset mode must fail, not default to a skip.
REVIEW_MODE="${MERGE_MODE:?MERGE_MODE unset — re-run the configuration block above}"
if [ "$REVIEW_SETTING" = "off" ] || { [ "$REVIEW_SETTING" = "merge-only" ] && [ "$REVIEW_MODE" = "pr" ]; }; then
  printf '## Review\nSkipped: `.autocoder.json` review=%s (merge mode %s).\n\nReviewed-HEAD: %s\nVerdict: pass\n' \
    "$REVIEW_SETTING" "$REVIEW_MODE" "$(git rev-parse HEAD)" > "$REVIEW_FILE"
fi
git diff --name-only "$REVIEW_BASE"..HEAD   # the paths under review
```

**1. Review in a fresh context.** Self-review in the session that wrote the code
inherits its blind spots. Run `/code-review` on the branch (or `ce-code-review` /
`superpowers:requesting-code-review` per the skill table above). Where none is
available, launch fresh subagents with no shared context — 2–3 in parallel at
`$FAST_MODEL`, each with one lens and told to refute the change: **correctness**,
**scope creep**, **security**. Give every reviewer the same three inputs: the
diff (`git diff "$REVIEW_BASE"..HEAD`), the repo (to read callers and
neighbouring code), and the issue's title, body and comments (the intent the
diff must satisfy). If the repo has a `REVIEW.md` at its root, give it to every
reviewer too, as the repo's review rules (#169): what failure looks like there,
the nit cap, paths to skip, and how to write findings. Where it and this gate
differ, the gate's tags and blocking rules still decide what blocks landing.
`/install` writes a starter `REVIEW.md` (`scaffold-review-md.sh`).

**2. Security review on sensitive diffs.** If any changed path is sensitive,
also run `/security-review` (or a fresh security-lens subagent where it is not
available). Sensitive means: the `risk.high` globs in `.autocoder.json` when
present (#165), otherwise CI workflows (`.github/workflows/**`), hooks,
install/setup scripts, merge/push/sentinel scripts, auth, credentials or secret
handling, crypto, and dependency manifests or lockfiles.

**3. Tag every finding** exactly one of:

| Tag | Meaning | Action |
|---|---|---|
| **Important** | A real defect, scope violation or security problem **introduced by this diff** | Fix it, or answer it with a concrete reason it does not apply. **Blocks landing while open.** |
| **Nit** | Style or preference | Fix if trivial; never blocks |
| **Pre-existing** | Real, but present before this diff | File it with `/record-issue` (link the finding); **do not** fix it here — that widens the diff |

**4. Converge — at most 3 review-and-fix rounds (#166).**

- **Round 1** reviews the whole diff. **Rounds 2–3** review only what changed
  since the last review (`git diff <last-reviewed-sha>..HEAD`), plus whether each
  earlier Important finding is actually resolved.
- **Never repeat a finding.** Keep the running findings list and pass it to each
  later round; a finding already raised is either resolved or still open, not new.
- **Fix the class, not the instance.** For each Important finding, name the bug
  class (e.g. "unquoted variable in a path", "label write without lock release")
  and grep the diff for every other instance before the next round.
- **A finding that keeps coming back across issues is a missing rule.** If
  reviewers raise the same kind of finding again and again, record it with
  `/record-issue` proposing where the rule should live: a line in `REVIEW.md`, a
  lint or test check, or a skill. Don't widen this diff to add it.
- Commit each round's fixes, then re-run the targeted tests before re-review.
- **Still an open Important finding after round 3** → stop. The approach itself
  may be wrong. Do **not** land, and do **not** push `feature/issue-N`: any
  remote branch named `issue-<N>` is a claim lock (`claimed-issue-numbers.sh`)
  and would keep the issue unclaimable after a human resolves the design
  question. Push the work to `escalated/review-<N>` instead, which is not a
  lock, so the human can read the diff and it survives the worker. Escalate with
  `add-blocking-label.sh`, which posts the reason and releases the `working`
  lock in one step. It rejects any reason containing `[lowercase…]` as an
  unfilled placeholder, so write findings as plain `file:line — problem`:

```bash
git push origin "HEAD:refs/heads/escalated/review-${REVIEW_ISSUE}" \
  || echo "⚠️  could not push escalated/review-${REVIEW_ISSUE}; the work is only on the local branch"
bash "${SCRIPT_DIR:?SCRIPT_DIR unset — re-run the setup block above}/add-blocking-label.sh" "$REVIEW_ISSUE" "needs-design" \
  "Review did not converge in 3 rounds. Open Important findings: <each as file:line — problem>. Question: is this the right approach? The work is on branch escalated/review-${REVIEW_ISSUE}." \
  || { echo "❌ escalation failed — the issue still holds 'working'; fix the reason text and retry"; exit 1; }
```

**5. Record the outcome.** Write the record — it is appended to the merge
job's close comment (`merge` mode) or the PR body (`pr` mode). Write
`Verdict: pass` only when every Important finding is Fixed or Answered; any
commit after this invalidates the record and the review must be re-run:

```bash
cat > "$REVIEW_FILE" <<'REVIEW'
## Review
Rounds: <n> · Reviewer: </code-review | subagents: correctness, scope, security> · Security review: <ran | not needed — no sensitive paths>

| # | Tag | Finding | Resolution |
|---|---|---|---|
| 1 | Important | <file:line — what is wrong> | Fixed in <sha> / Answered: <reason> |
| 2 | Pre-existing | <…> | Filed as #<n> |
| 3 | Nit | <…> | Fixed / Left: <reason> |
REVIEW
printf '\nReviewed-HEAD: %s\nVerdict: pass\n' "$(git rev-parse HEAD)" >> "$REVIEW_FILE"
```

## Verify Before Claiming (MANDATORY)

Verification is a required step, not an optional skill (#170). Before you fill
the Review Digest below, on the final committed `HEAD`:

1. Run `$TEST_COMMAND` (and any targeted tests for the change) and read the
   actual result. A suite you did not run, or whose summary you did not read,
   is not evidence.
2. Copy the exact command and its result lines into the digest's
   **Verification** section: the command on a line starting with `$ `, its
   output on the lines after it. The renderer refuses a Verification section
   without both, for any change that has a diff.
3. Anything the tests do not exercise goes under **Not verified / confidence**.

`superpowers:verification-before-completion`, when installed, helps with this
step; it does not replace it.

The digest also carries two lines you do not write: **Risk** (the tier from
`landing-mode.sh`, #165) and **How to revert** (`git revert` over the branch's
commits, or the merge revert for a PR; the merge job adds the exact landed range
to its close comment). If undoing the change takes more than a revert (a data
migration, a config rollout), add a `## How to revert` section to the sections
file; it is printed after the computed line.

## Review Digest (MANDATORY)

Every place this command publishes work (a PR body in `pr` mode, the merge
job's close comment in `merge` mode, a decomposed parent's rollup close) uses
**one** body, rendered by `render-review-digest.sh` (#196). Write the prose into a
sections file, then render it. The script computes **Size** itself and exits
non-zero while any slot is unfilled. Every publish site below stops if it fails,
so a placeholder body can never ship.

```bash
DIGEST_SECTIONS="$(git rev-parse --git-common-dir)/autocoder-digest-${REVIEW_ISSUE:-$ISSUE_NUM}.md"
cat > "$DIGEST_SECTIONS" <<'DIGEST'
## Intent
{{FILL: one sentence: what problem this solves and for whom}}

## Where to look
{{FILL: the 1-3 hunks (file:line) where a mistake would matter; label everything
else "mechanical" with a one-line reason, e.g. "mirrors: byte-identical copies"}}

## Verification
{{FILL: the exact commands you ran and their actual result lines, e.g.
"$ bash tests/run-shell-suite.sh" then "Tests: 0 failed, 60 passed, 60 total"}}

## Not verified / confidence
{{FILL: what you did not exercise, known risks, and confidence: high|medium|low}}
DIGEST
# Only when the renderer asks for it (insertions > 3x deletions and > 200 lines):
#   printf '\n## Why net growth\n%s\n' "one sentence" >> "$DIGEST_SECTIONS"
```

Replace every `{{FILL: ...}}` slot, including the hint, with real content. The
renderer refuses a body that still contains one, so a forgotten slot stops the
publish instead of shipping. It does not police anything else you write: `Vec<T>`,
`<sha>` and `[links](url)` are fine.

**REVIEW FIT after implementation.** Before publishing, check the size the
reviewer will face. Over the limit, **always publish anyway**: add
`needs-review-focus` and make **Where to look** name every non-mechanical hunk.
Never split finished work. There is no protocol for that, and improvising one
risks losing verified work or leaving the claim half-released.

```bash
SIZE_LINE=$(bash "${SCRIPT_DIR}/render-review-digest.sh" --size-only --base "origin/${INTEGRATION_BRANCH}")
echo "Review size: $SIZE_LINE"
case "$SIZE_LINE" in
  *over=yes*) issue_update "${REVIEW_ISSUE:-$ISSUE_NUM}" --add-label "needs-review-focus" 2>/dev/null || true ;;
esac
```

`needs-review-focus` is informational. It is not a blocking label and must never
be added to a claimable-filter list.

## Fixing Strategy

### Step 1: Assess Complexity

Analyze the issue and determine if it's simple or complex:

**Simple Issue Indicators**:
- Description < 500 chars
- Single component/file mentioned
- Clear, specific fix described
- No test failures OR < 5 test failures
- Keywords: "hide", "timeout", "remove", "add field", "typo"

**Complex Issue Indicators**:
- Description > 1000 chars
- Multiple failing tests (>10)
- Multiple components involved
- Requires design/architecture
- Keywords: "implement", "system", "management", "integration", "~30 failures"

**Conflict hotspots** (check before you start):
- If your change has to edit a file other workers keep editing (it conflicted recently, or another open
  branch touches it: `git diff --name-only origin/<integration>...origin/feature/*`), keep your edit there
  as **small and additive** as you can. Put new logic in a **new file or module** and hook it in with a
  one-line registration or import, rather than growing the shared file's central functions.
- If the file has no seam to add to (one giant dispatch, render or route function that every feature must
  edit), say so in a comment on the issue and suggest a decomposition, so the manager can file it (see
  monitor-workers Step 5d). Don't do a large split of a shared file as a side effect of an unrelated issue.
- **Always rebase onto the integration branch immediately before launching the merge**, resolve any
  conflicts yourself keeping both sides' behaviour, and re-run the full test suite. A conflict reported
  by the merge job means rebase again and re-launch. It is not a `needs-clarification` question for the
  human. Escalate only if the same conflict returns twice.

**Rebase early and often (#222).** Do not branch once and integrate only at the end:
while you work, the integration branch moves, and every sibling landing adds conflict
risk that surfaces all at once in the merge job. After each commit, and whenever the
integration branch has moved while you are between steps, rebase and resolve any
conflict while it is small and the context is fresh:

```bash
git fetch -q origin "$INTEGRATION_BRANCH" && git rebase "origin/${INTEGRATION_BRANCH}" \
  || { git diff --name-only --diff-filter=U; echo "resolve, git rebase --continue, re-run the targeted tests"; }
```

The shared landing section also does a trial rebase right before its review check.

**Declare the areas you edit: keep `Touches:` current (#229).** The fix-loop gate
steers other workers away from files a claimed issue holds (`claims.avoid_overlap`,
`touches-fns.sh`), using a `Touches:` line in the issue body: comma-separated paths,
directories (a trailing `/` covers everything under it) or globs, e.g.
`Touches: src/web/village/, src/web/server.rs`. With no such line, the backticked
paths of a `## Files Affected` section count instead. An issue that declares nothing
overlaps nothing, so it gets no protection.

- **When you start** an issue with no `Touches:` line, add one once you have read
  the code and know which files you expect to change.
- **After each commit**, bring it up to date. Declared entries are kept; every file
  the branch actually changed (`git diff --name-only origin/<integration>...HEAD`)
  that they do not cover is added, three or more files in one directory collapsed
  to that directory.

```bash
# Touches: (#229). On the GitHub backend this rewrites the line in the issue body;
# other backends have no body edit verb, so it prints the line to add by hand.
# On start, before the first commit (the areas you expect to edit):
"${SCRIPT_DIR}/touches-set.sh" "$ISSUE_NUM" --base "origin/${INTEGRATION_BRANCH}" \
  --declare "src/web/village/, src/web/server.rs"
# After each commit:
"${SCRIPT_DIR}/touches-set.sh" "$ISSUE_NUM" --base "origin/${INTEGRATION_BRANCH}"
```

### Step 2A: Simple Issue - Direct Fix

For simple issues, proceed directly:

1. Read relevant code files to understand the root cause
2. Implement a complete fix (not partial)
3. Run targeted tests to verify the fix works
4. Create a git commit with the changes
5. Trial-rebase onto the integration branch ("Landing the Work", after Step 3, does it), then run the Pre-Landing Review Gate (above) on the rebased HEAD and resolve its findings
6. Mark as complete

```bash
# After fixing simple issue:
git add -A
# Title "#N: ...", never "Fix #N": a closing keyword closes the issue before the merge job reports (#209).
git commit -m "#${ISSUE_NUM}: Brief description

Detailed explanation of what was fixed and how.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>"

# Land it: skip Step 3 and go straight to "Landing the Work", which runs the rebase, review check, push and merge.
LAND_NUM="$ISSUE_NUM"; LAND_BRANCH="feature/issue-${ISSUE_NUM}"; LAND_TITLE="$ISSUE_TITLE"; LAND_BODY="$ISSUE_BODY"
```

### Step 2B: Complex Issue - Use Superpowers (if available)

Moved to `autocoder:references/fix-complex-issues.md` (#240). Read it when Step 1 rates the issue complex: it walks debugging, brainstorming, planning, execution and verification. Then continue with Step 3 below.

### Step 3: Commit and Close

After verification passes, and before the branch is banked (pushed, READY'd or handed to
`merge-to-integration.sh`), apply the **pre-merge rule**. The gate's job is to test, not to
merge: a branch that arrives already merged with the integration branch spends no gate pass
on a conflict, and a train that is launched right after the hotfixes have landed spends no
pass re-syncing (a five-branch train once took 65 minutes in three re-sync passes).

1. **Merge the freshly fetched integration branch into the branch first, with the merge
   drivers installed** (`git fetch origin && git merge origin/<integration>`, or a rebase onto
   it), build and run the cheap prefix on the combined tree, and only then push and READY.
   A READY branch has already absorbed the integration branch; the gate only tests it.
2. **When the train planner reports `does not merge clean onto master plus the train so far
   (<file>)`**, the branch conflicts with a sibling already on the train, not with the
   integration branch. The owner (or the manager) pre-merges the branch onto that sibling's
   tip in a scratch worktree, resolves it there, pushes with `--force-with-lease`, and
   re-READYs **with its own branch named first in backticks** (the queue takes the first
   backticked branch that exists on origin from the newest READY comment, and it can pick a
   sibling's branch out of a manager comment that named the sibling first). After
   the sibling lands, a rebase onto the integration branch drops the duplicate commits by
   patch-id. Such skips (a shared generated section, a registry row) clear in minutes this way.
3. **Trains for an operator-priority item are small** (3 to 4 members) **and are launched
   right after the hotfix landings, never before them**: every landing under a running gate is
   a re-sync pass over the whole train, so padding the priority item with more branches, or
   launching while a hotfix is about to land, buys only churn.
4. **Never `pgrep -f` a pattern your own command line contains when killing a stale run.**
   `pkill -f merge-to-integration` from a shell whose own command mentions that name kills
   the shell; name the pid from the pidfile (`/tmp/autocoder-merge-<issue>.pid`) or bracket
   the pattern (`merge-to-integratio[n]`).

Then:

```bash
# Commit changes
git add -A
# Title "#N: ...", never "Fix #N": a closing keyword closes the issue before the merge job reports (#209).
git commit -m "#${ISSUE_NUM}: Brief description

Detailed multi-line explanation of:
- Root cause analysis
- Solution approach
- Changes made
- Verification results

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>"

# Land it: "Landing the Work" below runs the rebase, review check, push and merge.
LAND_NUM="$ISSUE_NUM"; LAND_BRANCH="feature/issue-${ISSUE_NUM}"; LAND_TITLE="$ISSUE_TITLE"; LAND_BODY="$ISSUE_BODY"
```

### Landing the Work (Step 2A, Step 3 and 5D all end here)

Every flow lands through this one block (#242). The flow you came from has committed its
work and set four variables. Run its commit block first, then this one:

| Flow | `LAND_NUM` | `LAND_BRANCH` | `LAND_TITLE` / `LAND_BODY` |
|---|---|---|---|
| Step 2A, Step 3 (bug fix) | `$ISSUE_NUM` | `feature/issue-${ISSUE_NUM}` | `$ISSUE_TITLE` / `$ISSUE_BODY` |
| 5D (approved enhancement) | `$ENHANCE_NUM` | `enhancement/issue-${ENHANCE_NUM}-auto` | `$ENHANCE_TITLE` / `$ENHANCE_BODY` |

`REVIEW_ISSUE` in the Pre-Landing Review Gate and the Review Digest is the same number as `LAND_NUM`.

```bash
: "${LAND_NUM:?set LAND_NUM, LAND_BRANCH, LAND_TITLE and LAND_BODY in the flow's commit block first}"
: "${LAND_BRANCH:?set LAND_BRANCH in the flow's commit block first}"
: "${LAND_TITLE:?set LAND_TITLE in the flow's commit block first}"

# Trial rebase (#222): rebase before the review check, then review the rebased HEAD.
git fetch -q origin "${INTEGRATION_BRANCH:?INTEGRATION_BRANCH unset — re-run the configuration block above}"
if ! git rebase "origin/${INTEGRATION_BRANCH}"; then
  echo "⚠️  Rebase of #${LAND_NUM} onto origin/${INTEGRATION_BRANCH} conflicts in:"; git diff --name-only --diff-filter=U
  echo "   Resolve keeping both sides' behaviour, git rebase --continue, re-test, then re-run this block."
  exit 2
fi

# Pre-landing review gate (#147, #166): nothing publishes until the record for this HEAD says pass.
REVIEW_FILE="$(git rev-parse --git-common-dir)/autocoder-review-${LAND_NUM}.md"
if ! grep -qx "Reviewed-HEAD: $(git rev-parse HEAD)" "$REVIEW_FILE" 2>/dev/null \
   || ! grep -qx "Verdict: pass" "$REVIEW_FILE"; then
  echo "❌ No passing review for this HEAD of #${LAND_NUM} — run the Pre-Landing Review Gate, then re-run this block"
  exit 1
fi

# Landing mode by diff risk (#165): a diff touching a `risk.high` glob lands as a PR.
LANDING_MODE=$(bash "${SCRIPT_DIR}/landing-mode.sh" --mode "$MERGE_MODE" --base "origin/${INTEGRATION_BRANCH}") \
  || { echo "❌ Cannot choose a landing mode for #${LAND_NUM} — fix the \"risk\" setting in .autocoder.json and re-run this block"; exit 1; }

# Publish: git push, else the GitHub API. PUSH_OK means it landed; never --dry-run (#26).
PUSH_OK=false
if git push -u origin "$LAND_BRANCH"; then
  PUSH_OK=true
else
  echo "⚠️  git push failed — trying the GitHub API fallback..."
  if python3 "${SCRIPT_DIR}/api-push.py" "$LAND_BRANCH" --base "origin/${INTEGRATION_BRANCH:-master}"; then
    PUSH_OK=true
  fi
fi

if [ "$PUSH_OK" != true ]; then
  # Not published: leave the issue open and keep 'working' (#26).
  issue_comment "$LAND_NUM" --body "⚠️ **Publication failed — issue left open**

Both \`git push\` and the GitHub API fallback failed, so the fix has NOT landed.
The issue stays open and keeps its \`working\` label so the work is not lost or
silently redone.

Local branch: \`${LAND_BRANCH}\`" 2>/dev/null || true
  echo "❌ Could not publish ${LAND_BRANCH} — issue $LAND_NUM left OPEN (nothing was closed)"
  exit 1
fi

if [ "$LANDING_MODE" = "pr" ]; then
  # Create a pull request and stop. The body is the review digest (see
  # "Review Digest" above); a body with unfilled slots is never published.
  DIGEST=$(bash "${SCRIPT_DIR}/render-review-digest.sh" --issue "$LAND_NUM" \
    --base "origin/${INTEGRATION_BRANCH}" --sections "${DIGEST_SECTIONS:?write the Review Digest sections file first}" --pr) \
    || { echo "❌ Review digest for #${LAND_NUM} has unfilled slots or no Verification evidence (a "$ command" line and its result) — fix $DIGEST_SECTIONS and re-run (the renderer's stderr says which)"; exit 1; }
  gh pr create \
    --base "$INTEGRATION_BRANCH" \
    --head "$LAND_BRANCH" \
    --title "#${LAND_NUM}: ${LAND_TITLE}" \
    --body "${DIGEST}

$(cat "$REVIEW_FILE")

🤖 Generated with [Claude Code](https://claude.com/claude-code)" \
    || { echo "❌ gh pr create failed for #${LAND_NUM} — keeping the 'working' label; fix it and re-run"; exit 1; }

  # Hand off from 'working' (concurrency lock) to 'awaiting-integration'
  # (review gate). Without the second label the issue is immediately claimable
  # again and the loop re-does the work every iteration until a human merges.
  issue_update "$LAND_NUM" --remove-label "working" 2>/dev/null || true
  issue_update "$LAND_NUM" --add-label "awaiting-integration" 2>/dev/null || true
  echo "✅ PR created for issue #$LAND_NUM — awaiting review"
  "${SCRIPT_DIR}/append-to-history.sh" --history-file "HISTORY.md" --backend auto \
    "PR #${LAND_NUM}: ${LAND_TITLE}" \
    "PR created on branch ${LAND_BRANCH}." \
    "${LAND_BODY:0:150}" \
    "Awaiting code review."
else
  # Launch detached (#1693); the job owns the issue: `merging`, verify-shipped.sh (#35), close.
  SUMMARY_FILE=$(mktemp "${AUTOCODER_TMP:-/tmp}/autocoder-merge-${LAND_NUM}.summary.XXXXXX")
  # The close comment is the review digest (see "Review Digest" above); a body
  # with unfilled slots is never handed to the merge job.
  bash "${SCRIPT_DIR}/render-review-digest.sh" --issue "$LAND_NUM" \
    --base "origin/${INTEGRATION_BRANCH}" --sections "${DIGEST_SECTIONS:?write the Review Digest sections file first}" > "$SUMMARY_FILE" \
    || { echo "❌ Review digest for #${LAND_NUM} has unfilled slots or no Verification evidence (a "$ command" line and its result) — fix $DIGEST_SECTIONS and re-run (the renderer's stderr says which)"; exit 1; }
  cat "$REVIEW_FILE" >> "$SUMMARY_FILE"   # review outcome goes in the close comment
  if ! "${SCRIPT_DIR}/merge-launch.sh" \
    --feature "$LAND_BRANCH" \
    --issue "$LAND_NUM" \
    --integration "$INTEGRATION_BRANCH" \
    --test-cmd "$TEST_COMMAND" \
    --summary-file "$SUMMARY_FILE" \
    --own-issue; then
    echo "❌ Merge job did not launch for issue #${LAND_NUM} — keeping the 'working' label; fix the launch error and retry."
    exit 1
  fi

  # No label write here. The job performed the hand-off ('working' → 'merging')
  # as its first act and retires 'merging' when it closes, parks, or escalates.

  "${SCRIPT_DIR}/append-to-history.sh" --history-file "HISTORY.md" --backend auto \
    "Fix #${LAND_NUM}: ${LAND_TITLE}" \
    "Resolved on ${LAND_BRANCH}. Handed off to the merge job for ${INTEGRATION_BRANCH}." \
    "${LAND_BODY:0:150}" \
    "Tests passing on the branch. The merge job gates the integrated tree and closes the issue when it lands."
  echo "🚀 Issue #${LAND_NUM} handed off to the merge job (log path printed by merge-launch.sh); the job closes, parks, or escalates the issue itself"
fi
```

## Example Workflow

Moved to `autocoder:references/fix-complex-issues.md` (#240). Read it when you want a worked simple-vs-complex example.

## Blocking Detection & Label Assignment

Before attempting to work on an issue, assess whether it can be handled autonomously. If not, add the appropriate blocking label and skip to the next issue.

### Blocking Labels

| Label | When to Apply | Example Indicators |
|-------|---------------|-------------------|
| `needs-clarification` | Incomplete information, missing context, unclear requirements | "Fix the bug" (which bug?), "Improve performance" (of what?), vague descriptions |
| `needs-design` | Multiple valid approaches without clear winner, requires design phase | "Add user dashboard", "Implement notifications", architectural uncertainty |
| `needs-approval` | Architectural decisions, major changes, security implications, breaking changes | "Migrate to microservices", "Change auth system", "Remove deprecated API" |
| `too-complex` | Beyond autonomous capability (when decomposition fails or superpowers unavailable) | Manual decomposition needed, requires deep expertise |
| `future` | Idea for future consideration, not ready for implementation | "Expose data via MCP server", research spikes, long-term ideas |
| `decomposed` | Complex issue broken into sub-tasks (automatically applied, not blocking) | Parent issue tracking sub-task completion |
| `subtask` | Part of a larger decomposed issue (informational, not blocking) | Individual actionable task from decomposition |
| `merging` | Applied by the merge job itself (`merge-launch.sh --own-issue`) as its first act while a detached merge is in flight; never by a worker. Suppresses the issue from the claimable queue. Not a human-judgement gate, so `/review-blocked` ignores it. | The job retires it when it closes, parks, or escalates the issue; the post-merge sentinel re-queues the issue if the job dies without reporting. |
| `awaiting-integration` | Applied automatically when a PR is opened in `pr` merge mode, and by the merge job when the work landed on the integration branch but may not be closed yet: the published tree was not the gated tree (disjoint re-sync), the base was already red, or the commit is not on the ship branch. Suppresses the issue from the claimable queue so the loop does not redo finished work. Not a human-judgement gate, so `/review-blocked` ignores it. | Merging the PR closes the issue and retires the label; the post-merge sentinel closes a parked issue once its landed commit is on a green tip. If a PR is closed **without** merging, remove the label by hand (`gh issue edit <n> --remove-label awaiting-integration`) or the issue stays invisible to the loop. |

### Detection Process

Moved to `autocoder:references/fix-blocking.md` (#240). Read it when an issue may need a blocking label: it has the red flags, the reason-writing rules and the `add-blocking-label.sh` call.

### Ultra-Complex Issues - Decompose into Sub-Tasks

Moved to `autocoder:references/fix-decomposition.md` (#240). Read it when the task scope gate or Step 1 says the issue is too large: it has the decomposition rules, the sub-task body template and the `too-complex` fallback.

**Monitoring Decomposed Issues**:

When processing issues in the main loop, check for decomposed issues where all sub-tasks are complete:

```bash
# After fixing each issue, check if it was a sub-task that completes a decomposed issue
# Get parent issue if this was a subtask
PARENT_ISSUE=$(issue_get "$ISSUE_NUM" | jq -r '.body // ""' | sed -nE 's/.*Sub-task of #([0-9]+).*/\1/p' | head -1)

if [ -n "$PARENT_ISSUE" ]; then
  echo "🔍 Checking if parent issue #$PARENT_ISSUE is now complete..."

  # Check if all sub-tasks of parent are closed. The sub-task list lives in the
  # "Issue Decomposed into Sub-Tasks" COMMENT, not the body (#134): take the
  # checklist from the latest such comment, so a list corrected by a later
  # re-decomposition wins. Fall back to the body only when no such comment exists
  # (older decompositions, and the file backend, which folds comments into the body).
  PARENT_JSON=$(issue_get "$PARENT_ISSUE")
  PARENT_SUBTASKS=$(printf '%s' "$PARENT_JSON" | jq -r '
    ([(.comments // [])[] | (.body // "") | select(test("Issue Decomposed into Sub-Tasks"))] | last)
      // (.body // "")' | tr -d '\r' | grep -oE '^- \[[ xX]\] #[0-9]+' | grep -oE '[0-9]+$')
  ALL_CLOSED=true
  if [ -z "$PARENT_SUBTASKS" ]; then
    echo "⚠️  No sub-task checklist found on #$PARENT_ISSUE — not auto-closing it."
    ALL_CLOSED=false
  fi

  for SUBTASK_NUM in $PARENT_SUBTASKS; do
    SUBTASK_STATE=$(issue_get "$SUBTASK_NUM" | jq -r '.state')
    if [ "$SUBTASK_STATE" != "CLOSED" ]; then
      ALL_CLOSED=false
      break
    fi
  done

  if [ "$ALL_CLOSED" = "true" ]; then
    echo "✅ All sub-tasks complete! Closing parent issue #$PARENT_ISSUE"
    # The rollup is a review digest too (#196). It has no diff of its own (each
    # sub-task landed and was digested separately), so it renders against HEAD and
    # the sub-tasks go in "Where to look".
    ROLLUP_SECTIONS=$(mktemp "${AUTOCODER_TMP:-/tmp}/autocoder-rollup-${PARENT_ISSUE}.XXXXXX")
    {
      printf '## Intent\n%s\n\n' "$(issue_get "$PARENT_ISSUE" | jq -r '.title')"
      printf '## Where to look\nEach sub-task landed separately with its own digest; review them there:\n'
      for num in $PARENT_SUBTASKS; do printf -- '- #%s %s\n' "$num" "$(issue_get "$num" | jq -r '.title')"; done
      printf '\n## Verification\nEvery sub-task listed above is CLOSED (checked with issue_get just now).\n\n'
      printf '## Not verified / confidence\nThe sub-tasks were gated one at a time; nothing re-tested them together beyond each merge gate. Confidence: medium.\n'
    } > "$ROLLUP_SECTIONS"
    if ROLLUP=$(bash "${SCRIPT_DIR}/render-review-digest.sh" --issue "$PARENT_ISSUE" --base HEAD --sections "$ROLLUP_SECTIONS"); then
      if issue_close "$PARENT_ISSUE" --comment "✅ **Complex Issue Resolved**

${ROLLUP}

🤖 Auto-closed by autonomous fix workflow" && [ "$MERGE_MODE" != "pr" ]; then
        # Merge mode samples closed work for later human review (#197). The rollup
        # has no diff of its own, so only its labels and the random sample apply.
        bash "${SCRIPT_DIR}/spot-check-select.sh" --issue "$PARENT_ISSUE" \
          --sha "$(git rev-parse HEAD)" --base HEAD --apply || true
      fi
    else
      echo "❌ Rollup digest for #$PARENT_ISSUE did not render — leaving it open"
    fi
    rm -f "$ROLLUP_SECTIONS"
  fi
fi
```

### Skip Criteria (Legacy)

Moved to `autocoder:references/fix-blocking.md` (#240). Read it when deciding whether to skip an issue.

## No Priority Issues Found

Moved to `autocoder:references/fix-no-priority-work.md` (#240). Read it when no P0-P3 issue is claimable: it covers Steps 1-3, the full regression run and what to do with its results. Then continue with Step 4 below.

### Step 4: If All Tests Pass - Work on Enhancements

If regression tests pass completely (no new bug issues created), shift focus to **enhancements**.

#### 5A: Check for Approved Enhancement Issues

**IMPORTANT**: Only implement enhancements that have been **approved by a human** (i.e., do NOT have the `proposal` label). AI-generated proposals require human review before implementation.

```bash
# Check for open enhancement issues that are NOT proposals (approved for implementation)
issue_list --state open --label "enhancement" --limit 50 > /tmp/all-enhancements.json

# Filter out proposals, blocked issues, and issues being worked on - only get available approved enhancements
APPROVED_ENHANCEMENTS=$(cat /tmp/all-enhancements.json | python3 -c "
import json, sys
issues = json.load(sys.stdin)
blocking_labels = ['needs-approval', 'needs-design', 'needs-clarification', 'too-complex', 'future', 'awaiting-integration', 'merging']
approved = [i for i in issues
            if not any(l['name'] == 'proposal' for l in i.get('labels', []))
            and not any(l['name'] == 'working' for l in i.get('labels', []))
            and not any(l['name'] in blocking_labels for l in i.get('labels', []))]
print(json.dumps(approved))
")

ENHANCEMENT_COUNT=$(echo "$APPROVED_ENHANCEMENTS" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")

if [ "$ENHANCEMENT_COUNT" -gt 0 ]; then
  echo "🚀 Found $ENHANCEMENT_COUNT approved enhancement(s) to implement"
  # Get first approved enhancement
  ENHANCE_NUM=$(echo "$APPROVED_ENHANCEMENTS" | python3 -c "import json,sys; print(json.load(sys.stdin)[0]['number'])")
  ENHANCE_TITLE=$(echo "$APPROVED_ENHANCEMENTS" | python3 -c "import json,sys; print(json.load(sys.stdin)[0]['title'])")
  ENHANCE_BODY=$(echo "$APPROVED_ENHANCEMENTS" | python3 -c "import json,sys; print(json.load(sys.stdin)[0].get('body',''))")
  echo "📋 Working on approved enhancement #$ENHANCE_NUM: $ENHANCE_TITLE"
  # Body + comment thread (issue #134): design against the whole thread, not the body.
  ENHANCE_SPEC=$("${SCRIPT_DIR}/issue-spec.sh" "$ENHANCE_NUM") || {
    echo "⚠️  Could not read the comment thread for #$ENHANCE_NUM — read it yourself before designing."
    ENHANCE_SPEC="$ENHANCE_BODY"
  }
  echo "Specification (body, then comments — a later comment overrides the body):"
  echo "$ENHANCE_SPEC"
else
  # Check if there are pending proposals
  PROPOSAL_COUNT=$(cat /tmp/all-enhancements.json | python3 -c "
import json, sys
issues = json.load(sys.stdin)
proposals = [i for i in issues if any(l['name'] == 'proposal' for l in i.get('labels', []))]
print(len(proposals))
")

  # Check if there are blocked issues
  BLOCKED_COUNT=$(cat /tmp/all-enhancements.json | python3 -c "
import json, sys
issues = json.load(sys.stdin)
blocking_labels = ['needs-approval', 'needs-design', 'needs-clarification', 'too-complex', 'future', 'awaiting-integration', 'merging']
blocked = [i for i in issues if any(l['name'] in blocking_labels for l in i.get('labels', []))]
print(len(blocked))
")

  if [ "$PROPOSAL_COUNT" -gt 0 ]; then
    echo "📋 Found $PROPOSAL_COUNT proposal(s) awaiting human approval"
    echo "💡 Use '/list-proposals' to review pending proposals"
    echo "✨ No approved enhancements to implement. Creating new proposals..."
  elif [ "$BLOCKED_COUNT" -gt 0 ]; then
    echo "🚫 Found $BLOCKED_COUNT blocked issue(s) (requires human review)"
    echo "💡 Use '/review-blocked' to review and approve blocked issues"
    echo "✨ No approved enhancements to implement. Creating new proposals..."
  else
    echo "✨ No enhancements or proposals. Creating new proposals..."
  fi
  # Continue to Step 5B
fi
```

#### 5B: Propose New Enhancements (if none exist)

Moved to `autocoder:references/fix-no-priority-work.md` (#240). Read it when 5A finds no approved enhancement: it covers the coverage check, brainstorming and the proposal issue template.

#### 5C: Implement Approved Enhancement Using Superpowers

**IMPORTANT**: Only implement enhancements that do NOT have the `proposal` label. If an enhancement has the `proposal` label, it is awaiting human approval and must NOT be implemented.

For each **approved** enhancement issue (no `proposal` label), follow this workflow:

**Step 1: Create Feature Branch**

```bash
# Save parent branch (to return to on a race-abort) and base the enhancement branch on
# the latest shared integration branch — not the worktree's current branch — so the work
# starts from and merges back to the same shared branch instead of stranding on main-wt-N.
PARENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
INTEGRATION_BRANCH="${INTEGRATION_BRANCH:-$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')}"
INTEGRATION_BRANCH="${INTEGRATION_BRANCH:-main}"
git fetch origin "$INTEGRATION_BRANCH" || {
  echo "❌ Cannot fetch origin/${INTEGRATION_BRANCH} — refusing to start enhancement from stale state."
  issue_update "$ENHANCE_NUM" --remove-label "working" 2>/dev/null || true
  exit 1
}

ENHANCE_BRANCH="enhancement/issue-${ENHANCE_NUM}-auto"
if git checkout -b "$ENHANCE_BRANCH" "origin/${INTEGRATION_BRANCH}" 2>/dev/null; then
  echo "✅ Created $ENHANCE_BRANCH from origin/${INTEGRATION_BRANCH}"
elif git checkout "$ENHANCE_BRANCH" 2>/dev/null; then
  echo "ℹ️  Branch $ENHANCE_BRANCH already exists; pulling latest from origin/${INTEGRATION_BRANCH}..."
  git pull --rebase origin "$INTEGRATION_BRANCH" || {
    echo "❌ Rebase of $ENHANCE_BRANCH onto origin/${INTEGRATION_BRANCH} failed."
    issue_update "$ENHANCE_NUM" --remove-label "working" 2>/dev/null || true
    exit 1
  }
else
  echo "❌ Could not create or switch to $ENHANCE_BRANCH."
  issue_update "$ENHANCE_NUM" --remove-label "working" 2>/dev/null || true
  exit 1
fi
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ "$CURRENT_BRANCH" != "$ENHANCE_BRANCH" ]; then
  echo "❌ Could not switch to $ENHANCE_BRANCH (still on $CURRENT_BRANCH) — aborting"
  echo "   rather than implementing on the parent branch."
  exit 1
fi

# Claim-then-verify: add 'working' label IMMEDIATELY, then check for race
issue_update "$ENHANCE_NUM" --add-label "working" 2>/dev/null || true
sleep 1

# Re-fetch to verify we won the race (check for existing work-started comments)
RACE_CHECK=$(issue_get "$ENHANCE_NUM" 2>/dev/null | jq '[.comments[] | select(.body | test("Enhancement Implementation Started"))] | length' 2>/dev/null || echo "0")
if [ "$RACE_CHECK" -gt 0 ]; then
  echo "⚠️  Race condition: another agent already claimed enhancement #$ENHANCE_NUM. Skipping."
  git checkout "$PARENT_BRANCH" 2>/dev/null || true
  exit 0
fi

issue_comment "$ENHANCE_NUM" --body "🚀 **Enhancement Implementation Started**

Starting automated implementation of this enhancement.

**Branch**: \`enhancement/issue-${ENHANCE_NUM}-auto\`
**Started**: $(date)

Implementation in progress..."
```

**Step 2: Design Solution with Brainstorming**

```
# If thorough-brainstorming available (preferred):
Use Skill tool: thorough-brainstorming

# If superpowers available (fallback):
Use Skill tool: superpowers:brainstorming
```

This will:
- Explore design alternatives
- Clarify requirements
- Validate assumptions
- Refine into concrete design

**Step 3: Create Detailed Implementation Plan**

```
# If thorough-writing-plans available (preferred):
Use Skill tool: thorough-writing-plans

# If superpowers available (fallback):
Use Skill tool: superpowers:writing-plans
```

This will:
- Break down into bite-sized tasks
- Specify exact file paths and changes
- Include verification steps
- Assume zero prior codebase knowledge

**Update the GitHub issue** with the implementation plan:

```bash
issue_comment "$ENHANCE_NUM" --body "📋 **Implementation Plan Created**

## Detailed Implementation Plan

[Paste the implementation plan created by thorough-writing-plans or superpowers:writing-plans]

Beginning execution..."
```

**Step 4: Execute the Plan**

```
Use Skill tool: superpowers:executing-plans
```

This will:
- Load and review the plan critically
- Execute tasks in batches
- Report progress for review between batches
- Track completion systematically

**Step 5: Run Tests and Verify**

```bash
# Run full test suite
$TEST_COMMAND

# Capture test results
TEST_EXIT_CODE=$?
TEST_OUTPUT=$(cat /tmp/test-output.txt 2>/dev/null || echo "Test output not captured")
```

#### 5D: Handle Test Results

**If Tests Pass**:

```bash
if [ $TEST_EXIT_CODE -eq 0 ]; then
  echo "✅ All tests pass!"

  # Verify Before Claiming (MANDATORY, #170): the command and its result go in the
  # digest's Verification section. superpowers:verification-before-completion helps.

  # Commit changes
  git add -A
  git commit -m "Implement enhancement #${ENHANCE_NUM}: ${ENHANCE_TITLE}

Detailed explanation of:
- What was implemented
- Design decisions made
- Tests added/modified

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>"

  # Land it: "Landing the Work" (after Step 3) runs the rebase, review check, push and merge.
  LAND_NUM="$ENHANCE_NUM"; LAND_BRANCH="enhancement/issue-${ENHANCE_NUM}-auto"; LAND_TITLE="$ENHANCE_TITLE"; LAND_BODY="$ENHANCE_BODY"
fi
```

**If Tests Fail - Create Bug Issues:** moved to `autocoder:references/fix-enhancement-failures.md` (#240). Read it when the enhancement's tests fail: it files the bug issues and pauses the enhancement, keeping the `working` label and the branch.

#### 5E: Enhancement Skip Criteria

Moved to `autocoder:references/fix-enhancement-failures.md` (#240). Read it when an enhancement cannot be implemented automatically.

## MANDATORY: Continuous Loop

**THIS WORKFLOW RUNS FOREVER UNTIL MANUALLY STOPPED.**

### Context Compaction (MANDATORY — DO THIS EVERY ITERATION)

> ⛔ **Run `/compact` (Claude Code) — or clear/compact the session context (Codex / Gemini / other) — BEFORE starting each new issue. Every iteration. No exceptions.**
>
> The loop runs forever. Without compaction between issues the context window fills and the agent dies mid-fix. Compaction is what makes "runs forever" actually possible. Skipping it is the #1 cause of a fix-loop crashing partway through an issue.
>
> If pstack is installed, its SessionStart hook re-injects "invoke `pstack:poteto-mode`" after every compaction. Ignore it: this protocol stays the spine for the next issue (see *Optional skill enhancements*).

After completing ANY of these actions, you MUST immediately continue:

1. **After triaging unprioritized issues** → Fetch next priority issue
2. **After fixing and closing a bug issue** → Fetch next priority issue
3. **After skipping an issue** → Fetch next priority issue
4. **After running regression tests** → Check for new issues created
5. **After implementing an approved enhancement** → Check for more approved enhancements or bugs
6. **After test failures during enhancement** → Process created bug issues first
7. **After creating a proposal** → Continue generating more proposals if useful ideas remain
8. **If truly idle** → Output `IDLE_NO_WORK_AVAILABLE` to trigger sleep cycle

### Priority Order

The workflow follows this strict priority order:
1. **Triage Unprioritized Issues** (assign P0-P3 labels first)
2. **P0-P3 Bug Issues** (fix bugs first)
3. **Regression Test Failures** (creates new bug issues)
4. **Approved Enhancement Issues** (only enhancements WITHOUT the `proposal` label)
5. **Create New Proposals** (lowest priority - only when no bugs AND no approved enhancements)

**⚠️ NEVER automatically implement proposals.** Proposals (issues with `proposal` label) require human approval before implementation.

### Loop Implementation

Moved to `autocoder:references/fix-loop-and-proposals.md` (#240). Read it when you need the queue-counting script that picks the next kind of work.

### Never Stop

- **DO NOT** wait for user input between issues
- **DO NOT** stop after fixing one issue
- **DO NOT** ask "should I continue?"
- **DO NOT** implement issues with the `proposal` label (they require human approval)
- **DO** triage unprioritized issues first
- **DO** keep processing bug issues until the queue is empty
- **DO** run `/full-regression-test` when bug queue is empty
- **DO** process any new bug issues created by `/full-regression-test`
- **DO** work on **approved** enhancements only when no bugs exist
- **DO** output `IDLE_NO_WORK_AVAILABLE` after creating a proposal (to allow human review)
- **DO** output `IDLE_NO_WORK_AVAILABLE` when no bugs and proposals already exist
- **DO** create bug issues for any test failures during enhancement work
- **DO** loop back to bug fixing if enhancement work creates failures

### Idle State

**CRITICAL: You MUST output the idle signal when there's nothing to do.**

Output this EXACT text (on its own line) when ANY of these conditions are true:
- No priority bugs (P0-P3) AND no approved enhancements AND (proposals already exist OR blocked issues exist)
- After creating a new proposal (to allow human review time)
- After completing all available work

```
IDLE_NO_WORK_AVAILABLE
```

**Without this signal, the loop will spin forever without sleeping.**

This signals the stop hook to sleep (default 15 minutes) before checking again for:
- New human-created issues
- Comments on existing issues
- Approved proposals ready for implementation
- Blocked issues reviewed and approved (blocking label removed)

**The only way this workflow stops is if the user manually interrupts it.**

**Do NOT send messages to other sessions when idle.** Do not use `SendMessage` (or any tool) to report your idle status, empty backlog, or completed issues to another session. Silent idle is correct behavior. Only use `SendMessage` if you hit a genuine blocker the manager must resolve.

---

## Proposal Management

Moved to `autocoder:references/fix-loop-and-proposals.md` (#240). Read it when you need to explain how proposals are reviewed, approved, refined or rejected.
