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
ISSUE_SOURCE=file ISSUE_DIR_PATH="$MAIN/env-issues" resolve_effective_issue_source "" "" "$MAIN"
assert_eq "$ISSUE_SOURCE" "file" "environment source fallback"
assert_eq "$ISSUE_SOURCE_ORIGIN" "environment" "environment origin"
assert_eq "$ISSUE_DIR_PATH" "$MAIN/env-issues" "environment issue dir"

cat > "$MAIN/.autocoder.json" <<JSON
{"issueSource":"jira","issueBackend":"jira-script"}
JSON
resolve_effective_issue_source "" "" "$MAIN"
assert_eq "$ISSUE_SOURCE" "jira" "custom configured source preserved"
assert_eq "$ISSUE_BACKEND" "jira-script" "custom backend preserved"

if resolve_effective_issue_source linear "" "$MAIN" 2>/dev/null; then
  echo "FAIL: unsupported CLI issue source should fail" >&2
  exit 1
fi

echo "ok issue-source-lib"
