---
name: modernize-assess
description: Assess a project for modernization readiness and viability, evaluating technical debt, risks, and ROI to determine if modernization is recommended
---

# Project Modernization Assessment Protocol

**Version**: 1.0
**Purpose**: Systematically assess whether a project is a good candidate for modernization
**Output**: `assessment.md` with comprehensive analysis and recommendation
**Duration**: 2-4 hours

**Note**: Time estimates are based on typical human execution times and may vary significantly based on project complexity, team experience, and AI assistance capabilities.

---

## Overview

This protocol evaluates a software project across **8 critical dimensions** to determine:
- ✅ Is modernization **technically feasible**?
- ✅ Is modernization **financially worthwhile**?
- ✅ What are the **major risks and blockers**?
- ✅ What is the **recommended approach**?
- ✅ Should we proceed, defer, or abandon the modernization?

**Core Principle**: **Assess before you commit - not all projects should be modernized.**

---

## Assessment Dimensions

### 1. Technical Viability (0-100 score)
### 2. Business Value (0-100 score)
### 3. Risk Profile (LOW/MEDIUM/HIGH/CRITICAL)
### 4. Resource Requirements (estimated effort)
### 5. Dependencies & Ecosystem Health
### 6. Code Quality & Architecture
### 7. Test Coverage & Stability
### 8. Security Posture

---

## Assessment Process

### Step 1: Project Discovery (30 minutes)

**Gather Basic Information**:
- [ ] Project name, version, and purpose
- [ ] Primary programming language(s) and framework(s)
- [ ] Current framework versions
- [ ] Target framework versions (if known)
- [ ] Age of project (initial commit date)
- [ ] Last significant update
- [ ] Active development status
- [ ] Number of contributors
- [ ] Lines of code
- [ ] Number of dependencies

**Commands**:
```bash
# Project stats
find . -name "*.cs" -o -name "*.js" -o -name "*.py" -o -name "*.java" | xargs wc -l
git log --reverse --format="%ai" | head -1  # First commit
git log --format="%ai" | head -1            # Last commit
git shortlog -sn                            # Contributors

# Dependency analysis
# .NET: dotnet list package --outdated
# Node: npm outdated
# Python: pip list --outdated
```

---

### Step 2: Technical Viability Assessment (45 minutes)

#### 2.1 Framework Analysis

**Current Framework Status**:
- [ ] Is current framework still supported?
- [ ] End-of-life date for current version
- [ ] Security patches still available?
- [ ] Community support level (active/declining/dead)

**Target Framework Status**:
- [ ] Latest stable version available?
- [ ] Migration path documented?
- [ ] Breaking changes documented?
- [ ] Tool support available?

**Scoring Criteria**:
- **80-100**: Clear migration path, well-documented, active community
- **60-79**: Migration path exists, some documentation gaps
- **40-59**: Difficult migration, limited documentation
- **0-39**: No clear path, framework deprecated, or major architectural change required

#### 2.2 Dependency Health

**Analyze All Dependencies**:
```bash
# Count total dependencies
# Check for:
- Deprecated packages (score -= 10 per deprecated)
- Unmaintained packages (no updates >2 years, score -= 5)
- Packages with security vulnerabilities (score -= 20 per CRITICAL)
- Compatible versions available (score += 10 if yes)
```

**Red Flags** (automatic FAIL):
- ❌ Critical dependency with no maintained alternative
- ❌ 50%+ of dependencies unmaintained
- ❌ Core framework dependency incompatible with target

**Scoring**:
- **80-100**: All dependencies maintained, clear upgrade path
- **60-79**: Most dependencies healthy, few alternatives needed
- **40-59**: Many dependencies need replacement
- **0-39**: Dependency hell, extensive rewrites required

#### 2.3 Code Compatibility

**Breaking Changes Analysis**:
- [ ] Enumerate breaking changes between current → target
- [ ] Estimate affected code percentage
- [ ] Identify obsolete APIs in use
- [ ] Check for deprecated patterns

**Complexity Factors**:
- Using reflection heavily (+complexity)
- Platform-specific code (+complexity)
- Custom serialization (+complexity)
- Heavy use of deprecated APIs (+complexity)

**Scoring**:
- **80-100**: <10% code affected, automated migration possible
- **60-79**: 10-30% affected, mostly straightforward changes
- **40-59**: 30-60% affected, significant manual work
- **0-39**: >60% affected, near-rewrite required

---

### Step 3: Business Value Assessment (30 minutes)

#### 3.1 Strategic Alignment

**Questions**:
- [ ] Is this project critical to business operations?
- [ ] Is this project actively developed/maintained?
- [ ] Are there plans for new features?
- [ ] Does current tech stack limit business capabilities?
- [ ] Is recruiting difficult for current tech stack?

**Scoring**:
- **80-100**: Critical system, active development, strategic importance
- **60-79**: Important system, moderate development
- **40-59**: Peripheral system, maintenance mode
- **0-39**: Legacy system, sunset planned

#### 3.2 Effort-Benefit Analysis

**Modernization Effort** (estimated timeline):
- Assessment & Planning: X days
- Security Remediation: Y days
- Framework Migration: Z days
- Testing & Validation: W days
- Documentation: V days
- **Total Effort**: XX days

**Benefits** (expected improvements):
- Security: Reduced vulnerability risk, compliance improvements
- Performance: Improved response times, reduced resource usage
- Developer productivity: Faster feature development, better tooling
- Maintenance: Reduced legacy issues, better long-term support
- Recruitment: Easier hiring with modern technology stack

**Value Assessment**:
- High value if effort investment provides substantial long-term benefits
- Consider strategic alignment and business criticality
- Factor in risk of continuing with outdated technology

**Scoring**:
- **80-100**: Significant benefits, manageable effort, clear value
- **60-79**: Good benefits justify moderate effort investment
- **40-59**: Limited benefits relative to effort required
- **0-39**: Benefits don't justify the effort investment

---

### Step 4: Risk Assessment (30 minutes)

#### 4.1 Technical Risks

**Identify and Rate Risks**:

| Risk | Likelihood | Impact | Severity | Mitigation |
|------|------------|--------|----------|------------|
| Breaking changes break critical features | High | High | CRITICAL | Comprehensive testing |
| Dependency conflicts unresolvable | Medium | High | HIGH | Dependency analysis upfront |
| Performance regression | Low | Medium | MEDIUM | Baseline + benchmark |
| Team lacks expertise | High | Medium | HIGH | Training + consultants |
| Timeline overruns | Medium | Medium | MEDIUM | Phased approach |

**Risk Levels**:
- **CRITICAL**: >3 CRITICAL risks → **DEFER** modernization
- **HIGH**: >5 HIGH risks → Requires mitigation plan
- **MEDIUM**: Manageable with standard practices
- **LOW**: Minimal risk

#### 4.2 Business Risks

- [ ] Business disruption during migration
- [ ] Data loss or corruption risk
- [ ] Customer impact (downtime, features unavailable)
- [ ] Competitive disadvantage if delayed
- [ ] Opportunity cost (alternatives)

**Overall Risk Profile**:
- **LOW**: <2 HIGH risks, 0 CRITICAL, clear mitigations
- **MEDIUM**: 2-5 HIGH risks, good mitigations
- **HIGH**: >5 HIGH risks or 1-2 CRITICAL risks
- **CRITICAL**: >2 CRITICAL risks → **DO NOT PROCEED**

---

### Step 5: Resource Assessment (20 minutes)

#### 5.1 Team Capacity

**Current Team**:
- Number of developers: X
- Framework expertise level: Beginner/Intermediate/Expert
- Availability: X% (accounting for ongoing work)
- Training needs: X days

**Required Skills**:
- [ ] Target framework expertise
- [ ] Migration tooling knowledge
- [ ] Testing framework familiarity
- [ ] DevOps/deployment skills

**Gap Analysis**:
- Skills we have: [list]
- Skills we need: [list]
- Training required: X days
- Contractor/consultant needs: Y days

#### 5.2 Timeline Estimation

**Conservative Estimate** (based on project size):

| Project Size | Discovery | Security | Framework | API/Code | Testing | Docs | Total |
|--------------|-----------|----------|-----------|----------|---------|------|-------|
| Small (<10k LOC) | 1-2d | 2-5d | 5-10d | 3-7d | 2-4d | 2-3d | 15-31d |
| Medium (10-50k) | 2-3d | 3-7d | 10-20d | 7-14d | 4-8d | 3-5d | 29-57d |
| Large (>50k) | 3-5d | 5-10d | 20-40d | 14-28d | 8-16d | 5-10d | 55-109d |

**Buffer**: Add 30% contingency for unknowns

---

### Step 6: Code Quality Analysis (30 minutes)

#### 6.1 Architecture Assessment

**Evaluate Architecture**:
- [ ] Architecture pattern (monolith, microservices, layered, etc.)
- [ ] Separation of concerns (good/fair/poor)
- [ ] Coupling level (loose/moderate/tight)
- [ ] Design pattern usage (appropriate/mixed/absent)
- [ ] Technical debt level (low/medium/high)

**Modernization Compatibility**:
- ✅ **Good**: Well-architected, loose coupling → Easy migration
- ⚠️ **Fair**: Some technical debt → Moderate difficulty
- ❌ **Poor**: High coupling, poor separation → Difficult migration

**Scoring**:
- **80-100**: Clean architecture, low debt
- **60-79**: Some debt, but manageable
- **40-59**: Significant debt, refactoring needed
- **0-39**: Architecture rewrite recommended

#### 6.2 Code Quality Metrics

**Measure**:
```bash
# Cyclomatic complexity
# Code duplication percentage
# Method/class size averages
# Code coverage percentage
```

**Quality Indicators**:
- [ ] Average cyclomatic complexity: X (target <10)
- [ ] Code duplication: X% (target <5%)
- [ ] Average method lines: X (target <50)
- [ ] Test coverage: X% (target >80%)

**Scoring**:
- **80-100**: High quality, minimal refactoring needed
- **60-79**: Decent quality, some improvements needed
- **40-59**: Poor quality, significant refactoring required
- **0-39**: Very poor quality, rewrite consideration

---

### Step 7: Test Coverage & Stability (20 minutes)

#### 7.1 Existing Test Suite

**Analyze Tests**:
- [ ] Unit test count: X
- [ ] Integration test count: Y
- [ ] E2E test count: Z
- [ ] Test coverage: X%
- [ ] Test pass rate: Y%
- [ ] Test execution time: Z minutes

**Test Quality**:
- [ ] Tests are maintained and passing
- [ ] Tests cover critical paths
- [ ] Tests are not brittle/flaky
- [ ] Test infrastructure is documented

**Scoring**:
- **80-100**: >80% coverage, >95% pass rate, comprehensive suite
- **60-79**: 60-80% coverage, >90% pass rate
- **40-59**: 40-60% coverage, >80% pass rate
- **0-39**: <40% coverage or low pass rate

#### 7.2 Production Stability

**Metrics** (last 6 months):
- [ ] Production incidents: X
- [ ] Critical bugs: Y
- [ ] Uptime percentage: Z%
- [ ] Performance issues: W

**Scoring**:
- **80-100**: Stable system, rare incidents
- **60-79**: Generally stable, occasional issues
- **40-59**: Frequent issues, stability concerns
- **0-39**: Unstable, modernization may be too risky

---

### Step 8: Security Assessment (30 minutes)

#### 8.1 Vulnerability Scan

**Run Security Scan**:
```bash
# .NET: dotnet list package --vulnerable
# Node: npm audit
# Python: pip-audit
# Or use: Snyk, OWASP Dependency Check
```

**Categorize Vulnerabilities**:
- CRITICAL: X vulnerabilities
- HIGH: Y vulnerabilities
- MEDIUM: Z vulnerabilities
- LOW: W vulnerabilities

**Security Score**: (100 - (CRITICAL*20 + HIGH*10 + MEDIUM*5 + LOW*1))

**Scoring**:
- **80-100**: Minimal vulnerabilities, easy fixes
- **60-79**: Some vulnerabilities, manageable
- **40-59**: Many vulnerabilities, significant work
- **0-39**: Critical security issues, URGENT modernization

#### 8.2 Security Posture

**Evaluate**:
- [ ] Authentication/authorization modern?
- [ ] Encryption standards current?
- [ ] Secrets management proper?
- [ ] Security headers implemented?
- [ ] Input validation comprehensive?

---

## Assessment Report Generation

### assessment.md Template

```markdown
# Project Modernization Assessment

**Project**: [Name]
**Current Version**: [Version]
**Target Version**: [Version]
**Assessment Date**: [Date]
**Assessor**: [Name/Team]

---

## Executive Summary

**Recommendation**: ✅ PROCEED / ⚠️ PROCEED WITH CAUTION / ❌ DEFER / 🛑 DO NOT PROCEED

**Overall Score**: XX/100 (Excellent/Good/Fair/Poor)

**Key Findings**:
- [Finding 1]
- [Finding 2]
- [Finding 3]

**Estimated Effort**: XX-YY days (ZZ-WW calendar weeks)

---

## 1. Technical Viability: XX/100

### Framework Analysis
- **Current**: [Framework] [Version] (EOL: [Date])
- **Target**: [Framework] [Version]
- **Migration Path**: Clear/Documented/Unclear
- **Breaking Changes**: XX identified
- **Score**: XX/100

**Assessment**: [Detailed explanation]

### Dependency Health
- **Total Dependencies**: XX
- **Deprecated**: X (XX%)
- **Unmaintained**: Y (YY%)
- **Security Issues**: Z (CRITICAL: A, HIGH: B)
- **Score**: XX/100

**Red Flags**:
- [Flag 1 if any]
- [Flag 2 if any]

### Code Compatibility
- **Affected Code**: ~XX% (estimated)
- **Obsolete APIs**: X usages found
- **Platform-Specific Code**: Y instances
- **Score**: XX/100

**Major Challenges**:
1. [Challenge 1]
2. [Challenge 2]

---

## 2. Business Value: XX/100

### Strategic Alignment
- **Business Criticality**: Critical/Important/Peripheral
- **Development Status**: Active/Maintenance/Sunset
- **Strategic Value**: High/Medium/Low
- **Score**: XX/100

### Effort-Benefit Analysis

**Effort Estimate**:
- Assessment & Planning: X days
- Security Remediation: Y days
- Framework Migration: Z days
- Testing & Validation: W days
- Documentation: V days
- Contingency (30%): Z days
- **Total Effort**: **XX days**

**Expected Benefits**:
- Security: Reduced vulnerability risk, improved compliance
- Performance: Better response times, optimized resource usage
- Developer Productivity: Faster feature development, modern tooling
- Maintenance: Reduced legacy issues, improved long-term support
- Recruitment/Retention: Easier hiring with modern stack

**Value Assessment**:
- Significant benefits justify the effort investment
- Strategic importance aligns with business goals
- Long-term value outweighs short-term effort
- **Score**: XX/100

---

## 3. Risk Assessment: LOW/MEDIUM/HIGH/CRITICAL

### Technical Risks

| Risk | Likelihood | Impact | Severity | Mitigation |
|------|------------|--------|----------|------------|
| [Risk 1] | High/Med/Low | High/Med/Low | CRITICAL/HIGH/MEDIUM/LOW | [Strategy] |
| [Risk 2] | ... | ... | ... | [...] |

**Critical Risks** (0):
- [None] OR [List critical risks]

**High Risks** (X):
1. [Risk 1]
2. [Risk 2]

**Risk Mitigation Plan**:
- [Strategy 1]
- [Strategy 2]

### Business Risks
- [Risk 1]: [Assessment and mitigation]
- [Risk 2]: [Assessment and mitigation]

**Overall Risk Profile**: **LOW/MEDIUM/HIGH/CRITICAL**

---

## 4. Resource Requirements

### Team Capacity
- **Current Team Size**: X developers
- **Target Framework Expertise**: Expert/Intermediate/Beginner
- **Availability**: XX% (after ongoing work)
- **Skills Gap**: [List gaps]

### Training Needs
- [Skill 1]: X days
- [Skill 2]: Y days
- **Total Training**: Z days

### External Resources
- **Consultants Needed**: Yes/No
- **Specialized Skills**: [List if any]
- **Additional Effort**: X days (if consultants needed)

### Timeline
**Estimated Duration**: XX-YY weeks (ZZ-WW calendar months)

**Breakdown**:
- Phase 0 (Discovery): X-Y days
- Phase 1 (Security): X-Y days
- Phase 2 (Architecture): X-Y days
- Phase 3 (Framework): X-Y days
- Phase 4 (API Modernization): X-Y days
- Phase 5 (Performance): X-Y days
- Phase 6 (Documentation): X-Y days
- Phase 7 (Validation): X-Y days
- Contingency (30%): X-Y days

---

## 5. Code Quality: XX/100

### Architecture
- **Pattern**: [Monolith/Microservices/Layered/etc.]
- **Separation of Concerns**: Good/Fair/Poor
- **Coupling**: Loose/Moderate/Tight
- **Technical Debt**: Low/Medium/High
- **Score**: XX/100

**Analysis**: [Detailed assessment]

### Code Metrics
- **Cyclomatic Complexity**: X (target <10)
- **Code Duplication**: XX% (target <5%)
- **Average Method Size**: XX lines (target <50)
- **Score**: XX/100

---

## 6. Test Coverage: XX/100

### Test Suite Analysis
- **Unit Tests**: X tests
- **Integration Tests**: Y tests
- **E2E Tests**: Z tests
- **Coverage**: XX%
- **Pass Rate**: YY%
- **Execution Time**: Z minutes

**Assessment**: [Quality evaluation]

### Production Stability
- **Uptime**: XX.X%
- **Incidents (6mo)**: X
- **Critical Bugs**: Y
- **Performance Issues**: Z

**Score**: XX/100

---

## 7. Security Posture: XX/100

### Vulnerability Scan
- **CRITICAL**: X vulnerabilities
- **HIGH**: Y vulnerabilities
- **MEDIUM**: Z vulnerabilities
- **LOW**: W vulnerabilities
- **Security Score**: XX/100

**Critical Issues**:
1. [CVE-XXXX-XXXX]: [Description]
2. [CVE-YYYY-YYYY]: [Description]

### Security Practices
- Authentication: Modern/Dated/Poor
- Encryption: Current/Dated/None
- Secrets Management: Good/Fair/Poor
- Input Validation: Comprehensive/Partial/Minimal

---

## 8. Dependencies & Ecosystem

### Framework Ecosystem
- **Community Health**: Active/Declining/Stagnant
- **LTS Support**: Available/Limited/None
- **Tool Support**: Excellent/Good/Fair/Poor
- **Documentation**: Comprehensive/Good/Limited/Poor

### Dependency Analysis
- **Total**: XX packages
- **Up-to-date**: X (XX%)
- **Outdated**: Y (YY%)
- **Deprecated**: Z (ZZ%)
- **Unmaintained**: W (WW%)

**Major Dependencies**:
| Package | Current | Latest | Status | Migration Path |
|---------|---------|--------|--------|----------------|
| [Name] | vX.X | vY.Y | OK/Deprecated/EOL | Easy/Moderate/Hard |

---

## Overall Assessment

### Scoring Summary

| Dimension | Score | Weight | Weighted |
|-----------|-------|--------|----------|
| Technical Viability | XX/100 | 25% | XX.X |
| Business Value | XX/100 | 20% | XX.X |
| Risk Profile | XX/100 | 15% | XX.X |
| Resources | XX/100 | 10% | XX.X |
| Code Quality | XX/100 | 10% | XX.X |
| Test Coverage | XX/100 | 10% | XX.X |
| Security | XX/100 | 10% | XX.X |
| **TOTAL** | **XX/100** | **100%** | **XX.X** |

### Recommendation Matrix

**Score Interpretation**:
- **80-100**: ✅ **PROCEED** - Strong candidate, low risk
- **60-79**: ⚠️ **PROCEED WITH CAUTION** - Good candidate, manageable risks
- **40-59**: ❌ **DEFER** - Weak candidate, high risk, reconsider after improvements
- **0-39**: 🛑 **DO NOT PROCEED** - Poor candidate, critical risks, not viable

**This Project**: **XX/100** → **[RECOMMENDATION]**

---

## Recommendation

### ✅ PROCEED (if 80-100)

**Rationale**: [Explanation of why this is a good candidate]

**Strengths**:
- [Strength 1]
- [Strength 2]
- [Strength 3]

**Recommended Approach**: [Suggested strategy]

**Next Steps**:
1. Run `/modernize-plan` to create detailed migration plan
2. Secure resource approval (X developers, Y weeks)
3. Allocate team resources and timeline
4. Begin Phase 0 on [Date]

---

### ⚠️ PROCEED WITH CAUTION (if 60-79)

**Rationale**: [Explanation of viable but challenging project]

**Strengths**:
- [Strength 1]
- [Strength 2]

**Concerns**:
- [Concern 1]
- [Concern 2]

**Conditional Approval**: Proceed if:
1. [Condition 1]
2. [Condition 2]
3. [Condition 3]

**Risk Mitigation Required**:
- [Mitigation 1]
- [Mitigation 2]

**Next Steps**:
1. Address critical concerns listed above
2. Develop detailed risk mitigation plan
3. Run `/modernize-plan` with extra contingency
4. Executive sign-off required

---

### ❌ DEFER (if 40-59)

**Rationale**: [Explanation of why deferral is recommended]

**Critical Issues**:
1. [Issue 1]
2. [Issue 2]
3. [Issue 3]

**Recommended Actions Before Reconsidering**:
1. [Action 1]
2. [Action 2]
3. [Action 3]

**Re-Assessment Date**: [X months from now]

**Alternatives to Consider**:
- Maintain current version with security patches only
- Incremental improvements without full modernization
- Gradual replacement with new system
- [Other alternatives]

---

### 🛑 DO NOT PROCEED (if 0-39)

**Rationale**: [Explanation of why modernization is not viable]

**Blocking Issues**:
1. [Critical blocker 1]
2. [Critical blocker 2]
3. [Critical blocker 3]

**Recommended Alternatives**:
- **Rewrite from scratch**: [Justification]
- **Replace with COTS**: [Alternative solutions]
- **Sunset the system**: [Migration plan to replacement]
- **Maintain as-is**: [Minimal maintenance strategy]

**Decision**: Modernization is **NOT RECOMMENDED** for this project.

---

## Appendices

### A. Detailed Dependency List
[Full list of dependencies with versions and status]

### B. Breaking Changes Enumeration
[List of all breaking changes from current → target]

### C. Risk Register
[Complete risk register with all identified risks]

### D. Cost Breakdown
[Detailed cost estimation by phase and resource]

---

**Assessment Completed**: [Date]
**Valid Until**: [Date + 6 months]
**Next Review**: [Date + 3 months]
```

---

## Usage Examples

### Example 1: .NET 6 → .NET 9 Assessment

```
User: /modernize-assess
User: Assess my .NET 6 e-commerce platform for upgrading to .NET 9

Claude: I'll conduct a comprehensive modernization assessment...

[Step 1: Discovery]
- Project: E-Commerce Platform
- Current: .NET 6.0
- Target: .NET 9.0
- LOC: 47,500
- Dependencies: 83 packages
- Age: 4 years
- Active: Yes

[Step 2: Technical Viability]
Framework Analysis:
- .NET 6 EOL: Nov 2024 (6 months!)
- .NET 9 LTS: Current, well-supported
- Breaking changes: 23 identified
- Migration path: Clear ✅
Score: 85/100

Dependency Health:
- 83 packages analyzed
- 5 deprecated (6%)
- 2 unmaintained (2%)
- 3 security issues (1 HIGH)
Score: 78/100

Code Compatibility:
- ~15% code affected
- 12 obsolete API usages
- Mostly straightforward changes
Score: 82/100

**Technical Viability: 82/100** ✅

[Continues through all 8 dimensions...]

[Final Assessment]
**Overall Score: 78/100**
**Recommendation: ⚠️ PROCEED WITH CAUTION**

Writing assessment.md...
✅ Assessment complete: assessment.md created
```

### Example 2: Node.js 14 → 22 Assessment

```
User: /modernize-assess
User: We have a Node.js 14 API that needs evaluation for upgrading to Node.js 22

Claude: [Full assessment process]

[Final Result]
**Overall Score: 62/100**
**Recommendation: ⚠️ PROCEED WITH CAUTION**

Key Findings:
- Node 14 is EOL (critical security risk)
- 47 npm packages have vulnerabilities
- Test coverage only 34% (major concern)
- BUT: Clean architecture, good ROI

Conditional Approval:
1. Increase test coverage to >60% first
2. Address CRITICAL CVEs immediately
3. Allocate 2 months for migration

✅ assessment.md created
```

### Example 3: Legacy System - Not Recommended

```
User: /modernize-assess
User: Evaluate our 15-year-old Java 6 monolith for modernization

Claude: [Assessment process]

[Final Result]
**Overall Score: 34/100**
**Recommendation: 🛑 DO NOT PROCEED**

Critical Blockers:
1. Java 6 → 17/21: Too many breaking changes (>80% code affected)
2. 67% of dependencies unmaintained with no alternatives
3. No test coverage (0%)
4. Tight coupling throughout
5. ROI negative for modernization

Recommended Alternative:
**Strangler Fig Pattern** - Gradually replace with microservices
- Build new features in modern stack
- Migrate high-value modules incrementally
- Retire monolith over 3 years

❌ Modernization not recommended
✅ assessment.md created with alternatives
```

---

## Decision Criteria

### Proceed (80-100)
- Strong technical path
- Good ROI
- Low-medium risk
- Team capable
- Business value clear

### Proceed with Caution (60-79)
- Viable technical path
- Acceptable ROI
- Medium risk with mitigations
- Team can learn/adapt
- Business value justified

### Defer (40-59)
- Challenging technical path
- Marginal ROI
- High risk
- Team capacity concerns
- Unclear business value

### Do Not Proceed (0-39)
- No clear technical path
- Negative or very poor ROI
- Critical risks
- Team lacking capabilities
- No business justification

---

## Best Practices

1. **Be Objective** - Don't let sunk costs bias the assessment
2. **Be Conservative** - Underestimate benefits, overestimate costs
3. **Be Thorough** - Don't skip dimensions
4. **Be Honest** - Better to defer now than fail midway
5. **Document Everything** - The assessment.md is your evidence

---

## Anti-Patterns

❌ **Rubber-stamp approval** - "We already decided, just assess"
❌ **Ignoring red flags** - "We'll figure it out during migration"
❌ **Skipping ROI** - "We just need to modernize"
❌ **Unrealistic estimates** - "It'll only take 2 weeks"
❌ **Ignoring team capacity** - "We'll find time somehow"

---

**Document Owner**: Migration Coordinator
**Protocol Version**: 1.0
**Last Updated**: 2025-10-25
**Required Before**: Running `/modernize-plan` or `/modernize-project`

**Remember**: **Not all projects should be modernized. Assessment prevents costly mistakes.** ✅
