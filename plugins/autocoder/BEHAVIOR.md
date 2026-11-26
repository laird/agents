# Autocoder behaviour specification

The rules the fix protocol states, one per id, in one place (#395). Each rule has a stable id,
one sentence of behaviour, its source, and its signal: how a trace shows the rule broken, or
`judge` when only a reader of the transcript can tell. `analyze-traces.py` cites these ids, and
`tests/test_behavior_spec.py` keeps the two in step.

A rule is never renumbered. To retire one, start its Rule text with `Retired:`; it keeps its id
and needs no classifier.

## Citations

The Source column holds one or more citations separated by `;`. A citation is
`` `<file>` <text> ``:

- A `<file>` ending in `.md`, other than `CLAUDE.md`, is a command file in
  `plugins/autocoder/commands/`, and `<text>` is a heading in it.
- `CLAUDE.md` is the repository root's, and `<text>` is a heading in it.
- A `<file>` ending in `.sh` or `.py` is a script in `plugins/autocoder/scripts/`, and `<text>`
  is a free description; only the file's existence is checked.
- `same` repeats the previous rule's source.

A heading matches when a line `#{1,6} <heading>` reads `<text>` once a trailing parenthetical
qualifier such as `(MANDATORY)` or `(#7134)` is dropped from it.

## Rules

| Id | Rule | Source | Signal |
|---|---|---|---|
| B01 | Work goes to the gate only after the regression suite passed on the branch | `fix.md` Verify Before Claiming | a gate fails on a suite |
| B02 | A conflict or a rejected push is rebased and relaunched, never escalated on the first time | `CLAUDE.md` Landing work; `fix.md` Landing the Work | escalated with a conflict reason after one conflict |
| B03 | The same conflict twice is escalated, not retried a third time | same | three or more conflict gates in one attempt |
| B04 | The working label is released only on a terminal outcome | `fix.md` CRITICAL: Release the 'working' Label Only on a Terminal Outcome | released with no gate and no escalation; or re-claimed after release |
| B05 | A change lands only with a passing pre-landing review of the landed HEAD | `fix.md` Pre-Landing Review Gate | landed with no review record or a non-pass verdict |
| B06 | Every Important review finding is fixed or answered before landing | `fix.md` Pre-Landing Review Gate | review record with Important findings left |
| B07 | The worker does not stop or wait on a question it can answer itself | `fix.md` MANDATORY: Continuous Loop; `monitor-workers.md` Step 3b: Nudge workers that never saw a pre-check verdict | a verdict-nudged step |
| B08 | Immediately before launching the merge, the branch is rebased on the integration branch | `CLAUDE.md` Landing work | returned with cause stale-base |
| B09 | A red integration branch is not the change's fault and is not fixed by the worker | `merge-to-integration.sh` red-base check | gate with red_base true |
| B10 | Tool calls succeed; a tool that keeps failing is a harness fault, not something to retry blindly | `fix.md` Context Management | tool error share above a threshold |
| B11 | An attempt that opens a session ends in a gate, an escalation or an explicit release | `fix.md` CRITICAL: Release the 'working' Label Only on a Terminal Outcome | session ended, no gate, no escalation, no release |
| B12 | Work is decomposed rather than attempted when it is too large for one attempt | `fix.md` Ultra-Complex Issues - Decompose into Sub-Tasks | judge |
| B13 | A claim that is refused or abandoned is released visibly: the release comment that ends the claim window is posted in the same step as the label removal | `fix.md` Explicit release | released within two minutes of the claim, with no READY and no gate |
| B14 | An operational loop that fails is repaired, not left to fail run after run | `tick-fns.sh` records each run of an operational loop | three or more consecutive error or timeout ticks of one loop |
| B15 | An operational loop's run takes about as long as its usual run | same | a tick that took more than five times its loop's median duration, over at least ten timed ticks |
| B16 | An operational loop that keeps running has an effect; one that finds nothing to do for a day is rescheduled or stopped | same | at least ten ticks of one loop in the corpus's last day, every one a noop |
| B17 | An operational loop keeps its cadence | same | a silence after a tick longer than five times its loop's median gap, over at least ten ticks; the silence after the last tick runs to the corpus's end |
