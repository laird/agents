#!/bin/bash
# tests/test_script_packaging.sh — guards that every platform's plugin carries
# the scripts that platform actually runs.
#
# WHY THIS EXISTS:
#   Scripts lived in two trees and only one was ever packaged. `scripts/` held
#   the per-runtime loop drivers; `plugins/autocoder/scripts/` held what the
#   Claude plugin ships. `worker-launch-lib.sh` IS shipped, and it launched
#   Codex and Droid workers via "$repo_root/scripts/codex-fix-loop.sh" — a path
#   that does not exist under an installed plugin, so the launch quietly did
#   nothing. The Codex, Droid and Gemini packages shipped no scripts at all,
#   while their skills told agents to run scripts by repo-relative path.
#
#   Every one of those failures is invisible in the repo, because the files
#   exist — just not where an installed plugin can reach them. Only packaging
#   can catch it, so packaging is what this asserts.
#
# The sets are per platform and genuinely differ; see
# scripts/package-plugin-scripts.py for how each is derived.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
cd "$ROOT" || exit 1

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# ── The packaged sets are complete and current ────────────────────────────
if OUT=$(python3 scripts/package-plugin-scripts.py --check 2>&1); then
  ok "every platform package carries the scripts it uses"
else
  bad "packaged scripts are missing or stale:"
  echo "$OUT" | sed 's/^/    /'
fi

# ── A platform must not carry another platform's drivers ──────────────────
# Not tidiness: the sets collapsing into the union is the failure mode that
# hides a genuinely missing script behind "well, everything is everywhere".
check_absent() { # check_absent <dir> <glob> <label>
  local dir="$1" glob="$2" label="$3"
  if compgen -G "$dir/$glob" >/dev/null 2>&1; then
    bad "$label — found $(compgen -G "$dir/$glob" | tr '\n' ' ')"
  else
    ok "$label"
  fi
}
check_absent "codex-plugins/autocoder/scripts" "droid-*.sh"  "codex package carries no droid drivers"
check_absent "codex-plugins/autocoder/scripts" "gemini-*.sh" "codex package carries no gemini drivers"
check_absent ".factory-plugin/plugins/autocoder/scripts" "codex-*.sh"  "droid package carries no codex drivers"
check_absent ".factory-plugin/plugins/autocoder/scripts" "gemini-*.sh" "droid package carries no gemini drivers"
check_absent "skills/autocoder/scripts" "codex-*.sh" "gemini package carries no codex drivers"
check_absent "skills/autocoder/scripts" "droid-*.sh" "gemini package carries no droid drivers"

# ── Each platform's own drivers are present ───────────────────────────────
check_present() { # check_present <dir> <file> <label>
  if [ -f "$1/$2" ]; then ok "$3"; else bad "$3 — $1/$2 missing"; fi
}
check_present "codex-plugins/autocoder/scripts" "codex-fix-loop.sh" "codex package ships its fix loop"
check_present ".factory-plugin/plugins/autocoder/scripts" "droid-fix-loop.sh" "droid package ships its fix loop"
check_present "skills/autocoder/scripts" "gemini-fix-loop.sh" "gemini package ships its fix loop"
check_present "plugins/autocoder/scripts" "claude-worker-loop.sh" "claude package ships its worker loop"

# ── The shared launch layer travels with every platform that launches ─────
# worker-launch-lib.sh resolves the loop drivers relative to itself, so the
# driver it names has to be in the same directory it was installed into.
for dir in plugins/autocoder/scripts codex-plugins/autocoder/scripts .factory-plugin/plugins/autocoder/scripts; do
  check_present "$dir" "worker-launch-lib.sh" "$dir ships worker-launch-lib.sh"
done

# ── worker-launch-lib.sh must not hardcode the repo layout ────────────────
# The regression this replaces: "$repo_root/scripts/<driver>" resolves to
# nothing under an installed plugin, killing Codex and Droid launches silently.
if grep -qE '\$repo_root/scripts/(codex|droid)-' plugins/autocoder/scripts/worker-launch-lib.sh; then
  bad "worker-launch-lib.sh still addresses a loop driver via \$repo_root/scripts/"
else
  ok "worker-launch-lib.sh resolves loop drivers relative to itself"
fi

echo ""
echo "$PASS passed / $FAIL failed / $((PASS + FAIL)) total"
[ "$FAIL" -eq 0 ]
