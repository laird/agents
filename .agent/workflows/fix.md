# Start Autonomous Fix of GitHub Issues

Analyze all open GitHub issues, prioritize them, and begin systematically fixing or implementing them starting with the highest priority.

## Optional skill enhancements

<!-- BEGIN optional-skills-prelude v3 — keep in sync across all command files; see plugins/shared/optional-skills-prelude.md -->

If a named skill appears in your available skills list (delivered in the session-start system-reminder), invoke it via the `Skill` tool at the indicated step. Otherwise, follow the inline protocol below — it remains the source of truth and is unchanged by this section.

Platform note: in Gemini CLI / Antigravity, skills activate via `activate_skill` instead of the `Skill` tool; in Codex they activate as `$<skill>`; in Factory Droid they load from the skills tree. The mapping is otherwise identical on all four platforms.

**Skill-name matching.** Match each table entry as an exact string. Mapping tables use fully-qualified names (`<plugin>:<skill>`) for plugin-installed skills and bare names for personal toolkit skills. Compound Engineering skills are the exception: match them in **either** form — fully-qualified `compound-engineering:ce-<name>` (how Claude Code lists them) or bare `ce-<name>` (how Codex, Factory Droid, and Antigravity list them). pstack skills match as fully-qualified `pstack:<name>` (how Claude Code and Codex list them). A bare `<name>` counts as pstack only when bare `poteto-mode` is also in your available-skills list, which marks a skills-only pstack install; otherwise a bare `tdd` or `how` is a personal toolkit skill and gets no pstack precedence.

**Notation.** `A → B → C` means sequence (invoke in order). `A + B + C` means independent facets (all apply, order irrelevant). `A (primary)` means A is the orchestration spine. A leading `→` on a row indicates "next in sequence if applicable."

**pstack precedence.** pstack (https://github.com/michael-denyer/pstack-claude) outranks Compound Engineering, `superpowers:*`, and personal toolkit skills for the role below. If the listed `pstack:*` skill appears in your available-skills list, invoke it *in place of* every skill in the "In place of" column, including a Compound Engineering skill that would otherwise substitute for it. Roles pstack does not cover fall through to the Compound Engineering table. In an unattended run, take `pstack:interrogate`'s intent statement from the issue or plan instead of asking the user.

| Role | Use when installed | In place of |
|---|---|---|
| reviewing written code | `pstack:interrogate` | `ce-code-review`, `superpowers:requesting-code-review` |

Mapping tables also name pstack skills directly where no other plugin covers the step: `pstack:tdd` (bug regression test), `pstack:how` (understand unfamiliar code), `pstack:deslop` (clean the diff), `pstack:blast-radius` (what a change breaks beyond its diff), and `pstack:unslop` / `pstack:technical-writing` (prose this command authors). Run `pstack:blast-radius` without its `arena` escalation, and write its proof scripts outside the working tree so they are never committed.

**pstack orchestrators are not invoked.** This command's inline protocol is the spine. Do not enter `pstack:poteto-mode`, `pstack:figure-it-out`, `pstack:swarm`, `pstack:arena`, `pstack:architect`, `pstack:babysit`, or `pstack:make-pr-easy-to-review`, including when another pstack skill's steps tell you to run one. Each owns its own playbook, dispatch, implementation, or PR tail and would bypass worktree naming, the issue-claim sequence, and the configured Merge Mode. pstack's SessionStart hook injects "Invoke the `pstack:poteto-mode` skill ... when a task touches more than one file" at startup and after every compaction. Ignore that instruction while this command runs, every time it reappears. The hook defers only to CLAUDE.md, AGENTS.md, and direct requests, so for unattended workers also set `session hook: off` in `pstack-models.md` (see `docs/PSTACK.md`).

**Compound Engineering precedence.** If a skill from the `compound-engineering` plugin covers a role in the table below and appears in your available-skills list, invoke it *in place of* the skill named in the mapping tables for that role. Compound Engineering outranks both `superpowers:*` and personal toolkit skills (pstack outranks it, per the table above), and this rule overrides any "(preferred)" annotation a mapping table places on a substituted skill. Roles with no entry below are unaffected.

| Role | Use when installed | In place of |
|---|---|---|
| design exploration / requirements | `ce-brainstorm` | `thorough-brainstorming`, `superpowers:brainstorming` |
| implementation planning | `ce-plan` | `thorough-writing-plans`, `superpowers:writing-plans` |
| executing a plan | `ce-work`, invoked as `mode:return-to-caller <plan path>` | `superpowers:executing-plans` |
| debugging a defect | `ce-debug` | `superpowers:systematic-debugging` |
| reviewing a spec, plan, or report document | `ce-doc-review` | `critical-design-review`, `critical-implementation-review`, `update-design-doc`, `update-implementation-plan` |
| reviewing written code | `ce-code-review` | `superpowers:requesting-code-review` |
| acting on review feedback **on an existing PR** | `ce-resolve-pr-feedback` | `superpowers:receiving-code-review` |
| session handoff | `ce-handoff` | `create-handoff`, `resume-handoff` |

Three deliberate exclusions:

- **Worktree provisioning and branch finishing are not substituted.** `superpowers:using-git-worktrees` and `superpowers:finishing-a-development-branch` remain in force — do **not** substitute `ce-worktree`, `ce-commit-push-pr`, `ce-commit`, or `lfg` for them — because the inline protocol owns worktree naming, the issue-claim sequence, and the configured Merge Mode. `ce-work` is substituted for plan execution only, which is why the table requires `mode:return-to-caller`: bare `ce-work` owns its own shipping tail and would bypass all three.
- **`completion-review` is never substituted.** It is a plan-vs-delivery audit, not a diff review, and it runs on Document deliverables (`/retro`, `/fix`'s Document row) where a code reviewer has nothing to read. Run it as the mapping tables specify, alongside the code reviewer (`pstack:interrogate` or `ce-code-review`) rather than replaced by it.
- **Review feedback with no PR open.** When findings came from an in-session reviewer (`pstack:interrogate` or `ce-code-review`) and no PR exists yet, act on them via the inline protocol or `superpowers:receiving-code-review`; `ce-resolve-pr-feedback` requires GitHub PR threads.

**Failure semantics.** Not-installed: silent fallback. Mid-run failure or interruption of an installed skill: surface the failure message, fall back to the inline protocol for the rest of that step, no retry. Self-skip (e.g., `<SUBAGENT-STOP>`): silent fallback, not treated as failure. If at least one `superpowers:*` skill named in this command's mapping table is missing from your available-skills list **and no installed pstack or Compound Engineering skill covers its role**, emit one consolidated recommendation line at command entry: *Tip: this command works best with the `superpowers` plugin (https://github.com/obra/superpowers) — install via `/plugin install superpowers@claude-plugins-official`.* Never emit such notices for pstack, Compound Engineering, or personal toolkit skills.

**Skills are advisory, not gating.** A command's completion criteria are defined by its inline protocol. Optional skill outcomes are surfaced and considered, but do not override inline success criteria. "Always applied" in a mapping table means the skill is invoked when installed; outcomes remain advisory. When a command claims success while an advisory skill earlier in the run surfaced a failure, the success summary acknowledges the advisory finding.

**Version trust.** Skills are matched by name; the integration does not pin or verify versions. If a tracked skill's contract changes in a way that breaks the chain, the integration is stale and must be updated.

<!-- END optional-skills-prelude v3 -->

<!-- BEGIN optional-skills-mapping fix v2 — keep in sync between Claude/Antigravity mirrors of this command -->

`/fix` accepts heterogeneous work — bug fixes, feature implementation, refactoring, increasing test coverage, docs/config/chore, or proposing new tasks. The agent classifies the work after reading the issue and applies the matching skills along two axes: deliverable type and kind of work.

**Composition rule.** Step 2 and Step 3 compose by **union**: apply every skill named in either step. Where both steps name the same skill, apply it once. Where the two steps disagree on whether a skill is required vs. optional, the **stronger requirement wins** (a skill marked required in one step is required overall). Step 1 (deliverable classification) is purely a routing input to Step 2 and produces no skills of its own.

**Ordering across steps.** When Step 3 contributes a sequence (`A → B → C`), that sequence defines the spine. Step 2 facets attach at conventional points:
- **Provisioning facets** (e.g., `superpowers:using-git-worktrees`) attach at spine entry — before the first sequence step runs.
- **Verification facets** (e.g., `superpowers:verification-before-completion`, `pstack:blast-radius`) attach at spine exit — after the last sequence step. `pstack:deslop` edits code, so it runs first, on `git diff $INTEGRATION_BRANCH...HEAD` (not `main`), and verification runs after it: `pstack:deslop` → `superpowers:verification-before-completion`.
- **Wrap-up facets** (e.g., `completion-review`, `superpowers:requesting-code-review` → `superpowers:receiving-code-review`) attach after spine exit and after verification.

Where Step 3 contributes only a single skill or no sequence, treat it as a one-step spine and apply the same attachment points. Where a facet has no obvious attachment category, attach at spine exit.

**Step 1: classify the deliverable.**

| Deliverable type | Examples |
|---|---|
| **Branch** (code merged to main) | bug fix, new feature, refactor, increasing test coverage, docs/config/chore committed to the repo |
| **Document** (proposal, report, analysis) | proposing new tasks, investigation findings |
| **Throwaway** (spike, experiment) | rare; ad-hoc evaluation work that won't be merged |

**Step 2: apply the matching skills based on deliverable type.** "Always" below means the skill is invoked when installed; outcomes remain advisory.

| Applies when deliverable is... | Skill mapping |
|---|---|
| **Branch** | `superpowers:using-git-worktrees` + `pstack:deslop` → `superpowers:verification-before-completion` + `completion-review` (always); `pstack:blast-radius` (when the change alters a signature, contract, or behavior other code depends on); `superpowers:requesting-code-review` → `superpowers:receiving-code-review` (when seeking merge) |
| **Document** | `completion-review` + `pstack:unslop` (on text this issue authors, not on existing files it edits) |
| **Throwaway** | none of the above are required |

**Step 3: apply the matching skills based on kind of work.**

| If the work is... | Use these skills |
|---|---|
| Bug / unexpected behavior | `pstack:how` (only when the affected code is unfamiliar) → `superpowers:systematic-debugging` → `pstack:tdd` (preferred) or `superpowers:test-driven-development` |
| New feature / unclear requirement | `thorough-brainstorming` → `thorough-writing-plans` → `superpowers:test-driven-development` (fallback: `superpowers:brainstorming` → `superpowers:writing-plans`; optional `critical-design-review` after brainstorming, `critical-implementation-review` after writing-plans) |
| Refactor / restructuring | `pstack:how` (only when the code is unfamiliar) → `superpowers:test-driven-development` (characterization tests) → refactor under green |
| Increasing test coverage | `autocoder:improve-test-coverage` → `superpowers:test-driven-development` for new tests |
| Proposing new tasks | `thorough-brainstorming` (preferred) or `superpowers:brainstorming` → `critical-design-review` |
| Docs / config / chore | TDD optional |

<!-- END optional-skills-mapping fix v2 -->

## Usage

```bash
# Automatic priority-based selection (processes all issues in priority order)
/fix

# Target a specific issue directly (skips priority selection)
/fix 223
```

**With issue number**: Skips the priority selection process and immediately starts working on the specified issue, regardless of its priority label.

**Without issue number**: Fetches all open issues with priority labels (P0-P3) and processes them in priority order.

## What This Does

### Bug Fixing Phase (Priority)
1. Creates priority labels (P0, P1, P2, P3) if they don't exist
2. Fetches all open GitHub issues with priority labels
3. Identifies the highest priority issue (P0 > P1 > P2 > P3)
4. **For simple issues**: Directly troubleshoot and fix
5. **For complex issues**: Use superpowers skills to plan and execute
6. After fixing, moves to the next issue
7. Continues until all bug issues are resolved

### Regression Testing Phase
8. **When no priority bugs exist**: Run full regression test suite
9. Analyze regression test results and create GitHub issues for failures
10. Loop back to bug fixing if new issues are created

### Enhancement Phase (when no bugs)
11. Check for existing enhancement issues
12. **If enhancements exist**: Use superpowers to design, plan, and implement each one
13. Run tests after implementation
14. **If tests pass**: Commit, merge, and close enhancement
15. **If tests fail**: Create bug issues for failures, pause enhancement, fix bugs first
16. Repeat until all existing enhancements are implemented

### Propose New Enhancements (lowest priority)
17. **Only when no bugs AND no existing enhancements**: Propose new improvements
18. Use `thorough-brainstorming` (preferred) or `superpowers:brainstorming` to identify valuable enhancements
19. Create enhancement issue with detailed implementation plan
20. Loop back to Enhancement Phase to implement

Never stop, just keep looking for issues to address. Priority: Triage Unprioritized > Bugs > Existing Enhancements > Proposing New Enhancements.

**Note**: This command automatically reviews and prioritizes any open issues that lack priority labels (P0-P3) before processing the issue queue.

## Unprioritized Issue Triage

Moved to `.agent/shared/fix-triage.md` (#240). Read it when the configuration block prints `UNPRIORITIZED_ISSUES_FOUND=true`.

## Issue Complexity Detection

**Simple Issues** (direct fix):
- Single file changes
- Configuration tweaks
- Small bug fixes
- UI visibility issues
- Test timeout adjustments
- Removing deprecated code

**Complex Issues** (use superpowers if available):
- Multiple failing tests (>10 failures)
- Feature implementations
- Architecture changes
- Multi-file refactoring
- New functionality requiring design
- System integration issues

**Ultra-Complex Issues** (use quint if available):
- Major architecture decisions with significant trade-offs
- Issues requiring human judgment on business/product direction
- Problems too large for autonomous resolution (>100 test failures)
- Cross-cutting concerns affecting multiple systems
- Decisions with irreversible consequences
- When superpowers approaches have failed twice

## Model Selection

Model tiers are resolved from env vars → `.autocoder.json` → built-in defaults.
Agents inherit credentials from the running Gemini/Antigravity session — no separate API keys needed.
See `.agent/shared/model-config.md` for full reference and override instructions.

| Tier | Default (Gemini/Antigravity) | Used for |
|------|-----------------------------|---------|
| **Deep** (`$MANAGER_MODEL`) | `pro` | P0/P1 issues, root cause, proposals |
| **Balanced** (`$WORKER_MODEL`) | `flash` | P2/P3 fixes, plan execution, analysis |
| **Fast** (`$FAST_MODEL`) | `flash` | Labels, comments, commit messages |

### Escalation Triggers

Start at `$WORKER_MODEL`; escalate to `$MANAGER_MODEL` when:
- Fix attempt fails after 2 tries with the same approach
- Root cause spans 5+ files requiring coordinated changes
- Issue is labelled P0 or P1

### Example Task Tool Usage

```javascript
// Standard fix — use $WORKER_MODEL
Task("coder", "Fix dependency conflict in package.json...", model=WORKER_MODEL)

// Complex root cause — use $MANAGER_MODEL
Task("debugger", "Investigate why 15 tests fail with timeout...", model=MANAGER_MODEL)

// Mechanical task — use $FAST_MODEL
Task("labeler", "Add P2 label to issue #${ISSUE_NUM}...", model=FAST_MODEL)
```

## Context Management (MANDATORY — NON-NEGOTIABLE)

> ⛔ **STOP. Before you touch ANY new issue, you MUST compact your context. Every issue. Every time. No exceptions.**
>
> - **Antigravity:** run `/compact`.
> - **Codex / Gemini / other sessions:** clear or compact the session context using your session controls (the equivalent of `/compact`).
>
> This is not optional and not a suggestion. A long-running fix-loop **WILL** exhaust the context window and crash the agent mid-issue if you skip this. Compacting between issues is the single most important thing keeping the loop alive — treat skipping it as a defect.

**Rules — follow exactly:**

1. **Compact BEFORE fetching or starting every new issue.** Every iteration, without exception.
2. **Each issue starts from a fresh, compacted context.**
3. **NEVER carry over detailed investigation notes** from a previous issue — the compacted summary is sufficient.
4. **If you ever notice you've started a new issue without compacting, compact immediately** before doing anything else.

## Instructions

Start working on GitHub issues now:

```bash
# Source issue function layer (routes to GitHub or file backend)
# Resolve SCRIPT_DIR — see scripts/README.md#script-dir
SCRIPT_DIR=$(
  for d in "$(pwd)/.agent/scripts" \
           "$(pwd)/plugins/autocoder/scripts" \
           "$(pwd)/.claude-plugin/plugins/autocoder/scripts"; do
    if [ -f "$d/issue-fns.sh" ]; then echo "$d"; exit 0; fi
  done
  # Fallback: the installed plugin. Only <ver>/scripts is a complete tree;
  # <ver>/skills/autocoder/scripts is a subset that sorts after it (#142).
  # Rank by the <ver> directory alone, not the whole path: with two marketplaces
  # in the cache, a whole-path sort lets the marketplace name decide (#201).
  find "$HOME/.agent/plugins/cache" -type d -name "scripts" -path "*/autocoder/*" -not -path "*/skills/*" 2>/dev/null \
    | while read -r d; do if [ -f "$d/issue-fns.sh" ]; then echo "$d"; fi; done \
    | awk -F/ '{print $(NF-1) "\t" $0}' | sort -V -t$'\t' -k1,1 | tail -1 | cut -f2-
)
if [ ! -f "${SCRIPT_DIR}/issue-fns.sh" ]; then
  echo "autocoder: cannot locate issue-fns.sh (resolved SCRIPT_DIR='${SCRIPT_DIR}')" >&2
  exit 1
fi
source "${SCRIPT_DIR}/issue-fns.sh"
```

```bash
# Preflight: cheap check whether there's any claimable work before paying
# the LLM cost of the full /fix flow. See spec §5.
issue_any_claimable
case $? in
  0) ;;  # work exists; fall through
  1) echo "No claimable issues. Nothing to do."; exit 0 ;;
  *) echo "Backend error while checking for claimable issues"; exit 1 ;;
esac
```

```bash
# Configuration and setup live in fix-config.sh (#293): the project config
# (TEST_COMMAND, BUILD_COMMAND, MERGE_MODE),
# appending the autocoder section to GEMINI.md when it is missing; the gh identity
# check; model tiers (MANAGER/WORKER/FAST_MODEL); superpowers/quint detection
# (SUPERPOWERS_AVAILABLE, QUINT_AVAILABLE); label reconciliation; and the
# unprioritized-issue scan. It hands its variables back in a file of printf-%q
# lines. Act on what it prints: see "Configuration markers" below this block.
FIX_CONFIG_ENV=$(mktemp "${TMPDIR:-/tmp}/autocoder-config.XXXXXX")
MANAGER_MODEL="${MANAGER_MODEL:-}" WORKER_MODEL="${WORKER_MODEL:-}" FAST_MODEL="${FAST_MODEL:-}" \
  INTEGRATION_BRANCH="${INTEGRATION_BRANCH:-}" "${SCRIPT_DIR}/fix-config.sh" --platform gemini --out "$FIX_CONFIG_ENV" || exit 1
source "$FIX_CONFIG_ENV"; rm -f "$FIX_CONFIG_ENV"
export MANAGER_MODEL WORKER_MODEL FAST_MODEL

# Claim, selection and branch setup live in claim-issue.sh (#289). It works the
# issue named in /fix's argument, or picks the highest-priority claimable one;
# takes the lock (dependency refusal, #182 resume, remote-branch and start-marker
# locks, claim-then-verify); pulls the branch this worktree is on and creates or switches to
# feature/issue-<N> from it (recorded as PARENT_BRANCH); and posts the work-started comment.
# It hands its variables back in a file of printf-%q lines. Exit codes: see
# "Claim exit codes" below this block.
CLAIM_ENV=$(mktemp "${TMPDIR:-/tmp}/autocoder-claim.XXXXXX")
INTEGRATION_BRANCH="${INTEGRATION_BRANCH:-}" "${SCRIPT_DIR}/claim-issue.sh" --base parent --out "$CLAIM_ENV" "${1:-}"
CLAIM_RC=$?
source "$CLAIM_ENV"; rm -f "$CLAIM_ENV"
[ "$CLAIM_RC" -eq 0 ] || exit "$CLAIM_RC"
[ "$CLAIM_STATUS" = "claimed" ] || exit 0   # idle: IDLE_NO_WORK_AVAILABLE was printed

echo ""
echo "🎯 Highest Priority Issue to Fix"
echo "════════════════════════════════════════"
echo "Issue: #$ISSUE_NUM"
echo "Priority: P$ISSUE_PRIORITY"
echo "Title: $ISSUE_TITLE"
echo ""
# The spec is the body plus the comment thread (#134); print all of it.
ISSUE_SPEC=$("${SCRIPT_DIR}/issue-spec.sh" "$ISSUE_NUM") || {
  echo "⚠️  Could not read the comment thread for #$ISSUE_NUM — showing the body only. Read the comments yourself before writing code."
  ISSUE_SPEC="$ISSUE_BODY"
}
echo "Specification (body, then comments — a later comment overrides the body):"
echo "$ISSUE_SPEC"
echo ""
echo "════════════════════════════════════════"
echo ""
echo "📋 Starting work on issue #$ISSUE_NUM..."
echo ""

# ── Task scope gate ──────────────────────────────────────────────────────────
# MANDATORY: Before writing any code, assess whether this task fits in one
# agent context window and whether it can run safely in a worktree swarm.
#
# Ask yourself:
#   1. CONTEXT FIT: Can all required reading, reasoning, and implementation
#      complete in a single conversation without hitting context limits?
#      Red flags: "rewrite the authentication system", "migrate all API calls",
#      "audit every file in src/", tasks described in >1000 chars with no
#      clear single deliverable.
#
#   2. WORKTREE INDEPENDENCE: Can this work in an isolated worktree without
#      conflicting with other parallel worktrees working other issues?
#      Red flags: changes to shared config files (tsconfig.json, package.json,
#      migrations, schema files) that other agents might also need to change;
#      or changes that require knowing the final state of another in-flight issue.
#      A sub-task that touches the same file as a sibling sub-task is NOT
#      independent — it must be sequenced, not parallelized.
#
#   3. REVIEW FIT: Can a human review the result? Estimate the change, NOT
#      counting parity mirrors (.agent/, plugins/*/skills/, codex-plugins/,
#      .factory/). If it is likely to exceed reviewFit.maxChangedLines (default
#      400 changed lines) or reviewFit.maxFiles (default 10) in .autocoder.json,
#      it fails this test. This is the ONLY point where work is split for size:
#      finished work over the limit is published anyway, labelled
#      `needs-review-focus` (see "Review Digest" below), never split after the fact.
#
# If this issue FAILS any test → DECOMPOSE IT NOW (before any implementation):
#   - Decompose into 3-8 sub-tasks, each satisfying all three criteria above
#   - Create each sub-task as a new issue with `subtask` label and a
#     "Sub-task of #${ISSUE_NUM}" line in the body
#   - Add the `decomposed` label to this parent issue and release the claim
#   - Exit; workers will pick up the independent sub-tasks on the next tick
#
# If this issue PASSES all three tests → start the work on this branch.
#
# See .agent/shared/fix-decomposition.md ("Ultra-Complex Issues - Decompose into Sub-Tasks")
# for the full decomposition protocol including sub-task body template.
# ────────────────────────────────────────────────────────────────────────────
```

**Configuration markers (`fix-config.sh`).** The block above prints these lines; act on each one you see:

- `MERGE_MODE_NOT_CONFIGURED=true`: GEMINI.md has no Merge Mode section. Follow "First-Run: Configure Merge Mode" below.
- `ACTION_REQUIRED: Ask the user now`: no model tiers are configured. Ask the printed question using the platform's question tool and do not proceed until the user answers; then export their values, or save the defaults to `.autocoder.json`, as the printed text says.
- `UNPRIORITIZED_ISSUES_FOUND=true`: the issues listed between `UNPRIORITIZED_DATA<<EOF` and `EOF` need a priority. Follow "Unprioritized Issue Triage" above.

**Claim exit codes (`claim-issue.sh`).** The block above stops with the script's exit code; read the output to see which case you are in.

- **0, claimed:** you hold the `working` lock, the worktree is on `feature/issue-$ISSUE_NUM`, and the work-started comment is posted. The block has set `ISSUE_NUM`, `ISSUE_TITLE`, `ISSUE_BODY`, `ISSUE_PRIORITY`, `RESUMING`, `FIX_BRANCH`, `INTEGRATION_BRANCH`, `PARENT_BRANCH` (the branch you started from; the landing section merges back into it); set the same values in every later block. `RESUMING=true` means this worktree resumed its own claim (#182): re-read the comments and `git log origin/$INTEGRATION_BRANCH..HEAD` and do not redo finished work.
- **0 with `IDLE_NO_WORK_AVAILABLE`:** nothing is claimable. Stop; there is no issue to work.
- **1, refused or failed:** the message says why (issue not found, dependencies still open, another agent's remote branch or start marker, a lost claim race, a fetch or branch failure). Any lock this run took has been released, and a lock held by another agent is left alone. Do not work the issue.
- **2, resumed claim with a rebase conflict:** the worktree is mid-rebase on `feature/issue-$ISSUE_NUM` and keeps `working`. Resolve the conflicting files keeping both sides' behaviour, run `git rebase --continue`, re-run the tests, and carry on with this issue (the variables are set as for exit 0).

**Build from the body *and* the comments — a later comment overrides the body.** The specification printed above (`issue-spec.sh`) is the issue body followed by every comment, oldest first, with autocoder's claim and work-started markers filtered out. Review deltas, corrected API contracts, narrowed scope and "that earlier instruction was wrong" all arrive as comments, so the body alone is the stalest spec on the page (#134). Read the whole thread before writing code, and re-read it (`issue-spec.sh "$ISSUE_NUM"`) immediately before launching the merge, in case a correction landed while you worked. In the merge summary or PR body, name the comment you built to (e.g. "built to comment 3 by `<author>`, which supersedes the body's `onConflict` default"), or say "body only — no correcting comments" — so a worker that missed a correction is caught in review, not after merge.

## First-Run: Configure Merge Mode

Moved to `.agent/shared/fix-first-run.md` (#240). Read it when the configuration block prints `MERGE_MODE_NOT_CONFIGURED=true`.

## CRITICAL: Release the 'working' Label Only on a Terminal Outcome

The `working` label is the concurrency lock. It is held for the **whole life of
the claim**, not per commit. An open issue with no `working` label is, by
definition, claimable — so dropping the lock while the issue is still open and
still yours re-exposes it to the pool and invites a peer to duplicate your work.

**Release the lock ONLY when the claim has actually ended:**

| Terminal outcome | Release? | Also required |
|---|---|---|
| Issue closed (merged / resolved) | ✅ yes | — |
| PR opened (`pr` merge mode) | ✅ yes — as a hand-off | swap `working` for `awaiting-integration` in the same step, so the issue stays out of the claimable pool until the merge closes it |
| Merge launched (`merge` merge mode) | ✅ yes — as a hand-off | the detached job (`merge-launch.sh --own-issue`) swaps `working` for `merging` itself as its first act; this worker writes NO label after the launch returns. The job retires `merging` when it closes the issue, parks it under `awaiting-integration` (landed but not provably green, or not yet shipped), or escalates it to `needs-clarification`; the sentinel re-queues it if the job dies |
| Blocked (`needs-design`, `needs-clarification`, `needs-approval`, `too-complex`, `future`) | ✅ yes | post a release comment in the same step |
| Deliberately skipped or abandoned | ✅ yes | post a release comment in the same step |
| Could not switch to the feature branch (claim never started) | ✅ yes | — |

**NEVER release the lock for any of these:**

- After a **partial** commit, or a commit titled `#N (partial): …`
- Between batches of an implementation plan
- Because you are compacting context, pausing, or handing off mid-issue
- Because you *think* you are done — "done" means the issue is **CLOSED**, not
  "the last commit landed"
- Because you are moving on to another issue while this one is still open —
  that is an abandonment, so release it via the explicit-release path below
  (with a comment), not silently

```bash
# Correct: terminal outcome only, and only after the publication gate
# (PUSH_OK / merge-to-integration.sh) has passed. Pair the release with the close.
issue_close "$ISSUE_NUM" --comment "✅ Resolved — <summary>"
issue_update "$ISSUE_NUM" --remove-label "working" 2>/dev/null || true
```

```bash
# WRONG — this is issue #14. The issue is still OPEN, so removing the lock
# hands it straight back to the claimable pool while you still hold the branch.
git commit -m "#${ISSUE_NUM} (partial): first half of the refactor"
issue_update "$ISSUE_NUM" --remove-label "working" 2>/dev/null || true
```

### Explicit release (blocked, skipped, or abandoned)

A release that is not a close must be **visible**, so peers and
`/monitor-workers` can tell a deliberate hand-off from a crashed worker. Always
comment first, then drop the label:

```bash
issue_comment "$ISSUE_NUM" --body "🔓 **Releasing claim**

**Reason**: <blocked on X | skipped because Y | abandoning, see below>
**Branch**: \`feature/issue-${ISSUE_NUM}\` (<pushed | discarded>)
**State left behind**: <what is done, what remains>

Releasing the \`working\` lock so another agent can pick this up."
issue_update "$ISSUE_NUM" --remove-label "working" 2>/dev/null || true
```

**Never add a blocking label without also releasing the lock.** `add-blocking-label.sh`
does both for you; if you add `needs-design`, `too-complex`, `needs-clarification`,
`needs-approval`, or `future` directly via `issue_update` or `/update-issue`, you
must remove `working` and post the release comment in the same step.

### Holding the lock across a pause

If you are still working the issue — mid-plan, compacting context, resuming next
iteration — **keep the label**. The `feature/issue-<N>` branch plus the
work-started comment are the proof the lock is live. An abandoned lock is not
your problem to clean up mid-flight: `/monitor-workers` detects locks with no
agent activity and reclaims them with human confirmation.

## Pre-Landing Review Gate (MANDATORY)

**Order: trial-rebase first, then review (#222).** The shared landing section ("Landing the Work") rebases onto
the integration branch before its review check. A rebase that moves HEAD invalidates the
review record, so run that trial rebase *before* this gate. Reviewing first and rebasing
after means reviewing twice.

Tests prove the change does what its tests check; they say nothing about whether
it does what the issue asked, stays in scope, or opens a hole. Every landing
site below runs this gate **after the final commit and before the push** — so
before the `git merge` in `merge` mode and before `gh pr create` in `pr` mode
(#147). The landing code refuses to publish unless the review record for the
**current `HEAD`** says `Verdict: pass`. The record is a file inside `.git/`,
not a shell variable, so it survives across tool calls, is per-repo, and goes
stale the moment another commit lands on the branch.

**Setting.** `.autocoder.json` `"review"`: `"always"` (default — both modes),
`"merge-only"` (skip in `pr` mode, where a human reviews), or `"off"`. A skipped
review still writes a record saying so, so the trail shows it was skipped and
not forgotten.

**Risk tiers (#165).** `.autocoder.json` may list high-risk path globs:
`"risk": {"high": [".github/workflows/**", "**/install*.sh"]}`. Each landing
block asks `landing-mode.sh` how to land: a diff that touches any of those paths
lands as a pull request (and parks under `awaiting-integration`) even when Merge
Mode is `merge`; every other diff lands as configured. The globs are read from
the integration branch, not the working tree, so a branch cannot lower its own
tier, and `.autocoder.json` itself counts as high-risk while any are set. `*`
stays within one path segment and `**` spans directories. With no `risk` key,
nothing changes. This review never counts as the human approval a high-risk
change needs.

```bash
# The issue being landed: ISSUE_NUM, or ENHANCE_NUM in the enhancement flow.
REVIEW_ISSUE="${REVIEW_ISSUE:?set REVIEW_ISSUE to the issue being landed (ISSUE_NUM, or ENHANCE_NUM for an enhancement)}"
REVIEW_FILE="$(git rev-parse --git-common-dir)/autocoder-review-${REVIEW_ISSUE}.md"
REVIEW_SETTING=$(python3 -c "import json; print(str(json.load(open('.autocoder.json')).get('review','always')).lower())" 2>/dev/null || echo always)
git fetch -q origin "${INTEGRATION_BRANCH:?INTEGRATION_BRANCH unset — re-run the configuration block above}"
REVIEW_BASE=$(git merge-base HEAD "origin/${INTEGRATION_BRANCH}") \
  || { echo "❌ cannot find the merge base with origin/${INTEGRATION_BRANCH} — nothing to review against"; exit 1; }
rm -f "$REVIEW_FILE"   # never inherit an earlier attempt's verdict
# Same reading as the landing code: only an exact "pr" takes the PR path, so only
# "pr" may skip under merge-only. An unset mode must fail, not default to a skip.
REVIEW_MODE="${MERGE_MODE:?MERGE_MODE unset — re-run the configuration block above}"
if [ "$REVIEW_SETTING" = "off" ] || { [ "$REVIEW_SETTING" = "merge-only" ] && [ "$REVIEW_MODE" = "pr" ]; }; then
  printf '## Review\nSkipped: `.autocoder.json` review=%s (merge mode %s).\n\nReviewed-HEAD: %s\nVerdict: pass\n' \
    "$REVIEW_SETTING" "$REVIEW_MODE" "$(git rev-parse HEAD)" > "$REVIEW_FILE"
fi
git diff --name-only "$REVIEW_BASE"..HEAD   # the paths under review
```

**1. Review in a fresh context.** Self-review in the session that wrote the code
inherits its blind spots. Run `/code-review` on the branch where your platform provides it (or `ce-code-review` /
`superpowers:requesting-code-review` per the skill table above). Where none is
available, launch fresh subagents with no shared context — 2–3 in parallel at
`$FAST_MODEL`, each with one lens and told to refute the change: **correctness**,
**scope creep**, **security**. Give every reviewer the same three inputs: the
diff (`git diff "$REVIEW_BASE"..HEAD`), the repo (to read callers and
neighbouring code), and the issue's title, body and comments (the intent the
diff must satisfy). If the repo has a `REVIEW.md` at its root, give it to every
reviewer too, as the repo's review rules (#169): what failure looks like there,
the nit cap, paths to skip, and how to write findings. Where it and this gate
differ, the gate's tags and blocking rules still decide what blocks landing.
`/install` writes a starter `REVIEW.md` (`scaffold-review-md.sh`).

**2. Security review on sensitive diffs.** If any changed path is sensitive,
also run `/security-review` (or a fresh security-lens subagent where it is not
available). Sensitive means: the `risk.high` globs in `.autocoder.json` when
present (#165), otherwise CI workflows (`.github/workflows/**`), hooks,
install/setup scripts, merge/push/sentinel scripts, auth, credentials or secret
handling, crypto, and dependency manifests or lockfiles.

**3. Tag every finding** exactly one of:

| Tag | Meaning | Action |
|---|---|---|
| **Important** | A real defect, scope violation or security problem **introduced by this diff** | Fix it, or answer it with a concrete reason it does not apply. **Blocks landing while open.** |
| **Nit** | Style or preference | Fix if trivial; never blocks |
| **Pre-existing** | Real, but present before this diff | File it with `/record-issue` (link the finding); **do not** fix it here — that widens the diff |

**4. Converge — at most 3 review-and-fix rounds (#166).**

- **Round 1** reviews the whole diff. **Rounds 2–3** review only what changed
  since the last review (`git diff <last-reviewed-sha>..HEAD`), plus whether each
  earlier Important finding is actually resolved.
- **Never repeat a finding.** Keep the running findings list and pass it to each
  later round; a finding already raised is either resolved or still open, not new.
- **Fix the class, not the instance.** For each Important finding, name the bug
  class (e.g. "unquoted variable in a path", "label write without lock release")
  and grep the diff for every other instance before the next round.
- **A finding that keeps coming back across issues is a missing rule.** If
  reviewers raise the same kind of finding again and again, record it with
  `/record-issue` proposing where the rule should live: a line in `REVIEW.md`, a
  lint or test check, or a skill. Don't widen this diff to add it.
- Commit each round's fixes, then re-run the targeted tests before re-review.
- **Still an open Important finding after round 3** → stop. The approach itself
  may be wrong. Do **not** land, and do **not** push `feature/issue-N`: any
  remote branch named `issue-<N>` is a claim lock (`claimed-issue-numbers.sh`)
  and would keep the issue unclaimable after a human resolves the design
  question. Push the work to `escalated/review-<N>` instead, which is not a
  lock, so the human can read the diff and it survives the worker. Escalate with
  `add-blocking-label.sh`, which posts the reason and releases the `working`
  lock in one step. It rejects any reason containing `[lowercase…]` as an
  unfilled placeholder, so write findings as plain `file:line — problem`:

```bash
git push origin "HEAD:refs/heads/escalated/review-${REVIEW_ISSUE}" \
  || echo "⚠️  could not push escalated/review-${REVIEW_ISSUE}; the work is only on the local branch"
bash "${SCRIPT_DIR:?SCRIPT_DIR unset — re-run the setup block above}/add-blocking-label.sh" "$REVIEW_ISSUE" "needs-design" \
  "Review did not converge in 3 rounds. Open Important findings: <each as file:line — problem>. Question: is this the right approach? The work is on branch escalated/review-${REVIEW_ISSUE}." \
  || { echo "❌ escalation failed — the issue still holds 'working'; fix the reason text and retry"; exit 1; }
```

**5. Record the outcome.** Write the record — it is included in the
issue's close comment (`merge` mode) or the PR body (`pr` mode). Write
`Verdict: pass` only when every Important finding is Fixed or Answered; any
commit after this invalidates the record and the review must be re-run:

```bash
cat > "$REVIEW_FILE" <<'REVIEW'
## Review
Rounds: <n> · Reviewer: </code-review | subagents: correctness, scope, security> · Security review: <ran | not needed — no sensitive paths>

| # | Tag | Finding | Resolution |
|---|---|---|---|
| 1 | Important | <file:line — what is wrong> | Fixed in <sha> / Answered: <reason> |
| 2 | Pre-existing | <…> | Filed as #<n> |
| 3 | Nit | <…> | Fixed / Left: <reason> |
REVIEW
printf '\nReviewed-HEAD: %s\nVerdict: pass\n' "$(git rev-parse HEAD)" >> "$REVIEW_FILE"
```

## Verify Before Claiming (MANDATORY)

Verification is a required step, not an optional skill (#170). Before you fill
the Review Digest below, on the final committed `HEAD`:

1. Run `$TEST_COMMAND` (and any targeted tests for the change) and read the
   actual result. A suite you did not run, or whose summary you did not read,
   is not evidence.
2. Copy the exact command and its result lines into the digest's
   **Verification** section: the command on a line starting with `$ `, its
   output on the lines after it. The renderer refuses a Verification section
   without both, for any change that has a diff.
3. Anything the tests do not exercise goes under **Not verified / confidence**.

`superpowers:verification-before-completion`, when installed, helps with this
step; it does not replace it.

The digest also carries two lines you do not write: **Risk** (the tier from
`landing-mode.sh`, #165) and **How to revert** (`git revert` over the branch's
commits, or the merge revert for a PR; the merge job adds the exact landed range
to its close comment). If undoing the change takes more than a revert (a data
migration, a config rollout), add a `## How to revert` section to the sections
file; it is printed after the computed line.

## Review Digest (MANDATORY)

Every place this command publishes work (a PR body in `pr` mode, the merge
job's close comment in `merge` mode, a decomposed parent's rollup close) uses
**one** body, rendered by `render-review-digest.sh` (#196). Write the prose into a
sections file, then render it. The script computes **Size** itself and exits
non-zero while any slot is unfilled. Every publish site below stops if it fails,
so a placeholder body can never ship.

```bash
DIGEST_SECTIONS="$(git rev-parse --git-common-dir)/autocoder-digest-${REVIEW_ISSUE:-$ISSUE_NUM}.md"
cat > "$DIGEST_SECTIONS" <<'DIGEST'
## Intent
{{FILL: one sentence: what problem this solves and for whom}}

## Where to look
{{FILL: the 1-3 hunks (file:line) where a mistake would matter; label everything
else "mechanical" with a one-line reason, e.g. "mirrors: byte-identical copies"}}

## Verification
{{FILL: the exact commands you ran and their actual result lines, e.g.
"$ bash tests/run-shell-suite.sh" then "Tests: 0 failed, 60 passed, 60 total"}}

## Not verified / confidence
{{FILL: what you did not exercise, known risks, and confidence: high|medium|low}}
DIGEST
# Only when the renderer asks for it (insertions > 3x deletions and > 200 lines):
#   printf '\n## Why net growth\n%s\n' "one sentence" >> "$DIGEST_SECTIONS"
```

Replace every `{{FILL: ...}}` slot, including the hint, with real content. The
renderer refuses a body that still contains one, so a forgotten slot stops the
publish instead of shipping. It does not police anything else you write: `Vec<T>`,
`<sha>` and `[links](url)` are fine.

**REVIEW FIT after implementation.** Before publishing, check the size the
reviewer will face. Over the limit, **always publish anyway**: add
`needs-review-focus` and make **Where to look** name every non-mechanical hunk.
Never split finished work. There is no protocol for that, and improvising one
risks losing verified work or leaving the claim half-released.

```bash
SIZE_LINE=$(bash "${SCRIPT_DIR}/render-review-digest.sh" --size-only --base "${PARENT_BRANCH}")
echo "Review size: $SIZE_LINE"
case "$SIZE_LINE" in
  *over=yes*) issue_update "${REVIEW_ISSUE:-$ISSUE_NUM}" --add-label "needs-review-focus" 2>/dev/null || true ;;
esac
```

`needs-review-focus` is informational. It is not a blocking label and must never
be added to a claimable-filter list.

## Fixing Strategy

### Step 1: Assess Complexity

Analyze the issue and determine if it's simple or complex:

**Simple Issue Indicators**:
- Description < 500 chars
- Single component/file mentioned
- Clear, specific fix described
- No test failures OR < 5 test failures
- Keywords: "hide", "timeout", "remove", "add field", "typo"

**Complex Issue Indicators**:
- Description > 1000 chars
- Multiple failing tests (>10)
- Multiple components involved
- Requires design/architecture
- Keywords: "implement", "system", "management", "integration", "~30 failures"

**Rebase early and often (#222).** Do not branch once and integrate only at the end:
while you work, the integration branch moves, and every sibling landing adds conflict
risk that surfaces all at once in the merge job. After each commit, and whenever the
integration branch has moved while you are between steps, rebase and resolve any
conflict while it is small and the context is fresh:

```bash
git fetch -q origin "$PARENT_BRANCH" && git rebase "origin/${PARENT_BRANCH}" \
  || { git diff --name-only --diff-filter=U; echo "resolve, git rebase --continue, re-run the targeted tests"; }
```

The shared landing section also does a trial rebase right before its review check.

**Declare the areas you edit: keep `Touches:` current (#229).** The fix-loop gate
steers other workers away from files a claimed issue holds (`claims.avoid_overlap`,
`touches-fns.sh`), using a `Touches:` line in the issue body: comma-separated paths,
directories (a trailing `/` covers everything under it) or globs, e.g.
`Touches: src/web/village/, src/web/server.rs`. With no such line, the backticked
paths of a `## Files Affected` section count instead. An issue that declares nothing
overlaps nothing, so it gets no protection.

- **When you start** an issue with no `Touches:` line, add one once you have read
  the code and know which files you expect to change.
- **After each commit**, bring it up to date. Declared entries are kept; every file
  the branch actually changed (`git diff --name-only origin/<integration>...HEAD`)
  that they do not cover is added, three or more files in one directory collapsed
  to that directory.

```bash
# Touches: (#229). On the GitHub backend this rewrites the line in the issue body;
# other backends have no body edit verb, so it prints the line to add by hand.
# On start, before the first commit (the areas you expect to edit):
"${SCRIPT_DIR}/touches-set.sh" "$ISSUE_NUM" --base "origin/${INTEGRATION_BRANCH}" \
  --declare "src/web/village/, src/web/server.rs"
# After each commit:
"${SCRIPT_DIR}/touches-set.sh" "$ISSUE_NUM" --base "origin/${INTEGRATION_BRANCH}"
```

### Step 2A: Simple Issue - Direct Fix

For simple issues, proceed directly:

1. Read relevant code files to understand the root cause
2. Implement a complete fix (not partial)
3. Run targeted tests to verify the fix works
4. Create a git commit with the changes
5. Trial-rebase onto the integration branch ("Landing the Work", after Step 3, does it), then run the Pre-Landing Review Gate (above) on the rebased HEAD and resolve its findings
6. Mark as complete

```bash
# After fixing simple issue:
git add -A
# Title "#N: ...", never "Fix #N": a closing keyword closes the issue before the merge job reports (#209).
git commit -m "#${ISSUE_NUM}: Brief description

Detailed explanation of what was fixed and how.

🤖 Generated with [Antigravity](https://claude.com/claude-code)

Co-Authored-By: Antigravity <noreply@antigravity.ai>"

# Land it: skip Step 3 and go straight to "Landing the Work", which runs the rebase, review check, push and merge.
LAND_NUM="$ISSUE_NUM"; LAND_BRANCH="feature/issue-${ISSUE_NUM}"; LAND_TITLE="$ISSUE_TITLE"; LAND_BODY="$ISSUE_BODY"
```

### Step 2B: Complex Issue - Use Superpowers (if available)

Moved to `.agent/shared/fix-complex-issues.md` (#240). Read it when Step 1 rates the issue complex: it walks debugging, brainstorming, planning, execution and verification. Then continue with Step 3 below.

### Step 3: Commit and Close

**Never wait on a background-job notification for a verdict you need (#7134).** A pre-check
(the project's prebank, a scratch typecheck) launched in a background shell finishes without
you when the shell's completion notification is lost, and four such losses in one day cost a
fleet about four worker-hours of idle time. Run it in the FOREGROUND within your tool's time
ceiling (the project may offer a one-command bank step that does so, e.g. the plugin's
`enqueue.sh`); when the run is longer than the ceiling, background it and then POLL ITS
VERDICT LINE on a timer from the foreground, in chunks under the ceiling, until it appears:

```bash
until grep -qE '^=== (prebank|pre-check)[^:]*: (PASS|FAIL)' "$LOG" || ! kill -0 "$PID" 2>/dev/null; do sleep 30; done
tail -40 "$LOG"   # the block: act on PASS or FAIL now, never on "it will notify me"
```

A run with no verdict and no live process is dead: re-run it, do not wait. The manager's
`worker-verdict-watchdog.sh` re-prompts a pane that sat idle past a verdict, and its nudge is
a defect report against this rule, not a service to rely on.

After verification passes:

```bash
# Commit changes
git add -A
# Title "#N: ...", never "Fix #N": a closing keyword closes the issue before the merge job reports (#209).
git commit -m "#${ISSUE_NUM}: Brief description

Detailed multi-line explanation of:
- Root cause analysis
- Solution approach
- Changes made
- Verification results

🤖 Generated with [Antigravity](https://claude.com/claude-code)

Co-Authored-By: Antigravity <noreply@antigravity.ai>"

# Land it: "Landing the Work" below runs the rebase, review check, push and merge.
LAND_NUM="$ISSUE_NUM"; LAND_BRANCH="feature/issue-${ISSUE_NUM}"; LAND_TITLE="$ISSUE_TITLE"; LAND_BODY="$ISSUE_BODY"
```

### Landing the Work (Step 2A, Step 3 and 5D all end here)

Every flow lands through this one block (#242). The flow you came from has committed its
work and set four variables. Run its commit block first, then this one:

| Flow | `LAND_NUM` | `LAND_BRANCH` | `LAND_TITLE` / `LAND_BODY` |
|---|---|---|---|
| Step 2A, Step 3 (bug fix) | `$ISSUE_NUM` | `feature/issue-${ISSUE_NUM}` | `$ISSUE_TITLE` / `$ISSUE_BODY` |
| 5D (approved enhancement) | `$ENHANCE_NUM` | `enhancement/issue-${ENHANCE_NUM}-auto` | `$ENHANCE_TITLE` / `$ENHANCE_BODY` |

`REVIEW_ISSUE` in the Pre-Landing Review Gate and the Review Digest is the same number as `LAND_NUM`.

```bash
: "${LAND_NUM:?set LAND_NUM, LAND_BRANCH, LAND_TITLE and LAND_BODY in the flow's commit block first}"
: "${LAND_BRANCH:?set LAND_BRANCH in the flow's commit block first}"
: "${LAND_TITLE:?set LAND_TITLE in the flow's commit block first}"

# Trial rebase (#222): rebase before the review check, then review the rebased HEAD.
TRIAL_BASE="${PARENT_BRANCH:?PARENT_BRANCH unset — re-run the branch setup block above}"
git fetch -q origin "$PARENT_BRANCH" 2>/dev/null && TRIAL_BASE="origin/${PARENT_BRANCH}"
if ! git rebase "$TRIAL_BASE"; then
  echo "⚠️  Rebase of #${LAND_NUM} onto $TRIAL_BASE conflicts in:"; git diff --name-only --diff-filter=U
  echo "   Resolve keeping both sides' behaviour, git rebase --continue, re-test, then re-run this block."
  exit 2
fi

# Pre-landing review gate (#147, #166): nothing publishes until the record for this HEAD says pass.
REVIEW_FILE="$(git rev-parse --git-common-dir)/autocoder-review-${LAND_NUM}.md"
if ! grep -qx "Reviewed-HEAD: $(git rev-parse HEAD)" "$REVIEW_FILE" 2>/dev/null \
   || ! grep -qx "Verdict: pass" "$REVIEW_FILE"; then
  echo "❌ No passing review for this HEAD of #${LAND_NUM} — run the Pre-Landing Review Gate, then re-run this block"
  exit 1
fi

# Render the close comment NOW, while HEAD is still the feature branch: after the
# merge below the diff is gone. A body with unfilled slots is never published (#196).
CLOSE_DIGEST=$(bash "${SCRIPT_DIR}/render-review-digest.sh" --issue "$LAND_NUM" \
  --base "$PARENT_BRANCH" --sections "${DIGEST_SECTIONS:?write the Review Digest sections file first}") \
  || { echo "❌ Review digest for #${LAND_NUM} has unfilled slots or no Verification evidence (a "$ command" line and its result) — fix $DIGEST_SECTIONS and re-run (the renderer's stderr says which)"; exit 1; }

# Landing mode by diff risk (#165): a diff touching a `risk.high` glob lands as a PR.
git fetch -q 2>/dev/null || true   # judge the diff against the remote parent, not a stale local copy
LANDING_BASE=$(git rev-parse --abbrev-ref "${PARENT_BRANCH}@{upstream}" 2>/dev/null || echo "$PARENT_BRANCH")
LANDING_MODE=$(bash "${SCRIPT_DIR}/landing-mode.sh" --mode "$MERGE_MODE" --base "$LANDING_BASE") \
  || { echo "❌ Cannot choose a landing mode for #${LAND_NUM} — fix the \"risk\" setting in .autocoder.json and re-run this block"; exit 1; }

# Publish: git push, else the GitHub API. PUSH_OK means it landed; never --dry-run (#26).
PUSH_OK=false
if git push -u origin "$LAND_BRANCH"; then
  PUSH_OK=true
else
  echo "⚠️  git push failed — trying the GitHub API fallback..."
  if python3 "${SCRIPT_DIR}/api-push.py" "$LAND_BRANCH" --base "origin/${INTEGRATION_BRANCH:-master}"; then
    PUSH_OK=true
  fi
fi

if [ "$PUSH_OK" != true ]; then
  # Not published: leave the issue open and keep 'working' (#26).
  issue_comment "$LAND_NUM" --body "⚠️ **Publication failed — issue left open**

Both \`git push\` and the GitHub API fallback failed, so the fix has NOT landed.
The issue stays open and keeps its \`working\` label so the work is not lost or
silently redone.

Local branch: \`${LAND_BRANCH}\`" 2>/dev/null || true
  echo "❌ Could not publish ${LAND_BRANCH} — issue $LAND_NUM left OPEN (nothing was closed)"
  exit 1
fi

if [ "$LANDING_MODE" = "pr" ]; then
  # Create a pull request and stop. The body is the review digest (see
  # "Review Digest" above); a body with unfilled slots is never published.
  DIGEST=$(bash "${SCRIPT_DIR}/render-review-digest.sh" --issue "$LAND_NUM" \
    --base "$PARENT_BRANCH" --sections "${DIGEST_SECTIONS:?write the Review Digest sections file first}" --pr) \
    || { echo "❌ Review digest for #${LAND_NUM} has unfilled slots or no Verification evidence (a "$ command" line and its result) — fix $DIGEST_SECTIONS and re-run (the renderer's stderr says which)"; exit 1; }
  gh pr create \
    --base "$PARENT_BRANCH" \
    --head "$LAND_BRANCH" \
    --title "#${LAND_NUM}: ${LAND_TITLE}" \
    --body "${DIGEST}

$(cat "$REVIEW_FILE")

🤖 Generated with [Antigravity](https://claude.com/claude-code)" \
    || { echo "❌ gh pr create failed for #${LAND_NUM} — keeping the 'working' label; fix it and re-run"; exit 1; }

  # Hand off from 'working' (concurrency lock) to 'awaiting-integration'
  # (review gate). Without the second label the issue is immediately claimable
  # again and the loop re-does the work every iteration until a human merges.
  issue_update "$LAND_NUM" --remove-label "working" 2>/dev/null || true
  issue_update "$LAND_NUM" --add-label "awaiting-integration" 2>/dev/null || true
  echo "✅ PR created for issue #$LAND_NUM — awaiting review"
  "${SCRIPT_DIR}/append-to-history.sh" --history-file "HISTORY.md" --backend auto \
    "PR #${LAND_NUM}: ${LAND_TITLE}" \
    "PR created on branch ${LAND_BRANCH}." \
    "${LAND_BODY:0:150}" \
    "Awaiting code review."
else
  # Auto-merge: switch back to parent branch and merge
  git checkout "$PARENT_BRANCH"
  git merge --no-ff "$LAND_BRANCH"

  # Push parent branch. Fall back to the GitHub API if the git transport is
  # blocked, and record whether the work ACTUALLY LANDED.
  MERGE_PUSH_OK=false
  if git push; then
    MERGE_PUSH_OK=true
  else
    echo "⚠️  git push failed — trying the GitHub API fallback..."
    if python3 "${SCRIPT_DIR}/api-push.py" HEAD --target "$PARENT_BRANCH" \
         --base "origin/${PARENT_BRANCH}"; then
      MERGE_PUSH_OK=true
    fi
  fi

  if [ "$MERGE_PUSH_OK" != true ]; then
    # Nothing landed. Do NOT close, do NOT release the lock (see #26).
    issue_comment "$LAND_NUM" --body "⚠️ **Publication failed — issue left open**

Both \`git push\` and the GitHub API fallback failed, so the merge has NOT landed
on \`${PARENT_BRANCH}\`. The issue stays open and keeps its \`working\` label." 2>/dev/null || true
    echo "❌ Could not publish to ${PARENT_BRANCH} — issue #${LAND_NUM} left OPEN"
    exit 1
  fi

  # Clean up feature branch (local and remote)
  git branch -d "$LAND_BRANCH"
  git push origin --delete "$LAND_BRANCH" 2>/dev/null || true

  # ── Ship gate (issue #35) ───────────────────────────────────────────────
  # #26's PUSH_OK guard answers "did the push succeed?". It cannot answer "did
  # this reach the branch that ships?" A worker branching from a feature line
  # pushes fine, merges fine, tests fine — and closes the issue while the
  # shipping branch is untouched. Every signal is green and the tracker is wrong.
  #
  # NOTE: checking ancestry of $INTEGRATION_BRANCH does NOT work. When the swarm's
  # integration branch is itself a feature line, a commit merged into it IS an
  # ancestor of it, so the check passes and the issue closes — which is the bug.
  # Ship is measured against the branch that actually ships. (The PR merge mode
  # above needs no gate here: it never closes the issue itself — it hands off to
  # `awaiting-integration` and lets the merge close it.)
  LANDED_COMMIT=$(git rev-parse HEAD)
  if "${SCRIPT_DIR}/verify-shipped.sh" "$LANDED_COMMIT"; then
    # Genuinely shipped — safe to close.
    issue_update "$LAND_NUM" --remove-label "working" 2>/dev/null || true
    if issue_close "$LAND_NUM" --comment "✅ **Issue Resolved**

${CLOSE_DIGEST}

$(cat "$REVIEW_FILE")

**Branch**: \`${LAND_BRANCH}\` (merged and deleted)

🤖 Auto-resolved by autonomous fix workflow"; then
      # Merge mode samples closed work for later human review (#197). This merge put the
      # integration branch first, so the change is measured from the first parent.
      bash "${SCRIPT_DIR}/spot-check-select.sh" --issue "$LAND_NUM" --sha "$LANDED_COMMIT" \
        --base "$LANDED_COMMIT^1" --apply || true
    fi
  else
    # Real work, really pushed, but NOT on the shipping branch. Closing here
    # would assert "shipped" falsely. Leave the issue OPEN, keep the lock
    # released, and record exactly what must merge for this to ship.
    SHIP_BRANCH_NAME="${CLAUDE_CODE_SHIP_BRANCH:-$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name 2>/dev/null || echo main)}"
    issue_update "$LAND_NUM" --remove-label "working" 2>/dev/null || true
    issue_update "$LAND_NUM" --add-label "awaiting-integration" 2>/dev/null || true
    issue_comment "$LAND_NUM" --body "⏳ **Fix complete, not yet shipped — leaving this issue OPEN**

The work is done, committed, and merged to \`${INTEGRATION_BRANCH}\` as \`${LANDED_COMMIT}\`. It has **not** reached \`${SHIP_BRANCH_NAME}\`, so closing would assert something false.

**To ship**: \`${INTEGRATION_BRANCH}\` must merge to \`${SHIP_BRANCH_NAME}\`.

Labelled \`awaiting-integration\` so it is findable rather than silently reopened as new work.

🤖 Ship gate (issue #35)"
    echo "⏳ Issue #$LAND_NUM left OPEN — merged to $INTEGRATION_BRANCH but not on the shipping branch"
  fi

  "${SCRIPT_DIR}/append-to-history.sh" --history-file "HISTORY.md" --backend auto \
    "Fix #${LAND_NUM}: ${LAND_TITLE}" \
    "Resolved on ${LAND_BRANCH}. Merged to ${PARENT_BRANCH}." \
    "${LAND_BODY:0:150}" \
    "All tests passing. Branch merged and deleted."
fi
```

## Example Workflow

Moved to `.agent/shared/fix-complex-issues.md` (#240). Read it when you want a worked simple-vs-complex example.

## Blocking Detection & Label Assignment

Before attempting to work on an issue, assess whether it can be handled autonomously. If not, add the appropriate blocking label and skip to the next issue.

### Blocking Labels

| Label | When to Apply | Example Indicators |
|-------|---------------|-------------------|
| `needs-clarification` | Incomplete information, missing context, unclear requirements | "Fix the bug" (which bug?), "Improve performance" (of what?), vague descriptions |
| `needs-design` | Multiple valid approaches without clear winner, requires design phase | "Add user dashboard", "Implement notifications", architectural uncertainty |
| `needs-approval` | Architectural decisions, major changes, security implications, breaking changes | "Migrate to microservices", "Change auth system", "Remove deprecated API" |
| `too-complex` | Beyond autonomous capability (when decomposition fails or superpowers unavailable) | Manual decomposition needed, requires deep expertise |
| `future` | Idea for future consideration, not ready for implementation | "Expose data via MCP server", research spikes, long-term ideas |
| `decomposed` | Complex issue broken into sub-tasks (automatically applied, not blocking) | Parent issue tracking sub-task completion |
| `subtask` | Part of a larger decomposed issue (informational, not blocking) | Individual actionable task from decomposition |
| `awaiting-integration` | Applied automatically when a PR is opened in `pr` merge mode. Suppresses the issue from the claimable queue so the loop does not redo finished work while review is pending. Not a human-judgement gate, so `/review-blocked` ignores it. | Merging the PR closes the issue and retires the label. If a PR is closed **without** merging, remove the label by hand (`gh issue edit <n> --remove-label awaiting-integration`) or the issue stays invisible to the loop. |

### Detection Process

Moved to `.agent/shared/fix-blocking.md` (#240). Read it when an issue may need a blocking label: it has the red flags, the reason-writing rules and the `add-blocking-label.sh` call.

### Ultra-Complex Issues - Decompose into Sub-Tasks

Moved to `.agent/shared/fix-decomposition.md` (#240). Read it when the task scope gate or Step 1 says the issue is too large: it has the decomposition rules, the sub-task body template and the `too-complex` fallback.

**Monitoring Decomposed Issues**: moved to `.agent/shared/fix-decomposition.md` (#293). When the issue you just finished is a sub-task (its body says `Sub-task of #N`), read its "Monitoring Decomposed Issues" section: it checks whether every sibling sub-task is closed and, if so, closes the parent with a rollup digest (and samples it for spot-check in merge mode).

### Skip Criteria (Legacy)

Moved to `.agent/shared/fix-blocking.md` (#240). Read it when deciding whether to skip an issue.

## No Priority Issues Found

Moved to `.agent/shared/fix-no-priority-work.md` (#240). Read it when no P0-P3 issue is claimable: it covers Steps 1-3, the full regression run and what to do with its results. Then continue with Step 4 below.

### Step 4: If All Tests Pass - Work on Enhancements

If regression tests pass completely (no new bug issues created), shift focus to **enhancements**.

#### 5A: Check for Approved Enhancement Issues

**IMPORTANT**: Only implement enhancements that have been **approved by a human** (i.e., do NOT have the `proposal` label). AI-generated proposals require human review before implementation.

```bash
# Check for open enhancement issues that are NOT proposals (approved for implementation)
issue_list --state open --label "enhancement" --limit 50 > /tmp/all-enhancements.json

# Filter out proposals, blocked issues, and issues being worked on - only get available approved enhancements
APPROVED_ENHANCEMENTS=$(cat /tmp/all-enhancements.json | python3 -c "
import json, sys
issues = json.load(sys.stdin)
blocking_labels = ['needs-approval', 'needs-design', 'needs-clarification', 'too-complex', 'future', 'awaiting-integration']
approved = [i for i in issues
            if not any(l['name'] == 'proposal' for l in i.get('labels', []))
            and not any(l['name'] == 'working' for l in i.get('labels', []))
            and not any(l['name'] in blocking_labels for l in i.get('labels', []))]
print(json.dumps(approved))
")

ENHANCEMENT_COUNT=$(echo "$APPROVED_ENHANCEMENTS" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")

if [ "$ENHANCEMENT_COUNT" -gt 0 ]; then
  echo "🚀 Found $ENHANCEMENT_COUNT approved enhancement(s) to implement"
  # Get first approved enhancement
  ENHANCE_NUM=$(echo "$APPROVED_ENHANCEMENTS" | python3 -c "import json,sys; print(json.load(sys.stdin)[0]['number'])")
  ENHANCE_TITLE=$(echo "$APPROVED_ENHANCEMENTS" | python3 -c "import json,sys; print(json.load(sys.stdin)[0]['title'])")
  ENHANCE_BODY=$(echo "$APPROVED_ENHANCEMENTS" | python3 -c "import json,sys; print(json.load(sys.stdin)[0].get('body',''))")
  echo "📋 Working on approved enhancement #$ENHANCE_NUM: $ENHANCE_TITLE"
  # Body + comment thread (issue #134): design against the whole thread, not the body.
  ENHANCE_SPEC=$("${SCRIPT_DIR}/issue-spec.sh" "$ENHANCE_NUM") || {
    echo "⚠️  Could not read the comment thread for #$ENHANCE_NUM — read it yourself before designing."
    ENHANCE_SPEC="$ENHANCE_BODY"
  }
  echo "Specification (body, then comments — a later comment overrides the body):"
  echo "$ENHANCE_SPEC"
else
  # Check if there are pending proposals
  PROPOSAL_COUNT=$(cat /tmp/all-enhancements.json | python3 -c "
import json, sys
issues = json.load(sys.stdin)
proposals = [i for i in issues if any(l['name'] == 'proposal' for l in i.get('labels', []))]
print(len(proposals))
")

  # Check if there are blocked issues
  BLOCKED_COUNT=$(cat /tmp/all-enhancements.json | python3 -c "
import json, sys
issues = json.load(sys.stdin)
blocking_labels = ['needs-approval', 'needs-design', 'needs-clarification', 'too-complex', 'future', 'awaiting-integration']
blocked = [i for i in issues if any(l['name'] in blocking_labels for l in i.get('labels', []))]
print(len(blocked))
")

  if [ "$PROPOSAL_COUNT" -gt 0 ]; then
    echo "📋 Found $PROPOSAL_COUNT proposal(s) awaiting human approval"
    echo "💡 Use '/list-proposals' to review pending proposals"
    echo "✨ No approved enhancements to implement. Creating new proposals..."
  elif [ "$BLOCKED_COUNT" -gt 0 ]; then
    echo "🚫 Found $BLOCKED_COUNT blocked issue(s) (requires human review)"
    echo "💡 Use '/review-blocked' to review and approve blocked issues"
    echo "✨ No approved enhancements to implement. Creating new proposals..."
  else
    echo "✨ No enhancements or proposals. Creating new proposals..."
  fi
  # Continue to Step 5B
fi
```

#### 5B: Propose New Enhancements (if none exist)

Moved to `.agent/shared/fix-no-priority-work.md` (#240). Read it when 5A finds no approved enhancement: it covers the coverage check, brainstorming and the proposal issue template.

#### 5C: Implement Approved Enhancement Using Superpowers

**IMPORTANT**: Only implement enhancements that do NOT have the `proposal` label. If an enhancement has the `proposal` label, it is awaiting human approval and must NOT be implemented.

For each **approved** enhancement issue (no `proposal` label), follow this workflow:

**Step 1: Create Feature Branch**

```bash
# Save parent branch before creating feature branch
PARENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)

git checkout -b "enhancement/issue-${ENHANCE_NUM}-auto" 2>/dev/null || git checkout "enhancement/issue-${ENHANCE_NUM}-auto"

# Claim-then-verify: add 'working' label IMMEDIATELY, then check for race
issue_update "$ENHANCE_NUM" --add-label "working" 2>/dev/null || true
sleep 1

# Re-fetch to verify we won the race (check for existing work-started comments)
RACE_CHECK=$(issue_get "$ENHANCE_NUM" 2>/dev/null | jq '[.comments[] | select(.body | test("Enhancement Implementation Started"))] | length' 2>/dev/null || echo "0")
if [ "$RACE_CHECK" -gt 0 ]; then
  echo "⚠️  Race condition: another agent already claimed enhancement #$ENHANCE_NUM. Skipping."
  git checkout "$PARENT_BRANCH"
  # Continue to next iteration or exit
fi

issue_comment "$ENHANCE_NUM" --body "🚀 **Enhancement Implementation Started**

Starting automated implementation of this enhancement.

**Branch**: \`enhancement/issue-${ENHANCE_NUM}-auto\`
**Started**: $(date)

Implementation in progress..."
```

**Step 2: Design Solution with Brainstorming**

```
# If thorough-brainstorming available (preferred):
Use Skill tool: thorough-brainstorming

# If superpowers available (fallback):
Use Skill tool: superpowers:brainstorming
```

This will:
- Explore design alternatives
- Clarify requirements
- Validate assumptions
- Refine into concrete design

**Step 3: Create Detailed Implementation Plan**

```
# If thorough-writing-plans available (preferred):
Use Skill tool: thorough-writing-plans

# If superpowers available (fallback):
Use Skill tool: superpowers:writing-plans
```

This will:
- Break down into bite-sized tasks
- Specify exact file paths and changes
- Include verification steps
- Assume zero prior codebase knowledge

**Update the GitHub issue** with the implementation plan:

```bash
issue_comment "$ENHANCE_NUM" --body "📋 **Implementation Plan Created**

## Detailed Implementation Plan

[Paste the implementation plan created by thorough-writing-plans or superpowers:writing-plans]

Beginning execution..."
```

**Step 4: Execute the Plan**

```
Use Skill tool: superpowers:executing-plans
```

This will:
- Load and review the plan critically
- Execute tasks in batches
- Report progress for review between batches
- Track completion systematically

**Step 5: Run Tests and Verify**

```bash
# Run full test suite
$TEST_COMMAND

# Capture test results
TEST_EXIT_CODE=$?
TEST_OUTPUT=$(cat /tmp/test-output.txt 2>/dev/null || echo "Test output not captured")
```

#### 5D: Handle Test Results

**If Tests Pass**:

```bash
if [ $TEST_EXIT_CODE -eq 0 ]; then
  echo "✅ All tests pass!"

  # Verify Before Claiming (MANDATORY, #170): the command and its result go in the
  # digest's Verification section. superpowers:verification-before-completion helps.

  # Commit changes
  git add -A
  git commit -m "Implement enhancement #${ENHANCE_NUM}: ${ENHANCE_TITLE}

Detailed explanation of:
- What was implemented
- Design decisions made
- Tests added/modified

🤖 Generated with [Antigravity](https://claude.com/claude-code)

Co-Authored-By: Antigravity <noreply@antigravity.ai>"

  # Land it: "Landing the Work" (after Step 3) runs the rebase, review check, push and merge.
  LAND_NUM="$ENHANCE_NUM"; LAND_BRANCH="enhancement/issue-${ENHANCE_NUM}-auto"; LAND_TITLE="$ENHANCE_TITLE"; LAND_BODY="$ENHANCE_BODY"
fi
```

**If Tests Fail - Create Bug Issues:** moved to `.agent/shared/fix-enhancement-failures.md` (#240). Read it when the enhancement's tests fail: it files the bug issues and pauses the enhancement, keeping the `working` label and the branch.

#### 5E: Enhancement Skip Criteria

Moved to `.agent/shared/fix-enhancement-failures.md` (#240). Read it when an enhancement cannot be implemented automatically.

## MANDATORY: Continuous Loop

**THIS WORKFLOW RUNS FOREVER UNTIL MANUALLY STOPPED.**

### Context Compaction (MANDATORY — DO THIS EVERY ITERATION)

> ⛔ **Run `/compact` (Antigravity) — or clear/compact the session context (Codex / Gemini / other) — BEFORE starting each new issue. Every iteration. No exceptions.**
>
> The loop runs forever. Without compaction between issues the context window fills and the agent dies mid-fix. Compaction is what makes "runs forever" actually possible. Skipping it is the #1 cause of a fix-loop crashing partway through an issue.
>
> If pstack is installed, its SessionStart hook re-injects "invoke `pstack:poteto-mode`" after every compaction. Ignore it: this protocol stays the spine for the next issue (see *Optional skill enhancements*).

After completing ANY of these actions, you MUST immediately continue:

1. **After triaging unprioritized issues** → Fetch next priority issue
2. **After fixing and closing a bug issue** → Fetch next priority issue
3. **After skipping an issue** → Fetch next priority issue
4. **After running regression tests** → Check for new issues created
5. **After implementing an approved enhancement** → Check for more approved enhancements or bugs
6. **After test failures during enhancement** → Process created bug issues first
7. **After creating a proposal** → Continue generating more proposals if useful ideas remain
8. **If truly idle** → Output `IDLE_NO_WORK_AVAILABLE` to trigger sleep cycle

### Priority Order

The workflow follows this strict priority order:
1. **Triage Unprioritized Issues** (assign P0-P3 labels first)
2. **P0-P3 Bug Issues** (fix bugs first)
3. **Regression Test Failures** (creates new bug issues)
4. **Approved Enhancement Issues** (only enhancements WITHOUT the `proposal` label)
5. **Create New Proposals** (lowest priority - only when no bugs AND no approved enhancements)

**⚠️ NEVER automatically implement proposals.** Proposals (issues with `proposal` label) require human approval before implementation.

### Loop Implementation

Moved to `.agent/shared/fix-loop-and-proposals.md` (#240). Read it when you need the queue-counting script that picks the next kind of work.

### Never Stop

- **DO NOT** wait for user input between issues
- **DO NOT** stop after fixing one issue
- **DO NOT** ask "should I continue?"
- **DO NOT** implement issues with the `proposal` label (they require human approval)
- **DO** triage unprioritized issues first
- **DO** keep processing bug issues until the queue is empty
- **DO** run `/full-regression-test` when bug queue is empty
- **DO** process any new bug issues created by `/full-regression-test`
- **DO** work on **approved** enhancements only when no bugs exist
- **DO** output `IDLE_NO_WORK_AVAILABLE` after creating a proposal (to allow human review)
- **DO** output `IDLE_NO_WORK_AVAILABLE` when no bugs and proposals already exist
- **DO** create bug issues for any test failures during enhancement work
- **DO** loop back to bug fixing if enhancement work creates failures

### Idle State

**CRITICAL: You MUST output the idle signal when there's nothing to do.**

Output this EXACT text (on its own line) when ANY of these conditions are true:
- No priority bugs (P0-P3) AND no approved enhancements AND (proposals already exist OR blocked issues exist)
- After creating a new proposal (to allow human review time)
- After completing all available work

```
IDLE_NO_WORK_AVAILABLE
```

**Without this signal, the loop will spin forever without sleeping.**

This signals the stop hook to sleep (default 15 minutes) before checking again for:
- New human-created issues
- Comments on existing issues
- Approved proposals ready for implementation
- Blocked issues reviewed and approved (blocking label removed)

**The only way this workflow stops is if the user manually interrupts it.**

---

## Proposal Management

Moved to `.agent/shared/fix-loop-and-proposals.md` (#240). Read it when you need to explain how proposals are reviewed, approved, refined or rejected.
