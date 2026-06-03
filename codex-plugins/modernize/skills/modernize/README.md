# Modernize

Shared cross-platform skill entrypoint for assessment, planning, phased modernization execution, and retrospective improvement loops.

## Installation

### Claude Code

```bash
cp -r /path/to/modernize ~/.claude/skills/modernize
```

Or symlink for development:

```bash
ln -s /path/to/modernize ~/.claude/skills/modernize
```

Invoke with: `/modernize`

### Codex

```bash
cp -r /path/to/modernize ~/.codex/skills/modernize
```

Or symlink for development:

```bash
ln -s /path/to/modernize ~/.codex/skills/modernize
```

Restart Codex after installing or updating the skill.

### Antigravity

Global install:

```bash
cp -r /path/to/modernize ~/.gemini/antigravity/skills/modernize
```

Workspace install:

```bash
cp -r /path/to/modernize .agents/skills/modernize
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
| Phased modernization workflow | ✅ | ✅ | ✅ | ✅ |
| Retrospective improvement loop | ✅ | ✅ | ✅ | ✅ |

## References

- [SKILL.md](SKILL.md)
- [Lifecycle](references/lifecycle.md)
- [Source Map](references/source-map.md)
- [Codex integration](../../docs/CODEX.md)
- [Antigravity integration](../../docs/ANTIGRAVITY.md)
