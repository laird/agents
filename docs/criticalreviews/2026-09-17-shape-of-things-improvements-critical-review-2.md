# Critical Design Review: 2026-09-17-shape-of-things-improvements (Round 2)

**Spec:** `/home/Laird.Popkin/src/agents/docs/specs/2026-09-17-shape-of-things-improvements.md`
**Verified Assumptions section:** present

## 0. Coverage enumeration

Re-derived over the full spec (not the round-1 diff). Rows whose text and
evidence are unchanged since round 1 cite that round's disposition; all
round-1-fixed and new text got fresh rows.

### Sections

| Row | Disposition |
|---|---|
| Status header | ok — accurately states R1 applied and both decisions resolved |
| Problem / Goals / Non-goals | ok — Goals W6 bullet updated to the new-command decision, consistent with W6 body; remainder unchanged from R1 (ok) |
| W1 contract changes / claimability / consumers / testing | ok — unchanged since R1 (all rows ok there); `--stuck`, dangling-edge, cycle-containment story intact |
| W1 storage table: file row | ok — unchanged from R1 |
| W1 storage table: github row (REWRITTEN) | ok — native endpoints carried over from R1 verification; new GHES fallback → rules sweep row below |
| W1 storage table: jira row (REWRITTEN per R1 §2.1) | ok — now requires `issuelinks` in the get field list; the one remaining unknown (embedded stub carries `fields.status`) is explicitly flagged for implementation-time confirmation in the spec text |
| W1 storage table: ado row (REWRITTEN per R1 §2.2) | ok — now specifies `$expand=relations`, the `/relations/-` add shape, remove-by-index read-modify-write, and the curl-stub test obligation; rel-direction suffix explicitly flagged unverified |
| W1 design note (native vs convention) | ok — decision and rationale stated; no mechanism claims beyond those verified (add/remove-label in all four backends — R1 §0; Jira no-spaces constraint — `issues-jira.sh:73`) |
| W2 routing table (REWRITTEN per R1 §2.3) | ok — `needs-design` row removed; remaining rows use ordinary labels present at claim time |
| W2 brainstorm-issue wiring (NEW) | → §2.1 — the "via the same helper" option cannot work in-session |
| W2 integration point (REWRITTEN per R1 §2.4) | worker-loop injection ok (verified R1: `claude-worker-loop.sh:98-114`); tier-logging sentence → §2.2 — gate-log record is written before the tier exists |
| W2 risk note / modelRouting override | ok — unchanged from R1 |
| W2 testing | ok — unchanged from R1 |
| W3 shape / cost bound | ok — unchanged from R1 |
| W3 integration (REWRITTEN per R1 §2.5) | ok — anchor is now merge-mode-agnostic ("before either `merge-to-integration.sh` (merge mode) or PR creation (pr mode)"); the pr-mode skip is closed |
| W4 (all subsections) | ok — unchanged from R1 (all rows ok there) |
| W5 (REWRITTEN per R1 §2.7) | ok — the trigger metric is now stated as nonexistent, with the measurement prerequisite (persistent jsonl + analyzer extension) named in the issue body; no capability is claimed of current code |
| W6 current state (REWRITTEN per R1 §2.6) | ok — matches verified layout (autocoder: `/retro` + manual; modernize: `/retro-apply`); placement decision recorded with date and owner |
| W6 placement (NEW, D1) | ok — no name collision (`plugins/autocoder/commands/` has no `retro-apply.md`, R1 dir listing); namespaced invocation is evidenced practice (`run_claude "/autocoder:fix $ISSUE_NUM"`, `claude-worker-loop.sh:114`); mirror obligation stated |
| W6 design + retroApplyUpstream (NEW, D2) | ok — see rules sweep rows below |
| W6 retro handoff (NEW) | ok — see rules sweep row below |
| Open decisions | ok — D1/D2 marked resolved with owner/date; no open items remain |
| Verified assumptions (NEW) | → §1 |
| Cross-cutting: mirrors / versions / sequencing | ok — unchanged from R1; new artifacts (retro-apply command, its mirror) fall under the stated mirror-from-birth rule |
| Success criteria | W2 criterion → §2.2 (says "gate log records a tier per issue", which inherits the temporal impossibility); others ok — unchanged from R1 |

### Rules and operands

| Row | Disposition |
|---|---|
| GHES label fallback `blocked-by-<m>` — over-inclusion (spurious edge parsed) | ok — prefix-parse over the issue's own labels; only labels matching `blocked-by-<digits>` count; no other label in the repo's documented vocabulary (`working`, `needs-*`, `swarm`, priority labels) shares the prefix |
| GHES label fallback — under-inclusion (edge silently lost) | ok — `gh label create … \|\| true` swallows both already-exists and permission failure, but a permission failure then surfaces as `--add-label` failing → `block` exits 3 (visible backend error, not a silent miss) |
| GHES fallback `deps`/`claim` reading edges | ok — labels round-trip through `get` in the gh backend (list/view JSON schema, `issues-gh.sh:22`); blocker state resolved by per-blocker `get`, same as the native path |
| Claimability predicate (all backends) | ok — unchanged from R1 (both directions checked there) |
| W2 routing table first-match-wins — row reachability | ok — post-R1-fix, every remaining row uses labels that survive into the claimable pool |
| Helper tier resolution precedence | ok — unchanged from R1 (`model-config.md:34`) |
| retro `Status: proposed \| accepted \| applied` line — producer/consumer agreement | ok — same spec section defines both the producer (`/retro` closing step) and consumer (`/retro-apply` acts on `accepted`, skips others); modernize's `/retro-apply` keeps its own `Proposed/Approved` vocabulary in a different plugin — no shared artifact: each plugin's retro writes and reads its own IMPROVEMENTS.md convention. Worth one guard sentence in the protocol doc if both plugins are installed in one repo, but the commands are namespaced and operator-invoked — no automatic path crosses them |
| retroApplyUpstream ask-and-record — first-run vs subsequent | ok — unset key → ask + write `.autocoder.json` (non-secret, per-repo config, matching existing keys' pattern); set key → no prompt. Agents-repo CWD short-circuit stated |
| retroApplyUpstream `issue` failure path | ok — filing failure falls back to `improvements` for that run "and says so"; no silent loss |
| retroApplyUpstream `skip` | ok — logged no-op, stated |

### Data-flow arrows

| Row | Disposition |
|---|---|
| gate → handoff → loop → helper → `--model` on fix launch | ok — unchanged from R1 |
| helper → backend `get` → labels | ok — unchanged from R1 |
| loop's chosen tier → durable record for `/retro` correlation | → §2.2 — the named destination (gate-log record) is written before the tier is chosen |
| brainstorm-issue → tier | → §2.1 |
| `/retro` → IMPROVEMENTS.md Status lines → `/retro-apply` | ok — producer and consumer defined together; artifact is a file in the target repo, no persistence-shape split |
| `/retro-apply` plugin-route → agents-repo CWD → direct edit | ok — writable source tree, existing behavior |
| `/retro-apply` plugin-route → consumer repo → `retroApplyUpstream` behaviors | ok — all three sinks defined with failure fallback |
| W5 merge-timing jsonl → analyzer | ok — now stated as work to build, not capability that exists |
| All other arrows (W1 create→block, deps→show-issue/--stuck, W4 role-runner, state files) | ok — unchanged from R1 |

## 1. Verified-assumptions cross-check

All ten listed assumptions reconfirmed on fresh read — each was verified
this cycle with primary evidence (vendor API docs fetched in R1; file:line
reads of `issues-jira.sh`, `issues-ado.sh`, `issues-gh.sh`,
`claude-worker-loop.sh`, `start-issue-work.sh`, `analyze-gate-log.py`;
directory listings; commit c4b6153) and none of the cited evidence has
changed since.

**Span check** — design dependencies not covered by a listed assumption:

- *A slash command inherits its session's model and cannot change it
  mid-session.* The spec relies on this twice (scoping `/fix-loop` out of
  W2; and — inconsistently — NOT applying it to `/brainstorm-issue`).
  The dependency is real and verifiable (`claude -p --model` is a launch
  flag, `claude-worker-loop.sh:75-79`; no per-command model mechanism
  exists). Its inconsistent application is §2.1.
- *`gh label create` requires only the write access workers already have.*
  Fallback-path-only, and a failure is visible (block exits 3, rules sweep
  above) — degraded loudly, not wrongly. No spec change forced; noted for
  the implementation plan.
- No other uncovered dependency found.

## 2. Literal-wrongness findings

### 2.1 `/brainstorm-issue` cannot "resolve its tier via the same helper"

**Description:** W2's brainstorm wiring offers two mechanisms: "the
`/brainstorm-issue` protocol is updated to resolve its tier via the same
helper (which returns deep … with a `--context design` flag), or
equivalently pins `$MANAGER_MODEL` in its protocol text." The first
mechanism is unimplementable: `/brainstorm-issue` is a slash command
executing inside an already-running session, and a session's model is
fixed at launch (`--model` is a process launch flag —
`claude-worker-loop.sh:75-79`; no mid-session per-command model switch
exists). This is the same constraint the spec itself cites one paragraph
later to scope interactive `/fix-loop` out of W2 — applied to one command
but not the other. An implementer taking the first (primary-positioned)
option hits a dead end.

**Fix:** Delete the helper option. State instead: design work runs in the
manager session, which runs `$MANAGER_MODEL` (deep) by default
(`model-config.md:10`); the `/brainstorm-issue` protocol doc asserts this
expectation, and the crew/fleet economics hold because the deep tier is
already where the manager lives. The helper remains worker-loop-only.

### 2.2 The fix-side tier cannot be "its own field in the gate-log record"

**Description:** W2 (and the W2 success criterion, "gate log records a
tier per issue") route the chosen tier into the gate-log record via "an
additive schema change to `gate-log.py`." Temporally impossible:
`gate-log.py` is "Invoked by /autocoder:gate at gate exit" (its own
docstring) — the record is written when the gate process ends, but the
tier is chosen by the worker loop *after* that, between reading the
handoff file and launching the fix (`claude-worker-loop.sh:105-114`). The
gate's record cannot carry a value that doesn't exist yet.

**Fix:** Log the tier at the moment it is known, through the post-fix
hook the loop already calls: `post-issue-metrics.sh "$ISSUE_NUM" --session
"$LAST_TRANSCRIPT"` runs immediately after each fix
(`claude-worker-loop.sh:118-122`) — add the tier (and issue number, which
it already has) to that record, or have the loop append a separate
fix-tick line to the same jsonl `gate-log.py` writes (new `--outcome`
value would violate `VALID_OUTCOMES`; a distinct record type or the
metrics path is cleaner — UNVERIFIED which store `/retro` reads today;
pick whichever the retro protocol already ingests during implementation
planning). Update the W2 success criterion to "a tier is durably recorded
per fix run and joinable to the issue number."

## 3. Forced decisions

No forced decisions found.

## 4. Previously addressed

- R1 §2.1 (Jira `issuelinks` not fetched) — resolved: storage table now
  requires the field-list change and flags the one residual unknown.
- R1 §2.2 (ADO relations expand + patch shape) — resolved: `$expand`,
  `/relations/-` add, remove-by-index, and the test obligation are all in
  the table.
- R1 §2.3 (dead `needs-design` row) — resolved: row removed with the
  reachability rationale inline (its replacement wiring spawned §2.1 of
  this round).
- R1 §2.4 (`start-issue-work.sh` as routing point) — resolved: integration
  scoped to `claude-worker-loop.sh`, `/fix-loop` explicitly out of scope
  (its tier-logging sentence spawned §2.2 of this round).
- R1 §2.5 (pr-mode review skip) — resolved: merge-mode-agnostic anchor.
- R1 §2.6 (retro-apply premise) — resolved: current-state section rewritten
  to the verified layout.
- R1 §2.7 (phantom merge metric) — resolved: measurement prerequisite named
  in the W5 issue body.
- R1 §3.1 (W6 placement) — resolved by operator: new autocoder command,
  mirrored from birth.
- R1 §3.2 (plugin-channel semantics) — resolved by operator: ask-and-record
  (`retroApplyUpstream`), with failure fallback.
- R1 header warning (no Verified Assumptions section) — resolved: section
  added with ten evidence-backed items.

## 5. Recommendation

⚠️ **Approve with literal-wrongness fixes** — two §2 items, both confined
to W2's round-1 replacement text and both with mechanical fixes; no forced
decisions remain. Address §2.1 and §2.2, then the spec is ready for
implementation planning.
