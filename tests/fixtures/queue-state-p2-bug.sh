#!/usr/bin/env bash
# Fixture: .issues/ has exactly one open P2 bug.
#
# Contract:
#   $1 = setup | teardown
#   ISSUE_DIR_PATH (env, optional) — defaults to ./.issues
set -euo pipefail

action="${1:-}"
if [[ "$action" != "setup" && "$action" != "teardown" ]]; then
  echo "usage: $0 setup|teardown" >&2
  exit 2
fi

ISSUE_DIR_PATH="${ISSUE_DIR_PATH:-$(pwd)/.issues}"
BACKUP_DIR="${ISSUE_DIR_PATH}.fixture-backup-$$"
MARKER="${ISSUE_DIR_PATH}.fixture-backup-marker"

backup_existing() {
  if [[ -e "$ISSUE_DIR_PATH" ]]; then
    mv "$ISSUE_DIR_PATH" "$BACKUP_DIR"
  else
    mkdir -p "$BACKUP_DIR"
    : > "$BACKUP_DIR/.was-empty"
  fi
  echo "$BACKUP_DIR" > "$MARKER"
}

restore_backup() {
  if [[ ! -f "$MARKER" ]]; then return 0; fi
  local backup; backup="$(cat "$MARKER")"
  rm -rf "$ISSUE_DIR_PATH"
  if [[ -f "$backup/.was-empty" ]]; then
    rm -rf "$backup"
  elif [[ -d "$backup" ]]; then
    mv "$backup" "$ISSUE_DIR_PATH"
  fi
  rm -f "$MARKER"
}

write_issue() {
  # $1=num, $2=title, $3=labels (comma list), $4=status, $5=body
  local num="$1" title="$2" labels="$3" status="$4" body="$5"
  local path
  path="$(printf '%s/%03d.md' "$ISSUE_DIR_PATH" "$num")"
  {
    printf -- '---\n'
    printf 'number: %s\n' "$num"
    printf 'title: %s\n' "$title"
    printf 'labels: [%s]\n' "$labels"
    printf 'status: %s\n' "$status"
    printf -- '---\n'
    printf '%s\n' "$body"
  } > "$path"
}

if [[ "$action" == "setup" ]]; then
  backup_existing
  mkdir -p "$ISSUE_DIR_PATH"
  write_issue 1 \
    "Sample bug for fixture" \
    "bug, P2" \
    "open" \
    "Reproduces on main as of fixture install.
Steps: run the failing command; observe incorrect output.
Expected: correct output per spec; actual: error in logs."
  printf '1' > "$ISSUE_DIR_PATH/.seq"
  echo "queue-state-p2-bug: setup OK ($ISSUE_DIR_PATH, backup=$BACKUP_DIR)"
else
  restore_backup
  echo "queue-state-p2-bug: teardown OK ($ISSUE_DIR_PATH)"
fi
