#!/bin/bash
# tests/test_manifest_versions.sh — every plugin manifest agrees on versions.
#
# WHY THIS EXISTS:
#   This repo ships the same two plugins to four agent platforms, and each
#   platform reads a different manifest. Nothing checked that they agreed, so
#   they silently drifted:
#     - .factory-plugin/marketplace.json (the Droid marketplace) sat at root
#       3.19.0 with autocoder 4.3.0 while the Claude marketplace advertised
#       4.15.0 — twelve minor versions behind, and load-bearing for Droid users.
#     - The six per-platform plugin.json files were left behind by a bump that
#       only touched .claude-plugin/marketplace.json.
#
#   A version mismatch does not fail loudly. The plugin still loads; it just
#   reports a version that does not match what the marketplace promised, and
#   the update mechanism that keys on the root marketplace version misfires.
#
# NOTE on authority: Claude Code reads the version from the MARKETPLACE ENTRY,
# not from .claude-plugin/plugins/<name>/plugin.json. Verified empirically —
# with the entry at 9.9.9 and the nested manifest at 7.7.7, `claude plugin
# details` reported 9.9.9. Those nested files are kept in sync anyway because
# they are published artifacts, but they are not what the loader consults.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
cd "$ROOT" || exit 1

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# ── Every manifest parses as JSON ─────────────────────────────────────────
while IFS= read -r f; do
  if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$f" 2>/dev/null; then
    ok "parses: $f"
  else
    bad "does not parse as JSON: $f"
  fi
done < <(find . -name "plugin.json" -o -name "marketplace.json" | grep -v "^./.git/" | grep -v node_modules | sort)

# ── All plugin versions agree, whichever manifest declares them ───────────
# Collect the manifest paths with `find`, NOT Python's glob: every manifest in
# this repo lives under a dot-directory (.claude-plugin, .factory-plugin,
# .agents, codex-plugins/*/.codex-plugin), and glob skips those by default. An
# earlier version of this check used glob, scanned zero files, found zero
# mismatches, and passed — while .factory-plugin sat twelve versions behind.
manifest_list_file="$(mktemp)"
find . \( -name 'plugin.json' -o -name 'marketplace.json' \) \
  -not -path './.git/*' -not -path '*/node_modules/*' | sort > "$manifest_list_file"

# The file list arrives as argv, not stdin: a `python3 - <<'PY'` heredoc already
# occupies stdin, so piping the list in silently delivers nothing.
report="$(python3 - "$manifest_list_file" <<'PY'
import json, sys, collections

seen = collections.defaultdict(set)   # plugin name -> {version}
where = collections.defaultdict(list) # (name, version) -> [file]

def record(name, version, f):
    if name in ("autocoder", "modernize") and version:
        seen[name].add(version)
        where[(name, version)].append(f)

files = [l.strip() for l in open(sys.argv[1]) if l.strip()]
if not files:
    print("STATUS FAIL")
    print("MISMATCH: no manifest files found to check")
    raise SystemExit(0)

for f in files:
    try:
        d = json.load(open(f))
    except Exception:
        continue
    if "plugins" in d and isinstance(d["plugins"], list):
        for e in d["plugins"]:
            if isinstance(e, dict):
                record(e.get("name"), e.get("version"), f)
    else:
        record(d.get("name"), d.get("version"), f)

bad = False
# A run that recorded no versions at all is a broken check, not a clean pass.
if not seen:
    print("MISMATCH: scanned files but found no autocoder/modernize versions")
    bad = True
for name, versions in sorted(seen.items()):
    if len(versions) > 1:
        bad = True
        print(f"MISMATCH {name}: {sorted(versions)}")
        for v in sorted(versions):
            for f in where[(name, v)]:
                print(f"    {v}  {f}")
    else:
        print(f"AGREE {name}: {versions.pop()}")
print("STATUS", "FAIL" if bad else "OK")
PY
)"
rm -f "$manifest_list_file"
echo "$report" | grep -v '^STATUS'
if echo "$report" | grep -q '^STATUS OK'; then
  ok "all manifests agree on plugin versions"
else
  bad "plugin versions disagree across manifests (see above)"
fi

# ── The two root marketplace versions track each other ────────────────────
cc_ver=$(python3 -c "import json;print(json.load(open('.claude-plugin/marketplace.json'))['version'])")
fp_ver=$(python3 -c "import json;print(json.load(open('.factory-plugin/marketplace.json'))['version'])")
if [ "$cc_ver" = "$fp_ver" ]; then
  ok "root marketplace versions match ($cc_ver)"
else
  bad "root marketplace versions differ: .claude-plugin=$cc_ver .factory-plugin=$fp_ver"
fi

# ── Marketplace sources point at directories that exist ───────────────────
for mp in .claude-plugin/marketplace.json .factory-plugin/marketplace.json .agents/plugins/marketplace.json; do
  [ -f "$mp" ] || continue
  missing=$(python3 - "$mp" <<'PY'
import json, os, sys
d = json.load(open(sys.argv[1]))
out = []
for e in d.get("plugins", []):
    src = e.get("source")
    if isinstance(src, dict):
        src = src.get("path")
    if src and not os.path.isdir(src.lstrip("./") or "."):
        out.append(f"{e.get('name')} -> {src}")
print("; ".join(out))
PY
)
  if [ -z "$missing" ]; then
    ok "$mp sources all resolve"
  else
    bad "$mp has unresolvable sources: $missing"
  fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
