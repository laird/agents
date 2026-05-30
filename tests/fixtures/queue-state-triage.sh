#!/usr/bin/env bash
# Fixture: five issues without P0–P3 labels (forces triage).
# Mix of bug + enhancement labels, but no priority labels.
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
    mkdir -p "$BACKUP_DIR"; : > "$BACKUP_DIR/.was-empty"
  fi
  echo "$BACKUP_DIR" > "$MARKER"
}

restore_backup() {
  if [[ ! -f "$MARKER" ]]; then return 0; fi
  local backup; backup="$(cat "$MARKER")"
  rm -rf "$ISSUE_DIR_PATH"
  if [[ -f "$backup/.was-empty" ]]; then rm -rf "$backup"
  elif [[ -d "$backup" ]]; then mv "$backup" "$ISSUE_DIR_PATH"
  fi
  rm -f "$MARKER"
}

write_issue() {
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
  write_issue 1 "Untriaged: crash on empty input"       "bug"         "open" \
    "Process crashes when stdin is empty. No priority assigned yet."
  write_issue 2 "Untriaged: support dark-mode toggle"   "enhancement" "open" \
    "User requested a dark-mode toggle in settings. Needs scoping."
  write_issue 3 "Untriaged: flaky test in CI"           "bug"         "open" \
    "Intermittent failure in integration suite; cause unknown."
  write_issue 4 "Untriaged: faster startup"             "enhancement" "open" \
    "Cold-start latency is ~1.2s; users have asked for sub-second."
  write_issue 5 "Untriaged: typo in error message"      "bug"         "open" \
    "Error message reads 'recieved' instead of 'received'."
  printf '5' > "$ISSUE_DIR_PATH/.seq"
  echo "queue-state-triage: setup OK ($ISSUE_DIR_PATH, backup=$BACKUP_DIR)"
else
  restore_backup
  echo "queue-state-triage: teardown OK ($ISSUE_DIR_PATH)"
fi
