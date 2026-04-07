# Codex Install

Install the shared Codex runtime from this repository into your local environment:

```bash
bash /Users/Laird.Popkin/src/agents/scripts/install-codex.sh /path/to/target-repo
```

Example:

```bash
bash /Users/Laird.Popkin/src/agents/scripts/install-codex.sh /Users/Laird.Popkin/src/nextgen-CDD
```

This installer:

- symlinks `skills/autocoder` and `skills/modernize` into `~/.codex/skills`
- symlinks `codex-start-parallel`, `start-parallel`, `join-parallel`, `end-parallel`, and `stop-parallel` into `~/.local/bin`
- symlinks the `codex-*.sh` runtime wrappers into `/path/to/target-repo/scripts`
- appends `source /Users/Laird.Popkin/src/agents/scripts/codex-shell-aliases.sh` to your shell rc file if needed

After the installer finishes:

```bash
source ~/.zshrc
cd /Users/Laird.Popkin/src/nextgen-CDD
startcc 3
```

`startcc` and `startct` use the shared `agents` runtime scripts directly, so they work in fresh git worktrees without requiring each worktree to contain copied wrapper files.
