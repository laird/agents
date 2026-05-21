# `model:` frontmatter convention for Claude Code slash commands

**Date:** 2026-05-21
**Context:** Phase 3 fix-loop token-efficiency shipped `plugins/autocoder/commands/dispatch.md`
with `model: claude-haiku-4-5` in its frontmatter. That was the first command in this repo to
use a `model:` field. Issue #1 item 6 required verifying the convention.

## What I found

1. **Upstream Claude Code docs** —
   `https://code.claude.com/docs/en/slash-commands` (canonical URL after the
   `docs.claude.com/en/docs/claude-code/slash-commands → code.claude.com/docs/en/slash-commands`
   301 redirect). The "Frontmatter reference" table lists `model` as an optional field:
   > "Model to use when this skill is active. The override applies for the rest of the
   > current turn and is not saved to settings; the session model resumes on your next
   > prompt. Accepts the same values as `/model`, or `inherit` to keep the active model."

2. **Bundled `plugin-dev` skill** at
   `~/.claude/plugins/marketplaces/claude-plugins-official/plugins/plugin-dev/skills/command-development/references/frontmatter-reference.md`
   (lines 130–148, 438–443). Documents valid values as **`sonnet`, `opus`, `haiku`** (short
   aliases only) and shows `model: gpt4` as an explicit "Invalid model name" example. No
   dated model IDs (`claude-haiku-4-5-20251001`) appear anywhere in the bundled examples.

3. **Local grep of `~/.claude/plugins/`** — every real-world use of `model:` frontmatter
   in the official marketplace (`feature-dev`, `plugin-dev`, `superpowers`) uses one of
   `haiku`, `sonnet`, `opus`, or `inherit`. Zero hits for dated IDs.

## Conclusion

- `model:` frontmatter **is officially supported** in Claude Code slash commands / skills.
- The documented value set is the short aliases used by `/model`: `haiku`, `sonnet`,
  `opus`, plus `inherit`. Dated model IDs are not a documented input here.
- `dispatch.md` originally had `model: claude-haiku-4-5`, which is not a documented value.
  Fixed to `model: haiku`.
- The Task-tool `model="haiku"` call inside `dispatch.md`'s body (§7.1.1 of the spec)
  remains the load-bearing routing path; the frontmatter is a belt-and-braces pin so that
  invoking `/dispatch` directly also lands on Haiku regardless of the parent session model.

## For future maintainers

If Claude Code ever adds first-class support for pinning to a specific dated model ID
(e.g. so commands survive an alias rotation from `haiku` v4.5 → v5), the field to update
is still `model:` in the frontmatter of `plugins/autocoder/commands/dispatch.md` — just
swap the value. No structural change required.
