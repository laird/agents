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
