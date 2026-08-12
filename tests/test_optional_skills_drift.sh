#!/bin/bash
# tests/test_optional_skills_drift.sh — runs the optional-skills drift guard in CI.
#
# WHY THIS EXISTS:
#   scripts/check-optional-skills-drift.sh is the sole guard keeping the
#   optional-skills prelude byte-identical across 16 files and the per-command
#   mapping blocks identical between the Claude Code and Antigravity mirrors.
#   Its header called itself CI-safe, but nothing ran it: the workflow's shell
#   job globs `tests/test_*.sh`, and the script lives in scripts/. So a PR that
#   drifted the mirrors merged green, and every hardening in the guard only
#   fired when a human remembered to type the command.
#
#   This wrapper matches the glob, so the existing job picks it up with no
#   workflow change. Exit status is the only signal that job parses.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
exec bash "$ROOT/scripts/check-optional-skills-drift.sh"
