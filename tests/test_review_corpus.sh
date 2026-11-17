#!/bin/bash
# tests/test_review_corpus.sh — review-corpus.py: build a review test set from
# sentinel reverts and score a reviewer against it (#167).
#
# Everything runs in a private temp repo with a stub reviewer; no network, no
# tracker, no `claude`.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RC="$ROOT/plugins/autocoder/scripts/review-corpus.py"
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cd "$TMP" || exit 1
git init -q repo && cd repo || exit 1
git config user.email t@example.com; git config user.name T
c() { git add -A; git commit -qm "$@"; git rev-parse HEAD; }

echo 'good' > app.sh;                 BASE=$(c "base")
echo 'echo ok' > util.sh;             CLEAN=$(c "#1: add util")
echo 'BUG exit 0' >> app.sh;          CULPRIT=$(c "#2: break the gate")
echo 'more' > other.sh;               c "#3: unrelated" >/dev/null
# What main-sentinel.sh make_revert() commits: the reverse of the culprit push.
printf 'good\n' > app.sh
REVERT=$(c "Revert autocoder push ${CULPRIT:0:7} (issue #2)" -m "Range ${CLEAN}..${CULPRIT}" \
  -m "Autocoder-Reverts: ${CULPRIT}
Autocoder-Reverts-Issue: 2")
# The re-land, as reland_howto() describes: git revert <revert> (its own commit,
# which only re-applies the culprit), then the fix as the issue's next commits.
git revert --no-edit "$REVERT" >/dev/null 2>&1
RELAND=$(git rev-parse HEAD)
echo 'other' > noise.sh; c "#5: someone else's work" >/dev/null
printf 'good\nfixed exit 1\n' > app.sh; FIX2=$(c "#2: exit 1 when the gate fails")
# A commit whose message mentions a revert in words only must not become a case.
echo x > y; c "revert the colour change, actually" >/dev/null
echo 'off-by-one fixed' > fixme.sh; FIX=$(c "#4: fix off-by-one")

python3 "$RC" harvest --ref HEAD > "$TMP/h.out" 2>&1 || bad "harvest failed: $(cat "$TMP/h.out")"
CASE="tests/review_corpus/cases/revert-${CULPRIT:0:10}"
[ "$(ls tests/review_corpus/cases | wc -l)" -eq 1 ] && ok "one culprit case, from the trailers only" \
  || bad "cases: $(ls tests/review_corpus/cases)"
jq -e --arg c "$CULPRIT" --arg r "$REVERT" --arg l "$RELAND" '.kind == "culprit" and .expect == "flag"
  and .issue == "2" and .commits.culprit == $c and .commits.revert == $r and .commits.reland == $l' \
  "$CASE/case.json" >/dev/null && ok "case.json records culprit, revert, re-land and issue" || bad "case.json: $(cat "$CASE/case.json")"
grep -q '^+BUG exit 0' "$CASE/diff.patch" && ! grep -q other.sh "$CASE/diff.patch" \
  && ok "diff.patch is exactly the culprit push (prev-good..culprit)" || bad "diff: $(cat "$CASE/diff.patch")"
grep -q '^+fixed exit 1' "$CASE/fix.patch" && grep -q "$FIX2" "$CASE/fix.patch" \
  && ! grep -q '^+BUG' "$CASE/fix.patch" && ! grep -q noise.sh "$CASE/fix.patch" \
  && ok "fix.patch is the issue's fix after the re-land, not the re-applied culprit or others' work" \
  || bad "fix.patch: $(cat "$CASE/fix.patch" 2>/dev/null)"

python3 "$RC" harvest --ref HEAD | grep -q '0 new' && ok "a second harvest adds nothing" || bad "harvest not idempotent"

python3 "$RC" add --clean "$CLEAN" >/dev/null && [ -f "tests/review_corpus/cases/clean-${CLEAN:0:10}/diff.patch" ] \
  && ok "add --clean" || bad "add --clean"
python3 "$RC" add --clean "$CLEAN" >/dev/null 2>&1 && bad "adding the same case twice succeeds" || ok "a duplicate case is refused"
python3 "$RC" add --reversed-fix "$FIX" >/dev/null
RF="tests/review_corpus/cases/reversed-fix-${FIX:0:10}"
grep -q '^-off-by-one fixed' "$RF/diff.patch" && jq -e '.kind == "culprit"' "$RF/case.json" >/dev/null \
  && ok "add --reversed-fix stores the fix undone, as a culprit" || bad "reversed-fix: $(cat "$RF/diff.patch")"

# ── score, with stub reviewers ────────────────────────────────────────────────
# A reviewer that flags a diff adding "BUG" or removing a fix: catches both culprits.
cat > "$TMP/good" <<'SH'
#!/bin/bash
d=$(cat); [ -f "$REVIEW_CASE_DIR/diff.patch" ] || exit 9
if grep -qE '^\+BUG|^-off-by-one' <<<"$d"; then echo "Verdict: flag"; else echo "Verdict: pass"; fi
SH
printf '#!/bin/bash\ncat >/dev/null; echo "Verdict: flag"\n' > "$TMP/paranoid"
printf '#!/bin/bash\ncat >/dev/null; echo "looks fine"\n' > "$TMP/mute"
chmod +x "$TMP/good" "$TMP/paranoid" "$TMP/mute"

python3 "$RC" score --reviewer "$TMP/good" --json --save "$TMP/base.json" > "$TMP/s.json"
jq -e '.culprits == 2 and .caught == 2 and .clean == 1 and .false_alarms == 0 and .score == 1' "$TMP/s.json" >/dev/null \
  && ok "a good reviewer catches every culprit with no false alarm" || bad "score: $(cat "$TMP/s.json")"
python3 "$RC" score --reviewer "$TMP/paranoid" --json > "$TMP/p.json"
jq -e '.caught == 2 and .false_alarms == 1 and .score == 0' "$TMP/p.json" >/dev/null \
  && ok "flagging everything is charged a false alarm" || bad "paranoid: $(cat "$TMP/p.json")"
python3 "$RC" score --reviewer "$TMP/mute" --json > "$TMP/m.json" 2>/dev/null \
  && bad "a run with reviewer errors exits 0" || ok "a run with reviewer errors fails"
jq -e '.errors == 3 and .caught == 0 and .false_alarms == 1 and .score == -1 and all(.rows[]; .correct == false)' \
  "$TMP/m.json" >/dev/null && ok "an error is never a catch and always a false alarm" || bad "mute: $(cat "$TMP/m.json")"
echo '{"score": -1}' > "$TMP/low.json"
python3 "$RC" score --reviewer "$TMP/mute" --baseline "$TMP/low.json" --allow-equal >/dev/null 2>&1 \
  && bad "an erroring reviewer passes the baseline" || ok "an erroring reviewer never passes the baseline"

python3 "$RC" score --reviewer "$TMP/paranoid" --baseline "$TMP/base.json" >/dev/null 2>&1 \
  && bad "a worse reviewer passes the baseline" || ok "a worse score fails the baseline"
python3 "$RC" score --reviewer "$TMP/good" --baseline "$TMP/base.json" >/dev/null 2>&1 \
  && bad "an equal score passes without --allow-equal" || ok "an equal score is not an improvement"
python3 "$RC" score --reviewer "$TMP/good" --baseline "$TMP/base.json" --allow-equal >/dev/null 2>&1 \
  && ok "--allow-equal accepts an equal score" || bad "--allow-equal"
python3 "$RC" score --reviewer "$TMP/good" --corpus "$TMP/none" >/dev/null 2>&1 \
  && bad "an empty corpus scores" || ok "an empty corpus fails"
mkdir -p "$TMP/only/cases" && cp -r tests/review_corpus/cases/revert-* "$TMP/only/cases/"
python3 "$RC" score --reviewer "$TMP/paranoid" --corpus "$TMP/only" >/dev/null 2>&1 \
  && bad "a culprit-only corpus scores" || ok "a corpus without clean cases fails"
mkdir -p "$TMP/bad/cases/x" && echo '{' > "$TMP/bad/cases/x/case.json"
python3 "$RC" score --reviewer "$TMP/good" --corpus "$TMP/bad" 2>"$TMP/bad.err" >/dev/null \
  && bad "a malformed case scores" || { grep -q 'malformed case x' "$TMP/bad.err" && ! grep -q Traceback "$TMP/bad.err" \
  && ok "a malformed case is reported, not a traceback" || bad "malformed: $(cat "$TMP/bad.err")"; }
( cd "$TMP" && python3 "$RC" score --corpus tests/review_corpus --repo repo --reviewer "$TMP/good" >/dev/null 2>&1 ) \
  && ok "--corpus resolves against --repo" || bad "--repo resolution"
( cd "$TMP" && python3 "$RC" score --repo repo >/dev/null 2>"$TMP/norules" ) ; grep -q 'no rules file' "$TMP/norules" \
  && ok "the claude reviewer refuses to run without REVIEW.md" || bad "no-rules: $(cat "$TMP/norules")"

# The committed corpus is well formed: every case has its diff and a valid kind.
MALFORMED=0
for cj in "$ROOT"/tests/review_corpus/cases/*/case.json; do
  [ -f "$cj" ] || continue
  d=$(dirname "$cj")
  jq -e '(.kind == "culprit" and .expect == "flag") or (.kind == "clean" and .expect == "pass")' "$cj" >/dev/null \
    && [ -s "$d/diff.patch" ] || { bad "malformed committed case $(basename "$d")"; MALFORMED=1; }
done
[ "$MALFORMED" -eq 0 ] && ok "the committed corpus is well formed"

echo ""
echo "Tests: $FAIL failed, $PASS passed, $((PASS + FAIL)) total"
[ "$FAIL" -eq 0 ]
