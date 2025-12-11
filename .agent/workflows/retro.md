---
description: Run a retrospective to identify process improvements
---

# Retrospective Process Improvement Protocol

**Version**: 1.0
**Purpose**: Coordinate agents to review project history and identify process improvements
**Output**: `IMPROVEMENTS.md` (ADR format with 3-5 specific recommendations)
**Duration**: 2-4 hours

---

## Overview

This protocol orchestrates a **multi-agent retrospective** to analyze project history, identify inefficiencies, bottlenecks, risks, and **agent behavioral issues**, then produce a unified set of **3-5 specific, actionable recommendations** for process improvement.

**Improvements Target**:

- **Agent Behavior**: Wrong tool usage, wasted effort, requirement misunderstandings.
- **Protocol Updates**: Process changes, new phases, quality gates.
- **Automation**: Scripts, hook, CI/CD.
- **Commands**: Updates to command files.

**CRITICAL**: User interruptions and corrections are the strongest signal that agents need behavioral improvement.

---

## Retrospective Process

### Phase 1: Historical Analysis (60 minutes)

**1.1 Review Project History (Migration Coordinator)**

- Analyze `HISTORY.md` for patterns, blockers, delays, and quality gate failures.

**1.2 Review ADRs (Architect Agent)**

- Analyze `docs/ADR/` for decision outcomes, rework, and alternatives.

**1.3 Review Test History (Tester Agent)**

- Analyze test pass rates, flaky tests, and coverage evolution.

**1.4 Review Security History (Security Agent)**

- Analyze vulnerability remediation timelines and scanning frequency.

**1.5 Review Code Changes (Coder Agent)**

- Analyze git history for churn, large commits, and reverts.

```bash
git log --all --oneline --graph
git shortlog -sn
```

**1.6 Review Documentation (Documentation Agent)**

- Analyze completeness of CHANGELOG, Migration Guide, and README.

**1.7 Review User Interactions & Agent Errors (CRITICAL - All Agents)**
Search for user interruptions and corrections:

```bash
# Git commit messages with corrections
bash -c 'git log --all --grep="fix\|correct\|actually\|oops\|mistake"'

# History for user interventions
bash -c 'grep -i "user:\|correction\|fix\|reverted\|undo" HISTORY.md'

# Reverted commits
bash -c 'git log --all --oneline | grep -i "revert\|undo"'
```

**Identify Agent Mistakes**:

- **Wrong Tool Usage**: Using `bash cat` instead of `Read`, `find` instead of `Glob`.
- **Wasted Effort**: Building unrequested features.
- **Context Ignorance**: Not reading files before editing.
- **Requirement Misunderstanding**: User corrections needed.

---

### Phase 2: Agent Insights Gathering (30 minutes)

**Objective**: Each agent identifies problems and opportunities from their perspective.

**Template**:

- **What Went Well**: Positive observations.
- **What Could Be Improved**: Inefficiencies/problems.
- **Specific Recommendations**: Actionable items.

---

### Phase 3: Pattern Identification (30 minutes)

**Active Agent**: Migration Coordinator

Synthesize findings into themes:

- **Agent Behavioral Issues** (CRITICAL): Wrong tools, misunderstood requirements.
- **Protocol Improvements**: Timing of tests, gates, validation.
- **LLM-to-Code Opportunities**: Replace LLM calls with scripts (jq, awk, sed).
- **Context Window Optimization**: Reduce token waste.

---

### Phase 4: Recommendation Development (45 minutes)

**Active Agent**: All Agents (Collaborative)

Develop 3-5 specific, actionable recommendations.

**Criteria**: Specific, Actionable, Measurable, Evidence-based, High-impact.

**Example Recommendations**:

1. **Front-load Dependency Analysis**: To prevent mid-migration blockers.
2. **Continuous Documentation**: Update docs daily, not in batches.
3. **Automated Security Scanning**: Add to git hooks.
4. **"Read before Write" Enforcement**: Prevent file overwrites.
5. **Replace LLM with Scripts**: Use `jq`/`awk` for deterministic tasks.

---

### Phase 5: ADR Generation (30 minutes)

**Active Agent**: Documentation Agent

Create `IMPROVEMENTS.md` in MADR 3.0.0 format.

After retro is complete, suggest reviewing the suggested IMPROVEMENTS.md and then /retro-apply .

**Structure**:

1. **Context**: Analysis sources, key metrics.
2. **Decision Drivers**: Efficiency, Quality, Risk.
3. **Recommendations**:
   - **Problem**: Description and Evidence.
   - **Proposed Change**: Protocol, Behavior, or Automation update.
   - **Expected Impact**: Efficiency/Quality gains.
   - **Implementation**: Steps and Effort.
4. **Summary**: Priority table.
5. **Implementation Plan**: Immediate vs Long-term.
