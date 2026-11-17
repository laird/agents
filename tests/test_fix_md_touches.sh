#!/bin/bash
# tests/test_fix_md_touches.sh — /fix writes and keeps current the `Touches:` line
# the fix-loop gate reads to steer workers apart (#229, sub-task of #186).
#
# Structure: both fix.md copies put `Touches:` in the decomposition template, chain
# sub-tasks whose areas overlap with `Depends on:`, and tell workers to run
# touches-set.sh on start and after each commit. Behaviour: touches-set.sh, against a
# stubbed `gh` in a private temp repo (never the real tracker), declares areas, adds
# the files the branch changed, collapses a crowded directory, replaces the line in
# place, leaves an up-to-date body alone, and only prints on a backend that cannot
# edit a body. touches_of (the gate's parser) reads back what it wrote.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$ROOT/plugins/autocoder/scripts"
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# The decomposition protocol (template and chaining rule) moved out of fix.md into
# a reference file per platform (#240); the worker guidance stays in fix.md.
for pair in "plugins/autocoder/commands/fix.md:skills/autocoder/references/fix-decomposition.md" \
            ".agent/workflows/fix.md:.agent/shared/fix-decomposition.md"; do
  f="${pair%%:*}"; P="$ROOT/$f"; d="${pair#*:}"; D="$ROOT/$d"
  python3 - "$D" <<'PY' && ok "$d: the sub-task template carries a Touches: line" || bad "$d: no Touches: line in the sub-task template"
import sys
s = open(sys.argv[1]).read()
i = s.index("--body \"$(cat <<SUBTASK_BODY")
j = s.index("\nSUBTASK_BODY\n", i)
t = s[i:j]
fa, tl, ac = t.find("## Files Affected"), t.find("\nTouches: "), t.find("## Acceptance Criteria")
sys.exit(0 if -1 < fa < tl < ac else 1)
PY
  grep -q 'two sub-tasks whose `Touches:` areas overlap share a hotspot and must be chained with `Depends on:`' "$D" \
    && ok "$d: overlapping sub-tasks are chained with Depends on:" || bad "$d: no rule chaining overlapping sub-tasks"
  grep -qF "${d##*/}" "$P" && ok "$f points to $d" || bad "$f does not point to $d"
  grep -q 'keep `Touches:` current (#229)' "$P" && ok "$f: workers are told to keep Touches: current" || bad "$f: no Touches: guidance"
  grep -q '"${SCRIPT_DIR}/touches-set.sh" "$ISSUE_NUM" --base "origin/${INTEGRATION_BRANCH}" \\$' "$P" \
    && grep -A1 '"${SCRIPT_DIR}/touches-set.sh" "$ISSUE_NUM" --base "origin/${INTEGRATION_BRANCH}" \\$' "$P" | grep -q -- '--declare "' \
    && ok "$f: start snippet declares areas" || bad "$f: no start snippet with --declare"
  grep -qx '"${SCRIPT_DIR}/touches-set.sh" "$ISSUE_NUM" --base "origin/${INTEGRATION_BRANCH}"' "$P" \
    && ok "$f: after-commit snippet" || bad "$f: no after-commit snippet"
done

# ── Behaviour: a private repo, a stubbed gh holding one issue body ────────────
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
unset ISSUE_SOURCE ISSUE_BACKEND
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'SH'
#!/bin/bash
# issue view N --json ... | issue edit N --body-file -
case "$1 $2" in
  "issue view") python3 -c 'import json,sys; print(json.dumps({"number": int(sys.argv[1]), "title": "t", "body": open(sys.argv[2], newline="").read(), "labels": [], "state": "OPEN", "comments": []}))' "$3" "$GH_BODY" ;;
  "issue edit") [ "$4" = --body-file ] && [ "$5" = - ] || exit 9; cat > "$GH_BODY"; echo edit >> "$GH_BODY.edits" ;;
  *) exit 9 ;;
esac
SH
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH" GH_BODY="$TMP/body"

git init -q --bare "$TMP/origin.git"
git init -q "$TMP/repo"; cd "$TMP/repo" || exit 1
git config user.email t@example.com; git config user.name T
printf '{"issueSource": "github"}\n' > .autocoder.json
echo a > a; git add -A; git commit -qm base
git remote add origin "$TMP/origin.git"; git push -q origin HEAD:main; git fetch -q origin
git checkout -qb feature/issue-7

printf '## Sub-task of #1\n\n```\nTouches: quoted/in/a/fence/\n```\n\nSome text.' > "$GH_BODY"
SET() { "$SCRIPTS/touches-set.sh" 7 --base origin/main "$@"; }
gate_reads() {
  # shellcheck source=../plugins/autocoder/scripts/touches-fns.sh
  ( source "$SCRIPTS/touches-fns.sh"; "$SCRIPTS/issues-gh.sh" get 7 | touches_of - | paste -sd' ' - )
}

OUT=$(SET --declare "src/web/, docs/plan.md" 2>&1); RC=$?
[ "$RC" -eq 0 ] && [ "$(gate_reads)" = "src/web/ docs/plan.md" ] && ok "on start: the declared areas are written and the gate reads them" \
  || bad "declare: rc=$RC out=$OUT gate='$(gate_reads)'"
grep -q '^Touches: quoted/in/a/fence/$' "$GH_BODY" && grep -q '^Some text\.$' "$GH_BODY" \
  && ok "the rest of the body (a fenced example included) is kept" || bad "body damaged: $(cat "$GH_BODY")"

mkdir -p src/web src/core tools
for x in src/web/a.rs src/core/1.rs src/core/2.rs src/core/3.rs tools/t.sh docs.md; do echo x > "$x"; done
git add -A; git commit -qm work
SET >/dev/null 2>&1
[ "$(gate_reads)" = "src/web/ docs/plan.md docs.md src/core/ tools/t.sh" ] \
  && ok "after a commit: changed files are added, covered ones skipped, a crowded directory collapsed" \
  || bad "after commit: '$(gate_reads)'"
[ "$(grep -c '^Touches: ' "$GH_BODY")" -eq 2 ] && ok "the line is replaced in place, not appended again" \
  || bad "Touches: lines: $(grep -c '^Touches: ' "$GH_BODY")"

EDITS=$(wc -l < "$GH_BODY.edits")
OUT=$(SET 2>&1)
[ "$(wc -l < "$GH_BODY.edits")" -eq "$EDITS" ] && echo "$OUT" | grep -q 'already current' \
  && ok "an up-to-date line is not rewritten" || bad "rewrote an unchanged line: $OUT"

OUT=$(SET --dry-run --declare "x/" 2>&1)
[ "$(wc -l < "$GH_BODY.edits")" -eq "$EDITS" ] && echo "$OUT" | grep -q 'would set: Touches: .*x/$' \
  && ok "--dry-run prints and writes nothing" || bad "dry run: $OUT"

SET --base origin/nonexistent >/dev/null 2>&1 && bad "an unknown base succeeded" || ok "an unknown base fails"

# A Files Affected section with no Touches: line: the line is appended once.
printf '## Files Affected\n- `lib/x.py`\n' > "$GH_BODY"
SET --declare "lib/x.py" >/dev/null 2>&1
tail -n 1 "$GH_BODY" | grep -q '^Touches: lib/x.py, ' && ok "with no Touches: line, one is appended" || bad "append: $(cat "$GH_BODY")"

# A body that leaves a code fence open (a pasted, truncated log): the fence is
# closed first, so the gate reads the line and the next run finds it (review, #229).
printf 'intro\n```\nlog line' > "$GH_BODY"
SET --declare "a/" >/dev/null 2>&1; SET --declare "a/" >/dev/null 2>&1
gate_reads | grep -q '^a/ ' && [ "$(grep -c '^Touches: ' "$GH_BODY")" -eq 1 ] \
  && ok "an open fence is closed before the line, and a second run does not duplicate it" \
  || bad "open fence: gate '$(gate_reads)', body: $(cat "$GH_BODY")"

# A directory that gains one file per run still collapses once it holds three.
printf 'Touches: src/core/1.rs, src/core/2.rs' > "$GH_BODY"
(source "$SCRIPTS/touches-fns.sh"; touches_update "$(cat "$GH_BODY")" "" "src/core/3.rs") | head -n 1 \
  | grep -qx 'Touches: src/core/' && ok "files listed by earlier runs count towards collapsing" || bad "no collapse across runs"

# CRLF bodies keep their line endings.
printf 'x\r\nTouches: a/\r\nend' > "$GH_BODY"
SET --declare "b/" >/dev/null 2>&1
[ "$(grep -c $'\r$' "$GH_BODY")" -eq 2 ] && grep -q $'^Touches: a/, b/, .*\r$' "$GH_BODY" && ok "a CRLF body is rewritten only on its Touches: line" \
  || bad "CRLF body: $(cat -A "$GH_BODY")"

timeout 10 "$SCRIPTS/touches-set.sh" 7 --declare >/dev/null 2>&1; [ $? -eq 2 ] && ok "an option with no value is a usage error, not a hang" \
  || bad "--declare without a value did not exit 2"

# A backend that cannot edit a body: the line is printed, nothing is written.
cd "$TMP" && git init -q filerepo && cd filerepo || exit 1
git config user.email t@example.com; git config user.name T
printf '{"issueSource": "file"}\n' > .autocoder.json
echo a > a; git add -A; git commit -qm base; git branch -q base
IF() { ( source "$SCRIPTS/issue-fns.sh" >/dev/null 2>&1; "$@" ); }
N=$(IF issue_create --title t --body "no areas yet" | jq -r .number)
echo b > b; git add b; git commit -qm b
OUT=$("$SCRIPTS/touches-set.sh" "$N" --base base 2>&1); RC=$?
[ "$RC" -eq 0 ] && echo "$OUT" | grep -qx 'Touches: b' && ok "file backend: the line is printed to add by hand" \
  || bad "file backend: rc=$RC out=$OUT"
[ "$(IF issue_get "$N" | jq -r .body)" = "no areas yet" ] \
  && ok "file backend: the body is not changed" || bad "file backend body changed"

"$SCRIPTS/touches-set.sh" >/dev/null 2>&1; [ $? -eq 2 ] && ok "no issue is a usage error" || bad "no issue: not exit 2"

echo ""
echo "Tests: $FAIL failed, $PASS passed, $((PASS + FAIL)) total"
[ "$FAIL" -eq 0 ]
