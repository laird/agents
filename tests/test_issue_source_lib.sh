#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)/plugins/autocoder/scripts"
source "$SCRIPT_DIR/issue-source-lib.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

MAIN="$TMP/project"
mkdir -p "$MAIN"

assert_eq() {
  local actual="$1"
  local expected="$2"
  local message="$3"
  if [ "$actual" != "$expected" ]; then
    echo "FAIL: $message: expected '$expected', got '$actual'" >&2
    exit 1
  fi
}

cat > "$MAIN/.autocoder.json" <<JSON
{"issueSource":"file","issueDir":"configured-issues"}
JSON

resolve_effective_issue_source "" "" "$MAIN"
assert_eq "$ISSUE_SOURCE" "file" "configured issue source"
assert_eq "$ISSUE_SOURCE_ORIGIN" "configured" "configured origin"
assert_eq "$ISSUE_DIR_PATH" "$MAIN/configured-issues" "configured issue dir"

resolve_effective_issue_source github "" "$MAIN"
assert_eq "$ISSUE_SOURCE" "github" "CLI source overrides configured source"
assert_eq "$ISSUE_SOURCE_ORIGIN" "cli" "CLI origin"

resolve_effective_issue_source file "$MAIN/local-issues" "$MAIN"
assert_eq "$ISSUE_SOURCE" "file" "CLI file source"
assert_eq "$ISSUE_DIR_PATH" "$MAIN/local-issues" "CLI issue dir"

rm "$MAIN/.autocoder.json"
# Use explicit exports (not VAR=value prefix) so bash's save/restore of
# per-call env doesn't undo the function's own export after it returns.
export ISSUE_SOURCE=file
export ISSUE_DIR_PATH="$MAIN/env-issues"
resolve_effective_issue_source "" "" "$MAIN"
assert_eq "$ISSUE_SOURCE" "file" "environment source fallback"
assert_eq "$ISSUE_SOURCE_ORIGIN" "environment" "environment origin"
assert_eq "$ISSUE_DIR_PATH" "$MAIN/env-issues" "environment issue dir"
unset ISSUE_SOURCE ISSUE_DIR_PATH

# A genuinely custom (non-built-in) configured source still routes through the
# ISSUE_BACKEND escape hatch.
cat > "$MAIN/.autocoder.json" <<JSON
{"issueSource":"linear","issueBackend":"linear-script"}
JSON
resolve_effective_issue_source "" "" "$MAIN"
assert_eq "$ISSUE_SOURCE" "linear" "custom configured source preserved"
assert_eq "$ISSUE_BACKEND" "linear-script" "custom backend preserved"

# jira is a first-class source: it resolves without an issueBackend override,
# because the dispatcher maps it to issues-jira.sh directly.
cat > "$MAIN/.autocoder.json" <<JSON
{"issueSource":"jira"}
JSON
resolve_effective_issue_source "" "" "$MAIN"
assert_eq "$ISSUE_SOURCE" "jira" "jira configured source preserved"
assert_eq "$ISSUE_BACKEND" "" "jira needs no custom backend override"

# jira is also accepted as a --issue-source CLI value.
resolve_effective_issue_source jira "" "$MAIN"
assert_eq "$ISSUE_SOURCE" "jira" "jira accepted as CLI source"

if resolve_effective_issue_source notreal "" "$MAIN" 2>/dev/null; then
  echo "FAIL: unsupported CLI issue source should fail" >&2
  exit 1
fi

echo "ok issue-source-lib"
