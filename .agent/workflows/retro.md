# Autocoder Retrospective Analysis

Analyze accumulated project history to produce 3–5 specific, evidence-backed recommendations for improving the autocoder workflow. Output: `IMPROVEMENTS.md`.

## Optional skill enhancements

<!-- BEGIN optional-skills-prelude v2 — keep in sync across all command files; see plugins/shared/optional-skills-prelude.md -->

If a named skill appears in your available skills list (delivered in the session-start system-reminder), invoke it via the `Skill` tool at the indicated step. Otherwise, follow the inline protocol below — it remains the source of truth and is unchanged by this section.

Platform note: in Gemini CLI / Antigravity, skills activate via `activate_skill` instead of the `Skill` tool; in Codex they activate as `$<skill>`; in Factory Droid they load from the skills tree. The mapping is otherwise identical on all four platforms.

**Skill-name matching.** Match each table entry as an exact string. Mapping tables use fully-qualified names (`<plugin>:<skill>`) for plugin-installed skills and bare names for personal toolkit skills. Compound Engineering skills are the exception: match them in **either** form — fully-qualified `compound-engineering:ce-<name>` (how Claude Code lists them) or bare `ce-<name>` (how Codex, Factory Droid, and Antigravity list them).

**Notation.** `A → B → C` means sequence (invoke in order). `A + B + C` means independent facets (all apply, order irrelevant). `A (primary)` means A is the orchestration spine. A leading `→` on a row indicates "next in sequence if applicable."

**Compound Engineering precedence.** If a skill from the `compound-engineering` plugin covers a role in the table below and appears in your available-skills list, invoke it *in place of* the skill named in the mapping tables for that role. Compound Engineering outranks both `superpowers:*` and personal toolkit skills. Roles with no entry below are unaffected.

| Role | Use when installed | In place of |
|---|---|---|
| design exploration / requirements | `ce-brainstorm` | `thorough-brainstorming`, `superpowers:brainstorming` |
| implementation planning | `ce-plan` | `thorough-writing-plans`, `superpowers:writing-plans` |
| executing a plan | `ce-work` | `superpowers:executing-plans` |
| debugging a defect | `ce-debug` | `superpowers:systematic-debugging` |
| reviewing a spec or plan document | `ce-doc-review` | `critical-design-review`, `critical-implementation-review`, `update-design-doc`, `update-implementation-plan` |
| reviewing written code | `ce-code-review` | `completion-review`, `superpowers:requesting-code-review` |
| acting on review feedback | `ce-resolve-pr-feedback` | `superpowers:receiving-code-review` |
| session handoff | `ce-handoff` | `create-handoff`, `resume-handoff` |

Worktree provisioning and branch finishing are **not** substituted: `superpowers:using-git-worktrees` and `superpowers:finishing-a-development-branch` remain in force, because the inline protocol owns worktree naming, the issue-claim sequence, and the configured Merge Mode.

**Failure semantics.** Not-installed: silent fallback. Mid-run failure or interruption of an installed skill: surface the failure message, fall back to the inline protocol for the rest of that step, no retry. Self-skip (e.g., `<SUBAGENT-STOP>`): silent fallback, not treated as failure. If at least one `superpowers:*` skill named in this command's mapping table is missing from your available-skills list **and no installed Compound Engineering skill covers its role**, emit one consolidated recommendation line at command entry: *Tip: this command works best with the `superpowers` plugin (https://github.com/obra/superpowers) — install via `/plugin install superpowers@claude-plugins-official`.* Never emit such notices for Compound Engineering or personal toolkit skills.

**Skills are advisory, not gating.** A command's completion criteria are defined by its inline protocol. Optional skill outcomes are surfaced and considered, but do not override inline success criteria. "Always applied" in a mapping table means the skill is invoked when installed; outcomes remain advisory. When a command claims success while an advisory skill earlier in the run surfaced a failure, the success summary acknowledges the advisory finding.

**Version trust.** Skills are matched by name; the integration does not pin or verify versions. If a tracked skill's contract changes in a way that breaks the chain, the integration is stale and must be updated.

<!-- END optional-skills-prelude v2 -->

<!-- BEGIN optional-skills-mapping retro v2 — keep in sync between Claude/Antigravity mirrors of this command -->

`/retro` produces a **Document** deliverable (IMPROVEMENTS.md). Skill mapping:

| Step | Skill mapping |
|---|---|
| Synthesize findings into recommendations | `completion-review` (always) |
| Capture a durable learning from the retrospective | `compound-engineering:ce-compound` (when installed) |

<!-- END optional-skills-mapping retro v2 -->

## Usage

```bash
# Analyze last 12 months of history
/retro

# Scope to a specific date range
/retro --since 2026-01-01
```

## What This Does

1. Sources issue configuration — exits immediately if not configured
2. Reads history log (`HISTORY.md` or `history-log` GitHub issue)
3. Analyzes git log for user corrections, reverts, repeated fix attempts
4. Queries issue tracker for blocking patterns and reopened issues
5. Identifies recurring test failures from history
6. Synthesizes 3–5 evidence-backed recommendations
7. Writes `IMPROVEMENTS.md` to the project root

## Data Sources

**History log** — primary source of what happened:
- File backend: `HISTORY.md` in project root (written by `/fix` and `/full-regression-test`)
- GitHub backend: comments on the `history-log` labeled issue

**Git log** — signals of agent behavior quality:
- Reverts and correction keywords in commit messages
- Feature branches attempted more than once for the same issue

**Issue tracker** — patterns across all work:
- Currently blocked issues, broken down by blocking label
- Proposal creation and approval rates

**Test failure patterns** — extracted from history log:
- Regression test entries showing repeated failures on the same area

## Instructions

```bash
# Parse arguments
SINCE_DATE=""
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  case ${args[i]} in
    --since)
      SINCE_DATE="${args[i+1]}"
      ((i++))
      ;;
  esac
done

# Source issue config (exits with clear error if not configured)
SCRIPT_DIR=$(
  if [ -d "$(pwd)/.agent/scripts" ]; then echo "$(pwd)/.agent/scripts"
  elif [ -d "$(pwd)/plugins/autocoder/scripts" ]; then echo "$(pwd)/plugins/autocoder/scripts"
  elif [ -d "$(pwd)/.claude-plugin/plugins/autocoder/scripts" ]; then echo "$(pwd)/.claude-plugin/plugins/autocoder/scripts"
  else find "$HOME/.agent/plugins/cache" -type d -name "scripts" -path "*/autocoder/*" 2>/dev/null | sort -V | tail -1
  fi
)
source "${SCRIPT_DIR}/issue-fns.sh"
# ISSUE_SOURCE is now exported (or command has exited with error)

echo "🔍 Autocoder Retrospective Analysis"
echo "======================================"
echo "Issue source: $ISSUE_SOURCE"
[ -n "$SINCE_DATE" ] && echo "Analyzing since: $SINCE_DATE" || echo "Analyzing: last 12 months"
echo ""
```

### Phase 1: Collect Data (~15 min)

**1.1 Read history log**

For file backend:
```bash
if [ -f "HISTORY.md" ]; then
  HISTORY_ENTRIES=$(grep -c "^## " HISTORY.md 2>/dev/null || echo "0")
  echo "📖 Found $HISTORY_ENTRIES history entries in HISTORY.md"
  cat HISTORY.md
else
  echo "⚠️  No HISTORY.md found — history is sparse."
  echo "    Run /fix or /full-regression-test to begin building history."
fi
```

For GitHub backend (`$ISSUE_SOURCE = "github"`):
```bash
HISTORY_ISSUE=$(gh issue list --label "history-log" --state open --limit 1 \
  --json number --jq '.[0].number' 2>/dev/null)
if [ -n "$HISTORY_ISSUE" ] && [ "$HISTORY_ISSUE" != "null" ]; then
  echo "📖 Reading history from issue #${HISTORY_ISSUE}..."
  gh issue view "$HISTORY_ISSUE" --comments --json comments \
    --jq '.comments[] | "---\n" + .body' 2>/dev/null
else
  echo "⚠️  No history-log issue found — history is empty."
fi
```

**1.2 Analyze git log**

```bash
SINCE_FLAG="--since=${SINCE_DATE:-1 year ago}"

echo ""
echo "📊 Git log analysis"
echo "==================="

COMMIT_COUNT=$(git log --oneline $SINCE_FLAG | wc -l | tr -d ' ')
echo "Commits in range: $COMMIT_COUNT"

echo ""
echo "--- Correction/revert commits ---"
git log --all --oneline $SINCE_FLAG \
  --grep="revert\|correct\|actually\|oops\|undo\|mistake" \
  --regexp-ignore-case | head -20

echo ""
echo "--- Issues with multiple fix attempts ---"
git log --all --format="%D" $SINCE_FLAG \
  | grep -oE "feature/issue-[0-9]+" \
  | sort | uniq -c | sort -rn \
  | awk '$1 > 1 {print}' | head -10
```

**1.3 Analyze issue tracker**

```bash
echo ""
echo "📊 Issue tracker analysis"
echo "========================="

issue_list --state open --limit 200 > /tmp/retro-open.json 2>/dev/null || echo "[]" > /tmp/retro-open.json

python3 << 'PYTHON'
import json

open_issues = json.load(open('/tmp/retro-open.json'))
blocking_labels = ['needs-design', 'too-complex', 'needs-clarification', 'needs-approval', 'future']

by_label = {}
for issue in open_issues:
    for lbl in issue.get('labels', []):
        if lbl['name'] in blocking_labels:
            by_label[lbl['name']] = by_label.get(lbl['name'], 0) + 1

proposals = sum(1 for i in open_issues if any(l['name'] == 'proposal' for l in i.get('labels', [])))

print("Open blocking issues:")
for k, v in sorted(by_label.items(), key=lambda x: -x[1]):
    print(f"  {k}: {v}")
print(f"\nOpen proposals awaiting approval: {proposals}")
PYTHON

# History-derived stats
if [ -f "HISTORY.md" ]; then
  FIXED=$(grep -c "^## .* - Fix #" HISTORY.md 2>/dev/null || echo "0")
  BLOCKED=$(grep -c "^## .* - Blocked #" HISTORY.md 2>/dev/null || echo "0")
  PRS=$(grep -c "^## .* - PR #" HISTORY.md 2>/dev/null || echo "0")
  REGRESSIONS=$(grep -c "^## .* - Regression Test Run" HISTORY.md 2>/dev/null || echo "0")
  echo ""
  echo "History stats: fixes=$FIXED, PRs=$PRS, blocked=$BLOCKED, regression-runs=$REGRESSIONS"
fi
```

**1.4 Test failure patterns from history**

```bash
echo ""
echo "📊 Test failure patterns"
echo "========================"
if [ -f "HISTORY.md" ]; then
  echo "--- Regression test run summaries ---"
  grep -A 5 "^## .* - Regression Test Run" HISTORY.md | head -60
fi
```

### Phase 2: Identify Patterns (~10 min)

Based on the collected data, cluster signals into categories and score each by frequency × impact (both 1–10):

- **Agent behavior**: Wrong approaches, skipped context, requirement misunderstandings, wasted effort
- **Protocol gaps**: Blocking detection misses, escalation failures, fix strategy weaknesses
- **Recurring failures**: Tests or issue types that re-appear after being "fixed"
- **Automation opportunities**: Repeated manual patterns that could be scripted

Select the top 3–5 highest-scoring patterns.

### Phase 3: Develop Recommendations (~15 min)

For each top pattern:

```
**Problem**: [What goes wrong and how often — include a count if data supports it]

**Evidence**:
- [Specific example 1: issue number, git commit, or HISTORY.md entry]
- [Specific example 2]

**Proposed Change**: [Exact change — name the file and section to modify]

**Change Type**: Protocol Update | Agent Behavior | Automation | New Script

**Expected Impact**: [Quantified: e.g., "Reduce needs-clarification blocks by ~30%"]

**Affected Components**:
- `plugins/autocoder/commands/fix.md` — [which section]
```

### Phase 4: Write IMPROVEMENTS.md (~5 min)

Write `IMPROVEMENTS.md` to the project root:

```markdown
# Autocoder Process Improvement Recommendations

**Date**: YYYY-MM-DD
**Status**: Proposed
**Retrospective Period**: [start date] – [end date or "present"]
**Issue Source**: [file|github]

---

## Context

Following [N] fixes, [N] PRs, [N] blocked issues, and [N] regression test runs,
the autocoder agent analyzed its history to identify process improvements.

**Analysis Sources**:
- History log: [N] entries reviewed
- Git log: [N] commits from [period]
- Issue tracker: [N] open issues ([N] blocked), [N] proposals pending

**Key Metrics**:
- Autonomous fix rate: [N / (N+N+N)] = [X]%
- Block rate: needs-design=[N], too-complex=[N], needs-clarification=[N]
- Issues requiring multiple attempts: [N]

---

## Recommendations

### Recommendation 1: [Title]

[Body per Phase 3 template]

---

[Repeat for each recommendation, separated by `---`]

---

## Summary

| # | Recommendation | Impact | Effort | Priority |
|---|---|---|---|---|
| 1 | [title] | High | Low | P0 |
| 2 | [title] | Medium | Low | P1 |
| 3 | [title] | Medium | Medium | P1 |

---

## Next Steps

1. Review each recommendation above
2. Apply approved changes to `plugins/autocoder/commands/` manually
3. Run `/retro` again after 20+ more issues to measure improvement

---
*Generated by `/retro` — autocoder retrospective analysis*
```

After writing the file, print:

```
✅ IMPROVEMENTS.md written to project root.

Review the recommendations, apply the approved changes to plugins/autocoder/commands/,
then run /retro again in a few weeks to measure improvement.
```
