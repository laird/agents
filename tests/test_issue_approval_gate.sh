#!/bin/bash
# tests/test_issue_approval_gate.sh — guards the approved-work gate.
#
# WHAT IT PROTECTS:
#   A repo can require that an issue carry an approval label (conventionally
#   `swarm`) before any agent may work it. Two properties matter, and each has
#   a failure mode that is quiet rather than loud:
#
#   1. The gate must apply to the CLAIM, not only to the queue. Issues reach a
#      worker by number from paths the queue never filters -- a manager
#      dispatch, /fix N, a resumed loop. A gate that only filters `list` looks
#      correct in every listing while unapproved work still gets done.
#
#   2. The gate must be OFF by default. Every repo that has never heard of
#      requiredLabel must behave exactly as before; a gate that defaults to on
#      makes a swarm silently find no work at all.
#
#   Backend coverage is deliberate: the file backend is exercised end to end on
#   a real directory, and gh/Jira/ADO are checked at the query they emit, since
#   an ungated query means unapproved issues are handed out no matter what the
#   claim path does.

set -u
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
cd "$ROOT" || exit 1
SCRIPTS="plugins/autocoder/scripts"

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_eq() {
  local label="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then pass "$label"; else fail "$label — want '$want' got '$got'"; fi
}
assert_contains() {
  local label="$1" needle="$2" hay="$3"
  if printf '%s' "$hay" | grep -qF -- "$needle"; then pass "$label"
  else fail "$label — '$needle' not in: $hay"; fi
}
assert_not_contains() {
  local label="$1" needle="$2" hay="$3"
  if printf '%s' "$hay" | grep -qF -- "$needle"; then fail "$label — '$needle' unexpectedly present in: $hay"
  else pass "$label"; fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ── A real repo with a real .issues tree ─────────────────────────────────────
REPO="$TMP/repo"
mkdir -p "$REPO/.issues/open" "$REPO/.issues/working"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email t@t; git -C "$REPO" config user.name t

write_issue() {  # write_issue <number> <title> [labels...]
  local n="$1" title="$2"; shift 2
  # The on-disk format is unquoted and comma-separated -- `labels: [swarm]` --
  # matching _format_issue in issues-file.py. Quoted JSON would parse as a
  # label literally named "\"swarm\"" and never match the gate.
  local labels="[]"
  if [ $# -gt 0 ]; then
    labels="[$(printf '%s, ' "$@" | sed 's/, $//')]"
  fi
  # Zero-padded to three digits, matching issue_path() in issues-file.py: the
  # claim path resolves an exact filename, so `1.md` is invisible to it even
  # though `list` globs it up.
  cat > "$REPO/.issues/open/$(printf '%03d' "$n").md" <<EOF
---
number: $n
title: $title
labels: $labels
status: open
---

Body of issue $n.
EOF
}

write_issue 1 "approved work" swarm
write_issue 2 "not approved yet"

FILE_BACKEND="$ROOT/$SCRIPTS/issues-file.py"
file_run() {  # file_run <verb> [args...]  -> OUT / RC
  OUT=$(cd "$REPO" && ISSUE_DIR_PATH="$REPO/.issues" python3 "$FILE_BACKEND" "$@" 2>&1)
  RC=$?
}
set_config() {  # set_config <label> | set_config  (removes the key)
  if [ $# -eq 0 ]; then
    echo '{"issueSource":"file"}' > "$REPO/.autocoder.json"
  else
    printf '{"issueSource":"file","requiredLabel":"%s"}\n' "$1" > "$REPO/.autocoder.json"
  fi
}

# ── 1. OFF by default: an unconfigured repo behaves exactly as before ────────
set_config
file_run list --state open
assert_contains "ungated list returns the approved issue"   '"number": 1' "$OUT"
assert_contains "ungated list returns the unlabeled issue"  '"number": 2' "$OUT"
file_run any-claimable
assert_eq "ungated any-claimable reports work" "0" "$RC"

# ── 2. Configured: the queue only offers approved issues ────────────────────
set_config swarm
file_run list --state open
assert_contains "gated list keeps the approved issue"   '"number": 1' "$OUT"
assert_not_contains "gated list drops the unapproved issue" '"number": 2' "$OUT"

# ── 3. THE property: claim refuses an unapproved issue by number ────────────
file_run claim 2
assert_eq "claiming an unapproved issue fails cleanly (exit 1)" "1" "$RC"
assert_contains "refusal names the missing label" "swarm" "$OUT"
if [ -f "$REPO/.issues/open/002.md" ] && [ ! -f "$REPO/.issues/working/002.md" ]; then
  pass "refused claim left the issue in open/"
else
  fail "refused claim moved the issue anyway"
fi

file_run claim 1
assert_eq "claiming an approved issue succeeds" "0" "$RC"
if [ -f "$REPO/.issues/working/001.md" ]; then
  pass "approved claim moved the issue to working/"
else
  fail "approved claim did not move the issue"
fi

# ── 4. any-claimable sees nothing when only unapproved issues remain ────────
# Issue 1 is now claimed, leaving only the unapproved issue 2 in open/.
file_run any-claimable
assert_eq "any-claimable reports no work when only unapproved issues remain" "1" "$RC"

# ── 5. An explicitly empty env override disables a configured gate ──────────
OUT=$(cd "$REPO" && ISSUE_DIR_PATH="$REPO/.issues" AUTOCODER_REQUIRED_LABEL="" \
  python3 "$FILE_BACKEND" list --state open 2>&1)
assert_contains "empty AUTOCODER_REQUIRED_LABEL turns the gate off" '"number": 2' "$OUT"

# The env var also overrides the configured label with a different one.
OUT=$(cd "$REPO" && ISSUE_DIR_PATH="$REPO/.issues" AUTOCODER_REQUIRED_LABEL="other" \
  python3 "$FILE_BACKEND" list --state open 2>&1)
assert_not_contains "a different env label gates on that label instead" '"number": 2' "$OUT"

# ── 6. GitHub backend: the claimable search carries the label ───────────────
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'STUB'
#!/bin/bash
prev=""
for a in "$@"; do
  [ "$prev" = "--search" ] && printf '%s' "$a" > "$GH_SEARCH_CAPTURE"
  prev="$a"
done
if printf '%s\n' "$@" | grep -q -- '--jq'; then echo 0; else echo '[]'; fi
STUB
chmod +x "$TMP/bin/gh"

gh_search() {  # gh_search <label-or-empty> <verb...>
  local label="$1"; shift
  export GH_SEARCH_CAPTURE="$TMP/gh_search.txt"
  : > "$GH_SEARCH_CAPTURE"
  (cd "$REPO" && PATH="$TMP/bin:$PATH" AUTOCODER_REQUIRED_LABEL="$label" \
    bash "$ROOT/$SCRIPTS/issues-gh.sh" "$@" >/dev/null 2>&1)
  cat "$GH_SEARCH_CAPTURE"
}
assert_contains "gh list --state open requires the label" 'label:"swarm"' "$(gh_search swarm list --state open)"
assert_contains "gh any-claimable requires the label"     'label:"swarm"' "$(gh_search swarm any-claimable)"
assert_not_contains "ungated gh search carries no label requirement" 'label:"swarm"' "$(gh_search "" list --state open)"
# `working` is not gated: an issue claimed before the gate was configured must
# stay visible rather than look like a worker that vanished.
assert_not_contains "gh list --state working is not gated" 'label:"swarm"' "$(gh_search swarm list --state working)"

# ── 7. Jira backend: the claimable JQL carries the label ────────────────────
cat > "$TMP/bin/curl" <<'STUB'
#!/bin/bash
data=""; prev=""
for a in "$@"; do
  [ "$prev" = "--data" ] && data="$a"
  prev="$a"
done
printf '%s\n' "$data" >> "$CURL_CAPTURE"
printf '{"issues":[]}\n200'
STUB
chmod +x "$TMP/bin/curl"

jira_jql() {  # jira_jql <label-or-empty> <verb...>
  export CURL_CAPTURE="$TMP/curl.txt"
  local label="$1"; shift
  : > "$CURL_CAPTURE"
  (cd "$REPO" && PATH="$TMP/bin:$PATH" AUTOCODER_REQUIRED_LABEL="$label" \
    JIRA_BASE_URL="https://acme.atlassian.net" JIRA_PROJECT="ENG" \
    JIRA_EMAIL="you@acme.com" JIRA_API_TOKEN="secret" \
    bash "$ROOT/$SCRIPTS/issues-jira.sh" "$@" >/dev/null 2>&1)
  head -1 "$CURL_CAPTURE" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read() or "{}").get("jql",""))'
}
assert_contains "jira open JQL requires the label" 'labels = "swarm"' "$(jira_jql swarm list --state open)"
# An unlabeled issue cannot carry the approval label, so the `labels is EMPTY`
# escape hatch must not survive the gate.
assert_not_contains "gated jira JQL drops the labels-is-EMPTY disjunct" 'labels is EMPTY' "$(jira_jql swarm list --state open)"
assert_contains "ungated jira JQL keeps labels is EMPTY" 'labels is EMPTY' "$(jira_jql "" list --state open)"

# ── 8. ADO backend: the claimable WIQL carries the tag ──────────────────────
ado_wiql() {  # ado_wiql <label-or-empty> <verb...>
  export CURL_CAPTURE="$TMP/curl.txt"
  local label="$1"; shift
  : > "$CURL_CAPTURE"
  (cd "$REPO" && PATH="$TMP/bin:$PATH" AUTOCODER_REQUIRED_LABEL="$label" \
    ADO_ORG_URL="https://dev.azure.com/acme" ADO_PROJECT="Proj" ADO_PAT="secret" \
    bash "$ROOT/$SCRIPTS/issues-ado.sh" "$@" >/dev/null 2>&1)
  head -1 "$CURL_CAPTURE" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read() or "{}").get("query",""))'
}
assert_contains "ado open WIQL requires the tag" "[System.Tags] CONTAINS 'swarm'" "$(ado_wiql swarm list --state open)"
assert_not_contains "ungated ado WIQL carries no tag requirement" "CONTAINS 'swarm'" "$(ado_wiql "" list --state open)"

echo ""
echo "$PASS passed / $FAIL failed / $((PASS + FAIL)) total"
[ "$FAIL" -eq 0 ]
