#!/usr/bin/env bash
# Fixture: three issues — one P0 bug mid-fix (working), one P1 bug ready
# to claim, one approved enhancement (no `proposal` label).
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
  # 001: P0 bug currently being fixed (status=working when `working` label present;
  # per issues-file.py cmd_update, the working label drives status=working).
  write_issue 1 "P0 bug: deploy crashes on cold start"   "bug, P0, working" "working" \
    "Critical: cold-start crash on staging. Currently mid-fix (working label set)."
  # 002: P1 bug ready to be claimed by next /autocoder:dev tick.
  write_issue 2 "P1 bug: incorrect totals on summary page" "bug, P1"        "open"    \
    "Summary page sums one row too few. No claim yet; ready for next tick."
  # 003: Approved enhancement — has no `proposal` label, so the fix loop treats
  # it as an actionable enhancement rather than a proposal awaiting review.
  write_issue 3 "Enhancement: add CSV export to reports"  "enhancement, P2" "open"    \
    "Approved enhancement (no proposal label). Add CSV export endpoint + UI button."
  printf '3' > "$ISSUE_DIR_PATH/.seq"
  echo "queue-state-active: setup OK ($ISSUE_DIR_PATH, backup=$BACKUP_DIR)"
else
  restore_backup
  echo "queue-state-active: teardown OK ($ISSUE_DIR_PATH)"
fi
