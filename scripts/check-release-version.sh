#!/bin/bash
# check-release-version.sh — release gate for integration → master PRs.
#
# A release must (1) bump the marketplace root version above what master ships,
# and (2) keep the three version locations in step so an installed plugin never
# self-reports a stale version. This script enforces both. It is called by
# .github/workflows/release-gate.yml on pull requests whose base is master, and
# can be run locally before opening a release PR.
#
# Usage:
#   scripts/check-release-version.sh [BASE_REF]
#     BASE_REF  git ref to compare against (default: origin/master)
#
# Checks (evaluated against the working tree / current HEAD):
#   1. BUMP        — marketplace root version is strictly greater than BASE_REF's.
#   2. CONSISTENCY — for every plugin in .claude-plugin/marketplace.json, its
#                    plugins[].version equals .claude-plugin/plugins/<name>/plugin.json.
#
# Exit codes: 0 = all checks pass · 1 = a check failed · 2 = usage/setup error.

set -u
BASE_REF="${1:-origin/master}"
MKT=".claude-plugin/marketplace.json"

[ -f "$MKT" ] || { echo "❌ $MKT not found (run from the repo root)." >&2; exit 2; }

# Base marketplace JSON (empty if the ref or file is unavailable).
BASE_MKT_JSON="$(git show "${BASE_REF}:${MKT}" 2>/dev/null || true)"

BASE_MKT_JSON="$BASE_MKT_JSON" python3 - "$MKT" <<'PY'
import json, os, sys

head_path = sys.argv[1]

def ver_tuple(v):
    parts = []
    for p in str(v).split("."):
        num = "".join(ch for ch in p if ch.isdigit())
        parts.append(int(num) if num else 0)
    while len(parts) < 3:
        parts.append(0)
    return tuple(parts[:3])

fail = []

with open(head_path) as f:
    head = json.load(f)
head_root = head.get("version")
if not head_root:
    fail.append(f"{head_path}: missing root 'version'")

# ── 1. BUMP ────────────────────────────────────────────────────────────────
base_raw = os.environ.get("BASE_MKT_JSON", "").strip()
if not base_raw:
    print("⚠️  Could not read base marketplace.json — skipping the bump check "
          "(is this the first release?).")
else:
    base_root = json.loads(base_raw).get("version")
    if head_root and base_root:
        if ver_tuple(head_root) > ver_tuple(base_root):
            print(f"✅ bump: marketplace root {base_root} → {head_root}")
        else:
            fail.append(f"marketplace root version must increase for a release: "
                        f"base={base_root} head={head_root} (bump it before merging to master)")

# ── 2. CONSISTENCY (marketplace plugins[] == plugin.json) ───────────────────
for p in head.get("plugins", []):
    name = p.get("name")
    mkt_ver = p.get("version")
    pj_path = f".claude-plugin/plugins/{name}/plugin.json"
    if not os.path.exists(pj_path):
        fail.append(f"{name}: {pj_path} not found")
        continue
    with open(pj_path) as f:
        pj_ver = json.load(f).get("version")
    if pj_ver == mkt_ver:
        print(f"✅ consistency: {name} {mkt_ver} (marketplace == plugin.json)")
    else:
        fail.append(f"{name}: marketplace plugins[].version={mkt_ver} but "
                    f"{pj_path}={pj_ver} — keep them equal (see CLAUDE.md version rule)")

if fail:
    print("\n❌ release gate failed:", file=sys.stderr)
    for f_ in fail:
        print(f"   - {f_}", file=sys.stderr)
    sys.exit(1)
print("\n✅ release gate passed.")
PY
