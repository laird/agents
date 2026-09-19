#!/bin/bash
# tests/test_issues_gh_deps.sh — dependency-edge verbs on the GitHub backend.
#
# Covers issues-gh.sh deps/block/unblock plus the blocker-aware claim and
# any-claimable: native dependencies endpoints (blocked_by POST/DELETE/GET,
# blocking GET), the GHES `blocked-by-<m>` label fallback and its 404
# discrimination (a dependencies 404 also means "issue not found" — the label
# path may only be taken for an issue proven to exist), script-side R2
# (idempotent re-add exit 0, self-edge exit 1, two-node cycle exit 1),
# dangling blocker = satisfied (R4), and the KTD5/KTD8 exit discipline
# (any resolution failure → exit 3, never "no work").
#
# `gh` is a stub on PATH: it records every argv line to GH_CAPTURE and answers
# from a canned world configured via GH_STUB_* env vars — no network, and the
# real gh is never reached (a tripwire file catches any invocation that
# escapes the harness).

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
BACKEND="$ROOT/plugins/autocoder/scripts/issues-gh.sh"

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

assert_eq() {
  local label="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then pass "$label"; else fail "$label — want '$want', got '$got'"; fi
}

# `--` terminates grep's option parsing: needles like "-X POST" start with `-`.
assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then pass "$label"
  else fail "$label — '$needle' not found in: $haystack"; fi
}

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    fail "$label — '$needle' unexpectedly present in: $haystack"
  else pass "$label"; fi
}

# assert_json <label> <json> <python-expr over parsed dict d>
assert_json() {
  local label="$1" json="$2" expr="$3"
  if echo "$json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
sys.exit(0 if ($expr) else 1)
" 2>/dev/null; then
    pass "$label"
  else
    fail "$label — expr '$expr' false for: $(echo "$json" | tr -d '\n')"
  fi
}

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
CAP="$TMP/capture.txt"
TRIPWIRE="$TMP/gh-tripwire"

# ── Stub gh ─────────────────────────────────────────────────────────────────
# World state via env: GH_STUB_ISSUES (existing numbers), GH_STUB_CLOSED,
# GH_STUB_EDGES ("n:m1,m2" blocked_by edges, blocker issue id = 10<m>),
# GH_STUB_LABELS ("n:lab1,lab2"), GH_STUB_CANDIDATES (open-search results),
# GH_STUB_NO_NATIVE (dependencies endpoints 404 — GHES), GH_STUB_NO_BLOCKING
# (only the blocking endpoint 404s), GH_STUB_FAIL_STATE_OF (issue numbers
# whose `--json state` view fails HTTP 500), GH_STUB_FAIL_DEPS (blocked_by
# GET fails HTTP 500). Responses are emitted post-`--jq` (raw lines), since
# each endpoint is only ever queried with one jq program.
cat > "$TMP/bin/gh" <<'STUB'
#!/bin/bash
if [ -z "${GH_CAPTURE:-}" ]; then
  echo "gh invoked outside the harness: $*" >> "$(dirname "$0")/../gh-tripwire"
  exit 97
fi
printf '%s\n' "$*" >> "$GH_CAPTURE"

has_issue() { local i; for i in $GH_STUB_ISSUES; do [ "$i" = "$1" ] && return 0; done; return 1; }
is_closed() { local i; for i in $GH_STUB_CLOSED; do [ "$i" = "$1" ] && return 0; done; return 1; }
labels_of() { local e; for e in $GH_STUB_LABELS; do case "$e" in "$1":*) printf '%s' "${e#*:}"; return ;; esac; done; }
blocked_by_of() {   # "num id" lines for issue $1
  local e m rest
  for e in $GH_STUB_EDGES; do
    case "$e" in
      "$1":*)
        rest="${e#*:}"
        while [ -n "$rest" ]; do
          m="${rest%%,*}"
          echo "$m 10$m"
          [ "$rest" = "$m" ] && break
          rest="${rest#*,}"
        done ;;
    esac
  done
}
blocking_of() {     # issues whose blocked_by list contains $1
  local e n ms
  for e in $GH_STUB_EDGES; do
    n="${e%%:*}"; ms="${e#*:}"
    case ",$ms," in *,"$1",*) echo "$n" ;; esac
  done
}
label_holders() {   # issues carrying the label blocked-by-$1
  local e n ls
  for e in $GH_STUB_LABELS; do
    n="${e%%:*}"; ls="${e#*:}"
    case ",$ls," in *,"blocked-by-$1",*) echo "$n" ;; esac
  done
}
not_found_api()  { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
server_error()   { echo "gh: Internal Server Error (HTTP 500)" >&2; exit 1; }
not_found_view() { echo "GraphQL: Could not resolve to an Issue with the number of $1. (repository.issue)" >&2; exit 1; }

case "$1" in
  issue)
    case "$2" in
      view)
        n="$3"
        json=""; prev=""
        for a in "$@"; do [ "$prev" = "--json" ] && json="$a"; prev="$a"; done
        has_issue "$n" || not_found_view "$n"
        if [ "$json" = "state" ]; then
          for f in $GH_STUB_FAIL_STATE_OF; do [ "$f" = "$n" ] && server_error; done
          if is_closed "$n"; then echo '{"state":"CLOSED"}'; else echo '{"state":"OPEN"}'; fi
        else
          out='{"labels":['; first=1
          ls="$(labels_of "$n")"
          while [ -n "$ls" ]; do
            l="${ls%%,*}"
            [ "$first" -eq 1 ] || out="$out,"
            first=0
            out="$out{\"name\":\"$l\"}"
            [ "$ls" = "$l" ] && break
            ls="${ls#*,}"
          done
          echo "$out]}"
        fi ;;
      edit)
        has_issue "$3" || not_found_view "$3"
        exit 0 ;;
      list)
        search=""; prev=""
        for a in "$@"; do [ "$prev" = "--search" ] && search="$a"; prev="$a"; done
        case "$search" in
          *blocked-by-*)
            want="${search#*blocked-by-}"; want="${want%%\"*}"
            label_holders "$want" ;;
          *)
            for c in $GH_STUB_CANDIDATES; do echo "$c"; done ;;
        esac ;;
    esac ;;
  api)
    method="GET"; prev=""; path=""
    for a in "$@"; do
      [ "$prev" = "-X" ] && method="$a"
      case "$a" in repos/*) path="$a" ;; esac
      prev="$a"
    done
    t="${path#*/issues/}"; n="${t%%/*}"
    case "$path" in
      */dependencies/blocked_by/*)          # DELETE .../blocked_by/<id>
        has_issue "$n" || not_found_api
        [ -n "${GH_STUB_NO_NATIVE:-}" ] && not_found_api
        exit 0 ;;
      */dependencies/blocked_by)
        has_issue "$n" || not_found_api
        [ -n "${GH_STUB_NO_NATIVE:-}" ] && not_found_api
        [ -n "${GH_STUB_FAIL_DEPS:-}" ] && server_error
        [ "$method" = "POST" ] && exit 0
        blocked_by_of "$n" ;;
      */dependencies/blocking)
        has_issue "$n" || not_found_api
        [ -n "${GH_STUB_NO_NATIVE:-}" ] && not_found_api
        [ -n "${GH_STUB_NO_BLOCKING:-}" ] && not_found_api
        blocking_of "$n" ;;
      repos/*)                              # GET issues/<n> --jq .id
        has_issue "$n" || not_found_api
        echo "10$n" ;;
    esac ;;
  label)
    exit 0 ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/gh"

# ── World + runner ──────────────────────────────────────────────────────────
reset_world() {
  W_ISSUES="1 2 3 5 7 8 9 10"   # 6 and 99 deliberately do not exist
  W_EDGES=""
  W_CLOSED="3"
  W_LABELS=""
  W_CANDIDATES=""
  W_NO_NATIVE=""
  W_NO_BLOCKING=""
  W_FAIL_STATE=""
  W_FAIL_DEPS=""
}

run() {
  : > "$CAP"
  # BASH_ENV="" keeps a user profile from prepending PATH entries that would
  # shadow the stub; AUTOCODER_REQUIRED_LABEL="" pins the approval gate off.
  OUT=$(BASH_ENV="" PATH="$TMP/bin:$PATH" \
    GH_CAPTURE="$CAP" \
    GH_STUB_ISSUES="$W_ISSUES" GH_STUB_EDGES="$W_EDGES" \
    GH_STUB_CLOSED="$W_CLOSED" GH_STUB_LABELS="$W_LABELS" \
    GH_STUB_CANDIDATES="$W_CANDIDATES" \
    GH_STUB_NO_NATIVE="$W_NO_NATIVE" GH_STUB_NO_BLOCKING="$W_NO_BLOCKING" \
    GH_STUB_FAIL_STATE_OF="$W_FAIL_STATE" GH_STUB_FAIL_DEPS="$W_FAIL_DEPS" \
    AUTOCODER_REQUIRED_LABEL="" \
    "$BACKEND" "$@" 2>"$TMP/err.txt")
  RC=$?
  ERR=$(cat "$TMP/err.txt")
  CAPTURED=$(cat "$CAP")
}

# ── 1. block issues POST to blocked_by with the blocker's issue_id ──────────
reset_world
run block 2 --on 1
assert_eq "block 2 --on 1 exits 0" "0" "$RC"
assert_contains "block POSTs to issue 2's blocked_by endpoint" \
  "api -X POST repos/{owner}/{repo}/issues/2/dependencies/blocked_by" "$CAPTURED"
assert_contains "block sends the blocker's issue_id (#1 → 101)" \
  "issue_id=101" "$CAPTURED"
assert_contains "stub gh intercepted the calls (real gh never reached)" \
  "issue view 2" "$CAPTURED"

# ── 2. unblock issues DELETE .../blocked_by/<issue_id> ──────────────────────
reset_world
W_EDGES="2:1"
run unblock 2 --on 1
assert_eq "unblock 2 --on 1 exits 0" "0" "$RC"
assert_contains "unblock DELETEs the edge by the blocker's issue id" \
  "api -X DELETE repos/{owner}/{repo}/issues/2/dependencies/blocked_by/101" "$CAPTURED"

# unblock of an absent edge is a clean negative
reset_world
run unblock 2 --on 1
assert_eq "unblock of an absent edge exits 1" "1" "$RC"
assert_not_contains "absent-edge unblock issues no DELETE" "-X DELETE" "$CAPTURED"

# ── 3. deps reads both directions (blocked_by GET + blocking GET) ───────────
reset_world
W_EDGES="2:1,3 5:2"
run deps 2
assert_eq "deps 2 exits 0" "0" "$RC"
assert_contains "deps GETs the blocked_by endpoint" \
  "issues/2/dependencies/blocked_by" "$CAPTURED"
assert_contains "deps GETs the blocking endpoint" \
  "issues/2/dependencies/blocking" "$CAPTURED"
assert_json "deps reports blocker 1 open" "$OUT" \
  '{"number": 1, "state": "open"} in d["blockedBy"]'
assert_json "deps reports blocker 3 closed" "$OUT" \
  '{"number": 3, "state": "closed"} in d["blockedBy"]'
assert_json "deps reports the blocks direction" "$OUT" 'd["blocks"] == [5]'

# deps on a nonexistent issue is a clean negative
reset_world
run deps 99
assert_eq "deps 99 (missing issue) exits 1" "1" "$RC"

# blocking endpoint absent while blocked_by works → blocks: [] plus a note
reset_world
W_EDGES="2:1"
W_NO_BLOCKING=1
run deps 2
assert_eq "deps with blocking endpoint absent still exits 0" "0" "$RC"
assert_json "blocked_by still reported natively" "$OUT" \
  'd["blockedBy"] == [{"number": 1, "state": "open"}]'
assert_json "blocks degrades to [] when blocking endpoint 404s" "$OUT" \
  'd["blocks"] == []'
assert_contains "degradation is surfaced on stderr" "blocking" "$ERR"

# ── 4. GHES fallback: label path for an issue that EXISTS ───────────────────
reset_world
W_NO_NATIVE=1
run block 2 --on 7
assert_eq "fallback block 2 --on 7 exits 0" "0" "$RC"
assert_contains "fallback creates the blocked-by-7 label" \
  "label create blocked-by-7" "$CAPTURED"
assert_contains "fallback adds the label to the blocked issue" \
  "issue edit 2 --add-label blocked-by-7" "$CAPTURED"
assert_not_contains "fallback never POSTs to the native endpoint" \
  "-X POST" "$CAPTURED"

# fallback deps: blockedBy parsed back from the issue's own labels
reset_world
W_NO_NATIVE=1
W_LABELS="2:blocked-by-7,P1"
run deps 2
assert_eq "fallback deps 2 exits 0" "0" "$RC"
assert_json "fallback deps parses blocked-by-7 from labels" "$OUT" \
  'd["blockedBy"] == [{"number": 7, "state": "open"}]'

# fallback blocks direction via label search
run deps 7
assert_eq "fallback deps 7 exits 0" "0" "$RC"
assert_json "fallback blocks read via blocked-by-7 label search" "$OUT" \
  'd["blocks"] == [2]'
assert_contains "fallback searches by label, positive form" \
  'label:"blocked-by-7"' "$CAPTURED"

# fallback unblock removes the label
reset_world
W_NO_NATIVE=1
W_LABELS="2:blocked-by-7"
run unblock 2 --on 7
assert_eq "fallback unblock exits 0" "0" "$RC"
assert_contains "fallback unblock removes the label" \
  "issue edit 2 --remove-label blocked-by-7" "$CAPTURED"

# ── 5. 404 discrimination: missing issue is exit 1, never the label path ────
reset_world
W_NO_NATIVE=1
run block 99 --on 1
assert_eq "block on a missing issue exits 1" "1" "$RC"
assert_not_contains "missing issue never triggers label create" \
  "label create" "$CAPTURED"
assert_not_contains "missing issue never gets a label added" \
  "--add-label" "$CAPTURED"

run block 2 --on 99
assert_eq "block --on a missing blocker exits 1" "1" "$RC"
assert_not_contains "missing blocker never triggers a write" \
  "--add-label" "$CAPTURED"

# ── 6. R2 script-side: idempotent re-add, self-edge, two-node cycle ─────────
reset_world
W_EDGES="2:1"
run block 2 --on 1
assert_eq "idempotent re-add exits 0" "0" "$RC"
assert_not_contains "idempotent re-add records no POST" "-X POST" "$CAPTURED"
assert_not_contains "idempotent re-add records no label write" "--add-label" "$CAPTURED"

reset_world
run block 2 --on 2
assert_eq "self-edge block 2 --on 2 exits 1" "1" "$RC"
assert_not_contains "self-edge records no POST" "-X POST" "$CAPTURED"

reset_world
W_EDGES="2:1"
run block 1 --on 2
assert_eq "two-node cycle block 1 --on 2 exits 1" "1" "$RC"
assert_contains "cycle refusal names the reverse edge" "cycle" "$ERR"
assert_not_contains "cycle records no POST" "-X POST" "$CAPTURED"

# ── 7. claim honors blockers ─────────────────────────────────────────────────
reset_world
W_EDGES="8:7"
run claim 8
assert_eq "claim with an open blocker exits 1" "1" "$RC"
assert_contains "refusal names the open blocker" "#7" "$ERR"
assert_not_contains "refused claim never adds the working label" \
  "--add-label working" "$CAPTURED"

W_CLOSED="3 7"
run claim 8
assert_eq "claim succeeds once the blocker is closed" "0" "$RC"
assert_contains "successful claim adds the working label" \
  "issue edit 8 --add-label working" "$CAPTURED"

# dangling blocker counts as satisfied (R4)
reset_world
W_EDGES="2:6"    # issue 6 does not exist
run deps 2
assert_json "dangling blocker reports state missing" "$OUT" \
  'd["blockedBy"] == [{"number": 6, "state": "missing"}]'
run claim 2
assert_eq "dangling blocker does not block the claim" "0" "$RC"

# ── 8. any-claimable: first candidate blocked, second claimable (KTD8) ──────
reset_world
W_CANDIDATES="8 9"
W_EDGES="8:7"
run any-claimable
assert_eq "any-claimable skips the blocked candidate and exits 0" "0" "$RC"
assert_contains "any-claimable bounds the candidate sweep" "-L 50" "$CAPTURED"

W_CANDIDATES="8"
run any-claimable
assert_eq "any-claimable exits 1 when every candidate is blocked" "1" "$RC"

reset_world
run any-claimable
assert_eq "any-claimable exits 1 on an empty queue" "1" "$RC"

# ── 9. resolution failure is exit 3, never a clean negative (KTD5) ──────────
reset_world
W_EDGES="8:7"
W_FAIL_STATE="7"     # blocker state view fails HTTP 500
run claim 8
assert_eq "claim exits 3 when blocker state resolution fails" "3" "$RC"
W_CANDIDATES="8"
run any-claimable
assert_eq "any-claimable exits 3 when blocker state resolution fails" "3" "$RC"

reset_world
W_EDGES="8:7"
W_FAIL_DEPS=1        # blocked_by GET itself fails HTTP 500
run claim 8
assert_eq "claim exits 3 when the deps fetch fails" "3" "$RC"
W_CANDIDATES="8"
run any-claimable
assert_eq "any-claimable exits 3 when the deps fetch fails" "3" "$RC"

# ── usage errors ────────────────────────────────────────────────────────────
reset_world
run deps
assert_eq "deps without a number exits 2" "2" "$RC"
run block 2
assert_eq "block without --on exits 2" "2" "$RC"
run unblock 2
assert_eq "unblock without --on exits 2" "2" "$RC"

# ── tripwire: nothing escaped the harness to a real gh ──────────────────────
if [ -f "$TRIPWIRE" ]; then
  fail "gh was invoked outside the harness — $(wc -l < "$TRIPWIRE") call(s)"
  sed 's/^/       /' "$TRIPWIRE"
else
  pass "no gh invocation escaped the stub harness"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
