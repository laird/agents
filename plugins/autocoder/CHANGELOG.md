# Autocoder Changelog

Changes waiting for the next release go under `## [Unreleased]`. Issue branches
add entries here and never bump a version; the release bumps every manifest at
once (Version Management in `docs/maintaining.md`).

## [Unreleased]

### Fixed

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
  (a dirty tree, a refused commit) keep their verdicts.
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
