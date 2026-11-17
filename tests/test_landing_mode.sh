#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255: never write the real event logs
# tests/test_landing_mode.sh — landing-mode.sh picks merge vs pr from the diff's
# risk tier (#165), and fix.md lands through it at every landing site.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LM="$ROOT/plugins/autocoder/scripts/landing-mode.sh"
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want '$2', got '$3'"; fi; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cd "$TMP" || exit 1
git init -q -b main repo && cd repo || exit 1
git config user.email t@example.invalid; git config user.name t
git config core.quotePath true   # git's default; a user config may turn it off
mkdir -p .github/workflows src scripts
echo a > src/app.py; echo b > README.md; echo c > .github/workflows/ci.yml
echo d > scripts/install-tools.sh; echo e > install.sh
git add -A && git commit -qm base

# set_config <json|""> — commit .autocoder.json on main (the base).
set_config() {
  git checkout -q main
  if [ -n "$1" ]; then printf '%s\n' "$1" > .autocoder.json; git add .autocoder.json
  else git rm -q --ignore-unmatch .autocoder.json; fi
  git commit -qm config --allow-empty
}
# branch_touching <file...> — fresh branch off main that edits the files.
branch_touching() {
  git checkout -q -B topic main
  for f in "$@"; do mkdir -p "$(dirname "$f")"; echo "x$RANDOM" >> "$f"; done
  git add -A && git commit -qm change
}
mode() { bash "$LM" --mode "${2:-merge}" --base main --head "${1:-HEAD}" 2>/dev/null; }

RISK='{"risk":{"high":[".github/workflows/**","**/install*.sh","src/auth/*.py"]}}'

# ── No config / no risk key: the configured mode stands ──────────────────
set_config ""
branch_touching .github/workflows/ci.yml
eq "no .autocoder.json: merge stays merge" merge "$(mode)"
set_config '{"review":"always"}'
branch_touching .github/workflows/ci.yml
eq "no risk key: merge stays merge" merge "$(mode)"

# ── Tiers configured ─────────────────────────────────────────────────────
set_config "$RISK"
branch_touching src/app.py README.md
eq "low-risk diff merges" merge "$(mode)"
branch_touching .github/workflows/ci.yml
eq "workflow change → pr" pr "$(mode)"
branch_touching .github/workflows/nested/deep.yml
eq "** spans directories" pr "$(mode)"
branch_touching install.sh
eq "**/install*.sh matches a top-level install.sh" pr "$(mode)"
branch_touching scripts/install-tools.sh
eq "**/install*.sh matches a nested installer" pr "$(mode)"
branch_touching src/auth/login.py
eq "single * matches inside its segment" pr "$(mode)"
branch_touching src/auth/sub/x.py
eq "single * does not cross a /" merge "$(mode)"
branch_touching src/app.py
eq "pr mode stays pr on a low-risk diff" pr "$(mode HEAD pr)"
eq "unknown mode passes through on a low-risk diff" squash "$(mode HEAD squash)"

# The reason names the path and the glob that matched.
branch_touching .github/workflows/ci.yml
ERR=$(bash "$LM" --mode merge --base main 2>&1 >/dev/null)
echo "$ERR" | grep -q '.github/workflows/ci.yml  (risk.high: .github/workflows/\*\*)' \
  && ok "stderr names the path and glob" || bad "stderr lacks the matched path: $ERR"

# Renames: moving a protected file out of its directory still counts.
git checkout -q -B topic main
mkdir -p elsewhere; git mv .github/workflows/ci.yml elsewhere/ci.yml; git commit -qm move
eq "renaming a file out of a protected dir → pr" pr "$(mode)"

# Unusual filenames: git C-quotes non-ASCII, tab and quote characters by
# default, and a quoted path matches no glob.
branch_touching ".github/workflows/é.yml"
eq "non-ASCII filename in a protected dir → pr" pr "$(mode)"
branch_touching "$(printf '.github/workflows/tab\there.yml')"
eq "filename with a tab → pr" pr "$(mode)"
branch_touching '.github/workflows/q"uote.yml'
eq "filename with a quote → pr" pr "$(mode)"

# A [class] never matches "/", like * and ?.
set_config '{"risk":{"high":["src/a[/x]b.py"]}}'
branch_touching "src/a/b.py"
eq "[class] does not match a /" merge "$(mode)"
branch_touching "src/axb.py"
eq "[class] matches its members" pr "$(mode)"
set_config "$RISK"

# Only the branch's own changes count, not what landed on the base since.
git checkout -q -B topic main; echo y >> src/app.py; git commit -qam low
git checkout -q main; echo z >> .github/workflows/ci.yml; git commit -qam "base moved"
eq "base-only high-risk change does not taint the branch" merge "$(mode topic)"

# The branch cannot lower its own tier: the config is read from the base.
set_config "$RISK"
git checkout -q -B topic main
printf '{"risk":{"high":[]}}\n' > .autocoder.json
echo w >> .github/workflows/ci.yml; git add -A; git commit -qm weaken
eq "editing the tiers on the branch does not lower them" pr "$(mode)"
branch_touching .autocoder.json
eq ".autocoder.json is high-risk while tiers exist" pr "$(mode)"

# ── Fail closed ──────────────────────────────────────────────────────────
set_config '{"risk":'
branch_touching src/app.py
bash "$LM" --mode merge --base main >/dev/null 2>&1; eq "invalid JSON on base → exit 2" 2 "$?"
set_config '{"risk":{"high":".github/**"}}'
branch_touching src/app.py
bash "$LM" --mode merge --base main >/dev/null 2>&1; eq "risk.high not a list → exit 2" 2 "$?"
set_config "$RISK"
bash "$LM" --mode merge --base no-such-ref >/dev/null 2>&1; eq "unknown base → exit 2" 2 "$?"
bash "$LM" --base main >/dev/null 2>&1; eq "missing --mode → exit 2" 2 "$?"

# ── fix.md lands through landing-mode.sh at every site ───────────────────
for F in plugins/autocoder/commands/fix.md .agent/workflows/fix.md .pi/prompts/fix.md; do
  P="$ROOT/$F"
  SITES=$(grep -c 'git push -u origin "\(feature\|enhancement\)/issue-' "$P")
  CALLS=$(grep -c '^ *LANDING_MODE=$(bash "${SCRIPT_DIR}/landing-mode.sh" --mode "$MERGE_MODE"' "$P")
  eq "$F: one landing-mode call per landing site" "$SITES" "$CALLS"
  STOPS=$(grep -A1 '^ *LANDING_MODE=$(bash' "$P" | grep -c 'exit 1; }')
  eq "$F: every landing-mode call stops on failure" "$CALLS" "$STOPS"
  eq "$F: no landing branches on the raw MERGE_MODE" 0 "$(grep -c 'if \[ "$MERGE_MODE" = "pr" \]' "$P")"
  PR_BRANCHES=$(grep -c 'if \[ "$LANDING_MODE" = "pr" \]' "$P")
  eq "$F: every landing site branches on LANDING_MODE" "$SITES" "$PR_BRANCHES"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
