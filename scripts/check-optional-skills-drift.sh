#!/usr/bin/env bash
# scripts/check-optional-skills-drift.sh
# Two-pass drift detector for opportunistic-skill-integration prelude blocks.
# Pass 1: boilerplate identical across all 12 command files + 2 canonical sources.
# Pass 2: per-command mapping identical between Claude Code and Antigravity mirrors.
# Exits non-zero on any drift or structural problem (CI-safe).
#
# Known limitation: Pass 2 verifies cross-platform parity, not correctness.
# A bug applied identically to both mirrors satisfies Pass 2.

set -euo pipefail
drift_seen=0

# Resolve repo root so the script works from any cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# --- Pass 1: boilerplate identical across all files ---
boilerplate_files=(
  plugins/shared/optional-skills-prelude.md
  .agent/shared/optional-skills-prelude.md
  plugins/autocoder/commands/brainstorm-issue.md
  plugins/autocoder/commands/approve-proposal.md
  plugins/autocoder/commands/fix.md
  plugins/autocoder/commands/fix-loop.md
  plugins/modernize/commands/plan.md
  plugins/modernize/commands/modernize.md
  .agent/workflows/brainstorm-issue.md
  .agent/workflows/approve-proposal.md
  .agent/workflows/fix.md
  .agent/workflows/fix-loop.md
  .agent/workflows/plan.md
  .agent/workflows/modernize.md
)

for f in "${boilerplate_files[@]}"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: missing file: $f" >&2
    exit 1
  fi
done

boilerplate_hashes=$(
  for f in "${boilerplate_files[@]}"; do
    awk '/BEGIN optional-skills-prelude v1/,/END optional-skills-prelude v1/' "$f" | sha256sum
  done | sort -u
)
unique_count=$(echo "$boilerplate_hashes" | wc -l | tr -d ' ')
if [ "$unique_count" -ne 1 ]; then
  echo "ERROR: boilerplate hashes diverge across files ($unique_count distinct hashes)" >&2
  echo "$boilerplate_hashes" >&2
  drift_seen=1
else
  echo "boilerplate: OK (one hash across all files)"
fi

# --- Pass 2: per-command mapping identical between Claude/Antigravity mirrors ---
for cmd in brainstorm-issue approve-proposal plan modernize fix fix-loop; do
  matches=$(find plugins/*/commands -name "${cmd}.md" 2>/dev/null)
  count=$(echo "$matches" | grep -c . || true)
  if [ "$count" -ne 1 ]; then
    echo "ERROR: ${cmd}.md matches ${count} files in plugins/*/commands (expected 1):" >&2
    echo "$matches" >&2
    exit 1
  fi
  cc_file="$matches"
  ag_file=".agent/workflows/${cmd}.md"
  if [ ! -f "$ag_file" ]; then
    echo "ERROR: missing $ag_file" >&2
    exit 1
  fi
  cc_hash=$(awk "/BEGIN optional-skills-mapping ${cmd} v1/,/END optional-skills-mapping ${cmd} v1/" "$cc_file" | sha256sum)
  ag_hash=$(awk "/BEGIN optional-skills-mapping ${cmd} v1/,/END optional-skills-mapping ${cmd} v1/" "$ag_file" | sha256sum)
  if [ "$cc_hash" = "$ag_hash" ]; then
    echo "${cmd}: OK"
  else
    echo "${cmd}: DRIFT" >&2
    drift_seen=1
  fi
done

exit "$drift_seen"
