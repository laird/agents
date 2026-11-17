#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255: never write the real event logs
# tests/test_issue_create_priority.sh — `issue_create --priority PX` labels the issue PX,
# and `create` refuses flags it does not know (#199), on the gh and file backends.
# (Jira and ADO are covered in test_issues_jira.sh / test_issues_ado.sh.)
#
# Every backend's create used to drop --priority without a word: the gh/jira/ado
# arg loops ended in `*) shift`, so /record-issue --priority P1 filed an issue with
# no priority label, and the caller saw success.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$ROOT/plugins/autocoder/scripts"
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want '$2', got '$3'"; fi; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ── gh backend: a stub gh records the create command line ───────────────────
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<STUB
#!/bin/bash
if [ "\$1 \$2" = "issue create" ]; then printf '%s\n' "\$@" > "$TMP/gh-create.args"; echo "https://github.com/o/r/issues/77"; exit 0; fi
exit 0
STUB
chmod +x "$TMP/bin/gh"
gh_create() { BASH_ENV="" PATH="$TMP/bin:$PATH" bash "$S/issues-gh.sh" create "$@" 2>"$TMP/err"; }

rm -f "$TMP/gh-create.args"
gh_create --title T --body B --priority P1 --label bug >/dev/null; RC=$?
eq "gh: create --priority exits 0" "0" "$RC"
LABELS=$(awk 'prev=="--label"{print} {prev=$0}' "$TMP/gh-create.args" 2>/dev/null | LC_ALL=C sort | tr '\n' ',')
eq "gh: --priority P1 becomes --label P1 (bug kept)" "P1,bug," "$LABELS"

rm -f "$TMP/gh-create.args"
gh_create --title T --priority P5 >/dev/null; RC=$?
eq "gh: --priority P5 exits 2" "2" "$RC"
[ ! -e "$TMP/gh-create.args" ] && ok "gh: nothing created for a bad priority" || bad "gh: created despite a bad priority"
gh_create --title T --assignee me >/dev/null; RC=$?
eq "gh: unknown flag exits 2" "2" "$RC"
grep -q "unknown argument '--assignee'" "$TMP/err" && ok "gh: the refusal names the flag" || bad "gh: refusal message: $(cat "$TMP/err")"

# ── file backend ─────────────────────────────────────────────────────────────
export ISSUE_DIR_PATH="$TMP/issues"
mkdir -p "$ISSUE_DIR_PATH"/{open,working,blocked,closed}
fb() { python3 "$S/issues-file.py" "$@"; }
N=$(fb create --title T --priority P1 --label bug | python3 -c 'import json,sys; print(json.load(sys.stdin)["number"])')
eq "file: --priority P1 labels the issue P1 (bug kept)" "P1,bug" "$(fb get "$N" | python3 -c 'import json,sys; print(",".join(sorted(l["name"] for l in json.load(sys.stdin)["labels"])))')"
N=$(fb create --title T --priority P2 --label P2 | python3 -c 'import json,sys; print(json.load(sys.stdin)["number"])')
eq "file: --priority equal to a --label is not duplicated" "P2" "$(fb get "$N" | python3 -c 'import json,sys; print(",".join(l["name"] for l in json.load(sys.stdin)["labels"]))')"
fb create --title T --priority P9 >/dev/null 2>&1; eq "file: --priority P9 exits 2" "2" "$?"
fb create --title T --bogus x >/dev/null 2>&1; eq "file: unknown flag exits 2" "2" "$?"

# ── through issue_create, the API every caller uses ──────────────────────────
# Run from a private repo whose own .autocoder.json selects the file backend. From
# inside the real checkout, its .autocoder.json (issueSource=github) wins over
# ISSUE_SOURCE and this would file a REAL issue. It did once (#230, #231). The
# gh stub on PATH refuses `issue create` as a second guard.
cat > "$TMP/bin/gh" <<'STUB'
#!/bin/bash
[ "$1 $2" = "issue create" ] && { echo "test guard: refusing a real 'gh issue create'" >&2; exit 97; }
exit 0
STUB
git init -q "$TMP/repo"
printf '{"issueSource": "file", "issueDir": "%s"}\n' "$ISSUE_DIR_PATH" > "$TMP/repo/.autocoder.json"
OUT=$(cd "$TMP/repo" && BASH_ENV="" PATH="$TMP/bin:$PATH" ISSUE_SOURCE=file \
  bash -c "source '$S/issue-fns.sh' && issue_create --title Via --body b --priority P3")
N=$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["number"])')
eq "issue_create --priority P3 via issue-fns.sh labels it P3" "P3" "$(fb get "$N" 2>/dev/null | python3 -c 'import json,sys; print(",".join(l["name"] for l in json.load(sys.stdin)["labels"]))' 2>/dev/null)"

echo ""
echo "Tests: $FAIL failed, $PASS passed, $((PASS + FAIL)) total"
[ "$FAIL" -eq 0 ]
