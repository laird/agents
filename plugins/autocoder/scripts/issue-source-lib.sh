#!/bin/bash
# Read-only issue-source resolution for swarm launch/lifecycle scripts.

resolve_main_worktree() {
  local root
  root=$(git worktree list --porcelain 2>/dev/null | awk '/^worktree / {print substr($0, 10); exit}')
  if [ -n "$root" ]; then
    printf '%s\n' "$root"
  else
    pwd
  fi
}

_issue_source_json_value() {
  local json_file="$1"
  local key="$2"
  python3 - "$json_file" "$key" <<'PY'
import json
import os
import sys

path, key = sys.argv[1], sys.argv[2]
if not os.path.exists(path):
    sys.exit(0)
try:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    sys.exit(0)
value = data.get(key, "")
if value is None:
    value = ""
print(value)
PY
}

_issue_source_abs_path() {
  local path="$1"
  local base="${2:-}"
  python3 - "$path" "$base" <<'PY'
import os
import sys
path, base = sys.argv[1], sys.argv[2]
if os.path.isabs(path):
    print(os.path.abspath(path))
elif base:
    print(os.path.abspath(os.path.join(base, path)))
else:
    print(os.path.abspath(path))
PY
}

resolve_effective_issue_source() {
  local cli_source="${1:-}"
  local cli_dir="${2:-}"
  local main_worktree="${3:-$(resolve_main_worktree)}"
  local config_file="$main_worktree/.autocoder.json"
  local configured_source configured_dir configured_backend
  local env_source="${ISSUE_SOURCE:-}"
  local env_dir="${ISSUE_DIR_PATH:-}"
  local env_backend="${ISSUE_BACKEND:-}"

  ISSUE_SOURCE=""
  ISSUE_DIR_PATH=""
  ISSUE_BACKEND=""
  ISSUE_SOURCE_ORIGIN=""

  configured_source=$(_issue_source_json_value "$config_file" issueSource)
  configured_dir=$(_issue_source_json_value "$config_file" issueDir)
  configured_backend=$(_issue_source_json_value "$config_file" issueBackend)

  if [ -n "$cli_source" ]; then
    case "$cli_source" in
      file|github|jira) ;;
      *)
        echo "❌ Invalid --issue-source '$cli_source'. Use file, github, or jira." >&2
        return 2
        ;;
    esac
    ISSUE_SOURCE="$cli_source"
    ISSUE_SOURCE_ORIGIN="cli"
  elif [ -n "$configured_source" ]; then
    ISSUE_SOURCE="$configured_source"
    ISSUE_SOURCE_ORIGIN="configured"
  elif [ -n "$env_source" ]; then
    ISSUE_SOURCE="$env_source"
    ISSUE_SOURCE_ORIGIN="environment"
  else
    echo "❌ No issue source configured for this project." >&2
    echo "   Run /set-issue-source or pass --issue-source file|github." >&2
    return 1
  fi

  if [ -n "$cli_dir" ] && [ "$ISSUE_SOURCE" != "file" ]; then
    echo "❌ --issue-dir is only valid with --issue-source file." >&2
    return 2
  fi

  if [ "$ISSUE_SOURCE" = "file" ]; then
    if [ -n "$cli_dir" ]; then
      ISSUE_DIR_PATH=$(_issue_source_abs_path "$cli_dir")
    elif [ "$ISSUE_SOURCE_ORIGIN" = "environment" ] && [ -n "$env_dir" ]; then
      ISSUE_DIR_PATH=$(_issue_source_abs_path "$env_dir")
    elif [ -n "$configured_dir" ]; then
      ISSUE_DIR_PATH=$(_issue_source_abs_path "$configured_dir" "$main_worktree")
    else
      ISSUE_DIR_PATH="$main_worktree/.issues"
    fi
  fi

  if [ "$ISSUE_SOURCE" != "file" ] && [ "$ISSUE_SOURCE" != "github" ] && [ "$ISSUE_SOURCE" != "jira" ]; then
    if [ "$ISSUE_SOURCE_ORIGIN" = "environment" ]; then
      ISSUE_BACKEND="$env_backend"
    else
      ISSUE_BACKEND="$configured_backend"
    fi
  fi

  export ISSUE_SOURCE ISSUE_SOURCE_ORIGIN
  [ -n "$ISSUE_DIR_PATH" ] && export ISSUE_DIR_PATH
  [ -n "$ISSUE_BACKEND" ] && export ISSUE_BACKEND
  return 0
}

issue_env_exports() {
  printf "export ISSUE_SOURCE=%q\n" "$ISSUE_SOURCE"
  if [ "$ISSUE_SOURCE" = "file" ] && [ -n "${ISSUE_DIR_PATH:-}" ]; then
    printf "export ISSUE_DIR_PATH=%q\n" "$ISSUE_DIR_PATH"
  fi
  if [ -n "${ISSUE_BACKEND:-}" ]; then
    printf "export ISSUE_BACKEND=%q\n" "$ISSUE_BACKEND"
  fi
}
