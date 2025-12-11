---
name: security-scanning-protocol
description: Automated vulnerability scanning protocol with verified CVE tracking and quality gates
---

# Security Scanning Protocol

**Version**: 1.0 (NEW per Retrospective Recommendation 3)
**Date**: 2025-11-09
**Purpose**: Automate security vulnerability scanning with verified metrics, not estimates
**Applicability**: All .NET projects, especially modernizations

---

## Overview

This protocol ensures security work is **verified** not **estimated** by requiring automated vulnerability scans at multiple stages. It prevents "trust-based" security claims and provides audit-ready evidence of CVE remediation.

**Core Principle**: **Security scores must be calculated from scan results, never estimated.**

---

## Problem Solved

**Anti-Pattern**: Security work without verification ❌

```
Phase 1: Update packages (assume CVEs fixed)
Result: Security score "~52/100 (estimated)" ⚠️
Problem: No proof CVEs actually eliminated
Risk: Unknown actual security posture
```

**Best Practice**: Automated scanning with verification ✅

```
Phase 0: Scan shows 63 CVEs (4 CRITICAL, 11 HIGH)
Phase 1: Update packages, re-scan
Result: 18 CVEs (0 CRITICAL, 0 HIGH) ✅ VERIFIED
Evidence: Diff shows 45 CVEs eliminated
Quality Gate: PASS (zero CRITICAL/HIGH confirmed)
```

---

## Security Scanning Stages

### Stage 1: Baseline Security Scan (Phase 0 - Mandatory First)

**When**: Phase 0, Task 1 (immediately after SDK setup, before assessment)

**Why First**: Cannot plan security work without knowing actual CVE count

**Command**:

```bash
# Run vulnerability scan and save baseline
dotnet list package --vulnerable --include-transitive | tee security-baseline.txt

# Alternative: Save structured output
dotnet list package --vulnerable --include-transitive --format json > security-baseline.json
```

**Parse Results**:

```bash
# Count vulnerabilities by severity
CRITICAL=$(grep "Critical" security-baseline.txt | wc -l)
HIGH=$(grep "High" security-baseline.txt | wc -l)
MEDIUM=$(grep "Moderate" security-baseline.txt | wc -l)
LOW=$(grep "Low" security-baseline.txt | wc -l)

echo "Baseline: $CRITICAL CRITICAL, $HIGH HIGH, $MEDIUM MEDIUM, $LOW LOW"
```

**Calculate Security Score**:

```
Formula: 100 - (CRITICAL×10 + HIGH×5 + MEDIUM×2 + LOW×0.5)

Example:
  4 CRITICAL × 10 = 40
 11 HIGH     × 5  = 55
 23 MEDIUM   × 2  = 46
 25 LOW      × 0.5 = 12.5
 Total penalty: 153.5
 Score: 100 - 153.5 = -53.5 (capped at 0)
 Baseline Security Score: 0/100 (CRITICAL RISK)
```

**Document in docs/modernization-assessment.md**:

```markdown
## Security Baseline

**Scan Date**: YYYY-MM-DD HH:MM
**Tool**: dotnet list package --vulnerable --include-transitive
**Results**:
- **CRITICAL**: 4 vulnerabilities
- **HIGH**: 11 vulnerabilities
- **MEDIUM**: 23 vulnerabilities
- **LOW**: 25 vulnerabilities
- **TOTAL**: 63 vulnerabilities

**Security Score**: 0/100 (CRITICAL RISK)

**Top 10 CVEs** (prioritize fixes):
1. CVE-2018-11093 - Newtonsoft.Json 10.0.1 - CRITICAL
2. CVE-2019-XXXX - RabbitMQ.Client 5.0.1 - HIGH
3. ...

**Scan Evidence**: `security-baseline.txt` (committed to git)
```

**Deliverable**: Verified baseline CVE count and security score

---

### Stage 2: Post-Update Security Validation (Phase 1 - Mandatory After Fixes)

**When**: Phase 1, after all security updates applied

**Why**: Verify updates actually fixed CVEs (not assumed)

**Command**:

```bash
# Re-run scan after updates
dotnet list package --vulnerable --include-transitive | tee security-after-phase1.txt

# Compare before/after
echo "=== Security Scan Comparison ===" > security-diff.txt
echo "" >> security-diff.txt
echo "BEFORE (Baseline):" >> security-diff.txt
grep -E "Critical|High|Moderate|Low" security-baseline.txt | wc -l >> security-diff.txt
echo "" >> security-diff.txt
echo "AFTER (Phase 1):" >> security-diff.txt
grep -E "Critical|High|Moderate|Low" security-after-phase1.txt | wc -l >> security-diff.txt
echo "" >> security-diff.txt
diff security-baseline.txt security-after-phase1.txt >> security-diff.txt
```

**Validation Checks**:

```bash
# Verify CRITICAL/HIGH eliminated
CRITICAL_AFTER=$(grep "Critical" security-after-phase1.txt | wc -l)
HIGH_AFTER=$(grep "High" security-after-phase1.txt | wc -l)

if [ $CRITICAL_AFTER -gt 0 ] || [ $HIGH_AFTER -gt 0 ]; then
  echo "❌ Quality Gate FAILED: $CRITICAL_AFTER CRITICAL, $HIGH_AFTER HIGH CVEs remain"
  exit 1
fi

echo "✅ Quality Gate PASSED: Zero CRITICAL/HIGH CVEs"
```

**Recalculate Security Score**:

```
After Phase 1:
  0 CRITICAL × 10 = 0
  0 HIGH     × 5  = 0
 12 MEDIUM   × 2  = 24
  6 LOW      × 0.5 = 3
 Total penalty: 27
 Score: 100 - 27 = 73
 Post-Phase-1 Security Score: 73/100 ✅
```

**Update CHANGELOG.md** (verified, not estimated):

```markdown
### Security

- ✅ **Fixed 63 CVEs** (verified via scan diff)
  - CRITICAL: 4 → 0 (100% eliminated)
  - HIGH: 11 → 0 (100% eliminated)
  - MEDIUM: 23 → 12 (48% reduced)
  - LOW: 25 → 6 (76% reduced)
- ✅ **Security score improvement**: 0/100 → 73/100 (verified)
- ✅ **Scan evidence**: `security-after-phase1.txt` and `security-diff.txt`

**Key Fixes**:
- CVE-2018-11093: Newtonsoft.Json 10.0.1 → 13.0.3 ✅
- CVE-2019-XXXX: RabbitMQ.Client 5.0.1 → 6.8.1 ✅
```

**Quality Gate**:

- ✅ CRITICAL count: 0 (verified in scan)
- ✅ HIGH count: 0 (verified in scan)
- ✅ Security score ≥45 (calculated from scan: 73/100)
- ✅ Scan diff shows improvement (documented)
- ✅ No NEW vulnerabilities introduced

---

### Stage 3: Continuous Security Monitoring (Phases 2-7)

**When**: After each major dependency change

**Why**: Catch regressions immediately

**Command**:

```bash
# Quick scan after dependency changes
dotnet list package --vulnerable --include-transitive > security-phase-$PHASE.txt

# Compare to previous scan
diff security-after-phase1.txt security-phase-$PHASE.txt

# Alert if NEW vulnerabilities
NEW_VULNS=$(diff security-after-phase1.txt security-phase-$PHASE.txt | grep ">" | wc -l)
if [ $NEW_VULNS -gt 0 ]; then
  echo "⚠️  WARNING: $NEW_VULNS new vulnerabilities detected in Phase $PHASE"
  echo "Review changes before proceeding"
fi
```

**Frequency**: After each phase that touches dependencies

---

### Stage 4: Final Security Validation (Phase 7 - Pre-Release)

**When**: Phase 7 (before GO/NO-GO decision)

**Why**: Final verification before production release

**Command**:

```bash
# Final comprehensive scan
dotnet list package --vulnerable --include-transitive | tee security-final.txt

# Compare to baseline
echo "=== Final Security Assessment ===" > security-final-report.txt
echo "" >> security-final-report.txt
echo "BASELINE (Phase 0): 63 CVEs" >> security-final-report.txt
echo "FINAL (Phase 7): $(grep -E 'Critical|High|Moderate|Low' security-final.txt | wc -l) CVEs" >> security-final-report.txt
echo "" >> security-final-report.txt
echo "IMPROVEMENT: $(( 63 - $(grep -E 'Critical|High|Moderate|Low' security-final.txt | wc -l) )) CVEs eliminated" >> security-final-report.txt
```

**Final Quality Gate**:

- ✅ Zero CRITICAL vulnerabilities (verified)
- ✅ Zero HIGH vulnerabilities (verified)
- ✅ Security score ≥75 (production target)
- ✅ All scans documented in HISTORY.md
- ✅ Audit trail complete (baseline → final)

---

## Automation Script Template

Create `.build/security-scan.sh`:

```bash
#!/bin/bash
# Security vulnerability scanning automation
# Usage: ./security-scan.sh [baseline|validate|monitor]

set -e

MODE=${1:-monitor}
PHASE=${2:-unknown}
BASELINE="security-baseline.txt"
CURRENT="security-current.txt"

# Run scan
echo "🔍 Running vulnerability scan..."
dotnet list package --vulnerable --include-transitive | tee $CURRENT

# Count vulnerabilities
CRITICAL=$(grep -c "Critical" $CURRENT || echo "0")
HIGH=$(grep -c "High" $CURRENT || echo "0")
MEDIUM=$(grep -c "Moderate" $CURRENT || echo "0")
LOW=$(grep -c "Low" $CURRENT || echo "0")

# Calculate score
PENALTY=$((CRITICAL * 10 + HIGH * 5 + MEDIUM * 2 + LOW / 2))
SCORE=$((100 - PENALTY))
if [ $SCORE -lt 0 ]; then SCORE=0; fi

echo ""
echo "📊 Security Scan Results:"
echo "  CRITICAL: $CRITICAL"
echo "  HIGH: $HIGH"
echo "  MEDIUM: $MEDIUM"
echo "  LOW: $LOW"
echo "  Security Score: $SCORE/100"
echo ""

# Mode-specific logic
case $MODE in
  baseline)
    echo "💾 Saving baseline..."
    cp $CURRENT $BASELINE
    echo "✅ Baseline saved: $BASELINE"
    ;;

  validate)
    echo "🔍 Validating against quality gate..."
    if [ $CRITICAL -gt 0 ] || [ $HIGH -gt 0 ]; then
      echo "❌ FAILED: $CRITICAL CRITICAL, $HIGH HIGH CVEs found"
      echo "Quality gate requires zero CRITICAL/HIGH vulnerabilities"
      exit 1
    fi
    if [ $SCORE -lt 45 ]; then
      echo "❌ FAILED: Security score $SCORE < 45"
      exit 1
    fi
    echo "✅ PASSED: Zero CRITICAL/HIGH, Score: $SCORE/100"
    ;;

  monitor)
    if [ -f $BASELINE ]; then
      echo "📈 Comparing to baseline..."
      diff $BASELINE $CURRENT > security-diff.txt || true
      NEW=$(diff $BASELINE $CURRENT | grep -c ">" || echo "0")
      FIXED=$(diff $BASELINE $CURRENT | grep -c "<" || echo "0")
      echo "  New vulnerabilities: $NEW"
      echo "  Fixed vulnerabilities: $FIXED"
    fi
    ;;
esac

echo ""
echo "📄 Scan saved: $CURRENT"
```

**Usage**:

```bash
# Phase 0: Create baseline
.build/security-scan.sh baseline

# Phase 1: Validate after fixes
.build/security-scan.sh validate

# Phase 2-7: Monitor for changes
.build/security-scan.sh monitor phase2
```

---

## Integration with CI/CD (Future)

**Pre-commit Hook** (prevent CRITICAL/HIGH commits):

```bash
#!/bin/bash
# .git/hooks/pre-commit

# Run quick security check
./security-scan.sh validate
if [ $? -ne 0 ]; then
  echo "❌ Commit blocked: Security vulnerabilities detected"
  echo "Run './security-scan.sh monitor' to see details"
  exit 1
fi
```

**GitHub Actions** (scheduled scans):

```yaml
name: Security Scan
on:
  schedule:
    - cron: '0 0 * * 0'  # Weekly
  push:
    branches: [ main ]

jobs:
  security:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v2
      - uses: actions/setup-dotnet@v2
      - run: ./security-scan.sh validate
```

---

## Best Practices

1. **Always scan before planning** - Phase 0, Task 1
2. **Re-scan after every security update** - Phase 1
3. **Monitor during development** - Phases 2-7
4. **Final validation before release** - Phase 7
5. **Commit scan results to git** - Audit trail
6. **Never estimate security scores** - Always calculate from scans
7. **Use diff to prove improvement** - Show evidence
8. **Block progression on quality gate failures** - Hard stops, not warnings

---

## Troubleshooting

**Problem**: Scan shows vulnerabilities in transitive dependencies

**Solution**:

```bash
# Identify which package brings in the vulnerable transitive dependency
dotnet list package --include-transitive | grep <vulnerable-package>

# Update the direct dependency that references it
dotnet add package <direct-dependency> --version <newer-version>
```

**Problem**: No vulnerabilities shown but security concerns remain

**Solution**:

- Scan may only show known CVEs (NVD database)
- Use additional tools: Snyk, Dependabot, OWASP Dependency Check
- Check for abandoned packages (last update >2 years)

**Problem**: Vulnerable package has no secure version available

**Solution**:

1. Check for alternative packages
2. Document as accepted risk with mitigation plan
3. Consider forking and patching (last resort)

---

## References

- [.NET Vulnerability Scanning Docs](https://learn.microsoft.com/en-us/dotnet/core/tools/dotnet-list-package)
- [NVD - National Vulnerability Database](https://nvd.nist.gov/)
- [CVE - Common Vulnerabilities and Exposures](https://cve.mitre.org/)

---

**Document Owner**: Security Agent
**Last Updated**: 2025-11-09
**Version**: 1.0
