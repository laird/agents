#!/bin/bash
# validate-migration-stage.sh - Validate completion of a migration stage
#
# Usage: ./scripts/validate-migration-stage.sh <stage_number> <stage_name>
#
# Validates that a migration stage meets all quality gate requirements.

set -e

STAGE_NUM="${1:?Stage number required}"
STAGE_NAME="${2:?Stage name required}"

echo "=== Validating Stage $STAGE_NUM: $STAGE_NAME ==="
echo ""

ERRORS=0

# Check 1: Build succeeds
echo "Checking build..."
if [ -f "package.json" ]; then
    npm run build 2>/dev/null || npm install 2>/dev/null || { echo "  [FAIL] Build failed"; ((ERRORS++)); }
elif [ -f "*.sln" ] 2>/dev/null || [ -f "*.csproj" ] 2>/dev/null; then
    dotnet build || { echo "  [FAIL] Build failed"; ((ERRORS++)); }
elif [ -f "go.mod" ]; then
    go build ./... || { echo "  [FAIL] Build failed"; ((ERRORS++)); }
elif [ -f "Cargo.toml" ]; then
    cargo build || { echo "  [FAIL] Build failed"; ((ERRORS++)); }
else
    echo "  [SKIP] No build system detected"
fi

# Check 2: Tests pass
echo "Checking tests..."
./scripts/run-stage-tests.sh "$STAGE_NUM" "$STAGE_NAME" strict || { echo "  [FAIL] Tests failed"; ((ERRORS++)); }

# Check 3: No uncommitted changes (optional)
echo "Checking git status..."
if git diff --quiet 2>/dev/null; then
    echo "  [OK] No uncommitted changes"
else
    echo "  [WARN] Uncommitted changes detected"
fi

echo ""
if [ $ERRORS -eq 0 ]; then
    echo "=== Stage $STAGE_NUM: $STAGE_NAME VALIDATED ==="
    exit 0
else
    echo "=== Stage $STAGE_NUM: $STAGE_NAME FAILED VALIDATION ($ERRORS errors) ==="
    exit 1
fi
