#!/usr/bin/env bash
# scripts/check-optional-skills-drift.sh
# Two-pass drift detector for opportunistic-skill-integration prelude blocks.
# Pass 1: boilerplate identical across all 14 command files + 2 canonical sources.
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
  plugins/autocoder/commands/dev.md
  plugins/autocoder/commands/dev-loop.md
  plugins/autocoder/commands/plan.md
  plugins/modernize/commands/plan.md
  plugins/modernize/commands/modernize.md
  .agent/workflows/brainstorm-issue.md
  .agent/workflows/approve-proposal.md
  .agent/workflows/dev.md
  .agent/workflows/dev-loop.md
  .agent/workflows/autocoder-plan.md
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
#
# Entries are "<marker>|<claude-path>|<antigravity-path>". Paths are explicit
# rather than discovered by `find plugins/*/commands -name "<cmd>.md"`, because
# a bare command name is NOT unique across plugins: both autocoder and modernize
# ship a plan.md. The marker name (not the filename) identifies the mapping
# block, so autocoder's uses "autocoder-plan" while modernize's uses "plan".
mapping_specs=(
  "brainstorm-issue|plugins/autocoder/commands/brainstorm-issue.md|.agent/workflows/brainstorm-issue.md"
  "approve-proposal|plugins/autocoder/commands/approve-proposal.md|.agent/workflows/approve-proposal.md"
  "autocoder-plan|plugins/autocoder/commands/plan.md|.agent/workflows/autocoder-plan.md"
  "plan|plugins/modernize/commands/plan.md|.agent/workflows/plan.md"
  "modernize|plugins/modernize/commands/modernize.md|.agent/workflows/modernize.md"
  "dev|plugins/autocoder/commands/dev.md|.agent/workflows/dev.md"
  "dev-loop|plugins/autocoder/commands/dev-loop.md|.agent/workflows/dev-loop.md"
)

for spec in "${mapping_specs[@]}"; do
  IFS='|' read -r cmd cc_file ag_file <<< "$spec"
  for f in "$cc_file" "$ag_file"; do
    if [ ! -f "$f" ]; then
      echo "ERROR: missing $f" >&2
      exit 1
    fi
  done
  # A marker that matches nothing hashes the empty string on BOTH sides and would
  # silently "pass". Assert the block actually exists before comparing.
  if ! grep -q "BEGIN optional-skills-mapping ${cmd} v1" "$cc_file"; then
    echo "ERROR: $cc_file has no 'optional-skills-mapping ${cmd} v1' block" >&2
    exit 1
  fi
  if ! grep -q "BEGIN optional-skills-mapping ${cmd} v1" "$ag_file"; then
    echo "ERROR: $ag_file has no 'optional-skills-mapping ${cmd} v1' block" >&2
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
