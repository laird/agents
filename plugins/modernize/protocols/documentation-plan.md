---
name: documentation-plan
description: Documentation strategy template for migrations with CHANGELOG, guides, and effort estimates
---

# Generic .NET Project Documentation Plan Template

**Version**: 1.0
**Purpose**: Universal documentation strategy template for .NET migrations and modernizations
**Applicability**: Any .NET project undergoing version migration or major refactoring

---

## Executive Summary

This template provides a comprehensive documentation strategy for .NET projects undergoing migration, modernization, or significant architectural changes.

**Documentation Goals**:
- Provide clear migration paths from [old version] to [new version]
- Document all breaking changes with code examples
- Record architectural decisions in ADRs
- Update all existing documentation for new framework
- Create comprehensive security documentation
- Ensure users can successfully upgrade with minimal friction

---

## Documentation Inventory (Customize for Your Project)

### Current Documentation Assessment

**Step 1: Inventory Existing Documentation**

```bash
# Find all documentation files
find docs/ -type f \( -name "*.md" -o -name "*.rst" -o -name "*.txt" \) | wc -l

# Categorize by type
find docs/ -name "*.md" | head -20
find docs/ -name "*.rst" | head -20
```

**Typical Structure**:
```
docs/
├── getting-started/      # Installation, quick start guides
├── tutorials/            # Step-by-step tutorials
├── api-reference/        # API documentation
├── architecture/         # Architecture documentation
├── deployment/           # Deployment guides
├── troubleshooting/      # Common issues and solutions
├── migration-guides/     # Version migration guides
└── release-notes/        # Release notes and changelogs
```

**Document Types**:
- **Markdown**: User-facing documentation (.md)
- **reStructuredText**: Sphinx documentation (.rst)
- **XML**: API documentation (triple-slash comments)
- **README**: Project overview and quick start

### Documentation Gaps Analysis

**Critical (Must Create)**:
- [ ] `CHANGELOG.md` - Complete changelog for [new version]
- [ ] `MIGRATION-GUIDE.md` - Step-by-step upgrade guide
- [ ] `docs/adr/` - Architecture Decision Records
- [ ] `docs/migration-guides/` - Specific migration guides for breaking changes
- [ ] `docs/security/SECURITY.md` - Security policy and vulnerability documentation
- [ ] Sample application README files

**Important (Should Update)**:
- [ ] `README.md` - Add new version notice, update requirements
- [ ] `docs/getting-started/installation.md` - Update for new framework requirements
- [ ] All code examples - Update for new framework patterns
- [ ] API documentation - Update for breaking changes
- [ ] Configuration guides - Update for new configuration systems

**Nice-to-Have**:
- [ ] Architecture diagrams (Mermaid.js in markdown)
- [ ] Performance comparison documentation
- [ ] Troubleshooting guide for migration issues
- [ ] FAQ for new version

---

## Documentation Creation Plan

### Phase 1: Critical Release Documentation (Priority 1)

#### 1.1 CHANGELOG.md

**Purpose**: Comprehensive changelog following [Keep a Changelog](https://keepachangelog.com/en/1.0.0/) format

**Template**:
```markdown
# Changelog

All notable changes to [Project Name] will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [X.Y.Z] - YYYY-MM-DD

### Added
- New feature 1
- New feature 2
- [Framework] support

### Changed
- **BREAKING**: Minimum framework requirement: [Old] → [New]
- **BREAKING**: API change description
- Updated dependency X from A.B to C.D

### Security
- Fixed CVE-YYYY-NNNNN (CVSS X.X): Description
- Fixed vulnerability in component X

### Deprecated
- Feature/API that will be removed in future

### Removed
- **BREAKING**: Removed deprecated feature X
- **BREAKING**: Removed support for [old framework]

### Fixed
- Bug fix 1
- Bug fix 2

### Performance
- Performance improvement description (X% faster)
- Memory optimization (X% less allocation)

## [Previous Versions]
See [RELEASENOTES.md](RELEASENOTES.md) for historical releases.
```

**Estimated Effort**: 4-6 hours
**Inputs**: All ADRs, migration notes, security fixes, test results

---

#### 1.2 MIGRATION-GUIDE.md

**Purpose**: Step-by-step guide for upgrading from previous version

**Template Structure**:
```markdown
# Migration Guide: [Project] v[Old] → v[New]

**Target Audience**: Developers upgrading existing [Project] applications
**Estimated Migration Time**: X-Y hours (small) to X-Y days (large)
**Complexity**: [Low/Moderate/High]

---

## Prerequisites

### System Requirements

**Before Migration**:
- [Old framework versions]

**After Migration**:
- [New framework versions]
- [New dependencies]
- [External service requirements]

### Migration Checklist

- [ ] Inventory all project packages
- [ ] Document current framework version
- [ ] Identify custom code that may be affected
- [ ] Review breaking changes list
- [ ] Document current test coverage
- [ ] Set up test environment
- [ ] Create rollback plan

---

## Step-by-Step Migration

### Step 1: Assess Current Setup

**Inventory Packages**:
```bash
dotnet list package
# Review output for affected packages
```

**Document Current Framework**:
```bash
grep "<TargetFramework>" **/*.csproj
```

---

### Step 2: Upgrade Framework

**Update Project Files**:
```xml
<!-- Before -->
<PropertyGroup>
  <TargetFramework>[old-tfm]</TargetFramework>
</PropertyGroup>

<!-- After -->
<PropertyGroup>
  <TargetFramework>[new-tfm]</TargetFramework>
</PropertyGroup>
```

---

### Step 3: Update Dependencies

**Update Core Packages**:
```bash
dotnet add package [PackageName] --version [X.Y.Z]
```

**Remove Deprecated Packages**:
```bash
dotnet remove package [DeprecatedPackage]
```

---

### Step 4: Address Breaking Changes

**Breaking Change 1: [Description]**

Before:
```csharp
// Old code
```

After:
```csharp
// New code
```

Migration steps:
1. [Step 1]
2. [Step 2]

---

### Step 5: Test Thoroughly

**Unit Tests**:
```bash
dotnet test --filter Category=Unit
```

**Integration Tests**:
```bash
dotnet test --filter Category=Integration
```

---

### Step 6: Deploy Gradually

**Recommended Deployment Strategy**:
1. Canary (10% traffic) - Monitor for 24 hours
2. Gradual rollout (50% traffic) - Monitor for 48 hours
3. Full deployment (100% traffic) - Monitor for 1 week

---

## Breaking Changes Reference

### 1. [Breaking Change Name]

**Description**: [What changed]

**Migration**:
- [Step-by-step migration instructions]

**Code Example**:
```csharp
// Before
[old code]

// After
[new code]
```

---

## Common Issues and Solutions

### Issue 1: [Problem Description]

**Symptom**: [Error message or behavior]

**Cause**: [Root cause]

**Solution**:
```csharp
// Solution code
```

---

## Validation Checklist

### Pre-Migration
- [ ] Current version documented
- [ ] All packages inventoried
- [ ] Test coverage measured
- [ ] Rollback plan documented

### During Migration
- [ ] Framework SDK installed
- [ ] Project files updated
- [ ] Packages updated
- [ ] Breaking changes addressed

### Post-Migration
- [ ] All tests passing
- [ ] Performance benchmarks acceptable
- [ ] Deployment successful
- [ ] Monitoring shows healthy metrics

---

**Last Updated**: YYYY-MM-DD
**Version**: [X.Y.Z]
```

**Estimated Effort**: 12-16 hours

---

#### 1.3 Architecture Decision Records (ADRs)

**Purpose**: Document all major architectural decisions

**ADR Template** (based on Michael Nygard's format):
```markdown
# ADR ####: [Title]

**Date**: YYYY-MM-DD
**Status**: [Proposed | Accepted | Deprecated | Superseded by ADR ####]
**Deciders**: [List of people involved]
**Context Tag**: [Migration | Security | Performance | API Design]

---

## Context

[Describe the context and problem. What forces are at play?]

## Decision

[Describe the decision and rationale.]

## Consequences

### Positive
- [Benefit 1]
- [Benefit 2]

### Negative
- [Drawback 1]
- [Drawback 2]

### Neutral
- [Neutral consequence 1]

## Alternatives Considered

### Alternative 1: [Name]
**Description**: [Brief description]
**Pros**: [List]
**Cons**: [List]
**Rejected because**: [Reason]

## References

- [Related documentation]
- [Related issues/PRs]
```

**Common ADR Topics**:
1. Migration strategy and phasing
2. Framework version selection (LTS vs STS)
3. Dependency update strategy
4. Breaking changes management
5. Security vulnerability resolution
6. Performance optimization approaches
7. Test strategy and quality gates
8. Documentation strategy
9. Version support matrix
10. Release process and packaging

**Estimated Effort per ADR**: 2-3 hours
**Recommended Total**: 10-20 ADRs for major migration

---

#### 1.4 Specific Migration Guides

**Purpose**: Detailed guides for complex breaking changes

**Common Topics**:
1. **Serialization Migration** (e.g., Newtonsoft.Json → System.Text.Json)
2. **Dependency Injection Migration** (e.g., framework changes)
3. **Configuration Migration** (e.g., web.config → appsettings.json)
4. **Authentication/Authorization Migration**
5. **Database Provider Migration** (e.g., EF Core version updates)
6. **Logging Migration** (e.g., new logging frameworks)

**Template**:
```markdown
# [Component] Migration Guide

## Overview

**Old**: [Old component/version]
**New**: [New component/version]
**Migration Complexity**: [Low/Medium/High]
**Estimated Effort**: [Hours/Days]

## Why Migrate

- Reason 1
- Reason 2
- Reason 3

## Pre-Migration Assessment

- [ ] Inventory current usage
- [ ] Identify custom extensions
- [ ] Review dependencies
- [ ] Plan backward compatibility approach

## Migration Steps

### Step 1: [Description]

Before:
```csharp
// Old code
```

After:
```csharp
// New code
```

### Step 2: [Description]

...

## Testing Strategy

1. Unit test migration
2. Integration test validation
3. Performance comparison

## Rollback Plan

[How to revert if needed]

## Common Pitfalls

1. **Pitfall 1**: [Description and solution]
2. **Pitfall 2**: [Description and solution]
```

**Estimated Effort per Guide**: 4-6 hours

---

#### 1.5 Security Documentation

**Purpose**: Document security improvements and vulnerability resolutions

**Template**:
```markdown
# Security Policy

## Supported Versions

| Version | Supported          | End of Life    |
| ------- | ------------------ | -------------- |
| X.Y.x   | ✅ Yes             | TBD            |
| X.Y-1.x | ✅ Maintenance     | YYYY-MM        |
| < X.Y-1 | ❌ No              | EOL            |

## Reporting a Vulnerability

Please report security vulnerabilities to [email/platform].

**Response Timeline**:
- Initial response: 48 hours
- Status update: Weekly
- Fix timeline: Based on severity (Critical: 7 days, High: 30 days)

## Resolved Vulnerabilities

### vX.Y.Z Security Fixes

#### CVE-YYYY-NNNNN (CVSS X.X - SEVERITY)
**Component**: [Component name]
**Vulnerability**: [Description]
**Resolution**: [How it was fixed]
**Status**: ✅ RESOLVED

## Security Best Practices

### Using [Project] Securely

1. [Best practice 1]
2. [Best practice 2]
3. [Best practice 3]

### Configuration

```csharp
// Secure configuration example
```

### Deployment

- Use HTTPS only
- Enable authentication
- Configure CORS properly
- Set appropriate timeouts
```

**Estimated Effort**: 3-4 hours

---

### Phase 2: User Documentation Updates (Priority 2)

#### 2.1 README.md Update

**Changes Required**:
1. Add prominent new version notice at top
2. Update "Requirements" section
3. Update installation instructions
4. Update code examples
5. Add security improvements section
6. Update badges (NuGet version, build status)
7. Add link to migration guide

**Effort**: 2-3 hours

---

#### 2.2 Getting Started Documentation

**Files to Update**:
- Installation guide
- Quick start guide
- Configuration guide
- First application tutorial

**Changes**:
1. Update framework prerequisites
2. Update package installation commands
3. Update configuration examples
4. Update code samples

**Effort**: 2-4 hours per guide

---

#### 2.3 Code Examples Update

**Scope**: All code examples in documentation

**Changes Required**:
1. Update to new framework patterns (async/await, modern C#)
2. Update using statements for new namespaces
3. Update API calls for breaking changes
4. Ensure all examples compile on new framework
5. Add error handling where appropriate

**Effort**: 15-30 minutes per example

---

#### 2.4 API Documentation (XML Comments)

**Scope**: All public APIs

**Changes Required**:
1. Add/update XML doc comments for new APIs
2. Add `<remarks>` for framework-specific behavior
3. Add `<example>` tags with modern patterns
4. Document breaking changes in comments
5. Add `<see cref>` links to ADRs for major changes

**Effort**: 8-12 hours for large projects

---

### Phase 3: Sample Applications (Priority 2-3)

#### 3.1 Sample README Files

**Template for Each Sample**:
```markdown
# [Project Name] Sample Application

## Purpose
[What this sample demonstrates]

## Prerequisites
- [Framework] SDK
- [External dependencies]

## Running the Sample

### Quick Start
```bash
dotnet run
```

### With Docker
```bash
docker-compose up
```

## Features Demonstrated
- [Feature 1]
- [Feature 2]
- [Feature 3]

## Code Walkthrough

### [Key Section 1]
[Explanation and code reference]

### [Key Section 2]
[Explanation and code reference]

## Configuration

```json
{
  "setting1": "value1",
  "setting2": "value2"
}
```

## Troubleshooting

### Issue 1
**Problem**: [Description]
**Solution**: [Fix]

## Next Steps
- [Related sample 1]
- [Documentation link 1]
```

**Effort**: 2-3 hours per sample

---

## Documentation Standards

### Markdown Standards

**Formatting**:
- Use GitHub-flavored markdown
- Maximum line length: 120 characters
- Include table of contents for documents >500 lines
- Use code fences with language tags
- Use proper heading hierarchy

**Code Examples**:
- All code must compile
- Include necessary `using` statements
- Show both sync and async versions (if applicable)
- Include error handling
- Use realistic variable names

**Links**:
- Use relative links for internal documentation
- Verify all links before committing
- Use descriptive link text

### Code Example Template

```csharp
// [Brief description of what this demonstrates]

using System;
using System.Threading.Tasks;
using [ProjectNamespace];

namespace [ProjectName].Examples
{
    public class ExampleClass
    {
        public async Task DemonstrateFeatureAsync()
        {
            // 1. Setup
            var client = new Client();

            try
            {
                // 2. Main operation
                var result = await client.PerformOperationAsync();

                // 3. Verify result
                Console.WriteLine($"Success: {result}");
            }
            catch (Exception ex)
            {
                // 4. Error handling
                Console.WriteLine($"Error: {ex.Message}");
                throw;
            }
        }
    }
}
```

---

## Documentation Validation Checklist

**For Each Document**:
- [ ] Frontmatter (title, date, version) included
- [ ] Table of contents for long documents
- [ ] All code examples compile
- [ ] All links verified
- [ ] Spelling checked
- [ ] Grammar checked
- [ ] Screenshots current (if applicable)
- [ ] Cross-references correct
- [ ] File saved in correct directory

---

## Effort Estimates by Priority

### Priority 1: Critical (Must-Have)
- CHANGELOG.md: 4-6 hours
- MIGRATION-GUIDE.md: 12-16 hours
- ADRs (10-20): 20-60 hours
- Specific migration guides (3-5): 12-30 hours
- Security documentation: 3-4 hours
- **Total**: 51-116 hours

### Priority 2: Important (Should-Have)
- README.md update: 2-3 hours
- Getting started docs: 6-12 hours
- Code examples update: 8-20 hours
- API documentation: 8-12 hours
- **Total**: 24-47 hours

### Priority 3: Nice-to-Have
- Sample READMEs: 4-9 hours
- Architecture diagrams: 5-10 hours
- Performance docs: 4-6 hours
- Troubleshooting guide: 4-6 hours
- **Total**: 17-31 hours

**Grand Total**: 92-194 hours (12-24 business days)

---

## Success Criteria

### Documentation Completeness
- [ ] CHANGELOG.md created
- [ ] MIGRATION-GUIDE.md created
- [ ] All ADRs created
- [ ] Migration guides created
- [ ] Security documentation created
- [ ] README.md updated
- [ ] All code examples compile
- [ ] API docs updated

### Quality Metrics
- [ ] All links valid
- [ ] All code examples compile
- [ ] Spelling/grammar checked
- [ ] Peer reviewed

### User Validation
- [ ] Migration guide tested
- [ ] Code examples tested
- [ ] Sample applications run

---

## Customization Guide

1. **Copy this template** to your project's docs folder
2. **Fill in project-specific details**:
   - Replace `[Project Name]` with your project name
   - Replace `[Old]` and `[New]` with actual versions
   - Add project-specific breaking changes
3. **Customize ADR topics** based on your architectural decisions
4. **Adjust effort estimates** based on project size
5. **Prioritize** based on your release timeline
6. **Create tracking issues** for each documentation task

---

**Template Version**: 1.0
**Last Updated**: 2025-10-10
**Maintained By**: Documentation Team
**Status**: Template - Customize for your project
**Applicability**: Universal - All .NET migrations and modernizations
