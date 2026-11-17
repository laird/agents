#!/bin/bash
# analyze-test-failure.sh - Analyze test failures for a migration stage
#
# Usage: ./scripts/analyze-test-failure.sh <stage_number>
#
# Analyzes test failures and provides diagnostic information.

set -e

STAGE_NUM="${1:?Stage number required}"

echo "=== Analyzing Test Failures for Stage $STAGE_NUM ==="
echo ""

# Run tests and capture output
TEMP_FILE="/tmp/test-failures-stage-$STAGE_NUM.txt"

echo "Running tests and capturing failures..."
echo ""

# Run tests based on project type
if [ -f "package.json" ]; then
    npm test 2>&1 | tee "$TEMP_FILE" || true
elif [ -f "pytest.ini" ] || [ -f "setup.py" ] || [ -f "pyproject.toml" ]; then
    pytest --tb=long 2>&1 | tee "$TEMP_FILE" || true
elif [ -f "*.sln" ] 2>/dev/null || [ -f "*.csproj" ] 2>/dev/null; then
    dotnet test --logger "console;verbosity=detailed" 2>&1 | tee "$TEMP_FILE" || true
elif [ -f "go.mod" ]; then
    go test -v ./... 2>&1 | tee "$TEMP_FILE" || true
elif [ -f "Cargo.toml" ]; then
    cargo test -- --nocapture 2>&1 | tee "$TEMP_FILE" || true
else
    echo "No recognized test framework found."
    exit 0
fi

echo ""
echo "=== Failure Analysis ==="
echo ""

# Extract failure summary
FAIL_COUNT=$(grep -c -i "fail\|error\|FAILED" "$TEMP_FILE" 2>/dev/null || echo "0")
echo "Potential failures detected: $FAIL_COUNT"

# Show failed test names (common patterns)
echo ""
echo "--- Failed Tests ---"
grep -E "FAIL|FAILED|ERROR|✗|×" "$TEMP_FILE" 2>/dev/null | head -20 || echo "No obvious failures found in output"

echo ""
echo "--- Recommendations ---"
echo "1. Review the full test output in: $TEMP_FILE"
echo "2. Check for breaking API changes in stage $STAGE_NUM"
echo "3. Verify dependencies are correctly updated"
echo "4. Run individual failing tests with verbose output"

echo ""
echo "=== Analysis Complete ==="
