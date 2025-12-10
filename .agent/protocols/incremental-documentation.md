---
name: incremental-documentation
description: Incremental documentation protocol for continuous updates throughout project lifecycle
---

# Incremental Documentation Protocol

**Version**: 2.0 (UPDATED per Retrospective Recommendation 5)
**Date**: 2025-11-09
**Purpose**: Document as you go with validation-based status markers, not aspirational claims
**Applicability**: All software projects, especially migrations

---

## Overview

This protocol prevents end-of-project documentation marathons by maintaining documentation incrementally throughout development **with verified status markers** to prevent aspirational claims.

**Core Principle**: Document while context is fresh, not retrospectively. Only claim "✅ Fixed" after validation, not before.

**Impact**: Reduces Stage 8 (Documentation) from 2-3 hours to 30-45 minutes (review + polish only).

**NEW**: Status markers reflect reality (validated) not intent (aspirational).

---

## The Problem This Solves

### Anti-Pattern: End-of-Project Documentation ❌

```
Day 1-3: Development (no documentation)
Day 4: CHANGELOG.md, MIGRATION-GUIDE.md, ADRs, README updates
       (3-4 hours of writing from memory + HISTORY.md review)
```

**Problems**:
- Time-consuming documentation sprint
- Details forgotten or missed
- Code examples reconstructed from memory
- Less accurate documentation
- Delays project completion

### Best Practice: Incremental Documentation ✅

```
Day 1: Core migrated → Update CHANGELOG.md (5 min)
Day 2: Operations → Add breaking change to MIGRATION-GUIDE.md (10 min)
Day 3: Deprecate package → Document alternative immediately (15 min)
Day 4: Review + polish all docs (30-45 min)
```

**Benefits**:
- Accurate (documented while fresh)
- Faster overall (distributed effort)
- Better examples (written while coding)
- No forgotten details
- Stage 8 becomes review, not creation

---

## Document Types and Update Triggers

### 1. CHANGELOG.md

**NEW: Status Marker System (per Recommendation 5)**

**Status Markers** (use these to reflect reality):
- `⚠️ In Progress` - Work started but NOT validated (tests not passing yet)
- `✅ Fixed (validated)` - Tests passing, confirmed working (ONLY use after validation)
- `📝 Documented` - Breaking change documented but migration code pending

**Update Triggers**:
- [ ] After migrating each major stage AND tests pass
- [ ] When adding/removing dependencies AND build succeeds
- [ ] When fixing breaking changes AND tests validate fix
- [ ] When deprecating features AND migration path documented

**CRITICAL**: Only mark "✅ Fixed" AFTER tests pass, not before. Aspirational claims erode trust.

#### Stage 2 (Core Library)

```bash
# Initialize CHANGELOG.md
cat > CHANGELOG.md << 'EOF'
# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [3.0.0] - Unreleased

### Breaking Changes

#### .NET Framework Migration
- ⚠️ In Progress: Migrating from `netstandard1.5`/`net451` to `net9.0` single-target
  - Status: 15/28 projects migrated
  - Build: Passing for migrated projects
  - Tests: Not yet validated (pending Stage 3)
- 📝 Documented: Minimum requirement will be .NET 9.0 SDK or later
- 📝 Documented: Will remove all .NET Framework 4.5.1 support

#### Dependency Updates
- ⚠️ In Progress: **RabbitMQ.Client**: `5.0.1` → `6.8.1`
  - Dependency updated in .csproj files
  - Code migration not started (60 files need updates)
  - **Breaking**: `BasicProperties` constructor now protected
  - **Breaking**: `Body` property changed from `byte[]` to `ReadOnlyMemory<byte>`
  - **Breaking**: `CreateConnection()` added `clientProvidedName` parameter

- ✅ Fixed (validated): **Newtonsoft.Json**: `10.0.1` → `13.0.3`
  - Updated: 2025-11-09 10:15
  - Tests: 156/156 passing (100%) ✅
  - Security: CVE-2018-11093 eliminated (verified via scan)

### Security

- ✅ Fixed (validated): CVE-2018-11093 in Newtonsoft.Json (HIGH severity)
  - Scan Date: 2025-11-09 10:20
  - Verified: `dotnet list package --vulnerable` shows zero occurrences
- ⚠️ In Progress: RabbitMQ.Client 5.0.1 CVEs (8+ HIGH/CRITICAL)
  - Dependency updated, code migration pending
  - Validation pending: Stage 3 completion
- 📝 Goal: Achieve 0 CRITICAL/HIGH CVEs (currently: 0 CRITICAL, 0 HIGH ✅)

### Added

- 📝 Planned: `BasicPropertiesHelper` utility class (implementation pending)
- ✅ Added (validated): Nullable reference types enabled (`<Nullable>enable</Nullable>`)
  - Validated: Build succeeds with nullability enabled
  - Tests: All passing with new annotations
- ✅ Added (validated): Modern C# language features (`LangVersion=latest`)
  - Validated: C# 12 features compile correctly

EOF

git add CHANGELOG.md
git commit -m "docs: Initialize CHANGELOG.md for v3.0.0"
```

#### After Each Stage

```bash
# Add stage entry
cat >> CHANGELOG.md << 'EOF'

### Stage N Complete: [Stage Name]
- Migrated [X] projects to net9.0
- Updated [Package]: [OldVer] → [NewVer]
- Fixed [key issue]
- Status: [X/Y] projects complete

EOF

git add CHANGELOG.md
git commit -m "docs: Update CHANGELOG.md - Stage N complete"
```

#### When Deprecating Packages

```bash
# Add deprecation notice immediately
cat >> CHANGELOG.md << 'EOF'

### Deprecated

#### RawRabbit.Enrichers.ZeroFormatter
- **Reason**: ZeroFormatter abandoned (last update 2017), no .NET Core 2.0+ support
- **Alternative**: Use `RawRabbit.Enrichers.MessagePack` (actively maintained, better performance)
- **Migration**: See [MIGRATION-GUIDE.md](MIGRATION-GUIDE.md#zeroformatter--messagepack)

EOF

git add CHANGELOG.md
git commit -m "docs: Document ZeroFormatter deprecation in CHANGELOG"
```

---

### 2. MIGRATION-GUIDE.md

**Update Triggers**:
- [ ] When encountering breaking API changes
- [ ] When creating workarounds for issues
- [ ] When deprecating packages
- [ ] After fixing migration-specific bugs

#### Initialize Early (Stage 2)

```bash
cat > MIGRATION-GUIDE.md << 'EOF'
# Migration Guide: RawRabbit 2.x → 3.0

This guide provides step-by-step instructions for migrating from RawRabbit 2.x to 3.0.

## Prerequisites

- .NET 9.0 SDK ([Download](https://dotnet.microsoft.com/download/dotnet/9.0))
- Visual Studio 2022 17.8+ or Rider 2024.1+ (for .NET 9.0 support)

## Breaking Changes

[Will be updated incrementally as encountered]

## Deprecated Packages

[Will be updated as packages deprecated]

## Step-by-Step Migration

[Will be expanded as stages progress]

EOF

git add MIGRATION-GUIDE.md
git commit -m "docs: Initialize MIGRATION-GUIDE.md"
```

#### When Fixing Breaking Change

**Immediately add code example**:

```bash
# Append to MIGRATION-GUIDE.md
cat >> MIGRATION-GUIDE.md << 'EOF'

### RabbitMQ.Client 6.x: BasicProperties Constructor

**Impact**: Cannot use `new BasicProperties()` - constructor is now protected

**Before (2.x)**:
```csharp
var properties = new BasicProperties
{
    ContentType = "application/json",
    DeliveryMode = 2
};
```

**After (3.0)**:
```csharp
var properties = BasicPropertiesHelper.CreateBasicProperties();
properties.ContentType = "application/json";
properties.DeliveryMode = 2;
```

**Or use configuration builders** (recommended):
```csharp
await client.PublishAsync(message, ctx => ctx
    .UsePublishConfiguration(cfg => cfg
        .WithProperties(props => props
            .WithContentType("application/json")
            .WithDeliveryMode(2))));
```

EOF

git add MIGRATION-GUIDE.md
git commit -m "docs: Add BasicProperties migration guide"
```

#### When Deprecating Package

```bash
# Add immediately after decision
cat >> MIGRATION-GUIDE.md << 'EOF'

## Deprecated Packages

### ZeroFormatter → MessagePack

**Reason**: ZeroFormatter abandoned (last update 2017), no .NET Core 2.0+ support

**Alternative**: MessagePack (actively maintained, better performance)

**Migration Steps**:

1. Uninstall ZeroFormatter:
   ```bash
   dotnet remove package RawRabbit.Enrichers.ZeroFormatter
   ```

2. Install MessagePack:
   ```bash
   dotnet add package RawRabbit.Enrichers.MessagePack
   ```

3. Update attributes:
   ```csharp
   // Before (ZeroFormatter):
   [ZeroFormattable]
   public class MyMessage
   {
       [Index(0)]
       public string Name { get; set; }
   }

   // After (MessagePack):
   [MessagePackObject]
   public class MyMessage
   {
       [Key(0)]
       public string Name { get; set; }
   }
   ```

4. Update plugin registration:
   ```csharp
   // Before:
   Plugins = p => p.UseZeroFormatter()

   // After:
   Plugins = p => p.UseMessagePack()
   ```

EOF

git add MIGRATION-GUIDE.md
git commit -m "docs: Add ZeroFormatter→MessagePack migration guide"
```

---

### 3. README.md

**Update Triggers**:
- [ ] When making major architectural changes
- [ ] When changing minimum requirements
- [ ] After migration completes
- [ ] When breaking public API

#### Update Requirements Section

```bash
# Add .NET 9.0 announcement early
# Edit README.md to add "What's New" section at top
```

```markdown
## ✨ What's New in 3.0

**RawRabbit 3.0** is now available with full **.NET 9.0 support**! This major release includes:

- ✅ **Modern .NET**: Migrated to .NET 9.0 with latest language features
- 🔒 **Security**: 0 CVEs - all dependencies updated to latest secure versions
- ⚡ **Performance**: RabbitMQ.Client 6.8.1 with improved connection handling
- 🛡️ **Resilience**: Polly 8.5.0 with modern ResiliencePipeline API
- 📦 **Updated Serialization**: MessagePack 2.5.187, Protobuf 3.2.30

**⚠️ Breaking Changes**: This is a major version with breaking changes. See [MIGRATION-GUIDE.md](MIGRATION-GUIDE.md) for upgrade instructions.

**📋 Requirements**: .NET 9.0 SDK or later
```

---

### 4. ADRs (Architecture Decision Records)

**Update Trigger**: BEFORE making architectural decisions (see ADR-LIFECYCLE-PROTOCOL.md)

#### Pre-Research ADR Creation

```bash
# BEFORE researching ZeroFormatter alternatives
cat > "docs/adr/ADR 0003 Serialization Enricher Strategy.md" << 'EOF'
# ADR 0003: Serialization Enricher Strategy

**Status**: proposed
**Date**: 2025-10-13
**Context**: ZeroFormatter package cannot build on net9.0

## Problem Statement

ZeroFormatter enricher is incompatible with .NET 9.0. Must decide on migration path.

## Alternatives to Research

1. **ZeroFormatter** - Current implementation
2. **MessagePack** - Modern alternative
3. **Protobuf** - Google Protocol Buffers

## Evaluation Criteria

- Compatibility with .NET 9.0
- Performance (serialization speed)
- Maintenance status (active development)
- Migration effort
- Breaking changes impact

## Research Log

[Will be updated incrementally]

## Decision

[Will be filled when decision made]

## Consequences

[Will be filled when decision made]
EOF

git add "docs/adr/ADR 0003 Serialization Enricher Strategy.md"
git commit -m "ADR-0003: Propose serialization enricher strategy (status: proposed)"
```

#### After Researching Each Alternative

```bash
# Research ZeroFormatter
vim "docs/adr/ADR 0003 Serialization Enricher Strategy.md"

# Add to Research Log:
# ### Alternative 1: ZeroFormatter
# - Pros: Current implementation, no migration needed
# - Cons: Abandoned (last update 2017), cannot build on .NET 9.0
# - Compatibility: ❌ Incompatible

git add "docs/adr/ADR 0003 Serialization Enricher Strategy.md"
git commit -m "ADR-0003: Researched ZeroFormatter (incompatible)"

# Research MessagePack
vim "docs/adr/ADR 0003 Serialization Enricher Strategy.md"

# Add to Research Log:
# ### Alternative 2: MessagePack
# - Pros: Actively maintained, excellent performance, .NET 9.0 compatible
# - Cons: Requires code changes (attribute migration)
# - Compatibility: ✅ Compatible

git add "docs/adr/ADR 0003 Serialization Enricher Strategy.md"
git commit -m "ADR-0003: Researched MessagePack (recommended)"
```

#### When Decision Made

```bash
# Update ADR with decision
vim "docs/adr/ADR 0003 Serialization Enricher Strategy.md"

# Change status: proposed → accepted
# Fill in Decision section
# Fill in Consequences section

git add "docs/adr/ADR 0003 Serialization Enricher Strategy.md"
git commit -m "ADR-0003: Accepted - Deprecate ZeroFormatter, migrate to MessagePack"

# Log to HISTORY.md
./scripts/append-to-history.sh \
  "ADR-0003 Accepted: ZeroFormatter Deprecation" \
  "Decided to deprecate ZeroFormatter enricher and recommend MessagePack as alternative" \
  "ZeroFormatter abandoned and incompatible with .NET 9.0" \
  "Users must migrate to MessagePack or Protobuf. Migration guide provided."
```

---

## Stage-by-Stage Incremental Documentation

### Stage 2: Core Library

```bash
# 1. Update CHANGELOG.md
# 2. Initialize MIGRATION-GUIDE.md
# 3. Update README.md (if major changes)

# Time: ~15 minutes
```

### Stage 3: Operations

```bash
# 1. Add Stage 3 entry to CHANGELOG.md
# 2. Document any breaking changes in MIGRATION-GUIDE.md

# Time: ~5-10 minutes
```

### Stage 4: Enrichers

```bash
# 1. Add Polly 8.x migration guide (code examples)
# 2. Document deprecated packages (ZeroFormatter, Ninject)
# 3. Create ADRs for deprecation decisions
# 4. Update CHANGELOG.md

# Time: ~20-30 minutes
```

### Stage 5: DI Adapters

```bash
# 1. Document Ninject deprecation
# 2. Add migration path to Microsoft DI or Autofac
# 3. Update CHANGELOG.md

# Time: ~10-15 minutes
```

### Stage 6: Samples

```bash
# 1. Document sample migrations
# 2. Update README examples if needed
# 3. Add to CHANGELOG.md

# Time: ~5-10 minutes
```

### Stage 7: Testing

```bash
# 1. Document test results
# 2. Add test pass rates to CHANGELOG.md

# Time: ~5 minutes
```

### Stage 8: Review & Polish

```bash
# 1. Review all documentation for completeness
# 2. Fix broken links
# 3. Improve code examples
# 4. Add table of contents
# 5. Final proofreading

# Time: ~30-45 minutes (DOWN from 2-3 hours!)
```

---

## Benefits

### 1. Accuracy

- Details fresh in memory
- Code examples copy-pasted from actual work
- No reconstructing from memory

### 2. Efficiency

- Distributed effort (5-30 min per stage)
- Stage 8 becomes review (not creation)
- Overall time savings: 1-2 hours

### 3. Quality

- More complete documentation
- Better code examples
- Fewer omissions

### 4. Lower Cognitive Load

- Small incremental updates
- Don't need to recall entire project
- Context switching minimized

---

## Automation Helpers

### Template: Stage Documentation Checklist

```bash
#!/bin/bash
# scripts/stage-doc-checklist.sh

STAGE_NUM=$1

echo "📝 Stage $STAGE_NUM Documentation Checklist:"
echo ""
echo "- [ ] Update CHANGELOG.md with stage summary"
echo "- [ ] Add breaking changes to MIGRATION-GUIDE.md (if any)"
echo "- [ ] Document deprecated packages (if any)"
echo "- [ ] Create/update ADRs (if architectural decisions)"
echo "- [ ] Update README.md (if major changes)"
echo "- [ ] Commit documentation updates"
echo ""
echo "Estimated time: 5-20 minutes"
```

---

## Best Practices

### ✅ Do's

- ✅ Document immediately after completing work
- ✅ Copy-paste actual code for examples
- ✅ Commit documentation separately from code
- ✅ Use clear commit messages: `docs: Add X to CHANGELOG`
- ✅ Keep it brief (can expand in Stage 8)

### ❌ Don'ts

- ❌ Don't defer documentation to "later"
- ❌ Don't reconstruct from memory days later
- ❌ Don't skip breaking change documentation
- ❌ Don't forget to update CHANGELOG.md
- ❌ Don't create documentation all at once at end

---

## Integration with Other Protocols

### With Parallel Execution

Each parallel agent can update documentation independently:

```markdown
Task("Migrate Project A", """
...
5. Update documentation:
   - Add entry to CHANGELOG.md
   - Document breaking changes (if any)
   - Commit documentation
""", "coder")
```

### With Continuous Testing

Document test results immediately:

```bash
# After tests pass
echo "- Tests: 100% pass rate (Stage $STAGE_NUM)" >> CHANGELOG.md
```

---

## Checklist

After EVERY stage:

- [ ] Update CHANGELOG.md (5 min)
- [ ] Add to MIGRATION-GUIDE.md (if breaking changes)
- [ ] Create/update ADRs (if decisions made)
- [ ] Update README.md (if major changes)
- [ ] Commit documentation updates
- [ ] Time spent: <30 minutes

Final review (Stage 8):

- [ ] Review all documentation
- [ ] Fix inconsistencies
- [ ] Improve examples
- [ ] Add TOC
- [ ] Final proofread
- [ ] Time spent: <45 minutes

---

**Protocol Version**: 1.0
**Last Updated**: 2025-10-13
**Status**: Production Ready
**Applicability**: All software projects

**Key Takeaway**: Document incrementally, not retrospectively. Stage 8 becomes review, not creation.
