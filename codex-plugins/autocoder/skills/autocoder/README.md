# Autocoder

Shared cross-platform skill entrypoint for autonomous GitHub issue resolution, blocked-work review, worker monitoring, and continuous fix-loop operation.

## Installation

### Claude Code

```bash
cp -r /path/to/autocoder ~/.claude/skills/autocoder
```

Or symlink for development:

```bash
ln -s /path/to/autocoder ~/.claude/skills/autocoder
```

Invoke with: `/autocoder`

### Codex

```bash
cp -r /path/to/autocoder ~/.codex/skills/autocoder
```

Or symlink for development:

```bash
ln -s /path/to/autocoder ~/.codex/skills/autocoder
```

Restart Codex after installing or updating the skill.

### Antigravity

Global install:

```bash
cp -r /path/to/autocoder ~/.gemini/antigravity/skills/autocoder
```

Workspace install:

```bash
cp -r /path/to/autocoder .agents/skills/autocoder
```

### Gemini CLI

This directory now includes Gemini CLI extension metadata:

- `gemini-extension.json`
- `GEMINI.md`

Gemini CLI installs extensions from a GitHub repository root. To use this skill as a standalone extension, publish or vendor this directory as its own repository and run:

```bash
gemini extensions install <repo-url>
```

## Compatibility

| Capability | Claude Code | Codex | Antigravity | Gemini CLI |
|------------|:-----------:|:-----:|:-----------:|:----------:|
| Core skill instructions | ✅ | ✅ | ✅ | ✅ |
| Reference documents | ✅ | ✅ | ✅ | ✅ |
| Shell-driven fix loops | ✅ | ✅ | ✅ | ✅ |
| Worker monitoring guidance | ✅ | ✅ | ✅ | ✅ |

## References

- [SKILL.md](SKILL.md)
- [Workflow Map](references/workflow-map.md)
- [Command Mapping](references/command-mapping.md)
- [Codex integration](../../docs/CODEX.md)
- [Antigravity integration](../../docs/ANTIGRAVITY.md)
