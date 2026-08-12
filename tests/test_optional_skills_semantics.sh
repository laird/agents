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
