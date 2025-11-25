---
name: adr-lifecycle
description: ADR lifecycle protocol with 7 stages from creation to deprecation (MADR 3.0.0 format)
---

# ADR Lifecycle Protocol

**Version**: 1.1
**Date**: 2025-10-13
**Purpose**: Ensure ADRs are living documents updated throughout the decision lifecycle
**Applicability**: All architectural decisions in any .NET project

---

## Overview

Architecture Decision Records (ADRs) are **living documents** that must be updated throughout the entire decision lifecycle, from initial research through implementation and post-implementation review. This protocol ensures ADRs accurately reflect the evolution of architectural decisions and serve as reliable historical records.

---

## ADR File Naming Convention (MANDATORY)

**All ADR files MUST follow this exact naming pattern**:

```
ADR #### Title With Spaces.md
```

**Format Rules**:
- Prefix: `ADR` (uppercase, with space after)
- Number: Four digits with leading zeros (`0001`, `0002`, `0042`, `1234`)
- Space after number
- Title: Human-readable title with spaces between words (Title Case)
- Extension: `.md`

### ✅ Correct Examples

```
ADR 0001 Target Framework NET9.md
ADR 0002 RabbitMQ Client Upgrade.md
ADR 0003 ZeroFormatter Deprecation.md
ADR 0015 Dependency Injection Container Selection.md
ADR 0042 Serialization Enricher Strategy.md
```

### ❌ Incorrect Examples

```
0001-target-framework-net9.md          ❌ No ADR prefix, uses dashes
adr-0002-rabbitmq-upgrade.md            ❌ Lowercase, uses dashes
ADR 0003 ZeroFormatter-Deprecation.md   ❌ Uses dashes instead of spaces
ADR0004Ninject.md                       ❌ No spaces
ADR 04 Short Title.md                   ❌ Only 2 digits (need 4)
```

### Rationale

- **Readability**: Spaces make titles easier to read in file browsers
- **Sortability**: Four-digit numbers ensure proper alphanumeric sorting (0001 comes before 0100)
- **Consistency**: Single standard prevents confusion
- **Searchability**: "ADR ####" pattern easy to grep/search

### Creating New ADR

```bash
# Get next ADR number
LAST_ADR=$(ls docs/adr/ADR\ *.md | tail -1 | sed 's/.*ADR //' | sed 's/ .*//')
NEXT_NUM=$(printf "%04d" $((10#$LAST_ADR + 1)))

# Create new ADR with correct naming
touch "docs/adr/ADR $NEXT_NUM Your Decision Title.md"
```

### Enforcement

Agents MUST:
- Use correct naming when creating ADRs
- Rename any incorrectly named ADRs discovered
- Document the naming convention in project README/CLAUDE.md

---

## ADR Lifecycle Stages

### Stage 1: Problem Identification → Status: `proposed`

**When**: As soon as an architectural decision need is identified

**Actions**:
1. Create initial ADR with status `proposed`
2. Document the problem/context clearly
3. List initial decision drivers (constraints, requirements)
4. Identify preliminary alternatives (minimum 1-2 initially)

**ADR Content**:
```markdown
# ADR ####: [Decision Title]

## Status

proposed

## Context and Problem Statement

[Clear description of the architectural problem requiring a decision]

## Decision Drivers

* [Initial constraint 1]
* [Initial requirement 1]
* [More to be added during research]

## Considered Options

* [Option 1 - preliminary]
* [Option 2 - preliminary]
* [More options to be researched]

## Decision Outcome

**NOT YET DECIDED** - Research in progress

## Notes

- Created: YYYY-MM-DD
- Next steps: Research alternatives, evaluate options
```

**Example**:
```markdown
# ADR-0015: Dependency Injection Container Selection

## Status

proposed

## Context and Problem Statement

Project currently supports multiple DI containers (Autofac, Ninject, Microsoft DI).
Need to decide which containers to maintain for modern .NET compatibility.

## Decision Drivers

* Modern .NET compatibility
* Community adoption and maintenance
* Migration effort for users
* Performance characteristics

## Considered Options

* Keep all three (Autofac, Ninject, Microsoft DI)
* Deprecate Ninject, keep Autofac and Microsoft DI
* Microsoft DI only
* [More research needed]

## Decision Outcome

**NOT YET DECIDED** - Research in progress

## Notes

- Created: 2025-10-12
- Next steps: Research Ninject modern .NET compatibility, evaluate Autofac adoption
```

---

### Stage 2: Research Phase → Status: `proposed` (updated)

**When**: During active research of alternatives

**Actions**:
1. Update ADR with each alternative researched
2. Add pros/cons as discovered
3. Document research sources
4. Add evaluation criteria
5. Create evaluation matrix (preliminary scores)

**Frequency**: Update ADR after researching each alternative (incremental updates)

**ADR Updates**:
```markdown
## Considered Options

* Option 1: [Name]
* Option 2: [Name]
* Option 3: [Name]
* Option 4: [Name]

## Pros and Cons of the Options

### Option 1: [Name]

[Research findings]

* Good, because [researched benefit A]
* Good, because [researched benefit B]
* Bad, because [discovered limitation C]
* Bad, because [discovered limitation D]

[Repeat for each option]

## Research Sources

* [Official documentation URL]
* [GitHub repository - stars, activity, issues]
* [Benchmark results]
* [Community discussions]

## Evaluation Matrix

| Criteria | Weight | Option 1 | Option 2 | Option 3 | Option 4 |
|----------|--------|----------|----------|----------|----------|
| Performance | High | ?/5 | 4/5 | ?/5 | 3/5 |
| Maintainability | High | ?/5 | ?/5 | 5/5 | 4/5 |
| [More criteria] | ... | ... | ... | ... | ... |

**Status**: Research ongoing, scores incomplete
```

**Commit Message**: `docs: Update ADR #### with [Option Name] research findings`

---

### Stage 2.5: Spike Validation (HIGH-RISK DECISIONS ONLY) → Status: `proposed` (spikes in progress)

**NEW per Retrospective Recommendation 2**

**When**: For high-risk architectural decisions requiring empirical validation

**High-Risk Decision Criteria** (require spikes):
- Dependency major version changes (e.g., RabbitMQ.Client 5→6, Polly 5→8)
- Framework migrations (e.g., .NET Standard → .NET 8)
- Architectural pattern changes (e.g., sync → async)
- Removal of features (e.g., deprecating a DI container)

**Actions**:
1. **Create spike branches for top 2-3 alternatives** (1-2 days)
   - `spike/adr-####-option-1-[name]`
   - `spike/adr-####-option-2-[name]`
2. **For each spike**:
   - Test option on single representative project
   - Attempt actual implementation (not just research)
   - Run tests and document pass rates
   - Count compilation errors, file changes required
   - Measure performance if relevant
3. **Document empirical findings in ADR**
4. **Update evaluation matrix with spike results**
5. **Allow 24-48hr stakeholder review period** before Stage 4

**ADR Updates**:
```markdown
## Spike Validation Results

### Spike 1: Option 2 (RabbitMQ.Client 6.8.1 LTS)

**Branch**: `spike/adr-0002-option-2-rabbitmq-6.8.1`
**Duration**: 4 hours
**Files Modified**: 23 files
**Compilation Errors**: 12 errors (all fixable)
**Test Results**:
- Unit tests: 89% passing (17/156 failing)
- Integration tests: 100% passing (112/112)
**Issues Found**:
- `IRecoverable.Recovery` event signature changed
- Publisher confirms API changed (events → WaitForConfirmsOrDie)
- `BasicProperties` constructor now protected

**Effort Estimate**: 12-15 hours based on spike

### Spike 2: Option 3 (RabbitMQ.Client 7.x)

**Branch**: `spike/adr-0002-option-3-rabbitmq-7.x`
**Duration**: 3.5 hours
**Files Modified**: 18 files
**Compilation Errors**: 6 errors (all fixable)
**Test Results**:
- Unit tests: 94% passing (9/156 failing)
- Integration tests: 100% passing (112/112)
**Issues Found**:
- Simpler async patterns (designed for .NET 6+)
- Connection pooling simplified

**Effort Estimate**: 8-10 hours based on spike

## Evaluation Matrix (Updated with Spike Data)

| Criterion | Weight | Option 2 (6.8.1 LTS) | Option 3 (7.x) |
|-----------|--------|----------------------|----------------|
| API Compatibility (spike) | High | 3/5 (12 errors) | 4/5 (6 errors) |
| Test Pass Rate (spike) | High | 3/5 (89%) | 4/5 (94%) |
| Migration Effort (spike) | High | 3/5 (12-15hrs) | 5/5 (8-10hrs) |
| LTS Support (docs) | High | 5/5 | 3/5 |
| **Weighted Total** | | **3.5/5** | **4.0/5** ✅

**Spike Conclusion**: Option 3 (7.x) shows better compatibility with .NET 8 despite shorter LTS.
```

**Commit Message**: `docs: Add ADR #### spike validation results for Options 2 and 3`

**Stakeholder Review Period**:
- Share ADR with spike results
- Wait 24-48 hours for feedback
- Address questions/concerns
- Do NOT proceed to Stage 4 without review

---

### Stage 3: Evaluation Complete → Status: `proposed` (evaluation ready)

**When**: All alternatives researched, evaluation matrix complete

**Actions**:
1. Complete evaluation matrix with all scores
2. Calculate weighted scores
3. Document trade-offs
4. Add preliminary recommendation
5. **DO NOT change status to `accepted` yet**

**ADR Updates**:
```markdown
## Evaluation Matrix

| Criteria | Weight | Option 1 | Option 2 | Option 3 | Option 4 |
|----------|--------|----------|----------|----------|----------|
| Performance | High | 4/5 | 4/5 | 5/5 | 3/5 |
| Maintainability | High | 3/5 | 4/5 | 5/5 | 4/5 |
| Migration Cost | Medium | 5/5 | 3/5 | 2/5 | 4/5 |
| Community Support | High | 5/5 | 4/5 | 5/5 | 3/5 |
| **Weighted Score** | | **4.3** | **3.9** | **4.5** | **3.4** |

## Preliminary Recommendation

Based on evaluation, **Option 3** appears most favorable:
- Highest weighted score (4.5/5)
- Best performance and maintainability
- Strong community support
- Trade-off: Higher migration cost (acceptable given long-term benefits)

**Decision pending stakeholder review and final approval.**
```

**Commit Message**: `docs: Complete ADR #### evaluation matrix and preliminary recommendation`

---

### Stage 4: Decision Made → Status: `accepted` or `rejected`

**When**: Final decision approved (by team lead, architect, stakeholders)

**Actions**:
1. **Update status** to `accepted` or `rejected`
2. Document final decision outcome
3. Document decision rationale
4. List positive and negative consequences
5. Add implementation plan outline
6. **Log to HISTORY.md** via `append-to-history.sh`
7. Update ADR index (docs/ADR/README.md)

**ADR Updates**:
```markdown
## Status

accepted

## Decision Outcome

Chosen option: "**Option 3: [Name]**", because:
- Highest evaluation score (4.5/5)
- Best long-term maintainability and performance
- Strong community support ensures future viability
- Migration cost acceptable given 5+ year horizon

**Decision Date**: YYYY-MM-DD
**Approved By**: [Name/Role]

### Positive Consequences

* Improved performance (15-20% faster than current)
* Better maintainability (cleaner API, modern patterns)
* Strong community ensures long-term support
* Aligns with modern .NET best practices

### Negative Consequences

* Migration effort: 12-16 hours estimated
* Breaking changes for users (requires migration guide)
* Learning curve for team (2-3 days)
* Deprecates Option 2 (existing users impacted)

## Implementation Plan

1. Create feature branch
2. Implement Option 3 integration
3. Create migration guide (Option 2 → Option 3)
4. Update documentation
5. Add deprecation warnings to Option 2
6. Test thoroughly (unit + integration)
7. Merge to main branch

**Target Completion**: [Date]
```

**HISTORY.md Entry** (MANDATORY):
```bash
./scripts/append-to-history.sh \
  "Architecture: ADR #### [Decision Title] - Accepted" \
  "Decided on Option 3 ([Name]) after evaluating 4 alternatives. Evaluation matrix: Option 3 scored 4.5/5 (highest). Decision drivers: performance, maintainability, community support. Trade-offs: higher migration cost (12-16 hours) acceptable for long-term benefits. Implementation plan defined." \
  "Establish architectural direction for [problem area]. Ensure decision is well-researched (4 alternatives evaluated), documented (MADR 3.0.0 format), and justified (evaluation matrix with weighted scores). Provide clear implementation guidance." \
  "Architectural decision documented and approved. Implementation can proceed per plan. Migration guide required (breaking changes for users). Option 2 deprecated. Estimated 12-16 hour effort. Positive: +15-20% performance, better maintainability. Negative: migration effort, learning curve."
```

**Commit Message**: `docs: Accept ADR #### - [Decision Title] (Option 3 selected)`

---

### Stage 5: Implementation Phase → Status: `accepted` (implementation notes)

**When**: During implementation of the decision

**Actions**:
1. Add implementation notes section
2. Document deviations from original plan (if any)
3. Update if assumptions proven incorrect
4. Note unexpected challenges
5. **DO NOT change status** (remains `accepted`)

**ADR Updates**:
```markdown
## Implementation Notes

### Implementation Date Range
Started: YYYY-MM-DD
Completed: YYYY-MM-DD

### Actual Implementation

- Followed implementation plan with minor deviations
- Challenge 1: [Describe] - Resolved by [solution]
- Challenge 2: [Describe] - Resolved by [solution]
- Assumption X proven incorrect: [details]
- Actual effort: 14 hours (vs. 12-16 estimated) ✅

### Deviations from Plan

1. **Deviation**: [What changed]
   - **Reason**: [Why]
   - **Impact**: [Consequences]

2. **Deviation**: [What changed]
   - **Reason**: [Why]
   - **Impact**: [Consequences]

### Lessons Learned

- [Lesson 1]
- [Lesson 2]
```

**Commit Message**: `docs: Update ADR #### with implementation notes and lessons learned`

---

### Stage 6: Post-Implementation Review → Status: `accepted` (review complete)

**When**: 1-3 months after implementation, or after sufficient usage data

**Actions**:
1. Add post-implementation review section
2. Validate predictions (were positive/negative consequences accurate?)
3. Document actual outcomes
4. Measure against success criteria
5. Recommend any follow-up decisions
6. **Update HISTORY.md** with review findings

**ADR Updates**:
```markdown
## Post-Implementation Review

### Review Date
YYYY-MM-DD (3 months post-implementation)

### Predicted vs. Actual Outcomes

#### Performance
- **Predicted**: +15-20% improvement
- **Actual**: +18% improvement ✅
- **Conclusion**: Prediction accurate

#### Migration Effort
- **Predicted**: 12-16 hours
- **Actual**: 14 hours ✅
- **Conclusion**: Within estimates

#### Maintainability
- **Predicted**: Better maintainability
- **Actual**: Code complexity reduced 30%, bug rate down 40% ✅
- **Conclusion**: Exceeded expectations

### Success Criteria Assessment

| Criteria | Target | Actual | Status |
|----------|--------|--------|--------|
| Performance | +15% | +18% | ✅ PASS |
| Migration effort | <16 hours | 14 hours | ✅ PASS |
| Bug rate | -20% | -40% | ✅ EXCEEDED |
| Team satisfaction | >7/10 | 8.5/10 | ✅ PASS |

**Overall Assessment**: ✅ SUCCESSFUL

### Unexpected Benefits

- [Benefit 1 not predicted]
- [Benefit 2 not predicted]

### Unexpected Challenges

- [Challenge 1 not predicted]
- [Challenge 2 not predicted]

### Recommendations

- [Recommendation 1 for future similar decisions]
- [Recommendation 2]
- [Follow-up ADR needed? Describe]

### Would We Decide the Same Again?

**YES** / NO

Rationale: [Explanation]
```

**HISTORY.md Entry**:
```bash
./scripts/append-to-history.sh \
  "Architecture: ADR #### Post-Implementation Review - Success" \
  "Reviewed ADR #### ([Decision Title]) 3 months post-implementation. Outcomes: Performance +18% (predicted +15-20% ✅), migration effort 14h (predicted 12-16h ✅), bug rate -40% (predicted -20% ✅ EXCEEDED), team satisfaction 8.5/10 (target >7/10 ✅). All success criteria met or exceeded. Unexpected benefits: [list]. Unexpected challenges: [list]. Would decide same again: YES." \
  "Validate architectural decision outcomes and learn from implementation experience. Ensure predictions were accurate and decision was sound. Inform future similar decisions." \
  "ADR #### validated as successful decision. Predictions accurate. Exceeded expectations on maintainability. Lessons learned documented for future decisions. Follow-up: [any recommendations]."
```

**Commit Message**: `docs: Add ADR #### post-implementation review (successful, all criteria met)`

---

### Stage 7: Superseded/Deprecated → Status: `superseded` or `deprecated`

**When**: Decision is replaced by new approach or no longer recommended

**Actions**:
1. Update status to `superseded by ADR-YYYY` or `deprecated`
2. Document why decision changed
3. Link to replacement ADR (if superseded)
4. Add deprecation timeline
5. Create migration guide (if needed)

**ADR Updates**:
```markdown
## Status

superseded by [ADR-YYYY](ADR-YYYY-new-approach.md)

## Supersession Information

### Superseded Date
YYYY-MM-DD

### Reason for Supersession

Original decision (Option 3) worked well for 2 years but new requirements emerged:
- Requirement 1: [New need not addressed by Option 3]
- Requirement 2: [New need not addressed by Option 3]
- Technology evolution: [New Option 5 emerged with better capabilities]

### Replacement Decision

See [ADR-YYYY: New Approach for [Problem]](ADR-YYYY-new-approach.md) for replacement decision.

### Migration Timeline

- **Deprecation announced**: YYYY-MM-DD
- **Support ends**: YYYY-MM-DD (12 months)
- **Removal target**: YYYY-MM-DD (24 months)

### Migration Path

See [Migration Guide: Option 3 → New Approach](../migration/option3-to-new-approach.md)

## Historical Context

This ADR documents a decision that was **correct at the time** (2025-10-12) but has since been superseded due to:
- Changed requirements
- Technology evolution
- Better alternatives emerged

**Original decision rationale remains valid for historical context.**
```

**Commit Message**: `docs: Supersede ADR #### (replaced by ADR-YYYY - [new approach])`

---

## Mandatory Update Triggers

### MUST Update ADR When:

1. **New alternative discovered** during research
   - Add to "Considered Options"
   - Add pros/cons
   - Update evaluation matrix

2. **Evaluation criteria changes** (new constraint discovered)
   - Add to evaluation matrix
   - Re-score options if needed

3. **Decision made** (approved)
   - Change status to `accepted`
   - Document decision outcome
   - Log to HISTORY.md

4. **Implementation encounters challenges**
   - Add implementation notes
   - Document deviations
   - Update lessons learned

5. **Post-implementation review conducted**
   - Add review section
   - Validate predictions
   - Document actual outcomes

6. **Decision superseded or deprecated**
   - Change status
   - Link to replacement ADR
   - Add migration timeline

### SHOULD Update ADR When:

- Assumptions proven incorrect
- New research sources found
- Stakeholder feedback received
- Related ADRs created/updated
- Performance data collected

---

## Protocol Enforcement

### For Architect Agents

**Before making ANY architectural decision:**
1. Check if ADR exists for this decision area
2. If YES: Update existing ADR (don't create duplicate)
3. If NO: Create new ADR with status `proposed`

**During research:**
1. Update ADR incrementally as alternatives researched
2. Commit after each alternative added (granular history)

**When decision made:**
1. Update status to `accepted`
2. Log to HISTORY.md (MANDATORY)
3. Update ADR index

**During implementation:**
1. Add implementation notes to ADR
2. Document deviations and challenges

**Post-implementation (1-3 months):**
1. Conduct review
2. Update ADR with outcomes
3. Log review to HISTORY.md

### For Coder Agents

**Before implementing architectural change:**
1. Check for relevant ADR
2. If no ADR exists: Request architect agent create one
3. Implement per ADR guidance

**During implementation:**
1. Note deviations from ADR plan
2. Report challenges to architect agent for ADR update

**After implementation:**
1. Report actual effort vs. predicted
2. Provide feedback for post-implementation review

### For Migration Coordinator

**Planning phase:**
1. Ensure all major architectural decisions have ADRs
2. Create ADR stubs for decisions to be made

**Execution phase:**
1. Verify ADRs updated as decisions made
2. Enforce logging protocol

**Review phase:**
1. Schedule post-implementation reviews
2. Ensure ADRs updated with outcomes

---

## ADR Update Checklist

Before marking ADR work "complete", verify:

- [ ] Status accurately reflects current stage (proposed/accepted/rejected/deprecated/superseded)
- [ ] All alternatives researched are documented
- [ ] Evaluation matrix complete (if evaluation stage reached)
- [ ] Decision outcome documented (if decision made)
- [ ] Positive and negative consequences listed (if decision made)
- [ ] Implementation notes added (if implemented)
- [ ] Post-implementation review conducted (if >1 month since implementation)
- [ ] ADR index (docs/ADR/README.md) updated
- [ ] HISTORY.md updated (via append-to-history.sh) for major milestones
- [ ] Commit message describes what stage/update was made

---

## Examples: Full ADR Lifecycle

### Example 1: Quick Decision (1 Day)

**Day 1 Morning**: Problem identified
```bash
# Commit 1
git add docs/ADR/ADR 0042 quick-decision.md
git commit -m "docs: Create ADR-0042 for quick decision (status: proposed)"
```

**Day 1 Afternoon**: Research done, decision made
```bash
# Commit 2
git add docs/ADR/ADR 0042 quick-decision.md
git commit -m "docs: Complete ADR-0042 research and accept decision (Option 2 selected)"

# Log to HISTORY.md
./scripts/append-to-history.sh "Architecture: ADR-0042 Accepted" "..." "..." "..."
```

### Example 2: Complex Decision (2 Weeks + Implementation + Review)

**Week 1 Day 1**: Problem identified
```bash
git commit -m "docs: Create ADR-0043 for complex decision (status: proposed, research starting)"
```

**Week 1 Day 3**: Alternative 1-2 researched
```bash
git commit -m "docs: Update ADR-0043 with Options 1-2 research findings"
```

**Week 1 Day 5**: Alternative 3-4 researched
```bash
git commit -m "docs: Update ADR-0043 with Options 3-4 research findings"
```

**Week 2 Day 1**: Evaluation complete
```bash
git commit -m "docs: Complete ADR-0043 evaluation matrix (preliminary recommendation: Option 3)"
```

**Week 2 Day 3**: Decision approved
```bash
git commit -m "docs: Accept ADR-0043 (Option 3 selected after 4-option evaluation)"
./scripts/append-to-history.sh "Architecture: ADR-0043 Accepted" "..." "..." "..."
```

**Week 3-4**: Implementation
```bash
git commit -m "docs: Update ADR-0043 with implementation notes (challenges encountered)"
```

**3 Months Later**: Post-implementation review
```bash
git commit -m "docs: Add ADR-0043 post-implementation review (successful, all criteria met)"
./scripts/append-to-history.sh "Architecture: ADR-0043 Review - Success" "..." "..." "..."
```

---

## Benefits of Lifecycle-Aware ADRs

1. **Living Documentation**: ADRs evolve with decisions, not written once and forgotten
2. **Complete History**: See how decision evolved from research → decision → implementation → review
3. **Accountability**: Each update shows what was known when decision was made
4. **Learning**: Post-implementation reviews validate predictions and inform future decisions
5. **Transparency**: Incremental updates show research process and alternatives considered
6. **Auditability**: Git history + HISTORY.md provide complete decision audit trail
7. **Knowledge Transfer**: New team members understand decision rationale and outcomes
8. **Decision Quality**: Structured lifecycle prevents hasty decisions

---

## Integration with Existing Protocols

### Agent Logging Protocol
- **When**: ADR created, major updates, decision made, review complete
- **How**: Use Template 4 (Architectural Decision) in GENERIC-AGENT-LOGGING-PROTOCOL.md
- **Frequency**: Log ADR creation and acceptance; optionally log major research updates

### Testing Protocol
- **When**: Post-implementation review
- **How**: Include test results, bug rates, performance data in review
- **Metrics**: Use from GENERIC-TESTING-PROTOCOL.md

### Migration Planning
- **When**: Planning phase
- **How**: Create ADR stubs for decisions to be made during migration
- **Tracking**: ADRs track architectural decisions throughout migration stages

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2025-10-12 | Initial protocol defining 7-stage ADR lifecycle |

---

**This protocol ensures ADRs are living documents, not write-once artifacts.**
