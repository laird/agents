# Antigravity Helper Scripts

The scripts Antigravity's `.agent/workflows` and `.agent/rules` run.

**This directory is generated.** `scripts/package-plugin-scripts.py` (platform
`antigravity`) copies every script these workflows reference, and everything
those scripts reference in turn, from `plugins/autocoder/scripts/` and
`scripts/`. Edit the source, then run `python3 scripts/package-plugin-scripts.py`;
`tests/test_script_packaging.sh` fails if this tree drifts (#153).

Hand-maintained exceptions, listed as `local` in the packager because they carry
deliberate Antigravity adaptations: `start-parallel-agents.sh`,
`end-parallel-agents.sh`, `regression-test.sh`, `idle-sentinel.sh`. Keep their behaviour in step
with the plugin copies by hand.

> [!WARNING]
> The `watchdog-*.sh` scripts exist only here and are experimental.

<a id="script-dir"></a>
## Resolving `SCRIPT_DIR` in command files

Every command that sources `issue-fns.sh` opens with the same loop, marked
`# Resolve SCRIPT_DIR — see scripts/README.md#script-dir`. It tries, in order,
`$(pwd)/.agent/scripts`, `$(pwd)/plugins/autocoder/scripts` and
`$(pwd)/.claude-plugin/plugins/autocoder/scripts`, then falls back to the newest
installed plugin under `~/.claude/plugins/cache`.

A project-local tree only wins if it is a COMPLETE override, i.e. it actually
contains the file the command is about to source (`issue-fns.sh`; `/spot-check`
also requires `fix-loop-gate.sh`). Testing for the directory alone let a stale
vendored `.agent/` or `plugins/autocoder/` tree, left behind by an old project
import, shadow the installed plugin: the `source` then failed and every
`issue_*` call silently used the wrong backend.

Keep the loop byte-for-byte identical across commands; edit it everywhere at
once, in both `plugins/autocoder/commands/` and `.agent/workflows/`.
