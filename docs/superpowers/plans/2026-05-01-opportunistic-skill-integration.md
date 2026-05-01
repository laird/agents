# Opportunistic Skill Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire opportunistic invocation of `superpowers:*` and personal-toolkit skills into six commands across two platforms (Claude Code + Antigravity), with a sentinel-versioned canonical prelude, a per-command mapping block, a drift-check script, and a skills baseline file. The integration references skills only — never copies their content.

**Architecture:** Every target command gets one new "Optional skill enhancements" H2 section as its first H2, holding a byte-identical canonical boilerplate (sentinel-bracketed) plus a per-command mapping table (also sentinel-bracketed; identical between Claude Code and Antigravity mirrors of the same command). Dispatcher commands (`/fix-loop`, `/modernize`) additionally reference a worker skills manifest template held in the canonical prelude file. Drift between mirrors is detected by a hardened shell script.

**Tech Stack:** Bash (drift script), Markdown (all command/prelude files), `awk` + `sha256sum` (drift comparison), `find` (file location).

**Spec:** `docs/superpowers/specs/2026-04-30-opportunistic-skill-integration-design.md` (v4 + reference-only guardrail)

---

## File Inventory

**To create (4 files):**
- `plugins/shared/optional-skills-prelude.md` — Claude Code canonical boilerplate + worker manifest template
- `.agent/shared/optional-skills-prelude.md` — Antigravity mirror of the canonical
- `docs/superpowers/specs/2026-04-30-skills-baseline.txt` — Skill name + version baseline
- `scripts/check-optional-skills-drift.sh` — Two-pass drift detector

**To modify (12 files):**
- `plugins/autocoder/commands/{brainstorm-issue,approve-proposal,fix,fix-loop}.md`
- `plugins/modernize/commands/{plan,modernize}.md`
- `.agent/workflows/{brainstorm-issue,approve-proposal,plan,modernize,fix,fix-loop}.md`

Each modification adds two sentinel-bracketed regions (boilerplate + mapping) as the first H2 in the file body. No existing protocol content is removed.

---

## Phase 0: Pre-flight verifications (implementation-blocking)

These come from validation step 1 of the spec. They must run before any prelude file is written so blocking issues are caught early.

### Task 0.1: Verify superpowers public distribution URL and install command

**Files:**
- Read: nothing in repo
- Output: notes captured for use in Task 1.2

- [ ] **Step 1: Locate the installed superpowers plugin metadata**

```bash
cat ~/.claude/plugins/cache/claude-plugins-official/superpowers/*/plugin.json 2>/dev/null | head -40
ls ~/.claude/plugins/cache/claude-plugins-official/superpowers/ 2>/dev/null
```

Expected: a `plugin.json` (or similar manifest) and a version directory (currently `5.0.7`).

- [ ] **Step 2: Identify the public URL**

Read `homepage`, `repository`, or `url` field from `plugin.json`. If not present, locate the public source via the marketplace identifier (`claude-plugins-official` per the cached path). Document the canonical URL (e.g. `https://github.com/<owner>/superpowers`).

If you cannot determine the URL with certainty, stop and ask the user — do not guess. The URL ships verbatim to every user of every command.

- [ ] **Step 3: Identify the install command shape**

Determine the install command users actually run. Likely `/plugin install superpowers@claude-plugins-official` based on the cached marketplace identifier. Verify against current Claude Code documentation if available; ask the user if uncertain.

- [ ] **Step 4: Record findings**

Write the verified URL and install command to a scratch note (anywhere in conversation). They are consumed by Task 1.2 (canonical prelude creation) and Task 1.3 (Antigravity mirror).

- [ ] **Step 5: No commit** — this is research, no file change yet.

---

### Task 0.2: Verify `superpowers:subagent-driven-development` interaction with manifest insertion

**Files:**
- Read: `~/.claude/plugins/cache/claude-plugins-official/superpowers/*/skills/subagent-driven-development/SKILL.md`

- [ ] **Step 1: Read the installed skill body**

```bash
cat ~/.claude/plugins/cache/claude-plugins-official/superpowers/*/skills/subagent-driven-development/SKILL.md
```

- [ ] **Step 2: Check for prompt-construction requirements**

Look for:
- Any directive that the worker prompt must begin with a specific element (TodoWrite call, particular sentence, structured preamble).
- Any rule against prepending context paragraphs to worker prompts.
- Any explicit prompt template the dispatcher must use verbatim.

- [ ] **Step 3: Determine interaction outcome**

Three possible outcomes:

**A. No conflict.** The skill's prompt construction does not require a specific opening paragraph. The spec's "manifest as first paragraph" rule stands as written. Proceed.

**B. Compatible adjustment.** The skill requires e.g. a TodoWrite call early in the worker's response, but does not require it to be the *first paragraph of the prompt*. The manifest still works as the first paragraph; the skill's discipline applies to the worker's response. Proceed.

**C. Hard conflict.** The skill mandates a specific first paragraph that displaces the manifest. Stop. Open the design spec and update the manifest insertion rule (likely "immediately after the skill's required preamble, before the work assignment"). Re-run the spec's drift check expectations.

- [ ] **Step 4: Document the outcome**

If A or B, no spec change. If C, edit `docs/superpowers/specs/2026-04-30-opportunistic-skill-integration-design.md` to update the insertion rule and bump the canonical prelude version sentinel from `v1` to `v2` everywhere it appears in the plan below. Commit the spec update.

- [ ] **Step 5: No commit** if outcome is A or B; commit the spec update if outcome is C.

---

### Task 0.3: Audit existing command files for H2 placement compatibility

**Files:**
- Read: all 12 target command files

- [ ] **Step 1: List each file's structure**

```bash
for f in plugins/autocoder/commands/{brainstorm-issue,approve-proposal,fix,fix-loop}.md \
         plugins/modernize/commands/{plan,modernize}.md \
         .agent/workflows/{brainstorm-issue,approve-proposal,plan,modernize,fix,fix-loop}.md; do
  echo "=== $f ==="
  head -25 "$f"
done
```

- [ ] **Step 2: Identify the insertion point in each file**

For each file, the prelude must go as the first H2 (`## ...`) section in the body, immediately after any frontmatter / `<command-name>` tag / top-level title (`#`) / one-paragraph description.

Note any file where:
- The structure jumps directly from title to bullet points with no separating description paragraph (insertion may need a leading blank line + description sentence preserved).
- The file has no top-level `#` heading (rare; flag for case-by-case decision).
- The Antigravity mirror has a materially different structure than its Claude Code counterpart (insertion points may differ by file pair).

- [ ] **Step 3: Record per-file insertion-point notes**

Capture as a checklist for use in Phase 2 tasks. No code change yet.

- [ ] **Step 4: No commit** — research only.

---

## Phase 1: Canonical artifacts

### Task 1.1: Create the skills baseline file

**Files:**
- Create: `docs/superpowers/specs/2026-04-30-skills-baseline.txt`

- [ ] **Step 1: Inventory installed skill versions**

```bash
ls ~/.claude/plugins/cache/claude-plugins-official/superpowers/
ls ~/.claude/skills/ 2>/dev/null
ls ~/.claude/plugins/cache/*/skills/ 2>/dev/null | head -50
```

Note each skill's installed version. For superpowers skills, the version is the directory name (`5.0.7`). For personal toolkit skills, read the `version:` field from each `SKILL.md` if present.

- [ ] **Step 2: Write the baseline file**

```bash
cat > docs/superpowers/specs/2026-04-30-skills-baseline.txt <<'EOF'
# Skill versions installed at design time (2026-04-30).
# Format: <fully-qualified-name>=<version>
# Used by validation step 6 (skill contract drift check) for diff against future installs.

superpowers:brainstorming=5.0.7
superpowers:writing-plans=5.0.7
superpowers:executing-plans=5.0.7
superpowers:subagent-driven-development=5.0.7
superpowers:dispatching-parallel-agents=5.0.7
superpowers:using-git-worktrees=5.0.7
superpowers:verification-before-completion=5.0.7
superpowers:systematic-debugging=5.0.7
superpowers:test-driven-development=5.0.7
superpowers:requesting-code-review=5.0.7
superpowers:receiving-code-review=5.0.7
superpowers:finishing-a-development-branch=5.0.7
autocoder:improve-test-coverage=<version-from-plugin-json>
critical-design-review=1.4.0
critical-implementation-review=<version-from-skill-md>
update-design-doc=<version-from-skill-md>
update-implementation-plan=<version-from-skill-md>
arch-review=<version-from-skill-md>
security-review=<version-from-skill-md>
completion-review=<version-from-skill-md>
create-handoff=<version-from-skill-md>
EOF
```

Replace each `<version-from-...>` placeholder with the actual version read in Step 1. If a skill has no version field, use `unknown`.

- [ ] **Step 3: Verify file contents**

```bash
cat docs/superpowers/specs/2026-04-30-skills-baseline.txt
```

Expected: 21 entries, no remaining `<...>` placeholders.

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/specs/2026-04-30-skills-baseline.txt
git commit -m "Add skills baseline for opportunistic-skill-integration"
```

---

### Task 1.2: Create the canonical prelude file (Claude Code)

**Files:**
- Create: `plugins/shared/optional-skills-prelude.md`

- [ ] **Step 1: Ensure the directory exists**

```bash
mkdir -p plugins/shared
```

- [ ] **Step 2: Write the canonical prelude file**

Replace `<VERIFIED_URL>` with the URL from Task 0.1, and `<VERIFIED_INSTALL>` with the install command shape (e.g. `/plugin install superpowers@claude-plugins-official`).

```bash
cat > plugins/shared/optional-skills-prelude.md <<'EOF'
# Canonical Optional Skills Prelude

This file holds the canonical text embedded by sentinel into every command file that
participates in opportunistic skill integration. Drift between this file and the
embedded copies is detected by `scripts/check-optional-skills-drift.sh`.

## Boilerplate (embedded by every command file)

The block below — including the BEGIN/END sentinels — is copied byte-identically into
every target command file as the first H2 (`## Optional skill enhancements`) section
body. When updating, bump `v1` → `v2` everywhere simultaneously and regenerate all
embeddings.

<!-- BEGIN optional-skills-prelude v1 — keep in sync across all command files; see plugins/shared/optional-skills-prelude.md -->

If a named skill appears in your available skills list (delivered in the session-start system-reminder), invoke it via the `Skill` tool at the indicated step. Otherwise, follow the inline protocol below — it remains the source of truth and is unchanged by this section.

In Gemini CLI / Antigravity, skills activate via `activate_skill` instead of the `Skill` tool; the mapping is otherwise identical.

**Skill-name matching.** Match each table entry as an exact string. Mapping tables use fully-qualified names (`<plugin>:<skill>`) for plugin-installed skills and bare names for personal toolkit skills.

**Notation.** `A → B → C` means sequence (invoke in order). `A + B + C` means independent facets (all apply, order irrelevant). `A (primary)` means A is the orchestration spine. A leading `→` on a row indicates "next in sequence if applicable."

**Failure semantics.** Not-installed: silent fallback. Mid-run failure or interruption of an installed skill: surface the failure message, fall back to the inline protocol for the rest of that step, no retry. Self-skip (e.g., `<SUBAGENT-STOP>`): silent fallback, not treated as failure. If at least one `superpowers:*` skill named in this command's mapping table is missing from your available-skills list, emit one consolidated recommendation line at command entry: *Tip: this command works best with the `superpowers` plugin (<VERIFIED_URL>) — install via `<VERIFIED_INSTALL>`.* Never emit such notices for personal toolkit skills.

**Skills are advisory, not gating.** A command's completion criteria are defined by its inline protocol. Optional skill outcomes are surfaced and considered, but do not override inline success criteria. "Always applied" in a mapping table means the skill is invoked when installed; outcomes remain advisory. When a command claims success while an advisory skill earlier in the run surfaced a failure, the success summary acknowledges the advisory finding.

**Version trust.** Skills are matched by name; the integration does not pin or verify versions. If a tracked skill's contract changes in a way that breaks the chain, the integration is stale and must be updated.

<!-- END optional-skills-prelude v1 -->

## Worker skills manifest (referenced by dispatcher commands /fix-loop and /modernize)

The block below is prepended by dispatchers as the **first paragraph of each worker's
prompt**. The bullet list is generated at dispatch time as the intersection of the
dispatcher's available-skills list with the command's per-worker mapping.

<!-- BEGIN optional-skills-manifest v1 -->

The following optional skills are available in your environment. Match each name as an exact string against your available-skills list. If a skill is present, invoke it via the Skill tool at the indicated step; otherwise follow the inline protocol unchanged.

Skills available to this worker:
- <fully-qualified-name-1>
- <fully-qualified-name-2>
- ...

Failure semantics: silent fallback for not-installed; visible failure message for mid-run errors of installed skills; no retry within this run. Skills are advisory; your inline work contract still defines completion.

<!-- END optional-skills-manifest v1 -->
EOF
```

After writing, manually replace the two literal strings `<VERIFIED_URL>` and `<VERIFIED_INSTALL>` with the values from Task 0.1.

- [ ] **Step 3: Verify file**

```bash
grep -c "BEGIN optional-skills-prelude v1" plugins/shared/optional-skills-prelude.md
grep -c "END optional-skills-prelude v1" plugins/shared/optional-skills-prelude.md
grep -c "BEGIN optional-skills-manifest v1" plugins/shared/optional-skills-prelude.md
grep -c "END optional-skills-manifest v1" plugins/shared/optional-skills-prelude.md
grep -c "<VERIFIED_URL>" plugins/shared/optional-skills-prelude.md
grep -c "<VERIFIED_INSTALL>" plugins/shared/optional-skills-prelude.md
```

Expected: `1 1 1 1 0 0` (each sentinel appears once; no placeholders remain).

- [ ] **Step 4: Commit**

```bash
git add plugins/shared/optional-skills-prelude.md
git commit -m "Add canonical optional-skills prelude for Claude Code"
```

---

### Task 1.3: Create the canonical prelude file (Antigravity mirror)

**Files:**
- Create: `.agent/shared/optional-skills-prelude.md`

- [ ] **Step 1: Ensure the directory exists**

```bash
mkdir -p .agent/shared
```

- [ ] **Step 2: Copy the Claude Code canonical, then update the file-comment header**

```bash
cp plugins/shared/optional-skills-prelude.md .agent/shared/optional-skills-prelude.md
```

Edit the top-of-file header line (the H1 title and explanatory paragraph above the boilerplate sentinel) to mention `.agent/shared/optional-skills-prelude.md` rather than `plugins/shared/optional-skills-prelude.md`. **Do not** edit anything inside either sentinel pair — those must remain byte-identical to the Claude Code file.

- [ ] **Step 3: Verify boilerplate region is byte-identical to Claude Code**

```bash
diff <(awk '/BEGIN optional-skills-prelude v1/,/END optional-skills-prelude v1/' plugins/shared/optional-skills-prelude.md) \
     <(awk '/BEGIN optional-skills-prelude v1/,/END optional-skills-prelude v1/' .agent/shared/optional-skills-prelude.md)
```

Expected: no output (regions identical).

- [ ] **Step 4: Verify manifest region is byte-identical**

```bash
diff <(awk '/BEGIN optional-skills-manifest v1/,/END optional-skills-manifest v1/' plugins/shared/optional-skills-prelude.md) \
     <(awk '/BEGIN optional-skills-manifest v1/,/END optional-skills-manifest v1/' .agent/shared/optional-skills-prelude.md)
```

Expected: no output.

- [ ] **Step 5: Commit**

```bash
git add .agent/shared/optional-skills-prelude.md
git commit -m "Mirror canonical optional-skills prelude for Antigravity"
```

---

### Task 1.4: Create the drift-check script

**Files:**
- Create: `scripts/check-optional-skills-drift.sh`

- [ ] **Step 1: Write the script**

```bash
cat > scripts/check-optional-skills-drift.sh <<'EOF'
#!/usr/bin/env bash
# scripts/check-optional-skills-drift.sh
# Two-pass drift detector for opportunistic-skill-integration prelude blocks.
# Pass 1: boilerplate identical across all 12 command files + 2 canonical sources.
# Pass 2: per-command mapping identical between Claude Code and Antigravity mirrors.
# Exits non-zero on any drift or structural problem (CI-safe).
#
# Known limitation: Pass 2 verifies cross-platform parity, not correctness.
# A bug applied identically to both mirrors satisfies Pass 2.

set -euo pipefail
drift_seen=0

# --- Pass 1: boilerplate identical across all files ---
boilerplate_hashes=$(
  for f in plugins/shared/optional-skills-prelude.md \
           .agent/shared/optional-skills-prelude.md \
           plugins/*/commands/{brainstorm-issue,approve-proposal,plan,modernize,fix,fix-loop}.md \
           .agent/workflows/{brainstorm-issue,approve-proposal,plan,modernize,fix,fix-loop}.md; do
    [ -f "$f" ] || { echo "ERROR: missing file: $f" >&2; exit 1; }
    awk '/BEGIN optional-skills-prelude v1/,/END optional-skills-prelude v1/' "$f" | sha256sum
  done | sort -u
)
unique_count=$(echo "$boilerplate_hashes" | wc -l | tr -d ' ')
if [ "$unique_count" -ne 1 ]; then
  echo "ERROR: boilerplate hashes diverge across files ($unique_count distinct hashes)" >&2
  echo "$boilerplate_hashes" >&2
  drift_seen=1
else
  echo "boilerplate: OK (one hash across all files)"
fi

# --- Pass 2: per-command mapping identical between Claude/Antigravity mirrors ---
for cmd in brainstorm-issue approve-proposal plan modernize fix fix-loop; do
  matches=$(find plugins/*/commands -name "${cmd}.md")
  count=$(echo "$matches" | grep -c .)
  if [ "$count" -ne 1 ]; then
    echo "ERROR: ${cmd}.md matches ${count} files in plugins/*/commands (expected 1):" >&2
    echo "$matches" >&2
    exit 1
  fi
  cc_file="$matches"
  ag_file=".agent/workflows/${cmd}.md"
  [ -f "$ag_file" ] || { echo "ERROR: missing $ag_file" >&2; exit 1; }
  cc_hash=$(awk "/BEGIN optional-skills-mapping ${cmd} v1/,/END optional-skills-mapping ${cmd} v1/" "$cc_file" | sha256sum)
  ag_hash=$(awk "/BEGIN optional-skills-mapping ${cmd} v1/,/END optional-skills-mapping ${cmd} v1/" "$ag_file" | sha256sum)
  if [ "$cc_hash" = "$ag_hash" ]; then
    echo "${cmd}: OK"
  else
    echo "${cmd}: DRIFT" >&2
    drift_seen=1
  fi
done

exit "$drift_seen"
EOF
chmod +x scripts/check-optional-skills-drift.sh
```

- [ ] **Step 2: Run the script — expect failures**

```bash
./scripts/check-optional-skills-drift.sh; echo "exit=$?"
```

Expected: non-zero exit. Output mentions missing command files (none have been edited yet) — this is correct behavior. The script is meant to fail until all 12 command files have been edited.

- [ ] **Step 3: Smoke-test the multiple-match assertion**

Temporarily create a duplicate to verify the count assertion fires:

```bash
mkdir -p plugins/modernize/commands
touch plugins/modernize/commands/fix.md  # duplicate name
./scripts/check-optional-skills-drift.sh; echo "exit=$?"
rm plugins/modernize/commands/fix.md
```

Expected: non-zero exit; stderr says "fix.md matches 2 files in plugins/*/commands (expected 1)". Confirms the footgun guard works.

- [ ] **Step 4: Commit**

```bash
git add scripts/check-optional-skills-drift.sh
git commit -m "Add drift-check script for optional-skills prelude regions"
```

---

## Phase 2: Per-command implementation

Phase 2 has six tasks, one per command. Each task edits both mirrors and runs the drift script. The script will keep failing on Pass 1 (boilerplate must be present in *all* 12 files) until the last task. Pass 2 should succeed for the just-edited command after each task.

For each task, the workflow is:

1. **Identify the insertion point** in the Claude Code file using the audit notes from Task 0.3.
2. **Insert the boilerplate sentinel block** (copied verbatim from `plugins/shared/optional-skills-prelude.md`).
3. **Insert the per-command mapping sentinel block** (the table for that command, copied from the spec's "Per-command mappings" section).
4. **Mirror the same edits** into the Antigravity workflow file at the same insertion point.
5. **Run the drift script** — expect Pass 1 to fail (until all 12 are done), Pass 2 to succeed for this command.
6. **Commit**.

The boilerplate block to insert (verbatim — copy from `plugins/shared/optional-skills-prelude.md`):

```markdown
## Optional skill enhancements

<!-- BEGIN optional-skills-prelude v1 — keep in sync across all command files; see plugins/shared/optional-skills-prelude.md -->

If a named skill appears in your available skills list (delivered in the session-start system-reminder), invoke it via the `Skill` tool at the indicated step. Otherwise, follow the inline protocol below — it remains the source of truth and is unchanged by this section.

In Gemini CLI / Antigravity, skills activate via `activate_skill` instead of the `Skill` tool; the mapping is otherwise identical.

**Skill-name matching.** Match each table entry as an exact string. Mapping tables use fully-qualified names (`<plugin>:<skill>`) for plugin-installed skills and bare names for personal toolkit skills.

**Notation.** `A → B → C` means sequence (invoke in order). `A + B + C` means independent facets (all apply, order irrelevant). `A (primary)` means A is the orchestration spine. A leading `→` on a row indicates "next in sequence if applicable."

**Failure semantics.** Not-installed: silent fallback. Mid-run failure or interruption of an installed skill: surface the failure message, fall back to the inline protocol for the rest of that step, no retry. Self-skip (e.g., `<SUBAGENT-STOP>`): silent fallback, not treated as failure. If at least one `superpowers:*` skill named in this command's mapping table is missing from your available-skills list, emit one consolidated recommendation line at command entry: *Tip: this command works best with the `superpowers` plugin (<VERIFIED_URL>) — install via `<VERIFIED_INSTALL>`.* Never emit such notices for personal toolkit skills.

**Skills are advisory, not gating.** A command's completion criteria are defined by its inline protocol. Optional skill outcomes are surfaced and considered, but do not override inline success criteria. "Always applied" in a mapping table means the skill is invoked when installed; outcomes remain advisory. When a command claims success while an advisory skill earlier in the run surfaced a failure, the success summary acknowledges the advisory finding.

**Version trust.** Skills are matched by name; the integration does not pin or verify versions. If a tracked skill's contract changes in a way that breaks the chain, the integration is stale and must be updated.

<!-- END optional-skills-prelude v1 -->
```

The per-command mapping block follows immediately, between `<!-- BEGIN optional-skills-mapping <command> v1 -->` and `<!-- END optional-skills-mapping <command> v1 -->` sentinels. Each task gives the exact mapping content.

---

### Task 2.1: `/brainstorm-issue` — both platforms

**Files:**
- Modify: `plugins/autocoder/commands/brainstorm-issue.md`
- Modify: `.agent/workflows/brainstorm-issue.md`

- [ ] **Step 1: Insert prelude into the Claude Code file**

Open `plugins/autocoder/commands/brainstorm-issue.md`. Locate the first existing H2 section. Insert the boilerplate block (above) as a new H2 immediately before it. Then immediately after the closing boilerplate sentinel, insert:

```markdown

<!-- BEGIN optional-skills-mapping brainstorm-issue v1 — keep in sync between Claude/Antigravity mirrors of this command -->

| Step | Skill mapping |
|---|---|
| Design exploration / requirements dialogue | `superpowers:brainstorming` |
| Self-review of written spec → apply review findings | `critical-design-review` → `update-design-doc` |

<!-- END optional-skills-mapping brainstorm-issue v1 -->

```

(Note the leading and trailing blank lines around the sentinel block.)

- [ ] **Step 2: Mirror into the Antigravity file**

Open `.agent/workflows/brainstorm-issue.md`. Locate the equivalent insertion point. Insert both the boilerplate sentinel block and the same `optional-skills-mapping brainstorm-issue v1` block, byte-identical to what was inserted in the Claude Code file.

- [ ] **Step 3: Verify the mapping regions are byte-identical**

```bash
diff <(awk '/BEGIN optional-skills-mapping brainstorm-issue v1/,/END optional-skills-mapping brainstorm-issue v1/' plugins/autocoder/commands/brainstorm-issue.md) \
     <(awk '/BEGIN optional-skills-mapping brainstorm-issue v1/,/END optional-skills-mapping brainstorm-issue v1/' .agent/workflows/brainstorm-issue.md)
```

Expected: no output.

- [ ] **Step 4: Run the drift script**

```bash
./scripts/check-optional-skills-drift.sh; echo "exit=$?"
```

Expected: non-zero (Pass 1 fails until all 12 files have boilerplate). For Pass 2, the line `brainstorm-issue: OK` should appear; lines for other commands should report missing files or DRIFT.

- [ ] **Step 5: Commit**

```bash
git add plugins/autocoder/commands/brainstorm-issue.md .agent/workflows/brainstorm-issue.md
git commit -m "Wire opportunistic skills into /brainstorm-issue"
```

---

### Task 2.2: `/approve-proposal` — both platforms

**Files:**
- Modify: `plugins/autocoder/commands/approve-proposal.md`
- Modify: `.agent/workflows/approve-proposal.md`

Mapping block content for this command:

```markdown

<!-- BEGIN optional-skills-mapping approve-proposal v1 — keep in sync between Claude/Antigravity mirrors of this command -->

| Step | Skill mapping |
|---|---|
| Critical design review of the proposal | `critical-design-review` (always for non-trivial proposals) |
| Architectural soundness check | `→ arch-review` (only if the proposal introduces or changes architectural patterns, module boundaries, or technology choices) |
| Security implications | `→ security-review` (only if the proposal touches authentication, authorization, data handling, external interfaces, secret storage, or dependencies) |

<!-- END optional-skills-mapping approve-proposal v1 -->

```

- [ ] **Step 1: Insert prelude + mapping into Claude Code file** (same procedure as Task 2.1).
- [ ] **Step 2: Mirror into Antigravity file**.
- [ ] **Step 3: Verify mapping regions byte-identical**:

```bash
diff <(awk '/BEGIN optional-skills-mapping approve-proposal v1/,/END optional-skills-mapping approve-proposal v1/' plugins/autocoder/commands/approve-proposal.md) \
     <(awk '/BEGIN optional-skills-mapping approve-proposal v1/,/END optional-skills-mapping approve-proposal v1/' .agent/workflows/approve-proposal.md)
```

- [ ] **Step 4: Run drift script**: `./scripts/check-optional-skills-drift.sh`; expect `approve-proposal: OK`.
- [ ] **Step 5: Commit**:

```bash
git add plugins/autocoder/commands/approve-proposal.md .agent/workflows/approve-proposal.md
git commit -m "Wire opportunistic skills into /approve-proposal"
```

---

### Task 2.3: `/plan` — both platforms

**Files:**
- Modify: `plugins/modernize/commands/plan.md`
- Modify: `.agent/workflows/plan.md`

Mapping block content:

```markdown

<!-- BEGIN optional-skills-mapping plan v1 — keep in sync between Claude/Antigravity mirrors of this command -->

| Step | Skill mapping |
|---|---|
| Turn spec into implementation plan → review the produced plan → apply review findings | `superpowers:writing-plans` → `critical-implementation-review` → `update-implementation-plan` |

<!-- END optional-skills-mapping plan v1 -->

```

- [ ] **Step 1: Insert prelude + mapping into Claude Code file**.
- [ ] **Step 2: Mirror into Antigravity file**.
- [ ] **Step 3: Verify mapping regions byte-identical** (substitute `plan` for `approve-proposal` in the diff command).
- [ ] **Step 4: Run drift script**; expect `plan: OK`.
- [ ] **Step 5: Commit**:

```bash
git add plugins/modernize/commands/plan.md .agent/workflows/plan.md
git commit -m "Wire opportunistic skills into /plan"
```

---

### Task 2.4: `/modernize` — both platforms (dispatcher; references manifest)

**Files:**
- Modify: `plugins/modernize/commands/modernize.md`
- Modify: `.agent/workflows/modernize.md`

Mapping block content (note the manifest cross-reference at the bottom):

```markdown

<!-- BEGIN optional-skills-mapping modernize v1 — keep in sync between Claude/Antigravity mirrors of this command -->

| Step | Skill mapping |
|---|---|
| Execute PLAN.md phase-by-phase with checkpoints | `superpowers:executing-plans` (primary) |
| Dispatch coder/tester/etc. agents | `superpowers:subagent-driven-development` + `superpowers:dispatching-parallel-agents` (when 2+ independent worker tasks) |
| Isolate per-stage work | `superpowers:using-git-worktrees` (independent facet) |
| Verify before declaring a phase complete | `superpowers:verification-before-completion` (independent facet) |
| Per-phase wrap-up | `completion-review` |
| Hand off project state | `create-handoff` (invoke at one of: end of each completed phase as part of phase wrap-up; ~30 tool calls without a phase boundary — heuristic, adjust based on observed context pressure in early runs; or explicit user signal) |

**Worker dispatch.** When dispatching coder/tester/etc. agents, prepend the `optional-skills-manifest v1` block (held in `plugins/shared/optional-skills-prelude.md` / `.agent/shared/optional-skills-prelude.md`) as the **first paragraph** of each worker's prompt. Generate the bullet list as the intersection of your available skills × the per-worker mapping for the agent role being dispatched (per-worker mappings appear in the agent files when agent-level integration is taken up; for now, include `superpowers:test-driven-development`, `superpowers:systematic-debugging`, `superpowers:verification-before-completion`, `superpowers:using-git-worktrees`, `superpowers:finishing-a-development-branch` as the candidate set for code-producing workers).

<!-- END optional-skills-mapping modernize v1 -->

```

- [ ] **Step 1: Insert prelude + mapping into Claude Code file**.
- [ ] **Step 2: Mirror into Antigravity file**.
- [ ] **Step 3: Verify mapping regions byte-identical**.
- [ ] **Step 4: Run drift script**; expect `modernize: OK`.
- [ ] **Step 5: Commit**:

```bash
git add plugins/modernize/commands/modernize.md .agent/workflows/modernize.md
git commit -m "Wire opportunistic skills into /modernize (dispatcher with manifest reference)"
```

---

### Task 2.5: `/fix` — both platforms

**Files:**
- Modify: `plugins/autocoder/commands/fix.md`
- Modify: `.agent/workflows/fix.md`

Mapping block content (this is the largest mapping — three stacked tables plus composition rule):

```markdown

<!-- BEGIN optional-skills-mapping fix v1 — keep in sync between Claude/Antigravity mirrors of this command -->

`/fix` accepts heterogeneous work — bug fixes, feature implementation, refactoring, increasing test coverage, docs/config/chore, or proposing new tasks. The agent classifies the work after reading the issue and applies the matching skills along two axes: deliverable type and kind of work.

**Composition rule.** Step 2 and Step 3 compose by **union**: apply every skill named in either step. Where both steps name the same skill, apply it once. Where the two steps disagree on whether a skill is required vs. optional, the **stronger requirement wins** (a skill marked required in one step is required overall). Step 1 (deliverable classification) is purely a routing input to Step 2 and produces no skills of its own.

**Ordering across steps.** When Step 3 contributes a sequence (`A → B → C`), that sequence defines the spine. Step 2 facets attach at conventional points:
- **Provisioning facets** (e.g., `superpowers:using-git-worktrees`) attach at spine entry — before the first sequence step runs.
- **Verification facets** (e.g., `superpowers:verification-before-completion`) attach at spine exit — after the last sequence step.
- **Wrap-up facets** (e.g., `completion-review`, `superpowers:requesting-code-review` → `superpowers:receiving-code-review`) attach after spine exit and after verification.

Where Step 3 contributes only a single skill or no sequence, treat it as a one-step spine and apply the same attachment points. Where a facet has no obvious attachment category, attach at spine exit.

**Step 1: classify the deliverable.**

| Deliverable type | Examples |
|---|---|
| **Branch** (code merged to main) | bug fix, new feature, refactor, increasing test coverage, docs/config/chore committed to the repo |
| **Document** (proposal, report, analysis) | proposing new tasks, investigation findings |
| **Throwaway** (spike, experiment) | rare; ad-hoc evaluation work that won't be merged |

**Step 2: apply the matching skills based on deliverable type.** "Always" below means the skill is invoked when installed; outcomes remain advisory.

| Applies when deliverable is... | Skill mapping |
|---|---|
| **Branch** | `superpowers:using-git-worktrees` + `superpowers:verification-before-completion` + `completion-review` (always); `superpowers:requesting-code-review` → `superpowers:receiving-code-review` (when seeking merge) |
| **Document** | `completion-review` only |
| **Throwaway** | none of the above are required |

**Step 3: apply the matching skills based on kind of work.**

| If the work is... | Use these skills |
|---|---|
| Bug / unexpected behavior | `superpowers:systematic-debugging` → `superpowers:test-driven-development` |
| New feature / unclear requirement | `superpowers:brainstorming` → `superpowers:writing-plans` → `superpowers:test-driven-development` (optional `critical-design-review` after brainstorming, `critical-implementation-review` after writing-plans) |
| Refactor / restructuring | `superpowers:test-driven-development` (characterization tests) → refactor under green |
| Increasing test coverage | `autocoder:improve-test-coverage` → `superpowers:test-driven-development` for new tests |
| Proposing new tasks | `superpowers:brainstorming` → `critical-design-review` |
| Docs / config / chore | TDD optional |

<!-- END optional-skills-mapping fix v1 -->

```

- [ ] **Step 1: Insert prelude + mapping into Claude Code file**.
- [ ] **Step 2: Mirror into Antigravity file**.
- [ ] **Step 3: Verify mapping regions byte-identical**.
- [ ] **Step 4: Run drift script**; expect `fix: OK`.
- [ ] **Step 5: Commit**:

```bash
git add plugins/autocoder/commands/fix.md .agent/workflows/fix.md
git commit -m "Wire opportunistic skills into /fix"
```

---

### Task 2.6: `/fix-loop` — both platforms (dispatcher; references manifest)

**Files:**
- Modify: `plugins/autocoder/commands/fix-loop.md`
- Modify: `.agent/workflows/fix-loop.md`

Mapping block content:

```markdown

<!-- BEGIN optional-skills-mapping fix-loop v1 — keep in sync between Claude/Antigravity mirrors of this command -->

`/fix-loop` is a dispatcher coordinating parallel workers. The dispatcher and workers have distinct skill mappings.

**Dispatcher level (runs in the host workspace, not a worktree).**

| Step | Skill mapping |
|---|---|
| Plan and dispatch parallel workers | `superpowers:subagent-driven-development` + `superpowers:dispatching-parallel-agents` |
| Provision isolated worktrees for workers | `superpowers:using-git-worktrees` (for workers only; dispatcher runs in host workspace) |

**Per-worker level** (each worker in its own worktree; workers receive the dispatcher's manifest and apply the full `/fix` mapping above to their assigned issue, including the same composition rule and ordering-across-steps rule), plus:

| Step | Skill mapping |
|---|---|
| Each worker finishes its branch (PR / merge) | `superpowers:finishing-a-development-branch` |

**Worker dispatch.** Prepend the `optional-skills-manifest v1` block (from `plugins/shared/optional-skills-prelude.md` / `.agent/shared/optional-skills-prelude.md`) as the **first paragraph** of each worker's prompt. Generate the bullet list as the intersection of your available skills × the per-worker skill set: `superpowers:systematic-debugging`, `superpowers:test-driven-development`, `superpowers:using-git-worktrees`, `superpowers:verification-before-completion`, `superpowers:requesting-code-review`, `superpowers:receiving-code-review`, `superpowers:finishing-a-development-branch`, `superpowers:brainstorming`, `superpowers:writing-plans`, `autocoder:improve-test-coverage`, `critical-design-review`, `critical-implementation-review`, `completion-review`.

<!-- END optional-skills-mapping fix-loop v1 -->

```

- [ ] **Step 1: Insert prelude + mapping into Claude Code file**.
- [ ] **Step 2: Mirror into Antigravity file**.
- [ ] **Step 3: Verify mapping regions byte-identical**.
- [ ] **Step 4: Run drift script — this is the last command, expect full success**:

```bash
./scripts/check-optional-skills-drift.sh; echo "exit=$?"
```

Expected: exit 0. Output:
```
boilerplate: OK (one hash across all files)
brainstorm-issue: OK
approve-proposal: OK
plan: OK
modernize: OK
fix: OK
fix-loop: OK
```

If any line shows `DRIFT` or the boilerplate fails, return to the relevant Phase 2 task and fix.

- [ ] **Step 5: Commit**:

```bash
git add plugins/autocoder/commands/fix-loop.md .agent/workflows/fix-loop.md
git commit -m "Wire opportunistic skills into /fix-loop (dispatcher with manifest reference)"
```

---

## Phase 3: Validation

### Task 3.1: Run all six commands in degraded mode

**Files:**
- No file changes — runtime validation only.

- [ ] **Step 1: Confirm a degraded environment**

Either run in a fresh Claude Code instance with no plugins beyond core, or temporarily move any installed `superpowers/` and personal-toolkit skill directories aside:

```bash
# Optional: simulate "no skills installed" by hiding the cache
# mv ~/.claude/plugins/cache/claude-plugins-official/superpowers /tmp/superpowers-stash
# mv ~/.claude/skills /tmp/skills-stash
# Restore after test:
# mv /tmp/superpowers-stash ~/.claude/plugins/cache/claude-plugins-official/superpowers
# mv /tmp/skills-stash ~/.claude/skills
```

Or: validate by running in an environment where you confirm ahead of time that the relevant skills are not installed.

- [ ] **Step 2: For each command, run with a trivial input and observe output**

For each of `/brainstorm-issue`, `/approve-proposal`, `/plan`, `/modernize`, `/fix`, `/fix-loop`:

(a) Confirm the command completes via its inline protocol (no skill invocations).
(b) Confirm exactly one consolidated recommendation line appears at command entry pointing to the public superpowers plugin (only for commands that reference any `superpowers:*` skill in their mapping — all six in this scope).
(c) Confirm no error or failure messages appear from missing skills.
(d) Compare output against the pre-integration command behavior — should be functionally identical.

- [ ] **Step 3: Note any discrepancies**

If any command emits more than one recommendation line, or emits recommendations for personal toolkit skills, or behaves differently than pre-integration: open a follow-up issue and stop. Otherwise, document the validation pass.

- [ ] **Step 4: No commit** — runtime validation only.

---

### Task 3.2: Run all six commands in enhanced mode

**Files:**
- No file changes — runtime validation only.

- [ ] **Step 1: Confirm all skills are installed**

```bash
ls ~/.claude/plugins/cache/claude-plugins-official/superpowers/
ls ~/.claude/skills/ 2>/dev/null  # verify personal toolkit skills present
```

- [ ] **Step 2: For each command, run with a trivial input and observe**

(a) Confirm at least one optional skill fires per command (where applicable).
(b) Manually deny one Skill tool call mid-run; confirm the failure surfaces visibly and the command continues with the inline fallback.
(c) Confirm any visible advisory failure is acknowledged in the command's success summary.

- [ ] **Step 3: No commit**.

---

### Task 3.3: Manifest end-to-end check (dispatcher commands)

**Files:**
- No file changes — runtime validation only.

- [ ] **Step 1: Run `/fix-loop` with a trivial work assignment**

Use a low-priority issue or a deliberately small fix that should produce a single worker. Observe the worker's behavior.

- [ ] **Step 2: Confirm a per-worker-only skill fires**

For `/fix-loop`, the per-worker-only skill is `superpowers:finishing-a-development-branch`. Confirm it is invoked by the worker (either visible in tool-call output or in the resulting branch's PR creation).

If `superpowers:finishing-a-development-branch` does not fire and there is a finishable branch, the manifest plumbing is suspect — return to Task 2.6 and re-verify the manifest cross-reference text.

- [ ] **Step 3: Run `/modernize` with a trivial assignment**

Use the smallest possible PLAN.md (one phase, one task) to exercise dispatcher → worker plumbing without burning hours.

- [ ] **Step 4: Confirm a per-worker-only skill fires**

For `/modernize`, watch for a coder/tester worker invoking `superpowers:test-driven-development` or `superpowers:systematic-debugging` — skills that appear in the per-worker manifest but not in the dispatcher mapping.

- [ ] **Step 5: No commit**.

---

### Task 3.4: Drift sanity check

**Files:**
- No file changes — script behavior only.

- [ ] **Step 1: Modify a canonical and run the script**

```bash
# Make a deliberate one-character edit in the canonical
sed -i.bak 's/silent fallback/silent fall-back/' plugins/shared/optional-skills-prelude.md
./scripts/check-optional-skills-drift.sh; echo "exit=$?"
mv plugins/shared/optional-skills-prelude.md.bak plugins/shared/optional-skills-prelude.md
```

Expected: non-zero exit. Output mentions boilerplate hash divergence.

- [ ] **Step 2: Modify one Claude/Antigravity mirror only and run**

```bash
sed -i.bak 's/Bug \/ unexpected behavior/Bug or unexpected behavior/' plugins/autocoder/commands/fix.md
./scripts/check-optional-skills-drift.sh; echo "exit=$?"
mv plugins/autocoder/commands/fix.md.bak plugins/autocoder/commands/fix.md
```

Expected: non-zero exit. Output says `fix: DRIFT`.

- [ ] **Step 3: Confirm script returns to clean**

```bash
./scripts/check-optional-skills-drift.sh; echo "exit=$?"
```

Expected: exit 0, all OK.

- [ ] **Step 4: No commit**.

---

## Phase 4: Wrap-up

### Task 4.1: Bump plugin and marketplace versions

**Files:**
- Modify: `.claude-plugin/marketplace.json` (or wherever plugin/marketplace versions live in this repo)
- Modify: `plugins/autocoder/.claude-plugin/plugin.json` (autocoder plugin version)
- Modify: `plugins/modernize/.claude-plugin/plugin.json` (modernize plugin version)

Per CLAUDE.md, both individual plugin versions and the root marketplace version must be bumped. This change is a minor version bump (additive feature, no breaking change).

- [ ] **Step 1: Read current versions**

```bash
cat .claude-plugin/marketplace.json | head -30
cat plugins/autocoder/.claude-plugin/plugin.json 2>/dev/null
cat plugins/modernize/.claude-plugin/plugin.json 2>/dev/null
```

- [ ] **Step 2: Bump autocoder plugin minor version**

Increment the `version` field in `plugins/autocoder/.claude-plugin/plugin.json` (e.g., `3.5.0` → `3.6.0`) and the matching entry in `.claude-plugin/marketplace.json` under `plugins[]`.

- [ ] **Step 3: Bump modernize plugin minor version**

Increment the `version` field in `plugins/modernize/.claude-plugin/plugin.json` (e.g., `0.2.0` → `0.3.0`) and the matching entry in `.claude-plugin/marketplace.json`.

- [ ] **Step 4: Bump marketplace root version**

Increment the root `version` field in `.claude-plugin/marketplace.json`.

- [ ] **Step 5: Commit**:

```bash
git add .claude-plugin/marketplace.json plugins/autocoder/.claude-plugin/plugin.json plugins/modernize/.claude-plugin/plugin.json
git commit -m "Bump autocoder, modernize, and marketplace versions for opportunistic-skill-integration"
```

---

### Task 4.2: Final drift run + smoke confirmation

**Files:**
- No file changes.

- [ ] **Step 1: Run the drift script one more time**

```bash
./scripts/check-optional-skills-drift.sh; echo "exit=$?"
```

Expected: exit 0. All boilerplate identical; all six command mappings OK.

- [ ] **Step 2: Confirm Phase 3 validations were recorded**

In your notes, confirm:
- Task 3.1 (degraded mode): all six commands behaved per pre-integration baseline; one recommendation line per `superpowers:*`-referencing command.
- Task 3.2 (enhanced mode): at least one optional skill fired per command; manual denial surfaced visibly.
- Task 3.3 (manifest end-to-end): per-worker-only skill fired in both `/fix-loop` and `/modernize`.
- Task 3.4 (drift sanity): canonical edit and one-sided edit each detected.

- [ ] **Step 3: No additional commit** — Tasks 0–4.1 produced all the commits this rollout needs.

---

## Rollout summary

When all tasks pass, the repository contains:
- 4 new files (canonical preludes ×2, baseline, drift script)
- 12 modified command files (each with two new sentinel-bracketed regions as the first H2)
- Bumped autocoder, modernize, and marketplace versions

Each command now opportunistically uses `superpowers:*` and personal toolkit skills when installed. When skills are absent, commands fall back silently to their unchanged inline protocols, with a single up-front recommendation line for `superpowers:*` skills only.

The drift script (`scripts/check-optional-skills-drift.sh`) catches one-sided drift between Claude Code and Antigravity mirrors and is wireable as a pre-commit hook or CI check (exits non-zero on any drift).

No external skill content is copied into this repo — the integration references skills by name only.
