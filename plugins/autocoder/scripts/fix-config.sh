#!/usr/bin/env bash
# fix-config.sh — /fix's per-run configuration and setup (#293, sub-task of #198).
#
# Reads the project configuration, resolves the model tiers, detects optional
# plugins, reconciles the workflow's GitHub labels and scans for unprioritized
# issues. This was inline bash in commands/fix.md; it moved here unchanged so
# the protocol stays short and the setup can be tested. Messages and markers
# are the ones the inline block printed.
#
# Usage:
#   fix-config.sh --out FILE [--platform claude|gemini]
#
#   --out FILE   where to write the hand-back variables (required).
#   --platform   claude (default): CLAUDE.md, opus/sonnet/haiku, reads the
#                Integration Branch section.
#                gemini: GEMINI.md, pro/flash/flash, the Antigravity prompt text,
#                no Integration Branch (Antigravity merges into the parent branch).
#
# Environment in: MANAGER_MODEL WORKER_MODEL FAST_MODEL (an env override beats
#   .autocoder.json), MANAGER_MODEL_PRECONFIG / WORKER_MODEL_PRECONFIG,
#   INTEGRATION_BRANCH (kept as given on --platform gemini). The issue backend
#   comes from .autocoder.json via issue-fns.sh. Run from the project root: the
#   config file and .autocoder.json are read from the current directory.
#
# Stdout markers the agent acts on (unchanged from the inline block):
#   MERGE_MODE_NOT_CONFIGURED=true   no Merge Mode section in the config file
#   ACTION_REQUIRED: ...             no model tiers configured: ask the user
#   UNPRIORITIZED_ISSUES_FOUND=true  followed by UNPRIORITIZED_DATA<<EOF ... EOF
#
# Hand-back: FILE is a bash fragment of `NAME=value` lines quoted with
# printf %q. The caller runs `source FILE`. Variables:
#   TEST_COMMAND BUILD_COMMAND MERGE_MODE INTEGRATION_BRANCH
#   MANAGER_MODEL WORKER_MODEL FAST_MODEL
#   SUPERPOWERS_AVAILABLE QUINT_AVAILABLE
#   UNPRIORITIZED UNPRIORITIZED_COUNT
#
# Exit codes: 0 always once the arguments parse (the inline block never
# stopped); 1 for a usage error.

OUT=""
PLATFORM="claude"
while [ $# -gt 0 ]; do
  case "$1" in
    --out|--platform)
      [ $# -ge 2 ] || { echo "fix-config.sh: $1 needs a value" >&2; exit 1; }
      if [ "$1" = --out ]; then OUT="$2"; else PLATFORM="$2"; fi
      shift 2 ;;
    -h|--help) sed -n '2,38p' "$0"; exit 0 ;;
    *) echo "fix-config.sh: unknown argument $1" >&2; exit 1 ;;
  esac
done
if [ -z "$OUT" ]; then
  echo "fix-config.sh: --out FILE is required" >&2
  exit 1
fi
case "$PLATFORM" in
  claude) CONFIG_MD="CLAUDE.md" ;;
  gemini) CONFIG_MD="GEMINI.md" ;;
  *) echo "fix-config.sh: --platform must be claude or gemini" >&2; exit 1 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=issue-fns.sh
source "${SCRIPT_DIR}/issue-fns.sh"

TEST_COMMAND="" BUILD_COMMAND="" MERGE_MODE="" UNPRIORITIZED="" UNPRIORITIZED_COUNT=0
SUPERPOWERS_AVAILABLE=false QUINT_AVAILABLE=false
write_handback() {
  local rc=$? v
  {
    for v in TEST_COMMAND BUILD_COMMAND MERGE_MODE INTEGRATION_BRANCH \
             MANAGER_MODEL WORKER_MODEL FAST_MODEL \
             SUPERPOWERS_AVAILABLE QUINT_AVAILABLE UNPRIORITIZED UNPRIORITIZED_COUNT; do
      printf '%s=%q\n' "$v" "${!v}"
    done
  } > "$OUT"
  exit "$rc"
}
trap write_handback EXIT

# ── Project configuration ────────────────────────────────────────────────────
# Load project-specific configuration from the config file
if [ -f "$CONFIG_MD" ]; then
  echo "📋 Reading project configuration from $CONFIG_MD"

  # Check if autocoder configuration exists
  if ! grep -q "## Automated Testing & Issue Management" "$CONFIG_MD"; then
    echo "⚠️  No autocoder configuration found in $CONFIG_MD"
    echo "📝 Adding autocoder configuration section to $CONFIG_MD..."

    # Append autocoder configuration to the config file
    cat >> "$CONFIG_MD" << 'AUTOCODER_CONFIG'

## Automated Testing & Issue Management

This section configures the `/fix` command for autonomous issue resolution.

### Regression Test Suite
```bash
npm test
```

### Build Verification
```bash
npm run build
```

### Test Framework Details

**Unit Tests**:
- Framework: (Configure your test framework)
- Location: (Configure test file locations)

**E2E Tests**:
- Framework: (Configure E2E test framework)
- Location: (Configure E2E test locations)

**Test Reports**:
- Location: `docs/test/regression-reports/`

### Merge Mode
```
merge
```
AUTOCODER_CONFIG
    if [ "$PLATFORM" = "claude" ]; then
      # Auto-detect the repo's default branch (works for main, master, integration, etc.)
      DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
      DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"
      cat >> "$CONFIG_MD" << 'AUTOCODER_CONFIG'
Options: `merge` (auto-merge to the integration branch and push) or `pr` (push feature branch and create a pull request, then stop).

### Integration Branch
```
AUTOCODER_CONFIG
      echo "${DEFAULT_BRANCH}" >> "$CONFIG_MD"
      cat >> "$CONFIG_MD" << 'AUTOCODER_CONFIG'
```
The shared branch all completed work is merged into. In a parallel-worktree swarm this MUST be the real shared branch (e.g. `main`), never a per-worktree branch — otherwise fixes strand on `main-wt-N` and never converge.

AUTOCODER_CONFIG
    else
      cat >> "$CONFIG_MD" << 'AUTOCODER_CONFIG'
Options: `merge` (auto-merge to parent branch and push) or `pr` (push feature branch and create a pull request, then stop).

AUTOCODER_CONFIG
    fi

    echo "✅ Added autocoder configuration to $CONFIG_MD - please update with project-specific details"
  fi

  # Extract test command
  if grep -q "### Regression Test Suite" "$CONFIG_MD"; then
    TEST_COMMAND=$(sed -n "/### Regression Test Suite/,/^###/{/^\`\`\`bash$/n;p;}" "$CONFIG_MD" | grep -v "^#" | grep -v "^\`\`\`" | grep -v "^$" | head -1)
    echo "✅ Regression test command: $TEST_COMMAND"
  else
    TEST_COMMAND="npm test"
    echo "⚠️  No regression test command found, using default: $TEST_COMMAND"
  fi

  # Extract build command
  if grep -q "### Build Verification" "$CONFIG_MD"; then
    BUILD_COMMAND=$(sed -n "/### Build Verification/,/^###/{/^\`\`\`bash$/n;p;}" "$CONFIG_MD" | grep -v "^#" | grep -v "^\`\`\`" | grep -v "^$" | head -1)
    echo "✅ Build command: $BUILD_COMMAND"
  else
    BUILD_COMMAND="npm run build"
    echo "⚠️  No build command found, using default: $BUILD_COMMAND"
  fi
  # Extract merge mode (merge or pr)
  if grep -q "### Merge Mode" "$CONFIG_MD"; then
    MERGE_MODE=$(sed -n "/### Merge Mode/,/^###/{/^\`\`\`$/n;p;}" "$CONFIG_MD" | grep -v "^#" | grep -v "^\`\`\`" | grep -v "^$" | head -1)
    echo "✅ Merge mode: $MERGE_MODE"
  else
    MERGE_MODE=""
    echo "MERGE_MODE_NOT_CONFIGURED=true"
  fi
  if [ "$PLATFORM" = "claude" ]; then
    # Extract the integration branch (the shared branch all work merges into).
    # Falls back to auto-detecting the repo default branch (supports main, master, integration, etc.)
    if grep -q "### Integration Branch" "$CONFIG_MD"; then
      INTEGRATION_BRANCH=$(sed -n "/### Integration Branch/,/^###/{/^\`\`\`$/n;p;}" "$CONFIG_MD" | grep -v "^#" | grep -v "^\`\`\`" | grep -v "^$" | head -1)
    fi
    INTEGRATION_BRANCH="${INTEGRATION_BRANCH:-$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')}"
    INTEGRATION_BRANCH="${INTEGRATION_BRANCH:-main}"
    echo "✅ Integration branch: $INTEGRATION_BRANCH"
  fi
else
  echo "⚠️  No $CONFIG_MD found in project, using defaults"
  TEST_COMMAND="npm test"
  BUILD_COMMAND="npm run build"
  MERGE_MODE="merge"
  if [ "$PLATFORM" = "claude" ]; then
    INTEGRATION_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
    INTEGRATION_BRANCH="${INTEGRATION_BRANCH:-main}"
  fi
fi

# Ensure gh is authenticated as the correct user for this repo (GitHub backend only)
if [ "$ISSUE_SOURCE" = "github" ]; then
  REPO_OWNER=$(gh repo view --json owner --jq '.owner.login' 2>/dev/null || echo "")
  if [ -n "$REPO_OWNER" ]; then
    CURRENT_GH_USER=$(gh api user --jq '.login' 2>/dev/null || echo "")
    if [ -n "$CURRENT_GH_USER" ] && [ "$CURRENT_GH_USER" != "$REPO_OWNER" ]; then
      echo "🔄 Switching gh identity to match repo owner ($REPO_OWNER)..."
      gh auth switch --user "$REPO_OWNER" 2>/dev/null || echo "⚠️  Could not switch to $REPO_OWNER — ensure 'gh auth login' has been run for this account"
    fi
  fi
fi

# ── Model configuration ──────────────────────────────────────────────────────
# Resolve model tiers: env vars → .autocoder.json → built-in defaults.
# If nothing is configured, ask the user to confirm defaults before proceeding.
if [ "$PLATFORM" = "claude" ]; then
  _DEFAULT_MANAGER_MODEL="opus"
  _DEFAULT_WORKER_MODEL="sonnet"
  _DEFAULT_FAST_MODEL="haiku"
else
  _DEFAULT_MANAGER_MODEL="pro"
  _DEFAULT_WORKER_MODEL="flash"
  _DEFAULT_FAST_MODEL="flash"
fi

# Load from .autocoder.json if present and not already set via env
if [ -f ".autocoder.json" ] && command -v python3 >/dev/null 2>&1; then
  _JSON_MANAGER=$(python3 -c "import json,sys; d=json.load(open('.autocoder.json')); print(d.get('managerModel',''))" 2>/dev/null || echo "")
  _JSON_WORKER=$(python3 -c "import json,sys; d=json.load(open('.autocoder.json')); print(d.get('workerModel',''))" 2>/dev/null || echo "")
  _JSON_FAST=$(python3 -c "import json,sys; d=json.load(open('.autocoder.json')); print(d.get('fastModel',''))" 2>/dev/null || echo "")
  MANAGER_MODEL="${MANAGER_MODEL:-${_JSON_MANAGER:-$_DEFAULT_MANAGER_MODEL}}"
  WORKER_MODEL="${WORKER_MODEL:-${_JSON_WORKER:-$_DEFAULT_WORKER_MODEL}}"
  FAST_MODEL="${FAST_MODEL:-${_JSON_FAST:-$_DEFAULT_FAST_MODEL}}"
else
  MANAGER_MODEL="${MANAGER_MODEL:-$_DEFAULT_MANAGER_MODEL}"
  WORKER_MODEL="${WORKER_MODEL:-$_DEFAULT_WORKER_MODEL}"
  FAST_MODEL="${FAST_MODEL:-$_DEFAULT_FAST_MODEL}"
fi

# Detect whether this is the first run (no models were pre-configured)
_MODELS_PRECONFIGURED=false
if [ -n "${MANAGER_MODEL_PRECONFIG:-}" ] || [ -n "${WORKER_MODEL_PRECONFIG:-}" ]; then
  _MODELS_PRECONFIGURED=true
elif grep -q '"managerModel"\|"workerModel"\|"fastModel"' .autocoder.json 2>/dev/null; then
  _MODELS_PRECONFIGURED=true
fi

if [ "$_MODELS_PRECONFIGURED" = "false" ]; then
  echo ""
  echo "⚙️  Model configuration — no custom models detected."
  echo ""
  echo "   Default tiers:"
  echo "     Deep (manager/complex): $MANAGER_MODEL"
  echo "     Balanced (worker/standard): $WORKER_MODEL"
  echo "     Fast (labels/comments): $FAST_MODEL"
  echo ""
  echo "   To keep these defaults, reply: confirm"
  echo "   To override, set env vars before running /fix:"
  echo "     export MANAGER_MODEL=\"$_DEFAULT_MANAGER_MODEL\""
  echo "     export WORKER_MODEL=\"$_DEFAULT_WORKER_MODEL\""
  echo "     export FAST_MODEL=\"$_DEFAULT_FAST_MODEL\""
  echo "   Or add to .autocoder.json:"
  echo "     {\"managerModel\": \"$_DEFAULT_MANAGER_MODEL\", \"workerModel\": \"$_DEFAULT_WORKER_MODEL\", \"fastModel\": \"$_DEFAULT_FAST_MODEL\"}"
  echo ""
  # The agent asks the user to confirm or override; it must not proceed until
  # the user responds.
  if [ "$PLATFORM" = "claude" ]; then
    echo "ACTION_REQUIRED: Ask the user now using AskUserQuestion:"
  else
    echo "ACTION_REQUIRED: Ask the user now:"
  fi
  echo "  Question: 'Autocoder will use these model tiers — confirm or override?'"
  echo "  Options:"
  echo "    1. Use defaults ($MANAGER_MODEL / $WORKER_MODEL / $FAST_MODEL)"
  echo "    2. Override — I will set MANAGER_MODEL / WORKER_MODEL / FAST_MODEL env vars"
  if [ "$PLATFORM" = "claude" ]; then
    echo "       (use tier shorthand: opus/sonnet/haiku for Claude Code, pro/flash for Gemini)"
  fi
  echo "    3. Save defaults to .autocoder.json (so this prompt doesn't appear again)"
  echo ""
  if [ "$PLATFORM" = "claude" ]; then
    echo "  Agents inherit credentials from the running session — no API keys needed."
    echo ""
  fi
  echo "  If the user chooses option 3, write the following to .autocoder.json (merging"
  echo "  with any existing keys):"
  echo "    managerModel: $MANAGER_MODEL"
  echo "    workerModel:  $WORKER_MODEL"
  echo "    fastModel:    $FAST_MODEL"
  echo "  Then continue."
  echo "  If the user overrides, update MANAGER_MODEL / WORKER_MODEL / FAST_MODEL to"
  echo "  the values they provide before continuing."
fi

echo "✅ Models: manager=$MANAGER_MODEL  worker=$WORKER_MODEL  fast=$FAST_MODEL"

# ── Optional plugins ─────────────────────────────────────────────────────────
echo "🔌 Detecting available plugins..."

# Check for superpowers plugin (structured problem-solving skills)
SUPERPOWERS_AVAILABLE=false
if claude plugins list 2>/dev/null | grep -q "superpowers"; then
  SUPERPOWERS_AVAILABLE=true
  echo "✅ superpowers plugin detected - will use for complex issues"
else
  echo "ℹ️  superpowers plugin not installed - will use direct problem-solving"
fi

# Check for quint plugin (structured reasoning for ultra-complex decisions)
QUINT_AVAILABLE=false
if claude plugins list 2>/dev/null | grep -q "quint"; then
  QUINT_AVAILABLE=true
  echo "✅ quint plugin detected - will use for ultra-complex decisions requiring human guidance"
else
  echo "ℹ️  quint plugin not installed - will escalate ultra-complex issues for manual review"
fi

# ── Labels ───────────────────────────────────────────────────────────────────
# Ensure the labels this workflow relies on exist (GitHub backend only — the file
# backend creates labels on demand).
#
# This reconciles against `gh label list` on EVERY run rather than gating on a
# marker file. A marker was used here previously and it was committed to git, so
# `[ ! -f .github/.priority-labels-configured ]` was false in every clone,
# worktree and fork — the block had not run for anyone since 2026-02-02, and
# this repo was missing all seven blocking labels as a result. Reconciling
# against reality costs one API call, is idempotent, and cannot be defeated by
# a file landing in the repo.
if [ "$ISSUE_SOURCE" = "github" ]; then
  EXISTING_LABELS=$(gh label list --limit 200 --json name --jq '.[].name' 2>/dev/null || echo "")

  LABELS=("P0:Critical priority issue:d73a4a" "P1:High priority issue:ff9800" "P2:Medium priority issue:ffeb3b" "P3:Low priority issue:4caf50" "proposal:AI-generated proposal awaiting human approval:c5def5" "working:Issue currently being worked on by an agent:1d76db" "needs-approval:Architectural decisions, major changes, security implications:e99695" "needs-design:Requirements unclear, multiple approaches, needs design:fbca04" "needs-clarification:Incomplete information, missing context, questions needed:d4c5f9" "too-complex:Beyond autonomous capability, requires deep expertise:b60205" "future:Idea for future consideration, not ready for implementation:bfd4f2" "decomposed:Complex issue broken into sub-tasks:9c27b0" "subtask:Part of a larger decomposed issue:ba68c8" "awaiting-integration:Work is complete but has not reached the integration branch:0e8a16" "needs-review-focus:Larger than the review-fit limit; the digest names every hunk to read:fef2c0")
  # `merging` is applied by merge-launch.sh --own-issue, which the Antigravity
  # local-merge flow does not use.
  [ "$PLATFORM" = "claude" ] && LABELS+=("merging:A detached merge job is landing this issue on the integration branch:5319e7")
  LABELS+=("spot-check:Closed merge-mode work sampled for human review (see /spot-check):c2e0c6")
  for label in "${LABELS[@]}"; do
    IFS=':' read -r name desc color <<< "$label"
    if ! echo "$EXISTING_LABELS" | grep -qFx "$name"; then
      echo "Creating label: $name"
      gh label create "$name" --description "$desc" --color "$color" 2>/dev/null || true
    fi
  done
fi

# ── Step 0: unprioritized issues ─────────────────────────────────────────────
# Review and prioritize any unprioritized issues
echo "🔍 Checking for unprioritized issues..."
ALL_OPEN_JSON="${TMPDIR:-/tmp}/all-open-issues.json"  # TMPDIR keeps a test run off the shared file
issue_list --state open --limit 100 > "$ALL_OPEN_JSON"

# Find issues without any priority label (P0-P3), excluding issues already being worked on
UNPRIORITIZED=$(cat "$ALL_OPEN_JSON" | python3 -c "
import json, sys
issues = json.load(sys.stdin)
unprioritized = [i for i in issues
                 if not any(l['name'] in ['P0','P1','P2','P3'] for l in i.get('labels',[]))
                 and not any(l['name'] == 'working' for l in i.get('labels',[]))]
for issue in unprioritized:
    print(f\"{issue['number']}|{issue['title']}|{issue.get('body', '')[:500]}\")
")

if [ -n "$UNPRIORITIZED" ]; then
  UNPRIORITIZED_COUNT=$(echo "$UNPRIORITIZED" | grep -c "^" || echo "0")
  echo "⚠️  Found $UNPRIORITIZED_COUNT unprioritized issue(s). Reviewing and assigning priorities..."
  echo ""
  echo "UNPRIORITIZED_ISSUES_FOUND=true"
  echo "UNPRIORITIZED_DATA<<EOF"
  echo "$UNPRIORITIZED"
  echo "EOF"
else
  echo "✅ All open issues have priority labels assigned"
fi
exit 0
