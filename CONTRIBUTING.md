# Contributing — branching & release discipline

This repository uses a three-tier branch model so nothing reaches `master`
(the release line) without passing through integration testing and a version
bump.

```
feature/*  ──PR──▶  integration  ──PR──▶  master
  (work)            (integration test)     (release)
```

## Branches

| Branch | Purpose | What merges in |
|--------|---------|----------------|
| `feature/*` (also `claude/*`, `fix/*`) | One change in progress. | Your commits. |
| `integration` | Integration test line. The full CI suite runs here; changes bake together before release. | `feature/*` via PR. |
| `master` | Release line. Every merge here is a release. | `integration` via PR **only**. |

- **Never commit directly to `master` or `integration`.** Open a PR.
- Branch `feature/*` **off `integration`**, not `master`, so you build on what's queued for the next release.

## Everyday flow (feature → integration)

1. `git fetch origin && git checkout -B feature/my-change origin/integration`
2. Make the change; keep commits focused.
3. Push and open a PR **into `integration`**.
4. CI (`.github/workflows/test.yml`) runs the full pytest + shell suites. Green + review → merge.

Feature PRs do **not** need a version bump — only releases do.

## Release flow (integration → master)

A release promotes everything on `integration` to `master`. Open a PR from
`integration` into `master`. The **release gate**
(`.github/workflows/release-gate.yml`) runs on that PR and **fails unless**:

1. **Version bump** — the marketplace root `version` in
   `.claude-plugin/marketplace.json` is strictly greater than `master`'s.
2. **Three-place consistency** — for every plugin, its `marketplace.json`
   `plugins[].version` equals its own `.claude-plugin/plugins/<name>/plugin.json`.

So a release always bumps the version, and the version never drifts across the
three files.

### Bumping the version (the three places)

When cutting a release, update **all three**:

1. `.claude-plugin/marketplace.json` → the plugin's `plugins[].version`
2. `.claude-plugin/marketplace.json` → the root `version` (the marketplace bump the update mechanism keys off)
3. `.claude-plugin/plugins/<name>/plugin.json` → the plugin's own `version` (must equal #1)

> The other packagings (`.factory-plugin/`, `codex-plugins/`, `.codex-plugin/`)
> version independently — keep each packaging's marketplace and its `plugin.json`
> in step with **each other**; they need not match the Claude versions. See the
> version rule in `CLAUDE.md`.

### Check before you open the release PR

```bash
bash scripts/check-release-version.sh          # compares against origin/master
```

Exit 0 means the gate will pass; non-zero prints exactly what to fix.

## Branch protection (repo settings — one-time, owner)

CI enforces the *version* rules, but blocking direct pushes is a GitHub setting.
In **Settings → Branches**, add protection rules for `master` and `integration`:

- Require a pull request before merging.
- Require status checks to pass — select **`tests`** on both branches, and
  additionally **`release-gate`** on `master`.
- (Recommended) Require branches to be up to date before merging; disallow
  direct pushes.
