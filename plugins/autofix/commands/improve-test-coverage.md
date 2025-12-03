# Improve Test Coverage

Evaluate current test coverage, identify gaps, and systematically improve coverage by adding missing tests.

## Usage

```bash
# Full analysis and improvement
/improve-test-coverage

# Analysis only (no changes)
/improve-test-coverage --analyze

# Target specific directory
/improve-test-coverage src/components
```

## What This Does

1. **Analyze Coverage** - Run coverage tools and parse reports
2. **Identify Gaps** - Find untested files, functions, and code paths
3. **Prioritize** - Rank gaps by importance (critical paths first)
4. **Improve** - Add tests for identified gaps or create issues
5. **Verify** - Re-run coverage to confirm improvement

## Configuration

This command reads configuration from `CLAUDE.md`:

```markdown
## Automated Testing & Issue Management

### Regression Test Suite
```bash
npm test
```

### Coverage Command
```bash
npm run test:coverage
```

### Coverage Report
- Location: `coverage/lcov-report/index.html`
- Format: lcov
```

If no coverage configuration is found, common defaults are tried.

## Instructions

```bash
# Parse arguments
ANALYZE_ONLY=false
TARGET_PATH=""

for arg in "$@"; do
  case $arg in
    --analyze)
      ANALYZE_ONLY=true
      ;;
    *)
      TARGET_PATH="$arg"
      ;;
  esac
done

echo ""
echo "════════════════════════════════════════"
echo "  Test Coverage Analysis"
echo "  Started: $(date)"
echo "════════════════════════════════════════"
echo ""

# Load configuration from CLAUDE.md
if [ -f "CLAUDE.md" ]; then
  echo "📋 Loading configuration from CLAUDE.md"

  # Extract coverage command
  if grep -q "### Coverage Command" CLAUDE.md; then
    COVERAGE_COMMAND=$(sed -n "/### Coverage Command/,/^###/{/^\`\`\`bash$/n;p;}" CLAUDE.md | grep -v "^#" | grep -v "^\`\`\`" | grep -v "^$" | head -1)
    echo "✅ Coverage command: $COVERAGE_COMMAND"
  else
    # Try common coverage commands
    if [ -f "package.json" ]; then
      if grep -q '"test:coverage"' package.json; then
        COVERAGE_COMMAND="npm run test:coverage"
      elif grep -q '"coverage"' package.json; then
        COVERAGE_COMMAND="npm run coverage"
      else
        COVERAGE_COMMAND="npm test -- --coverage"
      fi
    elif [ -f "pytest.ini" ] || [ -f "pyproject.toml" ]; then
      COVERAGE_COMMAND="pytest --cov=. --cov-report=html"
    else
      COVERAGE_COMMAND="npm test -- --coverage"
    fi
    echo "⚠️  No coverage command found, using: $COVERAGE_COMMAND"
  fi

  # Extract coverage report location
  if grep -q "### Coverage Report" CLAUDE.md; then
    COVERAGE_REPORT=$(sed -n "/### Coverage Report/,/^###/{/Location:/p;}" CLAUDE.md | sed 's/.*`\([^`]*\)`.*/\1/' | head -1)
    echo "✅ Coverage report: $COVERAGE_REPORT"
  else
    # Try common locations
    for loc in "coverage/lcov-report/index.html" "htmlcov/index.html" "coverage/index.html"; do
      if [ -f "$loc" ]; then
        COVERAGE_REPORT="$loc"
        break
      fi
    done
    COVERAGE_REPORT="${COVERAGE_REPORT:-coverage/lcov-report/index.html}"
    echo "⚠️  No coverage report location found, using: $COVERAGE_REPORT"
  fi
else
  echo "⚠️  No CLAUDE.md found, using defaults"
  COVERAGE_COMMAND="npm test -- --coverage"
  COVERAGE_REPORT="coverage/lcov-report/index.html"
fi

echo ""
```

## Step 1: Run Coverage Analysis

```bash
echo "📊 [1/5] Running coverage analysis..."
COVERAGE_OUTPUT="/tmp/coverage-output-$(date +%s).txt"

# Run coverage command
if $COVERAGE_COMMAND 2>&1 | tee "$COVERAGE_OUTPUT"; then
  echo "✅ Coverage analysis complete"
else
  echo "⚠️  Coverage command exited with errors (may still have results)"
fi

# Extract coverage summary
echo ""
echo "Coverage Summary:"
echo "─────────────────"

# Try to extract coverage percentages (works for most frameworks)
if grep -qE "All files.*[0-9]+(\.[0-9]+)?%" "$COVERAGE_OUTPUT"; then
  grep -E "All files" "$COVERAGE_OUTPUT" | head -1
elif grep -qE "TOTAL.*[0-9]+%" "$COVERAGE_OUTPUT"; then
  grep -E "TOTAL" "$COVERAGE_OUTPUT" | head -1
elif grep -qE "Coverage:.*[0-9]+%" "$COVERAGE_OUTPUT"; then
  grep -E "Coverage:" "$COVERAGE_OUTPUT"
fi

# Extract overall percentage
OVERALL_COVERAGE=$(grep -oE '[0-9]+(\.[0-9]+)?%' "$COVERAGE_OUTPUT" | head -1 | tr -d '%')
echo ""
echo "Overall Coverage: ${OVERALL_COVERAGE:-Unknown}%"
```

## Step 2: Identify Coverage Gaps

```bash
echo ""
echo "🔍 [2/5] Identifying coverage gaps..."

# Create gaps file
GAPS_FILE="/tmp/coverage-gaps-$(date +%s).txt"
touch "$GAPS_FILE"

# Find files with low coverage from coverage output
# Handle different coverage report formats

# Jest/Istanbul format
if grep -qE "^\s*[a-zA-Z].*\|\s*[0-9]" "$COVERAGE_OUTPUT"; then
  echo "Detected Jest/Istanbul format"
  grep -E "^\s*[a-zA-Z].*\|\s*[0-9]" "$COVERAGE_OUTPUT" | while read -r line; do
    # Extract file and coverage percentage
    FILE=$(echo "$line" | awk '{print $1}')
    # Get the statement coverage (first percentage)
    STMT=$(echo "$line" | awk -F'|' '{print $2}' | tr -d ' ' | grep -oE '[0-9]+' | head -1)

    if [ -n "$STMT" ] && [ "$STMT" -lt 80 ]; then
      echo "$FILE|$STMT" >> "$GAPS_FILE"
    fi
  done
fi

# pytest-cov format
if grep -qE "^[a-zA-Z_/].*\s+[0-9]+\s+[0-9]+\s+[0-9]+%" "$COVERAGE_OUTPUT"; then
  echo "Detected pytest-cov format"
  grep -E "^[a-zA-Z_/].*\s+[0-9]+\s+[0-9]+\s+[0-9]+%" "$COVERAGE_OUTPUT" | while read -r line; do
    FILE=$(echo "$line" | awk '{print $1}')
    COV=$(echo "$line" | grep -oE '[0-9]+%' | tr -d '%')

    if [ -n "$COV" ] && [ "$COV" -lt 80 ]; then
      echo "$FILE|$COV" >> "$GAPS_FILE"
    fi
  done
fi

# Count gaps
GAP_COUNT=$(wc -l < "$GAPS_FILE" | tr -d ' ')
echo ""
echo "Found $GAP_COUNT files with coverage below 80%"
```

## Step 3: Find Untested Files

```bash
echo ""
echo "🔎 [3/5] Finding completely untested files..."

UNTESTED_FILE="/tmp/untested-files-$(date +%s).txt"
touch "$UNTESTED_FILE"

# Get source file patterns based on project type
if [ -f "package.json" ]; then
  # JavaScript/TypeScript project
  SRC_PATTERN="*.{js,jsx,ts,tsx}"
  TEST_PATTERNS=("*.test.*" "*.spec.*" "__tests__/*")
  SRC_DIRS=("src" "lib" "app" "components")
elif [ -f "pyproject.toml" ] || [ -f "setup.py" ]; then
  # Python project
  SRC_PATTERN="*.py"
  TEST_PATTERNS=("test_*.py" "*_test.py")
  SRC_DIRS=("src" "." "lib")
else
  # Default
  SRC_PATTERN="*.{js,ts,py}"
  TEST_PATTERNS=("*.test.*" "*.spec.*" "test_*")
  SRC_DIRS=("src" "lib")
fi

# Find source files without corresponding test files
for dir in "${SRC_DIRS[@]}"; do
  if [ -d "$dir" ]; then
    # Apply target path filter if provided
    SEARCH_PATH="${TARGET_PATH:-$dir}"

    find "$SEARCH_PATH" -name "*.ts" -o -name "*.tsx" -o -name "*.js" -o -name "*.jsx" -o -name "*.py" 2>/dev/null | \
    grep -v node_modules | \
    grep -v __tests__ | \
    grep -v ".test." | \
    grep -v ".spec." | \
    grep -v "test_" | \
    grep -v "_test." | \
    while read -r src_file; do
      # Get base name without extension
      base=$(basename "$src_file" | sed 's/\.[^.]*$//')

      # Check if test file exists
      has_test=false
      for pattern in "**/${base}.test.*" "**/${base}.spec.*" "**/test_${base}.*" "**/${base}_test.*"; do
        if compgen -G "$pattern" > /dev/null 2>&1; then
          has_test=true
          break
        fi
      done

      if [ "$has_test" = false ]; then
        # Check if file has significant code (not just types/interfaces)
        lines=$(wc -l < "$src_file" | tr -d ' ')
        if [ "$lines" -gt 10 ]; then
          echo "$src_file|0|$lines lines" >> "$UNTESTED_FILE"
        fi
      fi
    done
  fi
done

UNTESTED_COUNT=$(wc -l < "$UNTESTED_FILE" | tr -d ' ')
echo "Found $UNTESTED_COUNT source files without test files"
```

## Step 4: Prioritize Gaps

```bash
echo ""
echo "📋 [4/5] Prioritizing coverage gaps..."

PRIORITY_FILE="/tmp/coverage-priorities-$(date +%s).txt"

# Combine and prioritize gaps
cat > "$PRIORITY_FILE" << EOF
# Test Coverage Improvement Priorities
# Generated: $(date)
# Overall Coverage: ${OVERALL_COVERAGE:-Unknown}%

## Critical Priority (P0)
Files in critical paths with low coverage:

EOF

# Identify critical files (auth, security, payments, data)
cat "$GAPS_FILE" "$UNTESTED_FILE" 2>/dev/null | sort -u | while read -r line; do
  FILE=$(echo "$line" | cut -d'|' -f1)
  COV=$(echo "$line" | cut -d'|' -f2)

  if echo "$FILE" | grep -qiE "auth|security|login|payment|checkout|crypt"; then
    echo "- $FILE (${COV}% coverage) - CRITICAL PATH" >> "$PRIORITY_FILE"
  fi
done

cat >> "$PRIORITY_FILE" << EOF

## High Priority (P1)
Core business logic with low coverage:

EOF

cat "$GAPS_FILE" "$UNTESTED_FILE" 2>/dev/null | sort -u | while read -r line; do
  FILE=$(echo "$line" | cut -d'|' -f1)
  COV=$(echo "$line" | cut -d'|' -f2)

  if echo "$FILE" | grep -qiE "service|handler|controller|manager|repository|store"; then
    if ! echo "$FILE" | grep -qiE "auth|security|login|payment|checkout|crypt"; then
      echo "- $FILE (${COV}% coverage)" >> "$PRIORITY_FILE"
    fi
  fi
done

cat >> "$PRIORITY_FILE" << EOF

## Medium Priority (P2)
Utility and helper files with low coverage:

EOF

cat "$GAPS_FILE" "$UNTESTED_FILE" 2>/dev/null | sort -u | while read -r line; do
  FILE=$(echo "$line" | cut -d'|' -f1)
  COV=$(echo "$line" | cut -d'|' -f2)

  if echo "$FILE" | grep -qiE "util|helper|hook|component|middleware"; then
    echo "- $FILE (${COV}% coverage)" >> "$PRIORITY_FILE"
  fi
done

cat >> "$PRIORITY_FILE" << EOF

## Lower Priority (P3)
Other files with low coverage:

EOF

cat "$GAPS_FILE" "$UNTESTED_FILE" 2>/dev/null | sort -u | while read -r line; do
  FILE=$(echo "$line" | cut -d'|' -f1)
  COV=$(echo "$line" | cut -d'|' -f2)

  if ! echo "$FILE" | grep -qiE "auth|security|login|payment|checkout|crypt|service|handler|controller|manager|repository|store|util|helper|hook|component|middleware"; then
    echo "- $FILE (${COV}% coverage)" >> "$PRIORITY_FILE"
  fi
done

echo "Priority file created: $PRIORITY_FILE"
cat "$PRIORITY_FILE"
```

## Step 5: Improve Coverage (or Create Issues)

If `--analyze` was specified, stop here. Otherwise, proceed to improve coverage.

```bash
if [ "$ANALYZE_ONLY" = true ]; then
  echo ""
  echo "════════════════════════════════════════"
  echo "  Analysis Complete (--analyze mode)"
  echo "════════════════════════════════════════"
  echo ""
  echo "📊 Overall Coverage: ${OVERALL_COVERAGE:-Unknown}%"
  echo "📋 Files needing coverage: $((GAP_COUNT + UNTESTED_COUNT))"
  echo "📄 Priority file: $PRIORITY_FILE"
  echo ""
  echo "Run without --analyze to create tests for gaps."
  exit 0
fi

echo ""
echo "🔧 [5/5] Improving test coverage..."
```

### Create GitHub Issues for Coverage Gaps

For each priority level, create issues or directly add tests:

```bash
# Check if we should create issues or implement directly
IMPLEMENT_DIRECTLY=true

# If more than 10 files need coverage, create issues instead
TOTAL_GAPS=$((GAP_COUNT + UNTESTED_COUNT))
if [ "$TOTAL_GAPS" -gt 10 ]; then
  echo "Found $TOTAL_GAPS files needing coverage - creating GitHub issues..."
  IMPLEMENT_DIRECTLY=false
fi

if [ "$IMPLEMENT_DIRECTLY" = false ]; then
  # Create umbrella issue for test coverage improvement
  ISSUE_BODY=$(cat << EOF
## Test Coverage Improvement

**Current Coverage**: ${OVERALL_COVERAGE:-Unknown}%
**Target Coverage**: 80%+
**Files Needing Coverage**: $TOTAL_GAPS

## Priority Breakdown

$(cat "$PRIORITY_FILE" | tail -n +5)

## Implementation Plan

1. Start with P0 (critical path) files
2. Progress through P1 and P2 as coverage improves
3. Re-run coverage after each batch of tests
4. Close this issue when overall coverage reaches 80%+

## Commands

\`\`\`bash
# Run coverage analysis
/improve-test-coverage --analyze

# Run and improve coverage
/improve-test-coverage
\`\`\`

---
Generated by /improve-test-coverage
EOF
)

  gh issue create \
    --label "enhancement,testing,P2" \
    --title "Improve test coverage (currently ${OVERALL_COVERAGE:-Unknown}%)" \
    --body "$ISSUE_BODY" 2>/dev/null || echo "⚠️ Could not create GitHub issue"

  echo "✅ Created GitHub issue for test coverage improvement"
else
  echo "Implementing test coverage improvements directly..."

  # Get highest priority untested file
  FIRST_GAP=$(head -1 "$UNTESTED_FILE" | cut -d'|' -f1)

  if [ -n "$FIRST_GAP" ] && [ -f "$FIRST_GAP" ]; then
    echo ""
    echo "Starting with: $FIRST_GAP"
    echo ""
    echo "File contents:"
    echo "─────────────────"
    head -50 "$FIRST_GAP"
    echo ""
    echo "─────────────────"
    echo ""
    echo "📝 Creating test file for $FIRST_GAP..."
    echo ""
    echo "Use superpowers:test-driven-development skill to create tests for this file."
    echo "The test should cover:"
    echo "  - All exported functions/classes"
    echo "  - Edge cases and error conditions"
    echo "  - Integration with dependencies"
    echo ""
  fi
fi
```

## Output Summary

```bash
echo ""
echo "════════════════════════════════════════"
echo "  Test Coverage Analysis Complete"
echo "════════════════════════════════════════"
echo ""
echo "📊 Overall Coverage: ${OVERALL_COVERAGE:-Unknown}%"
echo "📋 Files with low coverage: $GAP_COUNT"
echo "📋 Files without tests: $UNTESTED_COUNT"
echo "📄 Priority file: $PRIORITY_FILE"
echo ""

if [ "$IMPLEMENT_DIRECTLY" = true ]; then
  echo "Next Steps:"
  echo "1. Use superpowers:test-driven-development to add tests"
  echo "2. Run /improve-test-coverage --analyze to verify improvement"
  echo "3. Repeat until coverage reaches 80%+"
else
  echo "GitHub issue created for tracking coverage improvement."
  echo "Use /fix-github to work through coverage improvements."
fi
echo ""
```

## Integration with /fix-github

This command can be invoked by `/fix-github` when:
- All tests pass and enhancements are being proposed
- Test coverage is identified as an improvement area
- A coverage-related issue is being worked on

When called from `/fix-github`, the command operates in "improvement mode" - it identifies the next highest-priority file needing coverage and provides context for test creation.

## Standalone Usage

Run independently to:
- Audit current test coverage
- Identify gaps before a release
- Plan testing sprint work
- Generate coverage improvement issues

---

**Ready to analyze and improve test coverage.**
