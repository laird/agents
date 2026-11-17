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
# Discovered, not hand-listed. A hand-maintained allow-list catches deletions and
# renames loudly but is blind to ADDITIONS: a new command file that embeds the
# prelude is simply never hashed. That already happened once (see the retro note
# in Pass 2). Discovery plus the pairing assertion below makes a one-sided
# addition fail instead of being skipped.
# `mapfile` is bash 4+; macOS ships bash 3.2, so read the list portably.
boilerplate_files=()
while IFS= read -r line; do
  boilerplate_files+=("$line")
done < <(grep -rlE 'BEGIN optional-skills-prelude v[0-9]+' --include='*.md' plugins .agent | sort)

if [ "${#boilerplate_files[@]}" -eq 0 ]; then
  echo "ERROR: no files carrying an optional-skills-prelude block were found" >&2
  exit 1
fi

# Every plugins/*/commands/<n>.md must have a .agent/workflows/<n>.md counterpart
# and vice versa, so a block added to one platform tree and forgotten in the
# other fails here rather than passing unnoticed.
pairing_error=0
for f in "${boilerplate_files[@]}"; do
  case "$f" in
    plugins/shared/optional-skills-prelude.md|.agent/shared/optional-skills-prelude.md) continue ;;
    plugins/*/commands/*.md) counterpart=".agent/workflows/$(basename "$f")" ;;
    .agent/workflows/*.md)
      base="$(basename "$f")"
      if ! ls plugins/*/commands/"$base" >/dev/null 2>&1; then
        echo "ERROR: $f has no plugins/*/commands/$base counterpart" >&2
        pairing_error=1
      fi
      continue ;;
    *) echo "ERROR: prelude block in unexpected location: $f" >&2; pairing_error=1; continue ;;
  esac
  if [ ! -f "$counterpart" ]; then
    echo "ERROR: $f has no $counterpart counterpart" >&2
    pairing_error=1
  fi
done
for f in plugins/shared/optional-skills-prelude.md .agent/shared/optional-skills-prelude.md; do
  if [ ! -f "$f" ]; then
    echo "ERROR: missing canonical file: $f" >&2
    pairing_error=1
  fi
done
[ "$pairing_error" -eq 0 ] || exit 1

for f in "${boilerplate_files[@]}"; do
  if [ -z "$(awk '/BEGIN optional-skills-prelude v[0-9]+/,/END optional-skills-prelude v[0-9]+/' "$f")" ]; then
    echo "ERROR: no optional-skills-prelude block found in: $f" >&2
    exit 1
  fi
done

# Keep the filename alongside the hash: a bare hash list tells a maintainer that
# drift exists but not which of the files drifted, which is the difference
# between a red run that gets fixed and one that gets ignored.
boilerplate_pairs=$(
  for f in "${boilerplate_files[@]}"; do
    h=$(awk '/BEGIN optional-skills-prelude v[0-9]+/,/END optional-skills-prelude v[0-9]+/' "$f" | sha256sum | cut -d' ' -f1)
    echo "$h  $f"
  done
)
unique_count=$(echo "$boilerplate_pairs" | cut -d' ' -f1 | sort -u | wc -l | tr -d ' ')
if [ "$unique_count" -ne 1 ]; then
  echo "ERROR: boilerplate hashes diverge across files ($unique_count distinct hashes)" >&2
  echo "$boilerplate_pairs" | sort >&2
  drift_seen=1
else
  echo "boilerplate: OK (one hash across ${#boilerplate_files[@]} files)"
fi

# --- Pass 1b: manifest block identical across the two canonical mirrors ---
# The manifest is a SECOND sentinel-bracketed region, carried only by the two
# shared files and prepended to every dispatched worker's prompt. It was
# previously extracted by neither pass: its mirrors could diverge arbitrarily —
# or one could be deleted outright — while this script printed all-OK. That is
# the same green-while-red failure the version-agnostic fix above eliminated,
# so the manifest gets the same treatment.
manifest_files=(
  plugins/shared/optional-skills-prelude.md
  .agent/shared/optional-skills-prelude.md
)
manifest_hashes=$(
  for f in "${manifest_files[@]}"; do
    blk=$(awk '/BEGIN optional-skills-manifest v[0-9]+/,/END optional-skills-manifest v[0-9]+/' "$f")
    if [ -z "$blk" ]; then
      echo "ERROR: no optional-skills-manifest block found in: $f" >&2
      exit 1
    fi
    printf '%s' "$blk" | sha256sum
  done | sort -u
)
manifest_count=$(echo "$manifest_hashes" | wc -l | tr -d ' ')
if [ "$manifest_count" -ne 1 ]; then
  echo "ERROR: manifest hashes diverge across mirrors ($manifest_count distinct hashes)" >&2
  drift_seen=1
else
  echo "manifest: OK (one hash across both mirrors)"
fi

# --- Pass 2: per-command mapping identical between Claude/Antigravity mirrors ---
# retro added: it carries both a prelude block and a mapping block but was
# missing from this manifest, so its mirrors could drift undetected.
for cmd in brainstorm-issue approve-proposal plan modernize fix fix-loop retro; do
  # Match on the mapping marker, not just the filename: retro.md exists in both
  # plugins/autocoder (carries the mapping block) and plugins/modernize (an
  # unrelated command with no block).
  # Collect candidates safely: an unquoted $(find ...) that expands to nothing
  # leaves grep with zero file operands, so it reads stdin and blocks instead of
  # failing. Word-splitting on a path containing a space is the same hazard.
  cands=()
  while IFS= read -r line; do
    cands+=("$line")
  done < <(find plugins/*/commands -name "${cmd}.md" 2>/dev/null)
  if [ "${#cands[@]}" -eq 0 ]; then
    echo "ERROR: no plugins/*/commands/${cmd}.md found" >&2
    exit 1
  fi
  matches=$(grep -lE "BEGIN optional-skills-mapping ${cmd} v[0-9]+" -- "${cands[@]}" 2>/dev/null || true)
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
