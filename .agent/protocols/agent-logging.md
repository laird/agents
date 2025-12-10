---
name: agent-logging
description: Agent logging protocol with HISTORY.md audit trail, 7 templates, and 4-parameter structure
---

# Generic Agent Logging Protocol

**Version**: 1.0
**Purpose**: Universal logging protocol for AI agents working on any .NET codebase
**Applicability**: All .NET migrations, modernizations, and significant code changes

---

## Why Logging is Required

The HISTORY.md file provides:

- **Audit Trail**: Complete record of all activities
- **Accountability**: Who did what, when, and why
- **Knowledge Transfer**: Future maintainers understand evolution
- **Debugging**: Trace issues to specific changes
- **Progress Tracking**: Visible project progress
- **Compliance**: Documentation for enterprise requirements

---

## Logging Requirements

### When to Log

**ALWAYS log after**:

- ✅ Completing a migration stage/phase
- ✅ Migrating project(s) to new .NET version
- ✅ Fixing security vulnerabilities
- ✅ Updating dependencies (major versions)
- ✅ Making architectural decisions
- ✅ Creating/modifying significant code features
- ✅ Completing build validations
- ✅ Running comprehensive test suites
- ✅ Resolving critical bugs
- ✅ Refactoring major components

**NEVER log for**:

- ❌ Reading files (research activities)
- ❌ Intermediate build attempts
- ❌ Work-in-progress changes
- ❌ Failed attempts (unless documenting decision to abort)
- ❌ Trivial changes (typos, formatting)

### How to Log

**Use the script**: `./scripts/append-to-history.sh`

**Script Usage**:

```bash
./scripts/append-to-history.sh \
  "STAGE_TITLE" \
  "WHAT_CHANGED" \
  "WHY_CHANGED" \
  "IMPACT"
```

**Parameters**:

1. **STAGE_TITLE** (required): Short, descriptive title
   - Format: "Stage N: Component - Action"
   - Examples:
     - "Stage 2: Core Library Migration"
     - "Security: CVE-2024-XXXXX Fixed"
     - "Dependency: Package.Name Updated"

2. **WHAT_CHANGED** (required): Detailed description of changes
   - Projects/files modified
   - Versions updated
   - Build status
   - Issues encountered/resolved
   - Specific technical details

3. **WHY_CHANGED** (required): Business/technical rationale
   - Purpose of the change
   - Problem being solved
   - Relationship to overall project goals
   - Requirements satisfied

4. **IMPACT** (required): Consequences on codebase
   - Projects affected
   - Breaking changes
   - Next steps enabled
   - Dependencies satisfied
   - Risk assessment

---

## Logging Templates

### Template 1: Stage/Phase Migration

```bash
./scripts/append-to-history.sh \
  "Stage N: [Component] Migration" \
  "Migrated [X] projects ([list names]) from [old target] to [new target]. Updated to version [X.Y.Z]. Build status: [X/Y successful]. [Summarize issues/warnings]. [List specific files/classes changed]." \
  "Complete [Stage Name] to [purpose/goal]. [Component] enables [capability/feature]. Required by [dependent stages/components]." \
  "[X] projects now target [framework]. Breaking changes: [list or 'none']. Build warnings: [count]. Tests: [pass rate]. Ready for [next stage]."
```

**Example**:

```bash
./scripts/append-to-history.sh \
  "Stage 3: Data Access Layer Migration" \
  "Migrated 8 projects (DataAccess.Core, DataAccess.SqlServer, DataAccess.Postgres, Repositories.*) from netstandard2.0 to net8.0. Updated Entity Framework Core from 3.1 to 8.0. Build status: 8/8 successful with 3 warnings. Updated DbContext configurations for EF8 conventions." \
  "Complete Data Access Layer migration to support modern .NET features. Required for API layer migration in Stage 4. EF Core 8 provides better performance and nullability support." \
  "8 projects now target net8.0. Breaking changes: EF Core 8 nullability enforcement, removed obsolete methods. Build warnings: 3 (nullable reference types). Tests: 100% pass. Ready for Stage 4 (API Layer)."
```

---

### Template 2: Security Fix

```bash
./scripts/append-to-history.sh \
  "Security: [Vulnerability ID] Fixed" \
  "Fixed [CVE/VULN-NNN]: [vulnerability name]. [Specific action taken: version upgrade, code change, configuration]. Affected packages: [list]. Security score: [before]→[after]/100." \
  "Address [severity] security vulnerability in [component]. [Risk description]. Required before [milestone/release]." \
  "Vulnerability resolved. Security score improved from [X] to [Y]. [Component] now secure. [Impact on project timeline/deployment]."
```

**Example**:

```bash
./scripts/append-to-history.sh \
  "Security: CVE-2024-12345 Fixed" \
  "Fixed CVE-2024-12345: SQL injection vulnerability in query builder. Upgraded Dapper from 2.0.0 to 2.1.28. Parameterized all dynamic SQL queries in OrderRepository, CustomerRepository. Security score: 65→85/100." \
  "Address CRITICAL security vulnerability allowing SQL injection through user-supplied filters. Required before production deployment." \
  "SQL injection vulnerability eliminated. Security score improved 65→85/100. All repositories now use parameterized queries. Production deployment unblocked."
```

---

### Template 3: Dependency Update

```bash
./scripts/append-to-history.sh \
  "Dependency: [Package] Updated" \
  "Updated [PackageName] from [old version] to [new version]. Affected projects: [list]. Breaking changes addressed: [list]. Build status: [success/issues]. [Migration steps taken]." \
  "Upgrade [package] for [reason: security/compatibility/features/EOL]. Enables [capability]. Required by [dependent component]." \
  "[N] projects updated. Breaking changes: [list or 'none']. Compatible with [framework]. [Performance impact]. [Next steps]."
```

**Example**:

```bash
./scripts/append-to-history.sh \
  "Dependency: Newtonsoft.Json Replaced" \
  "Replaced Newtonsoft.Json 13.0.1 with System.Text.Json 9.0.0 across 15 projects. Updated all [JsonProperty] to [JsonPropertyName], migrated 12 custom converters to System.Text.Json API. Build status: 15/15 successful, 0 warnings. Performance testing shows 2-3x improvement in serialization." \
  "Migrate to System.Text.Json for better modern .NET integration, 2-3x performance improvement, reduced dependencies. Required for native AOT support planned in Stage 7." \
  "15 projects updated. Breaking changes: Attribute API differences, converter API changes. All JSON operations 2-3x faster. Memory allocation reduced 40%. Compatible with net8.0. AOT-ready."
```

---

### Template 4: Architectural Decision

```bash
./scripts/append-to-history.sh \
  "Architecture: [Decision] Implemented" \
  "Implemented [architectural pattern/decision]. [Specific changes made]. Created [new components/modules]. Modified [existing components]. [Technical details]." \
  "Adopt [pattern/approach] to [solve problem/improve quality]. [Benefits]. Aligns with [architectural goals]. See ADR #### for detailed rationale." \
  "Architecture improved: [benefits]. New capabilities: [list]. Technical debt: [reduced/increased]. Maintainability: [impact]. Performance: [impact]."
```

**Example**:

```bash
./scripts/append-to-history.sh \
  "Architecture: CQRS Pattern Implemented" \
  "Implemented CQRS pattern in OrderManagement module. Created separate read/write models (OrderCommand, OrderQuery), implemented MediatR handlers (12 commands, 8 queries). Separated OrderRepository into OrderCommandRepository and OrderQueryRepository. Added event sourcing infrastructure." \
  "Adopt CQRS to separate read/write concerns, enable independent scaling, support event sourcing. Improves testability and performance. See ADR-0042 for detailed rationale and alternatives considered." \
  "Architecture improved: read/write separation enables horizontal scaling. Query performance improved 5x (materialized views). Command validation centralized. Technical debt reduced: cleaner separation of concerns. Maintainability: easier to test and extend."
```

---

### Template 5: Feature Implementation

```bash
./scripts/append-to-history.sh \
  "Feature: [Feature Name] Implemented" \
  "Implemented [feature name]: [description]. Created [classes/components]. Added [X] tests ([unit/integration]). Updated documentation: [list]. [Technical implementation details]." \
  "Deliver [feature] to [meet requirement/user need]. [Business value]. Requested by [stakeholder]. [Priority/timeline]." \
  "Feature complete and tested ([X]% coverage). Documentation updated. [Performance characteristics]. Ready for [QA/production]. [Known limitations]."
```

---

### Template 6: Test Suite Completion

```bash
./scripts/append-to-history.sh \
  "Testing: [Test Suite] Completed" \
  "Executed [test suite name]. Total tests: [X]. Passed: [Y] ([Z]%). Failed: [N]. Fixed [M] issues: [brief list]. Re-tested and validated. Final pass rate: [%]." \
  "Validate [component/stage] quality and correctness. Ensure no regressions from [changes]. Meet [quality gate/requirement]." \
  "Test suite: [X]% pass rate. Quality gate: [met/not met]. [P0/P1 issues remaining]. [Component] ready for [next stage/deployment]."
```

---

### Template 7: Documentation Creation

```bash
./scripts/append-to-history.sh \
  "Documentation: [What] Created/Updated" \
  "Created/Updated [document names]. Content: [brief description]. Scope: [what's covered]. [Page count/effort]. [Format: markdown/wiki/etc]." \
  "[Purpose of documentation]. Provides [value] for [audience]. Required by [policy/stakeholder]." \
  "Documentation complete. [Benefits]. No code changes. [Next documentation tasks]."
```

---

## Agent Responsibilities

### Before Starting Work

1. Review previous HISTORY.md entries
2. Understand logging format and expectations
3. Plan what will be logged at completion
4. Note starting state for before/after comparison

### During Work

1. Track all changes being made
2. Note build results, warnings, errors
3. Document issues encountered and resolutions
4. Keep running notes for logging parameters

### After Completing Work

1. **IMMEDIATELY** log to HISTORY.md using script
2. Include all 4 required parameters (detailed)
3. Verify entry was added successfully
4. Report logging completion in final summary

---

## Logging Checklist for Agents

Before reporting "COMPLETE":

- [ ] Work is fully finished (not partial)
- [ ] All builds successful (or failures documented)
- [ ] Tests run (if applicable)
- [ ] **HISTORY.md entry created via append-to-history.sh**
- [ ] Entry includes all 4 required sections (title, what, why, impact)
- [ ] Entry is specific and detailed (not vague)
- [ ] Technical details included (versions, file names, counts)
- [ ] Metrics included (before/after, pass rates, performance)
- [ ] Timestamp is automatic (don't worry about it)
- [ ] Verification: Entry appears in HISTORY.md

---

## Common Mistakes to Avoid

❌ **DON'T**:

- Use vague descriptions ("Updated some files", "Fixed stuff")
- Skip logging because "it's small"
- Manually edit HISTORY.md (use script)
- Forget to log before reporting completion
- Omit metrics and specific details
- Log before work is actually complete
- Use generic package names without versions

✅ **DO**:

- Log completed stages/milestones
- Include specific project/file names and versions
- Mention build status, warning counts, error counts
- Document breaking changes explicitly
- Note test pass rates and coverage
- Include performance metrics (if applicable)
- Note next steps/dependencies
- Use the append-to-history.sh script
- Verify entry was added successfully

---

## Verification

### Agent Self-Check

After logging, verify:

```bash
# Check last entry
tail -20 docs/HISTORY.md

# Verify timestamp format
# Should show: YYYY-MM-DD HH:MM:SS - Title
```

### Coordinator Check

Project coordinator verifies:

- All stages logged
- Entries are complete and accurate
- Timeline is visible
- Audit trail is clear
- Metrics are included

---

## Script Location

**Path**: `./scripts/append-to-history.sh`

**Features**:

- Automatic timestamp (YYYY-MM-DD HH:MM:SS)
- Structured format
- Validation of parameters
- Consistent formatting
- Creates HISTORY.md if missing

**Execution**:

```bash
# From project root
./scripts/append-to-history.sh "Title" "What" "Why" "Impact"

# Result: Entry appended to docs/HISTORY.md with timestamp
```

**Script Template** (create if missing):

```bash
#!/bin/bash
# append-to-history.sh - Universal history logging for .NET projects

HISTORY_FILE="docs/HISTORY.md"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# Create HISTORY.md if it doesn't exist
if [ ! -f "$HISTORY_FILE" ]; then
    mkdir -p docs
    echo "# Project History" > "$HISTORY_FILE"
    echo "" >> "$HISTORY_FILE"
    echo "This file tracks all significant changes, migrations, and decisions." >> "$HISTORY_FILE"
    echo "" >> "$HISTORY_FILE"
fi

# Validate parameters
if [ $# -ne 4 ]; then
    echo "Error: Requires exactly 4 parameters"
    echo "Usage: $0 \"TITLE\" \"WHAT_CHANGED\" \"WHY_CHANGED\" \"IMPACT\""
    exit 1
fi

# Append entry
cat >> "$HISTORY_FILE" << EOF

---

## $TIMESTAMP - $1

**What Changed**: $2

**Why Changed**: $3

**Impact**: $4

EOF

echo "✅ Entry added to $HISTORY_FILE"
```

---

## Enforcement

**This is MANDATORY, not optional.**

### Success Criteria

All agents MUST log to HISTORY.md as their **final step** before reporting completion.

### Consequences of Non-Compliance

- Work considered incomplete
- Agent must return and log properly
- Blocking issue for stage progression
- Cannot proceed to next stage/task

### Coordinator Responsibility

Project coordinator verifies all logs are present, accurate, and detailed.

---

## Benefits of Proper Logging

1. **Traceability**: Every change has a record
2. **Transparency**: Stakeholders see progress
3. **Debugging**: Issues traceable to specific changes
4. **Knowledge Base**: Historical decisions documented
5. **Audit Compliance**: Complete change history for enterprise
6. **Team Coordination**: Agents know what others did
7. **User Confidence**: Visible, documented progress
8. **Onboarding**: New team members understand project history
9. **Post-Mortems**: Learn from past decisions
10. **Compliance**: Meet regulatory documentation requirements

---

## Customization for Your Project

### Required Setup

1. **Create logging script**:

   ```bash
   cp docs/agents/GENERIC-AGENT-LOGGING-PROTOCOL.md docs/agents/AGENT-LOGGING-PROTOCOL.md
   # Customize for your project
   ```

2. **Create HISTORY.md**:

   ```bash
   mkdir -p docs
   cat > docs/HISTORY.md << 'EOF'
   # [Your Project Name] History

   This file tracks all significant changes, migrations, and decisions for [Your Project].

   ## Logging Convention

   All entries are added via `./scripts/append-to-history.sh` and include:
   - Timestamp (automatic)
   - What changed (detailed)
   - Why it changed (rationale)
   - Impact on project (consequences)

   EOF
   ```

3. **Configure agents**:
   - Add to CLAUDE.md: "use the append-to-history.sh tool to record activity"
   - Add to agent instructions: "MANDATORY: Log all completed work"
   - Reference this protocol in agent spawn instructions

4. **Integrate with CI/CD**:
   - Optionally verify HISTORY.md updated in PRs
   - Generate release notes from HISTORY.md
   - Track project velocity from log entries

---

**Document Version**: 1.0 (Generic)
**Last Updated**: 2025-10-10
**Maintained By**: Project Coordinator / Technical Lead
**Status**: ACTIVE - Template for any .NET project
**Applicability**: Universal - All .NET migrations and modernizations
