#!/bin/bash
# issue-config.sh — detect and cache the issue backend
# Source this file. Exports: ISSUE_SOURCE, ISSUE_DIR_PATH, ISSUE_BACKEND
# Non-interactive mode: exits 1 with error if no cached config and no TTY.

# NOTE: an already-exported ISSUE_SOURCE is a *cache*, not the truth. It leaks
# across repos, worktrees, and sessions, so it must not override this repo's
# .autocoder.json — a stale value silently routes the whole workflow at the
# wrong backend, where it finds zero issues and idles forever. Config wins;
# the inherited value only stands when the config supplies nothing.
# Parameter expansion with a default keeps callers under `set -u` safe.
_ic_INHERITED_SOURCE="${ISSUE_SOURCE:-}"

_ic_MAIN_WORKTREE=$(git worktree list --porcelain 2>/dev/null | grep -m1 "^worktree" | cut -d' ' -f2)
_ic_JSON="${_ic_MAIN_WORKTREE}/.autocoder.json"

# ── 1. Read cached config ──────────────────────────────────────────────────
if [ -f "$_ic_JSON" ]; then
  _ic_SOURCE=$(python3 -c "
import json, sys
try:
    d = json.load(open('$_ic_JSON'))
    print(d.get('issueSource', ''))
except Exception:
    print('')
" 2>/dev/null)
  if [ -n "$_ic_SOURCE" ]; then
    # Config is authoritative. Surface the disagreement rather than silently
    # honouring a stale environment value.
    if [ -n "$_ic_INHERITED_SOURCE" ] && [ "$_ic_INHERITED_SOURCE" != "$_ic_SOURCE" ]; then
      echo "⚠️  ISSUE_SOURCE='$_ic_INHERITED_SOURCE' in the environment disagrees with" >&2
      echo "   ${_ic_JSON} (issueSource='$_ic_SOURCE'). Using the repo config." >&2
      echo "   Unset ISSUE_SOURCE to silence this warning." >&2
    fi
    export ISSUE_SOURCE="$_ic_SOURCE"
    if [ "$ISSUE_SOURCE" = "file" ]; then
      _ic_DIR=$(python3 -c "
import json
d = json.load(open('$_ic_JSON'))
print(d.get('issueDir', ''))
" 2>/dev/null)
      export ISSUE_DIR_PATH="${_ic_DIR:-${_ic_MAIN_WORKTREE}/.issues}"
    fi
    _ic_BACKEND=$(python3 -c "
import json
d = json.load(open('$_ic_JSON'))
print(d.get('issueBackend', ''))
" 2>/dev/null)
    if [ -n "$_ic_BACKEND" ]; then
      export ISSUE_BACKEND="$_ic_BACKEND"
    fi
    return 0 2>/dev/null || exit 0
  fi
fi

# ── 1b. No config value — fall back to the inherited environment ───────────
# Nothing in .autocoder.json to contradict it, so an exported ISSUE_SOURCE
# still stands (repos with no config, and the per-subprocess cache both rely
# on this). Must come before the fail-fast below.
if [ -n "$_ic_INHERITED_SOURCE" ]; then
  export ISSUE_SOURCE="$_ic_INHERITED_SOURCE"
  return 0 2>/dev/null || exit 0
fi

# ── 2. Non-interactive fail-fast ───────────────────────────────────────────
if [ ! -t 0 ] && [ ! -t 1 ]; then
  echo "Error: No issue source configured." >&2
  echo "Run /set-issue-source to choose an issue source before running autonomous commands." >&2
  exit 1
fi

# ── 3. Check for .issues/ directory ───────────────────────────────────────
_ic_ISSUES_DIR="${_ic_MAIN_WORKTREE}/.issues"
if [ -d "$_ic_ISSUES_DIR" ]; then
  echo "Found .issues/ — using it as the issue source."
  read -r -p "Use .issues/ as the issue source? [Y/n] " _ic_CONFIRM
  _ic_CONFIRM="${_ic_CONFIRM:-Y}"
  if [[ "$_ic_CONFIRM" =~ ^[Yy]$ ]]; then
    python3 -c "
import json, os
path = '$_ic_JSON'
d = json.load(open(path)) if os.path.exists(path) else {}
d['issueSource'] = 'file'
d['issueDir'] = '$_ic_ISSUES_DIR'
json.dump(d, open(path, 'w'), indent=2)
"
    export ISSUE_SOURCE="file"
    export ISSUE_DIR_PATH="$_ic_ISSUES_DIR"
    return 0 2>/dev/null || exit 0
  fi
fi

# ── 4. Check for GitHub remote ─────────────────────────────────────────────
if git remote -v 2>/dev/null | grep -q "github.com"; then
  echo "No local issues directory found. This repo is on GitHub — using gh issues."
  read -r -p "Use GitHub Issues? [Y/n] " _ic_CONFIRM
  _ic_CONFIRM="${_ic_CONFIRM:-Y}"
  if [[ "$_ic_CONFIRM" =~ ^[Yy]$ ]]; then
    python3 -c "
import json, os
path = '$_ic_JSON'
d = json.load(open(path)) if os.path.exists(path) else {}
d['issueSource'] = 'github'
json.dump(d, open(path, 'w'), indent=2)
"
    export ISSUE_SOURCE="github"
    return 0 2>/dev/null || exit 0
  fi
fi

# ── 5. Neither found — ask user ────────────────────────────────────────────
echo ""
echo "No issue source found. Choose:"
echo "  1) Create .issues/ directory and use file backend"
if git remote -v 2>/dev/null | grep -q "github.com"; then
  echo "  2) Use GitHub Issues"
fi
read -r -p "Choice [1]: " _ic_CHOICE
_ic_CHOICE="${_ic_CHOICE:-1}"

if [ "$_ic_CHOICE" = "1" ]; then
  mkdir -p "$_ic_ISSUES_DIR"
  python3 -c "
import json, os
path = '$_ic_JSON'
d = json.load(open(path)) if os.path.exists(path) else {}
d['issueSource'] = 'file'
d['issueDir'] = '$_ic_ISSUES_DIR'
json.dump(d, open(path, 'w'), indent=2)
"
  export ISSUE_SOURCE="file"
  export ISSUE_DIR_PATH="$_ic_ISSUES_DIR"
elif [ "$_ic_CHOICE" = "2" ]; then
  python3 -c "
import json, os
path = '$_ic_JSON'
d = json.load(open(path)) if os.path.exists(path) else {}
d['issueSource'] = 'github'
json.dump(d, open(path, 'w'), indent=2)
"
  export ISSUE_SOURCE="github"
fi
