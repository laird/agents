# Codex Install

Install the shared Codex runtime from this repository into your local environment:

```bash
bash /path/to/agents/scripts/install-codex.sh /path/to/your-project
```

Example:

```bash
bash ~/src/agents/scripts/install-codex.sh ~/src/your-project
```

This installer:

- symlinks `skills/autocoder` and `skills/modernize` into `~/.codex/skills`
- symlinks `codex-start-parallel`, `start-parallel`, `join-parallel`, `end-parallel`, and `stop-parallel` into `~/.local/bin`
- symlinks the `codex-*.sh` runtime wrappers into `/path/to/your-project/scripts`
- appends `source /path/to/agents/scripts/codex-shell-aliases.sh` to your shell rc file if needed

After the installer finishes:

```bash
source ~/.zshrc
cd /path/to/your-project
startcc 3
```

`startcc` and `startct` use the shared `agents` runtime scripts directly, so they work in fresh git worktrees without requiring each worktree to contain copied wrapper files.
