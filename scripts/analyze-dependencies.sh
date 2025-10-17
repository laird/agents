#!/bin/bash
# scripts/analyze-dependencies.sh - Analyze project dependencies for parallelization
# Usage: ./scripts/analyze-dependencies.sh "src/RawRabbit.Operations.*"

set -e

STAGE_PROJECTS=$1

if [ -z "$STAGE_PROJECTS" ]; then
    echo "Usage: $0 <project-pattern>"
    echo "Example: $0 \"src/RawRabbit.Operations.*\""
    exit 1
fi

echo "🔍 Analyzing dependencies for parallel execution..."
echo ""

# Get all project files matching pattern
PROJECTS=$(find $STAGE_PROJECTS -name "*.csproj" 2>/dev/null | sort)

if [ -z "$PROJECTS" ]; then
    echo "❌ No projects found matching pattern: $STAGE_PROJECTS"
    exit 1
fi

PROJECT_COUNT=$(echo "$PROJECTS" | wc -l)

echo "📊 Projects in scope: $PROJECT_COUNT"
for proj in $PROJECTS; do
    PROJECT_NAME=$(basename "$proj" .csproj)
    echo "  - $PROJECT_NAME"
done
echo ""

echo "🔗 Dependency Analysis:"
LEVEL_0_COUNT=0
LEVEL_N_COUNT=0

for proj in $PROJECTS; do
    PROJECT_NAME=$(basename "$proj" .csproj)

    # Extract ProjectReference dependencies
    DEPS=$(grep -h "<ProjectReference" "$proj" 2>/dev/null | sed 's/.*Include="[^"]*\/\([^/]*\)\.csproj".*/\1/' || true)

    # Check if dependencies are in-stage (part of current pattern)
    IN_STAGE_DEPS=""
    if [ -n "$DEPS" ]; then
        for dep in $DEPS; do
            # Check if this dependency is in our project list
            if echo "$PROJECTS" | grep -q "$dep"; then
                IN_STAGE_DEPS="$IN_STAGE_DEPS $dep"
            fi
        done
    fi

    if [ -z "$IN_STAGE_DEPS" ]; then
        echo "  ✅ $PROJECT_NAME: No in-stage dependencies (Level 0 - Fully parallel)"
        ((LEVEL_0_COUNT++))
    else
        echo "  ⚠️  $PROJECT_NAME: Depends on:$IN_STAGE_DEPS (Level N - Analyze carefully)"
        ((LEVEL_N_COUNT++))
    fi
done
echo ""

echo "💡 Recommendation:"
if [ $LEVEL_0_COUNT -eq $PROJECT_COUNT ]; then
    echo "  ✅ ALL $PROJECT_COUNT projects are at Level 0 (no cross-dependencies)"
    echo "  🚀 Spawn $PROJECT_COUNT parallel agents in SINGLE message"

    # Calculate time savings (assuming 15 min per project)
    SEQUENTIAL_TIME=$((PROJECT_COUNT * 15))
    PARALLEL_TIME=20  # 15 min + 5 min overhead
    SAVINGS=$((SEQUENTIAL_TIME - PARALLEL_TIME))
    PERCENT_SAVINGS=$((SAVINGS * 100 / SEQUENTIAL_TIME))

    echo "  ⏱️  Time savings: ~$SAVINGS minutes ($PERCENT_SAVINGS% faster)"
elif [ $LEVEL_0_COUNT -gt 0 ]; then
    echo "  ⚙️  Mixed dependency levels detected:"
    echo "     - Level 0 (parallel): $LEVEL_0_COUNT projects"
    echo "     - Level N (sequential): $LEVEL_N_COUNT projects"
    echo "  📋 Strategy:"
    echo "     1. Spawn $LEVEL_0_COUNT parallel agents for Level 0 projects"
    echo "     2. Execute Level N projects after Level 0 completes"
else
    echo "  ⚠️  All projects have in-stage dependencies"
    echo "  📋 Analyze dependency graph to determine execution order"
    echo "  ℹ️  Consider sequential execution or smaller batches"
fi
echo ""

echo "✅ Analysis complete!"
