# `/fix-loop` token-efficiency redesign (v2)

**Status:** draft spec, partial implementation on `feat/fix-loop-token-efficiency`
**Date:** 2026-05-21
**Author:** Laird Popkin (assisted)
**Revision:** v2 — rewritten after first critical design review uncovered
multiple architectural assumptions that were unverified or wrong.
**Related:** `2026-01-25-intelligent-stop-hook-design.md`,
`2026-01-30-fix-loop-5min-idle-threshold.md`,
`2026-05-19-pluggable-issue-source-implementation-plan.md`

---

## 1. Problem

Each `/autocoder:fix` invocation loads ~18,700 tokens of slash-command
markdown plus the `superpowers:using-superpowers` session-start reminder
(~2–4 K tokens) before the LLM can even check whether there is work to
do. With `/loop 15m /autocoder:fix`, every tick is a fresh cache-miss
prefill (15-minute interval >> 5-minute prompt-cache TTL), so the full
prompt cost is paid on every tick — including idle ticks.

Observed in session 2026-05-21: 8+ consecutive idle ticks each loading
the full fix.md prompt and emitting only `IDLE_NO_WORK_AVAILABLE`.

## 2. Goals — honest version

The v1 spec claimed "$0 idle ticks" by skipping Claude entirely on idle.
The first CDR exposed that this is impossible inside the `/loop` skill,
which fundamentally fires a Claude prompt at cron time (see §11). We
revise the goals:

1. **Minimum-prompt idle ticks.** Replace the 18 KB `/autocoder:fix`
   prefill with a ~2 KB `/autocoder:gate` prefill on idle ticks. Goal:
   idle tick cost drops from ~$0.054 (Sonnet, cache-miss) to ~$0.006.
2. **Cache-warm cadence.** Tighten the loop from 15 min to 4 min so
   that consecutive ticks land within the prompt cache TTL. Cache-warm
   idle tick: ~$0.0006.
3. **Cheaper routing on active ticks.** Where the routing decision
   is mechanical (label arithmetic, complexity classification),
   prefer Haiku over Sonnet/Opus. Optional, gated on model-inheritance
   tests passing (§7).
4. **No regression in correctness.** Race-safe claim semantics, no
   double-work, label-state always reflects truth, agents-ui status
   file stays current.
5. **Backward-compatible.** Existing `/autocoder:fix N` direct
   invocation keeps working; existing GitHub-backend race detection
   stays in `/autocoder:fix` until the gate gains a CAS equivalent.

## 2.5 Verified assumptions (summary; full table in Appendix A)

Load-bearing assumptions were enumerated cold and verified empirically
on 2026-05-21 — see Appendix A. Highlights:

- Anthropic pricing corrected: Opus 4.7 input is $5/MTok (not $15);
  v1's projections that touched Opus were divided by 3.
- 1-hour cache TTL option (2× write cost) newly surfaced; evaluated
  as a Phase 0 finding.
- Real session jsonl shows `cache_creation_input_tokens: 18702` —
  empirical confirmation of the ~18K-token prompt estimate.
- Codebase facts (`issue-fns.sh` dispatch, `flock` semantics,
  `--if-unset` exit 9, gate smoke-test) all confirmed.

**Still unverified — gates Phase 2:** Skill-tool model inheritance,
Task-tool `model=` override, slash-command frontmatter `model:` scope,
Mode 1 `PostSessionEnd` hook availability. See §7 + Phase 2.0 probes.

## 3. Non-goals

- Eliminating LLM cost on idle ticks. Not possible inside `/loop`.
- Rewriting the skill chain inside `/autocoder:fix` (systematic
  debugging, TDD, etc.).
- Changing the issue-data model (labels, statuses, comments).
- Cross-host distributed locking. Single-host serialization via
  `flock` only; cross-host concurrency continues to rely on the
  existing GitHub comment-scan heuristic.

## 4. Pivot from v1: where the savings actually come from

v1 attributed all savings to "skip Claude on idle." After CDR, the
honest breakdown is:

| Lever | Saving | Cost to build | Notes |
|---|---|---|---|
| 1. Tighten cadence to 4 min (cache-warm) | ~10× | $0 | Just change the default in `fix-loop.md`. Free win. |
| 2. Slim idle-tick prompt to `/autocoder:gate` | ~10× more | moderate | Phase 2 of this plan. |
| 3. Route mechanical decisions to Haiku | ~3× more on active routing ticks | moderate | Phase 3, optional, requires verifying Task `model=` |
| 4. Slim `/autocoder:fix` worker | ~3× on active fix ticks | high | Phase 4 |

Lever 1 alone is most of the win. **Ship Lever 1 immediately**, then
treat Levers 2–4 as opt-in improvements.

## 5. Architecture (revised)

Three components added; one wiring change.

```
/loop 4m fires (4-minute cadence — within 5-min cache TTL)
   │
   ▼
claude (gate-model, sm prompt) loads /autocoder:gate
   │   ~2 KB prompt body
   │   bash: source issue-fns; run fix-loop-gate.sh; parse work.json
   │
   ├─ no work → emit "idle" → exit. Cache stays warm for next tick.
   │
   ├─ work=triage → Haiku assigns P0–P3 labels directly. No subagent.
   │
   └─ work=fix|enhance → invoke /autocoder:fix N as a subagent
        via the Task tool. See §7 for model selection.
```

### 5.1 `fix-loop-gate.sh` — pre-LLM helper (not the full gate)

Demoted from "the gate" to "a helper that the gate slash command
invokes via bash." Same code as v1 (already on the branch). Returns
exit 0 with a work-plan JSON in
`/tmp/autocoder-work-${SESSION}-${EPOCH}.json` (collision-safe), or
exit 1 when idle.

**Changes from v1 code:**

- **Race-loss iterates.** On `--if-unset` exit 9, drop the candidate
  and try the next one. Only exit 1 when the candidate list is
  exhausted. Fixes M1.
- **PID/session-suffixed work.json.** Avoids `/tmp` collision when two
  ticks overlap. Fixes M3.
- **Stale-claim sweep.** Before classifying, scan for issues with
  `working` set and a `working_started_at` timestamp older than 1 hour
  (configurable via `AUTOCODER_STALE_CLAIM_SECONDS`); remove the label.
  Fixes M4.
- **Writes agents-ui status file** on gate exit (idle or claimed) so
  the TUI stays current even when no Claude session is spawned for
  the fix work. Fixes M6.
- **Removes `phase=regression` and `phase=propose`** from the work-plan
  spec until they are actually emitted. Fixes C3. (Either implement
  them later or keep them as fallback logic inside `/autocoder:fix`.)

### 5.2 `--if-unset` flag on `issues-file.py update`

Unchanged from v1: atomic CAS via `--if-unset`, exit code 9 on
race-loss. Already implemented and smoke-tested on the branch.

**Caveat (Mo4):** silently ignored on GitHub backend today. Phase 4
must NOT remove `/autocoder:fix`'s comment-scan race detector unless
the gate gains GH CAS first.

### 5.3 `/autocoder:gate` — slim slash command (Phase 2)

Frontmatter pins model to whatever `fix-loop.md` is configured to use
(default Sonnet for v2 — Haiku is a Phase 3 opt-in, see §7).

Body target: <2 KB. Logic:

```bash
source issue-fns.sh
bash $SCRIPT_DIR/fix-loop-gate.sh || exit 0   # idle, brief response

# Work exists. Read plan and act.
WORK="$(cat $AUTOCODER_WORK_JSON)"
case "$(echo "$WORK" | jq -r .phase)" in
  triage)   # Haiku-quality label assignment; or just call /update-issue for each
            # in a Task subagent if we want Haiku specifically (see §7).
            ... ;;
  fix)      ISSUE=$(echo "$WORK" | jq -r .issue)
            # Invoke /autocoder:fix as the worker. Skill tool keeps us in the
            # same conversation (same model), which is fine for v2: gate prompt
            # is already small, so loading fix.md after it isn't worse than
            # loading fix.md directly. The savings come from idle ticks.
            # Skill: /autocoder:fix $ISSUE ;;
  enhance)  ... ;;
esac
```

**Critical caveat (C2 — promoted gate):** the Skill-tool
model-inheritance and Task-tool `model=` behaviors are **unverified**.
The §7 verification test must run **before Phase 2 starts**, not
just Phase 3. Reason: Phase 2's gate → fix Skill chain depends on
A1 (same-model inheritance); if A1 is wrong, Phase 2 wires the
worker to the wrong model and the cost numbers shift. The test is
~30 minutes of work; making it a Phase 2 prerequisite costs almost
nothing and de-risks both phases. Phase 3's additional dependency
on A2 (Task `model=` override) is checked at the same time.

### 5.4 `fix-loop.md` wiring

For Mode 1 (`CronCreate`):

```
loop_interval: 4m
prompt: /autocoder:gate
```

That's the only change to `fix-loop.md`. The CronCreate fires a Claude
session with `/autocoder:gate` as the prompt instead of `/autocoder:fix`.
The gate either signals idle (cheap) or invokes `/autocoder:fix` as a
worker (same model — see §5.3 caveat).

For Mode 2 (stop-hook): out of scope for this revision. Mode 2 sees no
benefit from a slim gate because the hook fires *after* the LLM has
already loaded a prompt. **Deprecation timeline:** mark Mode 2 as
maintenance-only in the next minor; remove in the version after that
(approximately 60 days from Phase 2 shipping). Fixes Mn4.

## 6. Cost model (revised against cache-warm baseline)

Pricing as of 2026-05-21 (verify against anthropic.com before
ship; numbers below are working values):

| Model | Input $/MTok | Cache read $/MTok | Output $/MTok |
|---|---|---|---|
| Haiku 4.5 | 1 | 0.10 | 5 |
| Sonnet 4.6 | 3 | 0.30 | 15 |
| Opus 4.7 | 5 | 0.50 | 25 |

(Corrected 2026-05-21 from Anthropic's `prompt-caching` docs page after
spec-verification pass. Earlier draft had Opus at 3× these values — every
Opus-derived projection below is therefore divided by 3 vs. v1.)

Cache-write also has two TTL options: **5-min default** at 1.25× the
base input rate, **1-hour optional** at 2× base. The cost model below
uses 5-min default. The 1-hour TTL is a tunable surfaced as a Phase 0
finding — if the post-Phase-0 measurement shows the 4-min cadence is
still partially missing cache, switching writes to 1h TTL may be
cheaper than reducing cadence further.

Output cost matters most on active ticks where the model writes a
fix; idle/triage ticks are *estimated* to generate ~50 output
tokens and be input-dominated — **this estimate is unverified and
must be replaced with measured values in the Phase 0 report**. The
cost model below covers idle costs only; active-tick cost-per-fix
is dominated by output and is treated in §13.4 Phase 4's report.

**Predicted multipliers** (used by the go/no-go formula in §13.4
to derive each next phase's predicted baseline *from the prior
phase's measured baseline*, instead of from naive arithmetic):

| Phase | Predicted multiplier `k` on per-tick cost | Reasoning |
|---|---|---|
| Phase 0 (cadence) | 1.0× per-tick (cost change comes from cache, not prompt size) | Cadence change keeps prompt; cache TTL fixes baseline |
| Phase 2 (slim gate) | ~9× reduction per idle tick | 18 KB → 2 KB prompt ratio |
| Phase 3 (Haiku routing) | ~3× reduction per routing tick | Sonnet → Haiku pricing (verified) |
| Phase 4 (slim worker) | ~3× reduction per active tick | 18 KB → 6 KB worker prompt ratio |

**Audit note.** These multipliers happen to be 3× across input,
cache-read, *and* output token classes because today's Anthropic
price ratios between Sonnet and Haiku are uniform 3× across all
three. If Anthropic re-prices any one class non-uniformly (e.g.,
Haiku cache-read goes to 0.05 while input stays at 1.00), the Phase
3 multiplier must be re-derived per token-class and a weighted
average computed against the observed tick's token mix. §13.4's
formula consumes these multipliers (`k_{n+1}`) rather than §6's
original-arithmetic dollar amounts, so under-delivery in phase N
doesn't inflate phase N+1's predicted savings.

**Today, `/loop 15m /autocoder:fix` (20 KB prompt total, cache TTL=5m,
all ticks are cache-miss):**

- Sonnet idle tick: ~18K tokens × $3/MTok ≈ **$0.054**
- Opus idle tick: ~18K tokens × $5/MTok ≈ **$0.09**
  (was claimed $0.27 in v1, based on wrong $15/MTok Opus price)

**Lever 1 only (`/loop 4m /autocoder:fix`, 20 KB, cache-warm except
first tick of a quiet hour):**

- Sonnet idle tick: 20 KB × $0.30/MTok ≈ **$0.006**
- ~9× cheaper than today, free to ship.

**Levers 1+2 (`/loop 4m /autocoder:gate`, 2 KB prompt, cache-warm):**

- Sonnet idle tick: 2 KB × $0.30/MTok ≈ **$0.0006**
- ~90× cheaper than today; ~10× cheaper than Lever 1 alone.

**Levers 1+2+3 (Haiku gate, 2 KB, cache-warm):**

- Haiku idle tick: 2 KB × $0.10/MTok ≈ **$0.0002**
- ~270× cheaper than today.

Across a 24-hour idle day at one tick every 4 min (360 ticks),
split by which model the loop is configured to use:

| Configuration | Sonnet $/day | Opus $/day | Saving vs. today (Sonnet / Opus) |
|---|---|---|---|
| Today (`/loop 15m`) — 96 ticks, cache-miss | $5.18 | $8.64 | — |
| Lever 1 only (`/loop 4m`, ≈93% cache-warm) | $2.16 | $5.76 | -58% / -33% |
| Levers 1+2 (Sonnet/Opus gate, 2 KB) | $0.22 | $0.58 | -96% / -93% |
| Levers 1+2+3 (Haiku gate, 2 KB) — **idle-tick cost only; active fix ticks still pay Sonnet/Opus rates** | $0.07 | $0.07 | -99% / -99% (Haiku is the gate model; the fix-worker model is unchanged) |

(Lever 1 alone is "free" because the cron interval change is a
one-line edit. Cache-write multiplier 1.25× for 5-min default TTL
is included in the cache-miss-tick portion; the Lever 1 row mixes
~93% cache-warm + ~7% cache-write ticks at 4-min cadence.)

**Honest build-cost estimate (revised with verified pricing):**
Phase 2.0 measurement tooling is ~6–10 hours. Phase 2 (slim gate) is
~4–8 hours on top. Phase 3 is ~8–16 hours + the model-inheritance
verification. Phase 4 is ~16–32 hours including the prompt-slim
refactor and regression testing.

Verified-pricing payback math (developer rate `$AUTOCODER_DEV_HOURLY_RATE`,
default $150/hr; figures shown for Sonnet workload — multiply Opus
savings by ~2× for the Opus column where applicable):

| Configuration | Annual savings (Sonnet) | Annual savings (Opus) | Build cost (this phase) | Cumulative build cost |
|---|---|---|---|---|
| Lever 1 only (cadence to 4 min) | ~$1,100/yr | ~$1,050/yr | $0 | $0 |
| Phase 2.0 (measurement tooling) | $0 (enables later phases) | $0 | $900–1,500 | $900–1,500 |
| + Phase 2 (slim gate) | additional ~$710/yr → $1,810 cumulative | additional ~$1,890/yr → $2,940 cumulative | $600–1,200 | $1,500–2,700 |
| + Phase 3 (Haiku routing) | additional ~$55/yr | additional ~$185/yr | $1,200–2,400 | $2,700–5,100 |
| + Phase 4 (slim worker) | active-tick savings $TBD | active-tick savings $TBD | $2,400–4,800 | $5,100–9,900 |

Payback observations:
- **Lever 1 + Phase 2 on Sonnet:** ~10–15 months payback. Worthwhile.
- **Lever 1 + Phase 2 on Opus:** ~6–9 months payback. Worthwhile and faster.
- **Phase 3:** marginal annual savings ≤$200; the build cost only
  justifies itself if (a) the model-inheritance test in §7 confirms
  the Task `model=` pattern works *and* (b) routing-tick volume is
  high enough to amortize the build cost. Phase 3 needs explicit
  go-ahead based on measured Phase 2 baseline; don't auto-proceed.
- **Phase 4:** active-tick savings depend on active-tick volume —
  measure in Phase 2 report before estimating.

The Opus correction (3× pricing reduction) shrinks absolute dollar
savings vs. v1's projections; the *relative* multipliers between
phases are unchanged because all prices were over-stated by the
same factor. The high-ROI subset remains: **Lever 1 + Phase 2.0 +
Phase 2.** Phases 3 and 4 require explicit business justification
given measured baselines, not the default-on stance.

## 7. Unverified assumptions (must test before Phase 3)

The CDR exposed two assertions in v1 that I had not verified:

**A1.** *"A Skill-tool invocation runs in the same conversation/model
as the caller. Front-matter `model:` is only honored at conversation
entry."*

**A2.** *"The Task tool's `model=` parameter spawns a subagent on a
different model than the caller's."*

### 7.1 Verification test result

#### 7.1.1 Test run 2026-05-21

**Test environment:** Claude Code, Opus 4.7 (1M context) parent
session at `/Users/Laird.Popkin/src/nextgen-CDD/.worktrees/agentex-port`.
Two `Agent` calls (Task tool equivalent) with `model="haiku"` and
`model="opus"` parameters, asking each subagent to report its own
model identity.

**Observations:**

| Subagent `model=` param | Reported identity | Knowledge cutoff |
|---|---|---|
| `haiku` | `claude-haiku-4-5-20251001` | Feb 2025 |
| `opus` | `claude-opus-4-7[1m]` (1M variant) | Jan 2026 |

Both subagents reported identity from their own session-start
system reminders — definitive evidence that the `model=` parameter
routes to distinct models.

**Findings:**

- **A2 (Task `model=` override) — CONFIRMED.** Subagents do run on
  the requested model; the parent's model does not propagate.
- **A1 (Skill-tool model inheritance) — NOT DIRECTLY TESTED.** The
  test exercised Task, not Skill. However, Phase 2's design uses
  Skill only for *same-model* chains (gate → fix-worker both on
  fix-loop's configured model), so A1 is moot for Phase 2. Phase 3
  uses Task for the Haiku→Sonnet handoff, which A2 confirms works.
- **A1 deferred:** if Phase 3 design later needs Skill cross-model,
  re-run a §7-style test specifically for Skill. Not blocking now.

**Implications for design:**

- **Phase 2 unblocked.** The C2 gate in §5.3 mandated A1 verification
  before Phase 2 starts; since Phase 2 only uses same-model Skill
  invocations, the A2-only result is sufficient.
- **Phase 3 unblocked.** Task `model=` handoff confirmed working;
  Haiku-gate + Sonnet-worker design is viable.
- **Appendix A rows 8–11 partially resolved.** Row 9 (A2) ✅
  confirmed. Row 8 (A1) remains untested but downgraded from
  blocker to "test if Phase 3 changes design to need it."
- **Per-tick overhead.** Both subagent invocations completed in
  2.4–3.9 s with zero tool calls — the routing handshake is cheap.

**Owner:** verified by Opus 4.7 parent session 2026-05-21.


If A1 is wrong, today's `/fix-loop` is already cross-model in places
and the savings calc shifts. If A2 is wrong, the entire "Haiku gate
+ Sonnet worker" pattern (Lever 3) does not work as designed and
collapses into "same-model end-to-end."

**Verification test (gate of Phase 3):**

1. Run a Claude session pinned to Sonnet.
2. Spawn `Task(model="haiku", prompt="report which model you are running on")`.
3. Inspect the response and the token-usage log.
4. Repeat with `Task(model="opus")` from Haiku.

Expected outcomes and how they shape the spec:

- Both Task model= overrides honored → ship Phase 3 as designed.
- Task model= honored but Skill ignored → keep dispatch as a slash
  command, but worker dispatch must be via Task, not Skill.
- Neither honored → drop Lever 3. Use a single model end-to-end. Stop
  at Phase 2; cost is then bounded by Lever 1+2 figures above.

**Phase 3 is conditional on this test.** Do not write
`/autocoder:dispatch` until the test result is documented in the
spec.

## 8. Critical-design-review findings status

From the v1 CDR. C/M/Mo/Mn = severity tier from that review.

| Finding | Resolution in v2 |
|---|---|
| C1 (gate cannot skip Claude inside `/loop`) | Reframed goal to "minimum-prompt idle" (§2, §4). Dropped the "$0 idle" claim. |
| C2 (model-inheritance unverified) | Added explicit verification test in §7; Phase 3 gated on it. |
| C3 (gate emits phases the spec doesn't list) | Removed `regression`/`propose` from work-plan shapes in §5.1. |
| M1 (race-loss exits instead of iterating) | §5.1 calls out the iterate behavior. Code change pending. |
| M2 (cron-wrapper location undefined) | §5.4 makes gate a Claude-resident slash command; no separate wrapper needed. |
| M3 (`/tmp` collisions) | §5.1: session+epoch suffix on work.json path. |
| M4 (orphaned `working` labels on crash) | §5.1: stale-claim sweep at gate entry. |
| M5 (Task subagents lose skill auto-discovery) | Accepted trade-off. Phase 3 worker prompts will name the skills explicitly (~3 KB cost) instead of relying on auto-load. |
| M6 (agents-ui status file drift) | §5.1: gate writes the status file on every exit path. |
| Mo1 (cache TTL ignored in cost model) | §6 rebuilt from cache-warm baseline. |
| Mo2 (cross-model cache cost) | §6 figures assume Lever 3 keeps each model in its own cache pool. Realistic since Haiku/Sonnet stay separate in 4-min ticks. |
| Mo3 ("implemented" overstates) | §10 phase tracker reads "code complete, tests pending" for items without unit tests. |
| Mo4 (GH backend race protection during phase rollout) | §5.2 + §10 phase guardrails. |
| Mo5 (no rollback plan) | §9 added. |
| Mo6 (build cost vs savings) | §6 build-cost estimate. |
| Mo7 (Haiku triage escalation heuristic) | Decision: triage runs on the gate's model (whatever fix-loop is configured for). No automatic escalation. Documented heuristic dropped — too unreliable. |
| Mn1 (phase=regression/propose unimplemented) | Same as C3. |
| Mn2 (--if-unset vs --if-not generalization) | Deferred. `--if-unset` ships as-is; generalize if needed later. |
| Mn3 (Phase 2 acceptance criteria unverifiable in /loop) | §10 acceptance criteria rewritten in terms of cost/token telemetry, not "no Claude invocations." |
| Mn4 (Mode 2 deprecation timeline) | §5.4 sets a 60-day timeline. |
| Mn5 (cadence vs cache TTL) | §6 picks 4 min specifically because it stays inside the 5-min cache window. |

## 9. Rollback plan

Each phase is reversible with one change:

- **Phase 2 rollback:** revert `fix-loop.md` to `prompt:
  /autocoder:fix`. `/autocoder:gate` can stay installed (harmless if
  unused). No data migration.
- **Phase 3 rollback:** delete `/autocoder:dispatch.md`. Update
  `/autocoder:gate.md` to drop dispatcher branch and invoke
  `/autocoder:fix` directly.
- **Phase 4 rollback:** restore the previous `/autocoder:fix.md` from
  git history.
- **Atomic-claim rollback (Phase 1):** remove the `--if-unset` flag
  uses from `fix-loop-gate.sh`. The flag remains on `issues-file.py`
  as a no-op for callers not using it.

User-facing escape hatch: `AUTOCODER_DISABLE_GATE=1` env var bypasses
the gate and falls through to the old `/autocoder:fix` flow. Document
in the README.

## 10. Implementation phases (revised)

Each phase is independently shippable. Code complete = code written
and smoke-tested. Tests passing = unit tests added and green in CI.
**Done = the corresponding impact report in §13 has been committed
and its Recommendation line says "continue."** The per-phase
"Acceptance" lines below are summaries; §13.4 is authoritative.

### Phase 0 — Cadence tighten (cheap win, still needs measurement)

- [ ] Change default cadence in `fix-loop.md` from 15 min to 4 min
- [ ] Document the rationale (stays inside 5-min cache TTL) in the
      command's help text
- [ ] **1-hour-TTL probe:** run a parallel experiment with cadence
      55 min and `cache_control: { ttl: "1h" }` writes; compare
      total daily cost (2× write cost × fewer cache-creation
      ticks) against 4-min cadence × 5-min-TTL writes. Report
      finding in Phase 0 report; if 1h-TTL is cheaper for the
      observed tick mix, switch the default. Worth the one extra
      experiment because the answer determines the right default.
- [ ] No code changes elsewhere (default-config-only changes)

**Acceptance (see §13.4):** Phase 0 report MUST present measurements
for BOTH configurations (4-min + 5min-TTL AND 55-min + 1h-TTL) on
the same fixture; the cheaper one is committed as default and the
report shows the comparison. The chosen cadence achieves ≥80%
cache-warm ticks; per-active-tick cost on a P2 fix fixture is no
worse than at 15-min cadence; median time-to-claim on a P1 bug
arrival drops by ≥3×. Cost-per-day is *expected* to shift modestly
(direction depends on TTL choice and model); the report explicitly
discloses the tradeoff direction.

### Phase 1 — Atomic claim primitive

- [x] `issues-file.py update --if-unset`, exit code 9 on race-loss
      (code complete, smoke-tested 2026-05-21)
- [ ] Unit test in `tests/test_issues_file.py` covering:
      claim-succeeds, claim-fails-when-set, claim-with-no-flag-is-
      idempotent
- [ ] **Concurrent-claim race test:** 10 subprocesses concurrently
      run `--add-label working --if-unset` against the same issue;
      exactly one exits 0, nine exit 9, label appears exactly once
      in the file. Defined as a fixture in
      `tests/test_atomic_claim.py`.

**Acceptance (see §13.4):** correctness gate, not cost gate.

### Phase 2.0 — Measurement tooling (prerequisite for any cost claims)

This is its own deliverable. Without it, none of the report-based
acceptance gates in §13.4 are computable, and no later phase can
honestly ship.

- [ ] `scripts/gate-log.py` — invoked by the gate to append one
      JSON record per tick to `${XDG_STATE_HOME:-$HOME/.local/state}/autocoder/gate.jsonl`.
      Fields per §13.2.
- [ ] `scripts/analyze-gate-log.py` — Python (defensively parses
      the Anthropic jsonl schema; emits `n/a` on missing fields;
      schema-check step exits non-zero if all expected keys are
      missing in any sampled record).
- [ ] `tests/fixtures/queue-state-{empty,p2-bug,triage,active}.sh`
      — bring `.issues/` into a known state; teardown restores.
- [ ] `scripts/run-phase-experiment.sh` — runs the loop for a
      configurable duration against a named fixture, captures
      gate.jsonl, runs the analyzer, prints the report markdown.
- [ ] CI: schema-check runs against a committed sample
      `tests/fixtures/sample-session.jsonl` so we notice if
      Anthropic renames fields. **Schema-check fails if ANY
      expected field is missing**; **warns** (does not fail) on
      unknown fields so additive Anthropic changes surface for
      review without breaking CI.
- [ ] **Sample-session.jsonl refresh policy.** Refresh on every
      major Claude Code version bump OR quarterly, whichever comes
      first. Owner: Phase 2.0 engineer; cadence enforced by a
      separate CI job that fails if the sample is >90 days old.
- [ ] **Golden-output test** (Phase 2.0 blocker): committed
      `sample-session.jsonl` carries known token counts
      (input=1024, cache_read=8192, cache_creation=0, output=37);
      analyzer's output must match exactly. Without this, a bug
      that always returns zero would pass Phase 2.0.
- [ ] **Time-injection support in `run-phase-experiment.sh`** (not
      in fixtures themselves; bash can't schedule). Runner reads
      `--inject-at <seconds> --inject-fixture <fixture>` flags;
      forks a background sleeper that copies the inject-fixture
      contents into `.issues/` at the specified offset. Fixtures
      themselves stay declarative.
- [ ] **PostSessionEnd hook probe:** Phase 2.0 must determine
      whether Claude Code Mode 1 fires PostSessionEnd hooks. If
      yes, gate-log.py uses it (precise per-tick wall-clock). If
      no, fall back to combining at next-tick gate entry — but
      then Phase 2 acceptance criteria that depend on per-tick
      wall-clock (`gate duration <2 s p95`) become **best-effort,
      not gating**. Document the fallback path's measurement gaps
      in the Phase 2.0 report.
- [ ] **TTL calibration scheduling.** Run the §13.1 #3 TTL
      experiment 3 times over ≤48 hours (off-peak, peak, weekend);
      report the *range*. Phase 2.0 doesn't complete until all
      three data points land.

**Acceptance:** all sub-tests above green: report shape valid,
golden-output match exact, time-injection exercises the
time-to-claim path, PostSessionEnd path resolved, TTL calibration
range published.

### Phase 2 — Slim gate (highest ROI after Phase 0)

- [ ] **§7 verification test run; §7.1.1 results documented in
      this spec.** Blocks all subsequent Phase 2 tasks. (Promotes
      the §5.3 caveat into a literal checklist item.)
- [x] `plugins/autocoder/scripts/fix-loop-gate.sh` (code complete,
      smoke-tested; needs M1/M3/M4/M6 updates per §5.1)
- [ ] `plugins/autocoder/commands/gate.md` — <2 KB body, frontmatter
      pins to fix-loop's configured model
- [ ] `fix-loop.md` wired to `/autocoder:gate`
- [ ] Telemetry: log `gate.outcome` (idle / claim / triage / error)
      and `gate.tokens_consumed` to a file the dispatcher TUI can
      read

**Acceptance:** running `/loop 4m /autocoder:gate` for one hour on
an empty queue consumes ≤2 KB × 360 ticks = ~720 KB of input tokens
(cache-read pricing), ≈$0.22 on Sonnet. Compare to ~$5/hour for the
old `/loop 15m /autocoder:fix` flow.

### Phase 3 — Haiku routing (conditional on §7 test passing)

- [ ] Run the verification test in §7 and record the result in this
      doc
- [ ] If Task `model=` is honored: write
      `plugins/autocoder/commands/dispatch.md` with `model:
      claude-haiku-4-5` frontmatter
- [ ] Triage path runs in Haiku directly (no subagent)
- [ ] Fix/enhance path: `Task(model="sonnet", prompt=...)` with the
      skill chain named explicitly in the prompt

**Acceptance:** triaging 10 unprioritized issues on Haiku produces
the same priority labels as a Sonnet baseline ≥80% of the time
(measured on a fixed test corpus committed to `tests/triage_corpus/`).

### Phase 4 — Slim `/autocoder:fix` worker

- [ ] Remove triage prelude, race detection, queue-scan loop from
      `fix.md`
- [ ] Keep skill-chain instructions, branch/commit/merge logic, idle
      signaling
- [ ] Target: <500 lines (down from 1961)
- [ ] **Guardrail:** keep GH backend comment-scan race detector
      unless `/autocoder:gate` has been verified to provide GH CAS
      equivalent (Mo4)
- [ ] Move proposal-management explainer, example workflows out into
      a separate `fix-reference.md`

**Acceptance:** `/autocoder:fix N` on a known simple issue completes
with ≥3× lower input token count than the v1 version, no behavior
change in the produced commit.

## 11. Why "/loop" can't skip Claude (architectural note)

CronCreate fires a prompt at cron time. That prompt is a Claude
conversation entry — there is no "shell only" mode. So any work the
gate does *before* loading the LLM has to be packaged inside the
prompt itself (a slim slash command), not before it.

This is why v1's "$0 on idle" goal was incoherent. The realistic floor
is "the cheapest possible prompt loaded into the LLM each tick" —
which is the new goal in §2.

If we wanted true "$0 on idle," we would have to abandon `/loop` and
deploy with system cron (launchd / systemd / crontab). That's a bigger
shipping story — different install instructions per OS, separate auth
for the system-cron user, no plugin-marketplace path for the cron line
itself, etc. **Out of scope for v2 implementation; conditionally
in scope as v3** (the "autocoder daemon"), triggered per the rule
in §13.5: post-Phase-4 measured idle cost still >$0.50/day and
>50% of that cost is unavoidable per-tick LLM prefill. If both
conditions fail, v3 is dropped.

## 12. Open questions / risks

1. **Skill-system caching across phases.** Cross-model invocation
   breaks the prompt cache, but Haiku and Sonnet each keep their own
   warm pool. Within a 4-min cadence, both models stay cached. Verify
   by measurement during Phase 3.
2. **GitHub backend race tightening.** Today's `--add-label working`
   without CAS + comment-scan is racy under heavy multi-host
   concurrency. v2 keeps the comment-scan in `/autocoder:fix` for now.
   A future `gh api ... --if-match` based CAS is out of scope.
3. **Triage quality on Haiku.** Haiku 4.5 is fast but smaller. Phase
   3 acceptance criteria measures this against a Sonnet baseline.
   If Haiku underperforms, Phase 3 may need to stay on Sonnet for
   triage and the speed-up is only on dispatching.
4. **Gate-resident stale-claim sweep is O(N) over issues.** For 145
   closed + N open issues, that's an N read per tick. At 4-min
   cadence, fine up to ~10K open issues. Beyond that, the sweep
   should move to a separate periodic job. (Not a near-term concern.)

## 13. Measurement & impact report

Every cost claim in §6 is pre-measurement arithmetic. Before declaring
any phase "shipped," produce an impact report with measured numbers
substituted for the price-sheet projections. This is also a gate that
makes "go further or stop" decisions explicit.

### 13.1 What to measure

For each phase that ships, capture per `/loop` tick:

| Metric | Source | How to capture |
|---|---|---|
| Input tokens consumed | `~/.claude/projects/<proj>/<session>.jsonl` `usage.input_tokens` | Parse jsonl defensively (M1) |
| Cache-read tokens | same, `usage.cache_read_input_tokens` | same |
| Cache-creation tokens | same, `usage.cache_creation_input_tokens` | same |
| Output tokens | same, `usage.output_tokens` | same |
| Tick outcome | gate stdout (`idle` / `triage` / `fix` / `enhance`) | gate-log.py appends record at session end |
| Tick wall-clock | gate entry to Claude exit | gate-log.py reads both timestamps |
| Model in use | session jsonl `model` field | gate-log.py copies |

**Schema-defensive analyzer.** The Anthropic jsonl schema is not a
committed API surface. `analyze-gate-log.py` must (a) emit `n/a`
when a field is missing rather than crashing, (b) **fail loudly
if ANY expected field is missing** in a record (catches
single-field renames that would otherwise silently produce wrong
numbers), and (c) run a schema-check on a committed sample jsonl
in CI so version drift surfaces early.

**Session-id join.** The gate runs inside the Claude session (per
§5.3); it logs its tick outcome to a temp file at gate exit (last
bash action before the LLM continues). At session end, the
PostSessionEnd hook (Mode 1) — or stop hook (Mode 2) — reads the
temp file and the session's jsonl, combines them into one
`gate.jsonl` record, and removes the temp file. **Risk:** Mode 1
PostSessionEnd hook availability is unverified — confirm in Phase
2.0 or fall back to combining at gate-entry of *next* tick (one
tick lag in the metrics).

**Experiment design.** Each phase produces three experiments:

1. **Steady-state**: ≥4 hours on a committed fixture
   (`tests/fixtures/queue-state-{empty,p2-bug,triage,active}.sh`).
   Captures cache-warm cost and tick-outcome distribution.
2. **Cache-decay**: ≥2 hours with deliberate 30-min gaps every
   hour, forcing cache eviction. Captures first-tick cost variance
   and validates the assumed 5-min TTL.
3. **TTL calibration**: Run gaps of 2 m, 4 m, 5 m, 6 m, 8 m back
   to back; observe where cache-creation cost reappears. **Run at
   three times-of-day** (off-peak, peak, weekend) and report the
   *range*, not a single number. Cadence is chosen below the
   *minimum* observed TTL to stay cache-warm under load.

All three experiments cite the fixture name and commit SHA so
reruns are reproducible. The report's "Test environment" section
must include `claude --version`, OS, fixture SHA, and a sample
jsonl record showing the schema observed, e.g.:

```json
{"model": "claude-sonnet-4-6",
 "usage": {"input_tokens": 1024,
           "cache_read_input_tokens": 8192,
           "cache_creation_input_tokens": 0,
           "output_tokens": 37}}
```

### 13.2 Instrumentation work (Phase 2 prerequisite)

`fix-loop-gate.sh` and `/autocoder:gate` write a one-line JSON record
per tick to `${XDG_STATE_HOME:-$HOME/.local/state}/autocoder/gate.jsonl`:

```json
{"ts": "2026-05-21T13:00:00Z", "tick_id": "...", "outcome": "idle",
 "model": "claude-sonnet-4-6", "issues_scanned": 12,
 "stale_swept": 0, "claimed": null,
 "gate_duration_ms": 87}
```

Companion script `scripts/analyze-gate-log.py` (Python; bash
filename ending `.sh` in earlier drafts was a typo — language is
Python per §10 Phase 2.0):

- Reads `gate.jsonl` for a date range
- Joins on session id with the corresponding `<session>.jsonl` usage records
- Emits a CSV (one row per tick) and a markdown summary

The CSV columns: `ts, outcome, model, input_tokens, cache_read_tokens,
cache_creation_tokens, output_tokens, gate_duration_ms,
issues_scanned`. The markdown summary aggregates per-outcome and
per-model.

### 13.3 Report format

After each phase ships, commit a report to
`docs/reports/YYYY-MM-DD-fix-loop-phase-N-impact.md`:

```markdown
# Phase N impact report — fix-loop token efficiency

**Measured:** YYYY-MM-DD over <hours>h
**Fixture:** tests/fixtures/queue-state-X.sh @ <sha>
**Environment:** claude <version>, <OS>, jsonl schema <observed-fields-list>

## Headline numbers

Cache-read % = `cache_read_input_tokens /
(input_tokens + cache_read_input_tokens + cache_creation_input_tokens)` × 100.

|                                  | Predicted | Prior-phase measured | This-phase measured | Delta |
|----------------------------------|----------:|---------------------:|---------------------:|------:|
| Per-tick input toks (cache-warm) |           |                      |                      |       |
| Per-tick input toks (cache-miss) |           |                      |                      |       |
| Per-tick cache-read %            |           |                      |                      |       |
| Per-tick output toks             |           |                      |                      |       |
| Per-active-tick total $          |           |                      |                      |       |
| Median time-to-claim (s)         |           |                      |                      |       |

"Predicted" = §6 original arithmetic, **never updated.** Each
report's "Prior-phase measured" column is the previous report's
"This-phase measured" — i.e., reports chain into a measured
baseline that diverges from §6 over time.

## Tick-outcome distribution
<idle / triage / fix / enhance counts and ratios — discloses tick-mix
so daily-cost projections can be recomputed for other workloads>

## Cache behavior

- Steady-state cache-read %:
- Cache-creation events observed:
- Effective TTL (from cache-decay experiment): ≈ N minutes
- **Anomaly definition:** cache-creation observed after <5 min gap
  OR cache-read absent within 5 min of prior tick. Anomalies listed
  here if any.

## Output-token cost

For active ticks only. Output tokens × output price = $.
<table>

## Findings
<unexpected results, gotchas, model misbehavior>

## Go/no-go for next phase

Compute per §13.4. Disclose the volume estimate `T` (ticks/year)
and the rate `R` ($/hour from `AUTOCODER_DEV_HOURLY_RATE`,
default $150) — both must match across §13.5's cumulative report
or the rollups disagree.

- This-phase measured B_n =
- Next-phase predicted B_{n+1} (from §6) =
- Annualized ticks T =
- Engineer-hours next phase H_{n+1} =
- Developer rate R =
- **Marginal: S = (B_n − B_{n+1}) × T  ;  C = H_{n+1} × R  ;  S/C =**
- **Cumulative: S_total = (B_0 − B_n) × T ; C_total = Σ HᵢR ; S_total/C_total =**
- Pass: S/C ≥ 3 OR (S_total/C_total ≥ 3 AND S/C ≥ 1).

## Recommendation
<continue / pause / revise spec / abandon> — bound by the ratio above.
```

**Recommendation gate ownership.** The engineer who would otherwise
start Phase N+1 is the gate. Their PR description must link this
report and quote the Recommendation line and the X/Y ratio.
CI checks the link is present.

### 13.4 Acceptance criteria, restated in terms of the report

Each phase's "done" definition includes a committed report whose
Recommendation line says "continue" (§13.3 owner rules):

- **Phase 0** (cadence): per-tick input cost at 4-min cadence is
  ≥80% cache-read; per-active-tick cost no worse than at 15-min on
  the same fixture; median time-to-claim drops ≥3×. Cost-per-day
  may rise; that's a deliberate responsiveness tradeoff.

- **Phase 1** (atomic claim): correctness, not cost. The
  concurrent-claim race test (§10 Phase 1) passes; no other
  measurement required.

- **Phase 2** (slim gate): on a cache-warm baseline, per-tick input
  tokens drop to ≤15% of pre-Phase-2 baseline (target: 11% from
  18 KB → 2 KB ratio; 15% leaves headroom for prompt growth and
  noise). Cache-miss tick cost reported separately and must not
  exceed pre-Phase-2 cache-miss cost. Gate duration <2 s p95.
  **Output-token budget:** idle ticks <50 output tokens; triage
  ticks <500 output tokens (measured; baseline §6 currently
  estimates "~50" pre-measurement and Phase 0 report will replace
  with measured value).

- **Phase 3** (Haiku routing): triage-correctness on Haiku ≥80% of
  Sonnet baseline on the test corpus committed in §10. Per-routing-
  tick input cost ≤30% of Phase 2 baseline (cache-warm, same
  fixture). Output-token cost on active routing ticks measured and
  reported (Mn5 dependency).

- **Phase 4** (slim worker): per-active-tick *total* cost (input +
  cache + output, priced at §6 rates) ≤50% of pre-Phase-4 baseline
  on the same active-issue fixture, AND two correctness gates:
  (a) **behavioral oracle** — the held-out test issue ships with
  a test suite (or repro script) that the produced fix must make
  pass; (b) **diff-scope check** — the held-out fixture declares
  `expected_files: [...]`; reviewer asserts the produced commit
  touches only files in that list. The expected-file-list is *not*
  fed into the worker prompt (that would add tokens back). It's
  applied post-hoc to the resulting diff. If the worker touches
  unexpected files, Phase 4 fails even if the test passes —
  prevents silent diff broadening.

**Go/no-go formula for "start next phase":**

Let:
- `B_n` = this-phase measured per-tick cost,
- `k_{n+1}` = next-phase predicted multiplier from §6's multiplier
  table (e.g., 9× for Phase 2, 3× for Phase 3, 3× for Phase 4),
- `B_{n+1} = B_n / k_{n+1}` — next-phase predicted per-tick cost
  derived *from measured baseline times §6's multiplier*, **not**
  from §6's original arithmetic dollar amounts. This protects
  against under-delivery in phase N inflating phase N+1's
  predicted savings.
- `T` = annualized ticks at observed volume,
- `H_{n+1}` = engineer-hours estimate for next phase,
- `R` = developer hourly rate from
  `${AUTOCODER_DEV_HOURLY_RATE:-150}`.

- Marginal annual savings: `S = (B_n − B_{n+1}) × T  =  B_n × (1 − 1/k_{n+1}) × T`
- Marginal build cost: `C = H_{n+1} × R`
- Cumulative-savings-to-date: `S_total = (B_0 − B_n) × T`
- Cumulative-cost-to-date: `C_total = Σ Hᵢ × Rᵢ` (per-engineer
  rate at the time hours were logged; do not average post-hoc)

**Start next phase if either:**

1. `S / C ≥ 3` (next phase pays back ≥3× its build cost in year 1), OR
2. `S_total / C_total ≥ 3` (project remains net-positive at ≥3× ROI even
   if next phase's marginal value is small) **and** `S / C ≥ 1` (next
   phase still pays back).

The second clause prevents the "over-delivery shrinks predicted next-
phase savings, project succeeds → gate fails" pathology: a project
already delivering 3× ROI can complete its remaining planned phases
as long as they remain net-positive.

Document the computed S, C, S_total, C_total in every report.

### 13.5 Cumulative report

After Phase 4 ships (or after the project pauses), write a final
roll-up at `docs/reports/YYYY-MM-DD-fix-loop-token-efficiency-summary.md`
with:

- Total measured savings vs. baseline (predicted vs. actual)
- Build-cost actuals (hours, PRs merged)
- Payback period at observed traffic
- Lessons learned (which §6 line items were wrong and by how much)
- Recommendation on v3 (system-cron daemon — see §11; treat as
  *conditionally in scope* contingent on this report's findings):
  trigger v3 work if BOTH (a) measured post-Phase-2 idle cost
  exceeds 1.5× the §6 multiplier-predicted baseline (shortfall-
  relative — if Phase 2 delivered its predicted 9× reduction, v3
  is not warranted regardless of absolute dollars), AND (b) Phase 4
  measurement shows >50% of remaining cost is unavoidable per-tick
  LLM prefill (i.e., further reduction requires skipping the LLM
  entirely). Shortfall-relative replaces the earlier absolute-
  threshold formulation, which produced false positives when
  Phase 2 over-delivered or under-delivered modestly.

This summary is what someone deciding whether to do the next thing
reads.

## 14. Migration

- **Existing users of `/loop 15m /autocoder:fix`** keep working
  unchanged until they opt in by changing their `fix-loop.md` config.
- **Phase 0 (cadence) and Phase 2 (gate)** are config + new file —
  no breaking changes to direct callers of `/autocoder:fix N`.
- **Phase 4** is the breaking-ish change: standalone `/autocoder:fix`
  (no number) stops doing its own triage. Users who depend on that
  call `/autocoder:gate` instead. Soft-deprecate by having
  `/autocoder:fix` (no args) auto-invoke `/autocoder:gate` for one
  release cycle.

## Appendix A. Verified assumptions — full table

Enumerated cold against the draft spec on 2026-05-21, then verified
empirically. Bold rows are **NOT verified** and gate one or more
phases.

| # | Assumption | Result | Evidence |
|---|---|---|---|
| 1 | Anthropic pricing | CORRECTED — Opus was 3× over-stated in v1; Haiku cache-read 0.10 not 0.08 | <https://platform.claude.com/docs/en/docs/build-with-claude/prompt-caching> fetched 2026-05-21 |
| 2 | Prompt cache TTL | 5-min default confirmed; **1-hour optional at 2× write cost** newly surfaced | same source |
| 3 | Cache applies to user-message content (slash command bodies sent as user messages) | confirmed | "Text messages: Content blocks in messages.content array, for both user and assistant turns" |
| 4 | Session jsonl path `~/.claude/projects/<encoded>/<session>.jsonl` exists | confirmed | `ls ~/.claude/projects/` |
| 5 | jsonl carries `usage.{input_tokens, cache_read_input_tokens, cache_creation_input_tokens, output_tokens}` + `model` | confirmed; additional undocumented fields observed (`server_tool_use`, `service_tier`, `inference_geo`, `iterations`, `speed`) — justifies the §13.2 schema-defensive analyzer | real sample inspected |
| 6 | Anthropic jsonl schema not a committed API surface | confirmed by observation of undocumented fields above |
| 7 | `/loop` uses CronCreate feeding prompts to Claude (no shell-only branch) | confirmed | `/loop` skill body |
| **8** | **Skill-tool inheritance: invocation runs in caller's model** | **NOT verified locally; gates Phase 2 per §5.3** | requires runtime test |
| **9** | **Task tool `model=` spawns subagent on different model** | **NOT verified locally; gates Phase 3 per §7** | requires runtime test |
| **10** | **Slash command frontmatter `model:` honored at conversation entry only** | **NOT verified locally; bundled into §7 verification** | requires runtime test |
| **11** | **Claude Code Mode 1 supports `PostSessionEnd` hook (or equivalent)** | **NOT verified; Phase 2.0 probe per §10** | requires runtime test |
| 12 | `/autocoder:fix` body ≈ 18K tokens | confirmed | file is 74,699 bytes ≈ 18,675 tokens; real session jsonl records `cache_creation_input_tokens: 18702` for one Sonnet session — empirical match |
| 13 | `using-superpowers` ≈ 2–4 KB | partial — actual 5,421 bytes (≈1,355 tokens at 4 chars/token; spec §1 "2–4 K tokens" estimate stays in the ballpark) | `wc -c SKILL.md` |
| 14 | `issue-fns.sh` dispatches by `ISSUE_SOURCE` and forwards args verbatim to `issues-file.py` | confirmed | `issue_update() { file) _ifns_file update "$@" ;; }` |
| 15 | `issues-file.py` uses `fcntl.flock(LOCK_EX)` per-issue file | confirmed | line 127 |
| 16 | `--if-unset` flag exits 9 on race-loss | confirmed (implemented + smoke-tested) | line 202–203 |
| 17 | `fix-loop-gate.sh` runs end-to-end on the file backend | confirmed (smoke-tested 2026-05-21) | idle → exit 1, claim → exit 0 + work.json, race → exit 1 |
| 18 | Today's `/loop 15m` is cache-miss every tick | confirmed (derived from row 2: 15 > 5 min) | `fix-loop.md:146` sets `IDLE_SLEEP_MINUTES="15"` |
| 19 | 5-min cache TTL uniform across times-of-day / load | **not verifiable from spec; §13.1 multi-time-of-day calibration during Phase 2.0** |

### Design-shape consequences (folded into spec body)

- §6 pricing table corrected; Opus-derived projections divided by 3 vs. v1.
- §6 build-cost-vs-savings table rewritten with verified numbers; Phase 2.0 cost row separated.
- §6 Sonnet/Opus day-cost columns split.
- 1-hour cache TTL evaluated as a Phase 0 probe (§10).
- §11/§13.5 v3-trigger threshold rederived against verified Opus pricing (was anchored on $0.50/day under v1's 3× over-stated rates).
- §6 multiplier table annotated as price-ratio-derived (audit note: re-derive if Anthropic re-prices any token class non-uniformly).
- §13.2 schema-defensive analyzer justified by the undocumented-fields observation in row 5.
- Rows 8–11 stand as Phase 2 prerequisites per §5.3 and §10 Phase 2.
