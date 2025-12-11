---
description: Orchestrate a team of specialist agents to upgrade a project to be modern, secure, well-tested, and performant
---

# Project Modernization & Security Protocol

**Version**: 2.0
**Purpose**: Coordinate multiple specialist agents to systematically upgrade any software project
**Team**: Migration Coordinator, Security Agent, Architect Agent, Coder Agent, Tester Agent, Documentation Agent
**Inputs**: Optional `docs/modernization-assessment.md` and `docs/modernization-plan.md` from `/assess` and `/plan`

---

## Prerequisites Check

**Before starting, check for**:

1. **Test Environment Setup** (MANDATORY FIRST)
   - Verify build succeeds: `dotnet build` (establish baseline)
   - Verify tests run: `dotnet test` (establish pass rate baseline)
   - Run vulnerability scan: `dotnet list package --vulnerable --include-transitive`

2. **Assessment & Plan**
   - Check if `docs/modernization-assessment.md` exists. If not, consider running `/assess`.
   - Check if `PLAN.md` exists. If not, consider running `/plan`.

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

**Activities**:

1. **Test Environment Setup** (MANDATORY FIRST)
   - **Why First**: Cannot validate anything without working build/test environment
   - Install required SDKs (.NET, Node.js, Python, etc.)
   - Install Docker for integration testing
   - Configure environment variables
   - **Verify build succeeds**
   - **Verify tests run**
   - **Run vulnerability scan**
   - Document baseline metrics: test count, pass rate, build warnings, CVE count

2. **Security Baseline** (BLOCKING)
   - Use vulnerability scan from previous step
   - Calculate security score (0-100): `100 - (CRITICAL×10 + HIGH×5 + MEDIUM×2 + LOW×0.5)`
   - Categorize vulnerabilities
   - Document top 10 CVEs in ASSESSMENT.md

3. **Project Analysis**
   - Inventory all dependencies and frameworks
   - Identify current versions vs latest stable
   - Map project structure and architecture
   - Identify technology debt

4. **Technology Assessment**
   - Research latest framework versions
   - Identify obsolete APIs and patterns
   - Document breaking changes
   - Create upgrade roadmap

5. **Test Baseline Analysis**
   - Capture baseline metrics (pass rate, coverage, performance)
   - Document current test infrastructure
   - Identify test gaps

**Quality Gate**:

- ✅ Test environment ready (build succeeds, tests run)
- ✅ Baseline test metrics documented
- ✅ Vulnerability scan completed
- ✅ Security score calculated (≥45 required)
- ✅ All CRITICAL/HIGH vulnerabilities documented

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

3. **Post-Update Security Validation** (BLOCKING)
   - **Re-run vulnerability scan**
   - **Compare before/after**
   - **Verify CRITICAL/HIGH count decreased**
   - **Verify no NEW vulnerabilities introduced**
   - Recalculate security score
   - **Run all tests** to ensure no regressions
   - Update HISTORY.md

**Quality Gate**:

- ✅ Security scan re-run and results verified
- ✅ Security score ≥45
- ✅ Zero CRITICAL vulnerabilities
- ✅ Zero HIGH vulnerabilities
- ✅ No NEW vulnerabilities introduced
- ✅ All tests passing

---

### Phase 2: Architecture & Design (2-3 days)

**Active Agents**: Architect Agent (lead), Migration Coordinator

**Activities**:

#### Spike-Driven ADR Process for High-Risk Decisions

1. **Framework Upgrade Planning**
   - Research target framework versions
   - **For high-risk decisions**: Create spike branches
     - Test options on single project
     - Document actual compilation errors, API changes, test failures
   - Create ADRs with status "proposed" first
   - Mark ADRs as "accepted" after review

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

**Quality Gate**: All major decisions documented in ADRs, migration plan approved

---

### Phase 3: Framework & Dependency Modernization (5-10 days)

**Active Agents**: Coder Agent (multiple if parallel), Tester Agent, Migration Coordinator

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
   - Maintain 100% pass rate
   - No progression until tests pass

**Parallel Execution Strategy**:
Spawn multiple Coder agents for different modules if applicable, summarized by Migration Coordinator.

**Quality Gate**:

- ✅ All projects build successfully
- ✅ 100% test pass rate (MANDATORY)
- ✅ No P0/P1 issues
- ✅ Code coverage ≥80%

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
   - Add integration tests
   - Target ≥85% coverage

**Quality Gate**:

- ✅ Zero obsolete API warnings
- ✅ Code coverage ≥85%
- ✅ 100% test pass rate
- ✅ Code quality score improved

---

### Phase 5: Performance Optimization (2-4 days)

**Active Agents**: Coder Agent, Tester Agent, Architect Agent

**Activities**:

1. **Performance Profiling**
   - Run performance benchmarks
   - Identify bottlenecks
   - Compare against baseline

2. **Optimization Implementation**
   - Optimize critical paths
   - Implement caching, query improvements, etc.

3. **Validation**
   - Re-run benchmarks
   - Verify improvements
   - Ensure no regressions

**Quality Gate**:

- ✅ Performance improvement ≥10% OR documented as optimal
- ✅ No performance regressions
- ✅ All tests passing

---

### Phase 6: Comprehensive Documentation (2-3 days)

**Active Agents**: Documentation Agent (lead), Migration Coordinator

**Activities**:

1. **CHANGELOG Creation**
   - Document breaking changes, features, bug fixes, security updates

2. **MIGRATION-GUIDE.md**
   - Step-by-step upgrade instructions
   - Breaking change details
   - Code examples (before/after)

3. **Update Documentation**
   - README, API docs, Architecture docs

4. **ADR Summaries**
   - Compile all ADRs into index

**Quality Gate**: All documentation complete, reviewed, and accurate

---

### Phase 7: Final Validation & Release (1-2 days)

**Active Agents**: Tester Agent (lead), Security Agent, Migration Coordinator

**Activities**:

1. **Complete Test Execution**
   - Unit, Integration, Component, E2E tests (100% pass)
   - Performance validation

2. **Final Security Scan**
   - Run comprehensive CVE scan
   - Verify security score ≥45
   - Document any LOW/MEDIUM issues

3. **Release Preparation**
   - Tag release, notes, packaging, deployment checklist

4. **GO/NO-GO Decision**
   - Review all quality gates
   - Production readiness assessment

**Quality Gate** (GO/NO-GO Decision):

- ✅ Security score ≥45
- ✅ Zero CRITICAL/HIGH vulnerabilities
- ✅ 100% test pass rate
- ✅ Code coverage ≥85%
- ✅ Zero P0/P1 issues
- ✅ All documentation complete
- ✅ Performance validated

After modernization is complete, offer to /retro to improve the agents for future modernization projects
---

## Logging Protocol

**MANDATORY**: All agents must log to `HISTORY.md` using `./scripts/append-to-history.sh`

**When to Log**:

- After completing each phase
- After fixing security vulnerabilities
- After making architectural decisions
- After completing migrations
- After test validation
- After documentation updates
