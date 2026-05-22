# Critical Design Review: 2026-05-22-issue-storage-and-backend-abstraction-design (Round 3)

**Spec:** `/Users/Laird.Popkin/src/agents/docs/superpowers/specs/2026-05-22-issue-storage-and-backend-abstraction-design.md`
**Verified Assumptions section:** MISSING

> ⚠️ This spec lacks a `Verified assumptions` section. Reviewer cannot distinguish verified facts from unverified assumptions; treat findings accordingly.

## 2. Literal-wrongness findings

### 2.1 Existing list-X slash commands break under the new layout; the migration plan covers only `monitor-workers`

**Description.** The new layout puts any issue carrying a label from `{needs-design, needs-clarification, needs-feedback, needs-approval, too-complex, future, proposal}` into `.issues/blocked/` (spec §1 line 39; §2 lines 142–152). At the same time, `--state open` now walks `open/*.md` only (§1 line 56), excluding `blocked/`.

The existing slash commands that exist to surface those labels for human review query `--state open --label X`:

- `plugins/autocoder/commands/list-needs-design.md:42` — `issue_list --state open --label "needs-design"`
- `plugins/autocoder/commands/list-needs-feedback.md:42` — `issue_list --state open --label "needs-feedback"`
- `plugins/autocoder/commands/list-proposals.md:34` — `issue_list --state open --label "proposal"`
- `plugins/autocoder/commands/monitor-workers.md:82,130,261,262` — `--state open` plus a jq filter for these labels (line 130) or for the `working` label (lines 82, 261)

Under the new semantics, each of these queries returns an empty array — the labeled issues live in `blocked/` (or `working/`), not `open/`. The asked-for behavior of each command ("show me the issues needing design / needing feedback / awaiting proposal review / what monitor-workers is watching") fails silently after migration.

The spec's migration plan in §3 explicitly mentions `monitor-workers.md` (step 6) but only for the working-label rewrite. It does not flag the list-X commands, nor the additional `monitor-workers` queries that filter on blocking labels (`monitor-workers.md:130,262`).

**Evidence.**
- Spec §1 line 56: `--state open` walks `open/*.md` only.
- Spec §1 line 39 + §2 lines 142–152: blocked-labeled issues live in `blocked/`.
- `plugins/autocoder/commands/list-needs-design.md:42`, `list-needs-feedback.md:42`, `list-proposals.md:34`: all query `--state open --label "<blocking-label>"`.
- `plugins/autocoder/commands/monitor-workers.md:130,262`: blocking-label filter under `--state open`.
- Spec §3 migration plan step 6 (line 390): mentions `monitor-workers.md` only for `--state working` and `issue_release`.

**Proposed fix.** Extend the migration plan in §3 (and the analogous prose in §4's blocking-label discussion if helpful) to enumerate every slash command that must change, and how. Concretely, add a step (or expand step 6) to the effect:

> Update commands that previously queried `--state open --label X` where X is in the blocking set: `list-needs-design.md`, `list-needs-feedback.md`, `list-proposals.md`, and the analogous `monitor-workers.md` queries. Their `--state open` is now `--state blocked` (the blocking-label filter becomes redundant, since the bucket already partitions blocking issues; the `--label` flag stays only if a single label needs to be selected from the blocked set). The `monitor-workers.md` "issues with the working label" queries (`--state open --label "working"`) become `--state working`. Mirror all of these in `.agent/workflows/` per `CLAUDE.md`.

Without this enumeration, an implementer following only the migration plan ships a layout change that silently disables the list-X commands. The asked-for behavior of "find issues that need design/feedback/proposal review" requires this update to be part of the same landing.

## 3. Forced decisions

No forced decisions found.

## 4. Previously addressed

All five round-2 findings are resolved by commit `a6a2551`:

- **2.1 (§2/§4 ordering contradiction):** Resolved by rewriting §4's file row to match §2's rename-first order for `claim`, with the asymmetry (claim rename-first, release flock-then-rename) now explicitly documented in §2 line 120.
- **2.2 (CLI contract enum):** Resolved — `--state blocked` is now in §4 line 176.
- **2.3 (release Python hardcoded `open/`):** Resolved — §2 lines 99–118 now compute `target_bucket` from labels under flock and rename to `<target>/N.md`.
- **2.4 (file-backend `any-claimable` can't emit exit 3):** Resolved — §4 line 217 shows the guarded form `[ -d "${ISSUE_DIR_PATH}/open" ] || exit 3; find ... | grep -q .`.
- **2.5 (Section E claim test unsatisfiable by gh):** Resolved — §6 Section E now splits into strict (file/jira) and best-effort (gh) variants.

The four round-1 findings remain resolved as documented in round 2's §4.

## 5. Recommendation

⚠️ **Approve with literal-wrongness fixes**

§2 has 1 finding, addressable by spec edit to the migration plan. §3 is empty. Once 2.1 is addressed, the spec is ready for implementation planning.
