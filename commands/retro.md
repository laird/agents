# Retro Command

**Description**: Review project history and coordinate agents to identify 3-5 specific process improvements, outputting recommendations as an ADR in IMPROVEMENTS.md

---

# Retrospective Process Improvement Protocol

**Version**: 1.0
**Purpose**: Coordinate agents to review project history and identify process improvements
**Team**: All specialist agents (Migration Coordinator, Security, Architect, Coder, Tester, Documentation)
**Output**: `IMPROVEMENTS.md` (ADR format with 3-5 specific recommendations)
**Duration**: 2-4 hours

**Note**: Time estimates are based on typical human execution times and may vary significantly based on project complexity, team experience, and AI assistance capabilities.

---

## Overview

This protocol orchestrates a **multi-agent retrospective** to analyze project history, identify inefficiencies, bottlenecks, risks, and **agent behavioral issues**, then produce a unified set of **3-5 specific, actionable recommendations** for process improvement.

**Improvements Target**:
- **Agent Behavior**: Wrong tool usage, wasted effort, requirement misunderstandings, user interruptions
- **Protocol Updates**: Process changes, new phases, quality gates, workflow reordering
- **Automation**: Scripts, hooks, CI/CD pipelines to enforce best practices
- **Commands**: Updates to command files to guide better agent behavior

**Core Principle**: **Continuous improvement through systematic reflection, learning from mistakes, and evidence-based recommendations.**

**CRITICAL**: User interruptions and corrections are the strongest signal that agents need behavioral improvement. Every user correction should be analyzed and potentially trigger a recommendation.

---

## Retrospective Process

### Phase 1: Historical Analysis (60 minutes)

**Objective**: Gather data from project history to understand what happened

#### 1.1 Review Project History

**Migration Coordinator (Lead)**:
```bash
# Analyze HISTORY.md for patterns
- Read complete HISTORY.md
- Identify all phases completed
- Extract timeline data (estimated vs actual)
- Note any blockers or delays
- Document quality gate failures
```

**Data to Extract**:
- [ ] Phases completed and their durations
- [ ] Quality gate failures and resolution times
- [ ] Recurring issues or patterns
- [ ] Dependencies that caused problems
- [ ] Testing cycles and fix-and-retest iterations
- [ ] Security remediation efforts
- [ ] Documentation gaps discovered late

#### 1.2 Review ADRs (Architectural Decision Records)

**Architect Agent**:
```bash
# Find and analyze all ADRs
find . -name "ADR-*.md" -o -name "adr-*.md" -o -path "*/docs/adr/*"
```

**Analysis**:
- [ ] Which decisions had good outcomes?
- [ ] Which decisions caused rework?
- [ ] Were decisions made too late?
- [ ] Were alternatives properly evaluated?
- [ ] Was rationale documented sufficiently?

#### 1.3 Review Test History

**Tester Agent**:
```bash
# Analyze test patterns
- Review test pass rates over time
- Identify flaky tests
- Check coverage evolution
- Note test infrastructure issues
```

**Patterns to Identify**:
- [ ] Tests that failed repeatedly
- [ ] Areas with inadequate coverage discovered late
- [ ] Test infrastructure bottlenecks
- [ ] Performance test issues
- [ ] Integration vs unit test balance

#### 1.4 Review Security History

**Security Agent**:
```bash
# Analyze security remediation
- Review vulnerability scan results over time
- Check security score progression
- Identify CVEs that took longest to fix
- Note dependency security issues
```

**Analysis**:
- [ ] Were security issues caught early enough?
- [ ] Which vulnerabilities were hardest to fix?
- [ ] Did dependency updates introduce new issues?
- [ ] Was security scanning frequent enough?

#### 1.5 Review Code Changes

**Coder Agent**:
```bash
# Analyze git history
git log --all --oneline --graph
git log --all --numstat --pretty="%H" | awk 'NF==3 {plus+=$1; minus+=$2} END {printf("+%d, -%d\n", plus, minus)}'
git shortlog -sn
```

**Patterns to Identify**:
- [ ] Large commits that could have been broken down
- [ ] Rework or reverts
- [ ] Areas of code with high churn
- [ ] Coordination issues between modules
- [ ] Breaking changes that caused cascading fixes

#### 1.6 Review Documentation

**Documentation Agent**:
```bash
# Analyze documentation completeness
- Check CHANGELOG.md
- Review MIGRATION-GUIDE.md
- Analyze ADRs
- Check README updates
```

**Analysis**:
- [ ] Was documentation created incrementally or in batches?
- [ ] Were breaking changes documented immediately?
- [ ] Did documentation lag behind implementation?
- [ ] Were examples and troubleshooting guides adequate?

#### 1.7 Review User Interactions & Agent Errors (CRITICAL)

**All Agents**:
```bash
# Analyze conversation history for agent issues
- Review git commit messages for user corrections
- Check HISTORY.md for user interventions
- Identify cases where user had to interrupt
- Find instances of wasted effort or wrong approaches
- Note misunderstandings of requirements
```

**CRITICAL Signals of Agent Problems**:
- [ ] **User interruptions**: User had to stop agent mid-task
- [ ] **Corrections**: User corrected agent's approach or understanding
- [ ] **Repeated questions**: Agent asked same question multiple times
- [ ] **Wrong tools**: Agent used wrong tool for task (e.g., Bash instead of Read)
- [ ] **Wasted effort**: Agent implemented something user didn't ask for
- [ ] **Misunderstood requirements**: Agent built wrong thing
- [ ] **Ignored context**: Agent didn't read existing files before acting
- [ ] **Over-engineering**: Agent added unnecessary complexity
- [ ] **Under-engineering**: Agent missed critical requirements
- [ ] **Poor coordination**: Agents duplicated work or conflicted

**Examples of Agent Mistakes to Identify**:

1. **Wrong Tool Usage**:
   - Agent used `find` command instead of Glob tool
   - Agent used `grep` instead of Grep tool
   - Agent used Bash `cat` instead of Read tool
   - Agent created file without reading existing version first

2. **Wasted Effort**:
   - Agent implemented feature before confirming requirements
   - Agent wrote tests that user didn't request
   - Agent refactored code user didn't ask to change
   - Agent created documentation before checking if it exists

3. **Context Ignorance**:
   - Agent didn't read relevant files before making changes
   - Agent asked questions already answered in codebase
   - Agent missed existing patterns/conventions
   - Agent duplicated existing functionality

4. **Requirement Misunderstanding**:
   - Agent built feature differently than user described
   - Agent missed critical constraints or requirements
   - Agent made assumptions without confirming
   - Agent ignored explicit user guidance

5. **Poor Planning**:
   - Agent started coding without creating plan
   - Agent didn't use TodoWrite for multi-step tasks
   - Agent didn't break down complex tasks
   - Agent jumped between tasks without finishing

6. **Communication Issues**:
   - Agent didn't explain what it was doing
   - Agent didn't report blockers early
   - Agent didn't ask for clarification when unclear
   - Agent made decisions without user approval

**Data Sources for Agent Error Analysis**:
```bash
# Git commit messages with corrections
git log --all --grep="fix\|correct\|actually\|oops\|mistake"

# Search HISTORY.md for user interventions
grep -i "user:\|correction\|fix\|reverted\|undo" HISTORY.md

# Look for reverted commits
git log --all --oneline | grep -i "revert\|undo"

# Find large time gaps (might indicate stuck agent)
git log --all --format="%ai %s" | awk '{print $1, $2}' | sort
```

**IMPORTANT**: User interventions are the strongest signal that agents need behavioral improvement. Every user correction should trigger a recommendation.

---

### Phase 2: Agent Insights Gathering (30 minutes)

**Objective**: Each agent identifies problems and opportunities from their perspective

**Format**: Each agent creates a structured list of observations

#### Template for Each Agent:

```markdown
## [Agent Name] Observations

### What Went Well
1. [Positive observation with evidence]
2. [Positive observation with evidence]

### What Could Be Improved
1. [Problem/inefficiency with specific examples]
2. [Problem/inefficiency with specific examples]
3. [Problem/inefficiency with specific examples]

### Specific Recommendations
1. [Actionable recommendation]
2. [Actionable recommendation]
```

**All Agents Contribute**:
- Migration Coordinator: Process orchestration, coordination, quality gates
- Security Agent: Security scanning, vulnerability remediation
- Architect Agent: Decision-making process, ADR usage
- Coder Agent: Implementation approach, code quality, module coordination
- Tester Agent: Testing strategy, coverage, fix-and-retest cycles
- Documentation Agent: Documentation timing, completeness, format

---

### Phase 3: Pattern Identification (30 minutes)

**Objective**: Migration Coordinator synthesizes all agent observations to identify common themes

**Process**:
1. **Aggregate all agent observations**
2. **Identify recurring themes** across multiple agents
3. **Categorize issues**:
   - **Agent behavioral issues** (wrong tools, wasted effort, misunderstandings)
   - **Protocol improvements** (process changes, new steps, reordering)
   - **Automation opportunities** (scripts, hooks, CI/CD)
   - **Communication gaps** (coordination, handoffs, user interaction)
   - **Quality gate improvements** (enforcement, criteria, timing)
   - **Documentation improvements** (timing, format, completeness)
   - **Tool usage** (using appropriate tools, avoiding anti-patterns)
4. **Prioritize by impact**:
   - High impact: Significant time/quality improvement
   - Medium impact: Moderate improvement
   - Low impact: Minor optimization

**Common Pattern Examples**:

**Protocol Issues**:
- "Testing started too late in multiple phases" (Tester + Coder)
- "Dependencies analyzed insufficiently upfront" (Architect + Security + Coder)
- "Documentation created in large batches instead of incrementally" (Documentation + all agents)
- "Quality gates not enforced consistently" (Coordinator + Tester)
- "Security scanning not integrated into dev workflow" (Security + Coder)

**Agent Behavioral Issues** (CRITICAL):
- "Coder Agent used Bash cat instead of Read tool 15 times" (All agents)
- "Agent implemented feature without confirming requirements, user corrected 3 times" (User + Coder)
- "Agent didn't read existing config before modifying, caused conflicts" (User + Coder)
- "Agent asked user for information already in README.md" (User + all agents)
- "Agent started coding without creating TodoWrite plan for complex task" (Coordinator)
- "Agent made assumption about architecture without consulting Architect Agent" (Coordinator)
- "User had to interrupt agent 4 times to correct approach" (User + all agents)

---

### Phase 4: Recommendation Development (45 minutes)

**Objective**: Collaboratively develop 3-5 specific, actionable recommendations

#### Recommendation Criteria:

**Each recommendation MUST be**:
- ✅ **Specific**: Clear, concrete change to process or protocol
- ✅ **Actionable**: Can be implemented immediately
- ✅ **Measurable**: Success can be objectively verified
- ✅ **Evidence-based**: Supported by data from project history
- ✅ **High-impact**: Addresses significant inefficiency or risk

#### Recommendation Template:

```markdown
### Recommendation [N]: [Title]

**Problem**: [What inefficiency or risk does this address?]

**Evidence**: [Specific examples from project history]

**Proposed Change**: [Exact change - can be protocol update, agent behavior, or automation]

**Change Type**: [Protocol Update / Agent Behavior / Automation / Tool Usage / Documentation]

**Expected Impact**: [Quantifiable improvement in time, quality, or risk]

**Implementation Complexity**: [Low/Medium/High]

**Affected Components**:
- **Agents**: [List of agents that will change behavior]
- **Protocols**: [List of protocol files to update]
- **Automation**: [Scripts, hooks, CI/CD to add]
- **Commands**: [Command files to modify]
```

#### Selection Process:

1. **Brainstorm**: All agents propose recommendations (aim for 10-15)
2. **Score each** on:
   - Impact: 1-10
   - Effort: 1-10 (lower is better)
   - Evidence strength: 1-10
   - Impact/Effort ratio (higher is better)
3. **Select top 3-5** with highest Impact/Effort ratio and strong evidence
4. **Refine** selected recommendations for clarity and specificity

---

### Phase 5: ADR Generation (30 minutes)

**Objective**: Document recommendations as an Architectural Decision Record

**Format**: MADR 3.0.0 (Markdown Architectural Decision Records)

#### IMPROVEMENTS.md Structure:

```markdown
# Process Improvement Recommendations

**Date**: [YYYY-MM-DD]
**Status**: Proposed
**Decision Makers**: All Agent Team
**Project**: [Project Name]
**Retrospective Period**: [Start Date] - [End Date]

---

## Context and Problem Statement

Following completion of [phases/milestones], the agent team conducted a retrospective analysis of project history to identify opportunities for process improvement. This document presents evidence-based recommendations to improve efficiency, quality, and robustness of the modernization process.

**Analysis Sources**:
- HISTORY.md (project timeline and events)
- Git commit history ([N] commits analyzed)
- ADRs ([N] decisions reviewed)
- Test results and quality metrics
- Security scan results
- Documentation artifacts

**Key Metrics from This Project**:
- Timeline: [Estimated X days, Actual Y days, Delta Z%]
- Quality Gate Failures: [N instances]
- Fix-and-Retest Cycles: [N cycles]
- Security Remediation: [N CVEs, X days to resolve]
- Test Coverage: [Start X% → End Y%]
- [Other relevant metrics]

---

## Decision Drivers

* **Efficiency**: Reduce time to complete modernization phases
* **Quality**: Improve first-time quality, reduce rework
* **Risk Reduction**: Catch issues earlier in the process
* **Coordination**: Improve agent collaboration and handoffs
* **Automation**: Reduce manual effort and human error

---

## Recommendations

### Recommendation 1: [Title]

**Status**: Proposed

#### Problem

[Detailed description of the inefficiency, bottleneck, or risk]

#### Evidence

[Specific examples from project history with data]

**Examples from this project**:
- [Example 1 with timestamp/reference]
- [Example 2 with timestamp/reference]
- [Example 3 with timestamp/reference]

**Quantified Impact**:
- [Metric 1]: [Value]
- [Metric 2]: [Value]

#### Proposed Change

[Exact change to protocols, process, or agent behavior]

**Protocol Changes**:
- **File**: [protocol file or section]
- **Current**: [What happens now]
- **Proposed**: [What should happen]

**Agent Behavior Changes**:
- **[Agent 1]**: [Specific behavior change]
- **[Agent 2]**: [Specific behavior change]

#### Expected Impact

**Efficiency Gains**:
- Estimated time savings: [X hours/days per phase]
- Reduced rework: [Y% reduction]

**Quality Improvements**:
- [Specific quality metric improvement]

**Risk Reduction**:
- [Specific risk mitigation]

#### Implementation

**Effort**: [Low/Medium/High] - [X hours estimated]

**Steps**:
1. [Step 1]
2. [Step 2]
3. [Step 3]

**Validation**:
- [ ] [How to verify the change was effective]
- [ ] [Metric to track improvement]

#### Affected Components

- **Agents**: [List of affected agents]
- **Protocols**: [List of protocol documents]
- **Tools**: [Any new tools or automation needed]

---

[Repeat for Recommendations 2-5]

---

## Summary

| Recommendation | Impact | Effort | Priority | Estimated Savings |
|----------------|--------|--------|----------|-------------------|
| 1. [Title] | High | Medium | P0 | [X days/phase] |
| 2. [Title] | High | Low | P0 | [Y days/phase] |
| 3. [Title] | Medium | Low | P1 | [Z days/phase] |
| 4. [Title] | Medium | Medium | P1 | [W days/phase] |
| 5. [Title] | Low | Low | P2 | [V days/phase] |

**Total Estimated Impact**: [Combined efficiency gains, quality improvements, risk reduction]

---

## Implementation Plan

### Phase 1: Immediate Changes (Apply First)
- Recommendation [N]: [Title] - Can be applied immediately
- Recommendation [M]: [Title] - Can be applied immediately

### Phase 2: Short-term Changes (Next Project)
- Recommendation [X]: [Title] - Apply at start of next modernization
- Recommendation [Y]: [Title] - Apply at start of next modernization

### Phase 3: Long-term Changes (Strategic)
- Recommendation [Z]: [Title] - Requires tooling/infrastructure

---

## Next Steps

1. Review and approve recommendations (Team consensus)
2. Use `/retro-apply` to implement approved changes
3. Track effectiveness in next modernization project
4. Update this document with lessons learned

---

## References

- HISTORY.md: Complete project timeline
- Git log: [Commit range analyzed]
- ADRs: [List of ADRs reviewed]
- Test reports: [Test result references]
- Security scans: [Scan result references]

---

**Document Status**: Proposed
**Approval Required**: Team consensus
**Apply Using**: `/retro-apply`
**Next Review**: After next modernization project
```

---

## Example Recommendations

### Example 1: Front-load Dependency Analysis

**Problem**: Dependency conflicts discovered mid-migration caused 2 week delay

**Evidence**:
- Phase 3 blocked for 14 days while resolving EntityFramework 6→8 conflicts
- 3 dependency reverts required
- Security vulnerabilities re-introduced during rollbacks

**Proposed Change**: Add comprehensive dependency analysis to Phase 0
- Migration Coordinator creates dependency migration matrix BEFORE Phase 1
- Architect Agent researches all breaking changes across dependency tree
- Test compatibility in isolated branch before main migration

**Expected Impact**:
- Save 1-2 weeks per project
- Reduce mid-migration blockers by 80%
- Eliminate dependency-related regressions

---

### Example 2: Continuous Documentation

**Problem**: Documentation created in Phase 6 caused 4 days of archaeology to recreate decisions

**Evidence**:
- Migration guide required re-analyzing 200+ commits to understand changes
- 12 ADRs written retroactively with incomplete context
- Breaking changes discovered that weren't documented during implementation

**Proposed Change**: All agents document continuously
- Coder Agent: Update CHANGELOG.md with every breaking change immediately
- Architect Agent: Write ADRs BEFORE implementation, not after
- Documentation Agent: Review and integrate docs daily, not at end

**Expected Impact**:
- Reduce Phase 6 time by 50% (4 days → 2 days)
- Improve documentation quality (real-time context vs reconstruction)
- Eliminate archaeological work

---

### Example 3: Automated Security Scanning in Pipeline

**Problem**: Security issues discovered in Phase 1 security scan should have been caught earlier

**Evidence**:
- 47 vulnerabilities found in Phase 1
- Most were in dependencies added 6 months prior
- Could have been caught with automated scanning

**Proposed Change**: Security Agent integrates automated scanning
- Add pre-commit hook for dependency vulnerability scanning
- Security Agent runs scan weekly, not just Phase 0
- Coder Agent blocks any dependency with CRITICAL/HIGH CVEs

**Expected Impact**:
- Catch vulnerabilities immediately (not months later)
- Reduce Phase 1 security work by 60%
- Prevent vulnerable dependencies from entering codebase

---

### Example 4: Always Read Before Write (Agent Behavior)

**Problem**: Coder Agent frequently modified files without reading them first, causing conflicts and requiring user corrections

**Evidence**:
- 8 instances where agent used Write tool without prior Read
- User had to interrupt 5 times to say "read the existing file first"
- 3 commits reverted due to overwriting existing content
- Git log shows pattern: "fix\|correct\|actually read"

**Proposed Change**: Enforce "Read before Write" rule for all agents
- Update all command protocols with explicit "MUST read file first" requirement
- Coder Agent: Always use Read tool before Write or Edit
- Documentation Agent: Check for existing docs before creating new ones
- Add validation reminder in tool descriptions

**Change Type**: Agent Behavior

**Expected Impact**:
- Eliminate file conflicts and overwrites (100% reduction)
- Reduce user interruptions by 60%
- Save 2-3 hours per project in rework
- Improve agent context awareness

**Affected Components**:
- **Agents**: Coder, Documentation (primary), all agents (secondary)
- **Protocols**: All commands/*.md - add "Read first" requirement
- **Commands**: Update tool usage guidelines in each command

---

### Example 5: Use Appropriate Tools (Agent Behavior)

**Problem**: Agents frequently used Bash commands instead of specialized tools, violating tool usage policy

**Evidence**:
- Coder Agent used `cat` instead of Read: 23 instances
- Multiple agents used `find` instead of Glob: 15 instances
- Agent used `grep` instead of Grep tool: 12 instances
- User corrected tool usage 18 times total
- Pattern in git log: "use Read not cat", "use Glob not find"

**Proposed Change**: Strict tool usage enforcement
- Update all protocols with tool selection decision tree
- Add pre-flight checklist: "Am I using the right tool?"
- Migration Coordinator validates tool usage in agent plans
- Add examples of correct tool usage to each command

**Change Type**: Agent Behavior + Protocol Update

**Expected Impact**:
- 95% reduction in wrong tool usage
- Better context handling (Read provides line numbers, Bash cat doesn't)
- Eliminate user corrections for tool selection
- Improve agent efficiency (specialized tools are faster)

**Affected Components**:
- **Agents**: All agents
- **Protocols**: Add tool selection guide to commands/modernize.md
- **Commands**: Update all commands/*.md with tool usage examples

---

### Example 6: Confirm Before Implementing (Agent Behavior)

**Problem**: Coder Agent implemented features based on assumptions without confirming requirements with user

**Evidence**:
- 4 instances where agent built wrong thing, user had to correct
- Agent added authentication system user didn't request
- Agent refactored code structure without being asked
- User: "I didn't ask for that, just wanted simple fix"
- Wasted 6 hours on unwanted implementations

**Proposed Change**: Require explicit confirmation for significant changes
- Coder Agent: Present plan and get user approval before implementing
- Use TodoWrite to show planned tasks, wait for approval
- Ask clarifying questions when requirements unclear
- Architect Agent: Confirm architectural decisions before implementation
- Add "confirm with user" checkpoint to protocols

**Change Type**: Agent Behavior + Protocol Update

**Expected Impact**:
- Eliminate wasted effort on wrong implementations (100%)
- Save 4-8 hours per project in rework
- Improve user satisfaction
- Reduce user interruptions and corrections

**Affected Components**:
- **Agents**: Coder (primary), Architect, all agents (secondary)
- **Protocols**: Add confirmation checkpoints to commands/modernize.md phases
- **Commands**: Update all commands with "confirm before implement" guidance

---

## Success Criteria

**The retrospective is successful when**:

✅ **Comprehensive Analysis**:
- All HISTORY.md entries reviewed
- All agents contributed observations
- Git history analyzed quantitatively (including user corrections)
- User interruptions and agent errors identified
- Patterns identified across multiple data sources
- Agent behavioral issues surfaced and documented

✅ **Evidence-Based Recommendations**:
- Each recommendation supported by specific examples
- Quantified impact estimates
- Clear implementation steps
- Measurable success criteria

✅ **Actionable Output**:
- 3-5 specific recommendations (not vague suggestions)
- IMPROVEMENTS.md in proper ADR format
- Ready for `/retro-apply` implementation
- Team consensus on recommendations

✅ **High Impact**:
- Recommendations address real inefficiencies (not minor optimizations)
- Combined estimated savings ≥10% of project timeline
- Risk reduction quantified
- Quality improvements measurable

---

## Anti-Patterns to Avoid

❌ **Blame Culture**: Focus on process, not individuals
❌ **Vague Recommendations**: "Communicate better" → Specify HOW
❌ **Unmeasurable Improvements**: "Be more efficient" → Quantify
❌ **Analysis Paralysis**: 3-5 recommendations, not 50
❌ **No Evidence**: Opinions without data are not recommendations
❌ **Unrealistic Changes**: Must be implementable with available resources
❌ **Ignoring Small Wins**: Not all improvements need to be massive

---

## Usage

### Starting a Retrospective

```
User: /retro
User: Our modernization project just completed. Review the history and recommend improvements.

Claude: I'll coordinate the agent team to conduct a comprehensive retrospective...

[Migration Coordinator] Analyzing HISTORY.md...
- Project: .NET 6 → .NET 9 migration
- Timeline: Estimated 22 days, Actual 28 days (+27%)
- Quality gate failures: 3 instances
- [Detailed analysis]

[Security Agent] Analyzing security remediation...
- Phase 1: 47 vulnerabilities, 5 days to resolve
- Dependency issues: 12 packages had conflicts
- [Detailed findings]

[Architect Agent] Reviewing ADRs...
- 5 ADRs created, 3 created retroactively
- [Analysis]

[Each agent provides observations]

[All Agents] Analyzing user interactions and agent errors...
- Found 18 user corrections in git log
- Identified 12 instances of wrong tool usage
- User interrupted agents 7 times to provide guidance
- 3 commits reverted due to agent mistakes
- [Detailed findings]

[Migration Coordinator] Synthesizing patterns...

**Protocol Issues**:
- Pattern 1: Testing started too late (appeared in 3 phases)
- Pattern 2: Dependency conflicts discovered mid-migration
- Pattern 3: Documentation created in batches

**Agent Behavioral Issues** (CRITICAL):
- Pattern 4: Coder Agent used Bash cat instead of Read tool (23 instances)
- Pattern 5: Agent implemented features without confirming (4 major cases)
- Pattern 6: Agent didn't read files before modifying (8 instances)

Developing recommendations...

Top 6 recommendations by impact/effort ratio:
1. Always read before write - agent behavior (Impact: 9/10, Effort: 1/10) ← Agent behavior
2. Front-load dependency analysis - protocol (Impact: 9/10, Effort: 3/10)
3. Use appropriate tools enforcement - agent behavior (Impact: 8/10, Effort: 2/10) ← Agent behavior
4. Continuous documentation - protocol (Impact: 8/10, Effort: 2/10)
5. Confirm before implementing - agent behavior (Impact: 9/10, Effort: 2/10) ← Agent behavior
6. Automated security scanning - automation (Impact: 9/10, Effort: 5/10)

Creating IMPROVEMENTS.md...

✅ Retrospective complete: IMPROVEMENTS.md created
```

---

**Document Owner**: Migration Coordinator
**Protocol Version**: 1.0
**Last Updated**: 2025-11-01
**Companion Command**: `/retro-apply`

**Remember**: **Retrospectives are worthless without action. Review, approve, then apply.** ✅
