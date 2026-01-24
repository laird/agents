#!/bin/bash
# run-stage-tests.sh - Run tests for a specific migration stage
#
# Usage: ./scripts/run-stage-tests.sh <stage_number> <stage_name> [strict|lenient]
#
# Runs tests and validates they pass for the specified migration stage.

set -e

STAGE_NUM="${1:?Stage number required}"
STAGE_NAME="${2:?Stage name required}"
MODE="${3:-strict}"

echo "=== Stage $STAGE_NUM: $STAGE_NAME Tests ==="
echo "Mode: $MODE"
echo ""

# Run tests based on project type
TEST_EXIT_CODE=0

if [ -f "package.json" ]; then
    npm test || TEST_EXIT_CODE=$?
elif [ -f "pytest.ini" ] || [ -f "setup.py" ] || [ -f "pyproject.toml" ]; then
    pytest --tb=short || TEST_EXIT_CODE=$?
elif [ -f "*.sln" ] 2>/dev/null || [ -f "*.csproj" ] 2>/dev/null; then
    dotnet test || TEST_EXIT_CODE=$?
elif [ -f "go.mod" ]; then
    go test ./... || TEST_EXIT_CODE=$?
elif [ -f "Cargo.toml" ]; then
    cargo test || TEST_EXIT_CODE=$?
else
    echo "Warning: No recognized test framework found."
    TEST_EXIT_CODE=0
fi

echo ""
if [ $TEST_EXIT_CODE -eq 0 ]; then
    echo "=== Stage $STAGE_NUM PASSED ==="
    exit 0
else
    echo "=== Stage $STAGE_NUM FAILED ==="
    if [ "$MODE" = "strict" ]; then
        echo "Strict mode: Failing build"
        exit 1
    else
        echo "Lenient mode: Continuing despite failures"
        exit 0
    fi
fi
