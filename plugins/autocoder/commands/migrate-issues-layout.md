# Migrate Issues Layout

One-shot migration from the legacy flat `.issues/*.md` layout to the four-bucket
layout (`open/`, `working/`, `blocked/`, `closed/`). Idempotent — refuses to run
if any bucket already contains `.md` files.

Only runs against the file backend; on the github backend issues live in
GitHub itself and have no on-disk layout to migrate.

## Setup

```bash
SCRIPT_DIR=$(
  if [ -d "$(pwd)/plugins/autocoder/scripts" ]; then echo "$(pwd)/plugins/autocoder/scripts"
  elif [ -d "$(pwd)/.claude-plugin/plugins/autocoder/scripts" ]; then echo "$(pwd)/.claude-plugin/plugins/autocoder/scripts"
  else find "$HOME/.claude/plugins/cache" -type d -name "scripts" -path "*/autocoder/*" 2>/dev/null | sort -V | tail -1
  fi
)
source "${SCRIPT_DIR}/issue-fns.sh"
```

## Usage

```
/migrate-issues-layout
```

## Steps

1. Refuse to run if the configured backend isn't the file backend:

```bash
if [ "$ISSUE_SOURCE" != "file" ]; then
  echo "/migrate-issues-layout only applies to the file backend (ISSUE_SOURCE=$ISSUE_SOURCE)."
  echo "Github-backed repositories have no on-disk layout to migrate."
  exit 0
fi
```

2. Invoke the file-backend's `migrate-layout` subcommand:

```bash
python3 "${SCRIPT_DIR}/issues-file.py" migrate-layout
```

The subcommand:

- Refuses to run if `open/`, `working/`, `blocked/`, or `closed/` already
  contains `.md` files (idempotency guard).
- Creates the four buckets.
- For each `*.md` at the top level of `.issues/`: parses frontmatter and
  moves to the bucket matching status / labels (`closed` → `closed/`;
  `working` → `working/`; any blocking label → `blocked/`; else → `open/`).
- Initializes `.seq` to `max(existing numbers, 0)` so subsequent `/record-issue`
  calls produce unique numbers.
- Prints a per-bucket count summary.

3. Confirm: "Layout migrated. `/list-issues` now walks bucket directories
   directly."

## See Also

- `/set-issue-source` — choose between the file and github backends; this
  command auto-detects flat layouts and offers to run migration.
- `/list-issues` — list issues (now bucket-partitioned by `--state`).
