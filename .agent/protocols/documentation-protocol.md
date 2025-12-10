---
name: documentation-protocol
description: Unified documentation protocol integrating HISTORY.md, ADRs, and inline documentation
---

# Comprehensive Documentation Protocol

**Version**: 1.0
**Date**: 2025-10-12
**Purpose**: Unified documentation requirements for all agents across entire project lifecycle
**Applicability**: All .NET projects, all agents, all development phases

---

## Overview

This protocol defines **comprehensive documentation requirements** for all work performed on .NET projects. Documentation is not an afterthought but an integral part of every development activity from problem identification through post-implementation review.

**Three Documentation Pillars:**
1. **HISTORY.md** - Chronological audit trail of all completed work
2. **ADRs (Architecture Decision Records)** - Living documents tracking architectural decisions
3. **Inline Documentation** - Code comments, README files, migration guides, API docs

---

## Part 1: HISTORY.md - Chronological Audit Trail

### Purpose

HISTORY.md provides a **complete chronological record** of all significant changes, migrations, and decisions. It serves as:
- Audit trail for compliance and governance
- Knowledge base for future maintainers
- Progress tracking for stakeholders
- Debug tool (trace issues to specific changes)
- Onboarding resource for new team members

### Protocol Reference

**Full Protocol**: `docs/agents/agents/GENERIC-AGENT-LOGGING-PROTOCOL.md`

### When to Log to HISTORY.md

**ALWAYS log after**:
- ✅ Completing a migration stage/phase
- ✅ Migrating project(s) to new framework
- ✅ Fixing security vulnerabilities
- ✅ Updating dependencies (major versions)
- ✅ Making architectural decisions (when status changed to `accepted`)
- ✅ Creating/modifying significant code features
- ✅ Completing build validations
- ✅ Running comprehensive test suites
- ✅ Resolving critical bugs
- ✅ Refactoring major components
- ✅ Conducting post-implementation reviews (ADR reviews)

**NEVER log for**:
- ❌ Reading files (research activities)
- ❌ Intermediate build attempts
- ❌ Work-in-progress changes
- ❌ Failed attempts (unless documenting decision to abort)
- ❌ Trivial changes (typos, formatting)

### How to Log

**Mandatory Script**: `./scripts/append-to-history.sh`

```bash
./scripts/append-to-history.sh \
  "STAGE_TITLE" \
  "WHAT_CHANGED" \
  "WHY_CHANGED" \
  "IMPACT"
```

**Parameters**:
1. **STAGE_TITLE** (required): Short, descriptive title
   - Format: "Stage N: Component - Action" or "Category: Specific Action"
   - Examples: "Stage 2: Core Library Migration", "Security: CVE-2024-XXXXX Fixed", "Architecture: ADR-0042 Accepted"

2. **WHAT_CHANGED** (required): Detailed description
   - Projects/files modified
   - Versions updated
   - Build status
   - Issues encountered/resolved
   - Specific technical details
   - Metrics (before/after, pass rates, performance)

3. **WHY_CHANGED** (required): Business/technical rationale
   - Purpose of the change
   - Problem being solved
   - Relationship to overall project goals
   - Requirements satisfied

4. **IMPACT** (required): Consequences
   - Projects affected
   - Breaking changes
   - Next steps enabled
   - Dependencies satisfied
   - Risk assessment
   - Quantitative results

### Templates

**See GENERIC-AGENT-LOGGING-PROTOCOL.md for 7 detailed templates**:
- Template 1: Stage/Phase Migration
- Template 2: Security Fix
- Template 3: Dependency Update
- Template 4: Architectural Decision (ADR accepted/reviewed)
- Template 5: Feature Implementation
- Template 6: Test Suite Completion
- Template 7: Documentation Creation

---

## Part 2: ADRs - Architecture Decision Records

### Purpose

ADRs are **living documents** that track architectural decisions throughout their entire lifecycle. They serve as:
- Historical record of why decisions were made
- Research documentation showing alternatives considered
- Implementation guidance for developers
- Post-implementation validation of predictions
- Learning resource for future similar decisions

### Protocol Reference

**Full Protocol**: `docs/agents/ADR-LIFECYCLE-PROTOCOL.md`

### ADR File Naming Convention (MANDATORY)

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

**✅ Correct Examples**:
- `ADR 0001 Target Framework NET9.md`
- `ADR 0002 RabbitMQ Client Upgrade.md`
- `ADR 0015 Dependency Injection Container Selection.md`

**❌ Incorrect Examples**:
- `0001-target-framework.md` ❌ No ADR prefix, uses dashes
- `ADR 0002 upgrade.md` ❌ Uses dashes instead of spaces
- `ADR0003Decision.md` ❌ No spaces

**Creating New ADR**:
```bash
# Get next ADR number
LAST_ADR=$(ls docs/adr/ADR\ *.md | tail -1 | sed 's/.*ADR //' | sed 's/ .*//')
NEXT_NUM=$(printf "%04d" $((10#$LAST_ADR + 1)))

# Create with correct naming
touch "docs/adr/ADR $NEXT_NUM Your Decision Title.md"
```

See `ADR-LIFECYCLE-PROTOCOL.md` for complete naming requirements.

---

### ADR Lifecycle (7 Stages)

#### Stage 1: Problem Identification → Status: `proposed`

**When**: As soon as architectural decision need identified

**Action**: Create initial ADR
```bash
# Create ADR file
touch docs/adr/ADR ####-decision-title.md

# Commit
git commit -m "docs: Create ADR #### for [decision] (status: proposed, research starting)"
```

**ADR Content**:
```markdown
# ADR ####: [Decision Title]

## Status
proposed

## Context and Problem Statement
[Clear description of architectural problem]

## Decision Drivers
* [Initial constraint/requirement 1]
* [Initial constraint/requirement 2]

## Considered Options
* [Option 1 - preliminary]
* [Option 2 - preliminary]
* [More to be researched]

## Decision Outcome
**NOT YET DECIDED** - Research in progress

## Notes
- Created: YYYY-MM-DD
- Next steps: Research alternatives
```

**Log to HISTORY.md**: Optional (can wait until decision accepted)

---

#### Stage 2: Research Phase → Status: `proposed` (incremental updates)

**When**: During active research of alternatives

**Action**: Update ADR after **each** alternative researched

**Frequency**: After researching each alternative (incremental commits)

**Commit Pattern**:
```bash
# After researching Option 1
git commit -m "docs: Update ADR #### with Option 1 research findings"

# After researching Option 2
git commit -m "docs: Update ADR #### with Option 2 research findings"

# After researching Option 3
git commit -m "docs: Update ADR #### with Option 3 research findings"
```

**ADR Updates**:
```markdown
## Considered Options
* Option 1: [Name with details]
* Option 2: [Name with details]
* Option 3: [Name with details]

## Pros and Cons of the Options

### Option 1: [Name]
[Research findings]
* Good, because [benefit A]
* Good, because [benefit B]
* Bad, because [limitation C]

### Option 2: [Name]
[Research findings]
* Good, because [benefit A]
* Bad, because [limitation B]

## Research Sources
* [Official docs URL]
* [GitHub repo - activity, issues]
* [Benchmarks]

## Evaluation Matrix (Work in Progress)
| Criteria | Weight | Option 1 | Option 2 | Option 3 |
|----------|--------|----------|----------|----------|
| Performance | High | 4/5 | ?/5 | ?/5 |
| Maintainability | High | 3/5 | 5/5 | ?/5 |
```

**Log to HISTORY.md**: Optional (major milestones only)

---

#### Stage 3: Evaluation Complete → Status: `proposed` (evaluation ready)

**When**: All alternatives researched, evaluation complete

**Action**: Complete evaluation matrix, add preliminary recommendation

**Commit**:
```bash
git commit -m "docs: Complete ADR #### evaluation matrix (preliminary recommendation: Option 3)"
```

**ADR Updates**:
```markdown
## Evaluation Matrix
| Criteria | Weight | Option 1 | Option 2 | Option 3 |
|----------|--------|----------|----------|----------|
| Performance | High | 4/5 | 4/5 | 5/5 |
| Maintainability | High | 3/5 | 5/5 | 4/5 |
| Cost | Medium | 5/5 | 3/5 | 3/5 |
| **Weighted Score** | | **4.0** | **4.2** | **4.3** |

## Preliminary Recommendation
Based on evaluation, **Option 3** appears most favorable (4.3/5 score).
**Decision pending final approval.**
```

**Log to HISTORY.md**: No (not yet decided)

---

#### Stage 4: Decision Made → Status: `accepted` or `rejected`

**When**: Final decision approved

**Action**: Update status, document decision, **LOG TO HISTORY.MD**

**Commit**:
```bash
git commit -m "docs: Accept ADR #### - [Decision Title] (Option 3 selected)"
```

**ADR Updates**:
```markdown
## Status
accepted

## Decision Outcome
Chosen option: "**Option 3: [Name]**", because:
- Highest evaluation score (4.3/5)
- [Specific rationale]

**Decision Date**: YYYY-MM-DD
**Approved By**: [Name/Role]

### Positive Consequences
* [Benefit 1]
* [Benefit 2]

### Negative Consequences
* [Trade-off 1]
* [Trade-off 2]

## Implementation Plan
1. [Step 1]
2. [Step 2]
```

**Log to HISTORY.md**: **MANDATORY**
```bash
./scripts/append-to-history.sh \
  "Architecture: ADR #### [Decision Title] - Accepted" \
  "Decided on Option 3 after evaluating 4 alternatives. Score: 4.3/5. Rationale: [details]." \
  "Establish architectural direction for [area]. Ensure well-researched decision." \
  "Decision documented and approved. Implementation can proceed. [Impact details]."
```

**Update ADR Index**: Add entry to `docs/adr/README.md`

---

#### Stage 5: Implementation Phase → Status: `accepted` (with notes)

**When**: During implementation

**Action**: Add implementation notes, document challenges

**Commit**:
```bash
git commit -m "docs: Update ADR #### with implementation notes (challenges and resolutions)"
```

**ADR Updates**:
```markdown
## Implementation Notes

### Implementation Date Range
Started: YYYY-MM-DD
Completed: YYYY-MM-DD

### Actual Implementation
- Followed plan with minor deviations
- Challenge 1: [Issue] - Resolved by [solution]
- Actual effort: 14 hours (vs. 12-16 estimated) ✅

### Deviations from Plan
1. **Deviation**: [What changed]
   - **Reason**: [Why]
   - **Impact**: [Consequences]

### Lessons Learned
- [Lesson 1]
- [Lesson 2]
```

**Log to HISTORY.md**: Optional (implementation already logged elsewhere)

---

#### Stage 6: Post-Implementation Review → Status: `accepted` (review complete)

**When**: **MANDATORY 1-3 months after implementation**

**Action**: Validate predictions, document actual outcomes, **LOG TO HISTORY.MD**

**Commit**:
```bash
git commit -m "docs: Add ADR #### post-implementation review (successful, criteria met)"
```

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

### Success Criteria Assessment
| Criteria | Target | Actual | Status |
|----------|--------|--------|--------|
| Performance | +15% | +18% | ✅ PASS |
| Effort | <16h | 14h | ✅ PASS |

**Overall**: ✅ SUCCESSFUL

### Would We Decide Same Again?
**YES** - Rationale: [Explanation]
```

**Log to HISTORY.md**: **MANDATORY**
```bash
./scripts/append-to-history.sh \
  "Architecture: ADR #### Post-Implementation Review - Success" \
  "Reviewed ADR #### 3 months post-implementation. All criteria met. Performance +18% (predicted +15-20% ✅). Effort 14h (predicted 12-16h ✅)." \
  "Validate architectural decision outcomes and learn from experience." \
  "Decision validated as successful. Predictions accurate. Lessons learned documented."
```

---

#### Stage 7: Superseded/Deprecated → Status: `superseded` or `deprecated`

**When**: Decision replaced or no longer recommended

**Action**: Update status, link to replacement

**Commit**:
```bash
git commit -m "docs: Supersede ADR #### (replaced by ADR-YYYY)"
```

**ADR Updates**:
```markdown
## Status
superseded by [ADR-YYYY](ADR-YYYY-new-approach.md)

## Supersession Information

### Superseded Date
YYYY-MM-DD

### Reason
[Why decision changed - new requirements, better alternatives, etc.]

### Replacement
See [ADR-YYYY](ADR-YYYY-new-approach.md)

### Migration Timeline
- Support ends: YYYY-MM-DD
- Removal target: YYYY-MM-DD
```

**Log to HISTORY.md**: Optional but recommended

---

### ADR Directory Structure

```
docs/
├── adr/
│   ├── README.md (index of all ADRs)
│   ├── ADR 0001 net8-single-target.md
│   ├── ADR 0002 security-remediation-strategy.md
│   ├── ADR 0003 rabbitmq-client-migration.md
│   └── ...
```

**NEVER** save ADRs to root directory - always `docs/adr/` or `docs/ADR/`

---

## Part 3: Inline Documentation

### Code Comments

**When to Comment**:
- Complex algorithms (explain the "why", not the "what")
- Non-obvious business logic
- Workarounds for known issues
- Performance optimizations
- Security-sensitive code
- Public APIs (XML documentation)

**When NOT to Comment**:
- Self-explanatory code (good naming is better)
- Obvious operations
- Redundant explanations

**Example - Good**:
```csharp
// RabbitMQ.Client 6.x requires IModel.CreateBasicProperties() instead of constructor
// This is a breaking change from 5.x that requires factory pattern
var properties = channel.CreateBasicProperties();
```

**Example - Bad**:
```csharp
// Create basic properties
var properties = channel.CreateBasicProperties();
```

### README Files

**Required README Locations**:
- Root: `README.md` (project overview, quick start)
- Each major directory: `README.md` or `index.md`
- `docs/`: Documentation index
- `docs/adr/`: ADR index
- `sample/`: Sample usage guide

**README Content**:
1. Purpose/overview
2. Getting started (installation, setup)
3. Usage examples
4. Configuration
5. Dependencies
6. Common issues/troubleshooting
7. Links to detailed docs

### Migration Guides

**When to Create**:
- Framework migrations (e.g., .NET Framework → .NET 8)
- Breaking API changes
- Dependency upgrades with breaking changes
- Deprecated feature replacements

**Location**: `docs/migration/` or `docs/guides/migration/`

**Content**:
1. Migration overview
2. Prerequisites
3. Breaking changes (with before/after examples)
4. Step-by-step migration instructions
5. Testing recommendations
6. Rollback plan
7. Common issues and solutions
8. FAQ

**Example Structure**:
```
docs/
├── migration/
│   ├── MIGRATION-GUIDE-v2.0-to-v2.1.md
│   ├── rabbitmq-client-5-to-6.md
│   └── newtonsoft-json-security-fix.md
```

### API Documentation

**XML Documentation (C#)**:
```csharp
/// <summary>
/// Publishes a message to RabbitMQ using the configured middleware pipeline.
/// </summary>
/// <typeparam name="TMessage">The type of message to publish</typeparam>
/// <param name="message">The message instance to publish</param>
/// <param name="configuration">Optional pipeline configuration</param>
/// <returns>A task representing the async publish operation</returns>
/// <exception cref="ArgumentNullException">Thrown when message is null</exception>
/// <exception cref="BrokerUnreachableException">Thrown when RabbitMQ is unavailable</exception>
public Task PublishAsync<TMessage>(
    TMessage message,
    Action<IPipeContext> configuration = null)
{
    // Implementation
}
```

**When Required**:
- All public APIs (classes, methods, properties)
- All protected members (for inheritance)
- Complex internal methods (for maintainability)

### CHANGELOG.md

**Purpose**: Release notes for users

**Location**: Root directory or `docs/`

**Format**: Keep a Changelog standard (https://keepachangelog.com/)

**Example**:
```markdown
# Changelog

## [2.1.0] - 2025-10-15

### Added
- .NET 8 support

### Changed
- Migrated from .NET Framework 4.5.1 to .NET 8 (BREAKING)
- Updated RabbitMQ.Client from 5.0.1 to 6.8.1 (BREAKING)

### Fixed
- CVE-2024-43485 in Newtonsoft.Json (security)

### Deprecated
- Ninject DI adapter (use Microsoft.DependencyInjection or Autofac)

## [2.0.0] - 2023-06-01
...
```

**Update When**:
- Preparing release
- After completing major features
- After fixing critical bugs
- After security patches

---

## Documentation Workflow by Agent Type

### Architect Agent

**Responsibilities**:
1. Create ADRs for all architectural decisions (mandatory)
2. Update ADRs throughout complete 7-stage lifecycle
3. Log ADR creation (optional) and acceptance (MANDATORY) to HISTORY.md
4. Conduct post-implementation reviews 1-3 months after implementation
5. Log post-implementation reviews to HISTORY.md (MANDATORY)
6. Maintain ADR index (docs/adr/README.md)
7. Create migration guides for architectural changes

**Protocols**:
- ADR-LIFECYCLE-PROTOCOL.md (primary)
- GENERIC-AGENT-LOGGING-PROTOCOL.md (Template 4)

---

### Coder Agent

**Responsibilities**:
1. Add XML documentation to all public APIs
2. Add code comments for complex logic
3. Update inline documentation when refactoring
4. Log completed work to HISTORY.md (stages, features, refactoring)
5. Report implementation challenges to architect for ADR updates
6. Create/update README files for new components

**Protocols**:
- GENERIC-AGENT-LOGGING-PROTOCOL.md (Templates 1, 3, 5)

---

### Tester Agent

**Responsibilities**:
1. Create test reports (docs/test/)
2. Document test failures with priority levels
3. Log test suite completion to HISTORY.md
4. Provide test results for ADR post-implementation reviews
5. Update test documentation when test infrastructure changes

**Protocols**:
- GENERIC-TESTING-PROTOCOL.md
- GENERIC-AGENT-LOGGING-PROTOCOL.md (Template 6)

---

### Security Agent

**Responsibilities**:
1. Create security assessment reports (docs/migration/ or docs/security/)
2. Log security fixes to HISTORY.md
3. Document vulnerability remediation
4. Create security advisories for users (SECURITY.md)
5. Update ADRs with security implications

**Protocols**:
- GENERIC-AGENT-LOGGING-PROTOCOL.md (Template 2)

---

### Documentation Agent

**Responsibilities**:
1. Create CHANGELOG.md
2. Create migration guides
3. Create user-facing documentation
4. Update README files
5. Compile documentation from all agents
6. Generate release notes
7. Log documentation creation to HISTORY.md

**Protocols**:
- GENERIC-DOCUMENTATION-PLAN-TEMPLATE.md
- GENERIC-AGENT-LOGGING-PROTOCOL.md (Template 7)

---

### Migration Coordinator

**Responsibilities**:
1. Ensure all agents follow documentation protocols
2. Enforce HISTORY.md logging for all completed work
3. Create ADR stubs for decisions to be made
4. Schedule post-implementation reviews for ADRs
5. Verify ADR index is up-to-date
6. Generate stage reports
7. Maintain overall documentation quality

**Protocols**:
- All protocols (enforcement role)

---

## Documentation Quality Gates

### Stage Completion Criteria

**Before marking stage COMPLETE**:
- [ ] All work logged to HISTORY.md via append-to-history.sh
- [ ] All architectural decisions have ADRs (status: accepted)
- [ ] All ADRs updated to current lifecycle stage
- [ ] ADR index (docs/adr/README.md) is current
- [ ] Code comments added for complex logic
- [ ] XML documentation added for public APIs
- [ ] README files updated for new/changed components
- [ ] Test reports generated (if testing phase)
- [ ] Security reports generated (if security phase)

### Release Criteria

**Before creating release**:
- [ ] CHANGELOG.md updated with all changes
- [ ] Migration guide created (if breaking changes)
- [ ] All ADRs in docs/adr/ have status accepted or rejected (no proposed)
- [ ] Post-implementation reviews completed for all ADRs >3 months old
- [ ] API documentation complete for all public APIs
- [ ] README files current and accurate
- [ ] HISTORY.md reflects all release work
- [ ] Sample applications documentation updated

---

## Documentation Metrics

Track documentation health:

| Metric | Target | Critical Threshold |
|--------|--------|--------------------|
| HISTORY.md entries per stage | 100% | 100% |
| ADRs for architectural decisions | 100% | 90% |
| ADRs with post-implementation reviews (>3mo) | 100% | 80% |
| Public API XML documentation | 100% | 95% |
| README files per major directory | 100% | 90% |
| Migration guides for breaking changes | 100% | 100% |

---

## Best Practices

### Do's ✅

1. **Write documentation as you work** (not after)
2. **Update ADRs incrementally** during research (commit after each alternative)
3. **Log to HISTORY.md immediately** after completing work
4. **Conduct post-implementation reviews** 1-3 months after implementation
5. **Use templates** from GENERIC-AGENT-LOGGING-PROTOCOL.md
6. **Commit documentation separately** from code (clear git history)
7. **Link related documents** (ADRs link to each other, HISTORY.md references ADRs)
8. **Be specific** with metrics, versions, dates, file names

### Don'ts ❌

1. **Don't defer documentation** until "later" (it never happens)
2. **Don't skip HISTORY.md logging** (mandatory for all completed work)
3. **Don't create ADRs after implementation** (create before/during research)
4. **Don't skip post-implementation reviews** (learning opportunity)
5. **Don't save ADRs to root directory** (always docs/adr/)
6. **Don't use vague descriptions** ("Updated some files", "Fixed stuff")
7. **Don't skip ADR status updates** (status must reflect current stage)
8. **Don't write documentation for yourself** (write for future maintainers)

---

## Integration with Development Workflow

### Planning Phase
1. **Coordinator**: Create ADR stubs for decisions to be made
2. **Architect**: Research alternatives, update ADRs incrementally
3. **All**: Review existing HISTORY.md to understand current state

### Execution Phase
1. **Architect**: Update ADR status to accepted when decisions made, log to HISTORY.md
2. **Coder**: Add inline documentation, log completed work to HISTORY.md
3. **Tester**: Generate test reports, log test results to HISTORY.md
4. **Security**: Generate security reports, log fixes to HISTORY.md

### Review Phase
1. **Architect**: Conduct ADR post-implementation reviews, log to HISTORY.md
2. **Documentation**: Compile CHANGELOG.md from HISTORY.md entries
3. **Documentation**: Create migration guides from breaking changes
4. **Coordinator**: Verify all documentation complete before release

### Maintenance Phase
1. **Architect**: Update ADRs to superseded when replaced
2. **All**: Update documentation when making changes
3. **Coordinator**: Schedule periodic ADR reviews (annual or biannual)

---

## Templates and Examples

### Complete Documentation Set for One Feature

```
Feature: New Caching Middleware

Documentation Created:
├── docs/adr/ADR 0021 caching-strategy.md (architectural decision)
├── docs/HISTORY.md (3 entries: decision accepted, implementation complete, review)
├── src/RawRabbit.Enrichers.Caching/README.md (usage guide)
├── src/RawRabbit.Enrichers.Caching/CachingMiddleware.cs (XML docs + comments)
├── docs/migration/add-caching-middleware.md (migration guide)
└── CHANGELOG.md (entry in [Unreleased] section)
```

**Timeline**:
1. Week 1: ADR created (proposed), research phase (4 commits with alternatives)
2. Week 2: Evaluation complete, decision made (ADR accepted, HISTORY.md logged)
3. Week 3-4: Implementation (ADR implementation notes added)
4. Month 1: Implementation complete (HISTORY.md logged)
5. Month 4: Post-implementation review (ADR reviewed, HISTORY.md logged)

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2025-10-12 | Initial comprehensive documentation protocol integrating ADR lifecycle |

---

## Related Protocols

- **ADR-LIFECYCLE-PROTOCOL.md** - Complete 7-stage ADR lifecycle (Part 2 of this protocol)
- **GENERIC-AGENT-LOGGING-PROTOCOL.md** - HISTORY.md logging requirements (Part 1 of this protocol)
- **GENERIC-TESTING-PROTOCOL.md** - Test documentation requirements
- **GENERIC-DOCUMENTATION-PLAN-TEMPLATE.md** - Documentation planning guide

---

**This protocol ensures comprehensive documentation at all levels: audit trail (HISTORY.md), architectural decisions (ADRs), and inline code documentation.**
