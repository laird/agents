#!/bin/bash
# tests/test_issue_lifecycle_verbs.sh — the four lifecycle verbs a detached merge job
# drives after a worker's claim, on every backend:
#   handoff   working -> merging              (issue stays unclaimable)
#   park      -> awaiting-integration         (landed; waiting for a green tip or a human)
#   escalate  -> <blocking-label>             (a human must look)
#   requeue   -> open                         (back in the claimable queue)
#
# File backend: the bucket is what makes an issue claimable or visible, so every verb
# is asserted by `ls issues/*/NNN.md`, not just by its labels. The bug this pins: a
# handed-off issue sat in working/ and a raw `update --remove-label awaiting-integration
# --add-label needs-clarification` left it there, where neither `list --state open` nor
# `list --state blocked` showed it, so re-queued and escalated issues vanished.
# Each verb is run twice; the second run must change nothing.
#
# GitHub / Jira / ADO backends: the request shape, via stubbed gh / curl.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$ROOT/plugins/autocoder/scripts"
ISSUES_PY="$SCRIPT_DIR/issues-file.py"
N=31

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ── file backend ────────────────────────────────────────────────────────────
export ISSUE_SOURCE=file
export ISSUE_DIR_PATH="$TMP/issues"
reset_issue() {
  rm -rf "$TMP/issues"
  mkdir -p "$TMP/issues/open" "$TMP/issues/working" "$TMP/issues/blocked" "$TMP/issues/closed"
  printf -- '---\nnumber: %s\ntitle: Lifecycle\npriority: P2\nlabels: [%s]\nstatus: open\n---\nBody.\n' "$N" "${1:-bug}" > "$TMP/issues/open/0${N}.md"
}
bucket()   { basename "$(dirname "$(ls "$TMP"/issues/*/0${N}.md 2>/dev/null | head -1)")"; }
labels()   { python3 "$ISSUES_PY" get "$N" | python3 -c 'import json,sys; print(" ".join(sorted(l["name"] for l in json.load(sys.stdin)["labels"])))'; }
body()     { cat "$TMP"/issues/*/0${N}.md; }
in_list()  { python3 "$ISSUES_PY" list --state "$1" | python3 -c 'import json,sys; print(any(i["number"]=='"$N"' for i in json.load(sys.stdin)))'; }
snapshot() { echo "$(bucket)|$(labels)"; }

# handoff: working -> merging, still in working/, never claimable
reset_issue; python3 "$ISSUES_PY" claim "$N"
python3 "$ISSUES_PY" handoff "$N" && ok "handoff exits 0" || bad "handoff failed"
[ "$(bucket)" = working ] && [ "$(labels)" = "bug merging" ] && ok "handoff: working/ bucket, labels [bug merging]" || bad "handoff state: $(snapshot)"
[ "$(in_list open)" = False ] && ok "handoff: not in the claimable queue" || bad "handoff: issue is claimable"
S1=$(snapshot); python3 "$ISSUES_PY" handoff "$N"; [ "$(snapshot)" = "$S1" ] && ok "handoff is idempotent" || bad "second handoff changed state: $(snapshot)"
python3 "$ISSUES_PY" claim "$N" 2>/dev/null && bad "a handed-off issue could be claimed" || ok "a handed-off issue cannot be claimed"

# park: merging -> awaiting-integration, still in working/, comment appended
python3 "$ISSUES_PY" park "$N" --comment "PARK-NOTE landed as abc123" && ok "park exits 0" || bad "park failed"
[ "$(bucket)" = working ] && [ "$(labels)" = "awaiting-integration bug" ] && ok "park: working/ bucket, merging retired, awaiting-integration set" || bad "park state: $(snapshot)"
body | grep -q "PARK-NOTE landed as abc123" && ok "park appends its comment" || bad "park comment missing"
[ "$(in_list open)" = False ] && ok "park: not claimable" || bad "park: issue is claimable"
[ "$(in_list blocked)" = False ] && ok "park: not shown as blocked (not a human gate)" || bad "park: listed as blocked"
python3 "$ISSUES_PY" list --state all --label awaiting-integration | grep -q "\"number\": $N" && ok "park: findable by label (the sentinel's probe)" || bad "park: not findable by label"
S1=$(snapshot); python3 "$ISSUES_PY" park "$N" --comment "again"; [ "$(snapshot)" = "$S1" ] && ok "park is idempotent" || bad "second park changed state: $(snapshot)"

# escalate from parked: -> blocked/, every lock label gone
python3 "$ISSUES_PY" escalate "$N" --label needs-clarification --comment "ESCALATE-NOTE" && ok "escalate exits 0" || bad "escalate failed"
[ "$(bucket)" = blocked ] && [ "$(labels)" = "bug needs-clarification" ] && ok "escalate: blocked/ bucket, only the blocking label remains" || bad "escalate state: $(snapshot)"
[ "$(in_list blocked)" = True ] && ok "escalate: visible to list --state blocked" || bad "escalate: invisible to /review-blocked (the vanishing-issue bug)"
body | grep -q "ESCALATE-NOTE" && ok "escalate appends its comment" || bad "escalate comment missing"
S1=$(snapshot); python3 "$ISSUES_PY" escalate "$N" --label needs-clarification --comment "again"; [ "$(snapshot)" = "$S1" ] && ok "escalate is idempotent" || bad "second escalate changed state: $(snapshot)"
python3 "$ISSUES_PY" escalate "$N" --label bug 2>/dev/null; [ $? -ne 0 ] && ok "escalate refuses a non-blocking label" || bad "escalate accepted a non-blocking label"

# escalate straight from merging (the merge job's failure path)
reset_issue; python3 "$ISSUES_PY" claim "$N"; python3 "$ISSUES_PY" handoff "$N"
python3 "$ISSUES_PY" escalate "$N" --label needs-clarification --comment "gate failed"
[ "$(bucket)" = blocked ] && [ "$(labels)" = "bug needs-clarification" ] && ok "escalate from merging lands in blocked/" || bad "escalate from merging: $(snapshot)"

# requeue from merging: -> open/, claimable again
reset_issue; python3 "$ISSUES_PY" claim "$N"; python3 "$ISSUES_PY" handoff "$N"
python3 "$ISSUES_PY" requeue "$N" --comment "REQUEUE-NOTE job died" && ok "requeue exits 0" || bad "requeue failed"
[ "$(bucket)" = open ] && [ "$(labels)" = "bug" ] && ok "requeue: open/ bucket, no lock labels" || bad "requeue state: $(snapshot)"
[ "$(in_list open)" = True ] && ok "requeue: back in the claimable queue" || bad "requeue: not claimable (the vanishing-issue bug)"
body | grep -q "REQUEUE-NOTE" && ok "requeue appends its comment" || bad "requeue comment missing"
S1=$(snapshot); python3 "$ISSUES_PY" requeue "$N" --comment "again"; [ "$(snapshot)" = "$S1" ] && ok "requeue is idempotent" || bad "second requeue changed state: $(snapshot)"
python3 "$ISSUES_PY" claim "$N" && ok "a requeued issue can be claimed again" || bad "requeued issue not claimable"

# requeue from parked, with another blocking label present: -> blocked/, not open/
reset_issue "bug, future"; python3 "$ISSUES_PY" claim "$N"; python3 "$ISSUES_PY" handoff "$N"; python3 "$ISSUES_PY" park "$N" --comment p
python3 "$ISSUES_PY" requeue "$N" --comment "r"
[ "$(bucket)" = blocked ] && [ "$(labels)" = "bug future" ] && ok "requeue honours a remaining blocking label (blocked/)" || bad "requeue with blocking label: $(snapshot)"

# close strips every lock label
reset_issue; python3 "$ISSUES_PY" claim "$N"; python3 "$ISSUES_PY" handoff "$N"; python3 "$ISSUES_PY" park "$N" --comment p
python3 "$ISSUES_PY" close "$N" --comment done
[ "$(bucket)" = closed ] && [ "$(labels)" = "bug" ] && ok "close drops merging and awaiting-integration" || bad "close state: $(snapshot)"

# a closed issue has left the lifecycle: verbs refuse (exit 1) and change nothing
for v in handoff park requeue; do
  python3 "$ISSUES_PY" "$v" "$N" 2>/dev/null; rc=$?
  [ "$rc" -eq 1 ] && [ "$(bucket)" = closed ] && ok "$v on a closed issue exits 1 and leaves it closed" || bad "$v on closed: rc=$rc bucket=$(bucket)"
done
python3 "$ISSUES_PY" escalate "$N" --label future 2>/dev/null; rc=$?
[ "$rc" -eq 1 ] && [ "$(bucket)" = closed ] && ok "escalate on a closed issue exits 1 and leaves it closed" || bad "escalate on closed: rc=$rc bucket=$(bucket)"
python3 "$ISSUES_PY" handoff 999 2>/dev/null; [ $? -eq 1 ] && ok "handoff on a missing issue exits 1" || bad "handoff on missing issue rc=$?"

# a lock label on an issue that sits in open/ (an import, a hand edit, a worker that
# swapped `working` for `ready-for-review` in place): hidden from the claimable queue,
# refused by claim, not a blocked issue, and claimable again once requeue clears it
for L in ready-for-review needs-rebase; do
  reset_issue "bug, $L"
  python3 "$ISSUES_PY" claim "$N" 2>"$TMP/claim.err"; rc=$?
  [ "$rc" -eq 1 ] && [ "$(bucket)" = open ] && grep -q "$L" "$TMP/claim.err" && ok "claim refuses an open/ issue carrying $L: exit 1, names the label, file stays in open/" || bad "claim with $L: rc=$rc bucket=$(bucket) stderr=$(cat "$TMP/claim.err")"
  [ "$(in_list open)" = False ] && ok "$L: hidden from list --state open" || bad "$L: offered as claimable"
  python3 "$ISSUES_PY" list --state open --label "$L" | grep -q "\"number\": $N" && ok "$L: still found by an explicit --label probe (the sentinel's)" || bad "$L: invisible to list --state open --label $L"
  [ "$(in_list blocked)" = False ] && ok "$L: not shown as blocked (not a human gate)" || bad "$L: listed as blocked"
  python3 "$ISSUES_PY" any-claimable; rc=$?
  [ "$rc" -eq 1 ] && ok "$L: any-claimable reports nothing claimable" || bad "$L: any-claimable rc=$rc"
  python3 "$ISSUES_PY" requeue "$N" --comment "manager handed it back"
  [ "$(labels)" = "bug" ] && python3 "$ISSUES_PY" claim "$N" && ok "requeue strips $L; the issue is claimable again" || bad "requeue with $L: $(snapshot)"
done

# the dispatcher exposes the verbs
(
  cd "$TMP" && git init -q repo && cd repo && printf '{"issueSource":"file","issueDir":"%s"}\n' "$TMP/issues" > .autocoder.json
  reset_issue; python3 "$ISSUES_PY" claim "$N"
  unset ISSUE_SOURCE ISSUE_DIR_PATH
  # shellcheck source=../plugins/autocoder/scripts/issue-fns.sh
  source "$SCRIPT_DIR/issue-fns.sh"
  issue_handoff "$N" && issue_park "$N" --comment p && issue_escalate "$N" --label future --comment e && issue_requeue "$N" --comment r
) && [ "$(bucket)" = blocked ] && [ "$(labels)" = "bug future" ] && ok "issue-fns.sh dispatches handoff/park/escalate/requeue" || bad "dispatcher: $(snapshot)"

# ── GitHub backend: label order and tolerance, via a gh stub ────────────────
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/bin/bash
echo "$*" >> "$GH_LOG"
# A label the repo never defined: gh fails the removal. The verb must not care.
case "$*" in *"--remove-label awaiting-integration"*) echo "'awaiting-integration' not found" >&2; exit 1 ;; esac
case "$*" in "issue list "*) echo '[{"number":8,"title":"merging","body":"","labels":[{"name":"merging"}],"state":"OPEN"},{"number":9,"title":"free","body":"","labels":[],"state":"OPEN"}]' ;; esac
exit 0
EOF
chmod +x "$TMP/bin/gh"
export GH_LOG="$TMP/gh.log"
gh_run() { : > "$GH_LOG"; BASH_ENV="" PATH="$TMP/bin:$PATH" ISSUE_SOURCE=github "$SCRIPT_DIR/issues-gh.sh" "$@"; }

gh_run handoff 7 && ok "gh handoff exits 0" || bad "gh handoff rc"
[ "$(sed -n 1p "$GH_LOG")" = "issue edit 7 --add-label merging" ] && [ "$(sed -n 2p "$GH_LOG")" = "issue edit 7 --remove-label working" ] \
  && ok "gh handoff adds merging before removing working" || bad "gh handoff calls: $(cat "$GH_LOG")"
gh_run park 7 --comment "parked" && ok "gh park exits 0" || bad "gh park rc"
grep -q "^issue edit 7 --add-label awaiting-integration" "$GH_LOG" && grep -q "^issue edit 7 --remove-label merging" "$GH_LOG" && grep -q "^issue comment 7 --body parked" "$GH_LOG" \
  && ok "gh park adds awaiting-integration, drops merging, comments" || bad "gh park calls: $(cat "$GH_LOG")"
gh_run escalate 7 --label needs-clarification --comment "boom" && ok "gh escalate exits 0 even when a removal is refused" || bad "gh escalate rc"
[ "$(sed -n 1p "$GH_LOG")" = "issue edit 7 --add-label needs-clarification" ] && grep -q "^issue edit 7 --remove-label awaiting-integration" "$GH_LOG" && grep -q "^issue comment 7 --body boom" "$GH_LOG" \
  && ok "gh escalate adds the blocking label first, drops all three locks, comments" || bad "gh escalate calls: $(cat "$GH_LOG")"
gh_run escalate 7 --comment "no label" 2>/dev/null; [ $? -eq 2 ] && ok "gh escalate without --label is a usage error" || bad "gh escalate without --label rc=$?"
gh_run requeue 7 --comment "died" && grep -q "^issue edit 7 --remove-label merging" "$GH_LOG" && grep -q "^issue comment 7 --body died" "$GH_LOG" \
  && ok "gh requeue drops the locks and comments" || bad "gh requeue calls: $(cat "$GH_LOG")"
grep -q "^issue edit 7 --remove-label ready-for-review" "$GH_LOG" && grep -q "^issue edit 7 --remove-label needs-rebase" "$GH_LOG" \
  && ok "gh requeue also drops ready-for-review and needs-rebase" || bad "gh requeue left a merge-gate label: $(cat "$GH_LOG")"
OUT=$(gh_run list --state open --limit 5 2>/dev/null)
grep -q '"number": 9' <<<"$OUT" && ! grep -q '"number": 8' <<<"$OUT" && ok "gh claimable queue excludes merging" || bad "gh claimable queue does not exclude merging: $OUT"

# ── Jira and ADO backends: one converging label edit per verb, via a curl stub ─
cat > "$TMP/bin/curl" <<'EOF'
#!/bin/bash
method="GET"; data=""; prev=""
for a in "$@"; do
  case "$prev" in -X) method="$a" ;; --data) data="$a" ;; esac
  prev="$a"
done
url="${@: -1}"
printf '%s\t%s\t%s\n' "$method" "$url" "$data" >> "$CURL_LOG"
case "$url" in
  */_apis/wit/workitems/*) printf '{"id":7,"fields":{"System.Tags":"P1; working; merging"}}\n200' ;;
  *) printf '{}\n200' ;;
esac
EOF
chmod +x "$TMP/bin/curl"
export CURL_LOG="$TMP/curl.log"
mkdir -p "$TMP/jira" && git -C "$TMP/jira" init -q && printf '{"issueSource":"jira","jira":{"baseUrl":"https://x.atlassian.net","project":"ENG"}}\n' > "$TMP/jira/.autocoder.json"
jira_run() { : > "$CURL_LOG"; (cd "$TMP/jira" && BASH_ENV="" PATH="$TMP/bin:$PATH" JIRA_EMAIL=a@b JIRA_API_TOKEN=t "$SCRIPT_DIR/issues-jira.sh" "$@"); }
jira_run handoff 7 && grep -q '"add": "merging"' "$CURL_LOG" && grep -q '"remove": "working"' "$CURL_LOG" && ok "jira handoff adds merging, removes working" || bad "jira handoff: $(cat "$CURL_LOG")"
jira_run escalate 7 --label needs-clarification --comment c && grep -q '"add": "needs-clarification"' "$CURL_LOG" && grep -q '"remove": "awaiting-integration"' "$CURL_LOG" && grep -q '"remove": "merging"' "$CURL_LOG" && grep -q '/comment' "$CURL_LOG" \
  && ok "jira escalate adds the blocking label, removes all locks, comments" || bad "jira escalate: $(cat "$CURL_LOG")"
jira_run requeue 7 && grep -q '"remove": "merging"' "$CURL_LOG" && ok "jira requeue removes merging" || bad "jira requeue: $(cat "$CURL_LOG")"
grep -q '"remove": "ready-for-review"' "$CURL_LOG" && grep -q '"remove": "needs-rebase"' "$CURL_LOG" && ok "jira requeue also removes ready-for-review and needs-rebase" || bad "jira requeue left a merge-gate label: $(cat "$CURL_LOG")"
jira_run list --state open >/dev/null 2>&1; grep -q 'merging' "$CURL_LOG" && ok "jira claimable JQL excludes merging" || bad "jira JQL lacks merging"

mkdir -p "$TMP/ado" && git -C "$TMP/ado" init -q && printf '{"issueSource":"ado","ado":{"orgUrl":"https://dev.azure.com/org","project":"Proj"}}\n' > "$TMP/ado/.autocoder.json"
ado_run() { : > "$CURL_LOG"; (cd "$TMP/ado" && BASH_ENV="" PATH="$TMP/bin:$PATH" ADO_PAT=t "$SCRIPT_DIR/issues-ado.sh" "$@"); }
ado_run park 7 --comment c; PATCH=$(grep PATCH "$CURL_LOG" | cut -f3)
echo "$PATCH" | grep -q "awaiting-integration" && ! echo "$PATCH" | grep -q "merging" && ! echo "$PATCH" | grep -q "working" \
  && ok "ado park: tags gain awaiting-integration and lose working/merging" || bad "ado park patch: $PATCH"
ado_run requeue 7; PATCH=$(grep PATCH "$CURL_LOG" | cut -f3)
echo "$PATCH" | grep -q '"P1"' && ! echo "$PATCH" | grep -q "merging" && ok "ado requeue: only the non-lock tags remain" || bad "ado requeue patch: $PATCH"
ado_run list --state open >/dev/null 2>&1; grep -q "NOT CONTAINS 'merging'" "$CURL_LOG" && ok "ado claimable WIQL excludes merging" || bad "ado WIQL lacks merging"

TOTAL=$((PASS + FAIL))
echo "$PASS passed / $FAIL failed / $TOTAL total"
[ "$FAIL" -eq 0 ]
