# Critical Design Review #3 — Opportunistic Skill Integration

**Reviewing:** `docs/superpowers/specs/2026-04-30-opportunistic-skill-integration-design.md` (v3)
**Prior reviews:** review-1 (11 issues + AAC + 3 holistic, all resolved in v2); review-2 (4 critical + AAC + 6 minor, all resolved in v3)
**Reviewer role:** Senior Principal Software Architect

## 1. Overall Assessment

v3 is close to ready. Every issue from reviews 1 and 2 is resolved with substantive design changes, the integration shape is internally consistent, and the validation plan now has an automated component. The remaining issues are smaller and concentrated in three areas: **drift detection has a known blind spot v3 doesn't acknowledge**, **the `/fix` composition rule is silent on order-across-steps when sequences are involved**, and **the success-criterion measurement plan is a research project, not a measurement**. None require redesign; all are tightenings or honesty-about-limitations notes.

## 2. Critical Issues

### 2.1 The drift check has a "shared bug" blind spot v3 does not acknowledge

The Pass 2 byte-comparison check verifies that the Claude Code and Antigravity mappings of the same command are byte-identical. This catches *one-sided* edits — the failure mode the parallel-maintenance rule worries about most. It does **not** catch the symmetric failure: a maintainer (or a sloppy AI assistant) edits both files identically and breaks both. In that scenario:

- Pass 1 still passes (boilerplate untouched).
- Pass 2 still passes (mirrors are identical to each other).
- The mapping content itself is wrong on both platforms.
- Smoke tests may or may not catch it depending on which row was broken.

This is a real, intentional limitation of byte-comparison drift detection — but v3 silently presents the drift script as the safety net for table content. Future maintainers will trust the green CI signal without understanding what it does and does not cover.

**Why it matters:** Trust in the wrong signal is worse than no signal. A maintainer who sees the drift check pass will skip the manual smoke test, exactly where the shared-bug failure mode would surface.

**Fix:** Add an explicit "Known limitation" subsection to the drift-check section: "Pass 2 verifies cross-platform parity, not correctness. A bug replicated to both mirrors satisfies Pass 2. Smoke tests (validation steps 3 and 4) are the safety net for content correctness; the drift check is only a safety net for cross-platform drift." Document it where the drift check is presented, not buried elsewhere.

### 2.2 `/fix` composition rule does not specify order when steps mix sequences and facets

The CDR2-C4 fix established: Step 2 ∪ Step 3, stronger-wins on required-vs-optional. The rule covers *whether* a skill applies; it does not cover *when* it applies relative to other skills from the other step.

Concrete ambiguity. Consider a "branch + new feature" `/fix`:

- **Step 2 contributes:** `using-git-worktrees + verification-before-completion + completion-review` (independent facets, "always" applied)
- **Step 3 contributes:** `brainstorming → writing-plans → TDD` (a strict sequence)

The union is six skills. v3 does not say where the Step 2 facets fit relative to the Step 3 sequence. Plausible orderings differ in observable behavior:

- Worktrees provisioned *before* brainstorming → spec is written inside the worktree.
- Worktrees provisioned *between* writing-plans and TDD → spec lives in host, code lives in worktree.
- Verification-before-completion runs *during* TDD vs. *after* TDD vs. *as a final wrap* — all defensible, all different.

Different agents will produce different orderings, and the integration's value (consistent discipline) erodes.

**Why it matters:** Sequences and facets are different types of constraints. A union of "ordered set ∪ unordered set" is not itself well-defined without a framing rule.

**Fix:** Add to the Composition rule, immediately after the union/stronger-wins paragraph: "**Ordering across steps.** Step 3 sequences (`A → B → C`) define the spine. Step 2 facets attach at natural points in the spine: provisioning facets (e.g., `using-git-worktrees`) at spine entry; verification facets (e.g., `verification-before-completion`) at spine exit; wrap-up facets (e.g., `completion-review`, `requesting-code-review`) after spine exit. Where a facet has no obvious attachment point, attach at spine exit. The agent uses judgment for facets without a documented attachment hint."

### 2.3 Validation plan does not verify the manifest sub-system itself

CDR2-C1 made the worker skills manifest a load-bearing artifact: it's the entire mechanism by which `/fix-loop` and `/modernize` workers see optional skills. v3's validation plan covers degraded mode and enhanced mode at the command level, but neither explicitly verifies:

- The dispatcher correctly intersects its available-skills list with the per-worker mapping.
- The manifest text is byte-identical to the canonical template.
- The manifest is actually inserted as the first paragraph of the worker prompt (not buried below it, not omitted).
- Workers receiving the manifest behave as if the listed skills are available.

A bug in any of these renders the per-worker mapping inert — the original C1 problem returns silently, and smoke tests pass because the worker's inline fallback still completes the work.

**Why it matters:** The manifest is the most fragile piece of the integration (most plumbing, most context-sensitivity), and the validation plan treats it as an internal detail of the dispatcher commands rather than the explicit subsystem it is.

**Fix:** Add a validation step 7: "**Manifest verification (dispatcher commands only).** For `/fix-loop` and `/modernize`, manually inspect a single dispatched worker prompt with logging or print-debug instrumentation. Confirm: (a) the manifest is the first paragraph of the worker prompt, (b) the bullet list is the intersection of installed skills × per-worker mapping (not the full mapping; not empty when skills are present), (c) the boilerplate matches the canonical manifest template byte-for-byte." This is a one-time check per dispatcher command at implementation time, not an ongoing burden.

## 3. Previously Addressed Items

All review-1 items: see review-2 § 3.
All review-2 items resolved in v3:
- **CDR2-C1** Manifest spec — resolved by canonical text, insertion rule, per-role policy, and conflict resolution with `subagent-driven-development`.
- **CDR2-C2** Mapping-table drift — resolved by second sentinel scope and Pass 2 of the drift script (though see 2.1 for the shared-bug blind spot).
- **CDR2-C3** Notation inconsistency — resolved by audit and rewrite of all five inconsistent cells, plus the leading-`→` row-spanning convention added to the legend.
- **CDR2-C4** `/fix` composition rule — resolved by union with stronger-wins (though see 2.2 for the order-across-steps gap).
- **CDR2-AAC** Declarative descriptors — explicitly deferred with trigger conditions.
- **CDR2-M1** Recommendation text — pinned in canonical prelude (though see 5.1 for URL verification).
- **CDR2-M2** "Always applied" / "advisory" tension — clarified.
- **CDR2-M3** Version baseline — extracted to machine-readable file.
- **CDR2-M4** Validation manual-only — drift check now scripted and CI-wireable.
- **CDR2-M5** Success criteria — added (though see 2.x and 5.x for measurement-mechanism gaps).
- ~30 threshold tunability — labeled as heuristic.

## 4. Alternative Architectural Challenge

**Alternative: Skip the manifest sub-system entirely; require dispatcher commands to have an agent-level prelude in `coder.md`, `tester.md`, etc.**

Rather than the dispatcher passing a manifest to workers, workers (which run as the existing specialist agents) would have their own prelude block in their agent file (`plugins/modernize/agents/coder.md`, etc.). Each agent's prelude would reference the same canonical boilerplate and carry an agent-specific mapping table.

| Pros | Cons |
|---|---|
| Eliminates the entire manifest sub-system (CDR2-C1 fix becomes unnecessary) — workers see skills the same way top-level commands do | Requires editing 6 agent files, doubling this round's scope |
| Self-contained: each agent's prelude lives where the agent is defined (matches the "command IS a protocol" architectural property at the agent level) | Some agents are invoked by multiple commands — coder runs in both `/modernize` and `/fix-loop`. The agent's prelude must be a superset of every dispatcher's per-worker mapping, which couples the agents to the dispatchers in a different way |
| Drops "Worker skills manifest" subsection, all of CDR2-C1 fix complexity, and the manifest sentinels (CDR2-C2 Pass for manifest text becomes unnecessary) | The user explicitly chose "command level first" earlier in the design dialogue; this alternative reverses that choice |
| Validation step 7 (2.3 above) reduces to a parity check on agent files | Agent-level changes were declared out of scope for this round |

**Recommendation on the alternative:** Reject for this round, on the explicit ground that "command level first" was a deliberate user choice that this design has internalized. Note the alternative in "Out of scope, future rounds" alongside agent-level integration in general — when agent-level integration is taken up, the manifest sub-system can be retired in favor of agent-level preludes, and the dispatcher commands simplify accordingly.

## 5. Minor Issues & Improvements

- **5.1 The recommendation URL `https://github.com/obra/superpowers` is unverified at design time.** v3 says "URL and install path are verified at implementation time," but the URL appears verbatim in the canonical prelude as a load-bearing piece of user-facing text. Shipping with a guessed URL means every command potentially emits a broken link. Mark this as an implementation-blocking item: the implementation plan must verify the actual URL of the public superpowers distribution and the actual install command before any prelude file is written. If the project is distributed under a different identifier (the cached path `~/.claude/plugins/cache/claude-plugins-official/superpowers/...` suggests the marketplace identifier is `claude-plugins-official`), the install command should reflect that.

- **5.2 The success criterion measurement mechanism is undefined.** "Measured via per-run HISTORY.md entries" tells the agent to *write*, not who *reads*. After one month, "60% of /fix and /plan runs invoke at least one optional skill" requires someone to count entries, define what "a /fix run" means in the log, and publish a result. Without a documented procedure (or even a one-liner shell command that produces the percentage), the success criterion is theatrical. Either define a concrete computation (`grep -c "skills: superpowers:" HISTORY.md / grep -c "command: /fix" HISTORY.md`) or downgrade the criterion from "≥60%" to "skills are observably firing in some runs" — a qualitative check that doesn't pretend to be a metric.

- **5.3 HISTORY.md instrumentation is scope creep on the additive-only constraint.** The design's core promise is "the existing protocol body is not modified." Success criterion measurement (CDR2-M5) requires every command to emit a structured line to `HISTORY.md` per run — a new behavior, not an opportunistic skill enhancement. v3 doesn't acknowledge this. Either accept the scope creep (state it explicitly, list the per-command edits required, factor them into the implementation plan) or move HISTORY.md instrumentation to "Out of scope, future rounds" and downgrade the success criterion accordingly.

- **5.4 The drift script's `find plugins/*/commands -name "${cmd}.md" -print -quit` is fragile.** If a command name later exists in both `autocoder/commands/` and `modernize/commands/`, `-print -quit` returns one arbitrarily and the other silently escapes the check. Today no command name collides; tomorrow's reorganization might. Add an assertion: `[ $(find plugins/*/commands -name "${cmd}.md" | wc -l) -eq 1 ] || { echo "ERROR: ${cmd} matches multiple files"; exit 1; }`.

- **5.5 UX of advisory-failure + inline-success is unaddressed.** When `superpowers:verification-before-completion` reports "verification failed" and the inline protocol's tests pass, v3 says: surface the skill's failure (per CDR1-C4) and let the inline protocol claim success (per CDR1-H3). The user sees a failure message and then a success claim from the same command — a confusing sequence that looks like the command is lying. State the user-facing presentation explicitly: e.g., the command's success summary acknowledges any visible advisory failures ("Completed per inline protocol; advisory skill `verification-before-completion` reported a concern — see above"). Otherwise the two rules combine into bad UX even if each is individually correct.

- **5.6 `subagent-driven-development` interaction unverified.** v3 asserts "the manifest is wrapper text; the skill owns the body." This is an interface contract with another component whose implementation is not reviewed in this design. If `subagent-driven-development` requires a specific opening (e.g., a TodoWrite directive must be the first paragraph), the manifest displaces it and the skill breaks. Implementation plan should include "read `superpowers:subagent-driven-development` v5.0.7 and verify the manifest-as-first-paragraph rule does not conflict with its own prompt-construction discipline" as a pre-flight check.

## 6. Questions for Clarification

1. **Implementation order.** Should the canonical prelude file be written first (so command edits can transclude it) or after the command edits land (so the canonical text is settled by the actual usage)? Either works; choosing now avoids back-and-forth.
2. **HISTORY.md schema.** If 5.3 is accepted as a real edit (rather than out-of-scope), what's the line format? Free-form prose, or a structured `command: <name>; skills: <comma-list>; deliverable: <type>` entry?
3. **Drift-check exit code.** Pass 1 reports a unique-hash count; Pass 2 reports per-command status. Should the script exit non-zero on any drift (CI-friendly) or always exit zero with informational output? Current pseudo-code does neither explicitly.

## 7. Final Recommendation

**Approve with minor changes.** v3's core architecture is settled. Before writing the implementation plan:

1. Document the drift-check shared-bug limitation explicitly (issue 2.1).
2. Extend the `/fix` composition rule to specify ordering when steps mix sequences and facets (issue 2.2).
3. Add validation step 7: manifest verification for dispatcher commands (issue 2.3).
4. Either define a concrete success-criterion computation or downgrade the criterion (5.2 + 5.3 together).
5. Mark the recommendation URL as implementation-must-verify (5.1).

The remaining minors (5.4, 5.5, 5.6) can be addressed in the implementation plan rather than another design revision. v4 should be a tightening pass, not a redesign — likely the last design iteration before implementation.
