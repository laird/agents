# Droid Install

Install the shared Droid runtime from this repository into your local environment:

```bash
bash /path/to/agents/scripts/install-droid.sh /path/to/target-repo
```

Example:

```bash
bash /Users/Laird.Popkin/src/agents/scripts/install-droid.sh /Users/Laird.Popkin/src/my-project
```

This installer:

- Symlinks `.factory/skills/autocoder` and `.factory/skills/modernize` into the target repo
- Symlinks `.factory/droids/*.md` (6 specialist subagents) into the target repo
- Symlinks all plugin commands into `.factory/commands/`
- Symlinks `droid-start-parallel`, `start-parallel`, `join-parallel`, `end-parallel`, and `stop-parallel` into `~/.local/bin`
- Symlinks the `droid-*.sh` runtime wrappers into the target repo's `scripts/` directory
- Appends `source .../droid-shell-aliases.sh` to your shell rc file if needed

After the installer finishes:

```bash
source ~/.zshrc
cd /path/to/target-repo
droid
```

## Plugin Installation (Alternative)

You can also install via Droid's plugin system:

```bash
# Add the marketplace
droid plugin marketplace add https://github.com/laird/agents

# Install plugins
droid plugin install modernize@plugin-marketplace
droid plugin install autocoder@plugin-marketplace
```

## Shell Aliases

`startdt` and `startdc` use the shared `agents` runtime scripts directly, so they work in fresh git worktrees without requiring each worktree to contain copied wrapper files.

```bash
startdt 3    # start 1 manager + 3 Droid workers in tmux
startdc 3    # start 1 manager + 3 Droid workers in cmux
joindt       # rejoin the current repo's tmux Droid session
joindc       # list/select cmux workspaces
```
