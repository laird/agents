# Assessment Workflow

**Purpose**: Comprehensive project analysis and modernization readiness evaluation

## Configuration

Read project-specific settings from guidance file (e.g., `CLAUDE.md`, `gemini.md`).

## Coordinator Activities

1. **Initiate**: Review scope, assign tasks to specialists, establish timeline
2. **Consolidate**: Collect findings, identify themes, prioritize by impact
3. **Analyze**: Identify risks/blockers, develop mitigation strategies
4. **Deliver**: Create `ASSESSMENT.md` with findings and recommendations

## Specialist Assessments

| Agent | Focus | Activities |
|-------|-------|------------|
| Architect | Architecture, tech debt | Analyze patterns, scalability, maintainability |
| Security | Vulnerabilities, compliance | Run scans, assess auth/authz, data protection |
| Coder | Code quality, migration readiness | Analyze metrics, deprecated APIs, complexity |
| Tester | Coverage, QA readiness | Analyze gaps, automation capabilities |
| Documentation | Completeness, accuracy | Review state, identify gaps, assess ADRs |

## ASSESSMENT.md Template

```markdown
# Project Modernization Assessment

**Project**: {name} | **Date**: {date} | **Scope**: {scope}

## Executive Summary
{key findings and recommendations}

## Architecture
- **Stack**: {current}
- **Strengths**: {list}
- **Weaknesses**: {list}
- **Tech Debt**: {analysis}
- **Opportunities**: {list}

## Security
| Severity | Count | Status |
|----------|-------|--------|
| Critical | {n} | {status} |
| High | {n} | {status} |
| Medium | {n} | {status} |
| Low | {n} | {status} |

**Gaps**: {analysis}
**Recommendations**: {list}

## Code Quality
- **Coverage**: {%}
- **Complexity**: {metrics}
- **Migration Complexity**: {analysis}
- **Needs**: {list}

## Testing
- **Unit Coverage**: {%}
- **Integration Coverage**: {%}
- **E2E Coverage**: {%}
- **Gaps**: {list}
- **Infrastructure**: {assessment}

## Documentation
- **Completeness**: {rating}
- **Accuracy**: {rating}
- **ADR Status**: {assessment}
- **Gaps**: {list}

## Risk Analysis

| Risk | Impact | Probability | Mitigation |
|------|--------|-------------|------------|
| {risk} | H/M/L | H/M/L | {strategy} |

## Recommendations

### Priority 1 (Critical)
{list}

### Priority 2 (High)
{list}

### Priority 3 (Medium)
{list}

## Success Criteria
{definition}

## Next Steps
{actions}
```

## Success Metrics

### Assessment Quality Metrics

| Metric | Target | How to Measure |
|--------|--------|----------------|
| Coverage completeness | 100% | All 5 specialist areas assessed |
| Finding accuracy | >90% | Validated by specialist review |
| Recommendation actionability | 100% | Each has clear owner + next step |
| Risk identification | Complete | All H/M risks have mitigations |
| Stakeholder satisfaction | Approved | Sign-off on assessment |

### Project Success Metrics

| Metric | Target | Measurement |
|--------|--------|-------------|
| Modernization success rate | 100% | All planned changes completed |
| Security score improvement | ≥45/100 | Post-migration security scan |
| Test pass rate | 100% | Full regression suite |
| Build success | 100% | All targets compile |
| Timeline adherence | ±10% | Actual vs estimated |
| Zero P0/P1 post-migration | 0 | Issues in first 30 days |

### Effort Estimation Guidelines

| Project Size | Assessment Duration | Indicators |
|--------------|---------------------|------------|
| Small | 1-2 days | <10K LOC, <20 dependencies, single service |
| Medium | 3-5 days | 10-50K LOC, 20-100 deps, 2-5 services |
| Large | 1-2 weeks | >50K LOC, >100 deps, >5 services |

## Quality Gates

- All specialist assessments complete
- Findings consolidated and integrated
- Risks documented with mitigations
- Recommendations prioritized
- Success criteria defined

## Coordination

- Parallel assessment by all specialists
- Regular check-ins for alignment
- Cross-functional review of findings
- Collaborative risk assessment
