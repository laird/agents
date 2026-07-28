# Autocoder Plan

Turn a high-level goal into a reviewed design doc plus a set of independently-implementable story issues that the existing worker fleet (`/dev-loop` → `/dev`) can pull and implement.

This command is **human-gated** and **orchestrates existing skills** — it does not reimplement brainstorming, design review, or planning.

## Optional skill enhancements

<!-- BEGIN optional-skills-prelude v1 — keep in sync across all command files; see plugins/shared/optional-skills-prelude.md -->

If a named skill appears in your available skills list (delivered in the session-start system-reminder), invoke it via the `Skill` tool at the indicated step. Otherwise, follow the inline protocol below — it remains the source of truth and is unchanged by this section.

In Gemini CLI / Antigravity, skills activate via `activate_skill` instead of the `Skill` tool; the mapping is otherwise identical.

**Skill-name matching.** Match each table entry as an exact string. Mapping tables use fully-qualified names (`<plugin>:<skill>`) for plugin-installed skills and bare names for personal toolkit skills.

**Notation.** `A → B → C` means sequence (invoke in order). `A + B + C` means independent facets (all apply, order irrelevant). `A (primary)` means A is the orchestration spine. A leading `→` on a row indicates "next in sequence if applicable."

**Failure semantics.** Not-installed: silent fallback. Mid-run failure or interruption of an installed skill: surface the failure message, fall back to the inline protocol for the rest of that step, no retry. Self-skip (e.g., `<SUBAGENT-STOP>`): silent fallback, not treated as failure. If at least one `superpowers:*` skill named in this command's mapping table is missing from your available-skills list, emit one consolidated recommendation line at command entry: *Tip: this command works best with the `superpowers` plugin (https://github.com/obra/superpowers) — install via `/plugin install superpowers@claude-plugins-official`.* Never emit such notices for personal toolkit skills.

**Skills are advisory, not gating.** A command's completion criteria are defined by its inline protocol. Optional skill outcomes are surfaced and considered, but do not override inline success criteria. "Always applied" in a mapping table means the skill is invoked when installed; outcomes remain advisory. When a command claims success while an advisory skill earlier in the run surfaced a failure, the success summary acknowledges the advisory finding.

**Version trust.** Skills are matched by name; the integration does not pin or verify versions. If a tracked skill's contract changes in a way that breaks the chain, the integration is stale and must be updated.

<!-- END optional-skills-prelude v1 -->

<!-- BEGIN optional-skills-mapping autocoder-plan v1 — keep in sync between Claude/Antigravity mirrors of this command -->

| Step | Skill mapping |
|---|---|
| Brainstorm the goal (step 1) | `thorough-brainstorming` (preferred) or `superpowers:brainstorming` |
| Spec critical-review loop (step 3) | `critical-design-review` → `update-design-doc` |
| Story decomposition structure (step 4) | `thorough-writing-plans` (structural aid only — the output unit is a story issue, not a fine-grained task list) |
| Story critical-review loop (step 4b) | `critical-implementation-review` → `update-implementation-plan` |

<!-- END optional-skills-mapping autocoder-plan v1 -->

## Usage

```bash
# Plan a goal end to end
/autocoder:plan "Add SAML SSO to the admin console"

# Resume/replan against an existing spec issue
/autocoder:plan --spec 42
```

## What This Does

1. Ensures the `decomposed` / `subtask` labels exist
2. Brainstorms the goal into a design doc under `docs/specs/` — **human approves**
3. Commits the doc onto the integration branch (without switching your working tree)
4. Creates a **spec issue** pointing at the doc
5. Runs a critical-design-review loop over the doc (max 3 passes)
6. Decomposes the reviewed spec into 3–8 stories
7. Runs a critical-implementation-review loop over the decomposition (max 3 passes) — **human approves the breakdown**
8. Creates one **story issue** per story, linked to the spec
9. Hands off to the worker fleet

## Instructions

### Step 0: Bootstrap labels

```bash
SCRIPT_DIR=$(
  if [ -d "$(pwd)/plugins/autocoder/scripts" ]; then echo "$(pwd)/plugins/autocoder/scripts"
  elif [ -d "$(pwd)/.claude-plugin/plugins/autocoder/scripts" ]; then echo "$(pwd)/.claude-plugin/plugins/autocoder/scripts"
  else find "$HOME/.claude/plugins/cache" -type d -name "scripts" -path "*/autocoder/*" 2>/dev/null | sort -V | tail -1
  fi
)
source "${SCRIPT_DIR}/issue-fns.sh"

GOAL="${1:-}"

if [ -z "$GOAL" ]; then
  echo "❌ Usage: /autocoder:plan \"<goal>\""
  echo "   Example: /autocoder:plan \"Add SAML SSO to the admin console\""
  exit 1
fi

# Ensure the linkage labels exist. Mirrors the label-bootstrap loop in dev.md:459;
# only the two labels this pipeline depends on are asserted here.
for label in "decomposed:Complex issue broken into sub-tasks:9c27b0" \
             "subtask:Part of a larger decomposed issue:ba68c8"; do
  NAME="${label%%:*}"
  REST="${label#*:}"
  DESC="${REST%:*}"
  COLOR="${REST##*:}"
  gh label create "$NAME" --description "$DESC" --color "$COLOR" 2>/dev/null || true
done

echo "🎯 Planning: $GOAL"
```

> **Note.** Label bootstrap is a no-op on the file backend (labels are free-form strings);
> the `|| true` keeps it harmless when `gh` is absent or the label already exists.

### Step 1: Brainstorm → design doc → integration branch

Invoke `thorough-brainstorming` (fallback `superpowers:brainstorming`) on `$GOAL`. Interactive brainstorming **runs in the manager session** — do not dispatch it to a subagent, which cannot hold a live dialogue with the user.

Write the resulting design to `docs/specs/YYYY-MM-DD-<topic>-design.md`.

**🚦 HUMAN GATE — the design must be approved before continuing.** Present the doc and wait for explicit approval.

Then commit the doc onto the configured integration branch **without switching the working tree**, so worktrees created or rebased afterward contain it (spec §3.2):

```bash
INTEGRATION_BRANCH="${CLAUDE_CODE_INTEGRATION_BRANCH:-$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')}"
INTEGRATION_BRANCH="${INTEGRATION_BRANCH:-main}"
git show-ref --verify -q "refs/heads/$INTEGRATION_BRANCH" || INTEGRATION_BRANCH=master

DOC_PATH="docs/specs/$(date +%Y-%m-%d)-${TOPIC_SLUG}-design.md"

# Build a commit against the integration branch's tree via plumbing, so the
# manager's checked-out branch is irrelevant and its working tree is untouched.
# A TEMPORARY INDEX is used (not `git mktree`, which only builds one flat tree
# level and cannot place a nested path like docs/specs/foo.md).
BASE_COMMIT=$(git rev-parse "$INTEGRATION_BRANCH")
BLOB=$(git hash-object -w "$DOC_PATH")

TMP_INDEX=$(mktemp -t autocoder-plan-index)
rm -f "$TMP_INDEX"   # git wants to create it itself
TREE=$(
  GIT_INDEX_FILE="$TMP_INDEX" \
  sh -c '
    git read-tree "$1" &&
    git update-index --add --cacheinfo "100644,$2,$3" &&
    git write-tree
  ' _ "$BASE_COMMIT" "$BLOB" "$DOC_PATH"
)
rm -f "$TMP_INDEX"

if [ -z "$TREE" ]; then
  echo "❌ Failed to build tree for $DOC_PATH"; exit 1
fi

NEW_COMMIT=$(echo "docs: design spec for ${TOPIC_SLUG}" | git commit-tree "$TREE" -p "$BASE_COMMIT")

# Refuse to move the branch if it advanced while we were building the commit.
git update-ref -m "autocoder:plan design doc" \
  "refs/heads/$INTEGRATION_BRANCH" "$NEW_COMMIT" "$BASE_COMMIT" \
  || { echo "❌ $INTEGRATION_BRANCH moved during planning — re-run /autocoder:plan"; exit 1; }

echo "✅ Design doc committed to $INTEGRATION_BRANCH: $DOC_PATH"
```

> **Why plumbing.** `/autocoder:plan` runs in the manager's host workspace, which may be
> on any branch. `commit-tree` + `update-ref` land the doc on the integration branch that
> worker worktrees derive from, without a checkout. The `update-ref` old-value argument
> (`$BASE_COMMIT`) makes the branch move a compare-and-swap: if anything else advanced the
> branch meanwhile, the update fails rather than clobbering that work.
>
> ⚠️ This advances the integration branch directly, with no PR and no review. That is
> deliberate — the doc must be visible to worktrees — but it is the one place this command
> writes to a shared branch.

### Step 2: Create the spec issue

The spec issue is a **thin pointer** to the canonical doc. Deliberately **no story checklist in the body** — the auto-close monitor enumerates children by the child-side `## Sub-task of #<SPEC>` marker, never by parsing this body.

```bash
SPEC_RESULT=$(issue_create \
  --label "P2" --label "decomposed" \
  --title "Spec: ${GOAL}" \
  --body "$(cat <<SPEC_BODY
## Goal

${GOAL}

## Design Document

Canonical design: \`${DOC_PATH}\` (on \`${INTEGRATION_BRANCH}\`)

The document is the source of truth. This issue tracks implementation progress.

## Stories

Story issues are linked to this spec by the \`## Sub-task of #<this issue>\` header in
each story body. This issue closes automatically once every story is closed.

---

🤖 Created by \`/autocoder:plan\`
SPEC_BODY
)")
SPEC_NUM=$(echo "$SPEC_RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin)['number'])")
echo "✅ Created spec issue #$SPEC_NUM"
```

### Step 3: Critical-review loop on the design doc

Loop, capped at **3 passes** (spec §3.1):

1. Invoke `critical-design-review` on `$DOC_PATH`.
2. If it returns **no findings** → stop, proceed to step 4.
3. Otherwise invoke `update-design-doc` with the review output, then re-review.
4. After 3 passes, stop regardless and **surface residual findings to the human** rather than looping.

Post each pass's summary as a spec-issue comment:

```bash
issue_comment "$SPEC_NUM" --body "## 🔍 Design review — pass ${PASS_NUM}/3

${REVIEW_SUMMARY}

**Result**: ${PASS_RESULT}   <!-- clean | findings applied | residual findings surfaced -->

🤖 \`critical-design-review\` via \`/autocoder:plan\`"
```

If the loop caps out with open findings, say so explicitly and ask the human whether to proceed or revise.

### Step 4: Decompose into stories

Break the reviewed spec into **3–8 stories**. Each story must be:

- **Independently implementable** — no story blocks another mid-flight
- **Independently testable** — has its own acceptance criteria
- **Worker-sized** — one worker can carry it from claim to merge

`thorough-writing-plans` may be used for structure, but the output unit here is a **story issue**, not that skill's fine-grained task contract (spec §3.3).

Note any genuine inter-story ordering as an explicit dependency in the story body rather than splitting differently.

### Step 4b: Critical-review loop on the decomposition

Same shape as step 3, capped at **3 passes** (spec §3.4), run **before any story issue is created**:

1. Invoke `critical-implementation-review` on the story breakdown.
2. No findings → stop.
3. Otherwise `update-implementation-plan`, then re-review.
4. Cap at 3; surface residual findings.

This catches missing stories, wrong boundaries, and hidden inter-story dependencies before they become worker-level bugs.

**🚦 HUMAN GATE — the human approves the reviewed breakdown before step 5 creates issues.**

### Step 5: Create story issues

For each approved story. The `## Sub-task of #${SPEC_NUM}` header is an **exact string** — it is the authoritative parent link the auto-close monitor enumerates by (see `dev.md`, "Monitoring Decomposed Issues"). Body shape follows `dev.md:1249–1275`.

```bash
STORY_NUMBERS=()

# Repeat per story:
STORY_RESULT=$(issue_create \
  --label "P2" --label "subtask" \
  --title "${STORY_TITLE}" \
  --body "$(cat <<STORY_BODY
## Sub-task of #${SPEC_NUM}

Story from the spec above. Design context: \`${DOC_PATH}\` on \`${INTEGRATION_BRANCH}\`.

## Description
${STORY_DESCRIPTION}

## Design Context
${STORY_CONTEXT}

## Acceptance Criteria
- [ ] ${CRITERION_1}
- [ ] ${CRITERION_2}

## Dependencies
- Part of #${SPEC_NUM}
- ${STORY_DEPENDENCIES:-None}

## Testing
${STORY_TESTING}

---

🤖 Created by \`/autocoder:plan\` from #${SPEC_NUM}
STORY_BODY
)")
STORY_NUM=$(echo "$STORY_RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin)['number'])")
STORY_NUMBERS+=("$STORY_NUM")
echo "✅ Created story #$STORY_NUM"
```

Story bodies carry enough context to act even if a worker's branch is stale (spec §3.2).

Post the checklist as a **comment** on the spec issue — for human visibility only, never parsed:

```bash
issue_comment "$SPEC_NUM" --body "## 📋 Stories

$(for num in "${STORY_NUMBERS[@]}"; do echo "- [ ] #$num"; done)

This spec closes automatically once all stories are closed.

🤖 \`/autocoder:plan\`"
```

### Step 6: Hand off

```bash
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "✅ Planning complete"
echo "═══════════════════════════════════════════════════════════════"
echo "  Spec issue:  #$SPEC_NUM"
echo "  Design doc:  $DOC_PATH (on $INTEGRATION_BRANCH)"
echo "  Stories:     ${STORY_NUMBERS[*]}"
echo ""
echo "The worker fleet (/dev-loop → /dev) will pull the 'subtask' stories,"
echo "implement each with TDD, comment progress, validate, merge, and close."
echo "Spec #$SPEC_NUM auto-closes when every story is closed."
echo ""
echo "Next: /start-parallel-agents  (or /add-worker N to scale up)"
echo "      /monitor-workers        (watch progress)"
```

## Gates Summary

| Step | Gate | Type |
|---|---|---|
| 1 | Design doc approved | 🚦 Human |
| 3 | Design review loop | Autonomous, capped at 3 passes |
| 4b | Decomposition review loop | Autonomous, capped at 3 passes |
| 4b | Breakdown approved | 🚦 Human |

Unlike `/dev` and `/dev-loop`, this command is **manager-facing and interactive** — its human gates are real stop-and-ask gates, not autonomous resolutions.

## See Also

- `/dev` — implement a single issue autonomously
- `/dev-loop` — continuous autonomous issue processing
- `/monitor-workers` — watch the fleet; suggests `/autocoder:plan` when the backlog runs low
- `/brainstorm-issue` — brainstorm one existing issue (narrower than this pipeline)
- `/review-blocked` — review issues workers escalated
