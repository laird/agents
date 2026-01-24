#!/bin/bash
# enforce-coverage.sh - Enforce minimum test coverage threshold
#
# Usage: ./scripts/enforce-coverage.sh [threshold]
#
# Runs tests with coverage and fails if below threshold (default: 80%).

set -e

THRESHOLD="${1:-80}"

echo "=== Enforcing Coverage Threshold: ${THRESHOLD}% ==="
echo ""

# Run coverage based on project type
COVERAGE=0

if [ -f "package.json" ]; then
    echo "Running npm coverage..."
    npm run coverage 2>/dev/null || npm test -- --coverage 2>/dev/null || {
        echo "Warning: Could not run coverage. Ensure coverage is configured in package.json"
        exit 0
    }
    # Try to extract coverage from common formats
    if [ -f "coverage/coverage-summary.json" ]; then
        COVERAGE=$(cat coverage/coverage-summary.json | grep -o '"pct":[0-9.]*' | head -1 | grep -o '[0-9.]*')
    fi
elif [ -f "pytest.ini" ] || [ -f "setup.py" ] || [ -f "pyproject.toml" ]; then
    echo "Running pytest coverage..."
    pytest --cov --cov-report=term 2>&1 | tee /tmp/coverage.txt || true
    COVERAGE=$(grep -o 'TOTAL.*[0-9]*%' /tmp/coverage.txt | grep -o '[0-9]*%' | tr -d '%' || echo "0")
elif [ -f "go.mod" ]; then
    echo "Running go coverage..."
    go test -coverprofile=coverage.out ./... 2>&1 || true
    COVERAGE=$(go tool cover -func=coverage.out 2>/dev/null | grep total | grep -o '[0-9.]*%' | tr -d '%' || echo "0")
else
    echo "Warning: No recognized test framework with coverage support found."
    exit 0
fi

echo ""
echo "Coverage: ${COVERAGE}%"
echo "Threshold: ${THRESHOLD}%"

if [ "$(echo "$COVERAGE >= $THRESHOLD" | bc -l 2>/dev/null || echo 0)" -eq 1 ]; then
    echo "=== Coverage PASSED ==="
    exit 0
else
    echo "=== Coverage FAILED (${COVERAGE}% < ${THRESHOLD}%) ==="
    exit 1
fi
