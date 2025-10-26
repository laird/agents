---
name: modernize-project
description: Orchestrate a team of specialist agents to upgrade a project to be modern, secure, well-tested, and performant
---

# Project Modernization & Security Protocol

**Version**: 2.0
**Purpose**: Coordinate multiple specialist agents to systematically upgrade any software project
**Team**: Migration Coordinator, Security Agent, Architect Agent, Coder Agent, Tester Agent, Documentation Agent
**Inputs**: Optional `assessment.md` and `plan.md` from `/modernize-assess` and `/modernize-plan`

---

## Prerequisites Check

**Before starting, this command checks for**:

```bash
# Check for assessment
if [ -f "assessment.md" ]; then
    echo "✅ Found assessment.md - will use assessment findings"
    USE_ASSESSMENT=true
else
    echo "⚠️  No assessment.md - recommend running /modernize-assess first"
    echo "   Continue with basic assessment? (y/n)"
    USE_ASSESSMENT=false
fi

# Check for plan
if [ -f "plan.md" ]; then
    echo "✅ Found plan.md - will follow existing plan"
    USE_PLAN=true
else
    echo "⚠️  No plan.md - will create plan on-the-fly"
    echo "   Recommend running /modernize-plan first for better accuracy"
    USE_PLAN=false
fi
```

**Recommendation Workflow**:
1. **Best**: Run `/modernize-assess` → `/modernize-plan` → `/modernize-project`
2. **Good**: Run `/modernize-plan` → `/modernize-project`
3. **Acceptable**: Run `/modernize-project` (will create minimal assessment/plan inline)

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
IF assessment.md EXISTS:
    ✅ Skip detailed assessment
    ✅ Use existing scores, risks, estimates
    ✅ Focus on validation and updates
    Duration: 0.5-1 day (validation only)
ELSE:
    ⚠️  Run full assessment (as described below)
    Duration: 1-2 days
```

**Activities**:
1. **Project Analysis**
   - **If assessment.md exists**: ✅ Load existing inventory
   - **If no assessment**: Inventory all dependencies and frameworks
   - Identify current versions vs latest stable
   - Map project structure and architecture
   - Identify technology debt
   - **Deliverable**: Project assessment (or validate existing)

2. **Security Baseline** (BLOCKING)
   - Run CVE vulnerability scan
   - Calculate security score (0-100)
   - Categorize vulnerabilities (CRITICAL/HIGH/MEDIUM/LOW)
   - **BLOCK**: Must achieve ≥45 security score before proceeding

3. **Technology Assessment**
   - Research latest framework versions
   - Identify obsolete APIs and patterns
   - Document breaking changes
   - Create upgrade roadmap

4. **Test Baseline**
   - Run all existing tests
   - Capture baseline metrics (pass rate, coverage, performance)
   - Document current test infrastructure
   - Identify test gaps

**Outputs**:
- Project assessment report (or use existing assessment.md)
- Security vulnerability report
- Technology upgrade roadmap
- Test baseline report
- Initial HISTORY.md entry

**With Existing Assessment**:
- ✅ Validate assessment still accurate (dependencies haven't changed)
- ✅ Update if needed (typically minimal)
- ✅ Faster completion (0.5-1 day vs 1-2 days)

**Quality Gate**: Security score ≥45, all CRITICAL/HIGH vulnerabilities documented

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

3. **Validation** (BLOCKING)
   - Re-run security scan
   - Verify CVE fixes
   - Run all tests to ensure no regressions
   - Update security score

**Outputs**:
- Security fixes applied
- Updated security scan report
- Test results (must maintain ≥95% pass rate)
- HISTORY.md entry for security work

**Quality Gate**:
- Security score ≥45
- Zero CRITICAL vulnerabilities
- Zero HIGH vulnerabilities (or documented with explicit approval)
- All tests passing (100%)

---

### Phase 2: Architecture & Design (2-3 days)

**Active Agents**: Architect Agent (lead), Migration Coordinator

**Input Handling**:
```
IF plan.md EXISTS:
    ✅ Use existing architecture decisions
    ✅ Validate ADRs are current
    ✅ Follow defined strategy
    Duration: 0.5-1 day (validation only)
ELSE:
    ⚠️  Create architecture decisions (as described below)
    Duration: 2-3 days
```

**Activities**:
1. **Framework Upgrade Planning**
   - Research target framework versions
   - Evaluate migration paths
   - Document breaking changes
   - Create ADRs for major decisions

2. **Dependency Strategy**
   - Identify dependency upgrade order
   - Map dependency conflicts
   - Plan parallel vs sequential updates
   - Create dependency upgrade matrix

3. **Architecture Decisions**
   - Obsolete pattern replacements
   - New feature approaches
   - Performance optimization strategies
   - Testing strategy updates

**Outputs**:
- ADRs for all major decisions (MADR 3.0.0 format) - or use existing from plan.md
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
IF plan.md EXISTS:
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
   - Fix-and-retest cycles
   - Maintain ≥95% pass rate
   - No progression until tests pass

**Parallel Execution Strategy**:
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
→ Action: Tester Agent documents failures
→ Coder Agent fixes issues
→ Re-run fix-and-retest cycle
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
