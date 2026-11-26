# Autocoder Changelog

Changes waiting for the next release go under `## [Unreleased]`. Issue branches
add entries here and never bump a version; the release bumps every manifest at
once (Version Management in `docs/maintaining.md`).

## [Unreleased]

## [4.71.0] - 2026-11-26

### Added

- `quota-failover.sh --ensure` and `worker-auth-watchdog.sh --ensure` share `scheduler-ensure.sh`: one scheduler per job (crontab, a systemd user timer with a `loginctl enable-linger` note, or a macOS LaunchAgent). Re-running does not add a second one, and `--loop` refuses when one is already installed. The idle sentinel uses the same host line and linger hint; its units still run the version-independent shim.
- Personal host names, home directories, tailnet examples, and the plugin author email are gone from the tree. Environment names in docs and tests are `example-host`. Antigravity `watchdog-fix.sh` takes `AUTOCODER_WATCHDOG_TARGET` / `--target` (default: the current directory) instead of a fixed checkout. `AGENTS_REPO_ROOT` overrides the derived checkout.
- The merge train can lift a red-integration hold when the red's fix has landed
  (`train.redHold.releaseOn`, #428). `closed` (the default, and an absent
  `redHold`) still holds until the tracking issue closes. `landed` stops
  holding once a hotfix or lane-labelled landing whose commit or READY names
  that issue is on the integration tip and the gate that published it was
  green. The cycle log and the status line say `hold lifted: fix landed <sha>
  (CI verdict pending)`. A fix that is not on the tip, or whose gate was not
  green, still holds. A malformed `redHold` is refused at config load.
- Preflight budget (`preflight-budget.sh`): a host-wide bound on preflights, as plugin
  tooling. Slots are sized from the gate's memory cap and the host's memory (a slot
  count override, a reserve, a per-preflight memory and a running-gates command are
  the inputs); waiters take tickets ordered by priority then arrival, so a hotfix
  (`hotfix/*` branch or `--priority hotfix`) takes the next free slot ahead of every
  ordinary waiter and a later preflight never passes an earlier one; the waiting line
  names the holders and the position. No preflight starts while the host's 1-minute
  load average is over the core count times a factor (1.0; `off` disables it), and
  the line says why. Claims are noclobber redirections and `flock`, never a `mkdir`
  exit status; dead holders and tickets are reaped. `enqueue.sh --budget` (or
  `train.enqueue.budget`) takes a slot for the rows after `merge-tree` and shows it
  as a `budget` row; `--priority` and `--host-exclusive NAME` go with it.
- Host-exclusive stages: `host_exclusive_lock NAME ROLE` in the same library, one
  lock per stage name host-wide, the gate's run admitted ahead of waiting preflights.
  The stage runner honours a manifest stage marked `"host_exclusive": true` (role
  `AUTOCODER_HOST_EXCLUSIVE_ROLE`, default `gate`; `enqueue.sh` exports `preflight`),
  reports the seconds waited apart from the stage's own and does not count them
  against its `timeout_s`.
- Host load on the ledger: the stage runner records the host's 1-minute load average
  at every stage's start and end (`load1_start`/`load1_end` in the timings, a `load
  a->b` column in the summary), `--stage-args` prints `--stage-load name=start:end`
  words, `landing-timings.py batch` keeps them as `stage_load` (only when given, so
  older rows and readers are unaffected), and `landing-report.py` prints a `host
  load` column per batch and the per-stage maxima, so host overload is separable from
  slow code.
- The merge queue owns the dependency-bot pass (`merge-train.py depbot`,
  `train_depbot.py`; the daemon's tick runs it when `train.depbot` is set).
  Every open PR by a configured bot author (`authors`, default
  `["dependabot[bot]"]`) gets a tracking issue (found again by the hidden
  `<!-- depbot-pr <n> -->` marker or its title) with a READY the planner
  accepts without a hand (`stack: `<bot branch>` carries #<issue>`, the tip,
  `flag: none`), first in priority (a marked `first` row, or a label); a moved
  tip gets a new READY, a PR the bot replaced supersedes its older issue, a
  landed tracking issue closes its PR naming the landed sha before the branch
  is deleted. The status line carries `depbot: N open, oldest M passes` or
  `depbot: unknown (pr list failed)`, never a silent zero. The planner now
  reads a branch whose last segment ends in a version (`...-4.17.21`) as a
  branch, not a file.

### Fixed

- `bounce-resume.sh` reads the issue JSON from a file instead of the
  environment. A long comment thread made that exec die with "Argument list
  too long", the script failed toward "none", and the gate claimed new work
  over a bounce that stayed `working` (#432).

### Fixed

- Self-improvement decisions stay inside one comparison (#434). `eval-run.py
  --comparison` stamps the id, the case-manifest and grader fingerprints, and
  the settings both sides must share (manifest, grader, worker, repeats,
  timeout). `eval-decide.py --comparison` tallies only those rows. It returns
  inconclusive when the settings disagree or a case's repeat counts differ, and
  rows from another comparison that reuse the same harness sha no longer move
  the verdict. A missing side stays "fewer than N runs". A second batch past
  the planned repeat count is inconclusive instead of being pooled. The
  manifest covers the task, seed and setup, not only `case.json`.
  `/propose-fix` keeps one id across a refine and re-runs only the candidate
  sha; a new repeat count or case set starts a new id with the worktree
  checked out at the baseline sha.

## [4.70.0] - 2026-11-26

### Added

- Operational loops' ticks (#422). A fifth ledger, `ticks.jsonl`
  (`AUTOCODER_TICKS`), takes one line per run of any loop that records
  itself: a shell loop calls `tick_start` and `tick_end` from `tick-fns.sh`,
  and a Python loop runs `tick-log.py`. `trace-build.py --ticks` turns each
  line into a trace of `kind: "tick"`, and attempt traces now carry
  `kind: "attempt"`. `analyze-traces.py` gains four tick classifiers, each
  keyed by loop id: `tick-error-streak`, `tick-slow`, `tick-noop-only` and
  `tick-missing`. They cite the new rules B14 to B17 in `BEHAVIOR.md`. The
  week page's loop block counts their findings.

- Quota failover (`quota-failover.sh`). When a worker or the manager pane shows
  that agent's usage limit (Claude's weekly-limit dialog and banner, Grok's
  team credit message, Codex's usage-limit text, and the same class of message
  for Gemini, Droid, and Pi), the watchdog restarts that pane on the next
  installed, authenticated agent. The order is `claude`, `codex`, `grok`, then
  `gemini`, `droid`, `pi`, so Claude, Codex, and Grok can replace each other,
  and one swarm may run a different agent in each pane. Overridable with
  `AUTOCODER_AGENT_PREFERENCE` or `.autocoder.json` `agentPreference`. The
  reset time on the pane is remembered; after it passes, an idle pane returns
  to the preferred agent. The switch uses `restart-worker.sh` (same worktree,
  branch, and `working` claim; the worktree is not reset). Claude and Grok
  resume with `/fix N` or `/fix-loop` (`/autocoder:…` on Claude) and the
  manager runs `manager-resume` then `monitor-loop`. Codex resumes with its
  `/goal` (or the shell loop) under `--ask-for-approval never`. The idle
  sentinel runs the tick, and `--ensure` installs a
  cron entry so a manager blocked on its own limit still gets switched. GitHub
  API and GraphQL rate-limit text is not treated as an agent quota hit. The
  restarted agent is launched with that agent's auto-approve flag. "Add funds"
  is never chosen.

- Swarm launches auto-approve tool permissions, by flag, so a pane does not
  sit on an approval prompt. Grok is `grok --trust --always-approve`. Claude
  is `claude --permission-mode bypassPermissions` (not
  `--dangerously-skip-permissions`, which opens a "No, exit" consent dialog).
  Codex is `codex --ask-for-approval never` on the interactive launch and on
  `codex exec` (current Codex rejects `--full-auto`). Gemini is
  `gemini --sandbox=false -y`. Droid's exec loop stays `droid exec --auto high`.
  Finished swarm work is validated and merged through `merge-launch.sh` /
  `merge-to-integration.sh`. Workers are not told to open a pull request. A
  high-risk diff and an open revert-breaker issue are the two landing stops
  that still open one.

- `--agent grok` (and `AUTOCODER_AGENT=grok`) starts a Grok CLI worker or manager
  in the same worktree and issue as the other agents. The launch command is
  `grok --trust --always-approve`: `--trust` records
  `~/.grok/trusted_folders.toml`, and `--always-approve` accepts tool calls.
  The launcher does not type an answer into a dialog, and it does not pass
  `--yolo` or `--dangerously-skip-permissions`. Commands are the bare names
  Grok lists: `/fix N`, `/fix-loop`, `/monitor-loop`, and
  `/manager-resume --non-interactive`. Herdr registers the pane with
  `herdr agent start --kind grok`.

### Fixed

- The fix-loop gate's claim race check no longer puts the issue JSON in the
  environment (#423). A long comment thread exceeded ARG_MAX, the check died
  after the claim comment was posted, and the gate treated that crash as a
  lost race, so the `working` label stayed. The JSON is read from a file. A
  check that does not run releases the claim; a lost race still does not.

- The merge train's landing proof no longer reports a member as not landed when
  a co-member's edit of the same source file conflicts on re-merge and a
  driver-owned path also differs (#377). The adjacent-edit proof already
  accepted the source conflict on its own. Driver-owned paths (a regenerated
  file, a page whose stamp a driver rewrites) are now set aside before that
  check, and the close-out names them (`ignored driver-owned: ...`). A boolean
  `merge` attribute (`check-attr` reports `set`) is git's built-in 3-way merge,
  so a missing line in that file still refuses the proof. A member whose added
  source line is absent stays open, and the close-out names that file and the
  first missing line.

## [4.69.0] - 2026-11-26

### Added

- Grok CLI installs this repo's Claude Code marketplace. `/fix-loop` and
  `/monitor-loop` schedule with `scheduler_create` on Grok (its `/loop`), and
  `/stop-loop` deletes those jobs. Script lookup also searches
  `~/.grok/installed-plugins`. Claude Code's Stop hook stays
  `settings.json` only: `hooks/hooks.json` is not shipped, because Claude
  would load it beside the existing hook.

## [4.68.0] - 2026-11-25

### Added

- `claim-bounced`, a trace classifier for claims dropped before any work began (#402, #395):
  it fires on an attempt released within two minutes of its claim, with no READY and no gate.
  `BEHAVIOR.md` gains B13, the rule it detects: a refused or abandoned claim is released
  visibly, the release comment posted in the same step as the label removal. In one swarm's
  ledgers 329 of 1,031 attempts were reclaimed, 80% of them released within a minute of the
  claim. The week page's findings now count this class, so the `claim-issue.sh` fix above shows
  as a falling number.

### Fixed

- `fix-loop-gate.sh` no longer claims an issue that waits for the merge train (#405). With a
  `train` section in `.autocoder.json`, an issue carrying one of `train.readyLabels` (default
  `ready-for-review`) is skipped, and the gate logs `ready (train): N` when it skips any. Before,
  the gate claimed such an issue every tick and the claim was released seconds later. Repositories
  without a `train` section see no change.

- `claim-issue.sh` releases visibly when it refuses an issue over a stale start comment (#402).
  A work-started comment with no release after it counts in every later claim window, so the
  refusal, which dropped the `working` label and posted nothing, left the window open: every
  later claimant refused for the same reason and the issue bounced between the fix-loop gate and
  the worker (one swarm's ledgers: one issue claimed and dropped 99 times in two days). With no
  live rival marker, the refusal now posts the `🔓 Releasing claim` comment right after the label
  removal, as the gate's own release does, and the next claim starts from a clean window. A
  genuine race (a second live claim marker) still refuses without a comment.
- Evaluation cases can run on a fake GitHub backend (#403). With `"backend": "fake-github"` in
  `case.json`, `eval-run.py` keeps the sandbox issue in a `fake-gh.py` store behind a `gh` shim.
  Comments staged in `issue.comments` get a `createdAt` `age_s` seconds in the past. The worker
  runs with `ISSUE_SOURCE=github`, so claim-protocol findings (a stale start comment, an old claim
  marker) and review-record findings can be replayed. `fake-gh.py` fails loudly on any `gh` form
  it does not answer. Result rows carry `backend`, and `eval-author.py check` validates the new
  keys.

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

- The dependency filter no longer reads one issue per dependency on the GitHub backend
  (#392). `_ideps_filter` resolved every distinct dependency outside the open list with its
  own `gh issue view`, serialized; on a 500-issue backlog with about 110 such dependencies
  that was 0.7 to 0.9 s each and the claim tick ran past its ceiling four times in a row
  while the API answered in a second. The outside dependencies are now read in one GraphQL
  request per 100 numbers (`_ideps_gh_lookup_many`); the #380 rules hold (a clean not-found
  is met, a failed request leaves every number in it unmet and says so, a null answer with
  any other error is unmet too, and a failed later chunk marks only its own numbers); the
  read is `issueOrPullRequest`, so a dependency on a pull request is read for its state
  (open gates, merged or closed frees), where the per-number `gh issue view` could not read
  one; the other backends and `issue_unmet_dependencies` keep the per-number read.
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
