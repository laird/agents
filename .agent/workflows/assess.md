---
description: Analyze project for modernization readiness
---

# Project Modernization Assessment Protocol

**Version**: 1.0
**Purpose**: Systematically assess whether a project is a good candidate for modernization
**Output**: `docs/modernization-assessment.md` with comprehensive analysis and recommendation
**Duration**: 2-4 hours

---

## Overview

This protocol evaluates a software project across **8 critical dimensions** to determine:

- ✅ Is modernization **technically feasible**?
- ✅ Is modernization **financially worthwhile**?
- ✅ What are the **major risks and blockers**?
- ✅ What is the **recommended approach**?

**Core Principle**: **Assess before you commit - not all projects should be modernized.**

---

## Assessment Process

### Step 1: Project Discovery (30 minutes)

**Active Agent**: Documentation Agent

**Gather Basic Information**:
Run the following commands to gather project statistics:

```bash
# Count lines of code
find . -name "*.cs" -o -name "*.js" -o -name "*.py" -o -name "*.java" | xargs wc -l

# Check git history
git log --reverse --format="%ai" | head -1  # First commit
git log --format="%ai" | head -1            # Last commit
git shortlog -sn | head -10                 # Contributors

# Dependency analysis
# .NET: dotnet list package --outdated
# Node: npm outdated
# Python: pip list --outdated
```

### Step 2: Technical Viability Assessment (45 minutes)

**Active Agent**: Architect Agent

**Evaluations**:

1. **Framework Analysis**: Check EOL dates, migration paths, breaking changes.
2. **Dependency Health**: Count deprecated/unmaintained/vulnerable packages.
3. **Code Compatibility**: Estimate % of code affected by breaking changes.

**Scoring Criteria**:

- **80-100**: Clear migration path, well-documented, active community
- **60-79**: Migration path exists, some documentation gaps
- **40-59**: Difficult migration, limited documentation
- **0-39**: No clear path, framework deprecated, or major architectural change required

### Step 3: Business Value Assessment (30 minutes)

**Active Agent**: Architect Agent + Documentation Agent

**Evaluations**:

1. **Strategic Alignment**: Criticality, development status, strategic value.
2. **Effort-Benefit Analysis**: Estimated effort vs expected improvements (Security, Performance, Productivity).

### Step 4: Risk Assessment (30 minutes)

**Active Agent**: Migration Coordinator

**Identify and Rate Risks** (Likelihood / Impact / Severity):

- Technical Risks (Breaking changes, conflicts, regression)
- Business Risks (Disruption, data loss, cost)

**Overall Risk Profile**:

- **LOW**: <2 HIGH risks, 0 CRITICAL
- **MEDIUM**: 2-5 HIGH risks
- **HIGH**: >5 HIGH risks or 1-2 CRITICAL
- **CRITICAL**: >2 CRITICAL risks → **DO NOT PROCEED**

### Step 5: Resource Assessment (20 minutes)

**Active Agent**: Migration Coordinator

**Evaluations**:

- **Team Capacity**: Skills, availability, training needs.
- **Timeline Estimation**: Based on project size (Small 2-weeks, Medium 1-month, Large 2-months+).

### Step 6: Code Quality Analysis (30 minutes)

**Active Agent**: Architect Agent + Coder Agent

**Evaluations**:

1. **Architecture**: Pattern, separation of concerns, coupling.
2. **Code Metrics**: Cyclomatic complexity, duplication, method size.

**Commands**:

```bash
# Cyclomatic complexity tools (varies by language)
# Code duplication percentage
# Method/class size averages
```

### Step 7: Test Coverage & Stability (20 minutes)

**Active Agent**: Tester Agent

**Evaluations**:

- **Existing Test Suite**: Count, coverage %, pass rate %, execution time.
- **Production Stability**: Incidents, critical bugs, uptime.

### Step 8: Security Assessment (30 minutes)

**Active Agent**: Security Agent

**Evaluations**:

1. **Vulnerability Scan**:

   ```bash
   # .NET: dotnet list package --vulnerable
   # Node: npm audit
   # Python: pip-audit
   ```

2. **Security Score**: `100 - (CRITICAL*20 + HIGH*10 + MEDIUM*5 + LOW*1)`
3. **Security Posture**: Authentication, encryption, secrets management.

---

## Assessment Report Generation

**Active Agent**: Documentation Agent

Create `docs/modernization-assessment.md` using the collected data. The report MUST include:

1. **Executive Summary**: Recommendation (PROCEED / CAUTION / DEFER / STOP), Overall Score.
2. **Technical Viability**: Score, framework analysis, dependency health.
3. **Business Value**: Score, alignment, effort-benefit.
4. **Risk Assessment**: Matrix of key risks.
5. **Resource Requirements**: Estimates.
6. **Code Quality**: Score, architecture notes.
7. **Test Coverage**: Score, summary of suite.
8. **Security**: Score, CVE counts.
9. **Overall Assessment**: Weighted total score.

**Recommendation Matrix**:

- **80-100**: ✅ **PROCEED**
- **60-79**: ⚠️ **PROCEED WITH CAUTION**
- **40-59**: ❌ **DEFER**
- **0-39**: 🛑 **DO NOT PROCEED**

To proceed, issue /plan command
