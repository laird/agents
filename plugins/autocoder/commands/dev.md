# Start Autonomous Development of GitHub Issues

Analyze all open GitHub issues, prioritize them, and begin systematically fixing bugs and implementing features starting with the highest priority.

## Optional skill enhancements

<!-- BEGIN optional-skills-prelude v1 — keep in sync across all command files; see plugins/shared/optional-skills-prelude.md -->

If a named skill appears in your available skills list (delivered in the session-start system-reminder), invoke it via the `Skill` tool at the indicated step. Otherwise, follow the inline protocol below — it remains the source of truth and is unchanged by this section.

In Gemini CLI / Antigravity, skills activate via `activate_skill` instead of the `Skill` tool; the mapping is otherwise identical.

**Skill-name matching.** Match each table entry as an exact string. Mapping tables use fully-qualified names (`<plugin>:<skill>`) for plugin-installed skills and bare names for personal toolkit skills.

**Notation.** `A → B → C` means sequence (invoke in order). `A + B + C` means independent facets (all apply, order irrelevant). `A (primary)` means A is the orchestration spine. A leading `→` on a row indicates "next in sequence if applicable."

**Failure semantics.** Not-installed: silent fallback. Mid-run failure or interruption of an installed skill: surface the failure message, fall back to the inline protocol for the rest of that step, no retry. Self-skip (e.g., `<SUBAGENT-STOP>`): silent fallback, not treated as failure. If at least one `superpowers:*` skill named in this command's mapping table is missing from your available-skills list, emit one consolidated recommendation line at command entry: *Tip: this command works best with the `superpowers` plugin (https://github.com/obra/superpowers) — install via `/plugin install superpowers@claude-plugins-official`.* Never emit such notices for personal toolkit skills.

**Skills are advisory, not gating.** A command's completion criteria are defined by its inline protocol. Optional skill outcomes are surfaced and considered, but do not override inline success criteria. "Always applied" in a mapping table means the skill is invoked when installed; outcomes remain advisory. When a command claims success while an advisory skill earlier in the run surfaced a failure, the success summary acknowledges the advisory finding.

**Version trust.** Skills are matched by name; the integration does not pin or verify versions. If a tracked skill's contract changes in a way that breaks the chain, the integration is stale and must be updated.

<!-- END optional-skills-prelude v1 -->

<!-- BEGIN optional-skills-mapping dev v1 — keep in sync between Claude/Antigravity mirrors of this command -->

`/dev` accepts heterogeneous work — bug fixes, feature implementation, refactoring, increasing test coverage, docs/config/chore, or proposing new tasks. The agent classifies the work after reading the issue and applies the matching skills along two axes: deliverable type and kind of work.

**Composition rule.** Step 2 and Step 3 compose by **union**: apply every skill named in either step. Where both steps name the same skill, apply it once. Where the two steps disagree on whether a skill is required vs. optional, the **stronger requirement wins** (a skill marked required in one step is required overall). Step 1 (deliverable classification) is purely a routing input to Step 2 and produces no skills of its own.

**Ordering across steps.** When Step 3 contributes a sequence (`A → B → C`), that sequence defines the spine. Step 2 facets attach at conventional points:
- **Provisioning facets** (e.g., `superpowers:using-git-worktrees`) attach at spine entry — before the first sequence step runs.
- **Verification facets** (e.g., `superpowers:verification-before-completion`) attach at spine exit — after the last sequence step.
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
| **Branch** | `superpowers:using-git-worktrees` + `superpowers:verification-before-completion` + `completion-review` (always); `superpowers:requesting-code-review` → `superpowers:receiving-code-review` (when seeking merge) |
| **Document** | `completion-review` only |
| **Throwaway** | none of the above are required |

**Step 3: apply the matching skills based on kind of work.**

| If the work is... | Use these skills |
|---|---|
| Bug / unexpected behavior | `peters-toolkit:bugfix` (preferred — end-to-end bugfix orchestration; fallback: `bugfix`); if neither is installed: `superpowers:systematic-debugging` → `superpowers:test-driven-development` |
| New feature / unclear requirement | `thorough-brainstorming` → `thorough-writing-plans` → `superpowers:test-driven-development` (fallback: `superpowers:brainstorming` → `superpowers:writing-plans`; optional `critical-design-review` after brainstorming, `critical-implementation-review` after writing-plans) |
| Refactor / restructuring | `superpowers:test-driven-development` (characterization tests) → refactor under green |
| Increasing test coverage | `autocoder:improve-test-coverage` → `superpowers:test-driven-development` for new tests |
| Proposing new tasks | `thorough-brainstorming` (preferred) or `superpowers:brainstorming` → `critical-design-review` |
| Docs / config / chore | TDD optional |

**Bugfix note.** `peters-toolkit:bugfix` already carries its own failing-test, root-cause, and review stages end to end. When it runs, do not additionally invoke `superpowers:systematic-debugging` or `superpowers:test-driven-development` for the same bug, and treat its internal review gate as satisfying the Step 2 `superpowers:requesting-code-review` → `superpowers:receiving-code-review` pair. The remaining Step 2 facets (worktree provisioning, verification-before-completion, completion-review) still apply. If `peters-toolkit:bugfix` fails mid-run, fall back to the `superpowers:systematic-debugging` → `superpowers:test-driven-development` chain per the prelude's failure semantics.

<!-- BEGIN bugfix-autonomous-gate-policy v1 — keep in sync between Claude/Antigravity mirrors -->

**Autonomous gate policy for `peters-toolkit:bugfix`.** `/dev` runs unattended, so the skill's in-chat STOP gates (G1, G2, G4, G5, G8) must not become chat prompts. Invoke it with an explicit issue id (`bugfix <ISSUE_NUM>`) so it never shows its resume picker, and **never ask the user a question or wait for an in-chat approval while running under `/dev` or `/dev-loop`.** Each gate resolves as follows:

| Gate | Autonomous resolution |
|---|---|
| **G1** — bug statement + tier | Self-decide and record the tier plus reasoning as an issue comment. When the tier is genuinely ambiguous, choose the **higher** tier — the skill's "never under-tier" law still binds. |
| **G2** — root-cause sign-off | Still a hard STOP **on the work**, not on the human: complete the root-cause analysis and write it to the issue before any fix. If the root cause cannot be established within this command's investigation budget, apply `needs-clarification` (missing information) or `needs-design` (multiple defensible causes) and move to the next issue. |
| **G4 / G5** — design / plan approval | Self-approve once `critical-design-review` / `critical-implementation-review` comes back green. If a review still returns blocking findings after two update loops, or the decision needs architecture, security, or product judgment, apply `needs-approval` (or `needs-design`) and move on. |
| **G8** — pre-PR human review | Satisfied by this command's own quality gates: build and tests green, `superpowers:verification-before-completion`, `completion-review`, and the original reproduction confirmed gone. In `pr` integration mode the pull request itself carries the human review; in `merge` mode the quality gates are the sign-off. Never hold the loop waiting for an approval message. |

Everything in the skill that is process rather than human interaction stays fully in force: the failing reproduction test lands before the fix, no under-tiering, and full verification precedes integration. Escalation replaces waiting — when a gate genuinely needs a human, use the blocking-label mechanism in "Blocking Detection & Label Assignment" below and let `/review-blocked` pick it up; do not pause mid-issue.

<!-- END bugfix-autonomous-gate-policy v1 -->

<!-- END optional-skills-mapping dev v1 -->

## Usage

```bash
# Automatic priority-based selection (processes all issues in priority order)
/dev

# Target a specific issue directly (skips priority selection)
/dev 223
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

When unprioritized issues are detected, review each one and assign an appropriate priority label before continuing with the fix workflow.

### Triage Process

For each unprioritized issue:

1. **Read the issue** - Understand the title, description, and any labels
2. **Assess severity and impact**:
   - **P0 (Critical)**: System down, data loss, security vulnerability, blocks all users
   - **P1 (High)**: Major feature broken, significant user impact, no workaround
   - **P2 (Medium)**: Feature partially broken, workaround exists, moderate impact
   - **P3 (Low)**: Minor issue, cosmetic, nice-to-have, minimal user impact
3. **Assign the priority label**:

```bash
# Assign priority to an issue (backend-neutral)
issue_update <ISSUE_NUMBER> --add-label "P2"  # Use appropriate priority
```

4. **Add a triage comment** explaining the priority decision:

```bash
issue_comment <ISSUE_NUMBER> --body "🏷️ **Triage Complete**

**Priority Assigned**: P2 (Medium)

**Rationale**: [Brief explanation of why this priority was chosen]

🤖 Triaged by autonomous fix workflow"
```

### Triage Decision Matrix

| Indicator | P0 | P1 | P2 | P3 |
|-----------|----|----|----|----|
| Production impact | Critical/Down | Major degradation | Partial impact | Minimal |
| User scope | All users | Many users | Some users | Few users |
| Workaround | None | Difficult | Available | Easy |
| Data risk | Loss/corruption | Possible | Unlikely | None |
| Security | Active exploit | Vulnerability | Potential | None |
| Keywords | "crash", "down", "urgent", "security" | "broken", "fails", "blocking" | "issue", "bug", "incorrect" | "minor", "cosmetic", "enhancement" |

### Triage Instructions

When `UNPRIORITIZED_ISSUES_FOUND=true` is detected:

1. Parse the `UNPRIORITIZED_DATA` to get issue numbers, titles, and descriptions
2. For each issue, use the decision matrix to determine priority
3. Assign the label and post a triage comment
4. Continue to the main fix workflow after all issues are triaged

**Model Selection for Triage**: Use **Haiku** for straightforward triage decisions, escalate to **Sonnet** if the issue description is ambiguous or requires deeper analysis.

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

## Model Selection (Opus 4.5)

When spawning agents or using the Task tool during issue resolution, select the model based on task complexity:

### Issue Complexity → Model Mapping

| Issue Type | Model | Rationale |
|------------|-------|-----------|
| Simple (P2/P3, clear fix) | Sonnet | Known patterns, documented solutions |
| Complex (P0/P1, architectural) | Opus | Deep analysis, trade-off decisions |
| Regression test analysis | Sonnet | Standard test interpretation |
| Root cause investigation | Opus | Multi-factor analysis |
| Improvement proposals | Opus | Creative problem-solving |
| Labeling & formatting | Haiku | Mechanical operations |

### Escalation Triggers

**Start with Sonnet, escalate to Opus when:**
- Fix attempt fails after 2 tries with same approach
- Issue involves 5+ files requiring coordinated changes
- Root cause is unclear after initial investigation
- Multiple test failures share non-obvious common cause
- Issue requires architectural decision (new patterns, dependencies)

**Stay with Sonnet when:**
- Error messages clearly indicate the fix
- Issue matches known patterns from previous fixes
- Single file change with isolated impact
- Test failures have obvious cause (typo, missing import)

**Drop to Haiku for:**
- Adding/updating priority labels
- Posting status comments to GitHub
- Formatting commit messages
- Simple file cleanup (delete, rename)

### Model Usage by Workflow Phase

| Phase | Recommended Model |
|-------|-------------------|
| Initial complexity assessment | Sonnet |
| Simple issue: direct fix | Sonnet |
| Complex issue: bugfix / systematic-debugging skill | Opus |
| Complex issue: brainstorming skill | Opus |
| Complex issue: writing-plans skill | Opus |
| Complex issue: executing-plans skill | Sonnet |
| Verification before completion | Sonnet |
| Regression test execution | Sonnet |
| Regression test analysis | Sonnet → Opus if patterns unclear |
| Improvement proposals | Opus |
| Issue creation from failures | Haiku |

### Example Task Tool Usage

```javascript
// Initial assessment - start with Sonnet
Task("analyst", "Assess complexity of issue #${ISSUE_NUM}...", model="sonnet")

// Complex root cause - use Opus
Task("debugger", "Investigate why 15 tests fail with timeout...", model="opus")

// Standard fix - use Sonnet
Task("coder", "Update package.json to fix dependency conflict...", model="sonnet")

// Label management - use Haiku
Task("labeler", "Add P2 label to issue #${ISSUE_NUM}...", model="haiku")
```

## Context Management (MANDATORY — NON-NEGOTIABLE)

> ⛔ **STOP. Before you touch ANY new issue, you MUST compact your context. Every issue. Every time. No exceptions.**
>
> - **Claude Code:** run `/compact`.
> - **Codex / Gemini / other sessions:** clear or compact the session context using your session controls (the equivalent of `/compact`).
>
> This is not optional and not a suggestion. A long-running dev-loop **WILL** exhaust the context window and crash the agent mid-issue if you skip this. Compacting between issues is the single most important thing keeping the loop alive — treat skipping it as a defect.

**Rules — follow exactly:**

1. **Compact BEFORE fetching or starting every new issue.** Every iteration, without exception.
2. **Each issue starts from a fresh, compacted context.**
3. **NEVER carry over detailed investigation notes** from a previous issue — the compacted summary is sufficient.
4. **If you ever notice you've started a new issue without compacting, compact immediately** before doing anything else.

## Instructions

Start working on GitHub issues now:

```bash
# Source issue function layer (routes to GitHub or file backend)
SCRIPT_DIR=$(
  if [ -d "$(pwd)/.agent/scripts" ]; then echo "$(pwd)/.agent/scripts"
  elif [ -d "$(pwd)/plugins/autocoder/scripts" ]; then echo "$(pwd)/plugins/autocoder/scripts"
  elif [ -d "$(pwd)/.claude-plugin/plugins/autocoder/scripts" ]; then echo "$(pwd)/.claude-plugin/plugins/autocoder/scripts"
  else find "$HOME/.claude/plugins/cache" -type d -name "scripts" -path "*/autocoder/*" 2>/dev/null | sort -V | tail -1
  fi
)
source "${SCRIPT_DIR}/issue-fns.sh"
```

```bash
# Preflight: cheap check whether there's any claimable work before paying
# the LLM cost of the full /dev flow. See spec §5.
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

This section configures the `/dev` command for autonomous issue resolution.

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

# Ensure priority labels exist (one-time setup per project, GitHub backend only —
# the file backend creates labels on demand)
if [ "$ISSUE_SOURCE" = "github" ] && [ ! -f ".github/.priority-labels-configured" ]; then
  echo "🏷️  Checking priority labels (one-time setup)..."
  EXISTING_LABELS=$(gh label list --json name --jq '.[].name' 2>/dev/null || echo "")

  for label in "P0:Critical priority issue:d73a4a" "P1:High priority issue:ff9800" "P2:Medium priority issue:ffeb3b" "P3:Low priority issue:4caf50" "proposal:AI-generated proposal awaiting human approval:c5def5" "working:Issue currently being worked on by an agent:1d76db" "needs-approval:Architectural decisions, major changes, security implications:e99695" "needs-design:Requirements unclear, multiple approaches, needs design:fbca04" "needs-clarification:Incomplete information, missing context, questions needed:d4c5f9" "too-complex:Beyond autonomous capability, requires deep expertise:b60205" "future:Idea for future consideration, not ready for implementation:bfd4f2" "decomposed:Complex issue broken into sub-tasks:9c27b0" "subtask:Part of a larger decomposed issue:ba68c8"; do
    IFS=':' read -r name desc color <<< "$label"
    if ! echo "$EXISTING_LABELS" | grep -qFx "$name"; then
      echo "Creating label: $name"
      gh label create "$name" --description "$desc" --color "$color" 2>/dev/null || true
    fi
  done

  # Mark labels as configured
  mkdir -p .github
  echo "# Priority labels configured on $(date -I)" > .github/.priority-labels-configured
  echo "✅ Priority labels configured"
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
# Usage: /dev [issue_number]
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

  # Remote branch is the strongest lock — check it before the working label.
  # A peer may have pushed the branch before the label propagated, or a manager
  # may have cleared a stale label without realising work was still in flight.
  REMOTE_BRANCH_SPEC=$(git ls-remote --heads origin "feature/issue-${ISSUE_NUM}" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$REMOTE_BRANCH_SPEC" -gt "0" ]; then
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
    if [ "$START_MARKERS" -gt 0 ] && [ "$CURRENT_BRANCH" != "$TARGET_BRANCH" ]; then
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

  # Claim-then-verify: the claim above (issue_claim or pre-claimed handoff check) is the
  # primary lock. For GitHub backend (non-atomic), post an early marker comment and wait
  # for competing workers to surface before proceeding.
  if [ "${ISSUE_SOURCE:-}" = "github" ]; then
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

  # NOTE: the lock and its race arbitration are established above (issue_claim +
  # [autocoder-claim] marker + settlement window). A second, weaker label-add check
  # used to live here; it was redundant once the arbitration landed, and it aborted
  # via `exit 1` WITHOUT releasing the label it had just added — leaking the lock.
else
  # No specific issue - get highest priority issue (using labels only)
  issue_list --state open --limit 100 > /tmp/all-issues.json

  # Filter out issues with 'working' label (being worked on by another agent)
  # Also filter out issues with blocking labels (needs human review)
  # Also filter out decomposed parent issues (work on their sub-tasks instead)
  cat /tmp/all-issues.json | jq -r '
    .[] |
    select(
      (.labels | map(.name) | any(. == "P0" or . == "P1" or . == "P2" or . == "P3"))
      and (.labels | map(.name) | any(. == "working") | not)
      and (.labels | map(.name) | any(. == "needs-approval" or . == "needs-design" or . == "needs-clarification" or . == "too-complex" or . == "future" or . == "decomposed") | not)
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
  cat /tmp/all-issues.json | jq -r '
    [.[] |
    select(
      (.labels | map(.name) | any(. == "P0" or . == "P1" or . == "P2" or . == "P3"))
      and (.labels | map(.name) | any(. == "working") | not)
      and (.labels | map(.name) | any(. == "needs-approval" or . == "needs-design" or . == "needs-clarification" or . == "too-complex" or . == "future" or . == "decomposed") | not)
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

    # Write idle status file for agents-ui TUI monitoring
    mkdir -p /tmp/agents-ui
    SESSION_NAME=$(tmux display-message -p '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null || echo "unknown")
    echo "{\"status\": \"idle\", \"completed\": \"$(date -Iseconds)\"}" > "/tmp/agents-ui/${SESSION_NAME}.json"

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
echo "Description:"
echo "$ISSUE_BODY" | head -20
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
# If this issue FAILS either test → DECOMPOSE IT NOW (before branch creation):
#   - Decompose into 3-8 sub-tasks, each satisfying both criteria above
#   - Create each sub-task as a new issue with `subtask` label and a
#     "Sub-task of #${ISSUE_NUM}" line in the body
#   - Add the `decomposed` label to this parent issue and release the claim
#   - Exit; workers will pick up the independent sub-tasks on the next tick
#
# If this issue PASSES both tests → proceed to branch creation immediately.
#
# See "Ultra-Complex Issues - Decompose into Sub-Tasks" later in this document
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
  # Terminal outcome only: setup failed before any work began — Releasing and aborting.
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
    echo "❌ Rebase of $FIX_BRANCH onto origin/${INTEGRATION_BRANCH} failed — resolve conflicts manually."
    # Terminal outcome only: setup failed before any work began — Releasing and aborting.
    issue_update "$ISSUE_NUM" --remove-label "working" 2>/dev/null || true
    exit 1
  }
else
  echo "❌ Could not create or switch to $FIX_BRANCH."
  # Terminal outcome only: setup failed before any work began — Releasing and aborting.
  issue_update "$ISSUE_NUM" --remove-label "working" 2>/dev/null || true
  exit 1
fi
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ "$CURRENT_BRANCH" != "$FIX_BRANCH" ]; then
  echo "❌ Branch switch verification failed (still on $CURRENT_BRANCH)."
  # Terminal outcome only: setup failed before any work began — Releasing and aborting.
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

# Write status file for agents-ui TUI monitoring
mkdir -p /tmp/agents-ui
SESSION_NAME=$(tmux display-message -p '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null || echo "unknown")
echo "{\"status\": \"working\", \"issue\": ${ISSUE_NUM}, \"title\": \"${ISSUE_TITLE}\", \"started\": \"$(date -Iseconds)\"}" > "/tmp/agents-ui/${SESSION_NAME}.json"
```

**⚠️ The claim sequence above (working label → `feature/issue-<N>` branch → work-started comment) is mandatory and runs FIRST for every issue — bug OR enhancement.** Do not begin triage analysis, brainstorming, or implementation until all three exist. Priority-labeled enhancements (P0–P3) are handled by this standard path, **not** by the "No Priority Issues Found → 5C" flow (that flow only applies when there are no priority issues left). If you ever notice you are editing files while still on the parent branch (`main`, `main-wt-N`, etc.), stop immediately and run the claim sequence — committing on the parent branch strands the `working` lock with no matching branch and makes peers treat it as stale.

## First-Run: Configure Merge Mode

When `MERGE_MODE_NOT_CONFIGURED=true` is detected in the output above, you **MUST** prompt the user before proceeding:

1. Use AskUserQuestion to ask: *"How should completed issues be integrated? Options: **merge** (auto-merge feature branch to parent and push — fully autonomous) or **pr** (push feature branch and create a pull request for human review). Enter 'merge' or 'pr':"*
2. Set `MERGE_MODE` to the user's response (default to `merge` if unclear).
3. Append the setting to the project's CLAUDE.md (or AGENTS.md if it exists) so it persists:

```bash
cat >> CLAUDE.md << MERGE_MODE_CONFIG

### Merge Mode
\`\`\`
${MERGE_MODE}
\`\`\`
Options: \`merge\` (auto-merge to parent branch and push) or \`pr\` (push feature branch and create a pull request, then stop).
MERGE_MODE_CONFIG
echo "✅ Saved merge mode '$MERGE_MODE' to CLAUDE.md"
```

4. Commit the CLAUDE.md change so all agents share the setting.

## CRITICAL: Release the 'working' Label Only on a Terminal Outcome

The `working` label is the concurrency lock. It is held for the **whole life of
the claim**, not per commit. An open issue with no `working` label is, by
definition, claimable — so dropping the lock while the issue is still open and
still yours re-exposes it to the pool and invites a peer to duplicate your work.

**Release the lock ONLY when the claim has actually ended:**

| Terminal outcome | Release? | Also required |
|---|---|---|
| Issue closed (merged / resolved) | ✅ yes | — |
| PR opened and the issue is closed by that merge | ✅ yes, at close | — |
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
# Correct: terminal outcome only. Pair the release with the close.
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

### Step 2A: Simple Issue - Direct Fix

For simple issues, proceed directly:

1. Read relevant code files to understand the root cause
2. Implement a complete fix (not partial)
3. Run targeted tests to verify the fix works
4. Create a git commit with the changes
5. Mark as complete

```bash
# After fixing simple issue:
git add -A
git commit -m "Fix #${ISSUE_NUM}: Brief description

Detailed explanation of what was fixed and how.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>"

# Push feature branch
# Publish the branch. `git push` first; if the transport is blocked (e.g. a
# proxy rejecting git-receive-pack with HTTP 403), fall back to the GitHub API.
# PUSH_OK records whether the work ACTUALLY LANDED — never infer it from a
# command's exit status alone, and never from `git push --dry-run`, which
# succeeds against a blocked transport because it never sends the pack.
PUSH_OK=false
if git push -u origin "feature/issue-${ISSUE_NUM}"; then
  PUSH_OK=true
else
  echo "⚠️  git push failed — trying the GitHub API fallback..."
  if python3 "${SCRIPT_DIR}/api-push.py" "feature/issue-${ISSUE_NUM}" --base "origin/${INTEGRATION_BRANCH:-master}"; then
    PUSH_OK=true
  fi
fi

if [ "$PUSH_OK" != true ]; then
  # The code did not land. Closing now would make the tracker claim something
  # false, and would strand the work (see #26). Leave the issue open, KEEP the
  # 'working' label, and say so.
  issue_comment "$ISSUE_NUM" --body "⚠️ **Publication failed — issue left open**

Both \`git push\` and the GitHub API fallback failed, so the fix has NOT landed.
The issue stays open and keeps its \`working\` label so the work is not lost or
silently redone.

Local branch: \`feature/issue-${ISSUE_NUM}\`" 2>/dev/null || true
  echo "❌ Could not publish feature/issue-${ISSUE_NUM} — issue $ISSUE_NUM left OPEN (nothing was closed)"
  exit 1
fi

if [ "$MERGE_MODE" = "pr" ]; then
  # Create a pull request and stop
  gh pr create \
    --base "$INTEGRATION_BRANCH" \
    --head "feature/issue-${ISSUE_NUM}" \
    --title "Fix #${ISSUE_NUM}: Brief description" \
    --body "Closes #${ISSUE_NUM}

[Detailed explanation of fix]

🤖 Generated with [Claude Code](https://claude.com/claude-code)"

  # KEEP the 'working' label. The issue is still OPEN until the PR merges, so
  # releasing the lock here would put it straight back in the claimable pool and
  # let a peer redo the work the PR already contains (issue #14). The lock is
  # released when the merge closes the issue; if the PR is abandoned,
  # /monitor-workers reclaims the stale lock.
  echo "✅ PR created for issue #$ISSUE_NUM — awaiting review ('working' lock retained until merge)"
  # Log to history
  "${SCRIPT_DIR}/append-to-history.sh" --history-file "HISTORY.md" --backend auto \
    "PR #${ISSUE_NUM}: ${ISSUE_TITLE}" \
    "PR created on branch feature/issue-${ISSUE_NUM}." \
    "${ISSUE_BODY:0:150}" \
    "Awaiting code review."
else
  # Auto-merge to the shared integration branch (worktree-safe: never checks out the
  # integration branch, re-tests the combined tree, retries push on sibling races, and
  # escalates conflicts to a label instead of stranding work on main-wt-N).
  "${SCRIPT_DIR}/merge-to-integration.sh" \
    --feature "feature/issue-${ISSUE_NUM}" \
    --issue "$ISSUE_NUM" \
    --integration "$INTEGRATION_BRANCH" \
    --test-cmd "$TEST_COMMAND" \
    || { echo "⚠️  Merge to ${INTEGRATION_BRANCH} did not complete (see output above)."; exit 1; }

  # Clean up the local feature branch (merge-to-integration.sh already removed the remote)
  git branch -d "$FIX_BRANCH" 2>/dev/null || git branch -D "$FIX_BRANCH" 2>/dev/null || true

  # ── Ship gate (issue #35) ───────────────────────────────────────────────
  # #26's PUSH_OK guard answers "did the push succeed?". It cannot answer "did
  # this reach the branch that ships?" A worker branching from a feature line
  # pushes fine, merges fine, tests fine — and closes the issue while the
  # shipping branch is untouched. Every signal is green and the tracker is wrong.
  #
  # NOTE: checking ancestry of $INTEGRATION_BRANCH does NOT work. When the swarm's
  # integration branch is itself a feature line, a commit merged into it IS an
  # ancestor of it, so the check passes and the issue closes — which is the bug.
  # Ship is measured against the branch that actually ships.
  LANDED_COMMIT=$(git rev-parse HEAD)
  if "${SCRIPT_DIR}/verify-shipped.sh" "$LANDED_COMMIT"; then
    # Genuinely shipped — safe to close.
    issue_update "$ISSUE_NUM" --remove-label "working" 2>/dev/null || true
    issue_close "$ISSUE_NUM" --comment "✅ **Issue Resolved**

[Detailed explanation of fix]

**Branch**: \`feature/issue-${ISSUE_NUM}\` (merged and deleted)

🤖 Auto-resolved by autonomous fix workflow"
  else
    # Real work, really pushed, but NOT on the shipping branch. Closing here
    # would assert "shipped" falsely. Leave the issue OPEN, keep the lock
    # released, and record exactly what must merge for this to ship.
    SHIP_BRANCH_NAME="${CLAUDE_CODE_SHIP_BRANCH:-$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name 2>/dev/null || echo main)}"
    issue_update "$ISSUE_NUM" --remove-label "working" 2>/dev/null || true
    issue_update "$ISSUE_NUM" --add-label "awaiting-integration" 2>/dev/null || true
    issue_comment "$ISSUE_NUM" --body "⏳ **Fix complete, not yet shipped — leaving this issue OPEN**

The work is done, committed, and merged to \`${INTEGRATION_BRANCH}\` as \`${LANDED_COMMIT}\`. It has **not** reached \`${SHIP_BRANCH_NAME}\`, so closing would assert something false.

**To ship**: \`${INTEGRATION_BRANCH}\` must merge to \`${SHIP_BRANCH_NAME}\`.

Labelled \`awaiting-integration\` so it is findable rather than silently reopened as new work.

🤖 Ship gate (issue #35)"
    echo "⏳ Issue #$ISSUE_NUM left OPEN — merged to $INTEGRATION_BRANCH but not on the shipping branch"
  fi

# Write completion status file for agents-ui TUI monitoring
SESSION_NAME=$(tmux display-message -p '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null || echo "unknown")
echo "{\"status\": \"idle\", \"issue\": ${ISSUE_NUM}, \"title\": \"${ISSUE_TITLE}\", \"completed\": \"$(date -Iseconds)\"}" > "/tmp/agents-ui/${SESSION_NAME}.json"
  # Log to history
  "${SCRIPT_DIR}/append-to-history.sh" --history-file "HISTORY.md" --backend auto \
    "Fix #${ISSUE_NUM}: ${ISSUE_TITLE}" \
    "Resolved on feature/issue-${ISSUE_NUM}. Merged to ${INTEGRATION_BRANCH}." \
    "${ISSUE_BODY:0:150}" \
    "All tests passing. Branch merged and deleted."
fi
```

### Step 2B: Complex Issue - Use Superpowers (if available)

For complex issues requiring design and planning. If `SUPERPOWERS_AVAILABLE=true`, use superpowers skills. Otherwise, use direct problem-solving approaches.

**1. Bug Fixing / Systematic Debugging (if bugs)**

If the issue involves bugs or test failures:

```
# If peters-toolkit:bugfix available (preferred — handles the bug end to end):
Use Skill tool: peters-toolkit:bugfix
# (bare `bugfix` if that is the installed name)
# Do NOT also run systematic-debugging/TDD for the same bug.

# Else if superpowers available:
Use Skill tool: superpowers:systematic-debugging

# If neither available:
# - Reproduce the issue and capture error output
# - Trace through code to identify root cause
# - Form and test hypotheses
# - Document findings before implementing fix
```

This will:
- Investigate root cause thoroughly
- Analyze patterns across failures
- Test hypotheses before implementing
- Ensure understanding before solutions

**2. Brainstorming (if new features)**

If the issue requires new feature design:

```
# If thorough-brainstorming available (preferred):
Use Skill tool: thorough-brainstorming

# If superpowers available (fallback):
Use Skill tool: superpowers:brainstorming

# If neither available:
# - Explore 2-3 design alternatives
# - List pros/cons for each approach
# - Identify open questions and assumptions
# - Select approach with clear rationale
```

This will:
- Explore design alternatives
- Clarify requirements through questions
- Validate assumptions
- Refine rough ideas into concrete designs

**3. Writing Plans (for implementation)**

After design is complete, create implementation plan:

```
# If thorough-writing-plans available (preferred):
Use Skill tool: thorough-writing-plans

# If superpowers available (fallback):
Use Skill tool: superpowers:writing-plans

# If neither available:
# - Break work into numbered tasks (5-15 tasks)
# - Specify exact file paths and changes for each
# - Include verification command for each task
# - Order tasks by dependency
```

This will:
- Break down into bite-sized tasks
- Specify exact file paths and changes
- Include verification steps
- Assume zero prior codebase knowledge

**4. Executing Plans**

Execute the plan in controlled batches:

```
# If superpowers available:
Use Skill tool: superpowers:executing-plans

# If superpowers NOT available:
# - Execute 3-5 tasks at a time
# - Run verification after each batch
# - Stop and reassess if verification fails
# - Track completed vs remaining tasks
```

This will:
- Load and review the plan critically
- Execute tasks in batches
- Report progress for review between batches
- Track completion systematically

**5. Verification**

Before claiming complete, verify the fix:

```
# If superpowers available:
Use Skill tool: superpowers:verification-before-completion

# If superpowers NOT available:
# - Run all verification commands
# - Capture and review output
# - Confirm success criteria are met
# - Run full test suite before committing
```

This will:
- Run verification commands
- Confirm output shows success
- Provide evidence before assertions
- Ensure tests pass before committing

### Step 3: Commit and Close

After verification passes:

```bash
# Commit changes
git add -A
git commit -m "Fix #${ISSUE_NUM}: Brief description

Detailed multi-line explanation of:
- Root cause analysis
- Solution approach
- Changes made
- Verification results

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>"

# Push feature branch
# Publish the branch. `git push` first; if the transport is blocked (e.g. a
# proxy rejecting git-receive-pack with HTTP 403), fall back to the GitHub API.
# PUSH_OK records whether the work ACTUALLY LANDED — never infer it from a
# command's exit status alone, and never from `git push --dry-run`, which
# succeeds against a blocked transport because it never sends the pack.
PUSH_OK=false
if git push -u origin "feature/issue-${ISSUE_NUM}"; then
  PUSH_OK=true
else
  echo "⚠️  git push failed — trying the GitHub API fallback..."
  if python3 "${SCRIPT_DIR}/api-push.py" "feature/issue-${ISSUE_NUM}" --base "origin/${INTEGRATION_BRANCH:-master}"; then
    PUSH_OK=true
  fi
fi

if [ "$PUSH_OK" != true ]; then
  # The code did not land. Closing now would make the tracker claim something
  # false, and would strand the work (see #26). Leave the issue open, KEEP the
  # 'working' label, and say so.
  issue_comment "$ISSUE_NUM" --body "⚠️ **Publication failed — issue left open**

Both \`git push\` and the GitHub API fallback failed, so the fix has NOT landed.
The issue stays open and keeps its \`working\` label so the work is not lost or
silently redone.

Local branch: \`feature/issue-${ISSUE_NUM}\`" 2>/dev/null || true
  echo "❌ Could not publish feature/issue-${ISSUE_NUM} — issue $ISSUE_NUM left OPEN (nothing was closed)"
  exit 1
fi

if [ "$MERGE_MODE" = "pr" ]; then
  # Create a pull request and stop
  gh pr create \
    --base "$INTEGRATION_BRANCH" \
    --head "feature/issue-${ISSUE_NUM}" \
    --title "Fix #${ISSUE_NUM}: Brief description" \
    --body "Closes #${ISSUE_NUM}

## Root Cause
[Detailed analysis]

## Solution
[Approach taken]

## Changes Made
[List of changes]

## Verification
[Test results and evidence]

🤖 Generated with [Claude Code](https://claude.com/claude-code)"

  # KEEP the 'working' label. The issue is still OPEN until the PR merges, so
  # releasing the lock here would put it straight back in the claimable pool and
  # let a peer redo the work the PR already contains (issue #14). The lock is
  # released when the merge closes the issue; if the PR is abandoned,
  # /monitor-workers reclaims the stale lock.
  echo "✅ PR created for issue #$ISSUE_NUM — awaiting review ('working' lock retained until merge)"
  # Log to history
  "${SCRIPT_DIR}/append-to-history.sh" --history-file "HISTORY.md" --backend auto \
    "PR #${ISSUE_NUM}: ${ISSUE_TITLE}" \
    "PR created on branch feature/issue-${ISSUE_NUM}." \
    "${ISSUE_BODY:0:150}" \
    "Awaiting code review."
else
  # Auto-merge to the shared integration branch (worktree-safe: never checks out the
  # integration branch, re-tests the combined tree, retries push on sibling races, and
  # escalates conflicts to a label instead of stranding work on main-wt-N).
  "${SCRIPT_DIR}/merge-to-integration.sh" \
    --feature "feature/issue-${ISSUE_NUM}" \
    --issue "$ISSUE_NUM" \
    --integration "$INTEGRATION_BRANCH" \
    --test-cmd "$TEST_COMMAND" \
    || { echo "⚠️  Merge to ${INTEGRATION_BRANCH} did not complete (see output above)."; exit 1; }

  # Clean up the local feature branch (merge-to-integration.sh already removed the remote)
  git branch -d "$FIX_BRANCH" 2>/dev/null || git branch -D "$FIX_BRANCH" 2>/dev/null || true

  # Remove 'working' label and close issue with detailed explanation
  issue_update "$ISSUE_NUM" --remove-label "working" 2>/dev/null || true
  issue_close "$ISSUE_NUM" --comment "✅ **Issue Resolved**

## Root Cause
[Detailed analysis]

## Solution
[Approach taken]

## Changes Made
[List of changes]

## Verification
[Test results and evidence]

**Branch**: \`feature/issue-${ISSUE_NUM}\` (merged and deleted)
**Commit**: [commit hash]

🤖 Auto-resolved by autonomous fix workflow with superpowers"

# Write completion status file for agents-ui TUI monitoring
SESSION_NAME=$(tmux display-message -p '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null || echo "unknown")
echo "{\"status\": \"idle\", \"issue\": ${ISSUE_NUM}, \"title\": \"${ISSUE_TITLE}\", \"completed\": \"$(date -Iseconds)\"}" > "/tmp/agents-ui/${SESSION_NAME}.json"
  # Log to history
  "${SCRIPT_DIR}/append-to-history.sh" --history-file "HISTORY.md" --backend auto \
    "Fix #${ISSUE_NUM}: ${ISSUE_TITLE}" \
    "Resolved on feature/issue-${ISSUE_NUM}. Merged to ${INTEGRATION_BRANCH}." \
    "${ISSUE_BODY:0:150}" \
    "All tests passing. Branch merged and deleted."
fi
```

## Example Workflow

### Simple Issue Example:
```
Issue #240: TypeScript compilation errors in disabled-features
→ Direct fix: Delete broken test files
→ Verify: $BUILD_COMMAND (from CLAUDE.md autocoder config)
→ Commit and close
```

### Complex Issue Example:
```
Issue #222: Review Management system broken (~30 test failures)
→ Complexity detected: >30 failures, multiple components
→ Use peters-toolkit:bugfix (preferred) or superpowers:systematic-debugging
  - Investigate root cause
  - Analyze test failure patterns
  - Identify common issues
→ Use thorough-brainstorming (preferred) or superpowers:brainstorming
  - Design fix approach
  - Validate assumptions
→ Use thorough-writing-plans (preferred) or superpowers:writing-plans
  - Create implementation plan
  - Break into tasks
→ Use superpowers:executing-plans
  - Execute in batches
  - Review between batches
→ Use superpowers:verification-before-completion
  - Run all tests
  - Confirm passing
→ Commit and close with evidence
```

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

### Detection Process

**Step 1: Read the issue carefully**

Look for these red flags:
- **Vague or incomplete**: No specific steps, missing context, unclear acceptance criteria → `needs-clarification`
- **Multiple solutions**: Several valid approaches, trade-offs unclear, design needed → `needs-design`
- **Major decision**: Architectural change, breaking change, security impact → `needs-approval`
- **Too large**: >100 test failures, affects multiple systems, irreversible → `too-complex`

**Step 2: If blocked, add label and skip**

```bash
BLOCKING_LABEL=""  # Will be set to one of: needs-clarification, needs-design, needs-approval, too-complex
BLOCKING_REASON=""  # Human-readable explanation

# Example: Issue has unclear requirements
if [issue description is vague or missing critical information]; then
  BLOCKING_LABEL="needs-clarification"
  BLOCKING_REASON="Issue description is unclear. Need specific details about: [what's missing]"
fi

# Example: Issue requires design decisions
#
# IMPORTANT: when applying `needs-design`, BLOCKING_REASON MUST explain
# *what specifically* needs designing. Do not leave placeholder text — the
# script rejects reasons containing unfilled brackets like `[list options]`.
#
# Write a multi-line reason covering, at minimum:
#   - The specific design questions that are open (1–N concrete questions)
#   - The candidate approaches you considered and why none is the clear winner
#   - What artifact would unblock the work (ADR? spec doc? a decision from a named owner?)
#
# Example of a good reason:
#   "Issue asks for 'real-time notifications' but doesn't specify transport.
#    Open questions:
#    1. SSE (we use it elsewhere) vs WebSocket vs polling?
#    2. Who is the audience — engagement participants only, or all users?
#    3. Persistence semantics — at-least-once? best-effort?
#    Approaches considered:
#    - SSE: matches existing infra but only server-push.
#    - WebSocket: bidirectional but new infra surface.
#    Needs an ADR or a decision from the platform owner before implementation."
if [multiple approaches possible, no clear winner]; then
  BLOCKING_LABEL="needs-design"
  BLOCKING_REASON="$(cat <<'NEEDS_DESIGN_REASON'
<one-paragraph summary of what is undecided>

Open questions:
1. <specific question>
2. <specific question>

Approaches considered:
- <approach>: <pros/cons>
- <approach>: <pros/cons>

Unblocks when: <ADR/spec/decision-owner that needs to land>
NEEDS_DESIGN_REASON
)"
fi

# Example: Issue requires architectural approval
if [breaking change or major architectural decision]; then
  BLOCKING_LABEL="needs-approval"
  BLOCKING_REASON="This requires architectural decision: [describe the decision]"
fi

# Example: Issue is too complex for autonomous resolution
if [>100 test failures or cross-cutting concerns]; then
  BLOCKING_LABEL="too-complex"
  BLOCKING_REASON="Too large for autonomous resolution: [describe complexity]"
fi

# If a blocking label was identified, use the script to add it and skip
if [ -n "$BLOCKING_LABEL" ]; then
  # Determine script location (portable across different plugin install locations)
  SCRIPT_DIR="$HOME/.claude/plugins/autocoder/scripts"

  bash "$SCRIPT_DIR/add-blocking-label.sh" "$ISSUE_NUM" "$BLOCKING_LABEL" "$BLOCKING_REASON"
  # Log to history
  "${SCRIPT_DIR}/append-to-history.sh" --history-file "HISTORY.md" --backend auto \
    "Blocked #${ISSUE_NUM}: ${ISSUE_TITLE}" \
    "Added label: ${BLOCKING_LABEL}." \
    "${BLOCKING_REASON:0:200}" \
    "Requires human review before proceeding."

  echo "⏭️  Skipping to next issue..."
  echo ""
  # Continue to next issue in the workflow
fi
```

**Step 3: If not blocked, proceed with fix**

If no blocking conditions detected, continue with the normal fix workflow (simple vs complex vs ultra-complex determination).

### Ultra-Complex Issues - Decompose into Sub-Tasks

This section is triggered both by the **task scope gate** (above, at claim time) and by the
complexity assessment (Step 1) when you discover mid-implementation that the scope is larger than expected.

For issues too large for autonomous resolution (>100 test failures, major architecture changes, significant trade-off decisions, or issues that fail the scope gate):

**Decomposition rules — each sub-task MUST satisfy ALL of these:**

1. **Context fit**: Completable in one agent conversation (not "migrate everything", not "audit all files")
2. **Worktree independence**: Touches a distinct set of files from sibling sub-tasks — no sub-task may edit the same file as another sibling that could run concurrently. If two sub-tasks MUST touch the same file, sequence them (sub-task B depends on sub-task A) and describe that dependency in the body.
3. **Testable in isolation**: Has its own acceptance criteria and can be verified independently.
4. **No shared in-flight state**: Does not require uncommitted changes from a sibling sub-task to compile or pass tests.

**First, attempt to decompose the issue into manageable sub-tasks:**

```bash
echo "⚠️  Issue requires decomposition: attempting breakdown"

# Use brainstorming skill to analyze and decompose the complex issue
if [ "$SUPERPOWERS_AVAILABLE" = "true" ] || [ "$THOROUGH_SKILLS_AVAILABLE" = "true" ]; then
  echo "📋 Using thorough-brainstorming (preferred) or superpowers:brainstorming to decompose issue #$ISSUE_NUM..."
  # Prompt: "Decompose issue #$ISSUE_NUM into 3-8 sub-tasks. Each sub-task must:
  # (a) fit in one agent context window, (b) touch a DISTINCT set of files from
  # every other sub-task so they can run in parallel worktrees without merge conflicts,
  # (c) be independently testable. List any sub-tasks that must run after another
  # (sequential dependencies). For each, provide: title, description, files affected,
  # acceptance criteria, priority, and dependencies."

  # After decomposition analysis is complete, create GitHub issues for each sub-task
  # Store sub-task numbers for linking
  SUBTASK_NUMBERS=()

  # Example sub-task creation (repeat for each decomposed task):
  # for SUBTASK in "${SUBTASKS[@]}"; do
  SUBTASK_RESULT=$(issue_create \
    --label "bug" --label "P2" --label "subtask" \
    --title "Subtask: [Brief description]" \
    --body "$(cat <<SUBTASK_BODY
## Sub-task of #${ISSUE_NUM}

This is a decomposed sub-task from the larger issue #${ISSUE_NUM}.

## Description
[What needs to be done in this specific sub-task]

## Files Affected
[List specific files or directories this sub-task will modify. This MUST NOT overlap
with the files listed in sibling sub-tasks unless those sub-tasks have a sequential
dependency (listed below). Overlapping file lists = merge conflict in the worktree swarm.]

## Acceptance Criteria
- [ ] Criterion 1
- [ ] Criterion 2
- [ ] Criterion 3

## Dependencies
- Sub-task of #${ISSUE_NUM}
- [Depends on: #<sibling-subtask-number> — reason why this must run after that one]
- [Can run in parallel with: #<sibling-subtask-number>]

## Testing
[How to verify this sub-task is complete in isolation, without sibling sub-tasks merged]

---

🤖 Auto-decomposed from #${ISSUE_NUM} by autonomous fix workflow
SUBTASK_BODY
)")
  SUBTASK_NUM=$(echo "$SUBTASK_RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin)['number'])")

  SUBTASK_NUMBERS+=("$SUBTASK_NUM")
  echo "✅ Created sub-task #$SUBTASK_NUM"
  # done

  # Release the parent issue claim before exiting — workers will pick up sub-tasks.
  # Terminal outcome only: release it via the explicit-release path below.
  issue_update "$ISSUE_NUM" --remove-label "working" 2>/dev/null || true
  issue_release "$ISSUE_NUM" 2>/dev/null || true

  # Update original issue to reference all sub-tasks
  issue_comment "$ISSUE_NUM" --body "🔍 **Issue Decomposed into Sub-Tasks**

This issue has been broken down into independently-workable sub-tasks that can
run in parallel worktrees without merge conflicts:

$(for num in "${SUBTASK_NUMBERS[@]}"; do echo "- [ ] #$num"; done)

**Parallel safety**: each sub-task touches different files. Check each sub-task's
\"Files Affected\" section before assigning to confirm no overlap.

**Status**: This issue will be automatically closed once all sub-tasks are completed and verified.

🤖 Auto-decomposed by autonomous fix workflow"

  # Add label to indicate decomposition
  issue_update "$ISSUE_NUM" --add-label "decomposed" 2>/dev/null || true

  echo "✅ Decomposed issue #$ISSUE_NUM into ${#SUBTASK_NUMBERS[@]} sub-tasks"
  echo "📋 Sub-tasks: ${SUBTASK_NUMBERS[*]}"
  echo ""
  echo "⏭️  Claim released. Sub-tasks will be picked up by workers on the next tick."

else
  # Fallback: If superpowers not available, add too-complex label
  echo "ℹ️  Superpowers not available for decomposition"

  # Prepare detailed reason for blocking
  COMPLEXITY_REASON="Ultra-complex issue requiring decomposition or human guidance.

**Complexity Indicators**:
- [List specific indicators: >100 test failures, major architectural change, etc.]

**Recommended Approach**:
- Manually decompose into smaller sub-tasks
- Use /review-blocked to interactively review this issue
- Consider using superpowers plugin for assisted decomposition

**Available Tools**:
$(if [ "$QUINT_AVAILABLE" = "true" ]; then
  echo "- ✅ Quint plugin available for structured reasoning"
else
  echo "- ℹ️  Quint plugin not installed - manual review recommended"
fi)"

  # Determine script location (portable across different plugin install locations)
  SCRIPT_DIR="$HOME/.claude/plugins/autocoder/scripts"

  # Use the script to add blocking label
  bash "$SCRIPT_DIR/add-blocking-label.sh" "$ISSUE_NUM" "too-complex" "$COMPLEXITY_REASON"

  echo "⏭️  Issue labeled as too-complex. Use /review-blocked to review."
fi

echo ""
# Continue to next issue
```

**Monitoring Decomposed Issues**:

When processing issues in the main loop, check for decomposed issues where all sub-tasks are complete:

```bash
# After fixing each issue, check if it was a sub-task that completes a decomposed issue
# Get parent issue if this was a subtask
PARENT_ISSUE=$(issue_get "$ISSUE_NUM" | jq -r '.body' | sed -nE 's/.*Sub-task of #([0-9]+).*/\\1/p' || echo "")

if [ -n "$PARENT_ISSUE" ]; then
  echo "🔍 Checking if parent issue #$PARENT_ISSUE is now complete..."

  # Check if all sub-tasks of parent are closed
  PARENT_SUBTASKS=$(issue_get "$PARENT_ISSUE" | jq -r '.body' | grep -oE '#[0-9]+' | tr -d '#' || echo "")
  ALL_CLOSED=true

  for SUBTASK_NUM in $PARENT_SUBTASKS; do
    SUBTASK_STATE=$(issue_get "$SUBTASK_NUM" | jq -r '.state')
    if [ "$SUBTASK_STATE" != "CLOSED" ]; then
      ALL_CLOSED=false
      break
    fi
  done

  if [ "$ALL_CLOSED" = "true" ]; then
    echo "✅ All sub-tasks complete! Closing parent issue #$PARENT_ISSUE"
    issue_close "$PARENT_ISSUE" --comment "✅ **Complex Issue Resolved**

All sub-tasks have been completed and verified:

$(for num in $PARENT_SUBTASKS; do echo "- ✅ #$num"; done)

The decomposed approach successfully resolved this complex issue.

🤖 Auto-closed by autonomous fix workflow"
  fi
fi
```

### Skip Criteria (Legacy)

Skip to next issue if:
- Issue requires external dependencies (API keys, services) → add `needs-clarification` label
- Issue is blocked by another issue → add comment, don't add blocking label
- Issue requires user input/decision → add appropriate blocking label (`needs-approval`, `needs-design`, or `needs-clarification`)

## No Priority Issues Found

If no issues with P0-P3 labels exist, run full regression testing:

### Step 1: Run Full Regression Test

Use the `/full-regression-test` command to run the complete test suite:

```
/full-regression-test
```

This command will:
- Load test configuration from CLAUDE.md
- Run build verification
- Run unit tests
- Run E2E tests (if configured)
- Analyze failures and assign priorities
- Create/update GitHub issues for each failure
- Generate a detailed report

### Step 2: Review Results

After `/full-regression-test` completes:

- **If failures found**: Issues are created with priority labels (P0-P3)
- **If all pass**: No new issues created

Check newly created issues:

```bash
# View issues created by regression test
issue_list --state open --label "test-failure" --limit 20
```

### Step 3: Continue Workflow

After regression testing:

- **If issues were created** → Continue fixing (workflow picks them up automatically)
- **If all tests passed** → Move to Enhancement Phase (Step 5)

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
blocking_labels = ['needs-approval', 'needs-design', 'needs-clarification', 'too-complex', 'future']
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
blocking_labels = ['needs-approval', 'needs-design', 'needs-clarification', 'too-complex', 'future']
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

If no enhancement issues exist, analyze the codebase and propose improvements:

**First, check test coverage** using the persistent coverage report:

```bash
# Fast path: Read existing report if available
if [ -f "test-coverage.md" ]; then
  echo "📊 Reading test-coverage.md (fast path)"
  # Parse coverage from report header
  OVERALL_COV=$(grep "Overall Coverage" test-coverage.md | grep -oE '[0-9]+' | head -1)
  echo "Current coverage: ${OVERALL_COV}%"

  # Show lowest coverage areas from report
  echo ""
  echo "Areas needing coverage:"
  grep -E "<!-- COVERAGE: [0-9]+%" test-coverage.md | head -5
else
  # No report exists - run full analysis to create it
  echo "📊 No test-coverage.md found, running full analysis..."
  /improve-test-coverage --analyze
fi
```

If coverage is below 80%, use `/improve-test-coverage` to improve it (this uses the fast path when test-coverage.md exists).

**Then use `thorough-brainstorming` (preferred) or `superpowers:brainstorming`** to identify other valuable enhancements:

```
# If thorough-brainstorming available (preferred):
Use Skill tool: thorough-brainstorming

# If superpowers available (fallback):
Use Skill tool: superpowers:brainstorming
```

Focus areas for enhancement proposals:
1. **Test Coverage** - Use `/improve-test-coverage` to improve gaps (reads from test-coverage.md)
2. **Code Quality** - Complex functions to refactor, duplication to reduce
3. **Performance** - Slow queries, caching opportunities, bundle optimization
4. **Documentation** - API docs, code examples, best practices

**Create Enhancement Proposal** (tagged with `proposal` label for human review):

```bash
PROPOSAL_RESULT=$(issue_create \
  --label "enhancement" --label "proposal" --label "P3" \
  --title "Proposal: [Brief description]" \
  --body "$(cat <<'ENHANCEMENT_BODY'
## Proposed Enhancement

[Detailed description of what this enhancement accomplishes]

## Rationale

[Why this improvement is valuable - metrics, user impact, maintainability]

## Implementation Plan

### Phase 1: [First phase]
- [ ] Task 1.1
- [ ] Task 1.2

### Phase 2: [Second phase]
- [ ] Task 2.1
- [ ] Task 2.2

### Phase 3: Verification
- [ ] Run full test suite
- [ ] Manual verification of feature
- [ ] Update documentation

## Success Criteria

- [ ] All existing tests pass
- [ ] New tests added for enhancement
- [ ] Documentation updated
- [ ] No performance regression

## Estimated Complexity

[Simple | Medium | Complex]

---

## 📋 Proposal Status

**Status**: ⏳ Awaiting Human Approval

### How to Approve This Proposal

To approve and allow automated implementation:
```bash
/update-issue <issue_number> --remove-label "proposal"
```

### How to Provide Feedback

Comment on this issue with your feedback. The AI will incorporate your suggestions when you run `/refine-proposal <issue_number>`.

### How to Reject This Proposal

```bash
/close-issue <issue_number> "Rejected: [reason]"
```

---

🤖 Proposed by autonomous improvement workflow
ENHANCEMENT_BODY
)")
PROPOSAL_NUM=$(echo "$PROPOSAL_RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin)['number'])")

echo "✅ Created proposal issue #${PROPOSAL_NUM}. Awaiting human approval before implementation."
echo "💡 Use '/list-proposals' to view all pending proposals"
echo ""

# Write idle status file for agents-ui TUI monitoring
SESSION_NAME=$(tmux display-message -p '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null || echo "unknown")
echo "{\"status\": \"idle\", \"completed\": \"$(date -Iseconds)\"}" > "/tmp/agents-ui/${SESSION_NAME}.json"

echo "IDLE_NO_WORK_AVAILABLE"
```

**IMPORTANT**: After creating a proposal, output `IDLE_NO_WORK_AVAILABLE` to trigger the sleep cycle. This gives humans time to review the proposal before the next iteration. Do NOT immediately create more proposals or loop without sleeping.

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
  # Terminal outcome only: setup failed before any work began — Releasing and aborting.
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
    # Terminal outcome only: setup failed before any work began — Releasing and aborting.
    issue_update "$ENHANCE_NUM" --remove-label "working" 2>/dev/null || true
    exit 1
  }
else
  echo "❌ Could not create or switch to $ENHANCE_BRANCH."
  # Terminal outcome only: setup failed before any work began — Releasing and aborting.
  issue_update "$ENHANCE_NUM" --remove-label "working" 2>/dev/null || true
  exit 1
fi
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ "$CURRENT_BRANCH" != "$ENHANCE_BRANCH" ]; then
  echo "❌ Could not switch to $ENHANCE_BRANCH (still on $CURRENT_BRANCH) — aborting"
  echo "   rather than implementing on the parent branch."
  exit 1
fi

# Claim-then-verify: claim through issue_claim so the file backend's atomic rename
# arbitrates, then run the same marker/settlement arbitration as the bug path.
issue_claim "$ENHANCE_NUM" 2>/dev/null
claim_rc=$?
if [ "$claim_rc" -ne 0 ]; then
  echo "⚠️  Lost claim race on enhancement #$ENHANCE_NUM. Skipping."
  git checkout "$PARENT_BRANCH" 2>/dev/null || true
  exit 0
fi

if [ "${ISSUE_SOURCE:-}" = "github" ]; then
  issue_comment "$ENHANCE_NUM" --body "🔒 [autocoder-claim] Starting enhancement #${ENHANCE_NUM} — lock established" 2>/dev/null || true
  sleep 3
  CLAIM_MARKER_COUNT=$(issue_get "$ENHANCE_NUM" 2>/dev/null | jq \
    '[.comments[] | select(.body | test("\\[autocoder-claim\\]"))] | length' \
    2>/dev/null || echo "0")
  PRIOR_STARTED=$(issue_get "$ENHANCE_NUM" 2>/dev/null | jq \
    '[.comments[] | select(.body | test("Enhancement Implementation Started")) | select(.body | test("\\[autocoder-claim\\]") | not)] | length' \
    2>/dev/null || echo "0")
else
  sleep 1
  CLAIM_MARKER_COUNT=0
  PRIOR_STARTED=$(issue_get "$ENHANCE_NUM" 2>/dev/null | jq \
    '[.comments[] | select(.body | test("Enhancement Implementation Started"))] | length' \
    2>/dev/null || echo "0")
fi

if [ "$CLAIM_MARKER_COUNT" -gt 1 ] || [ "$PRIOR_STARTED" -gt 0 ]; then
  echo "⚠️  Race condition on enhancement #$ENHANCE_NUM. Releasing and aborting."
  # MUST release: we are surrendering a claim we never began work under. Leaving the
  # label set here would strand the enhancement with no worker holding it.
  issue_release "$ENHANCE_NUM" 2>/dev/null || issue_update "$ENHANCE_NUM" --remove-label "working" 2>/dev/null || true
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

  # Use verification skill before claiming complete
  # Use Skill tool: superpowers:verification-before-completion

  # Commit changes
  git add -A
  git commit -m "Implement enhancement #${ENHANCE_NUM}: ${ENHANCE_TITLE}

Detailed explanation of:
- What was implemented
- Design decisions made
- Tests added/modified

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>"

  # Push feature branch
  # Publish the branch. `git push` first; if the transport is blocked (e.g. a
  # proxy rejecting git-receive-pack with HTTP 403), fall back to the GitHub API.
  # PUSH_OK records whether the work ACTUALLY LANDED — never infer it from a
  # command's exit status alone, and never from `git push --dry-run`, which
  # succeeds against a blocked transport because it never sends the pack.
  PUSH_OK=false
  if git push -u origin "enhancement/issue-${ENHANCE_NUM}-auto"; then
    PUSH_OK=true
  else
    echo "⚠️  git push failed — trying the GitHub API fallback..."
    if python3 "${SCRIPT_DIR}/api-push.py" "enhancement/issue-${ENHANCE_NUM}-auto" --base "origin/${INTEGRATION_BRANCH:-master}"; then
      PUSH_OK=true
    fi
  fi

  if [ "$PUSH_OK" != true ]; then
    # The code did not land. Closing now would make the tracker claim something
    # false, and would strand the work (see #26). Leave the issue open, KEEP the
    # 'working' label, and say so.
    issue_comment "$ENHANCE_NUM" --body "⚠️ **Publication failed — issue left open**

  Both \`git push\` and the GitHub API fallback failed, so the fix has NOT landed.
  The issue stays open and keeps its \`working\` label so the work is not lost or
  silently redone.

  Local branch: \`enhancement/issue-${ENHANCE_NUM}-auto\`" 2>/dev/null || true
    echo "❌ Could not publish enhancement/issue-${ENHANCE_NUM}-auto — issue $ENHANCE_NUM left OPEN (nothing was closed)"
    exit 1
  fi

  # Auto-merge to the shared integration branch (worktree-safe: never checks out the
  # integration branch, re-tests the combined tree, retries push on sibling races, and
  # escalates conflicts to a label instead of stranding work on main-wt-N).
  "${SCRIPT_DIR}/merge-to-integration.sh" \
    --feature "enhancement/issue-${ENHANCE_NUM}-auto" \
    --issue "$ENHANCE_NUM" \
    --integration "$INTEGRATION_BRANCH" \
    --test-cmd "$TEST_COMMAND" \
    || { echo "⚠️  Merge to ${INTEGRATION_BRANCH} did not complete (see output above)."; exit 1; }

  # Clean up the local enhancement branch (merge-to-integration.sh already removed the remote)
  git branch -d "$ENHANCE_BRANCH" 2>/dev/null || git branch -D "$ENHANCE_BRANCH" 2>/dev/null || true

  # Remove 'working' label and close enhancement with details
  issue_update "$ENHANCE_NUM" --remove-label "working" 2>/dev/null || true
  issue_close "$ENHANCE_NUM" --comment "✅ **Enhancement Implemented**

## Summary
[What was implemented]

## Changes Made
[List of changes]

## Tests
- All existing tests pass
- New tests added: [list new tests]

## Verification
[Evidence that enhancement works correctly]

**Branch**: \`enhancement/issue-${ENHANCE_NUM}-auto\` (merged and deleted)

🤖 Auto-implemented by autonomous enhancement workflow"

  # Write completion status file for agents-ui TUI monitoring
  SESSION_NAME=$(tmux display-message -p '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null || echo "unknown")
  echo "{\"status\": \"idle\", \"issue\": ${ENHANCE_NUM}, \"title\": \"${ENHANCE_TITLE}\", \"completed\": \"$(date -Iseconds)\"}" > "/tmp/agents-ui/${SESSION_NAME}.json"
fi
```

**If Tests Fail - Create Bug Issues**:

```bash
if [ $TEST_EXIT_CODE -ne 0 ]; then
  echo "❌ Tests failed during enhancement implementation"

  # Parse test failures and create issues for each
  # Extract failing test names and create individual issues

  issue_create \
    --label "bug" --label "test-failure" --label "P1" \
    --title "Test failure during enhancement #${ENHANCE_NUM}: [Test name]" \
    --body "$(cat <<FAILURE_BODY
## Test Failure

**Related Enhancement**: #${ENHANCE_NUM}
**Branch**: \`enhancement/issue-${ENHANCE_NUM}-auto\`

## Failing Test
\`\`\`
[Test name and location]
\`\`\`

## Error Output
\`\`\`
${TEST_OUTPUT}
\`\`\`

## Context
This test failure occurred while implementing enhancement #${ENHANCE_NUM}.

## Suggested Investigation
1. Check if enhancement changes broke existing functionality
2. Verify test expectations are still valid
3. Check for missing dependencies or setup

🤖 Created by autonomous enhancement workflow
FAILURE_BODY
)"

  # Comment on enhancement issue about the failure
  issue_comment "$ENHANCE_NUM" --body "⚠️ **Implementation Blocked by Test Failures**

Test failures occurred during implementation. Bug issues have been created:
- [List created bug issue numbers]

Enhancement implementation paused. Will resume after bugs are fixed.

🤖 Autonomous enhancement workflow"

  # Do NOT merge - leave branch for investigation
  echo "⚠️ Enhancement branch preserved for investigation: enhancement/issue-${ENHANCE_NUM}-auto"

  # KEEP the 'working' label. The enhancement is PAUSED, not finished — the
  # branch is preserved and this worker intends to resume once the bug issues
  # land. Releasing here would re-expose an issue that already has unmerged work
  # on a branch (issue #14). Release it only if you are truly abandoning the
  # enhancement, and then use the explicit-release path (comment + label removal).
  echo "⏸️  Enhancement #$ENHANCE_NUM paused ('working' lock retained; branch preserved)"

  # Switch back to main
  git checkout main
fi
```

#### 5E: Enhancement Skip Criteria

Skip an enhancement and move to the next if:
- Enhancement requires external services not available
- Enhancement scope is too large (>50 files affected)
- Enhancement has unresolved dependencies on other issues
- Enhancement requires user decisions not documented

```bash
# Explicit release: announce the hand-off FIRST, then drop the lock, so peers
# and /monitor-workers see a deliberate release rather than a vanished lock.
issue_comment "$ENHANCE_NUM" --body "🔓 **Enhancement Skipped — releasing claim**

This enhancement cannot be automatically implemented because:
[Reason]

**Recommendation**: [What manual steps are needed]
**State left behind**: [what exists on the branch, if anything]

Releasing the \`working\` lock so another agent can pick this up.

🤖 Autonomous enhancement workflow"

# Terminal outcome only: this is an abandonment, paired with the release comment above.
issue_update "$ENHANCE_NUM" --remove-label "working" 2>/dev/null || true

# Add 'needs-review' label
issue_update "$ENHANCE_NUM" --add-label "needs-review"
```

---

## MANDATORY: Continuous Loop

**THIS WORKFLOW RUNS FOREVER UNTIL MANUALLY STOPPED.**

### Context Compaction (MANDATORY — DO THIS EVERY ITERATION)

> ⛔ **Run `/compact` (Claude Code) — or clear/compact the session context (Codex / Gemini / other) — BEFORE starting each new issue. Every iteration. No exceptions.**
>
> The loop runs forever. Without compaction between issues the context window fills and the agent dies mid-fix. Compaction is what makes "runs forever" actually possible. Skipping it is the #1 cause of a dev-loop crashing partway through an issue.

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

After every issue is resolved, skipped, or when checking for work:

```bash
# Fetch all open issues
issue_list --state open --limit 100 > /tmp/all-issues.json

# Count priority bug issues (P0-P3, excluding proposals, blocked, decomposed, and issues being worked on)
PRIORITY_ISSUES=$(cat /tmp/all-issues.json | python3 -c "
import json, sys
issues = json.load(sys.stdin)
blocking_labels = ['needs-approval', 'needs-design', 'needs-clarification', 'too-complex', 'future', 'decomposed']
priority = [i for i in issues
            if any(l['name'] in ['P0','P1','P2','P3'] for l in i.get('labels',[]))
            and not any(l['name'] == 'proposal' for l in i.get('labels',[]))
            and not any(l['name'] == 'working' for l in i.get('labels',[]))
            and not any(l['name'] in blocking_labels for l in i.get('labels',[]))]
print(len(priority))
")

# Count APPROVED enhancement issues (enhancement label but NOT proposal, blocked, or working label)
APPROVED_ENHANCEMENTS=$(cat /tmp/all-issues.json | python3 -c "
import json, sys
issues = json.load(sys.stdin)
blocking_labels = ['needs-approval', 'needs-design', 'needs-clarification', 'too-complex', 'future']
approved = [i for i in issues
            if any(l['name'] == 'enhancement' for l in i.get('labels',[]))
            and not any(l['name'] == 'proposal' for l in i.get('labels',[]))
            and not any(l['name'] == 'working' for l in i.get('labels',[]))
            and not any(l['name'] in blocking_labels for l in i.get('labels',[]))]
print(len(approved))
")

# Count pending proposals
PENDING_PROPOSALS=$(cat /tmp/all-issues.json | python3 -c "
import json, sys
issues = json.load(sys.stdin)
proposals = [i for i in issues if any(l['name'] == 'proposal' for l in i.get('labels',[]))]
print(len(proposals))
")

if [ "$PRIORITY_ISSUES" -gt 0 ]; then
  echo "🐛 Found $PRIORITY_ISSUES priority bug(s). Fixing bugs first..."
  # Process next bug issue (repeat from "Get highest priority issue" section)
elif [ "$APPROVED_ENHANCEMENTS" -gt 0 ]; then
  echo "🚀 No bugs! Found $APPROVED_ENHANCEMENTS approved enhancement(s). Implementing..."
  # Process next approved enhancement (Step 5C)
else
  echo "✨ No bugs or approved enhancements."

  # Count blocked issues
  BLOCKED_ISSUES_COUNT=$(cat /tmp/all-issues.json | python3 -c "
import json, sys
issues = json.load(sys.stdin)
blocking_labels = ['needs-approval', 'needs-design', 'needs-clarification', 'too-complex', 'future']
blocked = [i for i in issues if any(l['name'] in blocking_labels for l in i.get('labels', []))]
print(len(blocked))
")

  if [ "$PENDING_PROPOSALS" -gt 0 ] || [ "$BLOCKED_ISSUES_COUNT" -gt 0 ]; then
    if [ "$PENDING_PROPOSALS" -gt 0 ]; then
      echo "📋 $PENDING_PROPOSALS proposal(s) awaiting human approval."
      echo "💡 Use '/list-proposals' to review pending proposals"
    fi
    if [ "$BLOCKED_ISSUES_COUNT" -gt 0 ]; then
      echo "🚫 $BLOCKED_ISSUES_COUNT issue(s) blocked (requires human review)."
      echo "💡 Use '/review-blocked' to review and approve blocked issues"
    fi
    echo "💤 Nothing to do until proposals/blocked issues are approved or new issues arrive."
    echo ""

    # Write idle status file for agents-ui TUI monitoring
    SESSION_NAME=$(tmux display-message -p '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null || echo "unknown")
    echo "{\"status\": \"idle\", \"completed\": \"$(date -Iseconds)\"}" > "/tmp/agents-ui/${SESSION_NAME}.json"

    echo "IDLE_NO_WORK_AVAILABLE"
  else
    echo "No pending proposals or blocked issues. Will brainstorm new proposals..."
    # Run /full-regression-test first if not recently run
    # Then brainstorm proposals using thorough-brainstorming (preferred) or superpowers:brainstorming
    # After creating proposals, output IDLE_NO_WORK_AVAILABLE
  fi
fi
```

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

### What is a Proposal?

A **proposal** is an AI-generated enhancement suggestion that requires human review before implementation. Proposals are tagged with the `proposal` label and will NOT be automatically implemented.

### How to Review Proposals

Use the `/list-proposals` command to see all pending proposals:

```bash
/list-proposals
```

### How to Approve a Proposal

To approve a proposal for automated implementation, remove the `proposal` label:

```bash
/update-issue <issue_number> --remove-label "proposal"
```

Once the `proposal` label is removed, the `/dev` workflow will automatically implement the enhancement on its next iteration.

### How to Provide Feedback on a Proposal

1. **Comment on the issue** with your feedback, questions, or requested changes
2. Run `/refine-proposal <issue_number>` to have the AI incorporate your feedback
3. Review the updated proposal
4. Approve or provide additional feedback

### How to Reject a Proposal

```bash
/close-issue <issue_number> "Rejected: [reason for rejection]"
```

### Proposal Labels

| Label | Meaning |
|-------|---------|
| `proposal` | AI-generated, awaiting human approval |
| `enhancement` | Describes a feature improvement |
| `P0`-`P3` | Priority level (assigned during triage) |

**Note**: An issue can have both `proposal` and `enhancement` labels. The `proposal` label is what prevents automatic implementation.

---

🤖 **Ready to work on issue #$ISSUE_NUM! Start working on it now, then IMMEDIATELY continue to the next issue.**

**REMINDER**: The `working` label is released only on a **terminal outcome** —
the issue is closed, or you explicitly release it (blocked / skipped / abandoned)
with a release comment in the same step:

```bash
# Terminal outcome only. Never after a partial commit, a batch boundary, or a pause.
issue_update "$ISSUE_NUM" --remove-label "working" 2>/dev/null || true
```

Dropping it while the issue is still open and still yours re-exposes it to the
claimable pool and causes a peer to duplicate your work. Leaving it held while
you are genuinely still working is correct — `/monitor-workers` reclaims locks
that go stale.
