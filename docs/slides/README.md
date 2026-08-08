# First-run slides

`first-run.md` is a [Marp](https://marp.app/) deck — one slide per agentic
platform (Claude Code, Codex, Droid, Antigravity/Gemini, OpenCode) showing the
exact install → run → swarm commands, plus a verification summary.

Every command was checked against the repo (script paths, slash-command files,
flags). Regenerate the rendered outputs with:

```bash
npx @marp-team/marp-cli first-run.md --pdf      # docs/slides/first-run.pdf
npx @marp-team/marp-cli first-run.md --images png
```
