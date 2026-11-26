# Maintaining this repository

Detailed rules for keeping the platform copies, skills and manifests in step.
`CLAUDE.md` gives the short version and links here.

## Parallel Maintenance Requirement

**CRITICAL**: This repository maintains two parallel implementations that MUST stay in sync:

| Platform | Directory | Guidance File |
|----------|-----------|---------------|
| **Claude Code** | `plugins/` | `CLAUDE.md` |
| **Antigravity** | `.agent/` | `GEMINI.md` |

**When modifying any workflow, command, or protocol:**

1. **Always update BOTH versions** - Changes to one must be mirrored to the other
2. **Check the mapping**:
   - `plugins/autocoder/commands/*.md` ↔ `.agent/workflows/*.md`
   - `plugins/modernize/commands/*.md` ↔ `.agent/workflows/*.md`
   - `plugins/modernize/agents/*.md` ↔ `.agent/rules/*.md`
3. **Verify parity** after changes: Both should have identical functionality
4. **Test both platforms** if possible before committing

**Key parallel files:**
- `/improve-test-coverage`: `plugins/autocoder/commands/improve-test-coverage.md` ↔ `.agent/workflows/improve-test-coverage.md`
- `/fix`: `plugins/autocoder/commands/fix.md` ↔ `.agent/workflows/fix.md`
- `/fix-loop`: `plugins/autocoder/commands/fix-loop.md` ↔ `.agent/workflows/fix-loop.md`
- `/full-regression-test`: `plugins/autocoder/commands/full-regression-test.md` ↔ `.agent/workflows/full-regression-test.md`
- `/review-blocked`: `plugins/autocoder/commands/review-blocked.md` ↔ `.agent/workflows/review-blocked.md`
- `/review-blocked-gui`: `plugins/autocoder/commands/review-blocked-gui.md` ↔ `.agent/workflows/review-blocked-gui.md`
- `/install`: `plugins/autocoder/commands/install.md` ↔ `.agent/workflows/install.md`

**Key parallel scripts:**
- `start-parallel-agents.sh`: `plugins/autocoder/scripts/start-parallel-agents.sh` ↔ `.agent/scripts/start-parallel-agents.sh`
- `join-parallel-agents.sh`: `plugins/autocoder/scripts/join-parallel-agents.sh` ↔ `.agent/scripts/join-parallel-agents.sh`
- `fetch-blocked-issues.sh`: `plugins/autocoder/scripts/fetch-blocked-issues.sh` ↔ `.agent/scripts/fetch-blocked-issues.sh`
- `add-blocking-label.sh`: `plugins/autocoder/scripts/add-blocking-label.sh` ↔ `.agent/scripts/add-blocking-label.sh`
- `approve-blocked-issue.sh`: `plugins/autocoder/scripts/approve-blocked-issue.sh` ↔ `.agent/scripts/approve-blocked-issue.sh`
- `reject-blocked-issue.sh`: `plugins/autocoder/scripts/reject-blocked-issue.sh` ↔ `.agent/scripts/reject-blocked-issue.sh`

`.agent/scripts/` is a **generated mirror** (#153): `scripts/package-plugin-scripts.py`
fills it, and `tests/test_script_packaging.sh` fails on drift. Edit the plugin copy
and re-run the packager. The exceptions are the scripts listed as `local` for the
`antigravity` platform (`start-parallel-agents.sh`, `end-parallel-agents.sh`,
`regression-test.sh`, `idle-sentinel.sh`), which carry Antigravity adaptations and are still synced by hand.

## Skill Packaging

`skills/` at the repo root is the source of truth, but a skill that lives only
there reaches **nobody**: each platform loads skills from its own plugin tree.
Every root skill must be mirrored into the plugin that ships it:

| root skill | Claude Code (byte-identical, enforced) | Codex (adapted) | Droid (adapted) |
|---|---|---|---|
| `skills/autocoder/` | `plugins/autocoder/skills/autocoder/` | `codex-plugins/autocoder/skills/autocoder/` | `.factory/skills/autocoder/` |
| `skills/improve/` | `plugins/autocoder/skills/improve/` | — | — |
| `skills/modernize/` | `plugins/modernize/skills/modernize/` | `codex-plugins/modernize/skills/modernize/` | `.factory/skills/modernize/` |

**Only the Claude Code column is byte-identical**, and it is the only one
`tests/test_skill_packaging.sh` enforces. The Codex and Droid columns are
*platform-adapted* copies maintained by hand: `.factory/` says "Droid" where the
root says "Codex", and both drop the `references/model-config.md` pointer. Copy
the root file over the `plugins/` mirror; **hand-apply** the same edit to the
Codex and Droid trees and re-diff afterward to confirm only those intentional
differences remain. Nothing machine-checks that, so an edit made only in
`skills/` silently never reaches Codex or Droid users.

Copies, not symlinks — plugin installation copies trees, and a symlink that
survives git may not survive the install. **Adding a new `skills/<name>/`
directory requires adding it to the `SKILL_OWNER` map** in
`tests/test_skill_packaging.sh`, or the suite fails.

Note that a command referring to `autocoder:references/<file>.md` resolves
against the *plugin's* skills tree, not the repo root, so such a reference is
broken until the mirror exists.


## Plugin manifests

**Plugin Metadata**: `.claude-plugin/marketplace.json` — there is no separate
per-plugin `plugin.json` for Claude Code. Each `plugins[]` entry is the manifest:
it carries the name, version, description, and a `source` pointing at
`./plugins/<name>/`, and **that entry is what the loader reads.** Verified: with
a marketplace entry at 9.9.9 and a nested `plugin.json` at 7.7.7,
`claude plugin details` reported 9.9.9. Nested `.claude-plugin/plugins/*/plugin.json`
files were removed for this reason — they were maintained by hand and read by nothing.

**Installation**: add this repo as a plugin marketplace, or clone it.

### Which manifest each platform actually loads

| Platform | Manifest it reads | Per-plugin manifest |
|---|---|---|
| Claude Code | `.claude-plugin/marketplace.json` | none — the marketplace entry *is* the manifest |
| Grok | the same `.claude-plugin/marketplace.json` (Grok reads it when `.grok-plugin/marketplace.json` is absent) | `plugins/<name>/.grok-plugin/plugin.json` (name and version; without it Grok installs the plugin as `<name>-<hash>`) |
| Codex | `.agents/plugins/marketplace.json` | `codex-plugins/<name>/.codex-plugin/plugin.json` (carries the version) |
| Droid | `.factory-plugin/marketplace.json` | `.factory-plugin/plugins/<name>/plugin.json` |
| Antigravity | `.agent/` (rules + workflows, no marketplace) | — |

`tests/test_manifest_versions.sh` asserts every one of these agrees on a version.

### Version Management

**CRITICAL**: a version bump must move **every** manifest together, or a platform
advertises a version it isn't shipping. The Droid marketplace once sat twelve minor
versions behind because only the Claude one was bumped.

1. `.claude-plugin/marketplace.json` — root `version` **and** each `plugins[].version`
2. `.factory-plugin/marketplace.json` — root `version` **and** each `plugins[].version`
3. `.factory-plugin/plugins/<name>/plugin.json`
4. `codex-plugins/<name>/.codex-plugin/plugin.json`
5. `plugins/<name>/.grok-plugin/plugin.json`

Both root marketplace versions must match; the update mechanism keys on them. Run
`bash tests/test_manifest_versions.sh` after any bump.

**Example workflow:**
```bash
# When updating autocoder from 3.5.0 to 3.6.0:
# 1. Update plugins[].version: "3.6.0"  (individual plugin)
# 2. Update root version: "3.10.0"     (marketplace version bump)
```

**Why this matters**: The marketplace update mechanism relies on the root version number to detect that new plugin versions are available. Forgetting to bump the marketplace version will prevent users from receiving your plugin updates.

