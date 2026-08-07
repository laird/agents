# Critical Design Review: 2026-07-13-autocoder-planning-pipeline-design (Round 1)

**Spec:** `/Users/Laird.Popkin/src/agents/docs/specs/2026-07-13-autocoder-planning-pipeline-design.md`
**Verified Assumptions section:** present

## 1. Verified-assumptions cross-check

Each item in the spec's §10 table, re-read against the cited evidence:

- **Auto-close monitor works on file backend, not just gh** — reconfirmed. `issues-file.py:187` (`state = "CLOSED" if status == "closed" else "OPEN"`) and `:194` (`"state": state`) emit the gh-shaped `.state` field the monitor reads. ✅
- **`decomposed`/`subtask` + `Sub-task of #N` + parent checklist auto-close exist** — reconfirmed. `commands/fix.md:1205–1354`: child template emits `## Sub-task of #${ISSUE_NUM}`, monitor greps `Sub-task of #\K[0-9]+` (child→parent) and `#\K[0-9]+` (parent checklist), closes parent when all children `CLOSED`. ✅
- **No native parent field in file backend** — reconfirmed. `issues-file.py` create/get fields are number, title, priority, labels, status, assignee, body, comments; convention is required. ✅
- **Resume-worker primitive exists** — reconfirmed. `scripts/start-workers.sh` provides `start-worker N`. ✅
- **No per-worker pause primitive exists** — reconfirmed. Scripts are add/remove/restart-worker, start-workers, stop-parallel-agents only; scale-down correctly reuses `remove-worker`. ✅
- **Rename blast radius (~54 files)** — reconfirmed as a mechanical workstream across mirrors. ✅
- **Manager loop is `/monitor-workers` via `/monitor-loop` with add-worker(5b)/review-blocked(5c)** — reconfirmed against `commands/monitor-workers.md`, `commands/monitor-loop.md`. ✅

Additionally verified (load-bearing for the §3 step-6 hand-off, though not listed in §10):
- **Stories are claimable by workers** — `subtask` is NOT in `BLOCKING_LABELS` (`issues-file.py:54–62`); confirmed non-blocking at `fix.md:1107`. The hand-off is not silently blocked.
- **The tracking spec parent is not itself worked** — the claimable-issue filter excludes `decomposed` (`fix.md:548,554,578`). No worker will claim the pointer-only spec issue.

All verified assumptions hold. No §1 failures.

## 2. Literal-wrongness findings

No literal-wrongness findings.

The two ways the design could have literally broken its stated outcome — stories being unclaimable (`subtask` blocking) or workers claiming the tracking parent (`decomposed` not filtered) — were checked empirically and both are safe. The child/parent linking strings the spec mandates (`## Sub-task of #<SPEC>`, `- [ ] #<story>`) exactly match what the reused auto-close monitor parses. The review loops have defined termination (§3.1, §3.4). The rename is mechanical and the alias/hop concern is already flagged (§11 B5) as a token-efficiency note, not a correctness break.

## 3. Forced decisions

No forced decisions found.

The one candidate — how `/plan` guarantees the design doc lands on the shared integration branch (§3.2) so worktrees can see it — is resolved at the design level (the spec names the outcome: doc committed to the integration branch, planning runs in the host workspace). The mechanism (checkout/commit/push sequence) is implementation detail for `critical-implementation-review`, not a design-level either/or the codebase forces.

The human-gated planning nudge going unseen when the manager loop runs unattended is a direct consequence of the human-gated model the user explicitly chose — working as designed, not an unpicked choice.

## 5. Recommendation

✅ **Approve as-is** — §2 and §3 are both empty. The spec is ready for implementation planning (`thorough-writing-plans`). Implementation-time concerns explicitly deferred to `critical-implementation-review`: the doc-to-integration-branch commit mechanism (§3.2), keeping the spec parent body free of stray `#N` references so the auto-close monitor only waits on real stories, and the alias argument-forwarding stubs (§6/B5).
