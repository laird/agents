#!/bin/bash
# Guards the REPORT_DIR selection in regression-test.sh.
#
# CLAUDE.md contains several "Location: " lines. Taking the first global match
# picks the *Unit Tests* location (`tests/test_*.sh`) instead of the *Test
# Reports* one, and the script then mkdir's that verbatim — creating a directory
# literally named `tests/test_*.sh`. That directory shadows the project's own
# documented test glob, so `for t in tests/test_*.sh` yields a directory, bash
# exits 126, and the unit suite goes spuriously red (issue #97).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/plugins/autocoder/scripts/regression-test.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Stub gh/git so the run is hermetic — this test is about config parsing only.
mkdir -p "$TMP/bin"
for stub in gh git npx npm; do
  printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/$stub"
  chmod +x "$TMP/bin/$stub"
done

mkdir -p "$TMP/work/tests"
cd "$TMP/work"

# Mirrors the real CLAUDE.md ordering: the Unit Tests "Location:" precedes the
# Test Reports "Location:". No test commands are configured, so both suites skip
# and the run is fast.
cat > CLAUDE.md <<'MD'
## Automated Testing & Issue Management

### Test Framework Details

**Unit Tests**:
- Framework: plain `bash` assertion scripts
- Location: `tests/test_*.sh` (shell), `tests/test_*.py` (Python)

**E2E Tests**:
- Not configured for this repository.

**Test Reports**:
- Location: `docs/test/regression-reports/`

### Merge Mode
```
pr
```
MD

PATH="$TMP/bin:$PATH" bash "$SCRIPT" >/dev/null 2>&1 || true

fail() { echo "FAIL: $1" >&2; exit 1; }

# 1. The glob-named directory must never be created: it shadows tests/test_*.sh.
if [ -e 'tests/test_*.sh' ]; then
  fail "regression-test.sh created a path literally named 'tests/test_*.sh'"
fi

# 2. Nothing anywhere may be named with glob metacharacters.
if find . -name '*[*?]*' -print -quit | grep -q .; then
  fail "regression-test.sh created a path containing glob metacharacters: $(find . -name '*[*?]*' -print -quit)"
fi

# 3. The report must land in the Test Reports location, not the Unit Tests one.
if ! ls docs/test/regression-reports/regression-*.md >/dev/null 2>&1; then
  fail "no report written to docs/test/regression-reports/"
fi

# --- Scenario 2: a Test Reports Location that is itself a glob -----------------
# Exercises the metacharacter guard directly, so it cannot rot into dead code.
mkdir -p "$TMP/work2"
cd "$TMP/work2"
cat > CLAUDE.md <<'MD'
## Automated Testing & Issue Management

**Test Reports**:
- Location: `reports/run-*.d`
MD

PATH="$TMP/bin:$PATH" bash "$SCRIPT" >/dev/null 2>&1 || true

if find . -name '*[*?]*' -print -quit | grep -q .; then
  fail "glob-shaped Test Reports location was used verbatim: $(find . -name '*[*?]*' -print -quit)"
fi
if ! ls docs/test/regression-reports/regression-*.md >/dev/null 2>&1; then
  fail "glob-shaped location should fall back to docs/test/regression-reports/"
fi

echo "ok regression-test report dir"
