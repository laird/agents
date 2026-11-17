#!/bin/bash
# tests/test_spot_check_select.sh — the merge-mode spot-check selector (#197).
#
# Every trigger selects with its reason (P0/P1, security label, security path glob,
# size, sampled); free text such as "token" in the diff never selects; sampling is a
# pure function of the landed commit (rate 0 never, rate 1 always, same commit same
# answer); a merge commit is measured from its integration side; --apply labels and
# comments only when selected, through the configured backend.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$ROOT/plugins/autocoder/scripts/spot-check-select.sh"

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — expected '$3', got '$2'"; fi; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
g() { git -c user.email=t@example.com -c user.name=T "$@"; }

unset AUTOCODER_SPOT_CHECK_RATE AUTOCODER_REVIEW_MAX_LINES AUTOCODER_REVIEW_MAX_FILES
export ISSUE_SOURCE=file
export ISSUE_DIR_PATH="$TMP/issues"
mkdir -p "$ISSUE_DIR_PATH"/{open,working,blocked,closed}

cd "$TMP" || exit 1
git init -q -b master repo; cd repo || exit 1
printf 'a\n' > app.sh; g add .; g commit -qm base
BASE=$(git rev-parse HEAD)
# A small change whose diff mentions "token" and "auth": free text must not select.
printf 'a\n# refresh the auth token\n' > app.sh; g commit -qam small
SMALL=$(git rev-parse HEAD)
mkdir -p .github/workflows; printf 'on: push\n' > .github/workflows/ci.yml; g add .; g commit -qm ci
CI=$(git rev-parse HEAD)
seq 1 50 > big.txt; g add .; g commit -qm big
BIG=$(git rev-parse HEAD)

sel() { bash "$S" "$@" 2>/dev/null; }
# cfg_on <parent> <json> → a commit on <parent> that only adds .autocoder.json. The
# selector reads its settings from the BASE commit, so config is set up as a base.
cfg_on() {
  local cur; cur=$(git rev-parse --abbrev-ref HEAD)
  g checkout -q --detach "$1"; printf '%s\n' "$2" > .autocoder.json
  g add .autocoder.json; g commit -qm cfg; git rev-parse HEAD
  g checkout -q "$cur"
}

# ── 1. Priority ────────────────────────────────────────────────────────────────
eq "P0 selects" "$(AUTOCODER_SPOT_CHECK_RATE=0 sel --issue 1 --sha "$SMALL" --labels P0,bug)" P0
eq "P1 selects" "$(AUTOCODER_SPOT_CHECK_RATE=0 sel --issue 1 --sha "$SMALL" --labels enhancement,P1)" P1
eq "P2 alone does not select at rate 0" "$(AUTOCODER_SPOT_CHECK_RATE=0 sel --issue 1 --sha "$SMALL" --labels P2)" ""

# ── 2. Security ────────────────────────────────────────────────────────────────
eq "the security label selects" "$(AUTOCODER_SPOT_CHECK_RATE=0 sel --issue 1 --sha "$SMALL" --labels P3,security)" security
eq "no securityPaths configured: a workflow change alone does not select" \
  "$(AUTOCODER_SPOT_CHECK_RATE=0 sel --issue 1 --sha "$CI" --labels P3)" ""
CFG_WF=$(cfg_on "$SMALL" '{"spotCheck": {"securityPaths": [".github/workflows/*"]}}')
eq "a changed path matching a securityPaths glob selects" \
  "$(AUTOCODER_SPOT_CHECK_RATE=0 sel --issue 1 --sha "$CI" --base "$CFG_WF" --head "$CI" --labels P3)" security
CFG_WF0=$(cfg_on "$BASE" '{"spotCheck": {"securityPaths": [".github/workflows/*"]}}')
eq "a change outside the securityPaths globs does not" \
  "$(AUTOCODER_SPOT_CHECK_RATE=0 sel --issue 1 --sha "$SMALL" --base "$CFG_WF0" --head "$SMALL" --labels P3)" ""
CFG_TOK=$(cfg_on "$BASE" '{"spotCheck": {"securityPaths": ["*token*", "*auth*"]}}')
eq "free text 'token'/'auth' inside the diff never selects (paths only)" \
  "$(AUTOCODER_SPOT_CHECK_RATE=0 sel --issue 1 --sha "$SMALL" --base "$CFG_TOK" --head "$SMALL" --labels P3)" ""

# ── 3. Size (the #196 review-fit thresholds) ───────────────────────────────────
eq "a diff over the review-fit line threshold selects" \
  "$(AUTOCODER_SPOT_CHECK_RATE=0 AUTOCODER_REVIEW_MAX_LINES=10 sel --issue 1 --sha "$BIG" --labels P3)" size
eq "a diff under it does not" \
  "$(AUTOCODER_SPOT_CHECK_RATE=0 AUTOCODER_REVIEW_MAX_LINES=10 sel --issue 1 --sha "$SMALL" --labels P3)" ""
eq "an explicit --base/--head range is what gets measured" \
  "$(AUTOCODER_SPOT_CHECK_RATE=0 AUTOCODER_REVIEW_MAX_LINES=10 sel --issue 1 --sha "$SMALL" --base "$CI" --head "$BIG" --labels P3)" size
eq "--base SHA (a rollup with no diff of its own) never selects on size" \
  "$(AUTOCODER_SPOT_CHECK_RATE=0 AUTOCODER_REVIEW_MAX_LINES=0 AUTOCODER_REVIEW_MAX_FILES=0 sel --issue 1 --sha "$BIG" --base "$BIG" --labels P3)" ""

# A landed merge commit as merge-to-integration.sh makes it: origin/<integration> merged
# INTO the feature, so the integration side is the SECOND parent. Its default base must
# be that parent, so the measured change is the feature's own, not everyone else's.
g checkout -q -b feature "$BASE"
printf 'x\n' > small-feature.txt; g add .; g commit -qm feature-small
g merge -q --no-ff master -m "Merge origin/master into feature (pre-integration sync)"
LANDED_SMALL=$(git rev-parse HEAD)
eq "a merge commit is measured from its integration side: a small feature over a big integration change is not 'size'" \
  "$(AUTOCODER_SPOT_CHECK_RATE=0 AUTOCODER_REVIEW_MAX_LINES=10 sel --issue 1 --sha "$LANDED_SMALL" --labels P3)" ""
g checkout -q -b feature2 "$BIG"
seq 1 40 > big-feature.txt; g add .; g commit -qm feature-big
g checkout -q master; printf 'm\n' > m.txt; g add .; g commit -qm master-moves
g checkout -q feature2; g merge -q --no-ff master -m "Merge origin/master into feature2 (pre-integration sync)"
LANDED_BIG=$(git rev-parse HEAD)
eq "...and a big feature merged with a small integration change is 'size'" \
  "$(AUTOCODER_SPOT_CHECK_RATE=0 AUTOCODER_REVIEW_MAX_LINES=10 sel --issue 1 --sha "$LANDED_BIG" --labels P3)" size
g checkout -q master

# ── 4. Deterministic sampling ──────────────────────────────────────────────────
eq "rate 0 never samples" "$(AUTOCODER_SPOT_CHECK_RATE=0 sel --issue 1 --sha "$SMALL" --labels P3)" ""
ALL1=1
for c in $(git rev-list --all); do
  [ "$(AUTOCODER_SPOT_CHECK_RATE=1 sel --issue 1 --sha "$c" --base "$c" --labels P3)" = sampled ] || ALL1=0
done
eq "rate 1 always samples (every commit in the fixture)" "$ALL1" 1
# The decision is the first 32 bits of sha256(<full sha>) against rate × 2^32: pin it.
expect_for() {  # expect_for <sha> <rate>
  local h; h=$(printf '%s' "$1" | sha256sum | cut -c1-8)
  awk -v h=$((16#$h)) -v r="$2" 'BEGIN { print (h < r * 4294967296) ? "sampled" : "" }'
}
SEEN_BOTH=""
for c in $(git rev-list --all); do
  want=$(expect_for "$c" 0.5)
  got1=$(AUTOCODER_SPOT_CHECK_RATE=0.5 sel --issue 1 --sha "$c" --base "$c" --labels P3)
  got2=$(AUTOCODER_SPOT_CHECK_RATE=0.5 sel --issue 1 --sha "$c" --base "$c" --labels P3)
  short=$(AUTOCODER_SPOT_CHECK_RATE=0.5 sel --issue 1 --sha "${c:0:10}" --base "$c" --labels P3)
  [ "$got1" = "$want" ] && [ "$got2" = "$want" ] && [ "$short" = "$want" ] || { bad "sampling of $c is not hash(sha) < rate (want '$want', got '$got1'/'$got2', short '$short')"; continue; }
  SEEN_BOTH+="${want:-none} "
done
ok "sampling at rate 0.5 is hash(sha) < rate, stable across runs and for a short id"
CFG_R1=$(cfg_on "$BASE" '{"spotCheck": {"rate": 1}}')
eq "spotCheck.rate in the base commit's .autocoder.json is read" "$(sel --issue 1 --sha "$SMALL" --base "$CFG_R1" --head "$SMALL" --labels P3)" sampled
eq "AUTOCODER_SPOT_CHECK_RATE overrides it" "$(AUTOCODER_SPOT_CHECK_RATE=0 sel --issue 1 --sha "$SMALL" --base "$CFG_R1" --head "$SMALL" --labels P3)" ""
eq "an invalid env rate falls back to the configured one, not the default" \
  "$(AUTOCODER_SPOT_CHECK_RATE=2 sel --issue 1 --sha "$SMALL" --base "$CFG_R1" --head "$SMALL" --labels P3)" sampled
# The change under review cannot switch off its own sampling: a commit that sets
# rate 0 and drops securityPaths is judged by its base's settings.
CFG_STRICT=$(cfg_on "$BASE" '{"spotCheck": {"rate": 1, "securityPaths": [".github/*"]}}')
g checkout -q --detach "$CFG_STRICT"
printf '{"spotCheck": {"rate": 0}}\n' > .autocoder.json; g commit -qam "disable spot-check"
EVADE=$(git rev-parse HEAD); g checkout -q master
eq "a change that sets its own rate to 0 is still sampled at the base's rate" \
  "$(sel --issue 1 --sha "$EVADE" --labels P3)" sampled
printf '{"spotCheck": {"rate": 1}}\n' > .autocoder.json
eq "the working tree's .autocoder.json is not read when there is a base" \
  "$(sel --issue 1 --sha "$SMALL" --labels P3)" ""
rm -f .autocoder.json
OUT=$(AUTOCODER_SPOT_CHECK_RATE=banana bash "$S" --issue 1 --sha "$SMALL" --labels P3 2>&1 >/dev/null)
printf '%s' "$OUT" | grep -q "not a number" && ok "a malformed rate is reported and falls back to the default" \
  || bad "a malformed rate was not reported: $OUT"

# ── 5. Arguments ───────────────────────────────────────────────────────────────
bash "$S" --sha "$SMALL" >/dev/null 2>&1; eq "--issue is required" "$?" 2
bash "$S" --issue 1 >/dev/null 2>&1; eq "--sha is required" "$?" 2
bash "$S" --issue 1 --sha 'x; rm' >/dev/null 2>&1; eq "--sha must look like a commit id" "$?" 2
bash "$S" --issue 1 --sha "$SMALL" --bogus >/dev/null 2>&1; eq "an unknown argument is rejected" "$?" 2

# ── 6. Labels from the backend, and --apply ────────────────────────────────────
issue_file() {  # issue_file <bucket> <num> <labels>
  cat > "$ISSUE_DIR_PATH/$1/$(printf '%03d' "$2").md" <<MD
---
number: $2
title: Issue $2
labels: [$3]
status: $( [ "$1" = closed ] && echo closed || echo open )
---
Body.
MD
}
issue_file closed 7 "P1, enhancement"
issue_file closed 8 "P3"
eq "without --labels the issue's labels come from the backend" \
  "$(AUTOCODER_SPOT_CHECK_RATE=0 sel --issue 7 --sha "$SMALL")" P1

AUTOCODER_SPOT_CHECK_RATE=0 bash "$S" --issue 7 --sha "$SMALL" --apply >/dev/null 2>&1
AUTOCODER_SPOT_CHECK_RATE=0 bash "$S" --issue 8 --sha "$SMALL" --apply >/dev/null 2>&1
backend() { bash -c "source '$ROOT/plugins/autocoder/scripts/issue-fns.sh' && $*"; }
L7=$(backend issue_get 7 | jq -r '[.labels[].name] | join(",")')
case ",$L7," in *,spot-check,*) ok "--apply labels a selected issue spot-check" ;; *) bad "#7 not labelled: $L7" ;; esac
# The file backend folds comments into the body; read both.
backend issue_get 7 | jq -r '[.body, (.comments[]?.body)] | join("\n")' | grep -qF "🔎 Spot-check selected (reason: P1). Review digest: see the close comment above · \`git show ${SMALL}\`" \
  && ok "--apply posts the one-line comment naming the reason and the commit" \
  || bad "#7 lacks the spot-check comment: $(backend issue_get 7 | jq -c '[.body, .comments]')"
eq "the selected issue stays closed" "$(backend issue_get 7 | jq -r .state)" CLOSED
L8=$(backend issue_get 8 | jq -r '[.labels[].name] | join(",")')
case ",$L8," in *,spot-check,*) bad "#8 was labelled although not selected" ;; *) ok "--apply leaves an unselected issue alone" ;; esac
eq "an unselected issue gets no comment" "$(backend issue_get 8 | jq -r '[.body, (.comments[]?.body)] | join("\n")' | grep -c 'Spot-check')" 0
eq "/spot-check's query (--state all --label spot-check) finds the closed item" \
  "$(backend issue_list --state all --label spot-check | jq -r '[.[].number] | join(",")')" 7

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
