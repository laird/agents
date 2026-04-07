# Helper Scripts

This directory contains general helper scripts for the repository.

- **`watchdog-fix.sh`**: A script to restart the `/fix` workflow if it crashes (moved here from `.agent/scripts` in some contexts, but check `.agent/scripts` for the Antigravity-specific version).
- **`codex-autocoder.sh`**: Run one Codex autocoder pass using the repo's new Codex skill packaging.
- **`codex-fix-loop.sh`**: Repeat Codex autocoder passes with shell-managed sleep/stop behavior.
- **`codex-manage-workers.sh`**: Run one Codex manager pass to inspect worker status and blocked issues.
- **`codex-manage-workers-loop.sh`**: Repeat Codex manager passes in a loop.
- **`codex-monitor-workers.sh`**: Inspect Codex worker sessions and summarize the GitHub work queue.
- **`codex-monitor-loop.sh`**: Repeat Codex worker monitoring on an interval.
- **`codex-stop-loop.sh`**: Stop Codex fix or monitor loops by creating stop files.
- **`start-parallel-codex.sh`**: Backward-compatible Codex swarm launcher that defaults to tmux and delegates to the shared parallel starter.
- **`codex-shell-aliases.sh`**: Shell alias snippet for `startct`, `startcc`, `joinct`, and `joincc`.
- **`install-codex.sh`**: Install Codex skills, shared parallel-agent command symlinks, and shell alias sourcing.
- **`droid-autocoder.sh`**: Run one Droid autocoder pass using `droid exec`.
- **`droid-fix-loop.sh`**: Repeat Droid autocoder passes with shell-managed sleep/stop behavior.
- **`droid-manage-workers.sh`**: Run one Droid manager pass to inspect worker status and blocked issues.
- **`droid-manage-workers-loop.sh`**: Repeat Droid manager passes in a loop.
- **`droid-monitor-workers.sh`**: Inspect Droid worker sessions and summarize the GitHub work queue.
- **`droid-monitor-loop.sh`**: Repeat Droid worker monitoring on an interval.
- **`droid-stop-loop.sh`**: Stop Droid fix or monitor loops by creating stop files.
- **`droid-start-parallel.sh`**: Start a tmux/cmux-based Droid worker swarm with git worktrees.
- **`droid-shell-aliases.sh`**: Shell alias snippet for `startdt`, `startdc`, `joindt`, and `joindc`.
- **`install-droid.sh`**: Install Droid skills, droids, commands, shared parallel-agent command symlinks, and shell alias sourcing.
