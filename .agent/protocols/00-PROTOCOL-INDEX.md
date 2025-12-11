# RawRabbit Migration Protocols - Master Index

**Purpose**: Central navigation hub for all migration protocols and documentation
**Last Updated**: 2025-10-17
**Version**: 2.0 (Restructured)

---

## Quick Start Guide

**New to the protocols?** Start here:

1. Read this index to understand the structure
2. Review the **QUICK-REFERENCE** cards (1-page summaries)
3. Dive into **CORE-PROTOCOLS** for detailed workflows
4. Reference **DOCUMENTATION-PROTOCOLS** for ADRs, logging, etc.

**Experienced user?** Jump directly to:

- [Quick Reference Cards](#quick-reference-cards) (1-page summaries)
- [Core Protocols](#core-protocols-execution--quality)
- [Documentation Protocols](#documentation-protocols)

---

## Protocol Structure (v2.0)

### Hierarchy Overview

```
docs/agents/
├── 00-PROTOCOL-INDEX.md           ← You are here (master index)
│
├── QUICK-REFERENCE/               ← 1-page cheatsheets (start here!)
│   ├── parallel-execution-cheatsheet.md
│   ├── testing-cheatsheet.md
│   └── adr-cheatsheet.md
│
├── CORE-PROTOCOLS/                ← Execution & quality protocols
│   ├── PARALLEL-MIGRATION-PROTOCOL.md
│   ├── CONTINUOUS-TESTING-PROTOCOL.md
│   ├── STAGE-VALIDATION-PROTOCOL.md
│   └── GENERIC-MIGRATION-PLANNING-GUIDE.md
│
├── DOCUMENTATION-PROTOCOLS/       ← Documentation & logging
│   ├── DOCUMENTATION-MASTER.md
│   ├── ADR-LIFECYCLE-DETAILED.md
│   ├── AGENT-LOGGING-DETAILED.md
│   └── INCREMENTAL-DOCS-DETAILED.md
│
└── [Legacy files]                 ← Old structure (to be migrated)
```

---

## Quick Reference Cards

**Purpose**: 1-page summaries for common tasks (read these first!)

### 1. Parallel Execution Cheatsheet

**File**: `QUICK-REFERENCE/parallel-execution-cheatsheet.md`

**Use when**: Migrating multiple independent projects simultaneously

**Quick syntax**:

```bash
# Analyze
./scripts/analyze-dependencies.sh "src/pattern"

# Spawn in SINGLE message
Task("Project 1", "...", "coder")
Task("Project 2", "...", "coder")
...
```

**Time savings**: 50-83% reduction vs. sequential execution

---

### 2. Continuous Testing Cheatsheet

**File**: `QUICK-REFERENCE/testing-cheatsheet.md`

**Use when**: After completing any migration stage

**Quick syntax**:

```bash
# Run stage tests
./scripts/run-stage-tests.sh 3 "Operations" strict

# If failed, analyze
./scripts/analyze-test-failure.sh 3
```

**Key rule**: Fix-before-proceed (max 3 iterations)

---

### 3. ADR Lifecycle Cheatsheet

**File**: `QUICK-REFERENCE/adr-cheatsheet.md`

**Use when**: Making significant architectural decisions

**Quick syntax**:

```bash
# Create ADR (note: spaces in filename!)
touch "docs/adr/ADR 0004 Your Decision Title.md"

# Log to HISTORY.md
./scripts/append-to-history.sh "ADR 0004: Title" "..."
```

**Naming**: `ADR #### Title With Spaces.md` (spaces, not dashes!)

---

## Core Protocols (Execution & Quality)

### 1. Parallel Migration Protocol

**File**: `CORE-PROTOCOLS/PARALLEL-MIGRATION-PROTOCOL.md`
**Lines**: 474
**Purpose**: Maximize efficiency through concurrent agent execution

**Key concepts**:

- Dependency level analysis (Level 0 = fully parallel)
- Single-message agent spawning pattern
- Time savings calculation (50-67% reduction)

**When to use**:

- Stage 3 (Operations): 8 projects → parallel
- Stage 4 (Enrichers): 6-11 projects → partial parallel
- Stage 5 (DI Adapters): 3 projects → parallel
- Any stage with 3+ independent projects

**Scripts**:

- `scripts/analyze-dependencies.sh`
- `scripts/migrate-stage.sh` (integrates parallel enforcement)

**Quick reference**: `QUICK-REFERENCE/parallel-execution-cheatsheet.md`

---

### 2. Continuous Testing Protocol

**File**: `CORE-PROTOCOLS/CONTINUOUS-TESTING-PROTOCOL.md`
**Lines**: 577
**Purpose**: Catch bugs early through systematic testing after every stage

**Key concepts**:

- Fix-before-proceed rule (max 3 iterations)
- Stage-specific test filtering
- Automated failure analysis with pattern matching

**Test phases**:

1. Setup (environment validation)
2. Unit Tests (fast, no dependencies)
3. Integration Tests (requires RabbitMQ)
4. Component Tests (subsystem validation)
5. Performance Tests (BenchmarkDotNet)
6. Sample Tests (end-to-end scenarios)

**When to use**:

- After EVERY migration stage (mandatory)
- Before advancing to next stage
- When implementing fixes (retest until pass)

**Scripts**:

- `scripts/run-stage-tests.sh` (blocking mode)
- `scripts/analyze-test-failure.sh` (root cause analysis)
- `scripts/capture-test-baseline.sh` (regression detection)

**Quick reference**: `QUICK-REFERENCE/testing-cheatsheet.md`

---

### 3. Stage Validation Protocol

**File**: `CORE-PROTOCOLS/STAGE-VALIDATION-PROTOCOL.md`
**Lines**: 615
**Purpose**: Automated quality gate enforcement

**Quality gates**:

1. ✅ Build Success (0 errors, 0 warnings)
2. ✅ Test Pass Rate (100% all test types)
3. ✅ Security Scan (0 CRITICAL/HIGH CVEs)
4. ✅ Documentation Updates (HISTORY.md, CHANGELOG.md current)
5. ✅ Code Coverage (≥80% line coverage)
6. ✅ ADR Compliance (decisions documented)

**When to use**:

- After stage completion (before advancing)
- Before creating PR
- As part of CI/CD pipeline

**Scripts**:

- `scripts/validate-migration-stage.sh` (comprehensive validation)
- `scripts/protocol-compliance-dashboard.sh` (real-time monitoring)

**Integration**: Used by `migrate-stage.sh` automatically

---

### 4. Migration Planning Guide

**File**: `CORE-PROTOCOLS/GENERIC-MIGRATION-PLANNING-GUIDE.md`
**Lines**: 802
**Purpose**: 5-phase framework for planning complex migrations

**Phases**:

1. **Discovery** (assess scope, dependencies, risks)
2. **Planning** (create stages, estimate timeline)
3. **Security** (CVE assessment, vulnerability remediation)
4. **Execution** (staged migration with validation)
5. **Validation** (comprehensive testing, documentation)

**Phasing strategies**:

- Bottom-up (dependencies first)
- Top-down (applications first, then libraries)
- Risk-based (high-risk components isolated)
- Hybrid (combination approach)

**When to use**:

- At project start (before Stage 0)
- For complex migrations (10+ projects)
- When timeline estimates needed

**Outputs**:

- `docs/modernization-plan.md` (detailed migration plan)
- Stage breakdown with dependencies
- Timeline estimates
- Risk assessment

---

## Documentation Protocols

### 1. Documentation Master

**File**: `DOCUMENTATION-PROTOCOLS/DOCUMENTATION-MASTER.md`
**Purpose**: Single source of truth for all documentation practices

**Integrates**:

- HISTORY.md logging (audit trail)
- ADR lifecycle (architectural decisions)
- Incremental documentation (continuous updates)

**Structure**:

- Part 1: HISTORY.md (see Agent Logging Detailed)
- Part 2: ADRs (see ADR Lifecycle Detailed)
- Part 3: Inline Documentation (code comments, README updates)

**When to use**: As primary documentation reference

---

### 2. ADR Lifecycle (Detailed)

**File**: `DOCUMENTATION-PROTOCOLS/ADR-LIFECYCLE-DETAILED.md`
**Lines**: 736
**Purpose**: Complete specification for Architecture Decision Records

**7 lifecycle stages**:

1. Creation (Status: Proposed)
2. Review (team feedback)
3. Acceptance (Status: Accepted)
4. Implementation (Status: Implemented)
5. Validation (Status: Validated)
6. Post-Implementation Review (lessons learned)
7. Deprecation/Superseding (Status: Superseded/Deprecated)

**Critical naming**: `ADR #### Title With Spaces.md` (note spaces!)

**When to use**:

- Before making architectural decisions
- For technology selections
- For approach/pattern choices
- When team consensus needed

**Quick reference**: `QUICK-REFERENCE/adr-cheatsheet.md`

---

### 3. Agent Logging (Detailed)

**File**: `DOCUMENTATION-PROTOCOLS/AGENT-LOGGING-DETAILED.md`
**Lines**: 436
**Purpose**: Comprehensive logging to HISTORY.md for audit trail

**7 logging templates**:

1. Stage Completion
2. Project Migration
3. Fix/Iteration
4. Architecture Decision
5. Security Assessment
6. Testing Results
7. Documentation Update

**4-parameter structure**:

```bash
./scripts/append-to-history.sh \
  "WHAT: Title" \
  "WHY: Reason and context" \
  "IMPACT: What changed" \
  "OUTCOME: Result and next steps"
```

**When to use**:

- After every significant action
- When completing stages
- When making decisions
- During debugging iterations

**Script**: `scripts/append-to-history.sh`

---

### 4. Incremental Documentation (Detailed)

**File**: `DOCUMENTATION-PROTOCOLS/INCREMENTAL-DOCS-DETAILED.md`
**Lines**: 631
**Purpose**: Continuous documentation throughout migration (not at end)

**Update frequency**:

- HISTORY.md: After every action (real-time)
- CHANGELOG.md: After every stage (incremental)
- README.md: When API/usage changes
- Migration Guide: When patterns discovered
- ADRs: Before/during decisions (not after)

**Anti-pattern**: End-of-project documentation marathon

**Time savings**: 1-2 hours (documenting fresh vs. reconstructing from memory)

**When to use**: Throughout entire migration, not just at end

---

## Automation Scripts

### Located in `/scripts/`

**Parallel Execution**:

- `analyze-dependencies.sh` - Identify parallelization opportunities
- `migrate-stage.sh` - Master orchestration with protocol enforcement

**Testing**:

- `run-stage-tests.sh` - Stage-specific test execution (blocking mode)
- `analyze-test-failure.sh` - Pattern-based root cause analysis
- `capture-test-baseline.sh` - Pre/post migration comparison
- `compare-with-baseline.sh` - Regression detection

**Validation**:

- `validate-migration-stage.sh` - 6-gate quality validation
- `protocol-compliance-dashboard.sh` - Real-time compliance monitoring

**Documentation**:

- `append-to-history.sh` - Structured HISTORY.md logging

**Pattern Detection**:

- `scan-rabbitmq-patterns.sh` - RabbitMQ.Client 6.x compatibility scanner

---

## Usage Patterns

### Pattern 1: Starting a New Migration

```bash
# 1. Read planning guide
cat docs/agents/CORE-PROTOCOLS/GENERIC-MIGRATION-PLANNING-GUIDE.md

# 2. Create migration plan
# (Creates docs/modernization-plan.md)

# 3. Begin Stage 0 (Prerequisites)
./scripts/migrate-stage.sh 0 "Prerequisites"
```

---

### Pattern 2: Executing a Parallelizable Stage

```bash
# 1. Quick reference
cat docs/agents/QUICK-REFERENCE/parallel-execution-cheatsheet.md

# 2. Run master script (enforces parallel)
./scripts/migrate-stage.sh 3 "Operations" "src/RawRabbit.Operations.*"

# Script automatically:
# - Runs analyze-dependencies.sh
# - Prompts for parallel confirmation
# - Runs tests after completion
# - Validates quality gates
```

---

### Pattern 3: Creating an ADR

```bash
# 1. Quick reference
cat docs/agents/QUICK-REFERENCE/adr-cheatsheet.md

# 2. Create ADR file (note spaces!)
touch "docs/adr/ADR 0004 Your Decision.md"

# 3. Fill in template (see cheatsheet)

# 4. Log to HISTORY.md
./scripts/append-to-history.sh \
  "ADR 0004: Your Decision" \
  "Created ADR for [decision topic]" \
  "Document decision before implementation" \
  "ADR ready for team review"
```

---

### Pattern 4: Debugging Test Failures

```bash
# 1. Test fails
./scripts/run-stage-tests.sh 3 "Operations" strict
# ❌ GATE FAILED: 2 tests failed

# 2. Analyze failures
./scripts/analyze-test-failure.sh 3
# Output: Pattern detected, fix suggestions

# 3. Apply fixes (see pattern library)

# 4. Retest
./scripts/run-stage-tests.sh 3 "Operations" strict
# ✅ GATE PASSED
```

---

## Common Workflows

### Workflow 1: Simple Stage (No Parallelization)

```
1. Execute stage work
2. Build (verify 0 errors)
3. Run stage tests (strict mode)
4. Validate quality gates
5. Log to HISTORY.md
6. Proceed to next stage
```

### Workflow 2: Complex Stage (Parallel Execution)

```
1. Analyze dependencies
2. Confirm parallel opportunities
3. Spawn ALL agents in SINGLE message
4. Wait for concurrent completion
5. Run stage tests (strict mode)
6. Validate quality gates
7. Capture baseline
8. Log to HISTORY.md
9. Proceed to next stage
```

### Workflow 3: Fix-and-Retest Cycle

```
1. Tests fail
2. Analyze failure patterns
3. Apply fixes
4. Retest (track iteration count)
5. Repeat until pass (max 3 iterations)
6. If exceed 3: escalate to senior engineer
```

---

## Protocol Compliance Targets

| Protocol | Target Compliance | Current Status |
|----------|------------------|----------------|
| Parallel Migration | 95% | ⚠️ Improvement needed |
| Continuous Testing | 95% | ⚠️ Improvement needed |
| Stage Validation | 90% | ⚠️ Improvement needed |
| ADR Lifecycle | 95% | ✅ Good |
| Agent Logging | 98% | ✅ Excellent |
| Incremental Docs | 95% | ✅ Excellent |

**Improvement target**: 95% overall compliance (up from 63%)

---

## Document History

### Version 2.0 (2025-10-17) - Restructuring

- Created new directory structure (CORE-PROTOCOLS, DOCUMENTATION-PROTOCOLS, QUICK-REFERENCE)
- Added 3 quick reference cards (1-page summaries)
- Fixed ADR naming convention globally (spaces not dashes)
- Created master index (this document)
- Consolidated documentation protocols
- Improved navigation and accessibility

### Version 1.0 (2025-10-13) - Initial

- Original protocol suite created
- 8 core protocols documented
- 5 automation scripts developed
- Validated through RawRabbit migration

---

## Getting Help

### Quick Questions

- Check relevant **QUICK-REFERENCE** card first
- Search this index for keywords
- Review recent HISTORY.md entries for examples

### Detailed Information

- Read full **CORE-PROTOCOLS** or **DOCUMENTATION-PROTOCOLS**
- Review real examples in `docs/adr/` and `docs/HISTORY.md`
- Check automation script help: `script-name.sh --help`

### Issues or Improvements

- Document in HISTORY.md with lessons learned
- Create ADR for protocol changes
- Update this index after protocol modifications

---

## Related Documentation

**In this repository**:

- `docs/HISTORY.md` - Complete migration audit trail (548+ lines)
- `docs/modernization-plan.md` - RawRabbit migration plan
- `docs/adr/` - Architecture decision records (6+ ADRs)
- `docs/IMPROVEMENTS.md` - Process improvement proposals
- `docs/reports/` - Analysis reports

**External**:

- MADR 3.0.0 Specification (ADR format)
- .NET 9.0 Migration Guide
- RabbitMQ.Client 6.x Documentation

---

**Maintained by**: Migration Coordination Team
**Review Frequency**: After each major migration
**Last Review**: 2025-10-17
**Next Review**: After next migration completion
