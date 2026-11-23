#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255: never write the real event logs
# tests/test_release_gate_claim.sh — a gate tick that claims an issue and then
# declines it (e.g. holding for compaction) must be able to give the claim back
# (#248). release-gate-claim.sh releases only the claim this worktree's gate
# recorded, and only before /fix has created feature/issue-<N>.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$ROOT/plugins/autocoder/scripts"
REL="$SCRIPT_DIR/release-gate-claim.sh"
ISSUES_PY="$SCRIPT_DIR/issues-file.py"

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
REPO="$TMP/repo"
mkdir -p "$REPO"
cd "$REPO" || exit 1
git init --quiet
git -c user.email=t@example.invalid -c user.name=t commit --quiet --allow-empty -m init
export ISSUE_SOURCE=file
export ISSUE_DIR_PATH="$TMP/issues"
export AUTOCODER_ISSUE_EVENTS="$TMP/events.jsonl"
STATE="$(git rev-parse --absolute-git-dir)/autocoder-worker-state"

reset() {   # reset <n>: one open issue, claimed by "the gate", recorded for this worktree
  rm -rf "$TMP/issues"
  mkdir -p "$TMP/issues/open" "$TMP/issues/working" "$TMP/issues/blocked" "$TMP/issues/closed"
  printf -- '---\nnumber: %s\ntitle: Gate claim\npriority: P2\nlabels: [bug]\nstatus: open\n---\nBody.\n' "$1" > "$TMP/issues/open/0$1.md"
  python3 "$ISSUES_PY" claim "$1" >/dev/null
  printf '%s - -\n' "$1" > "$STATE"
}
labels() { python3 "$ISSUES_PY" get "$1" | python3 -c 'import json,sys; print(" ".join(sorted(l["name"] for l in json.load(sys.stdin)["labels"])))'; }
# The file backend appends comments to the body; other backends list them.
comments() { python3 "$ISSUES_PY" get "$1" | python3 -c 'import json,sys; i=json.load(sys.stdin); print("\n".join([i.get("body") or ""] + [c.get("body","") for c in i.get("comments") or []]))'; }

# 1. The declined claim is released, explained, and forgotten.
reset 41
OUT=$(bash "$REL" 41 "holding for context compaction" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "release exits 0" || bad "release exit $rc: $OUT"
[ "$(labels 41)" = "bug" ] && ok "working label removed" || bad "labels after release: $(labels 41)"
[ -f "$TMP/issues/open/041.md" ] && ok "issue is back in the claimable queue" || bad "issue not in open/: $(ls "$TMP"/issues/*/)"
comments 41 | grep -q '🔓 \*\*Releasing claim\*\*' && ok "release comment is a 🔓 release" || bad "no 🔓 comment: $(comments 41)"
comments 41 | grep -q 'holding for context compaction' && ok "release comment carries the reason" || bad "reason missing"
[ ! -f "$STATE" ] && ok "worker-state record cleared" || bad "record still present: $(cat "$STATE")"

# 2. A claim this worktree did not record is never touched.
reset 42
printf '99 - -\n' > "$STATE"
bash "$REL" 42 "x" >/dev/null 2>&1 && bad "released an issue the record does not name" || ok "refuses an issue the record does not name"
[ "$(labels 42)" = "bug working" ] && ok "other claim keeps working" || bad "labels: $(labels 42)"
rm -f "$STATE"
bash "$REL" 42 "x" >/dev/null 2>&1 && bad "released with no record at all" || ok "refuses with no record"

# 3. Once /fix has created the branch, work has started: refuse.
reset 43
git branch feature/issue-43
bash "$REL" 43 "x" >/dev/null 2>&1 && bad "released an issue with a feature branch" || ok "refuses once feature/issue-N exists"
[ "$(labels 43)" = "bug working" ] && ok "started issue keeps working" || bad "labels: $(labels 43)"
[ -f "$STATE" ] && ok "record kept for a started issue" || bad "record dropped"
git branch -D --quiet feature/issue-43

# 3b. A branch that exists only on origin is another worker's (a banked READY, a
#     claim the gate took over, athena2#7185): the gate's label is all this
#     worktree put on the issue, so it is given back.
reset 45
ORIGIN="$TMP/origin.git"; git init --quiet --bare "$ORIGIN"
git remote add origin "$ORIGIN" 2>/dev/null || git remote set-url origin "$ORIGIN"
git push --quiet origin HEAD:refs/heads/feature/issue-45
OUT=$(bash "$REL" 45 "banked by another worker" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "remote-only branch: release exits 0" || bad "remote-only branch: exit $rc: $OUT"
[ "$(labels 45)" = "bug" ] && ok "remote-only branch: working label removed" || bad "remote-only branch: labels $(labels 45)"
[ ! -f "$STATE" ] && ok "remote-only branch: record cleared" || bad "remote-only branch: record kept"
git remote remove origin

# 4. A claim that already ended only clears the record.
reset 44
python3 "$ISSUES_PY" release 44 >/dev/null
bash "$REL" 44 "x" >/dev/null 2>&1 && ok "ended claim exits 0" || bad "ended claim exit non-zero"
[ ! -f "$STATE" ] && ok "ended claim: record cleared" || bad "record still present"
comments 44 | grep -q '🔓' && bad "posted a release on an ended claim" || ok "no release comment on an ended claim"

# 5. Bad arguments.
bash "$REL" >/dev/null 2>&1 && bad "no args accepted" || ok "no args refused"
bash "$REL" abc "x" >/dev/null 2>&1 && bad "non-numeric issue accepted" || ok "non-numeric issue refused"
bash "$REL" 41 >/dev/null 2>&1 && bad "missing reason accepted" || ok "missing reason refused"

# 6. GitHub-shaped backend (fake): a claim another worker took after ours is not
#    ours to release; an unreadable issue or a failed label removal is left alone.
GH="$TMP/gh-scripts"; mkdir -p "$GH"
cp "$SCRIPT_DIR"/{release-gate-claim.sh,issue-fns.sh,worker-state-fns.sh,issue-config.sh} "$GH/"
cat > "$GH/issues-gh.sh" <<'FAKE'
#!/bin/bash
verb="$1"; shift
echo "$verb $*" >> "$FAKE_LOG"
case "$verb" in
  get)     [ "${FAKE_GET_FAIL:-0}" = 1 ] && exit 1; cat "$FAKE_JSON" ;;
  release|update) [ "${FAKE_UNLABEL_FAIL:-0}" = 1 ] && exit 1; exit 0 ;;
  *) exit 0 ;;
esac
FAKE
chmod +x "$GH/issues-gh.sh"
export FAKE_LOG="$TMP/gh.log" FAKE_JSON="$TMP/issue.json"
NOW_MS=$(( $(date +%s) * 1000 ))
gh_issue() {   # gh_issue <comment bodies...>: open, working #50 with these comments
  python3 - "$@" > "$FAKE_JSON" <<'PY'
import json, sys
print(json.dumps({"number": 50, "state": "OPEN", "labels": [{"name": "bug"}, {"name": "working"}],
                  "comments": [{"body": b} for b in sys.argv[1:]]}))
PY
}
run_gh() { : > "$FAKE_LOG"; ISSUE_SOURCE=github bash "$GH/release-gate-claim.sh" "$@" 2>&1; }

printf '50 %s -\n' "$NOW_MS" > "$STATE"
gh_issue "🔒 claim me-1 $NOW_MS wt=/x"
OUT=$(run_gh 50 "compact @someone"); rc=$?
[ "$rc" -eq 0 ] && grep -q '^release 50' "$FAKE_LOG" && ok "github: own live claim released" || bad "github own claim: rc=$rc $(cat "$FAKE_LOG")"
grep -q '^comment 50' "$FAKE_LOG" && ok "github: release comment posted" || bad "github: no comment"
grep '^comment 50' "$FAKE_LOG" | grep -q '@someone' && bad "github: reason can @-mention" || ok "github: @-mentions defused"

printf '50 %s -\n' "$NOW_MS" > "$STATE"
gh_issue "🔒 claim me-1 $NOW_MS wt=/x" "🔒 claim other-2 $(( NOW_MS + 600000 )) wt=/y"
OUT=$(run_gh 50 "compact"); rc=$?
[ "$rc" -eq 0 ] && ! grep -qE '^(release|update|comment) 50' "$FAKE_LOG" && ok "github: re-claimed issue untouched" || bad "github: touched a re-claimed issue: $(cat "$FAKE_LOG")"
[ ! -f "$STATE" ] && ok "github: re-claimed issue's record cleared" || bad "github: stale record kept"

printf '50 %s -\n' "$NOW_MS" > "$STATE"
gh_issue "🔒 claim me-1 $NOW_MS wt=/x"
OUT=$(FAKE_GET_FAIL=1 run_gh 50 "compact"); rc=$?
[ "$rc" -ne 0 ] && ! grep -qE '^(release|update|comment) 50' "$FAKE_LOG" && ok "github: unreadable issue untouched" || bad "github: unreadable issue rc=$rc $(cat "$FAKE_LOG")"
[ -f "$STATE" ] && ok "github: record kept when unreadable" || bad "github: record dropped when unreadable"

OUT=$(FAKE_UNLABEL_FAIL=1 run_gh 50 "compact"); rc=$?
[ "$rc" -ne 0 ] && ! grep -q '^comment 50' "$FAKE_LOG" && ok "github: no 🔓 when the label stays" || bad "github: label failure rc=$rc $(cat "$FAKE_LOG")"
[ -f "$STATE" ] && ok "github: record kept when the label stays" || bad "github: record dropped on label failure"
rm -f "$STATE"

# 7. The gate command tells a declining session to run it.
grep -q 'release-gate-claim.sh' "$ROOT/plugins/autocoder/commands/gate.md" \
  && ok "gate.md documents the release" || bad "gate.md does not mention release-gate-claim.sh"

echo ""
echo "Tests: $FAIL failed, $PASS passed, $((PASS + FAIL)) total"
[ "$FAIL" -eq 0 ]
