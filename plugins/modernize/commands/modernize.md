# Modernize Command

**Description**: Orchestrate a team of specialist agents to upgrade a project to be modern, secure, well-tested, and performant

---

# Project Modernization & Security Protocol

**Version**: 2.0
**Purpose**: Coordinate multiple specialist agents to systematically upgrade any software project
**Team**: Migration Coordinator, Security Agent, Architect Agent, Coder Agent, Tester Agent, Documentation Agent
**Inputs**: Optional `ASSESSMENT.md` and `PLAN.md` from `/modernize-assess` and `/modernize-plan`

---

## Prerequisites Check

**Before starting, this command checks for**:

```bash
# Check for assessment
if [ -f "ASSESSMENT.md" ]; then
    echo "✅ Found ASSESSMENT.md - will use assessment findings"
    USE_ASSESSMENT=true
else
    echo "⚠️  No ASSESSMENT.md - recommend running /modernize-assess first"
    echo "   Continue with basic assessment? (y/n)"
    USE_ASSESSMENT=false
fi

# Check for plan
if [ -f "PLAN.md" ]; then
    echo "✅ Found PLAN.md - will follow existing plan"
    USE_PLAN=true
else
    echo "⚠️  No PLAN.md - will create plan on-the-fly"
    echo "   Recommend running /modernize-plan first for better accuracy"
    USE_PLAN=false
fi

# Detect autocoder plugin for parallel issue resolution
AUTOCODER_AVAILABLE=false
if claude plugins list 2>/dev/null | grep -q "autocoder"; then
    AUTOCODER_AVAILABLE=true
    echo "✅ Autocoder plugin detected"
else
    echo "ℹ️  Autocoder plugin not installed — using direct fix-and-retest cycles"
    echo "   Tip: Install autocoder (/plugin install autocoder) to enable parallel"
    echo "   issue resolution via GitHub issues and worker agents"
fi

# Detect swarm environment (tmux/cmux/plain)
SWARM_ENV="none"
WORKER_COUNT=0
if [ "$AUTOCODER_AVAILABLE" = true ]; then
    if [ -n "$TMUX" ]; then
        SWARM_ENV="tmux"
        SESSION_NAME=$(tmux display-message -p '#{session_name}' 2>/dev/null)
        WORKER_COUNT=$(tmux list-panes -t "$SESSION_NAME:0" -F '#{pane_index}' 2>/dev/null | wc -l | tr -d ' ')
        echo "✅ tmux swarm detected (session: $SESSION_NAME, $WORKER_COUNT worker panes)"
        echo "   Test failures will be filed as GitHub issues and resolved by workers in parallel"
    elif cmux list-workspaces 2>/dev/null | grep -q "wt"; then
        SWARM_ENV="cmux"
        WORKER_COUNT=$(cmux list-workspaces 2>/dev/null | grep "wt" | wc -l | tr -d ' ')
        echo "✅ cmux swarm detected ($WORKER_COUNT worker workspaces)"
        echo "   Test failures will be filed as GitHub issues and resolved by workers in parallel"
    else
        echo "⚠️  Autocoder available but no swarm detected"
        echo "   Recommend: exit, run 'startt 3' (or 'startc 3'), then /modernize in the manager session"
        echo "   Continuing in single-agent mode — issues will be created, but you'll need workers to fix them"
    fi
fi

# Ensure gh is authenticated as the correct user for this repo
REPO_OWNER=$(gh repo view --json owner --jq '.owner.login' 2>/dev/null || echo "")
if [ -n "$REPO_OWNER" ]; then
    CURRENT_GH_USER=$(gh api user --jq '.login' 2>/dev/null || echo "")
    if [ -n "$CURRENT_GH_USER" ] && [ "$CURRENT_GH_USER" != "$REPO_OWNER" ]; then
        echo "🔄 Switching gh identity to match repo owner ($REPO_OWNER)..."
        gh auth switch --user "$REPO_OWNER" 2>/dev/null || echo "⚠️  Could not switch to $REPO_OWNER"
    fi
fi
```

**Recommendation Workflow**:

**With autocoder installed (recommended)**:
1. **Best**: Start swarm (`startt 3`), then in manager: `/assess` → `/plan` → `/modernize`
2. **Good**: Start swarm, then `/modernize` (creates assessment/plan inline)

**Without autocoder**:
1. **Best**: `/assess` → `/plan` → `/modernize`
2. **Good**: `/plan` → `/modernize`
3. **Acceptable**: `/modernize` (creates minimal assessment/plan inline)

---

## Autocoder Integration (when both plugins installed)

When the autocoder plugin is detected, modernize changes how it handles test failures during phases. Instead of direct fix-and-retest cycles, it creates GitHub issues and lets autocoder workers resolve them in parallel.

### How It Works

When a phase's quality gate fails due to test failures:

**Step 1: Analyze and group failures**

```bash
# Run tests and capture output
$TEST_COMMAND 2>&1 | tee /tmp/modernize-test-results.txt

# If tests fail, analyze and group by root cause
if [ $? -ne 0 ]; then
  echo "❌ Phase $CURRENT_PHASE quality gate failed — test failures detected"

  if [ "$AUTOCODER_AVAILABLE" = true ]; then
    echo "📋 Grouping failures by root cause for GitHub issue creation..."
    # Group failures by:
    # - Same module/directory (tests in same path)
    # - Same error pattern (similar error messages)
    # - Same triggering change (API replacement, dependency update)
  fi
fi
```

**Step 2: Create GitHub issues (one per root-cause group)**

```bash
# Ensure 'modernize' label exists
gh label create "modernize" --description "Created by /modernize for phase test failures" --color "0e8a16" 2>/dev/null || true

# For each root-cause group, create an issue
CREATED_ISSUES=""
for group in $FAILURE_GROUPS; do
  ISSUE_NUM=$(gh issue create \
    --title "[modernize] Phase $CURRENT_PHASE: $GROUP_DESCRIPTION" \
    --label "$PRIORITY_LABEL" \
    --label "modernize" \
    --body "## Modernize Phase $CURRENT_PHASE - $PHASE_NAME

**Root Cause**: $GROUP_DESCRIPTION

**Changed**: $WHAT_WAS_MODIFIED

**Failing Tests** ($FAILURE_COUNT):
$(for test in $GROUP_TESTS; do echo "- \`$test\` - $ERROR_SUMMARY"; done)

**Context**: This issue was created by \`/modernize\` during Phase $CURRENT_PHASE ($PHASE_NAME).
Fix the failing tests to unblock the modernization workflow.

**Phase Quality Gate**: $QUALITY_GATE_DESCRIPTION" \
    --json number --jq '.number')

  CREATED_ISSUES="$CREATED_ISSUES $ISSUE_NUM"
  echo "📝 Created issue #$ISSUE_NUM: $GROUP_DESCRIPTION ($PRIORITY_LABEL)"
done

# Log to HISTORY.md
./scripts/append-to-history.sh \
  "Phase $CURRENT_PHASE: Created $(echo $CREATED_ISSUES | wc -w) issues for test failures" \
  "Test failures during $PHASE_NAME grouped by root cause" \
  "Issues: $CREATED_ISSUES" \
  "Waiting for autocoder workers to resolve"
```

**Step 3: Wait for resolution (adaptive coordination)**

```bash
echo "⏳ Waiting for workers to resolve issues: $CREATED_ISSUES"

while true; do
  # Check GitHub — source of truth
  OPEN_COUNT=0
  for issue_num in $CREATED_ISSUES; do
    STATE=$(gh issue view "$issue_num" --json state --jq '.state')
    if [ "$STATE" = "OPEN" ]; then
      OPEN_COUNT=$((OPEN_COUNT + 1))

      # Check if any worker has claimed it
      HAS_WORKING=$(gh issue view "$issue_num" --json labels --jq '.labels[].name' | grep -c "working")
      if [ "$HAS_WORKING" = "0" ]; then
        # Issue unclaimed — try to dispatch a worker
        IDLE_DISPATCHED=false

        if [ "$SWARM_ENV" = "tmux" ]; then
          # Read worker screens to find idle agents
          for pane in $(tmux list-panes -t "$SESSION_NAME:0" -F '#{pane_index}' 2>/dev/null); do
            SCREEN=$(tmux capture-pane -t "$SESSION_NAME:0.$pane" -p 2>/dev/null | tail -15)
            if echo "$SCREEN" | grep -qiE "(no.*issues|waiting|idle|╰|❯|\\\$)"; then
              echo "🚀 Dispatching idle worker (pane $pane) to issue #$issue_num"
              tmux send-keys -t "$SESSION_NAME:0.$pane" "/autocoder:fix $issue_num" Enter
              IDLE_DISPATCHED=true
              break
            fi
          done
        elif [ "$SWARM_ENV" = "cmux" ]; then
          for ws in $(cmux list-workspaces 2>/dev/null | grep "wt"); do
            SCREEN=$(cmux read-screen --workspace "$ws" --lines 15 2>/dev/null)
            if echo "$SCREEN" | grep -qiE "(no.*issues|waiting|idle|╰|❯|\\\$)"; then
              echo "🚀 Dispatching idle worker ($ws) to issue #$issue_num"
              cmux send --workspace "$ws" "/autocoder:fix $issue_num"
              cmux send-key --workspace "$ws" Enter
              IDLE_DISPATCHED=true
              break
            fi
          done
        fi

        if [ "$IDLE_DISPATCHED" = false ]; then
          # Check how long the issue has been open without a worker
          CREATED_AT=$(gh issue view "$issue_num" --json createdAt --jq '.createdAt')
          MINUTES_AGO=$(( ($(date +%s) - $(date -d "$CREATED_AT" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$CREATED_AT" +%s 2>/dev/null)) / 60 ))
          if [ "$MINUTES_AGO" -gt 30 ]; then
            echo "⚠️  Issue #$issue_num has been open for ${MINUTES_AGO}m with no worker assigned"
            echo "   Please check on your worker agents or assign manually"
          fi
        fi
      fi
    fi
  done

  if [ "$OPEN_COUNT" -eq 0 ]; then
    echo "✅ All modernize issues resolved"
    break
  fi

  echo "⏳ $OPEN_COUNT issue(s) still open — checking again in 3 minutes..."
  sleep 180
done

# Re-run quality gate after all issues resolved
echo "🔄 Re-running phase quality gate..."
$TEST_COMMAND 2>&1 | tee /tmp/modernize-retest-results.txt
if [ $? -eq 0 ]; then
  echo "✅ Phase $CURRENT_PHASE quality gate passed"
else
  echo "❌ New test failures after fixes — creating additional issues..."
  # Repeat the issue creation cycle (the agent should loop back)
fi
```

### Without Autocoder (default behavior)

When autocoder is NOT installed, the standard fix-and-retest cycle is used:

1. Tester Agent documents failures and categorizes by priority
2. Coder Agent fixes issues directly
3. Tester Agent re-runs all tests
4. Repeat up to 3 iterations
5. If still failing after 3 iterations: BLOCK progression, escalate

No GitHub issues are created. No swarm coordination. All existing behavior is unchanged.

---

## Overview

This protocol orchestrates a **multi-agent team** to modernize and secure your project through a systematic, phased approach. The team works in coordination to ensure:
- ✅ Modern frameworks and dependencies
- ✅ Security vulnerabilities eliminated
- ✅ Comprehensive test coverage (≥95%)
- ✅ Performance optimization
- ✅ Complete documentation
- ✅ Production-ready quality

**Core Principle**: **Systematic, agent-coordinated modernization with quality gates at every stage.**

---

## Agent Team Roles

### 1. **Migration Coordinator** (Orchestrator)
- **Role**: Strategic oversight and coordination
- **Responsibilities**: Plan phases, coordinate agents, enforce quality gates, track progress
- **When active**: Throughout entire project

### 2. **Security Agent** (Blocker)
- **Role**: Vulnerability assessment and remediation
- **Responsibilities**: Scan CVEs, calculate security score, prioritize fixes
- **When active**: Phase 1 (blocks all progress until CRITICAL/HIGH resolved)

### 3. **Architect Agent** (Decision Maker)
- **Role**: Technology research and architectural decisions
- **Responsibilities**: Research alternatives, create ADRs, recommend patterns
- **When active**: Phases 1-2 (planning and design)

### 4. **Coder Agent** (Implementation)
- **Role**: Code migration and modernization
- **Responsibilities**: Update frameworks, replace obsolete APIs, fix builds
- **When active**: Phases 3-4 (can run multiple in parallel)

### 5. **Tester Agent** (Quality Gate)
- **Role**: Comprehensive testing and validation
- **Responsibilities**: Run all test phases, fix-and-retest cycles, enforce 100% pass rate
- **When active**: After every code change (blocks progression)

### 6. **Documentation Agent** (Knowledge Management)
- **Role**: Documentation creation and maintenance
- **Responsibilities**: HISTORY.md, ADRs, migration guides, changelogs
- **When active**: Continuous throughout, final comprehensive docs at end

---

## Modernization Phases

### Phase 0: Discovery & Assessment (1-2 days)

**Active Agents**: Migration Coordinator, Security Agent, Architect Agent

**Input Handling**:
```
IF ASSESSMENT.md EXISTS:
    ✅ Skip detailed assessment
    ✅ Use existing scores, risks, estimates
    ✅ Focus on validation and updates
    Duration: 0.5-1 day (validation only)
ELSE:
    ⚠️  Run full assessment (as described below)
    Duration: 1-2 days
```

**Activities**:

**⚠️ CRITICAL: Test Environment Setup MUST Be First Task**

1. **Test Environment Setup** (MANDATORY FIRST - NEW per Recommendation 1)
   - **Why First**: Cannot validate anything without working build/test environment
   - Install required SDKs (.NET, Node.js, Python, etc.)
   - Install Docker for integration testing
   - Configure environment variables
   - **Verify build succeeds**: `dotnet build` (establish baseline)
   - **Verify tests run**: `dotnet test` (establish pass rate baseline)
   - **Run vulnerability scan**: `dotnet list package --vulnerable --include-transitive`
   - Document baseline metrics: test count, pass rate, build warnings, CVE count
   - **Deliverable**: Working environment with verified baseline metrics
   - **Duration**: 1-2 hours (BLOCKING - nothing else can proceed without this)

2. **Security Baseline** (BLOCKING - Now uses verified scan from Task 1)
   - **Use vulnerability scan from Task 1** (already executed)
   - Calculate security score (0-100): `100 - (CRITICAL×10 + HIGH×5 + MEDIUM×2 + LOW×0.5)`
   - Categorize vulnerabilities (CRITICAL/HIGH/MEDIUM/LOW)
   - Document top 10 CVEs in ASSESSMENT.md
   - **BLOCK**: Must have scan results before proceeding (scores are verified, not estimated)

3. **Project Analysis**
   - **If ASSESSMENT.md exists**: ✅ Load existing inventory
   - **If no assessment**: Inventory all dependencies and frameworks
   - Identify current versions vs latest stable (using actual package resolution from Task 1 build)
   - Map project structure and architecture
   - Identify technology debt
   - **Deliverable**: Project assessment (or validate existing)

4. **Technology Assessment**
   - Research latest framework versions
   - Identify obsolete APIs and patterns
   - Document breaking changes
   - Create upgrade roadmap

5. **Test Baseline Analysis**
   - **Use test results from Task 1** (already executed)
   - Capture baseline metrics (pass rate, coverage, performance)
   - Document current test infrastructure
   - Identify test gaps

**Outputs**:
- Project assessment report (or use existing ASSESSMENT.md)
- Security vulnerability report
- Technology upgrade roadmap
- Test baseline report
- Initial HISTORY.md entry

**With Existing Assessment**:
- ✅ Validate assessment still accurate (dependencies haven't changed)
- ✅ Update if needed (typically minimal)
- ✅ Faster completion (0.5-1 day vs 1-2 days)

**Quality Gate** (UPDATED per Recommendation 1 & 3):
- ✅ Test environment ready (build succeeds, tests run)
- ✅ Baseline test metrics documented (pass rate, count, coverage)
- ✅ Vulnerability scan completed (verified CVE counts, not estimates)
- ✅ Security score calculated from scan results (≥45 required)
- ✅ All CRITICAL/HIGH vulnerabilities documented
- ✅ Docker/external dependencies ready for integration tests

---

### Phase 1: Security Remediation (2-5 days)

**Active Agents**: Security Agent (lead), Coder Agent, Tester Agent

**Activities**:
1. **Fix Critical Vulnerabilities** (P0)
   - Update packages with CRITICAL CVEs
   - Fix security misconfigurations
   - Remove deprecated/insecure code
   - Verify fixes with security scans

2. **Fix High-Priority Vulnerabilities** (P1)
   - Update packages with HIGH CVEs
   - Apply security patches
   - Implement security best practices

3. **Post-Update Security Validation** (BLOCKING - NEW per Recommendation 3)
   - **Re-run vulnerability scan**: `dotnet list package --vulnerable --include-transitive > security-after-phase1.txt`
   - **Compare before/after**: `diff security-baseline.txt security-after-phase1.txt`
   - **Verify CRITICAL/HIGH count decreased** (not just assumed)
   - **Verify no NEW vulnerabilities introduced** by updates
   - Recalculate security score from scan results (must show improvement)
   - **Run all tests** to ensure no regressions (Tier 1: Unit tests minimum)
   - Update HISTORY.md with verified security improvements

**Outputs**:
- Security fixes applied
- Updated security scan report
- Test results (must maintain 100% pass rate)
- HISTORY.md entry for security work

**Quality Gate** (UPDATED per Recommendation 3):
- ✅ Security scan re-run and results verified (not estimated)
- ✅ Security score ≥45 (calculated from verified scan results)
- ✅ Zero CRITICAL vulnerabilities (verified in scan diff)
- ✅ Zero HIGH vulnerabilities (verified in scan diff, or documented with explicit approval)
- ✅ No NEW vulnerabilities introduced by updates
- ✅ All tests passing (100% - Tier 1 Unit tests minimum)

---

### Phase 2: Architecture & Design (2-3 days)

**Active Agents**: Architect Agent (lead), Migration Coordinator

**Input Handling**:
```
IF PLAN.md EXISTS:
    ✅ Use existing architecture decisions
    ✅ Validate ADRs are current
    ✅ Follow defined strategy
    Duration: 0.5-1 day (validation only)
ELSE:
    ⚠️  Create architecture decisions (as described below)
    Duration: 2-3 days
```

**Activities**:

**⚠️ NEW: Spike-Driven ADR Process for High-Risk Decisions (per Recommendation 2)**

1. **Framework Upgrade Planning**
   - Research target framework versions
   - Evaluate migration paths
   - **For high-risk decisions**: Create spike branches (1-2 days)
     - Test Option A on single project
     - Test Option B on single project
     - Document actual compilation errors, API changes, test failures
   - Create evaluation matrix with empirical data from spikes
   - Document breaking changes
   - Create ADRs with status "proposed" first (allow 24-48hr review)
   - Mark ADRs as "accepted" after stakeholder review

2. **Dependency Strategy**
   - Identify dependency upgrade order
   - **For major version changes**: Create spike branches
     - Example: RabbitMQ.Client 5→6 vs 5→7
     - Run tests on each spike, document pass rates
     - Compare actual migration effort (file count, errors)
   - Map dependency conflicts (using spike results)
   - Plan parallel vs sequential updates
   - Create dependency upgrade matrix with verified estimates

3. **Architecture Decisions**
   - Obsolete pattern replacements
   - New feature approaches
   - Performance optimization strategies
   - Testing strategy updates
   - **All ADRs must include**:
     - Evaluation matrix with weighted criteria
     - Spike results (for high-risk decisions)
     - 24-48hr review period before "accepted" status

**Outputs**:
- ADRs for all major decisions (MADR 3.0.0 format) - or use existing from PLAN.md
- Dependency upgrade matrix
- Migration timeline
- Risk assessment
- HISTORY.md entry

**With Existing Plan**:
- ✅ ADRs already created and approved
- ✅ Migration strategy defined
- ✅ Just validate and proceed
- ✅ Faster completion (0.5-1 day vs 2-3 days)

**Quality Gate**: All major decisions documented in ADRs, migration plan approved

---

### Phase 3: Framework & Dependency Modernization (5-10 days)

**Active Agents**: Coder Agent (multiple if parallel), Tester Agent, Migration Coordinator

**Input Handling**:
```
IF PLAN.md EXISTS:
    ✅ Use defined module migration order
    ✅ Follow parallel execution strategy
    ✅ Use task breakdown from plan
    More accurate timeline
ELSE:
    ⚠️  Determine migration order on-the-fly
    More conservative timeline
```

**Activities**:
1. **Framework Upgrade**
   - Update to target framework version
   - Fix compilation errors
   - Update project files
   - Resolve API changes

2. **Dependency Updates**
   - Update dependencies in priority order
   - Resolve version conflicts
   - Update package references
   - Fix breaking changes

3. **Continuous Testing** (BLOCKING)
   - Run tests after each change
   - **If autocoder available**: Create GitHub issues for failures grouped by root cause, wait for workers to resolve (see [Autocoder Integration](#autocoder-integration-when-both-plugins-installed))
   - **If no autocoder**: Direct fix-and-retest cycles (Coder + Tester, max 3 iterations)
   - Maintain 100% pass rate
   - No progression until tests pass

**Parallel Execution Strategy**:

With autocoder swarm:
```
Migration Coordinator (manager session)
  ↓ creates GitHub issues for failures
  ├─ Autocoder Worker #1 (worktree 1) → picks up issue, fixes, PRs
  ├─ Autocoder Worker #2 (worktree 2) → picks up issue, fixes, PRs
  └─ Autocoder Worker #3 (worktree 3) → picks up issue, fixes, PRs
  ↓ polls GitHub until all issues closed
  ↓ re-runs quality gate
```

Without autocoder:
```
Migration Coordinator
  ↓
  ├─ Coder Agent #1 (Module A) → Tester Agent validates
  ├─ Coder Agent #2 (Module B) → Tester Agent validates
  └─ Coder Agent #3 (Module C) → Tester Agent validates
```

**Outputs**:
- Updated framework versions
- Updated dependencies
- Fixed compilation errors
- Test results (100% pass rate)
- HISTORY.md entries for each module

**Quality Gate**:
- All projects build successfully
- 100% test pass rate (MANDATORY)
- No P0/P1 issues
- Code coverage ≥80%

---

### Phase 4: API Modernization & Code Quality (3-7 days)

**Active Agents**: Coder Agent, Tester Agent, Architect Agent

**Activities**:
1. **Replace Obsolete APIs**
   - Identify deprecated API usage
   - Replace with modern equivalents
   - Update code patterns
   - Verify functionality

2. **Code Quality Improvements**
   - Apply modern language features
   - Remove code smells
   - Improve error handling
   - Optimize performance hotspots

3. **Test Enhancement**
   - Add missing test coverage
   - Update test patterns
   - Add integration tests
   - Performance benchmarks

**Outputs**:
- Modernized codebase
- Improved code quality metrics
- Enhanced test suite
- Performance benchmarks
- HISTORY.md entries

**Quality Gate**:
- Zero obsolete API warnings
- Code coverage ≥85%
- 100% test pass rate
- No performance regressions (≤10%)

---

### Phase 5: Performance Optimization (2-4 days)

**Active Agents**: Coder Agent, Tester Agent, Architect Agent

**Activities**:
1. **Performance Profiling**
   - Run performance benchmarks
   - Identify bottlenecks
   - Compare against baseline
   - Document performance goals

2. **Optimization Implementation**
   - Optimize critical paths
   - Implement caching strategies
   - Improve database queries
   - Reduce memory allocations

3. **Validation**
   - Re-run benchmarks
   - Verify improvements
   - Ensure no regressions
   - Document performance gains

**Outputs**:
- Performance optimization report
- Benchmark comparisons
- Performance ADRs (if architectural changes)
- HISTORY.md entry

**Quality Gate**:
- Performance improvement ≥10% OR documented as optimal
- No performance regressions
- All tests passing

---

### Phase 6: Comprehensive Documentation (2-3 days)

**Active Agents**: Documentation Agent (lead), Migration Coordinator

**Activities**:
1. **CHANGELOG Creation**
   - Document all breaking changes
   - List new features
   - Security fixes
   - Performance improvements
   - Migration notes

2. **Migration Guide**
   - Step-by-step upgrade instructions
   - Breaking change details
   - Code examples (before/after)
   - Troubleshooting guide
   - FAQ section

3. **Final Documentation**
   - Update README
   - API documentation
   - Architecture documentation
   - Deployment guides
   - Release notes

**Outputs**:
- CHANGELOG.md (Keep a Changelog format)
- MIGRATION-GUIDE.md (800+ lines, comprehensive)
- Updated README.md
- ADR summary
- Release notes
- Final HISTORY.md entry

**Quality Gate**: All documentation complete, reviewed, and accurate

---

### Phase 7: Final Validation & Release (1-2 days)

**Active Agents**: Tester Agent (lead), Security Agent, Migration Coordinator

**Activities**:
1. **Complete Test Suite**
   - Run all test phases
   - Unit tests (100% pass rate)
   - Integration tests (100% pass rate)
   - Component tests (100% pass rate)
   - Performance tests (baseline validation)
   - E2E tests (100% pass rate)

2. **Final Security Scan**
   - Run comprehensive CVE scan
   - Verify security score ≥45
   - Document any remaining LOW/MEDIUM issues
   - Get security approval

3. **Release Preparation**
   - Tag release version
   - Generate release notes
   - Create deployment checklist
   - Backup current production

**Outputs**:
- Final test report
- Final security report
- Release notes
- Deployment checklist
- Production readiness assessment

**Quality Gate** (GO/NO-GO Decision):
- ✅ Security score ≥45
- ✅ Zero CRITICAL/HIGH vulnerabilities
- ✅ 100% test pass rate (all test types)
- ✅ Code coverage ≥85%
- ✅ Zero P0/P1 issues
- ✅ All documentation complete
- ✅ Performance validated

---

## Using This Protocol

### Starting the Modernization

**Option 1: Full Team Orchestration**
```
User: /modernize-project
User: I have a .NET 6 project I need to upgrade to .NET 9, modernize dependencies, fix security issues, and improve test coverage.

Claude: I'll coordinate a team of specialist agents to modernize your project. Let me start with Phase 0: Discovery & Assessment...

[Migration Coordinator activates]
Phase 0: Discovery & Assessment
- Analyzing project structure...
- Running security scan...
- Creating upgrade roadmap...

[Security Agent activates]
Security Baseline:
- Current score: 23/100
- CRITICAL: 3 vulnerabilities
- HIGH: 12 vulnerabilities
⚠️ BLOCKING: Must fix CRITICAL/HIGH before proceeding

[Architect Agent activates]
Technology Assessment:
- Current: .NET 6.0
- Target: .NET 9.0
- Breaking changes identified: 47
- ADR needed for: [list of decisions]

...
```

**Option 2: Phase-by-Phase**
```
User: /modernize-project
User: Start with Phase 0 only - just assess my project

Claude: Running Phase 0: Discovery & Assessment...
[Detailed assessment output]
```

**Option 3: Specific Agent Focus**
```
User: /modernize-project
User: Focus on security remediation only (Phase 1)

Claude: [Security Agent + Coder Agent + Tester Agent activate]
```

### Monitoring Progress

The Migration Coordinator maintains a progress dashboard:

```markdown
## Modernization Progress

### Overall Status: Phase 3 - Framework Modernization (60% complete)

| Phase | Status | Duration | Quality Gate |
|-------|--------|----------|--------------|
| 0. Discovery | ✅ Complete | 1.5 days | ✅ Passed |
| 1. Security | ✅ Complete | 3 days | ✅ Score: 52/100 |
| 2. Architecture | ✅ Complete | 2 days | ✅ ADRs: 5 |
| 3. Framework | 🔄 In Progress | 4/7 days | ⏳ Pending |
| 4. API Modernization | ⏳ Pending | - | - |
| 5. Performance | ⏳ Pending | - | - |
| 6. Documentation | ⏳ Pending | - | - |
| 7. Final Validation | ⏳ Pending | - | - |

### Current Phase Details
- **Active Agents**: Coder #1, Coder #2, Tester
- **Module A**: ✅ Complete (.NET 9 migration done)
- **Module B**: 🔄 In Progress (fixing build errors)
- **Module C**: ⏳ Queued
- **Test Pass Rate**: 96.2% (6 failures, P2 severity)
```

---

## Quality Gates (Blocking Criteria)

### Security Gates (BLOCKING)
- ❌ **BLOCK**: Security score <45
- ❌ **BLOCK**: Any CRITICAL vulnerabilities unresolved
- ❌ **BLOCK**: Any HIGH vulnerabilities unresolved (unless explicitly approved)

### Testing Gates (BLOCKING)
- ❌ **BLOCK**: Test pass rate <100% (production releases)
- ❌ **BLOCK**: Code coverage <80%
- ❌ **BLOCK**: Any P0 or P1 test failures
- ❌ **BLOCK**: Performance regression >10%

### Build Gates (BLOCKING)
- ❌ **BLOCK**: Any compilation errors
- ❌ **BLOCK**: Any dependency conflicts
- ❌ **BLOCK**: Build warnings in critical code paths

### Documentation Gates (BLOCKING)
- ❌ **BLOCK**: Missing CHANGELOG
- ❌ **BLOCK**: Missing migration guide
- ❌ **BLOCK**: Undocumented breaking changes

---

## Agent Coordination Patterns

### Sequential Pipeline (Default)
```
Migration Coordinator
  ↓
Security Agent (Phase 1) → GATE → Must pass before Phase 2
  ↓
Architect Agent (Phase 2) → GATE → ADRs must be complete
  ↓
Coder Agent (Phase 3) → Tester Agent → GATE → 100% pass rate
  ↓
Coder Agent (Phase 4) → Tester Agent → GATE → 100% pass rate
  ↓
Documentation Agent (Phase 6)
  ↓
Tester + Security (Phase 7) → FINAL GATE → GO/NO-GO
```

### Parallel Execution (Faster)
```
Migration Coordinator
  ↓
Security Agent (Phase 1) → GATE
  ↓
Architect Agent (Phase 2) → GATE
  ↓
  ├─ Coder #1 (Module A) → Tester → ✅
  ├─ Coder #2 (Module B) → Tester → ✅
  └─ Coder #3 (Module C) → Tester → ✅
  ↓
Documentation Agent → Final Validation
```

### Fix-and-Retest Cycle
```
Coder Agent makes changes
  ↓
Tester Agent runs tests
  ↓ (failures found)
Tester Agent documents failures (P0/P1/P2/P3)
  ↓
Coder Agent fixes issues
  ↓
Tester Agent re-runs tests
  ↓
[Repeat until 100% pass rate achieved]
```

---

## Logging Protocol

**MANDATORY**: All agents must log to HISTORY.md using `./scripts/append-to-history.sh`

**When to Log**:
- After completing each phase
- After fixing security vulnerabilities
- After making architectural decisions
- After completing migrations
- After test validation
- After documentation updates

**Example Entry**:
```markdown
## 2025-10-25 14:30 - Phase 1: Security Remediation Complete

**Agent**: Security Agent + Coder Agent
**Phase**: 1 - Security Remediation

### What Changed
- Fixed 3 CRITICAL vulnerabilities (CVE-2024-1234, CVE-2024-5678, CVE-2024-9012)
- Fixed 12 HIGH vulnerabilities
- Updated 15 dependencies to latest secure versions
- Improved security score from 23/100 → 52/100

### Why Changed
- CRITICAL vulnerabilities blocked progression (Phase 0 quality gate)
- Required to achieve minimum security score ≥45
- Multiple packages had known exploits in production

### Impact
- Security score: 23/100 → 52/100 (+29 points)
- CRITICAL vulnerabilities: 3 → 0 (✅ resolved)
- HIGH vulnerabilities: 12 → 0 (✅ resolved)
- MEDIUM vulnerabilities: 8 → 5 (-3)
- Dependencies updated: 15 packages
- Test pass rate: 100% (no regressions introduced)

### Outcome
✅ **Quality Gate PASSED** - Ready for Phase 2: Architecture & Design
- Security score ≥45: ✅ (52/100)
- Zero CRITICAL: ✅
- Zero HIGH: ✅
- Tests passing: ✅ (100%)

**Next Phase**: Phase 2 - Architecture & Design (2-3 days estimated)
```

---

## Success Criteria

### Project Modernization Complete When:

✅ **Security**
- Security score ≥45
- Zero CRITICAL vulnerabilities
- Zero HIGH vulnerabilities
- All dependencies up-to-date

✅ **Quality**
- 100% test pass rate (all test types)
- Code coverage ≥85%
- Zero P0/P1 issues
- Performance validated (no regressions >10%)

✅ **Modernization**
- Latest stable framework version
- All dependencies current
- Zero obsolete API warnings
- Modern code patterns applied

✅ **Documentation**
- Complete CHANGELOG
- Comprehensive migration guide
- All ADRs documented
- Updated README and docs
- HISTORY.md fully populated

---

## Estimated Timeline

**Note**: Time estimates are based on typical human execution times and may vary significantly based on project complexity, team experience, and AI assistance capabilities.

| Phase | Duration | Can Parallelize |
|-------|----------|-----------------|
| 0. Discovery & Assessment | 1-2 days | No |
| 1. Security Remediation | 2-5 days | Partial (by vulnerability) |
| 2. Architecture & Design | 2-3 days | No |
| 3. Framework Modernization | 5-10 days | Yes (by module) |
| 4. API Modernization | 3-7 days | Yes (by area) |
| 5. Performance Optimization | 2-4 days | Partial |
| 6. Documentation | 2-3 days | Partial (by doc type) |
| 7. Final Validation | 1-2 days | No |

**Total**: 18-36 days (depends on project size and parallelization)

**Small Project** (<10k LOC): ~18-22 days
**Medium Project** (10k-50k LOC): ~25-30 days
**Large Project** (>50k LOC): ~30-36 days

---

## Example Usage Scenarios

### Scenario 1: .NET Framework to .NET 9
```
User: /modernize-project
User: Upgrade my .NET Framework 4.8 project to .NET 9, fix all security issues, and ensure 95%+ test coverage

Claude: I'll coordinate the modernization team:

Phase 0: Discovery & Assessment
- Current: .NET Framework 4.8
- Target: .NET 9.0
- Security Score: 18/100 ⚠️
- Test Coverage: 42% ⚠️

[Detailed execution across all 7 phases]
```

### Scenario 2: Node.js Upgrade + Security
```
User: /modernize-project
User: My Node.js 14 app needs to go to Node.js 22, fix CVEs, and add proper testing

Claude: Modernization Plan:
- Phase 0: Assess Node.js 14 → 22 migration path
- Phase 1: Fix 47 vulnerabilities (Security Agent priority)
- Phase 2: Plan ESM migration, update patterns (Architect)
- Phase 3-4: Upgrade dependencies, modernize code (Coder)
- Phase 5: Performance validation
- Phase 6-7: Documentation and final validation
```

### Scenario 3: Python 2 to Python 3
```
User: /modernize-project
User: Legacy Python 2.7 codebase → Python 3.12, modernize dependencies, add type hints

Claude: This is a major migration requiring all agents:
[Systematic execution with extra focus on syntax changes, dependency compatibility]
```

---

## Troubleshooting

### Quality Gate Failures

**Security Gate Failed**
```
❌ Security score: 38/100 (required ≥45)
→ Action: Security Agent + Coder Agent continue Phase 1
→ Cannot proceed to Phase 2 until resolved
```

**Testing Gate Failed**
```
❌ Test pass rate: 87% (required 100%)

With autocoder:
→ Group failures by root cause
→ Create GitHub issues (P0/P1 + modernize label)
→ Workers pick up and fix issues in parallel
→ Poll until all issues closed, re-run quality gate

Without autocoder:
→ Tester Agent documents failures
→ Coder Agent fixes issues
→ Re-run fix-and-retest cycle (max 3 iterations)
```

**Performance Gate Failed**
```
❌ Performance regression: -23% (threshold -10%)
→ Action: Roll back change
→ Architect Agent reviews approach
→ Coder Agent implements optimized solution
```

---

## Best Practices

1. **Always start with Phase 0** - Never skip discovery
2. **Don't skip quality gates** - They prevent production issues
3. **Fix security first** - Security blocks everything else
4. **Test continuously** - Don't batch testing until the end
5. **Document as you go** - Incremental documentation saves time
6. **Use parallel execution** - When dependencies allow it
7. **Log everything to HISTORY.md** - Complete audit trail
8. **Create ADRs for major decisions** - Future maintainers will thank you

---

## Anti-Patterns to Avoid

❌ **Skipping security phase** - "We'll fix it later"
❌ **Accepting <100% test pass rates** - "Good enough for now"
❌ **Batching all changes** - "One big PR at the end"
❌ **Skipping documentation** - "We'll document after release"
❌ **Ignoring quality gates** - "We're on a deadline"
❌ **Solo agent execution** - "Just the Coder Agent is fine"
❌ **No progress tracking** - "Trust the process"

---

**Document Owner**: Migration Coordinator
**Protocol Version**: 1.0
**Last Updated**: 2025-10-25
**Applicability**: Universal - All software projects requiring modernization

**Remember**: **Systematic agent coordination = Production-ready modernization** ✅
