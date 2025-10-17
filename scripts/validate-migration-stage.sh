#!/bin/bash
# scripts/validate-migration-stage.sh - Automated quality gate validation
# Usage: ./scripts/validate-migration-stage.sh <stage-number>

set -e

STAGE_NUM=$1

if [ -z "$STAGE_NUM" ]; then
    echo "Usage: $0 <stage-number>"
    echo "Example: $0 2"
    exit 1
fi

echo "🔍 Validating Stage $STAGE_NUM Quality Gates..."
echo ""

VALIDATION_FAILED=0

# Function to check and report
check_gate() {
    local gate_name=$1
    local gate_command=$2
    local gate_criteria=$3

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Gate: $gate_name"
    echo "Criteria: $gate_criteria"
    echo ""

    if eval "$gate_command"; then
        echo "✅ PASSED: $gate_name"
        return 0
    else
        echo "❌ FAILED: $gate_name"
        VALIDATION_FAILED=1
        return 1
    fi
}

# Gate 1: Build Success
echo ""
check_gate \
    "Build Success" \
    "~/.dotnet/dotnet build RawRabbit.sln --configuration Release --verbosity quiet" \
    "100% build success, 0 errors"

# Gate 2: Test Pass Rate (stages 2-7 only)
if [ "$STAGE_NUM" -ge 2 ] && [ "$STAGE_NUM" -le 7 ]; then
    echo ""
    check_gate \
        "Test Pass Rate" \
        "./scripts/run-stage-tests.sh $STAGE_NUM \"Validation\"" \
        "≥95% unit tests, ≥90% integration tests"
fi

# Gate 3: Security Scan (stages 1-7)
if [ "$STAGE_NUM" -ge 1 ] && [ "$STAGE_NUM" -le 7 ]; then
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Gate: Security Scan"
    echo "Criteria: Zero CRITICAL/HIGH vulnerabilities"
    echo ""

    VULN_OUTPUT=$(~/.dotnet/dotnet list RawRabbit.sln package --vulnerable 2>&1 || true)

    if echo "$VULN_OUTPUT" | grep -qi "critical\|high"; then
        echo "❌ FAILED: Security vulnerabilities detected"
        echo ""
        echo "$VULN_OUTPUT"
        VALIDATION_FAILED=1
    else
        echo "✅ PASSED: No CRITICAL/HIGH vulnerabilities"
    fi
fi

# Gate 4: Documentation Updates
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Gate: Documentation Updates"
echo "Criteria: HISTORY.md updated for stage"
echo ""

if [ -f "docs/HISTORY.md" ] || [ -f "HISTORY.md" ]; then
    # Look for recent entries (last 24 hours)
    HISTORY_FILE=$([ -f "docs/HISTORY.md" ] && echo "docs/HISTORY.md" || echo "HISTORY.md")
    RECENT_ENTRIES=$(find "$HISTORY_FILE" -mtime -1 2>/dev/null || echo "")

    if [ -n "$RECENT_ENTRIES" ]; then
        echo "✅ PASSED: HISTORY.md recently updated"
    else
        echo "⚠️  WARNING: HISTORY.md not updated in last 24 hours"
        echo "    (Not blocking, but recommended to log stage completion)"
    fi
else
    echo "⚠️  WARNING: HISTORY.md not found"
    echo "    (Will be created during migration)"
fi

# Gate 5: CHANGELOG.md updates (stages 1-8)
if [ "$STAGE_NUM" -ge 1 ]; then
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Gate: CHANGELOG.md Updates"
    echo "Criteria: Incremental documentation protocol followed"
    echo ""

    if [ -f "CHANGELOG.md" ]; then
        echo "✅ PASSED: CHANGELOG.md exists"

        # Check if recently updated
        RECENT_CHANGELOG=$(find CHANGELOG.md -mtime -7 2>/dev/null || echo "")
        if [ -n "$RECENT_CHANGELOG" ]; then
            echo "   ✅ Updated in last 7 days"
        else
            echo "   ⚠️  Not updated recently (check if stage changes documented)"
        fi
    else
        if [ "$STAGE_NUM" -le 2 ]; then
            echo "⚠️  WARNING: CHANGELOG.md not yet created"
            echo "   (Should be created in Stage 1 or 2)"
        else
            echo "❌ FAILED: CHANGELOG.md missing (required after Stage 2)"
            VALIDATION_FAILED=1
        fi
    fi
fi

# Final Summary
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [ $VALIDATION_FAILED -eq 0 ]; then
    echo "✅ Stage $STAGE_NUM Quality Gates: PASSED"
    echo ""
    echo "Ready to proceed to Stage $((STAGE_NUM + 1))"
    exit 0
else
    echo "❌ Stage $STAGE_NUM Quality Gates: FAILED"
    echo ""
    echo "⚠️  Fix issues before proceeding"
    echo ""
    echo "Troubleshooting:"
    echo "  1. Review failed gates above"
    echo "  2. Fix root causes"
    echo "  3. Rerun validation: $0 $STAGE_NUM"
    echo "  4. If issues persist, review PLAN.md for guidance"
    exit 1
fi
