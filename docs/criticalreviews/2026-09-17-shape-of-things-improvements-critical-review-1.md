# Critical Design Review: 2026-09-17-shape-of-things-improvements (Round 1)

**Spec:** `/home/Laird.Popkin/src/agents/docs/specs/2026-09-17-shape-of-things-improvements.md`
**Verified Assumptions section:** MISSING

> ⚠️ This spec lacks a `Verified assumptions` section. Reviewer cannot distinguish verified facts from unverified assumptions; treat findings accordingly.

## 0. Coverage enumeration

### Sections

| Row | Disposition |
|---|---|
| Problem / Goals / Non-goals | ok — claims about current state spot-checked below in the rules sweep; the six gap statements match the code (flat list: no deps verbs in any backend; tiers config-only: `claude-worker-loop.sh:36` fixed `WORKER_MODEL`; no agentic-review command in `plugins/autocoder/commands/`; sentinel monolithic: `idle-sentinel.sh` self-contained; merge serial: `merge-to-integration.sh` per-issue; retro-apply — **mis-stated**, → §2.6) |
| W1 contract changes (verbs, exit codes) | ok — exit-code discipline matches both reference backends (`issues-file.py:32-36`: 0/1/3; `issues-gh.sh:17`: same); verb list is additive, no collision with existing 9 |
| W1 claimability rule | → §0 rules sweep rows below; design internally consistent |
| W1 per-backend storage table | jira row → §2.1; ado row → §2.2; github row ok (REST `blocked_by` endpoints exist: `GET/POST /repos/{o}/{r}/issues/{n}/dependencies/blocked_by`, `DELETE .../blocked_by/{issue_id}` — docs.github.com/en/rest/issues/issue-dependencies, fetched this round); file row ok (frontmatter list values already round-trip: `issues-file.py:169` serializes `isinstance(val, list)`, labels already parse as a list) |
| W1 consumers | "no protocol change needed" negative claim → rules sweep row below (holds); `/brainstorm-issue`, `/show-issue`, `/list-issues` all exist in `plugins/autocoder/commands/` (dir listing) |
| W1 testing | ok — named suites match existing conventions (`test_issues_jira.sh` + `_integration.sh` pairs exist; `fake_jira.py`/`fake_ado.py` exist per CLAUDE.md and tests/fixtures) |
| W2 design (helper + routing table) | routing table → §2.3 (unreachable row) and §2.4 (integration point); tier precedence claim ok (`model-config.md:34` documents env → `.autocoder.json` → defaults) |
| W2 risk note / gate-log correlation | ok — gate log already carries a `model` field per record (`gate-log.py` record shape), so "logged to the gate log" requires only the fix-side tier to be recorded; extending the record is additive. Note the gate log records the *gate's* model; W2 must log the *fix* tier explicitly — folded into §2.4's fix |
| W2 testing | ok — stub-the-backend pattern matches existing `test_issues_*.sh` approach |
| W3 shape (personas, verify, rounds, disposition) | ok — persona count matches the precedent cited (7-persona idle-sentinel review, commit b63495e); `docs/criticalreviews/` naming matches existing convention |
| W3 integration | → §2.5 (merge-mode anchor) |
| W3 cost bound | ok — bound formula stated with caps; no mechanism claims to verify |
| W4 extraction list | ok — every extracted mechanism exists in `idle-sentinel.sh` (header documents `--ensure` cron/systemd/loop logic, tick lock `.autocoder/sentinel.tick.lock`, state file `.autocoder/sentinel-state.json`, error-tolerance counter); "59-assertion suite" matches commit c4b6153 ("59 behavioral + 15 doc-contract assertions"); byte-equivalence hedge is explicit |
| W4 role definition | ok — `.autocoder/` directory convention matches sentinel's existing usage; spawn mechanism exists (`claude -p --model` one-shot pattern, `claude-worker-loop.sh:75-79`; mux path via `mux-send-lib.sh`) |
| W4 reference roles | ok — intake's always-escalate guardrail is structural (frame applies the label), matching the `requiredLabel` precedent; qa-nightly consumes existing `regression-test.sh` |
| W4 testing | ok — mirrors sentinel's own test surface |
| W5 batch-land issue | trigger-metric claim → §2.7 |
| W6 retro-apply routing | premise → §2.6; plugin-channel writability → §3.2; placement → §3.1 |
| Cross-cutting: mirror parity | ok — matches CLAUDE.md repo law; spec commits new artifacts to mirroring from birth |
| Cross-cutting: version discipline | ok — matches CLAUDE.md's four-manifest rule and names the enforcing test |
| Cross-cutting: sequencing | ok — W1-first is forced by the dependency structure the spec itself creates; no ordering contradiction found |
| Success criteria | ok — each criterion is testable against its workstream; W1's "all four backends" criterion is umbrella-level and consistent with remote backends as fast-follows (criterion gates the workstream, not the first commit) |

### Rules and operands

| Row | Disposition |
|---|---|
| Claimability predicate "every blocker closed" — over-inclusion (blocked issue gets claimed) | ok — claim-time check window inherits the tolerance the contract already documents for github (`issues-gh.sh:25-27`: claim is best-effort, concurrent claims may both succeed); spec explicitly accepts the reopen race. No new over-inclusion class introduced |
| Claimability predicate — under-inclusion (claimable issue wrongly excluded) | ok — the one candidate class is dangling edges, and the spec rules them satisfied precisely to avoid permanent exclusion; `deps` marks `"state": "missing"` and `--stuck` surfaces it |
| Dangling-edge-satisfied rule — over-inclusion (typo'd blocker number silently satisfies) | ok — surfaced via `deps` missing-state + `--stuck`; a typo'd edge fails visible, not silent |
| Shallow-only cycle detection | ok — spec states the containment story explicitly (cycle members stay unclaimable; `--stuck` is the human surface); `any-claimable` exit 1 correctly keeps the sentinel from waking a manager for unclaimable work |
| "No protocol change needed" for claim-exit-1 (load-bearing negative claim) | ok — verified: the pick-another-on-exit-1 discipline already exists for `requiredLabel` (`skills/autocoder/SKILL.md`: "A claim on an unapproved issue is refused with exit 1; that is a decision, not a failure — pick another issue and do not retry it") and `fix.md:620-621` treats claim failure as non-fatal; deps-blocked claims reuse the identical exit path |
| W2 routing table, first-match-wins — row reachability per producer of "claimed" | `needs-design` row → §2.3 (unreachable: blocking labels are excluded from the claimable pool before the helper ever runs); `P0/P1`, `approved-design`, `mechanical`, default rows ok (ordinary labels, present at claim time) |
| W2 `modelRouting` override map | ok — same `.autocoder.json` extension pattern as existing keys; precedence stated |
| Intake role "never creates directly-claimable work" | ok — escalation label applied by the runner frame, not the mandate prompt; with `requiredLabel` configured the created issue is doubly unclaimable |
| qa-nightly "one issue per distinct failure signature" | ok — dedup key is a mandate-level instruction, calibratable; no mechanic depends on it |

### Data-flow arrows

| Row | Disposition |
|---|---|
| gate → handoff file → worker loop → fix launch | ok — verified `claude-worker-loop.sh:98-114`: gate writes issue# to `AUTOCODER_NEXT_FIX_FILE`, loop reads `ISSUE_NUM`, launches `run_claude "fix-$ISSUE_NUM"`; a per-issue `--model` can be injected at exactly this point (crosses a file boundary; payload is a bare issue number, all the helper needs) |
| model-for-issue.sh → backend `get` → labels | ok — every backend's `get` returns labels (file: frontmatter; gh: JSON schema `issues-gh.sh:22`; jira: `fields=...labels...` line 339; ado: System.Tags line 282) |
| brainstorm-issue → `create` children → `block` parent | ok — `create` returns the new issue identity in all four backends (file prints the record; gh returns the issue URL; jira/ado return key/id), which is the only parameter `block` needs |
| `deps` output → `/show-issue`, `--stuck` | ok — consumer fields ({number, state}) are defined by the same spec section that produces them |
| jira `deps` ← get payload (persistence boundary: API response shape) | → §2.1 — the field the consumer needs (`issuelinks`) is not in the requested field list |
| ado `deps` ← get payload (persistence boundary) | → §2.2 — relations require `$expand=Relations`; the current call (`issues-ado.sh:240`) omits it and the API default is `none` (WorkItemExpand: "none — Default behavior", MS REST 7.1 docs, fetched this round) |
| role-runner → predicate (exit code) → spawn (mandate file, tier, maxRuntime) | ok — every parameter the spawn needs is in the role JSON; predicate contract is exit-code-only, same as the 9-verb discipline |
| role state file write → next-tick read | ok — versioned JSON, single writer per role (per-role tick lock), same pattern sentinel already ships |
| W5 trigger ← gate-log analysis | → §2.7 — the metric named does not exist in the artifact analyzed |
| retro classification → target-repo AGENTS.md / `.claude/skills/` | ok — target repo is the CWD, writable |
| retro classification → "plugin" channel | → §3.2 — in a consumer repo the plugin tree is an installed cache, not a writable source tree |

## 1. Verified-assumptions cross-check

*Omitted — spec has no Verified Assumptions section (warning above).*

## 2. Literal-wrongness findings

### 2.1 Jira `deps` reads a field the `get` call never requests

**Description:** W1's Jira row claims "`deps` reads the links array already returned by the get payload." The get request is `fields=summary,description,labels,status,comment` (`plugins/autocoder/scripts/issues-jira.sh:339`) — `issuelinks` is not requested, so the payload contains no links array. As written, `deps` on Jira returns nothing, and the claimability rule (which must resolve blocker states) has no data.

**Fix:** Add `issuelinks` to the get field list, and have `deps` map inward "is blocked by" links (type `Blocks`) to `blockedBy`. Note the linked-issue stubs embedded in `issuelinks` include `fields.status`, so blocker state resolution needs no extra round-trips on Jira (UNVERIFIED: confirm the embedded stub carries `status` on the target instance during implementation — it does on Jira Cloud REST v2 defaults).

### 2.2 ADO relations are neither returned by the current `get` nor "the same shape as existing update calls"

**Description:** W1's ADO row makes two claims that fail against the API. (a) The current get (`issues-ado.sh:240`) has no `$expand` parameter, and `WorkItemExpand` defaults to `none`, which omits `relations` entirely (MS REST 7.1 docs, fetched this round) — so `deps` reading the existing payload gets nothing. (b) "same shape as existing update calls" — existing patches are field ops (`{"op":"add","path":"/fields/System.Tags",...}`, `issues-ado.sh:303`); relation ops are structurally different: add is `{"op":"add","path":"/relations/-","value":{"rel":"System.LinkTypes.Dependency-...","url":"<full work-item URL>"}}` requiring the target's URL not its id, and remove addresses a relation by **index** (`{"op":"remove","path":"/relations/<i>"}`), which forces a read-then-patch sequence `unblock` must implement (UNVERIFIED: exact rel-direction suffix `-Forward`/`-Reverse` mapping to blocked-by — confirm against a test org during implementation).

**Fix:** Rewrite the ADO row: `deps`/`claim` use `GET ...?$expand=relations`; `block` posts a `/relations/-` add with the constructed work-item URL; `unblock` is a read-modify-write (fetch relations, locate the Dependency relation whose URL tail matches the blocker id, remove by index). The hermetic `test_issues_ado.sh` curl-stub must assert this two-step shape.

### 2.3 The `needs-design → deep` routing row can never fire where the helper runs

**Description:** W2 calls `model-for-issue.sh` "after a successful claim." But `needs-design` is a blocking label: the claimable pool excludes it (`issues-gh.sh:46` builds the query by excluding each blocking label; SKILL.md lists `needs-design` among the labels that make an issue unworkable), so no issue carrying `needs-design` is ever claimed by a worker, and the row is dead code. The spec's stated goal — "design work (needs-design → brainstorm) uses $MANAGER_MODEL" — is not achieved by the mechanism given; design work happens in `/brainstorm-issue` on the manager side, which the spec never wires to the helper.

**Fix:** Remove the `needs-design` row from the worker-side table. Achieve "design runs deep" where design actually runs: state in W2 that `/brainstorm-issue` (and any manager-side design dispatch) resolves its tier via the same helper or is pinned to `$MANAGER_MODEL` in its protocol doc.

### 2.4 `start-issue-work.sh` is named as a routing point but launches nothing

**Description:** W2: "`claude-worker-loop.sh` / `start-issue-work.sh` call the helper after a successful claim and pass `--model` accordingly." `start-issue-work.sh` claims the issue, switches branches, and posts the start comment — it never launches an agent process (verified full read of its flow), so there is nothing to pass `--model` to. An implementer following the spec hits a dead end in one of the two named files.

**Fix:** Scope the integration to `claude-worker-loop.sh`: between reading `ISSUE_NUM` from the handoff file and `run_claude "fix-$ISSUE_NUM"` (`claude-worker-loop.sh:105-114`), call the helper and override the `--model` argument for that fix invocation; log the chosen tier alongside the issue number (the gate log's `model` field records the gate's model, not the fix's — the fix-side tier needs its own record or an extended gate-log field). Add one sentence scoping W2 out of interactive `/fix-loop` sessions, where the model is fixed at session start and cannot be switched per issue.

### 2.5 W3's merge anchor skips the review entirely in `pr` merge mode

**Description:** W3 anchors the optional review "before `merge-to-integration.sh`." Merge Mode is configurable (`merge` or `pr` — CLAUDE.md; this repo itself runs `pr`), and in `pr` mode the shipping tail creates a pull request instead of invoking `merge-to-integration.sh`. Anchored literally, an enabled `agenticReview` never runs on `pr`-mode repos — the asked-for behavior (review before landing) silently fails on exactly the configuration this repository uses.

**Fix:** Anchor to the Merge Mode step generically: "run the protocol at the start of the shipping tail, before either `merge-to-integration.sh` (merge mode) or PR creation (pr mode)."

### 2.6 W6's premise names a command that does not exist in autocoder

**Description:** W6 opens: "`/retro-apply` currently applies IMPROVEMENTS.md recommendations by editing `plugins/autocoder/commands/`." False: `plugins/autocoder/commands/` contains `retro.md` but no `retro-apply.md` (directory listing, this round); `/retro-apply` is a **modernize**-plugin command (`plugins/modernize/commands/retro-apply.md`) targeting that plugin's agent protocols, and autocoder's own documented flow is manual application ("Apply approved recommendations to `plugins/autocoder/commands/` manually" — CLAUDE.md, Retrospective section). The workstream as written modifies a file that isn't there.

**Fix:** Rewrite the premise to the actual state (autocoder: `/retro` produces IMPROVEMENTS.md, application is manual; modernize: `/retro-apply` exists with different scope). The routing design itself survives intact, but where it lands is a real choice the spec must make → §3.1.

### 2.7 W5's trigger criterion cites a measurement that doesn't exist

**Description:** W5: "sustained merge-gate queue wait exceeding the mean test-suite runtime … which `analyze-gate-log.py` can already measure." False: the analyzer's entire column set is gate-tick data — `ts, outcome, model, input_tokens, cache_read_tokens, cache_creation_tokens, output_tokens, gate_duration_ms, issues_scanned` (`analyze-gate-log.py:24-25`), aggregated per outcome/model. No merge timing exists anywhere durable: `merge-launch.sh` writes per-issue logs to `/tmp/autocoder-merge-<issue>.log` (`merge-launch.sh:38,82`), which are ephemeral and unanalyzed. The filed issue's build-trigger is unmeasurable as specified.

**Fix:** In the W5 issue body, make the measurement a prerequisite: have `merge-launch.sh`/`merge-to-integration.sh` append start/end/queue-entry timestamps to a persistent jsonl (same XDG pattern as `gate-log.py`), and extend `analyze-gate-log.py` (or a sibling) to report merge-gate wait. Until that lands, the trigger criterion cannot be evaluated.

## 3. Forced decisions

### 3.1 Where does W6's apply-with-routing live?

**The choice:** W6 modifies "/retro-apply," but no such command exists in the plugin W6 targets (§2.6).
**Why it's forced:** the spec cannot be implemented until the artifact it edits is chosen; the three candidates have different mirror-parity and scope obligations (a new autocoder command must be mirrored to `.agent/workflows/` from birth; extending modernize's command couples autocoder's retro loop to the modernize plugin; extending `retro.md` changes an existing command's contract).
**Options:** (a) new `plugins/autocoder/commands/retro-apply.md` implementing the routing design; (b) extend `plugins/modernize/commands/retro-apply.md` to serve both plugins; (c) fold an "apply" phase with the routing rubric into autocoder's existing `retro.md`.

### 3.2 What does "plugin"-routed output mean in a consumer repo?

**The choice:** W6's `plugin` channel edits the shared plugin source — which only exists as a writable tree when the CWD **is** this agents repo. In a consumer repo the plugin is an installed copy (plugin installation copies trees — CLAUDE.md, Skill Packaging); edits there are overwritten by the next update and never reach upstream.
**Why it's forced:** the default config is `"both"`, so the classifier will route plugin-bound recommendations in every repo; the design must say what happens in the (majority) case where the plugin tree isn't the source of truth.
**Options:** (a) plugin-routed recommendations become upstream issues (via `record-issue` against this repo's tracker); (b) they accumulate in the target repo's IMPROVEMENTS.md flagged "upstream, apply manually"; (c) `plugin` routing is only active when the CWD is the agents repo itself, and is a no-op (with a logged notice) elsewhere.

## 5. Recommendation

🛑 **Surface forced decisions to user** — §3.1 (where W6 lands) and §3.2 (plugin-channel semantics in consumer repos) need a call before implementation planning; the seven §2 findings are all fixable by spec edits once those decisions are made.
