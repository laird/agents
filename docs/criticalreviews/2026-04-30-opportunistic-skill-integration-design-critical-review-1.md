# Critical Design Review #1 — Opportunistic Skill Integration

**Reviewing:** `docs/superpowers/specs/2026-04-30-opportunistic-skill-integration-design.md`
**Prior reviews:** none
**Reviewer role:** Senior Principal Software Architect

## 1. Overall Assessment

The design's core idea — give existing commands a small, additive prelude that opportunistically delegates specific steps to installed skills, with the existing inline protocols as fallbacks — is sound, well-scoped, and aligned with YAGNI/progressive-disclosure principles. The chain of six commands matches the user's stated workflow, and the explicit refusal to modify existing protocol bodies is a strong constraint that limits blast radius. However, the design has several architectural soft spots concentrated around **execution context**, **shared source-of-truth**, and **graceful failure**. None require a redesign; all are tightenings to the integration shape.

## 2. Critical Issues

### 2.1 Subagent / worker execution context is unaddressed

`/fix-loop` dispatches parallel workers, and `/modernize` orchestrates six specialist agents. Detection relies on the session-start system-reminder, but a subagent's available-skills list is not necessarily the same as the parent's, and the `using-superpowers` skill itself instructs subagents to skip skill bootstrapping ("If you were dispatched as a subagent to execute a specific task, skip this skill"). The design assumes a top-level invocation context throughout.

**Why it matters:** Workers spawned by `/fix-loop` may *be* the place where `systematic-debugging`, `TDD`, `verification-before-completion`, and `finishing-a-development-branch` would actually fire. If the worker doesn't see those skills, the entire /fix-loop per-worker mapping is silently inert.

**Fix:** Add a "Skill visibility in dispatched contexts" subsection. State explicitly whether each command's worker/subagent is expected to inherit skill access, and if not, document how the dispatcher passes a "skills-available manifest" into the worker prompt.

### 2.2 No shared source-of-truth for the prelude boilerplate

The design produces 12 prelude blocks (6 commands × 2 platforms) that share two paragraphs of boilerplate (the detection rule, the Gemini note). The validation plan is "diff-check for consistency" — a manual safeguard against drift that will fail within a few months as commands evolve at different rates. The repository already has a parallel-maintenance burden between `plugins/` and `.agent/`; this design doubles it again across the six commands within each platform.

**Why it matters:** Every future change to the detection rule, the platform note, or the skill-naming convention must be applied in 12 places, with no compile-time check that they stayed in sync.

**Fix:** Define a single canonical prelude template (e.g., `plugins/shared/optional-skills-prelude.md` mirrored to `.agent/shared/`). Each command's prelude consists of two parts: the boilerplate (transcluded or copied with a "source: <path>" comment) plus the per-command mapping table. At minimum, mark the boilerplate text in each file with a sentinel comment so a future linter can detect drift.

### 2.3 Skill-name namespacing is inconsistent in the design itself

The design uses both bare names (`brainstorming`, `writing-plans`) and namespaced forms (`autocoder:improve-test-coverage`). The session's available-skills list shows skills registered under multiple namespace forms (e.g., both `superpowers:brainstorming` and bare `brainstorming` appear in the same list). The mapping tables don't pick one form, which means the agent's match logic is ambiguous.

**Why it matters:** A bare-name match against `brainstorming` could silently bind to a user's local skill of the same name rather than Peter's superpowers version. Worse, if Peter's skill is reorganized into a different namespace in a future release, the tables fall through to the inline fallback with no warning to the user.

**Fix:** State the matching rule explicitly: "Match by exact name as listed; if multiple namespaces exist for the same skill, prefer the `superpowers:` prefix when present." Make every entry in the mapping tables canonical (use `superpowers:brainstorming`, not `brainstorming`).

### 2.4 No defined behavior when an optional skill fails or is denied mid-run

The design says "if installed, invoke; otherwise, fall back." It does not say what happens if the skill *is* installed and is invoked but fails — user denies the tool call, the skill errors out, the skill itself decides not to apply. Inside `/modernize`, half-applied skills (e.g., `executing-plans` partially run, then aborted) could leave the orchestration in an ambiguous state.

**Why it matters:** This is the difference between "opportunistic enhancement" and "fragile dependency." Without a stated rule, agents will improvise inconsistently.

**Fix:** Add one sentence to the prelude rule: "If a skill is invoked and fails or is declined, fall back to the inline protocol for the remainder of that step. Do not retry the skill within the same command run."

### 2.5 Multi-skill ordering and overlap inside a single step

Several commands invoke multiple skills at the same logical step. `/modernize`'s execution row lists `executing-plans`, `subagent-driven-development`, `dispatching-parallel-agents`, and `using-git-worktrees` — three of which encode partially-overlapping orchestration discipline. `/fix`'s "new feature" row chains `brainstorming → writing-plans → TDD`, but the table format suggests parallel options. The skill-priority rule (process before implementation) from `using-superpowers` is not mentioned in the design.

**Why it matters:** The agent will pick an order, and that order will not be deterministic. For `/modernize` in particular, three orchestration skills running over the same phase risks conflicting checkpointing semantics.

**Fix:** For each row that lists more than one skill, either (a) annotate the order ("first → then") or (b) state explicitly that the skills are independent facets and may be invoked concurrently. For `/modernize`'s execution row, pick a primary skill (likely `executing-plans`) and demote the others to "consult as needed for sub-steps."

## 3. Previously Addressed Items

None — this is the first review.

## 4. Alternative Architectural Challenge

**Alternative: Single skill-routing layer instead of per-command preludes.**

Replace 12 prelude blocks with one canonical `optional-skills-routing.md` document plus a tiny per-command "hook table" that names the step IDs the routing layer should resolve. Commands stay otherwise unchanged. The routing layer holds the detection rule, the Gemini note, the namespace policy, the failure semantics, and the full step-to-skill mapping — all in one place.

| Pros | Cons |
|---|---|
| Single source of truth — eliminates the 12-file drift risk (issue 2.2) | Adds a layer of indirection; agents must read two files |
| Skill name/version/namespace policy lives in one editable place (addresses 2.3, 2.4) | Commands lose self-containedness — a key property of the current "command IS a protocol" architecture |
| Easier to add `/assess`, `/retro`, etc. in future rounds — just append to the routing table | Cross-platform mirror still required (one file × two platforms instead of six × two), but the count-per-change drops from 12 to 2 |
| Trivial to audit which skills are wired where | Existing command authors must learn a new convention |

**Recommendation on the alternative:** The current design is appropriate for the current scope (6 commands). I would not switch architectures now, but I would put a sentinel comment in each prelude (`<!-- optional-skills-prelude vN -->`) so a future migration to a routing layer is mechanical, and so a linter can detect drift today.

## 5. Minor Issues & Improvements

- **`/approve-proposal` lists three review skills (critical-design-review, arch-review, security-review).** Without guidance, the agent will run all three or none. Add: "Run only the reviews relevant to the proposal's scope; security-review only if the proposal touches security-sensitive surfaces."
- **`/fix`'s "always-applicable" rows have one stated exception (proposing new tasks).** Frame the always-applicable set by *deliverable type* rather than as default-with-exceptions: `{deliverable=branch}` → worktree/PR rows apply; `{deliverable=document}` → they do not. Cleaner and forward-compatible.
- **`/modernize`'s `create-handoff` mapping says "when context fills mid-project."** Agents notoriously underestimate when context is filling. Add a concrete trigger: e.g., "after each completed phase, or when the running token count exceeds a documented threshold."
- **The validation plan does not include a degraded-mode test** (zero optional skills installed). Add: "Manually run each command with all optional skills disabled and confirm the existing inline protocol runs unchanged."
- **`/fix-loop` dispatcher itself is implicitly a coordinator.** State whether it runs in the host workspace or in a worktree of its own. Currently ambiguous.

## 6. Questions for Clarification

1. Is `/fix-loop`'s worker invoked via the Task tool, or is it a separate `claude`/`gemini` subprocess? The answer determines whether workers see the parent's skill list.
2. Should the prelude be placed before or after existing YAML front-matter / command-description blocks? Command files in this repo have varying structures (some have `<command-name>` tags, some have plain markdown).
3. Is there an expectation that *invoking* a skill counts toward command "completeness" — i.e., does `/fix` consider itself done only after `completion-review` has actually run, or is the inline summary sufficient?
4. When a marketplace version bump ships, do users automatically get the updated commands, or does the prelude need to be feature-flagged for backwards compatibility with users on older skill versions?

## 7. Final Recommendation

**Approve with changes.** The core architecture is correct. Before implementation, the design should:

1. Address subagent/worker skill visibility (issue 2.1) — at minimum, document the assumption explicitly.
2. Add a sentinel comment to the prelude block to enable future drift detection / routing-layer migration (issue 2.2).
3. Pick a canonical skill-naming form and apply it uniformly in the mapping tables (issue 2.3).
4. State failure-mode semantics: skill failure → fall back, no retry (issue 2.4).
5. Clarify multi-skill ordering for rows that list more than one skill (issue 2.5).

These are tightening changes, not redesigns, and can be applied in a single pass to the spec before writing the implementation plan.
