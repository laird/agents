#!/bin/bash
# capture-test-baseline.sh - Capture baseline test results
#
# Usage: ./scripts/capture-test-baseline.sh
#
# Runs tests and captures the baseline results for comparison during migration.

set -e

BASELINE_FILE="docs/TEST-BASELINE.md"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

echo "=== Capturing Test Baseline ==="
echo "Timestamp: $TIMESTAMP"
echo ""

# Create docs directory if needed
mkdir -p docs

# Initialize baseline file
cat > "$BASELINE_FILE" << EOF
# Test Baseline

**Captured**: $TIMESTAMP

## Summary

EOF

# Detect and run appropriate test framework
if [ -f "package.json" ]; then
    echo "Running npm tests..."
    npm test 2>&1 | tee -a "$BASELINE_FILE" || true
elif [ -f "pytest.ini" ] || [ -f "setup.py" ] || [ -f "pyproject.toml" ]; then
    echo "Running pytest..."
    pytest --tb=short 2>&1 | tee -a "$BASELINE_FILE" || true
elif [ -f "*.sln" ] 2>/dev/null || [ -f "*.csproj" ] 2>/dev/null; then
    echo "Running dotnet test..."
    dotnet test 2>&1 | tee -a "$BASELINE_FILE" || true
elif [ -f "go.mod" ]; then
    echo "Running go test..."
    go test ./... 2>&1 | tee -a "$BASELINE_FILE" || true
elif [ -f "Cargo.toml" ]; then
    echo "Running cargo test..."
    cargo test 2>&1 | tee -a "$BASELINE_FILE" || true
else
    echo "No recognized test framework found." | tee -a "$BASELINE_FILE"
    echo "Supported: npm, pytest, dotnet, go, cargo" | tee -a "$BASELINE_FILE"
fi

echo ""
echo "=== Baseline captured to $BASELINE_FILE ==="
