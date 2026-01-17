---
description: Improve test coverage using persistent coverage report
---

# Improve Test Coverage

Evaluate and improve test coverage using a persistent `test-coverage.md` report. This report-driven approach allows fast iteration without re-running full coverage analysis each time.

## Usage

```bash
# Fast mode: Use existing test-coverage.md report
/improve-test-coverage

# Analysis only (no changes)
/improve-test-coverage --analyze

# Refresh: Regenerate test-coverage.md from scratch
/improve-test-coverage --refresh

# Target specific area by priority
/improve-test-coverage --priority P0

# Target specific directory
/improve-test-coverage src/components
```

## How It Works

### Fast Path (Default)

When `test-coverage.md` exists:

1. **Read Report** - Parse existing test-coverage.md
2. **Find Lowest Coverage** - Identify area with lowest coverage (respecting priority)
3. **Add Tests** - Create tests for files in that area
4. **Verify** - Run tests for just that area
5. **Update Section** - Update only the relevant section in test-coverage.md

### Full Analysis Path

When `test-coverage.md` doesn't exist OR `--refresh` is specified:

1. **Run Full Coverage** - Execute coverage tools
2. **Categorize Files** - Group by functional area and priority
3. **Generate Report** - Create/update test-coverage.md
4. **Continue** - Proceed with fast path

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

## Instructions

### Initialize

```bash
# Parse arguments
ANALYZE_ONLY=false
REFRESH_MODE=false
TARGET_PATH=""
TARGET_PRIORITY=""

for arg in "$@"; do
  case $arg in
    --analyze)
      ANALYZE_ONLY=true
      ;;
    --refresh)
      REFRESH_MODE=true
      ;;
    --priority)
      shift
      TARGET_PRIORITY="$1"
      ;;
    P0|P1|P2|P3)
      TARGET_PRIORITY="$arg"
      ;;
    *)
      if [ -z "$TARGET_PATH" ]; then
        TARGET_PATH="$arg"
      fi
      ;;
  esac
done

TODAY=$(date +%Y-%m-%d)

echo ""
echo "════════════════════════════════════════"
echo "  Test Coverage Improvement"
echo "  Started: $(date)"
echo "════════════════════════════════════════"
echo ""
```

### Load Configuration

```bash
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
    elif [ -f "go.mod" ]; then
      COVERAGE_COMMAND="go test -coverprofile=coverage.out ./..."
    else
      COVERAGE_COMMAND="npm test -- --coverage"
    fi
    echo "⚠️  No coverage command found, using: $COVERAGE_COMMAND"
  fi

  # Extract test command for targeted testing
  if grep -q "### Regression Test Suite" CLAUDE.md; then
    TEST_COMMAND=$(sed -n "/### Regression Test Suite/,/^###/{/^\`\`\`bash$/n;p;}" CLAUDE.md | grep -v "^#" | grep -v "^\`\`\`" | grep -v "^$" | head -1)
  else
    TEST_COMMAND="npm test"
  fi
  echo "✅ Test command: $TEST_COMMAND"
else
  echo "⚠️  No CLAUDE.md found, using defaults"
  COVERAGE_COMMAND="npm test -- --coverage"
  TEST_COMMAND="npm test"
fi

COVERAGE_REPORT="test-coverage.md"
echo ""
```

## Step 1: Check for Existing Coverage Report

```bash
echo "📊 [1/5] Checking for existing coverage report..."

if [ -f "$COVERAGE_REPORT" ] && [ "$REFRESH_MODE" = false ]; then
  echo "✅ Found existing test-coverage.md"
  echo ""
  echo "Using FAST PATH: Reading from existing report"
  echo "(Use --refresh to regenerate from scratch)"
  echo ""
  USE_FAST_PATH=true
else
  if [ "$REFRESH_MODE" = true ]; then
    echo "🔄 Refresh mode: Will regenerate test-coverage.md"
  else
    echo "⚠️  No test-coverage.md found, will create one"
  fi
  USE_FAST_PATH=false
fi
```

## Step 2: Fast Path - Parse Existing Report

If using fast path, parse the existing report to find the lowest coverage area:

```bash
if [ "$USE_FAST_PATH" = true ]; then
  echo ""
  echo "🔍 [2/5] Parsing coverage report..."

  # Extract all section coverage from HTML comments
  # Format: <!-- COVERAGE: XX% | FILES: X/Y | VERIFIED: YYYY-MM-DD -->
  SECTIONS_FILE="/tmp/coverage-sections-$(date +%s).txt"

  grep -E "<!-- COVERAGE: [0-9]+%" "$COVERAGE_REPORT" | while read -r line; do
    # Extract coverage percentage
    COV=$(echo "$line" | grep -oE "COVERAGE: [0-9]+" | grep -oE "[0-9]+")
    FILES=$(echo "$line" | grep -oE "FILES: [0-9]+/[0-9]+" | sed 's/FILES: //')
    VERIFIED=$(echo "$line" | grep -oE "VERIFIED: [0-9-]+" | sed 's/VERIFIED: //')

    # Find the section header (### Name) that precedes this comment
    SECTION_LINE=$(grep -n "$line" "$COVERAGE_REPORT" | head -1 | cut -d: -f1)
    SECTION_NAME=$(head -n "$SECTION_LINE" "$COVERAGE_REPORT" | grep "^### " | tail -1 | sed 's/^### //')

    # Find priority from ## P0/P1/P2/P3 header
    PRIORITY=$(head -n "$SECTION_LINE" "$COVERAGE_REPORT" | grep "^## P[0-3]" | tail -1 | grep -oE "P[0-3]")

    if [ -n "$COV" ] && [ -n "$SECTION_NAME" ]; then
      echo "$PRIORITY|$COV|$SECTION_NAME|$FILES|$VERIFIED" >> "$SECTIONS_FILE"
    fi
  done

  # Display current coverage summary
  echo ""
  echo "Current Coverage by Section:"
  echo "────────────────────────────"
  if [ -f "$SECTIONS_FILE" ]; then
    sort -t'|' -k1,1 -k2,2n "$SECTIONS_FILE" | while IFS='|' read -r priority cov name files verified; do
      printf "  %-4s %-30s %3s%% (%s)\n" "$priority" "$name" "$cov" "$files"
    done
  fi
  echo ""

  # Find lowest coverage section (respecting priority filter)
  if [ -n "$TARGET_PRIORITY" ]; then
    LOWEST=$(grep "^$TARGET_PRIORITY|" "$SECTIONS_FILE" 2>/dev/null | sort -t'|' -k2,2n | head -1)
  else
    # Sort by priority first, then by coverage
    LOWEST=$(sort -t'|' -k1,1 -k2,2n "$SECTIONS_FILE" 2>/dev/null | head -1)
  fi

  if [ -n "$LOWEST" ]; then
    LOWEST_PRIORITY=$(echo "$LOWEST" | cut -d'|' -f1)
    LOWEST_COV=$(echo "$LOWEST" | cut -d'|' -f2)
    LOWEST_SECTION=$(echo "$LOWEST" | cut -d'|' -f3)

    echo "📌 Lowest coverage area: $LOWEST_SECTION ($LOWEST_COV%) [$LOWEST_PRIORITY]"
  else
    echo "✅ All sections have coverage data"
    echo "   Run with --refresh to update all sections"
  fi
fi
```

## Step 3: Full Analysis Path - Run Coverage Tools

If not using fast path, run full coverage analysis:

```bash
if [ "$USE_FAST_PATH" = false ]; then
  echo ""
  echo "📊 [2/5] Running full coverage analysis..."
  COVERAGE_OUTPUT="/tmp/coverage-output-$(date +%s).txt"

  # Run coverage command
  if $COVERAGE_COMMAND 2>&1 | tee "$COVERAGE_OUTPUT"; then
    echo "✅ Coverage analysis complete"
  else
    echo "⚠️  Coverage command exited with errors (may still have results)"
  fi

  # Extract overall coverage
  OVERALL_COVERAGE=$(grep -oE '[0-9]+(\.[0-9]+)?%' "$COVERAGE_OUTPUT" | head -1 | tr -d '%')
  echo ""
  echo "Overall Coverage: ${OVERALL_COVERAGE:-Unknown}%"
fi
```

## Step 4: Generate/Update Coverage Report

When `test-coverage.md` doesn't exist, create it after running coverage analysis. This report becomes the source of truth for subsequent runs.

```bash
if [ "$USE_FAST_PATH" = false ]; then
  echo ""
  echo "📝 [3/5] Generating test-coverage.md..."
  echo "   (This file will be created and committed for future fast-path usage)"

  # Categorize source files by functional area
  CATEGORIES_FILE="/tmp/coverage-categories-$(date +%s).txt"

  # Find all source files and categorize them
  find . -type f \( -name "*.ts" -o -name "*.tsx" -o -name "*.js" -o -name "*.jsx" -o -name "*.py" -o -name "*.go" \) \
    -not -path "*/node_modules/*" \
    -not -path "*/.git/*" \
    -not -path "*/dist/*" \
    -not -path "*/build/*" \
    -not -name "*.test.*" \
    -not -name "*.spec.*" \
    -not -name "test_*" \
    2>/dev/null | while read -r file; do

    LINES=$(wc -l < "$file" | tr -d ' ')
    [ "$LINES" -lt 5 ] && continue  # Skip tiny files

    # Determine category and priority
    if echo "$file" | grep -qiE "auth|login|security|crypt|session|token|password"; then
      echo "P0|Authentication & Security|$file|$LINES" >> "$CATEGORIES_FILE"
    elif echo "$file" | grep -qiE "db|database|repository|model|entity|schema|migration"; then
      echo "P0|Data Access & Persistence|$file|$LINES" >> "$CATEGORIES_FILE"
    elif echo "$file" | grep -qiE "service|manager|processor|engine|core|domain"; then
      echo "P1|Core Business Logic|$file|$LINES" >> "$CATEGORIES_FILE"
    elif echo "$file" | grep -qiE "handler|controller|route|api|endpoint"; then
      echo "P1|API Handlers|$file|$LINES" >> "$CATEGORIES_FILE"
    elif echo "$file" | grep -qiE "util|helper|lib|common|shared"; then
      echo "P2|Utilities & Helpers|$file|$LINES" >> "$CATEGORIES_FILE"
    elif echo "$file" | grep -qiE "component|view|page|screen|widget"; then
      echo "P2|UI Components|$file|$LINES" >> "$CATEGORIES_FILE"
    elif echo "$file" | grep -qiE "config|setting|constant|env"; then
      echo "P3|Configuration|$file|$LINES" >> "$CATEGORIES_FILE"
    elif echo "$file" | grep -qiE "type|interface|dto|schema\."; then
      echo "P3|Types & Interfaces|$file|$LINES" >> "$CATEGORIES_FILE"
    else
      echo "P3|Other|$file|$LINES" >> "$CATEGORIES_FILE"
    fi
  done

  # Check for test files
  check_has_test() {
    local src_file="$1"
    local base=$(basename "$src_file" | sed 's/\.[^.]*$//')

    # Check common test file patterns
    for pattern in "./${base}.test."* "./${base}.spec."* "./test_${base}."* "./**/__tests__/${base}."*; do
      if compgen -G "$pattern" > /dev/null 2>&1; then
        return 0
      fi
    done
    return 1
  }

  # Generate the report
  cat > "$COVERAGE_REPORT" << 'HEADER'
# Test Coverage Report

HEADER

  echo "**Last Full Analysis**: $TODAY" >> "$COVERAGE_REPORT"
  echo "**Overall Coverage**: ${OVERALL_COVERAGE:-0}%" >> "$COVERAGE_REPORT"
  echo "**Target Coverage**: 80%" >> "$COVERAGE_REPORT"
  echo "" >> "$COVERAGE_REPORT"
  echo "## Summary" >> "$COVERAGE_REPORT"
  echo "" >> "$COVERAGE_REPORT"
  echo "| Priority | Area | Coverage | Files | Last Verified |" >> "$COVERAGE_REPORT"
  echo "|----------|------|----------|-------|---------------|" >> "$COVERAGE_REPORT"

  # Generate summary table (will be filled in as we process sections)
  SUMMARY_FILE="/tmp/coverage-summary-$(date +%s).txt"

  # Process each priority level
  for PRIORITY in P0 P1 P2 P3; do
    PRIORITY_NAME=""
    case $PRIORITY in
      P0) PRIORITY_NAME="Critical Priority" ;;
      P1) PRIORITY_NAME="High Priority" ;;
      P2) PRIORITY_NAME="Medium Priority" ;;
      P3) PRIORITY_NAME="Lower Priority" ;;
    esac

    # Get unique categories for this priority
    CATS=$(grep "^$PRIORITY|" "$CATEGORIES_FILE" 2>/dev/null | cut -d'|' -f2 | sort -u)

    if [ -n "$CATS" ]; then
      # Add to main report later, first collect data
      :
    fi
  done

  # Build full report with all sections
  echo "" >> "$COVERAGE_REPORT"
  echo "---" >> "$COVERAGE_REPORT"

  for PRIORITY in P0 P1 P2 P3; do
    PRIORITY_NAME=""
    case $PRIORITY in
      P0) PRIORITY_NAME="Critical Priority" ;;
      P1) PRIORITY_NAME="High Priority" ;;
      P2) PRIORITY_NAME="Medium Priority" ;;
      P3) PRIORITY_NAME="Lower Priority" ;;
    esac

    CATS=$(grep "^$PRIORITY|" "$CATEGORIES_FILE" 2>/dev/null | cut -d'|' -f2 | sort -u)

    if [ -n "$CATS" ]; then
      echo "" >> "$COVERAGE_REPORT"
      echo "## $PRIORITY: $PRIORITY_NAME" >> "$COVERAGE_REPORT"

      echo "$CATS" | while read -r CAT; do
        FILES_IN_CAT=$(grep "^$PRIORITY|$CAT|" "$CATEGORIES_FILE" 2>/dev/null)
        TOTAL_FILES=$(echo "$FILES_IN_CAT" | wc -l | tr -d ' ')
        TESTED_FILES=0

        echo "" >> "$COVERAGE_REPORT"
        echo "### $CAT" >> "$COVERAGE_REPORT"
        echo "<!-- COVERAGE: 0% | FILES: 0/$TOTAL_FILES | VERIFIED: $TODAY -->" >> "$COVERAGE_REPORT"
        echo "" >> "$COVERAGE_REPORT"
        echo "**Coverage**: 0%" >> "$COVERAGE_REPORT"
        echo "**Status**: Needs Analysis" >> "$COVERAGE_REPORT"
        echo "**Last Verified**: $TODAY" >> "$COVERAGE_REPORT"
        echo "" >> "$COVERAGE_REPORT"
        echo "| File | Coverage | Lines | Has Test | Notes |" >> "$COVERAGE_REPORT"
        echo "|------|----------|-------|----------|-------|" >> "$COVERAGE_REPORT"

        echo "$FILES_IN_CAT" | while IFS='|' read -r _ _ file lines; do
          HAS_TEST="No"
          if check_has_test "$file"; then
            HAS_TEST="Yes"
            TESTED_FILES=$((TESTED_FILES + 1))
          fi
          echo "| \`$file\` | 0% | $lines | $HAS_TEST | |" >> "$COVERAGE_REPORT"
        done

        echo "" >> "$COVERAGE_REPORT"
        echo "**Test Files**:" >> "$COVERAGE_REPORT"
        echo "- None identified" >> "$COVERAGE_REPORT"
        echo "" >> "$COVERAGE_REPORT"
        echo "---" >> "$COVERAGE_REPORT"

        # Add to summary
        echo "$PRIORITY|$CAT|0%|0/$TOTAL_FILES|$TODAY" >> "$SUMMARY_FILE"
      done
    fi
  done

  # Add coverage history section
  echo "" >> "$COVERAGE_REPORT"
  echo "## Coverage History" >> "$COVERAGE_REPORT"
  echo "" >> "$COVERAGE_REPORT"
  echo "| Date | Overall | P0 | P1 | P2 | P3 | Notes |" >> "$COVERAGE_REPORT"
  echo "|------|---------|----|----|----|----|-------|" >> "$COVERAGE_REPORT"
  echo "| $TODAY | ${OVERALL_COVERAGE:-0}% | - | - | - | - | Initial analysis |" >> "$COVERAGE_REPORT"

  # Add instructions
  cat >> "$COVERAGE_REPORT" << 'FOOTER'

---

## How to Update This Report

### After Adding Tests

1. Run tests for the specific area you modified:
   ```bash
   npm test -- --coverage --collectCoverageFrom='src/auth/**'
   ```

2. Update the relevant section:
   - Update the coverage percentage in the HTML comment: `<!-- COVERAGE: XX% | ... -->`
   - Update the **Coverage** field
   - Update **Last Verified** date
   - Update the file table with new coverage numbers
   - Add test file to **Test Files** list

3. Update the Summary table at the top

### Full Refresh

Run `/improve-test-coverage --refresh` to regenerate this entire report from scratch.

### Section Comment Format

Each section has a parseable comment:
```
<!-- COVERAGE: XX% | FILES: X/Y | VERIFIED: YYYY-MM-DD -->
```

- `COVERAGE`: Current coverage percentage for this area
- `FILES`: Files with tests / Total files in area
- `VERIFIED`: Date this section was last verified

---

*Generated by /improve-test-coverage*
FOOTER

  echo "✅ Generated test-coverage.md"

  # Now set up for the improvement phase
  LOWEST_SECTION=$(head -1 "$SUMMARY_FILE" 2>/dev/null | cut -d'|' -f2)
  LOWEST_COV="0"
  LOWEST_PRIORITY="P0"
fi
```

## Step 5: Improve Coverage (or Stop if Analyze Mode)

```bash
if [ "$ANALYZE_ONLY" = true ]; then
  echo ""
  echo "════════════════════════════════════════"
  echo "  Analysis Complete (--analyze mode)"
  echo "════════════════════════════════════════"
  echo ""

  if [ -f "$COVERAGE_REPORT" ]; then
    # Show summary from report
    echo "📊 Coverage Report: $COVERAGE_REPORT"
    echo ""
    head -30 "$COVERAGE_REPORT"
  fi

  echo ""
  echo "Run without --analyze to improve coverage."
  exit 0
fi

echo ""
echo "🔧 [4/5] Improving test coverage..."
echo ""
```

### Identify Files to Test

```bash
if [ -n "$LOWEST_SECTION" ]; then
  echo "Target Section: $LOWEST_SECTION"
  echo ""

  # Extract files from this section in test-coverage.md
  SECTION_START=$(grep -n "### $LOWEST_SECTION" "$COVERAGE_REPORT" | head -1 | cut -d: -f1)

  if [ -n "$SECTION_START" ]; then
    # Find the next section or end of file
    SECTION_END=$(tail -n +"$((SECTION_START + 1))" "$COVERAGE_REPORT" | grep -n "^### " | head -1 | cut -d: -f1)
    [ -z "$SECTION_END" ] && SECTION_END=1000
    SECTION_END=$((SECTION_START + SECTION_END))

    # Extract file paths from table rows
    FILES_TO_TEST=$(sed -n "${SECTION_START},${SECTION_END}p" "$COVERAGE_REPORT" | \
      grep "^\| \`" | \
      grep -oE "\`[^\`]+\`" | \
      tr -d '`' | \
      head -5)

    echo "Files needing tests:"
    echo "$FILES_TO_TEST" | while read -r file; do
      echo "  - $file"
    done
    echo ""

    # Get first untested file
    FIRST_FILE=$(echo "$FILES_TO_TEST" | head -1)

    if [ -n "$FIRST_FILE" ] && [ -f "$FIRST_FILE" ]; then
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      echo "Creating tests for: $FIRST_FILE"
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      echo ""
      echo "File preview (first 50 lines):"
      echo "────────────────────────────────"
      head -50 "$FIRST_FILE"
      echo "────────────────────────────────"
      echo ""
      echo "📝 TASK: Create comprehensive tests for this file."
      echo ""
      echo "Test requirements:"
      echo "  1. Cover all exported functions/classes"
      echo "  2. Include edge cases and error conditions"
      echo "  3. Test integration with dependencies"
      echo "  4. Follow existing test patterns in the codebase"
      echo ""
    fi
  fi
fi
```

### After Creating Tests - Update Report

After tests are created and verified, update the coverage report:

```bash
echo ""
echo "📝 [5/5] After adding tests, update the report..."
echo ""
echo "Once tests are created and passing:"
echo ""
echo "1. Run targeted coverage for the section:"
echo "   $TEST_COMMAND -- --coverage --collectCoverageFrom='${FIRST_FILE%/*}/**'"
echo ""
echo "2. Update test-coverage.md section '$LOWEST_SECTION':"
echo "   - Update <!-- COVERAGE: XX% | FILES: X/Y | VERIFIED: $TODAY -->"
echo "   - Update **Coverage**: XX%"
echo "   - Update **Last Verified**: $TODAY"
echo "   - Update file coverage in table"
echo "   - Add test file to **Test Files** list"
echo ""
echo "3. Update Summary table at top of report"
echo ""
```

## Output Summary

```bash
echo ""
echo "════════════════════════════════════════"
echo "  Test Coverage Improvement"
echo "════════════════════════════════════════"
echo ""
echo "📄 Coverage Report: $COVERAGE_REPORT"
echo "📌 Target Section: ${LOWEST_SECTION:-None}"
echo "📌 Target Priority: ${LOWEST_PRIORITY:-None}"
echo "📌 Current Coverage: ${LOWEST_COV:-0}%"
echo ""

if [ "$USE_FAST_PATH" = true ]; then
  echo "Mode: FAST PATH (used existing report)"
else
  echo "Mode: FULL ANALYSIS (generated new report)"
fi

echo ""
echo "Next Steps:"
echo "1. Create tests for identified files"
echo "2. Run: $TEST_COMMAND to verify tests pass"
echo "3. Update the '$LOWEST_SECTION' section in test-coverage.md"
echo "4. Run /improve-test-coverage again to continue"

# If we just created test-coverage.md, remind to commit it
if [ "$USE_FAST_PATH" = false ] && [ -f "$COVERAGE_REPORT" ]; then
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "📄 IMPORTANT: test-coverage.md was created"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "Commit this file to enable fast-path for future runs:"
  echo "  git add test-coverage.md"
  echo "  git commit -m 'Add test coverage report'"
  echo ""
  echo "Future runs will use this report instead of re-analyzing coverage."
fi
echo ""
```

## Integration with /fix-github

This command integrates with `/fix-github` workflow:

- When called from `/fix-github`, operates in improvement mode
- Uses existing test-coverage.md for fast iteration
- Updates report after each improvement cycle

## Workflow Benefits

### Speed Improvement

| Mode | What Happens | Time |
|------|--------------|------|
| Fast Path | Read report → Pick area → Add tests → Update section | Fast |
| Full Analysis | Run coverage → Categorize → Generate report → Add tests | Slower |

### When to Use Each Mode

- **Default**: Uses fast path when test-coverage.md exists
- **--refresh**: Forces full analysis, regenerates entire report
- **--analyze**: Shows current state without making changes
- **--priority P0**: Focus on specific priority level

---

**Ready to analyze and improve test coverage.**
