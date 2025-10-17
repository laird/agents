#!/bin/bash
# scripts/capture-test-baseline.sh - Capture pre-migration test baseline

set -e

echo "📊 Capturing pre-migration test baseline..."
echo ""

BASELINE_DIR="docs/test-baselines"
mkdir -p "$BASELINE_DIR"

TIMESTAMP=$(date '+%Y-%m-%d-%H%M%S')
BASELINE_FILE="$BASELINE_DIR/baseline-$TIMESTAMP.md"

echo "Running full test suite on CURRENT framework..."
echo "(This may take a few minutes...)"
echo ""

# Run tests and capture output
~/.dotnet/dotnet test --configuration Release \
  --logger "trx;LogFileName=baseline-tests.trx" \
  > /tmp/baseline-test-output.txt 2>&1 || true

# Extract metrics (dotnet test output format)
TOTAL_TESTS=$(grep -o "Total tests: [0-9]*" /tmp/baseline-test-output.txt | grep -o "[0-9]*" | head -1 || echo "0")
PASSED_TESTS=$(grep -o "Passed: [0-9]*" /tmp/baseline-test-output.txt | grep -o "[0-9]*" | head -1 || echo "0")
FAILED_TESTS=$(grep -o "Failed: [0-9]*" /tmp/baseline-test-output.txt | grep -o "[0-9]*" | head -1 || echo "0")
SKIPPED_TESTS=$(grep -o "Skipped: [0-9]*" /tmp/baseline-test-output.txt | grep -o "[0-9]*" | head -1 || echo "0")

# Get current framework from Core project
FRAMEWORK=$(grep -m 1 "TargetFramework" src/RawRabbit/RawRabbit.csproj | sed 's/.*<TargetFramework[^>]*>\(.*\)<\/TargetFramework[^>]*>.*/\1/' || echo "unknown")

# Calculate pass rate
if [ "$TOTAL_TESTS" -gt 0 ]; then
  PASS_RATE=$(echo "scale=2; $PASSED_TESTS * 100 / $TOTAL_TESTS" | bc)
else
  PASS_RATE="0.00"
fi

# Create baseline document
cat > "$BASELINE_FILE" << EOF
# Pre-Migration Test Baseline

**Date**: $(date '+%Y-%m-%d %H:%M:%S')
**Framework**: $FRAMEWORK
**Purpose**: Establish baseline before .NET 9.0 migration

---

## Test Statistics

- **Total Tests**: $TOTAL_TESTS
- **Passed**: $PASSED_TESTS
- **Failed**: $FAILED_TESTS
- **Skipped**: $SKIPPED_TESTS
- **Pass Rate**: ${PASS_RATE}%

## Build Configuration

- **Configuration**: Release
- **Framework**: $FRAMEWORK
- **.NET SDK**: $(~/.dotnet/dotnet --version)
- **Baseline Date**: $(date '+%Y-%m-%d')

## Test Results File

Test results stored at: TestResults/baseline-tests.trx

## Test Output

\`\`\`
$(tail -50 /tmp/baseline-test-output.txt)
\`\`\`

## Purpose

This baseline will be used to:
1. Compare post-migration test results
2. Detect regressions introduced during migration
3. Validate migration success
4. Identify new failures vs. pre-existing issues

## Success Criteria (Post-Migration)

After migration to .NET 9.0, expect:
- **Pass Rate**: ≥${PASS_RATE}% (maintain or improve)
- **Total Tests**: $TOTAL_TESTS (should remain similar)
- **New Failures**: 0 (all new issues must be fixed)

## Next Steps

1. Begin migration following docs/PLAN.md
2. After each stage, compare test results to this baseline
3. Fix any regressions immediately (fix-before-proceed rule)
4. Final validation: Run tests and compare to baseline

---

**Baseline captured successfully!**
**Next**: Execute Stage 0 (Prerequisites) and Stage 1 (Security Remediation)
EOF

# Copy test results if available
if [ -f "TestResults/baseline-tests.trx" ]; then
  cp TestResults/baseline-tests.trx "$BASELINE_DIR/" 2>/dev/null || true
fi

# Display summary
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Baseline captured: $BASELINE_FILE"
echo ""
echo "Summary:"
echo "  Framework:    $FRAMEWORK"
echo "  Total Tests:  $TOTAL_TESTS"
echo "  Passed:       $PASSED_TESTS"
echo "  Failed:       $FAILED_TESTS"
echo "  Skipped:      $SKIPPED_TESTS"
echo "  Pass Rate:    ${PASS_RATE}%"
echo ""
echo "Next Steps:"
echo "  1. Review baseline: cat $BASELINE_FILE"
echo "  2. Begin migration: Follow docs/PLAN.md"
echo "  3. Compare results after each stage"
echo ""
echo "🚀 Ready to begin migration!"
