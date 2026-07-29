---
marp: true
theme: default
paginate: true
size: 16:9
style: |
  section { font-size: 23px; padding: 34px 56px 28px; }
  h1 { color: #1f6feb; border-bottom: 3px solid #1f6feb; padding-bottom: 6px; margin-bottom: 10px; }
  h2 { color: #1f6feb; }
  code { background: #f0f3f6; padding: 1px 6px; border-radius: 4px; }
  pre { font-size: 17px; line-height: 1.28; margin: 9px 0; }
  p { margin: 7px 0; }
  strong { color: #24292f; }
  .tag  { display:inline-block; background:#1f6feb; color:#fff; font-size:14px; padding:2px 10px; border-radius:12px; vertical-align:middle; }
  .term { display:inline-block; background:#6e7781; color:#fff; font-size:14px; padding:2px 10px; border-radius:12px; vertical-align:middle; }
  section.title { justify-content: center; text-align: center; }
  section.title h1 { border: none; font-size: 46px; }
  table { font-size: 19px; }
---

<!-- _class: title -->

# autocoder — First Run

### The exact commands to go from nothing to a running swarm, on every agentic platform

Claude Code · Codex · Droid (Factory) · Antigravity / Gemini · OpenCode

<span class="term">verified against the repo — every command, script path & flag checked</span>

---

# First Run — Claude Code

<span class="tag">/ = in Claude Code</span> &nbsp; <span class="term">$ = your terminal</span>

```text
# 1 · add the marketplace
/plugin marketplace add laird/agents
# 2 · install the plugin, then activate it this session
/plugin install autocoder@plugin-marketplace
/reload-plugins
# 3 · install utility scripts  (symlinks start-parallel → ~/.local/bin)
/install
# 4 · choose the issue source  (github or file)
/set-issue-source
# 5 · run it
/fix          # one pass       /fix-loop  # continuous     /stop-loop  # stop
# 6 · launch an agentic swarm  (terminal, from the target repo)
$ start-parallel 3 --agent claude --mux tmux --issue-source github
```

**Prereqs:** git repo · `tmux`/`cmux` for a swarm · `gh auth login` for the GitHub backend

---

# First Run — Codex

<span class="term">$ = your terminal</span> &nbsp; (script-driven, not slash-commands)

```bash
# 1 · install skills, aliases & parallel-agent commands into a repo
bash scripts/install-codex.sh /path/to/target-repo
# 2 · run one autocoder pass
bash scripts/codex-autocoder.sh fix
# 3 · run continuously
bash scripts/codex-fix-loop.sh
# 4 · launch an agentic swarm  (defaults to tmux; pass cmux to override)
bash scripts/start-parallel-codex.sh 3
```

**Optional aliases:** source `scripts/codex-shell-aliases.sh` → `startct`, `startcc`, `joinct`, `joincc`

**Prereqs:** git repo · `tmux`/`cmux` for a swarm · Codex CLI installed

---

# First Run — Droid (Factory)

<span class="term">$ = your terminal</span>

```bash
# 1 · install skills, droids, aliases & parallel-agent commands into a repo
bash scripts/install-droid.sh /path/to/target-repo
# 2 · run one autocoder pass
bash scripts/droid-autocoder.sh fix
# 3 · run continuously
bash scripts/droid-fix-loop.sh
# 4 · launch an agentic swarm  (arg order: <mux> <count>)
bash scripts/droid-start-parallel.sh tmux 3
```

**Or** install as a plugin: `droid plugin marketplace add https://github.com/laird/agents` → `droid plugin install autocoder@plugin-marketplace`
**Optional aliases:** source `scripts/droid-shell-aliases.sh` → `startdt`, `startdc`, `joindt`, `joindc`

---

# First Run — Antigravity / Gemini

*One slide, because both drive **Google's Gemini models** — same model family, two different runtimes. Install the one you use (or both): the **Antigravity IDE** loads the `.agent/` directory; the **Gemini CLI** loads the `skills/` extensions. Neither needs the other.*

**Antigravity engine** (`.agent/` workflows) &nbsp; <span class="tag">/ = in Antigravity</span>

```bash
# 1 · install the .agent/ directory into your project
$ curl -sSL https://raw.githubusercontent.com/laird/agents/master/scripts/install.sh | bash
# 2 · run the workflows inside Antigravity
/fix        /fix-loop
```

**Gemini CLI** (runtime scripts) &nbsp; <span class="term">$ = your terminal</span>

```bash
bash scripts/gemini-autocoder.sh fix     # one pass
bash scripts/gemini-fix-loop.sh          # continuous
start-parallel 3 --agent gemini --mux tmux   # swarm (aliases: startgt / startgc)
```

---

# First Run — OpenCode

<span class="term">$ = your terminal</span> &nbsp; (config-based; core autocoder workflow)

```bash
# 1 · copy the OpenCode agent configs into your project
cp -r /path/to/agents/agents /your/project/

# 2 · run the autocoder agent from OpenCode
#     (defined in agents/autocoder/agent.md — triage, fix, test, propose)
```

**Scope:** OpenCode ships the **core** autocoder workflow. Manager-session features — blocked-issue review, worker monitoring, and swarm dispatch — live in the Claude Code, Antigravity, Codex, and Droid integrations.

**Prereqs:** git repo · OpenCode configured to load the `agents/` directory

---

<!-- _class: title -->

# Verified against the repo

<div style="text-align:left; font-size:21px;">

<span style="color:#1a7f37; font-weight:bold;">●</span> &nbsp;**Checked & correct** — every install/run/swarm command above: script paths exist, slash-command files exist (`/fix`, `/install`, `/set-issue-source`, …), `--agent`/`--mux` flags match `start-parallel --help`, `start-parallel-codex.sh 3` (number-first) is accepted, OpenCode `agents/autocoder/agent.md` and Antigravity `.agent/workflows/fix.md` present.

<span style="color:#bf8700; font-weight:bold;">●</span> &nbsp;**Found 3 stale references in the current README** (pre-existing) — `scripts/codex-stop-loop.sh` and `scripts/droid-stop-loop.sh` are documented but **do not exist** (loops stop on `Ctrl-C`); and the Antigravity install URL points at a `main` branch that doesn't exist — corrected to `master` on these slides. Recommend fixing the README.

</div>
