#!/bin/bash
# tests/test_optional_skills_semantics.sh — guards what the drift check cannot.
#
# WHY THIS EXISTS:
#   scripts/check-optional-skills-drift.sh proves the optional-skills blocks are
#   byte-identical across 16 files and both platform mirrors. It says nothing
#   about whether they are CORRECT. Every one of these defects shipped with a
#   fully green drift run, and was caught only by human/agent review:
#
#     - `completion-review` was routed to `ce-code-review`, pointing a diff
#       reviewer at /retro's markdown report.
#     - `ce-work` was substituted bare, so it owned its own shipping tail and
#       bypassed the branch-finishing and Merge Mode exclusions that the very
#       same section declares.
#     - Worker dispatch lists named CE skills bare (`ce-plan`) while the manifest
#       instructs exact-string matching against a list where Claude Code shows
#       them qualified (`compound-engineering:ce-plan`) — so six of seven were
#       silently dropped from every worker prompt.
#     - The manifest asserted role precedence without shipping the role
#       pairings, and workers never see the prelude's table.
#
#   Each assertion below pins one of those. This is a semantic guard, not a
#   parity guard; run it alongside the drift check, not instead of it.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
cd "$ROOT" || exit 1

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

CANON="plugins/shared/optional-skills-prelude.md"
PRELUDE="$(awk '/BEGIN optional-skills-prelude v[0-9]+/,/END optional-skills-prelude v[0-9]+/' "$CANON")"
MANIFEST="$(awk '/BEGIN optional-skills-manifest v[0-9]+/,/END optional-skills-manifest v[0-9]+/' "$CANON")"

[ -n "$PRELUDE" ] || { echo "FAIL: no prelude block in $CANON"; exit 1; }
[ -n "$MANIFEST" ] || { echo "FAIL: no manifest block in $CANON"; exit 1; }

# The precedence table's "In place of" column. Everything the table claims to
# replace must be a skill some mapping table actually names, or the row is dead.
PRECEDENCE_TABLE="$(echo "$PRELUDE" | grep '^| ' | grep -v '^|---' | grep -v 'Use when installed')"

# ── Skills that must NEVER be substituted ─────────────────────────────────
# Substituting any of these re-introduces a defect the review caught.
for skill in "completion-review" "superpowers:using-git-worktrees" "superpowers:finishing-a-development-branch"; do
  if echo "$PRECEDENCE_TABLE" | grep -q "\`$skill\`"; then
    bad "$skill appears in the precedence table — it must never be substituted"
  else
    ok "$skill is not substituted"
  fi
done

# ── ce-work must never be substituted bare ────────────────────────────────
# Bare ce-work owns its shipping tail: commit, push, PR. That bypasses the
# inline protocol's worktree naming, issue-claim sequence, and Merge Mode.
if echo "$PRECEDENCE_TABLE" | grep 'ce-work' | grep -q 'mode:return-to-caller'; then
  ok "ce-work row requires mode:return-to-caller"
else
  bad "ce-work is substituted without mode:return-to-caller — it would own the shipping tail"
fi

# ── The exclusions must name the CE skills, not just the superpowers ones ──
# "superpowers:using-git-worktrees is not substituted" does not tell an agent
# holding ce-worktree that ce-worktree is the thing not to reach for.
for ce in "ce-worktree" "ce-commit-push-pr"; do
  if echo "$PRELUDE" | grep -q "$ce"; then
    ok "exclusion names $ce explicitly"
  else
    bad "exclusion never names $ce — an agent holding it has no instruction"
  fi
done

# ── Worker dispatch lists must fully qualify every CE name ────────────────
# The manifest instructs exact-string matching; Claude Code lists CE skills
# qualified, so a bare name matches nothing on the platform CE ships to most.
for f in plugins/autocoder/commands/fix-loop.md .agent/workflows/fix-loop.md \
         plugins/modernize/commands/modernize.md .agent/workflows/modernize.md; do
  dispatch="$(grep -F 'Worker dispatch' "$f")"
  # Find ce-* names in the dispatch paragraph that are NOT preceded by the
  # plugin prefix. `[^-]` avoids matching the tail of compound-engineering:ce-x.
  unqualified="$(echo "$dispatch" | grep -oE '`ce-[a-z-]+`' || true)"
  if [ -n "$unqualified" ]; then
    bad "$f dispatch list has unqualified CE names: $(echo "$unqualified" | tr '\n' ' ')"
  else
    ok "$f dispatch list fully qualifies CE names"
  fi
done

# ── The manifest must carry the role pairings, not just the rule ──────────
# Dispatched workers receive the manifest and never the prelude. Without the
# pairings they cannot derive ce-work <-> executing-plans from names alone.
for pair in "ce-brainstorm" "ce-plan" "ce-work" "ce-debug" "ce-doc-review" "ce-code-review" "ce-resolve-pr-feedback"; do
  if echo "$MANIFEST" | grep -q "$pair"; then
    ok "manifest names $pair"
  else
    bad "manifest omits $pair — workers cannot apply precedence for it"
  fi
done

if echo "$MANIFEST" | grep -q "replaces"; then
  ok "manifest states what each CE skill replaces"
else
  bad "manifest asserts precedence without saying what is replaced"
fi

# ── pstack orchestrators must never be substituted or entered ─────────────
# Each owns a playbook, dispatch loop, implementation phase, or PR tail. As a
# substitution they would bypass worktree naming, the issue-claim sequence, and
# Merge Mode exactly as bare ce-work did. architect is here because its Phase B
# runs arena and its default Phase C implements with no checkpoint.
ORCHESTRATORS="poteto-mode figure-it-out swarm arena architect babysit make-pr-easy-to-review"
for name in $ORCHESTRATORS; do
  skill="pstack:$name"
  if echo "$PRECEDENCE_TABLE" | grep -q "\`$skill\`"; then
    bad "$skill appears in the precedence table — pstack orchestrators must never be substituted"
  else
    ok "$skill is not substituted"
  fi
  for block in PRELUDE MANIFEST; do
    if echo "${!block}" | grep -q "\`$skill\`"; then
      ok "$block excludes $skill by name"
    else
      bad "$block never names $skill — an agent holding it has no instruction not to enter it"
    fi
  done
done

# ── No mapping block, on any platform, may route into an orchestrator ─────
orch_fail_before=$FAIL
# The precedence-table check above cannot see a per-command row such as
# "Feature | pstack:architect". architect was mapped into /plan and
# /brainstorm-issue this way, where it would have written and committed code.
for f in plugins/*/commands/*.md .agent/workflows/*.md .pi/prompts/*.md; do
  mapping="$(awk '/BEGIN optional-skills-mapping/,/END optional-skills-mapping/' "$f")"
  [ -n "$mapping" ] || continue
  for name in $ORCHESTRATORS; do
    if echo "$mapping" | grep -q "\`pstack:$name\`"; then
      bad "$f mapping block routes into orchestrator pstack:$name"
    fi
  done
done
[ "$FAIL" -eq "$orch_fail_before" ] && ok "no mapping block routes into a pstack orchestrator"

# ── pstack:tdd is a bug regression-test skill, not general TDD ────────────
# Its description says "use only when ... a regression test"; its guardrails
# forbid coverage expansion. Substituting it for superpowers TDD globally would
# land it on the feature, refactor, and coverage rows it contradicts.
if echo "$PRECEDENCE_TABLE" | grep -q '`pstack:tdd`'; then
  bad "pstack:tdd is in the precedence table — it would replace TDD on non-bug rows"
else
  ok "pstack:tdd is not globally substituted"
fi
FIX_MAP="$(awk '/BEGIN optional-skills-mapping fix /,/END optional-skills-mapping fix /' plugins/autocoder/commands/fix.md)"
if [ "$(echo "$FIX_MAP" | grep -c '`pstack:tdd`')" -eq 1 ] && echo "$FIX_MAP" | grep '`pstack:tdd`' | grep -q '^| Bug'; then
  ok "/fix names pstack:tdd on the Bug row only"
else
  bad "/fix names pstack:tdd somewhere other than the Bug row"
fi

# ── deslop edits code, so verification must follow it ─────────────────────
if echo "$FIX_MAP" | grep '^| \*\*Branch\*\* | ' | grep -q '`pstack:deslop` → `superpowers:verification-before-completion`'; then
  ok "/fix runs deslop before verification"
else
  bad "/fix does not order deslop before verification — committed code could be unverified"
fi
if echo "$FIX_MAP" | grep -q 'INTEGRATION_BRANCH'; then
  ok "/fix scopes deslop to the integration branch, not main"
else
  bad "/fix leaves deslop diffing against its hard-coded main"
fi

# ── pstack's SessionStart routing must be explicitly overridden ───────────
# The hook injects "invoke poteto-mode for multi-file tasks" at startup and
# after every compaction. Nearly every /fix task is multi-file.
for block in PRELUDE MANIFEST; do
  if echo "${!block}" | grep -qiE "pstack's (SessionStart|session-start)" && echo "${!block}" | grep -qi "compaction"; then
    ok "$block overrides pstack's SessionStart routing, including after compaction"
  else
    bad "$block does not override pstack's SessionStart routing through compaction"
  fi
done
if echo "$PRELUDE" | grep -q 'session hook: off'; then
  ok "prelude names pstack's structural off switch"
else
  bad "prelude relies on text alone to beat the SessionStart hook"
fi

# ── Bare pstack names need a provenance marker ────────────────────────────
# Bare tdd/how would otherwise match any personal skill of that name and hand
# it precedence over Compound Engineering and superpowers.
if echo "$PRELUDE" | grep -q 'bare `poteto-mode`' && echo "$MANIFEST" | grep -q 'bare `poteto-mode`'; then
  ok "bare pstack names require the poteto-mode marker"
else
  bad "bare pstack names are matched without a provenance marker"
fi

# ── The manifest must carry the pstack pairing, not just the rule ─────────
if echo "$MANIFEST" | grep -q '`pstack:interrogate` replaces'; then
  ok "manifest states what pstack:interrogate replaces"
else
  bad "manifest omits what pstack:interrogate replaces — workers cannot apply pstack precedence"
fi

# ── Worker dispatch lists must fully qualify every pstack name ────────────
for f in plugins/autocoder/commands/fix-loop.md .agent/workflows/fix-loop.md \
         plugins/modernize/commands/modernize.md .agent/workflows/modernize.md; do
  dispatch="$(grep -F 'Worker dispatch' "$f")"
  if ! echo "$dispatch" | grep -q '`pstack:'; then
    bad "$f dispatch list names no pstack skills"
    continue
  fi
  bare="$(echo "$dispatch" | grep -oE '`(tdd|interrogate|how|why|architect|deslop|blast-radius|unslop)`' || true)"
  if [ -n "$bare" ]; then
    bad "$f dispatch list has unqualified pstack names: $(echo "$bare" | tr '\n' ' ')"
  else
    ok "$f dispatch list fully qualifies pstack names"
  fi
done

# ── .pi prompt copies must match the plugin blocks ────────────────────────
# The drift check discovers only plugins/ and .agent/; .pi/prompts embeds the
# same blocks and would otherwise diverge silently on the next bump.
for f in .pi/prompts/*.md; do
  base="$(basename "$f")"
  src="$(ls plugins/*/commands/"$base" 2>/dev/null | head -1)"
  [ -n "$src" ] || continue
  blocks() { awk '/BEGIN optional-skills-(prelude|mapping)/,/END optional-skills-(prelude|mapping)/' "$1"; }
  [ -n "$(blocks "$f")" ] || continue
  if [ "$(blocks "$f")" = "$(blocks "$src")" ]; then
    ok "$f optional-skills blocks match $src"
  else
    bad "$f optional-skills blocks drifted from $src"
  fi
done

# ── Every pstack skill named anywhere must exist upstream ─────────────────
# Names are matched as exact strings; a typo is a silent no-op forever. Prefer
# the installed plugin's tree when present so an upstream rename is caught.
PSTACK_SKILLS="architect arena automate-me babysit blast-radius bro create-verification-skill deslop figure-it-out fix-ci fix-merge-conflicts get-pr-comments how interrogate maintain-verification-skill make-pr-easy-to-review no-comments poteto-mode recall reflect setup-pstack show-me-your-work swarm tdd teach technical-writing thermo-nuclear-code-quality-review typescript-best-practices unslop what-did-i-get-done why"
cache="$(ls -d "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/plugins/cache/pstack-claude/pstack/*/skills 2>/dev/null | sort -V | tail -1)"
if [ -n "$cache" ]; then
  PSTACK_SKILLS="$(ls "$cache" | tr '\n' ' ')"
fi
named="$(grep -rhoE '`pstack:[a-z-]+`' plugins/*/commands/*.md plugins/shared/optional-skills-prelude.md .agent/workflows/*.md .pi/prompts/*.md | tr -d '`' | sed 's/^pstack://' | sort -u)"
for skill in $named; do
  if echo " $PSTACK_SKILLS " | grep -q " $skill "; then
    ok "pstack:$skill is a real pstack skill"
  else
    bad "pstack:$skill is named but pstack ships no such skill"
  fi
done

# ── Load-bearing prelude paragraphs must survive compaction ───────────────
# A previous refactor squashed the prelude and dropped both of these. They
# define what an agent does when an installed skill errors mid-run, and that
# skills are matched by name with no version pinning.
for para in "Failure semantics" "Version trust"; do
  if echo "$PRELUDE" | grep -q "\*\*$para\.\*\*"; then
    ok "$para paragraph present"
  else
    bad "$para paragraph missing from the prelude"
  fi
done

# ── Every skill the precedence table replaces is actually used somewhere ──
# A row replacing a skill no mapping table names is dead text that will rot.
replaced="$(echo "$PRECEDENCE_TABLE" | awk -F'|' '{print $4}' | grep -oE '`[a-z:-]+`' | tr -d '`' | sort -u)"
for skill in $replaced; do
  if grep -rqF "\`$skill\`" plugins/*/commands/*.md; then
    ok "replaced skill $skill is named by a mapping table"
  else
    bad "precedence table replaces $skill, but no mapping table names it"
  fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
