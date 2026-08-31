#!/usr/bin/env python3
"""Package each platform's autocoder scripts into that platform's plugin.

WHY THIS EXISTS
---------------
Scripts lived in two places -- `scripts/` for the per-runtime loop drivers and
`plugins/autocoder/scripts/` for everything the Claude plugin ships -- and only
the second was ever packaged. `worker-launch-lib.sh` *is* packaged, and it
launches Codex and Droid workers via `$repo_root/scripts/codex-fix-loop.sh`;
under an installed plugin that path does not exist, so the launch silently did
nothing. The Codex, Droid and Gemini packages shipped no scripts at all, while
their skills told agents to run `plugins/autocoder/scripts/regression-test.sh`
-- a path that only resolves if you happen to be sitting in this checkout.

Each platform gets the scripts IT uses, not the union. The sets genuinely
differ: Gemini's loop drivers are self-contained and pull in nothing, while
Codex and Droid drag in the whole issue-backend and swarm-manifest layer.

HOW THE SET IS DERIVED
----------------------
Seeds are this file's ENTRY_POINTS plus every script name mentioned in that
platform's own commands and skills, then closed transitively over references
between scripts. Deriving beats listing: a new `source foo.sh` in a loop driver
packages foo.sh automatically, where a hand-kept list would silently miss it
and break the platform at runtime rather than in CI.

USAGE
    python3 scripts/package-plugin-scripts.py            # sync
    python3 scripts/package-plugin-scripts.py --check    # verify, exit 1 on drift
"""

from __future__ import annotations

import filecmp
import re
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Where a script may be read from, in precedence order. A name present in both
# is taken from the plugin tree: that copy is the one the Claude plugin already
# ships, so it is the copy already under test.
SOURCE_POOLS = ("plugins/autocoder/scripts", "scripts")

SCRIPT_SUFFIXES = (".sh", ".py")

# Per platform: the package directory that receives the scripts, the content
# directories scanned for script mentions, and the launch entry points.
PLATFORMS = {
    "claude": {
        "package": "plugins/autocoder/scripts",
        "content": ["plugins/autocoder/commands", "plugins/autocoder/skills"],
        "entry_points": [
            "start-parallel-agents.sh",
            "claude-worker-loop.sh",
            "join-parallel-agents.sh",
            "end-parallel-agents.sh",
            "add-worker.sh",
            "remove-worker.sh",
            "restart-worker.sh",
        ],
    },
    "codex": {
        "package": "codex-plugins/autocoder/scripts",
        "content": ["codex-plugins/autocoder/skills"],
        "entry_points": [
            "codex-autocoder.sh",
            "codex-fix-loop.sh",
            "codex-manage-workers-loop.sh",
            "codex-monitor-loop.sh",
            "codex-monitor-workers.sh",
            "codex-review-blocked.sh",
            "codex-start-parallel.sh",
            "start-parallel-codex.sh",
            "probe-codex-goals.sh",
        ],
    },
    "droid": {
        "package": ".factory-plugin/plugins/autocoder/scripts",
        "content": [".factory/skills/autocoder", ".factory-plugin/plugins/autocoder"],
        "entry_points": [
            "droid-autocoder.sh",
            "droid-fix-loop.sh",
            "droid-manage-workers-loop.sh",
            "droid-monitor-loop.sh",
            "droid-monitor-workers.sh",
            "droid-start-parallel.sh",
        ],
    },
    # Gemini loads this repo's skills as a CLI extension, so skills/autocoder/
    # IS the Gemini package. Its scripts land inside it for that reason, and
    # they are mirrored into plugins/autocoder/skills/autocoder/scripts/ by the
    # skill packaging rule (tests/test_skill_packaging.sh compares the trees
    # byte for byte) -- four inert files in the Claude plugin is a smaller cost
    # than inventing a tree Gemini does not read.
    "gemini": {
        "package": "skills/autocoder/scripts",
        "mirror": "plugins/autocoder/skills/autocoder/scripts",
        "content": ["skills/autocoder"],
        "entry_points": [
            "gemini-autocoder.sh",
            "gemini-fix-loop.sh",
            "gemini-manage-workers-loop.sh",
            "gemini-monitor-loop.sh",
        ],
    },
}

SCRIPT_NAME = re.compile(r"([A-Za-z0-9][A-Za-z0-9._-]*\.(?:sh|py))")

# A script owned by one platform never ships to another. Without this the sets
# collapse into the union: a Claude command that documents `codex-autocoder.sh`
# drags the entire Codex loop layer into the Claude package, and every platform
# ends up carrying every other platform's drivers.
OWNER_PREFIXES = {
    "claude-": "claude",
    "codex-": "codex",
    "droid-": "droid",
    "gemini-": "gemini",
}
# Names the prefix rule cannot see.
OWNER_OVERRIDES = {
    "start-parallel-codex.sh": "codex",
    # Reachable from the shared worker-launch-lib.sh, but only down its Codex
    # branch -- which never runs on another platform.
    "probe-codex-goals.sh": "codex",
    "install-codex.sh": "codex",
    "install-droid.sh": "droid",
}


def owner_of(name: str) -> str | None:
    """The platform a script belongs to, or None when it is shared."""
    if name in OWNER_OVERRIDES:
        return OWNER_OVERRIDES[name]
    for prefix, platform in OWNER_PREFIXES.items():
        if name.startswith(prefix):
            return platform
    return None


def build_index() -> dict[str, Path]:
    """Map script name -> canonical source path."""
    index: dict[str, Path] = {}
    for pool in SOURCE_POOLS:
        directory = ROOT / pool
        if not directory.is_dir():
            continue
        for path in sorted(directory.iterdir()):
            if path.is_file() and path.suffix in SCRIPT_SUFFIXES:
                index.setdefault(path.name, path)
    return index


def mentioned_scripts(directories: list[str]) -> set[str]:
    found: set[str] = set()
    for rel in directories:
        base = ROOT / rel
        if not base.is_dir():
            continue
        for path in base.rglob("*"):
            if path.is_file() and path.suffix in (".md", ".json"):
                try:
                    found |= set(SCRIPT_NAME.findall(path.read_text(errors="ignore")))
                except OSError:
                    continue
    return found


def closure(platform: str, seeds: set[str], index: dict[str, Path]) -> set[str]:
    """Transitive closure over script references, excluding other platforms.

    The exclusion applies during traversal, not only to the result: stepping
    *through* another platform's driver is what would pull its whole dependency
    layer across.
    """
    def mine(name: str) -> bool:
        owner = owner_of(name)
        return owner is None or owner == platform

    seen: set[str] = set()
    stack = [s for s in seeds if s in index and mine(s)]
    while stack:
        name = stack.pop()
        if name in seen:
            continue
        seen.add(name)
        try:
            text = index[name].read_text(errors="ignore")
        except OSError:
            continue
        for ref in SCRIPT_NAME.findall(text):
            if ref in index and ref not in seen and mine(ref):
                stack.append(ref)
    return seen


def wanted(platform: str, index: dict[str, Path]) -> set[str]:
    spec = PLATFORMS[platform]
    seeds = set(spec["entry_points"]) | mentioned_scripts(spec["content"])
    return closure(platform, seeds, index)


def targets(spec: dict) -> list[Path]:
    dirs = [ROOT / spec["package"]]
    if "mirror" in spec:
        dirs.append(ROOT / spec["mirror"])
    return dirs


def sync() -> int:
    index = build_index()
    for platform, spec in PLATFORMS.items():
        names = sorted(wanted(platform, index))
        for directory in targets(spec):
            directory.mkdir(parents=True, exist_ok=True)
            copied = 0
            for name in names:
                src = index[name]
                dst = directory / name
                # Never copy a file onto itself (claude's package IS a source).
                if src.resolve() == dst.resolve():
                    continue
                if not dst.exists() or not filecmp.cmp(src, dst, shallow=False):
                    shutil.copy2(src, dst)
                    copied += 1
            print(f"{platform:8s} {len(names):3d} scripts -> {directory.relative_to(ROOT)}  ({copied} written)")
    return 0


def check() -> int:
    index = build_index()
    problems = 0
    for platform, spec in PLATFORMS.items():
        names = sorted(wanted(platform, index))
        for directory in targets(spec):
            rel = directory.relative_to(ROOT)
            for name in names:
                src = index[name]
                dst = directory / name
                if src.resolve() == dst.resolve():
                    continue
                if not dst.exists():
                    print(f"MISSING  {rel}/{name}  ({platform} needs it)")
                    problems += 1
                elif not filecmp.cmp(src, dst, shallow=False):
                    print(f"STALE    {rel}/{name}  differs from {src.relative_to(ROOT)}")
                    problems += 1
            print(f"{'OK' if not problems else '--':8s} {platform:8s} {len(names):3d} scripts in {rel}")
    if problems:
        print(f"\n{problems} problem(s). Run: python3 scripts/package-plugin-scripts.py")
        return 1
    print("\nEvery platform package carries the scripts it uses.")
    return 0


if __name__ == "__main__":
    sys.exit(check() if "--check" in sys.argv[1:] else sync())
