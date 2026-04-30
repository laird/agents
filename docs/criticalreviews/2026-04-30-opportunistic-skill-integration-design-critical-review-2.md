# Critical Design Review #2 — Opportunistic Skill Integration

**Reviewing:** `docs/superpowers/specs/2026-04-30-opportunistic-skill-integration-design.md` (v2)
**Prior reviews:** review-1 (all 11 issues + AAC + 3 holistic addressed in v2)
**Reviewer role:** Senior Principal Software Architect

## 1. Overall Assessment

v2 is materially stronger than v1. Every issue raised in review-1 is resolved with a substantive design change rather than hand-waving — sentinel-versioned boilerplate, fully-qualified skill names, an explicit failure-semantics matrix, the advisory-not-gating rule, and the deliverable/work-kind decomposition for `/fix` are all real architectural improvements. However, the v2 fixes have themselves introduced several new architectural rough edges concentrated around **the skills-manifest sub-system**, **drift checking that stops at the boilerplate boundary**, and **notation rules that v2 doesn't apply to itself**. Additionally, several pieces of v2 are pseudo-resolutions — TODO-style placeholders dressed up as decisions. None require redesign; all are tightenings.

## 2. Critical Issues

### 2.1 The "skills manifest" subsystem introduced by CDR1-C1 is under-specified

The C1 fix added: dispatcher commands (`/fix-loop`, `/modernize`) "MUST include a skills manifest in each worker's prompt, naming the optional skills the worker should invoke." That contract is the load-bearing piece of the entire dispatcher integration, and the spec leaves the following undefined:

- **Manifest text format.** Is there a canonical template? If yes, where does it live and how is it kept consistent across `/fix-loop` and `/modernize`? If no, two implementations will produce two formats and workers will see inconsistent prompt shapes.
- **Insertion point in the worker prompt.** Top of prompt, bottom, after the work assignment, before? Worker behavior changes depending on placement (LLMs weight earlier tokens differently than later ones).
- **Per-role tailoring.** A coder worker, a tester worker, and a documentation worker have different skill needs. Does the dispatcher pass the *full* manifest to all workers and trust each to filter, or compute a role-specific manifest? The spec implies the former; the per-worker mappings imply the latter.
- **Interaction with `superpowers:subagent-driven-development`.** That skill itself prescribes how to construct worker prompts. If the dispatcher invokes it (it's listed in `/fix-loop`'s and `/modernize`'s mappings), the skill's prompt-construction discipline may conflict with the manifest-passing requirement. Who wins?

**Why it matters:** The whole point of C1 was to make worker-level skills actually fire. If the manifest is malformed, mis-placed, or filtered wrong by the worker, the per-worker mappings remain inert — the original C1 problem returns through the back door.

**Fix:** Specify the manifest as a concrete artifact with the same rigor as the prelude block. At minimum:
- Add a sentinel-versioned canonical manifest template to `plugins/shared/optional-skills-prelude.md` (and Antigravity mirror).
- State the insertion rule: "manifest appears as the first paragraph of the worker prompt, before the work assignment."
- Decide the per-role tailoring policy explicitly (recommendation: dispatcher computes the *intersection* of installed skills × this command's per-worker mapping, passes the intersection to all workers, and lets each worker invoke only what its work needs — simpler than role-specific manifests).
- Resolve the `subagent-driven-development` conflict: state that the manifest is wrapper text *around* whatever prompt that skill produces, not a replacement.

### 2.2 The C2 drift check covers only the boilerplate, not the per-command mapping tables

The CDR1-C2 fix established a sync-check shell pipeline that verifies sentinel-bracketed boilerplate is byte-identical across all 12 command files. That's correct as far as it goes. But the **per-command mapping tables that follow the boilerplate** are exactly the place where drift will most likely occur:

- A maintainer fixes a typo in `/fix`'s feature-work row but doesn't propagate to `.agent/workflows/fix.md`.
- A skill rename triggers updates to `/fix`'s mapping but not `/fix-loop`'s per-worker reference (which transitively depends on `/fix`'s mapping).
- A new skill is added to `/plan`'s table with one notation in Claude and a different notation in Antigravity.

The sync check passes (boilerplate identical). The tables diverge silently. The original CDR1-C2 problem repeats one layer down.

**Why it matters:** This is the same architectural mistake C2 was meant to fix — manual cross-file consistency without a mechanical safeguard — applied to the higher-value content (the actual mappings) rather than the boilerplate.

**Fix:** Either (a) extend the sync-check shell pipeline to compare the entire prelude region (boilerplate + tables) between Claude and Antigravity mirrors of the same command — easy, cheap, catches most table drift; or (b) introduce a sentinel for the table region too (`<!-- BEGIN per-command-mapping -->` / `<!-- END per-command-mapping -->`) and add a separate parity check for that region between mirror pairs. Option (a) is lighter and sufficient.

### 2.3 The C5 notation rules are inconsistently applied within v2 itself

The notation introduced by CDR1-C5 (`→` for sequence, `+` for independent facets, `(primary)` for overlapping orchestration) is the canonical legend stated in the prelude boilerplate and meant to govern all mapping tables. v2 does not apply this notation consistently to its own tables:

- `/modernize`'s "Dispatch coder/tester/etc. agents" row uses semicolons and prose ("when dispatching workers"; "when 2+ independent worker tasks"), not `+` or `→`.
- `/approve-proposal` states the sequence in a separate prose sentence below the table ("Sequence when multiple reviews fire: critical-design-review → arch-review → security-review") rather than inside the table cells.
- `/fix-loop`'s dispatcher row describes the manifest-passing step with "(C1 contract; see Skill visibility in dispatched contexts)" which is documentation, not notation.
- Several rows that contain a single skill don't need notation, but neighbor rows that *do* mix multi-skill prose with the legend create inconsistency in scanning.

**Why it matters:** The notation is the contract that lets readers (human and agent) parse mapping tables unambiguously. v2 is the design that *defines* the notation — if it doesn't follow its own rule, the rule is aspirational rather than load-bearing, and implementations will follow v2's example, not its prescription.

**Fix:** Audit every mapping table cell. Either it contains a single skill, an explicit notation expression (`A → B`, `A + B`, `A (primary)`), or a notation expression with an inline trigger condition. No free-form prose. Specifically:
- Rewrite `/modernize`'s "Dispatch coder/tester/etc." row as: `superpowers:subagent-driven-development + superpowers:dispatching-parallel-agents (when 2+ independent tasks)`.
- Move `/approve-proposal`'s sequence into the row cells: each row gets `→ next-skill-in-sequence` or carries an inline trigger condition.
- For prose like "(C1 contract)", either inline the contract or remove the row and let the dedicated subsection carry the load.

### 2.4 `/fix`'s three-step decomposition has unresolved composition semantics

The CDR1-M2 fix gave `/fix` three stacked tables: deliverable type → applies-when-deliverable-is → kind-of-work. The interaction between the steps is not specified:

- If Step 2 (deliverable=document) says "completion-review only" and Step 3 (work=proposing new tasks) says `superpowers:brainstorming → critical-design-review`, does the agent apply both, only Step 2, or only Step 3?
- If Step 2 (deliverable=branch) says `superpowers:verification-before-completion` (always) and Step 3 (work=docs/chore) says "TDD optional", and verification-before-completion happens to *require* tests be present, do the rules conflict?
- The phrasing "(deliverable is a document; Step 2 confirms worktree/PR don't apply)" inside Step 3's "Proposing new tasks" row suggests Step 3 explicitly references Step 2 for conflict resolution — but only for that one row. For other rows, the relationship is unstated.

**Why it matters:** An agent reading this will guess at composition semantics. Different agents will guess differently. The decomposition was meant to clarify; without composition rules, it adds a degree of freedom that creates inconsistency.

**Fix:** State the composition rule explicitly, once, above the three tables: "**Step 2 and Step 3 compose by union: apply all skills named in either step. Where Step 2 includes a skill that Step 3 marks optional (e.g., TDD), Step 2 wins. Where Step 3 names a skill not in Step 2, add it.**" Or whatever rule the design author actually intends — the choice is less important than stating it.

## 3. Previously Addressed Items (from review-1)

All review-1 issues are resolved in v2:

- **CDR1-C1** Subagent visibility — resolved by skills-manifest contract (though see 2.1 for new gaps in that resolution).
- **CDR1-C2** Boilerplate drift — resolved by sentinel-versioned canonical source + sync check (though see 2.2 for the table-level gap).
- **CDR1-C3** Skill-name namespacing — resolved by fully-qualified-name rule with explicit matching policy.
- **CDR1-C4** Failure semantics — resolved by failure matrix, including the user's later refinements (silent missing, visible failure, one-time superpowers recommendation).
- **CDR1-C5** Multi-skill ordering — notation legend introduced (though see 2.3 for inconsistent application).
- **CDR1-AAC** Routing-layer alternative — explicitly deferred with trigger conditions.
- **CDR1-M1** `/approve-proposal` ambiguity — relevance triggers added per row.
- **CDR1-M2** `/fix` always-applicable framing — replaced with deliverable-type decomposition (though see 2.4 for new composition gap).
- **CDR1-M3** `create-handoff` trigger vagueness — three concrete triggers stated.
- **CDR1-M4** Degraded-mode test missing — validation plan now has 6 numbered checks.
- **CDR1-M5** `/fix-loop` dispatcher placement — explicitly stated as host-workspace.

## 4. Alternative Architectural Challenge

**Alternative: Declarative skill-application descriptors instead of prose-table preludes.**

Replace the prose mapping tables with a small machine-readable descriptor (YAML or JSON) per command — `plugins/autocoder/commands/fix.skills.yaml` etc. — and let a tiny shared snippet at the top of each command file instruct the agent to read the descriptor and apply it. Descriptor schema covers: skill identifier, step ID, trigger condition, notation type (sequence / facet / primary), per-deliverable applicability, per-work-kind applicability.

| Pros | Cons |
|---|---|
| Eliminates 2.2 (drift) and 2.3 (notation inconsistency) by construction — both are syntactically enforced by the schema | Introduces a parser/runtime layer; agents must read two files to understand a command |
| Validation gains a real automated check: "every descriptor parses, references real skill names, satisfies notation invariants" — replacing several manual smoke tests | Breaks the "command IS a self-contained protocol" property the design rests on |
| Easier to add `/assess`, `/retro`, etc. in future rounds — just author another descriptor | Higher up-front authoring cost; contributors must learn the schema |
| Manifest text for dispatchers (2.1) becomes a deterministic projection of the descriptor rather than ad-hoc prose | A descriptor schema is itself a thing that can drift; every fix needs to evolve in lock-step with the schema |

**Recommendation on the alternative:** Do not switch now. v2's prose-table approach is correct for the current scope and aligns with the codebase's existing self-contained-protocol convention. But the gaps in 2.2 and 2.3 demonstrate that prose tables have real maintenance costs that grow with table count. If a future round adds `/assess`, `/retro`, `/retro-apply`, `/improve-test-coverage`, and any agent-level files, the prelude count moves toward 20+ and prose tables become genuinely fragile. At that point, the descriptor alternative deserves a real evaluation — not as a redesign of v2, but as a migration layered on top of the sentinel-versioned structure v2 already establishes.

## 5. Minor Issues & Improvements

- **The recommendation text from CDR1-C4 is still a placeholder.** v2 says "exact wording is set at implementation time against the current public superpowers distribution." This is a TODO dressed as a decision. The implementation engineer will invent text without guidance. Specify the constraints now: link target (the public superpowers repo URL), maximum length (one line, ~120 chars), tone (informational, not nagging), and the expected install command shape.
- **The "advisory, not gating" rule (H3) creates implicit tension with `/fix`'s "always-applicable" branch row.** That row lists `superpowers:verification-before-completion` as "always" applied, but H3 means its outcome is advisory. The user reading the table sees "always," reads the prelude and sees "advisory" — the apparent contradiction is reconcilable but not reconciled in v2. Add a clarifying note: "always applied" means *invoked at the right step*; the *outcome* is still advisory per H3.
- **The H1 "Versions referenced at design time" subsection is human-readable prose.** It records skill versions as a baseline, but the validation plan's "skill contract drift check" has no machine-readable comparison source. Convert the version list to a small `skills-baseline.md` or `skills-baseline.txt` adjacent to the spec, so the drift check has something concrete to diff against in the future.
- **The validation plan is fully manual (6 manual checks × 6 commands × 2 platforms × multiple installation states ≈ 60+ command runs).** No CI hook, no test harness. For a design that emphasizes evidence elsewhere, this is a lot of trust in manual discipline. At minimum, the C2 drift-check shell pipeline can run in CI — propose adding it as a `pre-commit` or GitHub Actions check.
- **No success criteria for the integration itself.** The design has validation steps (does it work?) but no signal for "is it delivering value?" A simple success criterion — e.g., "after one month of use with all skills installed, at least N% of `/fix` runs successfully invoke at least one optional skill" — would let the next retrospective evaluate the integration objectively. Not required for v2 design, but flagging.
- **The `/modernize` `create-handoff` row's "~30 tool calls" threshold is a guess and labeled as one.** Fine as a heuristic; suggest making it tunable rather than load-bearing — "~30 (heuristic; adjust based on observed context pressure in early runs)."

## 6. Questions for Clarification

1. **Manifest format.** Is the manifest a separate paragraph the dispatcher prepends to the worker prompt, or text that the dispatcher *requests* the `superpowers:subagent-driven-development` skill incorporate? The two are different integration models.
2. **Per-worker tailoring of the manifest.** Does each worker get the full manifest (and choose what to apply), or a role-specific subset?
3. **Mid-rollout state.** If a user has an `/fix-loop` running when this change ships, do in-flight workers see the new prelude? (Most likely no — workers were dispatched under the old protocol — but it's worth stating.)
4. **Ownership of the recommendation text.** Whose voice is the up-front "tip" line in? The plugin author? The user's CLAUDE.md? A neutral third-party tone?

## 7. Final Recommendation

**Approve with changes.** v2's core architecture is correct and the resolution of review-1's issues is substantive. Before implementation:

1. Specify the skills-manifest sub-system as a concrete artifact (issue 2.1) — sentinel-versioned template, insertion rule, per-role policy, conflict resolution with `subagent-driven-development`.
2. Extend the C2 drift check to cover the per-command mapping tables, not just the boilerplate (issue 2.2).
3. Audit every mapping cell to apply the C5 notation consistently (issue 2.3).
4. State the Step-2 / Step-3 composition rule for `/fix` explicitly (issue 2.4).

Plus the two minor placeholder-resolutions worth doing in design rather than implementation: pin the recommendation text constraints (M1) and reconcile the "always applied" / "advisory" language tension in `/fix`'s deliverable rows (M2).

These are tightenings, not redesigns, and can be applied in one pass before writing the implementation plan.
