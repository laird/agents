#!/usr/bin/env bash
# scripts/check-optional-skills-drift.sh
# Two-pass drift detector for opportunistic-skill-integration prelude blocks.
# Pass 1: boilerplate identical across all 14 command files + 2 canonical sources.
# Pass 2: per-command mapping identical between Claude Code and Antigravity mirrors.
# Exits non-zero on any drift or structural problem (CI-safe).
#
# Sentinel versions are matched as `v<N>`, not a hardcoded `v1`, so bumping a
# block's version never requires editing this script — and, critically, never
# silently disables the check. A hardcoded version that stops matching extracts
# an empty block from BOTH mirrors, and two empty strings hash equal: the script
# would print OK while verifying nothing. Both passes now treat an empty
# extraction as a structural error.
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
  plugins/autocoder/commands/retro.md
  plugins/modernize/commands/plan.md
  plugins/modernize/commands/modernize.md
  .agent/workflows/brainstorm-issue.md
  .agent/workflows/approve-proposal.md
  .agent/workflows/fix.md
  .agent/workflows/fix-loop.md
  .agent/workflows/retro.md
  .agent/workflows/plan.md
  .agent/workflows/modernize.md
)

for f in "${boilerplate_files[@]}"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: missing file: $f" >&2
    exit 1
  fi
done

for f in "${boilerplate_files[@]}"; do
  if [ -z "$(awk '/BEGIN optional-skills-prelude v[0-9]+/,/END optional-skills-prelude v[0-9]+/' "$f")" ]; then
    echo "ERROR: no optional-skills-prelude block found in: $f" >&2
    exit 1
  fi
done

boilerplate_hashes=$(
  for f in "${boilerplate_files[@]}"; do
    awk '/BEGIN optional-skills-prelude v[0-9]+/,/END optional-skills-prelude v[0-9]+/' "$f" | sha256sum
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
# retro added: it carries both a prelude block and a mapping block but was
# missing from this manifest, so its mirrors could drift undetected.
for cmd in brainstorm-issue approve-proposal plan modernize fix fix-loop retro; do
  # Match on the mapping marker, not just the filename: retro.md exists in both
  # plugins/autocoder (carries the mapping block) and plugins/modernize (an
  # unrelated command with no block).
  matches=$(grep -lE "BEGIN optional-skills-mapping ${cmd} v[0-9]+" $(find plugins/*/commands -name "${cmd}.md" 2>/dev/null) 2>/dev/null || true)
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
  cc_block=$(awk "/BEGIN optional-skills-mapping ${cmd} v[0-9]+/,/END optional-skills-mapping ${cmd} v[0-9]+/" "$cc_file")
  ag_block=$(awk "/BEGIN optional-skills-mapping ${cmd} v[0-9]+/,/END optional-skills-mapping ${cmd} v[0-9]+/" "$ag_file")
  # An empty extraction on both sides hashes equal and would report a false OK.
  if [ -z "$cc_block" ] || [ -z "$ag_block" ]; then
    echo "ERROR: no ${cmd} mapping block found in $([ -z "$cc_block" ] && echo "$cc_file")$([ -z "$cc_block" ] && [ -z "$ag_block" ] && echo " and ")$([ -z "$ag_block" ] && echo "$ag_file")" >&2
    exit 1
  fi
  cc_hash=$(printf '%s' "$cc_block" | sha256sum)
  ag_hash=$(printf '%s' "$ag_block" | sha256sum)
  if [ "$cc_hash" = "$ag_hash" ]; then
    echo "${cmd}: OK"
  else
    echo "${cmd}: DRIFT" >&2
    drift_seen=1
  fi
done

exit "$drift_seen"
