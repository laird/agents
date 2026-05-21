#!/usr/bin/env bash
# Fixture: .issues/ empty (no open issues).
#
# Contract:
#   $1 = setup | teardown
#   ISSUE_DIR_PATH (env, optional) — defaults to ./.issues
#
# Setup:  back up existing ISSUE_DIR_PATH to "<dir>.fixture-backup-<pid>",
#         then create an empty .issues/ with a fresh .seq=0.
# Teardown: remove the fixture dir and restore the backup if present.
set -euo pipefail

action="${1:-}"
if [[ "$action" != "setup" && "$action" != "teardown" ]]; then
  echo "usage: $0 setup|teardown" >&2
  exit 2
fi

ISSUE_DIR_PATH="${ISSUE_DIR_PATH:-$(pwd)/.issues}"
BACKUP_DIR="${ISSUE_DIR_PATH}.fixture-backup-$$"
# Marker file lets teardown find the backup even if PID env was lost.
MARKER="${ISSUE_DIR_PATH}.fixture-backup-marker"

backup_existing() {
  if [[ -e "$ISSUE_DIR_PATH" ]]; then
    mv "$ISSUE_DIR_PATH" "$BACKUP_DIR"
  else
    mkdir -p "$BACKUP_DIR"
    # Sentinel so teardown knows there was no prior state.
    : > "$BACKUP_DIR/.was-empty"
  fi
  echo "$BACKUP_DIR" > "$MARKER"
}

restore_backup() {
  if [[ ! -f "$MARKER" ]]; then
    echo "fixture-empty: no backup marker found; nothing to restore" >&2
    return 0
  fi
  local backup
  backup="$(cat "$MARKER")"
  rm -rf "$ISSUE_DIR_PATH"
  if [[ -f "$backup/.was-empty" ]]; then
    rm -rf "$backup"
  elif [[ -d "$backup" ]]; then
    mv "$backup" "$ISSUE_DIR_PATH"
  fi
  rm -f "$MARKER"
}

if [[ "$action" == "setup" ]]; then
  backup_existing
  mkdir -p "$ISSUE_DIR_PATH"
  printf '0' > "$ISSUE_DIR_PATH/.seq"
  echo "queue-state-empty: setup OK ($ISSUE_DIR_PATH, backup=$BACKUP_DIR)"
else
  restore_backup
  echo "queue-state-empty: teardown OK ($ISSUE_DIR_PATH)"
fi
