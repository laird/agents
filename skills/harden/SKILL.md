---
name: harden
description: Use this skill to harden a platform — validate and stabilize it through repeated live end-to-end runs (not security hardening) — run, grade against an executable contract, root-cause fix, log learnings, and repeat until N consecutive clean runs. Hardening can be GENERAL (the whole platform) or FOCUSED on a particular goal (e.g. cost accuracy, autonomy, a subsystem). Applies to any system with a runnable end-to-end exercise; project-specific run commands come from the target repo's CLAUDE.md or from the operator.
---

# Harden: the Validation & Refinement Loop

Stabilize a platform by running its real end-to-end cycle repeatedly, treating every run as an
experiment that either passes an explicit contract or hands you the next defect. Proven on the
Athena deal-insights platform (12 runs, 11+ defect classes found and fixed in one day — see
`docs/assessments/2026-08-07-validation-run-log.md` in that repo for the worked example).

## Core loop

**scope → run → grade → fix → log → rerun**, until **two consecutive clean runs** (or the
operator's chosen N) against the declared scope. Never declare stability from one good run; never fix without root cause.

## Step 0 — establish scope and the exercise (before any looping)

**Scope.** Hardening is either:
- **General** — the whole platform must survive the full cycle cleanly; grade every contract
  stage and all telemetry.
- **Goal-focused** — the operator names a goal ("harden cost tracking", "harden the autonomy
  loop", "harden ingest"). Still run the real end-to-end exercise (subsystems fail at their
  seams, not in isolation), but grading WEIGHTS the goal: define goal-specific pass criteria
  (e.g. reconciliation delta ≈ 0), fix goal-relevant defects in-loop, and file off-goal
  discoveries as issues for the swarm/backlog instead of chasing them. State the scope in the
  run log's first entry.

**The exercise.** The loop is only as good as the thing it runs. Before round 1, pin down
exactly how to execute the platform's end-to-end cycle:
1. Read the target repo's `CLAUDE.md` for a hardening/validation binding (Athena: the
   "Validation & Refinement Loop" section — full research cycle via
   `npm run research -- --engagement-id <id> --auto --full-cycle --wait`, worker
   singleton restart procedure, log locations, reconciliation tooling).
2. If absent, discover it: run scripts, package.json/Makefile targets, CI definitions, prior
   run-log docs.
3. If still ambiguous — or the run spends real money, needs credentials, or mutates shared
   state — ASK THE OPERATOR before the first run: what to run, against what target/inputs,
   and the budget.
Then WRITE the binding into that repo's `CLAUDE.md` so the next hardening session skips this
step. Identical inputs across rounds (same target, config, scope) are part of the binding —
that's what makes caches replay and rounds comparable.

## The six steps

1. **Deploy exactly what you think you're testing.** Rebuild, then restart the serving
   process(es) and *verify a singleton* — stale processes holding old code in memory while
   sharing a work queue (Temporal, BullMQ, etc.) silently corrupt validation. `pgrep` the
   process pattern after every restart and kill extras; a process that survives SIGTERM gets
   SIGKILL. This single discipline prevented two corrupted validation rounds on Athena.

2. **Run the real cycle with identical inputs each time.** Same target, same config, same
   scope — so response caches (keyed on prompt+model+params) replay everything unchanged and
   each rerun costs pennies; only genuinely new work (and the code under test) executes live.
   Changing inputs between runs destroys both the cache economy and run-over-run comparability.

3. **Grade against an executable contract, not vibes.** Encode the operator's definition of "a
   successful run" as a checklist the run tool itself evaluates and exits non-zero on (Athena:
   five stages — guidance auto-approved, stress tests ≥ config minimum, deliverable completed,
   audited, findings addressed). Then grade beyond the checklist:
   - **Telemetry**: zero new error classes in the run's logs. An `UNKNOWN`-classified error is
     itself a defect (a classifier gap) — every provider/system error should map to a named,
     correctly-retryable class.
   - **Ground truth reconciliation**: compare the system's account of itself against external
     reality where APIs exist (billing/usage APIs vs internal cost tracking exposed a 4-5×
     undercount on Athena). The daily delta becomes a standing regression test.

4. **Fix at the root, immediately, before the next run.** Symptom patches poison later runs.
   Watch for the recurring failure shapes:
   - *Silent substitution*: the system ran something other than what was asked (wrong model,
     wrong provider, skipped validation) and reported success.
   - *Conditional instrumentation*: logging/cost-recording only on the happy path — add an
     un-bypassable backstop at the narrowest choke point rather than fixing 40 call sites.
   - *Multiple live seams*: triggers with several historical code paths where only one
     actually executes — instrument to find the seam every path shares before wiring fixes.
   - *Environment drift*: zombie workflows, exhausted credits/quota, stray processes.

5. **Log every run, mandatory — richly enough to write the final report from the log alone.**
   Append a chapter per round to the run-log document (e.g.
   `docs/assessments/<date>-<scope>-run-log.md`), committed and pushed with the fixes. Each
   chapter records:
   - **Header**: round number, date/time, and what build/commits are under test ("run N —
     <date> (<what changed since last round>)").
   - **Setup**: scope (general/goal), config deltas, cache state, anything operator-provided
     (credits, budget raises).
   - **Result**: status, duration, cost delta, artifacts produced (deliverable ids, report
     paths), and the contract grading (per-stage ✅/❌ with the checker's detail lines).
   - **Found**: every defect surfaced, each with its root-cause evidence (log lines,
     `file:line`, reproduction) — written so a reader who wasn't present can verify it.
   - **Improved**: every fix landed this round — commit SHAs, test counts, and one line on
     what behavior changed. Include fixes that *disproved* an earlier attempt (wrong seam,
     regression caught) — the misses teach as much as the hits.
   - **Learned**: the durable generalizations (new defect classes, operator rulings on what
     counts as success/pause/failure, environment gotchas) — these accrete into the platform's
     defect-class history and feed the final report's meta-analysis.
   The exit deliverable is a **stabilization verdict** chapter summarizing rounds × defect
   classes × fixes (see Athena's 12-run log for the reference shape: per-round chapters plus a
   closing verdict and a what-we-learned-each-round retrospective table). If the log can't
   answer "what did round N find and improve, and how do we know?", the logging was
   insufficient — fix the log before the next round.

6. **Exit criteria and verdict.** Two consecutive runs passing everything → write a
   stabilization verdict in the log naming what was fixed and what's deliberately deferred.
   If the contract's definition grows mid-loop (operators refine what "working" means when
   they see honest runs), fold the new stages into the executable contract and keep looping.

## Cost discipline

- Warm caches make reruns nearly free — budget systems must not count cache hits against
  live-call quotas (this exact bug starved Athena's first run).
- Provider billing exhaustion mid-run is a *pause-and-wait* condition, not a failure — check
  the provider's billing page before diagnosing "mysterious" degradation.
- When honest validation gets expensive (real work replacing silently-skipped work), surface
  the cost and the cheaper tiers/sampling options to the operator rather than silently downgrading.


## The swarm-mode cadence (canonical sequence)

When a swarm is available, the loop runs in batches:

1. **Run** the exercise; **grade** it (contract + telemetry + reconciliation).
2. **Analyze every finding to execution-ready**: root cause, evidence bundle (log lines,
   file:line, reproduction), proposed fix direction — a finding is not handed off until a
   worker could start coding from it.
3. **Triage**: entangled/seam-uncertain fixes stay with the coordinator (fix → early rerun to
   verify); independent, well-specified findings are filed for the **swarm**.
4. **The swarm works the batch** to completion.
5. **Re-run the exercise** — the batch acceptance test. Fixed findings vanish from the
   grading; regressions and misses reappear with fresh evidence.
6. **Repeat until no findings** — meaning the contract is fully green and no new defect
   classes appear — for **N consecutive runs** (default 2; one clean run can be luck).
   Deliberately deferred items, logged as accepted, don't block exit.

## Scaling the fix phase (autocoder swarms / subagent fan-out)

The loop is single-coordinator by design for run/grade/log and for ENTANGLED fixes — root
causes are usually discovered during grading, and fixing them in-context beats round-tripping
a backlog (the Athena stress-test fix took three attempts across three seams; serial
fix→rerun caught each miss). But when a grading round yields several INDEPENDENT,
well-specified defects (classifier gaps, UI bugs, missing telemetry), fan the fixes out:

- In repos with the autocoder workflow: file each defect as an issue with the grading
  evidence (log lines, file:line, reproduction) and let the swarm work them while the loop
  continues; the next loop iteration is the acceptance test for the whole batch.
- Elsewhere: dispatch parallel subagents, one defect each.
- Either way: assign disjoint file ownership per fix, require bounded commands (per-file
  tests piped to tail, single final build) so workers don't stall watchdogs, and route every
  fix through the loop's code-review gate before the validating rerun.

## Adapting to a project

This skill is project-agnostic. The bindings live in the target repo's `CLAUDE.md`:
the run command, the contract stages, the process pattern for the singleton check, log
locations, and the reconciliation tooling. If the target repo lacks these, your first loop
iteration is to build them: an executable contract checker in the run tool, single-entry
telemetry at the dispatch choke point, and a reconciliation script against external ground
truth. Athena's `CLAUDE.md` §"Validation & Refinement Loop" is the reference binding.
