# Review corpus: scoring the pre-landing reviewer

A fixed set of diffs whose right answer is known. It lets you measure a change
to the reviewer (its prompt, `REVIEW.md`, its tools or its model) before you
adopt it (#167). The layout follows [`tests/triage_corpus/`](../triage_corpus/README.md).

```
tests/review_corpus/
├── README.md
└── cases/<id>/
    ├── case.json    # kind, expected verdict, source, commits, note
    ├── diff.patch   # what the reviewer is shown
    └── fix.patch    # culprits only, when known: the change that fixed it
```

| `kind` | `expect` | Meaning |
|---|---|---|
| `culprit` | `flag` | A diff that shipped a real defect. A reviewer that passes it missed it. |
| `clean` | `pass` | A diff that landed and stayed green. Flagging it is a false alarm. |

Where cases come from (`source`):

- **`sentinel-revert`**: a push that the post-merge sentinel (`main-sentinel.sh`) found red
  and reverted. The revert carries the trailers `Autocoder-Reverts: <culprit>` and
  `Autocoder-Reverts-Issue: <n>`, plus a `Range <prev-good>..<culprit>` line. The
  culprit diff is therefore exact, not guessed from commit messages. Re-landing
  starts with `git revert <revert>`, which only re-applies the culprit. The issue's
  own commits after that (subject `#<n>:` or `Fix #<n>:`) are stored as `fix.patch`.
- **`reversed-fix`**: a real bug-fix commit from this repo, reversed. Undoing the fix
  restores a defect someone actually shipped. These seed the set until the sentinel
  has reverted enough pushes of its own.
- **`landed-clean`**: a real commit that landed and was not reverted.

## Running it

```bash
S=plugins/autocoder/scripts/review-corpus.py
python3 $S harvest                         # add every sentinel revert on origin/master
python3 $S add --clean <sha>               # add a known-clean commit
python3 $S add --reversed-fix <sha>        # add the reverse of a bug fix
python3 $S score --save /tmp/base.json     # score the current reviewer (claude -p + REVIEW.md)
# ...change REVIEW.md, the review prompt, or REVIEW_MODEL...
python3 $S score --baseline /tmp/base.json # exits 1 unless the score went up
```

`score` shows each case's diff to the reviewer and reads the last `Verdict: flag` or
`Verdict: pass` line it prints. If the reviewer prints no such line (or crashes, or
times out), the case is an error. An error is wrong for either kind: never a catch,
always a false alarm. Any error makes `score` exit 1, so a broken reviewer can
never pass `--baseline`. The corpus must hold both culprit and clean cases.
`--corpus` and `--rules` are resolved against `--repo`.

The score is the catch rate minus the false-alarm rate, from −1 to 1. Run it on
every change to the reviewer, and drop any change that does not raise the score
(pass `--allow-equal` to keep a change that leaves it unchanged).

`--reviewer <cmd>` swaps in any other reviewer. The command gets:
- the diff on stdin;
- `REVIEW_CASE_DIR` and `REVIEW_RULES` in its environment.

With the default `claude` reviewer, a full run costs one model call per case.
`REVIEW_MODEL` picks the model (default `sonnet`). `REVIEW_TIMEOUT` sets the
per-case timeout in seconds (default 600).

## Extending it

- Run `harvest` after the sentinel reverts something; it skips cases it already has.
- Keep culprits and clean cases roughly balanced. A set that is mostly culprits
  rewards a reviewer that flags everything.
- Pick diffs a reviewer could judge from the diff and the repo alone. A defect that
  only shows up at runtime under load is not a fair test.
- Commit the new case directories. `tests/test_review_corpus.sh` checks that each
  one is well formed.
