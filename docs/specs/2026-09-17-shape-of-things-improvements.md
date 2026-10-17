# Shape-of-Things Improvements — six workstreams from the Yegge essay analysis

**Status:** CDR rounds 1 and 2 applied (R1: 7 findings; R2: 2 findings,
both in W2's replacement text — reviews at
`docs/criticalreviews/2026-09-17-shape-of-things-improvements-critical-review-{1,2}.md`);
both forced decisions resolved (operator, 2026-09-17 — see "Open
decisions"). Ready for implementation planning.
**Owner:** autocoder plugin (W6 also touches retro/retro-apply)
**Source:** analysis of [The Shape of Things to Come, Part 1](https://yegge.ai/essays/the-shape-of-things-to-come/)
(Yegge, 2026-09) mapped against autocoder 4.28.0. Operator approved all six
directions on 2026-09-17; this spec turns them into buildable designs.

## Problem

The essay describes a convergent architecture for autonomous development —
a dependency-aware work graph as the coordination substrate, an expensive
"crew" tier that designs and reviews while a cheap "fleet" tier implements,
standing role agents for operational domains, and multi-round agentic review
in front of a shrinking human gate. Autocoder already has the skeleton of
each (pluggable issue backends, model tiers, idle-sentinel, review-blocked),
but in every case stops one step short:

1. Issues are a **flat list** — no dependency edges, so agents cannot pick
   work in topological order and a manager cannot decompose an epic into
   claimable children that unblock automatically.
2. Model tiers exist as **reference config only** — the fix loop launches
   every worker at `$WORKER_MODEL` regardless of whether the issue needs
   design (deep) or is executing an approved plan (fast/balanced).
3. Agentic review is **ad hoc** — the 7-persona review that hardened
   idle-sentinel was hand-orchestrated; there is no command, so it doesn't
   happen unless someone remembers to do it.
4. idle-sentinel is **one hardcoded role** — its scheduler/lock/state
   plumbing is exactly what an intake role or nightly-QA role needs, but
   none of it is reusable.
5. The merge pipeline is **strictly serial** — fine at today's throughput,
   mathematically doomed if throughput grows the way the essay predicts.
6. retro-apply **only edits the shared plugin** — the "chemical bonding"
   counter-argument to the essay's anti-framework stance is true in design
   but not in code.

## Goals

- W1: dependency edges as first-class verbs in the issue-source contract,
  honored by claimability, across all four backends.
- W2: per-issue model-tier routing at worker launch, driven by issue labels.
- W3: `/agentic-review` — a repeatable multi-persona, multi-round review
  command that narrows what reaches the human `review-blocked` gate.
- W4: extract sentinel plumbing into a role-agent framework; ship two
  reference roles (intake, nightly QA).
- W5: **design-only** — file a `needs-design` issue for batch-land merge
  mode; no implementation this cycle.
- W6: a new autocoder `/retro-apply` command with plugin-vs-project output
  routing, and `/retro` suggesting it when the user agrees with the
  recommendations.

## Non-goals

- Adopting Beads/`bd` as a required dependency. W1 captures the graph
  benefit inside the existing 9-verb contract. (An `issues-beads.sh` fifth
  backend is future work, unblocked by W1's verb additions.)
- Removing the human review gate. W3 narrows what reaches it; approval
  labels and `review-blocked` semantics are unchanged.
- Building batch-land (W5). Current throughput doesn't justify it; the
  deliverable is an issue, not code.
- Cross-backend edge sync or migration tooling. Edges live in whichever
  backend is configured; switching backends does not migrate edges (same
  as every other issue field today).

---

## W1 — Dependency edges in the issue-source contract

### Contract changes (9 verbs → 12)

Three new verbs, added to `issues-file.py`, `issues-gh.sh`, `issues-jira.sh`,
`issues-ado.sh` with the same exit-code discipline as the existing verbs
(0 success, 1 clean negative / not found, 3 backend error):

```
deps <number>                # print JSON: {"blockedBy": [...], "blocks": [...]}
                             # each entry: {number, state}
block <number> --on <m>      # add edge: <number> is blocked by <m>
unblock <number> --on <m>    # remove that edge; exit 1 if absent
```

`block` is idempotent (adding an existing edge exits 0). Self-edges
(`block N --on N`) exit 1. Cycle detection is **shallow only**: `block`
rejects a direct two-node cycle (m already blocked by n); longer cycles are
not detected at write time — instead, `any-claimable`'s semantics make a
cycle self-evident (everything in it stays unclaimable) and `/list-issues`
gains a `--stuck` flag that reports open issues whose blockers are all
open-and-blocked, which is where a cycle surfaces for a human.

### Claimability rule

An issue is claimable only if every issue in its `blockedBy` set is
**closed**. This extends the existing rule (open bucket + requiredLabel):

- `claim <n>`: after the existing checks, resolve `blockedBy`; if any
  blocker is not closed, exit 1 (clean negative — same as a lost race).
- `any-claimable`: an issue with open blockers does not count.
- A dangling edge (blocker was deleted / not found) is treated as
  **satisfied**, and `deps` marks it `"state": "missing"` so `--stuck` can
  surface it. Rationale: a deleted blocker must not strand its dependents
  forever, and deletion is already an explicit human act.

Blockers are checked at claim time only. An issue claimed while its blocker
was closed does not get un-claimed if the blocker reopens; that race is
accepted (same tolerance the contract already has for label edits during
claim).

### Per-backend storage

| Backend | blockedBy storage | notes |
|---|---|---|
| file | `blockedBy: [m, ...]` list in frontmatter of `<n>.md` | edge is stored on the blocked issue only; `blocks` is computed by scanning (list is already a full-directory scan) |
| github | native issue dependencies via `gh api`: `GET/POST /repos/{o}/{r}/issues/{n}/dependencies/blocked_by`, `DELETE .../blocked_by/{issue_id}` (verified against docs.github.com, CDR R1 §0) | if the API rejects (older GHES), fall back to the **label convention** `blocked-by-<m>` — add/remove-label already works in every backend, whereas body-trailer editing has no verb and is a last-writer-wins race (CDR R1 fix); `block` creates the label first (`gh label create ... \|\| true`) |
| jira | issue links, type "Blocks" (`is blocked by` inward) | **`get` must add `issuelinks` to its field list** (`issues-jira.sh` currently requests only `summary,description,labels,status,comment` — CDR R1 §2.1); `deps` maps inward Blocks links to `blockedBy`. The linked-issue stubs embed `fields.status`, so blocker-state resolution needs no extra round-trips (confirm on the target instance during implementation) |
| ado | `System.LinkTypes.Dependency` work-item relation | `deps`/`claim` fetch with **`$expand=relations`** — the API default (`$expand=None`) omits relations entirely (CDR R1 §2.2). Writes are relation ops, NOT field patches: `block` = `{"op":"add","path":"/relations/-","value":{"rel":"System.LinkTypes.Dependency-<dir>","url":"<work-item URL>"}}` (confirm `-Forward`/`-Reverse` direction for blocked-by against a test org); `unblock` = read-modify-write — fetch relations, find the Dependency relation whose URL tail is the blocker id, `{"op":"remove","path":"/relations/<index>"}`. The hermetic `test_issues_ado.sh` curl-stub must assert this two-step shape |

**Design note — native links vs. convention-everywhere:** a uniform
convention across all backends was considered. Labels (`blocked-by-<m>`)
are the only viable one — add/remove-label is implemented and tested in
all four backends today, and Jira's no-spaces label constraint permits the
hyphenated form — but convention edges are invisible to the trackers' own
dependency UIs, which is much of the point of choosing the gh/jira/ado
backends. Body trailers were rejected outright: no backend has a body-edit
verb, and concurrent body writes clobber. Decision: native links per
backend, label convention only as the GHES fallback above. No dual-write
mirroring (consistency burden with no consumer).

The file backend is the reference implementation and lands first, with the
contract text in `docs/issue-backends.md` updated in the same commit.

### Consumers

- `/brainstorm-issue` (manager decomposition): when a design produces
  subtasks, create children and `block <parent> --on <child>` each one. The
  parent becomes claimable exactly when the children close.
- `/show-issue` prints the deps block; `/list-issues` gains `--stuck`.
- `fix.md` protocol: on claim failure, the worker treats exit 1 as
  "pick another issue" — **no protocol change needed**; blocked issues are
  simply never claimable, which is the point of doing this at the contract
  layer.

### Testing

- `tests/test_issues_file_deps.sh`: edge CRUD, idempotency, self-edge
  rejection, shallow cycle rejection, claim-blocked-by-open, claim-after-
  close, dangling-edge-is-satisfied, `--stuck`.
- Extend the four existing backend tests (stubbed `curl` request-shape
  asserts for jira/ado; `fake_jira.py`/`fake_ado.py` lifecycle coverage
  gets a blocked→unblocked→claim sequence).

---

## W2 — Crew/fleet model routing at worker launch

### Design

New helper `plugins/autocoder/scripts/model-for-issue.sh <number>`:
prints one of `$MANAGER_MODEL` / `$WORKER_MODEL` / `$FAST_MODEL` (resolved
through the existing env → `.autocoder.json` → default precedence) by
inspecting the issue's labels via the configured backend:

| Condition (first match wins) | Tier |
|---|---|
| label `P0` or `P1` | deep (`$MANAGER_MODEL`) |
| label `approved-design` or `has-plan` (executing an approved plan) | balanced — **not** fast; see risk note |
| label `mechanical` (docs, renames, version bumps) | fast (`$FAST_MODEL`) |
| default | balanced (`$WORKER_MODEL`) |

There is deliberately **no `needs-design` row**: `needs-design` is a
blocking label, excluded from the claimable pool before the helper ever
runs, so such a row is unreachable in the worker path (CDR R1 §2.3). The
"design work runs deep" half of the crew/fleet split needs no routing
mechanism at all (CDR R2 §2.1): design happens in the manager session via
`/brainstorm-issue`, and the manager session already runs `$MANAGER_MODEL`
(deep) by default (`model-config.md`). A slash command cannot switch its
running session's model — the same constraint that scopes `/fix-loop` out
below — so the `/brainstorm-issue` protocol doc simply *asserts* the
deep-tier expectation, and the helper remains worker-loop-only.

**Integration point (CDR R1 §2.4):** `claude-worker-loop.sh` only. The
gate writes the claimed issue number to the handoff file; between reading
`ISSUE_NUM` and launching `run_claude "fix-$ISSUE_NUM"`, the loop calls
`model-for-issue.sh "$ISSUE_NUM"` and overrides `--model` for that fix
invocation. (`start-issue-work.sh` claims and branches but launches no
agent process — it is not an integration point.) The chosen tier is
recorded per fix run **at the moment it is known** — not in the gate-log
record, which `gate-log.py` writes at gate exit, *before* the loop picks
the tier (CDR R2 §2.2). Instead the worker loop passes the tier to the
post-fix metrics hook it already calls (`post-issue-metrics.sh
"$ISSUE_NUM" --session "$LAST_TRANSCRIPT"`), or appends a distinct
fix-record line to the same jsonl; implementation planning picks
whichever store the `/retro` protocol already ingests. **Scope:** W2 applies to
process-per-issue worker loops. Interactive `/fix-loop` sessions keep the
model fixed at session start; per-issue rerouting is not possible there
and is explicitly out of scope. The existing auto-escalation rule in
`model-config.md` (2 failed attempts → deep) is unchanged and layered on
top.

**Risk note (why approved-plan work is balanced, not fast):** the essay's
economics say implementation can run cheap, but autocoder's quality gates
(100% regression pass, merge gate) are downstream of implementation quality.
Start conservative; `.autocoder.json` gains an optional `modelRouting`
override map (`{"approved-design": "fast"}`) so an operator who trusts
their gates can opt down per label. Routing decisions are logged to the
gate log so `/retro` can later correlate tier with rework rate — that data,
not the essay, decides whether the default moves.

### Testing

`tests/test_model_for_issue.sh` — stub the backend `get`, assert tier per
label combination, precedence order, and the `modelRouting` override.

---

## W3 — `/agentic-review` command

### Shape

New command `plugins/autocoder/commands/agentic-review.md` (protocol
document, like the rest). Inputs: a branch/PR/diff ref (defaults to the
current feature branch vs. integration). The protocol:

1. **Persona round.** Launch N reviewer subagents in parallel, each with a
   distinct lens. Default persona set (7, matching the idle-sentinel review
   that motivated this): correctness, security, concurrency/races,
   simplification, test-coverage, docs-contract parity (this repo's mirror
   rules), and operator-experience. Personas are listed in the command doc
   so `/retro-apply` can tune them.
2. **Adversarial verify.** Every finding goes to a verifier subagent
   prompted to refute it. Findings refuted are dropped; survivors are
   ranked.
3. **Rounds until dry.** Repeat with the surviving-findings context, max 3
   rounds, stop early when a round produces zero new confirmed findings.
4. **Disposition.** Confirmed findings are either fixed in place (when the
   protocol invoker is a worker mid-`/fix`) or written to
   `docs/criticalreviews/<date>-<topic>-agentic-review-<n>.md` and, for
   findings the agent may not decide alone, escalated with the existing
   blocking labels (`needs-approval` etc.). The human `review-blocked`
   queue now receives *verified* findings instead of raw diffs.

### Integration

- `fix.md` gets an **optional** step at the start of the shipping tail: if
  `.autocoder.json` has `"agenticReview": {"enabled": true, "rounds": N,
  "personas": [...]}`, run the protocol **before the configured Merge Mode
  step, whichever it is** — before `merge-to-integration.sh` in `merge`
  mode, and before PR creation in `pr` mode (CDR R1 §2.5: anchoring to
  `merge-to-integration.sh` alone silently skipped the review on `pr`-mode
  repos, including this one). When enabled, the review always runs before
  work ships, regardless of merge mode. Disabled by default — it
  multiplies per-issue token cost and the merge gate is currently the
  binding quality control.
- Standalone use: `/agentic-review <branch>` for release candidates or
  human-authored PRs.

### Cost bound

Worst case tokens ≈ personas × rounds × verify. The command doc must state
the bound and the config caps (`rounds` ≤ 3, `personas` ≤ 9) — this is the
one workstream that *spends* Yegge's "infinite tokens" assumption, which
this repo does not share.

---

## W4 — Role-agent framework (generalizing idle-sentinel)

### What gets extracted

idle-sentinel stays **exactly as it is** — its ownership invariants
(manifest as source of truth, sentinel-only manifest clearing) are load-
bearing and role-specific, and it just survived a 2-round CDR; it is not
rewritten onto the new framework this cycle. Instead the *generic* plumbing
is extracted into `plugins/autocoder/scripts/role-lib.sh`:

- scheduler install/check (`--ensure` logic: crontab preferred, systemd
  user timer, `--loop` fallback; refuse to double-install)
- non-blocking per-role tick lock (`.autocoder/role-<name>.tick.lock`)
- state file read/write (`.autocoder/role-<name>-state.json`, versioned)
- log rotation and the error-tolerance counter

Sentinel adopts `role-lib.sh` only if the extraction is byte-equivalent in
behavior (verified by its existing 59-assertion suite); otherwise the lib
starts life as a copy and convergence is a follow-up issue.

### Role definition

`.autocoder/roles/<name>.json` in the target repo:

```json
{
  "name": "intake",
  "interval": "15m",
  "predicate": "plugins/autocoder/scripts/roles/intake-predicate.sh",
  "mandate": "plugins/autocoder/scripts/roles/intake-mandate.md",
  "model": "fast",
  "maxRuntimeMin": 20,
  "escalation": "needs-approval"
}
```

`role-runner.sh <name> --once|--loop|--ensure|--dry-run` (mirroring
sentinel's modes): each tick runs the **predicate script at zero token
cost**; only when it exits 0 does the runner spawn a one-shot agent with
the mandate file as its prompt, at the configured tier, killed after
`maxRuntimeMin`. The zero-spend-until-predicate-fires discipline is
inherited from sentinel and is the framework's core invariant.

### Reference roles (shipped, disabled by default)

1. **intake** — predicate: new items in a watched source (a second GitHub
   repo's issues, or a directory of dropped request files) newer than
   `state.last_seen`. Mandate: for each item run `record-issue`, apply
   triage labels, always apply the `escalation` label (`needs-approval`) —
   intake **never** creates directly-claimable work. This is the Wish
   Factory with the guardrail built into the frame, not the prompt.
2. **qa-nightly** — predicate: time-of-day window and no run recorded
   today. Mandate: run `regression-test.sh`; on failure, file one issue per
   distinct failure signature with the failure log attached, labeled per
   config.

### Testing

`tests/test_role_runner.sh`: predicate-false → zero spawns and untouched
state; predicate-true → single spawn (stubbed), lock contention → SKIP
counted; `--ensure` idempotency; `--dry-run` no side effects; runtime kill.

---

## W5 — Batch-land merge mode (design issue only)

Deliverable: one issue via `record-issue`, labeled `needs-design`, body
containing the sketch: opt-in `.autocoder.json` `"mergeMode": "batch"` —
green feature branches accumulate in a land queue; every T minutes (or M
branches) an octopus/serial batch merge is built in a throwaway worktree
(the isolation pattern `merge-to-integration.sh` already uses per #1821),
the full suite runs **once** over the combined tree, and on failure a
swarm-diagnose issue is filed identifying the batch members instead of
bisecting serially. Trigger criterion for actually building it: sustained
merge-gate queue wait exceeding the mean test-suite runtime (i.e., the
serial gate has become the bottleneck). **That metric does not exist yet**
(CDR R1 §2.7): `analyze-gate-log.py` covers gate-tick data only, and merge
timing goes to ephemeral `/tmp/autocoder-merge-<issue>.log`. The issue
body therefore names a measurement prerequisite: `merge-launch.sh` /
`merge-to-integration.sh` append queue-entry/start/end timestamps to a
persistent jsonl (same XDG-state pattern as `gate-log.py`), and
`analyze-gate-log.py` (or a sibling) reports merge-gate wait. Until that
lands and the criterion trips, no batch-land code.

---

## W6 — retro-apply project-local output channel

### Current state (corrected per CDR R1 §2.6)

Autocoder has **no** `/retro-apply` command: its `/retro` produces
IMPROVEMENTS.md and the documented flow applies recommendations to
`plugins/autocoder/commands/` **manually** (CLAUDE.md, Retrospective
section). The `/retro-apply` that exists belongs to the **modernize**
plugin (`plugins/modernize/commands/retro-apply.md`) and targets that
plugin's agent protocols. W6 therefore *introduces* an apply-with-routing
capability for the autocoder loop.

**Placement (decided — operator, 2026-09-17, resolving CDR R1 §3.1):** a
new command, `plugins/autocoder/commands/retro-apply.md`, mirrored to
`.agent/workflows/retro-apply.md` from birth per repo law. Modernize's
`/retro-apply` is untouched (different plugin, different scope); the
namespaced invocations (`/autocoder:retro-apply` vs
`/modernize:retro-apply`) keep them from colliding.

### Design

For each accepted IMPROVEMENTS.md recommendation, a routing step
classifies **where the lesson belongs**:

- **plugin** — the workflow itself was wrong; fix the protocol for all
  repos (current behavior).
- **project** — the lesson is repo-specific (this codebase's build quirks,
  domain rules, review hot-spots). Write it to the *target repo*: append a
  rule to its `AGENTS.md` (primary, per the skill's own config-precedence
  rule) / `CLAUDE.md` (legacy), or create `.claude/skills/<name>/SKILL.md`
  for procedural knowledge big enough to be a skill.

Config: `.autocoder.json` `"retroApplyTarget": "plugin" | "project" |
"both"` — default `"both"`, meaning the classifier chooses per
recommendation. **Plugin-routed output in consumer repos (decided —
operator, 2026-09-17, resolving CDR R1 §3.2):** in a consumer repo the
plugin tree is an installed copy, not a writable source tree, so
plugin-routed edits cannot land there. The first time `/retro-apply`
encounters a plugin-routed recommendation in a repo with no recorded
preference, it **asks the user** which behavior to use and **records the
answer** in `.autocoder.json` as `"retroApplyUpstream"`:

- `"issue"` — file an upstream issue against this framework's tracker
  (requires reachable credentials for it; if the filing fails, fall back
  to `"improvements"` for that run and say so);
- `"improvements"` — leave the recommendation in the target repo's
  IMPROVEMENTS.md flagged `Status: accepted (upstream, apply manually)`;
- `"skip"` — plugin routing is a logged no-op in this repo.

Subsequent runs use the recorded value without asking. When the CWD *is*
the agents repo itself, the question is moot — the plugin tree is the
writable source of truth and edits land directly (the existing behavior
of routing target `plugin`). The protocol doc gains the classification
rubric and two worked examples.

### `/retro` hands off to `/retro-apply`

`retro.md` (and its `.agent/workflows/` mirror) gains a closing step: after
presenting the 3–5 recommendations, ask the user which they agree with; if
any are accepted, suggest running `/autocoder:retro-apply` to apply them
(and record acceptance in IMPROVEMENTS.md — each recommendation gets a
`Status: proposed | accepted | applied` line so retro-apply knows what to
act on and what to skip). CLAUDE.md's "apply recommendations manually"
guidance is updated to name the command as the preferred path.

This is the concrete answer to the essay's anti-framework critique: the
shared plugin stays generic, and the bonding to each application happens
in that application's repo, written by the retro loop itself.

---

## Open decisions

Forced decisions from CDR round 1 (§3.1, §3.2).

- **D1 — where W6 lives: RESOLVED** (operator, 2026-09-17): new
  `plugins/autocoder/commands/retro-apply.md`, mirrored from birth; plus
  `/retro` suggests `/retro-apply` when recommendations are accepted. See
  W6.
- **D2 — "plugin"-routed output in consumer repos: RESOLVED** (operator,
  2026-09-17): all three behaviors are plausible, so none is hardcoded —
  `/retro-apply` asks the user on first encounter and records the choice
  in `.autocoder.json` (`retroApplyUpstream: issue | improvements | skip`).
  See W6.

## Verified assumptions

Facts verified during CDR round 1 (evidence in the review's §0); treat as
ground truth in later rounds:

- GitHub's REST API has issue-dependency endpoints:
  `GET/POST /repos/{o}/{r}/issues/{n}/dependencies/blocked_by` and
  `DELETE .../blocked_by/{issue_id}` (docs.github.com/en/rest/issues/issue-dependencies).
- ADO `GET workitem` omits `relations` unless `$expand=relations`
  (WorkItemExpand default `none`; MS REST 7.1 docs). Current
  `issues-ado.sh` get passes no `$expand`.
- Jira get currently requests `fields=summary,description,labels,status,comment`
  (`issues-jira.sh:339`) — no `issuelinks`.
- `claude-worker-loop.sh` launches a fresh `claude -p --model $WORKER_MODEL`
  process per issue; the gate writes the claimed issue number to a handoff
  file the loop reads before launching the fix (lines 75–114).
- `start-issue-work.sh` claims, branches, and comments; it launches no
  agent process.
- Blocking labels (`needs-design` etc.) are excluded from every backend's
  claimable pool (e.g. `issues-gh.sh:46`); claim-exit-1 is already
  "pick another, don't retry" by protocol (SKILL.md; `fix.md:620`).
- `analyze-gate-log.py` analyzes gate-tick records only (columns at
  lines 24–25); merge output goes to ephemeral `/tmp/autocoder-merge-*.log`.
- `/retro-apply` exists only in the modernize plugin; autocoder's flow is
  `/retro` + manual application (CLAUDE.md).
- All four backends implement add/remove label in `update` today; Jira
  labels cannot contain spaces (documented in `issues-jira.sh:73`), so the
  fallback label convention uses the hyphenated `blocked-by-<m>` form.
- idle-sentinel's test suite is 59 behavioral + 15 doc-contract assertions
  (commit c4b6153); its `--ensure`/lock/state plumbing is documented in
  `idle-sentinel.sh`'s header.

## Cross-cutting requirements

**Mirror parity (repo law, CLAUDE.md).** Every command/protocol change
lands in both trees: `plugins/autocoder/commands/*.md` ↔
`.agent/workflows/*.md`; scripts with `.agent/scripts/` twins likewise.
New skills references (model routing table) update the root `skills/` copy
and its three platform mirrors, hand-adapting Codex/Droid per the packaging
rules. W3's new command and W4's runner get mirrored from birth.

**Version discipline.** Each shipped workstream bumps all four manifest
locations together; `tests/test_manifest_versions.sh` runs after every
bump.

**Sequencing.**

| Order | Workstream | Why first/later |
|---|---|---|
| 1 | W1 (file backend + contract doc) | everything graph-shaped depends on it; W1 remote backends follow as fast-follows |
| 2 | W2 | small, independent, immediate cost payoff |
| 3 | W4 | wanted before W3 so qa-nightly exists to exercise review output |
| 4 | W3 | most expensive to run; benefits from W4 roles and W2 tiers |
| 5 | W6 | independent, any time; scheduled last only for focus |
| — | W5 | issue filed during W1's cycle; no build |

Each workstream is its own feature branch, its own CDR-checked
implementation plan, and its own version bump — this spec is the umbrella
design, not a single change.

## Success criteria

- W1: a parent issue decomposed into 3 children is unclaimable until all
  children close, on all four backends' test suites.
- W2: a tier is durably recorded per fix run, joinable to the issue
  number; a `mechanical`-labeled issue runs on the fast tier end-to-end.
- W3: running `/agentic-review` on a seeded-bug branch produces confirmed
  findings and a criticalreviews report; a clean branch produces a
  zero-findings report in ≤2 rounds.
- W4: intake role at `--dry-run` and predicate-false ticks spends zero
  tokens (no agent process spawned, asserted by the stub); a dropped
  request file becomes a `needs-approval` issue.
- W6: a retro on a target repo produces at least one project-routed edit
  and the plugin tree is untouched by it.
