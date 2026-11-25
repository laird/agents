# Autocoder Changelog

Changes waiting for the next release go under `## [Unreleased]`. Issue branches
add entries here and never bump a version; the release bumps every manifest at
once (Version Management in `docs/maintaining.md`).

## [Unreleased]

## [4.67.0] - 2026-11-25

### Added

- `/propose-fix` (#395, slice 4): the agent's step of the loop. In a worktree of the plugin
  without the held-out cases, it proposes ONE harness change for a finding, runs the dev cases
  before and after, lets the runner score the held-out cases on both commits, and keeps the
  change only when `eval-decide.py` accepts; a reject allows one refinement, a second ends it.

- `/analyze-traces` (#395, slices 1 and 2): `trace-build.py` compiles one trace per issue
  attempt from the issue, merge, landing and gate ledgers, the worker transcripts and the review
  records; `BEHAVIOR.md` states the fix protocol's rules with stable ids; `analyze-traces.py`
  runs a registry of classifiers citing those rules and writes the failures that repeat, with an
  optional judge (off by default) for rules only a reader can check.
- `trace-build.py` reads ledgers the way live runs write them (#395): a claim and its readback,
  or a lost claim race, are steps of one attempt; landing-timings `landed` rows are train
  landings; `ready`, `launched`, `batched` and `returned` rows are steps; and
  `--train-gate-issue` (default `train.gateIssue` from `.autocoder.json`) drops the train gate
  issue's traces.

- `/author-evals` and `/run-evals` (#395, slice 3): `eval-author.py` scaffolds a dev and a
  held-out evaluation case per trace finding, with a default verifier per classifier, and checks
  the cases before they are committed. `eval-run.py` runs each case against a worker in a fresh
  sandbox repository with a file-backend issue, grades the attempt's trace, and records pass or
  fail per harness commit.
- The weekly landing report shows the self-improvement loop (#395, slice 5).
  `landing-report.py --week` ends "Week in numbers" with the week's trace findings (classes,
  traces covered, top three), its eval runs per split and its harness-change decisions. A missing
  script or file reads n/a. `--loop off` drops the block. `eval-decide.py` (slice 4) accepts,
  rejects or calls inconclusive one harness change from its dev and held-out eval results, and
  records each decision for the week page.

### Fixed

- The merge train's landing proof no longer reports a member as not landed when
  re-merging it onto the landed commit differs only in files a custom merge driver
  owns, such as a regenerated file or a page whose stamp line a driver re-stamps
  (#377). Before, such a member was left in the queue and its owner was asked to
  rebase work that had already landed. The proof now closes the member when every
  difference or conflict is in a driver-owned path and the member also changes at
  least one path no driver owns. The close-out line names the ignored paths:
  `landing proof: drivers (ignored driver-owned: <paths>)`.

- The merge job no longer blames a change for a red the integration branch fixed
  while the change's gate was running (#375). When the integrated tree failed, the
  job gated `origin/<integration>` alone to decide whose failure it was, but it used
  the branch's current tip. A fix that landed during the gate made that tip pass,
  so the change was bounced, and in a train the member was returned to its owner.
  The job now fetches, and if the tip has moved past the base the tree was built
  on, it re-syncs onto the new tip and gates again (at most
  `AUTOCODER_MOVED_BASE_REGATES`, default 2, times). After that, the base it gates
  alone is the one the tree was built on. The base-alone run also no longer reuses
  a cached pass recorded under the plain command, which another change's
  diff-scoped run may have recorded without running the failing files
  (`GATE_CACHE_RERUN_PASS=1` in `gate-cache-fns.sh`).

- `reboot-recover.sh --boot` no longer gives up on a swarm whose manager pane
  herdr has not finished restoring (#372). After a reboot, recovery found the
  manager's pane, got `agent_not_found` from it on all three attempts, and
  recorded the boot with the swarm still down and nobody told. Now it runs no
  herdr command until herdr's socket accepts a connection, and logs the pid of
  the server that answered. Where herdr is a user service, it also waits for
  `herdr.service` to be active, not only for some server to answer. While the
  restore is under way it reads herdr again, up to `AUTOCODER_REBOOT_PANE_TRIES`
  (10) times, `AUTOCODER_REBOOT_PANE_WAIT` (15) seconds apart. A manager pane
  that never takes the prompt gets a manager started through the sentinel
  instead. A boot recorded with a swarm still unrecovered calls that swarm's
  `sentinel_notify` hook.
- `merge-to-integration.sh` no longer reports a rebase the host stopped as a
  conflict. Git replaying the feature commits onto the integration branch can die
  on the same conditions a gate stage does (`No space left on device` on a shared
  tmpfs under several concurrent gates, a memory death, a missing tool), and such
  a stop leaves no conflicted file, so the script read it as "failed without a
  conflict": exit 1, the issue labelled `needs-clarification` and a comment
  sending a person after a conflict that never existed. The rebase's own output is
  now classified with the gate's infrastructure patterns
  (`AUTOCODER_GATE_INFRA_PATTERNS`, the report-line filter included): a host stop
  is retried once after `AUTOCODER_REBASE_INFRA_RETRY_DELAY` seconds (default 30),
  and a second one refuses as INFRASTRUCTURE (exit 3, the
  `::error::merge-to-integration: INFRASTRUCTURE -- the rebase onto ... did not
  complete, twice: <git's line>` marker a train's classifier reads, an issue
  comment whose reason opens with INFRASTRUCTURE and says to relaunch), the
  branch intact and nothing gated. A real conflict and a stop that is neither
  (a dirty tree, a refused commit) keep their verdicts. Three shapes the
  adversarial review found with real git under a real ENOSPC and a memory limit
  are covered: git's own memory death (`fatal: Out of memory, malloc failed`)
  joins the default infrastructure patterns; an error printed behind git's
  progress output (`Rebasing (1/2)\r`) is read on its own line, so the marker
  and the issue comment carry git's line and no carriage return; and a stop
  that left `rebase-merge/` behind before `head-name` was written (which
  `git rebase --abort` cannot clear) has its state removed and the tree reset
  before the retry, instead of the retry tripping on "already a rebase-merge
  directory". Two neighbours fixed on the way: with a conflict resolver or
  union-merge globs configured, a stop that left no unmerged file was reported
  as "Conflict resolved" by a resolver that resolved nothing (the un-rebased tree
  went to the gate, and a later re-sync could publish an ungated tree as
  documents-only); the resolver now runs only for a stop with unmerged files and
  `conflict_try_resolve` returns 1 when no rebase is in progress. Both
  INFRASTRUCTURE refusals (the rebase's and the gate's) record `cause=infra` in
  the landing ledger, as a train records the same verdict, where they recorded
  `other`. A non-numeric `AUTOCODER_REBASE_INFRA_RETRY_DELAY` is reported and
  replaced by 30 instead of handing `sleep` a value it refuses.
- The merge train's landing proof (`train_lib.landing_proof`) no longer reads a
  member as "not in the integration branch" after a green landing when a
  keyed-row merge driver wrote its rows in another order. The gate rebases a
  train onto an integration branch that moved under it, and a keyed-row driver
  derives its row order from the merge's ancestor, so the landed file and the
  proof's re-merge agree on the rows and not on their order; the proof's
  byte-for-byte tree comparison then judged the member absent, left its issue
  in the queue at the same tip and recorded the landing as nothing. A new
  verdict, `rows`, accepts a re-merge that changes only the order of lines
  inside files a merge driver owns (a reorder in a file no driver owns is still
  the branch's own change). The probe also keeps the landed copy of every path a
  `regeneratedMergeDrivers` driver merges, so a project's generator never runs
  from whatever tree the repository has checked out.

### Added

- `/review-blocked-gui` (#308): review blocked issues in a local web page. It
  starts `review-blocked-server.py` (#311) on `127.0.0.1`, prints a URL with a
  per-run token, and suggests `/review-blocked --prepare` when issues have no
  current analysis. The page (`review-blocked-ui.html`, #313) shows each issue's
  block reason, body and analysed options, and records approve, reject, ask and
  skip decisions, one at a time or in a batch. `/review-blocked --prepare` (#312)
  fills the analysis cache (`blocked-analysis-cache.py`, #310) without asking
  anything. `--stop` ends the server.
- The script packager also ships `review-blocked-ui.html` next to the server on
  every platform whose package carries `review-blocked-server.py`.
