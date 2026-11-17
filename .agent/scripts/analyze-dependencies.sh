#!/bin/bash
# analyze-dependencies.sh - Analyze project dependencies
#
# Usage: ./scripts/analyze-dependencies.sh [pattern]
#
# Analyzes dependencies for the specified pattern or entire project.

set -e

PATTERN="${1:-}"

echo "=== Dependency Analysis ==="
echo "Pattern: ${PATTERN:-<all>}"
echo ""

# Check for common dependency files
if [ -f "package.json" ]; then
    echo "Node.js dependencies found (package.json)"
    if command -v npm &> /dev/null; then
        npm ls --depth=0 2>/dev/null || true
    fi
elif [ -f "requirements.txt" ]; then
    echo "Python dependencies found (requirements.txt)"
    cat requirements.txt
elif [ -f "*.csproj" ] 2>/dev/null || [ -f "*.sln" ] 2>/dev/null; then
    echo ".NET project found"
    find . -name "*.csproj" -exec grep -h "<PackageReference" {} \; 2>/dev/null | sort -u || true
elif [ -f "go.mod" ]; then
    echo "Go dependencies found (go.mod)"
    cat go.mod
elif [ -f "Cargo.toml" ]; then
    echo "Rust dependencies found (Cargo.toml)"
    grep -A 100 "\[dependencies\]" Cargo.toml | grep -B 100 "^\[" | head -n -1 || true
else
    echo "No recognized dependency file found."
    echo "Supported: package.json, requirements.txt, *.csproj, go.mod, Cargo.toml"
fi

echo ""
echo "=== Analysis Complete ==="
