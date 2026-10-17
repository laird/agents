# Environments: fast main, gated releases

Workers land on `main` quickly and `main` is allowed to go red. A release is not.
This document shows how to declare release environments and move them only to
commits that passed the full regression suite.

## The model

1. `main` is the integration branch. Workers merge into it after their own gate,
   and a push race can land an untested combination. That risk is accepted.
2. `main-sentinel.sh` tests every new `main` tip after the fact. A tip that passes
   the full suite becomes `origin/main-green` (the green ref is
   `<integration>-green`, so a swarm that integrates on `master` gets
   `master-green`; `AUTOCODER_GREEN_REF` or `--green-ref` rename it). A tip that
   fails is bisected over the pushes the pipeline recorded as tip refs and a P0
   is filed naming the culprit push and its issue; the fix rolls forward. Only
   with `--auto-revert` does the sentinel revert the culprit push itself. See
   `plugins/autocoder/scripts/README.md` section F.
3. An **environment** is a branch on origin (`env/staging`, `env/uat`, `env/prod`)
   that a deploy reads. Nothing moves it except `promote.sh`.
4. `promote.sh` moves an environment only to a commit with **proof**: the
   sentinel's green tip, or a tree the gate cache records as passing the full
   suite. A later stage additionally requires that the previous environment
   already contains the commit, so the pipeline order holds. Being on `main` is
   never proof.
5. An environment can add its own test (an E2E suite) that must pass on the
   candidate tree before the branch moves.

## Configure

Add an ordered `environments` array to `.autocoder.json` in the main worktree.
Order is the pipeline.

```json
{
  "environments": [
    {"name": "staging", "ref": "env/staging", "requires": "green", "auto": true},
    {"name": "uat",     "ref": "env/uat",     "requires": "staging"},
    {"name": "prod",    "ref": "env/prod",    "requires": "uat", "test": "npm run e2e"}
  ]
}
```

| Key | Meaning | Default |
|---|---|---|
| `name` | How you refer to the environment on the command line. | required |
| `ref` | The branch on origin that is the environment. Point your deploy at it. | `env/<name>` |
| `requires` | The proof a commit needs. `green` means the sentinel's green tip, or any commit whose tree has a recorded full-regression pass. An earlier environment's name means that environment's current tip, or a green commit that environment's tip already contains. A commit that has never been on staging cannot go to uat, however green it is. | required |
| `test` | An extra command run on the candidate tree, in a throwaway worktree, before the branch moves. Its verdict is cached by tree, so a repeat on the same tree is free. | none |
| `auto` | The sentinel promotes this environment after every green tick. Suits staging. Do not set it on prod. | `false` |

An entry may only require `green` or an environment listed before it. The script
refuses to run on a config that breaks that rule.

## Promote

```bash
# Move staging to the sentinel's green tip.
plugins/autocoder/scripts/promote.sh --to staging
# ✅ staging → 3f2a9c1 (tip of origin/main-green)

# Move uat to staging's current tip (the default candidate for requires: staging).
plugins/autocoder/scripts/promote.sh --to uat

# Move prod. Its own test runs first; a failure leaves env/prod where it was.
plugins/autocoder/scripts/promote.sh --to prod

# Promote a specific commit. It still needs proof.
plugins/autocoder/scripts/promote.sh --to staging --commit 3f2a9c1

# See every check and the decision without pushing.
plugins/autocoder/scripts/promote.sh --to prod --dry-run
```

Exit codes: `0` moved or already there, `1` setup or config error, `2` refused.
A refusal prints one line naming the missing proof, for example
`⛔ staging: refused, 8b1e0d2 is not the tip of origin/main-green and its tree has no recorded full-regression pass`.

`--repo DIR`, `--integration BRANCH`, `--green-ref NAME`, and `--test-cmd "<cmd>"`
match the sentinel's flags. The green ref defaults to `AUTOCODER_GREEN_REF`, then
`<integration>-green`, on both sides; a swarm that integrates on `master` passes
`--integration master` to `promote.sh` or sets `AUTOCODER_GREEN_REF=master-green`. `--test-cmd` matters: the gate cache keys on the exact command, so the
tree-pass lookup only works when `promote.sh` and `main-sentinel.sh` name the same
command. Both default to the `### Regression Test Suite` block of `AGENTS.md` or
`CLAUDE.md`, so a repo that relies on that default needs no flag on either side.

## See what is releasable

```bash
plugins/autocoder/scripts/promote.sh --list
```

```
ENV        REF                TIP      PROOF  AUTO  PROMOTABLE
staging    env/staging        10f753e  yes    yes   a9ee70e
uat        env/uat            27cfff7  yes    no    10f753e (needs --allow-rollback)
prod       env/prod           27cfff7  yes    no    27cfff7 (current) after 'npm run e2e'
```

`TIP` is the branch's current commit. `PROOF` says whether that commit still has
proof on record. `PROMOTABLE` is the newest commit the environment could move to
right now: the proof ref's tip, annotated when it is already current or would be
a rollback.

## Roll back

A move that is not a fast-forward is refused by default. Pass `--allow-rollback`
to move an environment backwards or sideways. The target still needs proof.

```bash
plugins/autocoder/scripts/promote.sh --to prod --commit 27cfff7 --allow-rollback
# 🔄 prod rolled back → 27cfff7 (tree 4c1d2e0 has a recorded full-regression pass)
```

The push uses `--force-with-lease` against the tip the script just read, so a
concurrent move is rejected instead of overwritten.

## Automatic staging

With `"auto": true`, `main-sentinel.sh` calls `promote.sh --auto` after every
green tick, including the tick that lands a revert. Auto environments are
promoted in pipeline order, each to its default candidate. A refused promotion
is logged and never changes the sentinel's exit code. Without any `auto`
environment the sentinel's behavior is unchanged.

## What "accept risk on main" means in practice

- A worker may push a combination it never tested (a push-race re-sync), and a
  red `main` can stay red until the sentinel's next tick. Other workers keep
  landing on it. That is the speed you are buying.
- The sentinel reverts the culprit push (and only that push: later innocent
  pushes stay), files a P0 that names the push, its issue and how to re-land,
  and moves `main-green` to the repaired tip. The red tip itself never gains
  proof: its tree is recorded as a fail, and `promote.sh --commit <red tip>`
  refuses it.
- An issue the merge job parked under `awaiting-integration` (landed on a red
  base, or by a disjoint re-sync) is closed by the sentinel on the first green
  tick whose tip contains its push and that `verify-shipped.sh` accepts.
- No environment ever points at a commit that failed, or was never run through,
  the full suite. Deploys read `env/*` branches, not `main`, so they never see
  the red window.

## Audit trail

Each move appends a line to `docs/HISTORY.md` through `append-to-history.sh`
when that script is present. The branch itself is the authoritative record:
`git log origin/env/prod` is the release history.
