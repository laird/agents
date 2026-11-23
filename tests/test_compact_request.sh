#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255: never write the real event logs
# tests/test_compact_request.sh — a worker waiting to be compacted claims nothing new (#373).
#
# An inline /loop worker cannot type /compact into itself. Before #373 it gave each
# fresh claim back and the gate claimed the same issue again every tick, for hours.
# compact-request.sh records the request; fix-loop-gate.sh then claims nothing while
# it is pending, a stale request expires, and a shell-loop worker (a fresh process per
# issue) ignores it. The watchdog's side is in test_worker_auth_watchdog.sh.

PASS=0; FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)/plugins/autocoder/scripts"
CR="$SCRIPT_DIR/compact-request.sh"

assert_eq() {
  if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS + 1)); else echo "FAIL: $1 — want '$2', got '$3'"; FAIL=$((FAIL + 1)); fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
MAIN="$TMP/main"
mkdir -p "$MAIN"
cd "$MAIN" || exit 1
git init --quiet
git -c user.email=t@example.com -c user.name=T commit --quiet --allow-empty -m initial
mkdir -p .issues/open .issues/working .issues/blocked .issues/closed
printf '{"issueSource": "file", "issueDir": "%s/.issues"}\n' "$MAIN" > .autocoder.json
cat > .issues/open/001.md <<'EOF'
---
number: 1
title: Real work
priority: P1
labels: [bug, P1]
status: open
---
Body.
EOF
WORK_JSON="$TMP/work.json"
gate() { rm -f "$WORK_JSON"; AUTOCODER_WORK_JSON="$WORK_JSON" bash "$SCRIPT_DIR/fix-loop-gate.sh" 2>"$TMP/gate.err"; echo $?; }

# ── the verbs ────────────────────────────────────────────────────────────
bash "$CR" pending >/dev/null 2>&1; assert_eq "nothing pending at first" 1 $?
bash "$CR" request "holding for compaction before #1" >/dev/null; assert_eq "request succeeds" 0 $?
[ -f "$(git rev-parse --absolute-git-dir)/autocoder-compact-request" ] \
  && assert_eq "the request lives in the worktree's git dir" yes yes \
  || assert_eq "the request lives in the worktree's git dir" yes no
OUT=$(bash "$CR" pending); assert_eq "pending after a request" 0 $?
case "$OUT" in *"holding for compaction before #1"*) assert_eq "pending names the reason" yes yes ;;
  *) assert_eq "pending names the reason" yes "$OUT" ;; esac

# ── the gate claims nothing while it is pending ──────────────────────────
assert_eq "gate is idle while a compaction is pending" 1 "$(gate)"
[ ! -f "$WORK_JSON" ] && [ -f .issues/open/001.md ] \
  && assert_eq "no plan written and the issue stays open" yes yes \
  || assert_eq "no plan written and the issue stays open" yes no
grep -q "waiting for a requested compaction" "$TMP/gate.err" && assert_eq "the gate says why" yes yes \
  || assert_eq "the gate says why" yes "$(cat "$TMP/gate.err")"

# ── a shell-loop worker runs each issue in a fresh process: the request is moot ──
RC=$(rm -f "$WORK_JSON"; AUTOCODER_NEXT_FIX_FILE="$TMP/next" AUTOCODER_WORK_JSON="$WORK_JSON" \
  bash "$SCRIPT_DIR/fix-loop-gate.sh" 2>/dev/null; echo $?)
assert_eq "shell-loop mode claims despite the request" 0 "$RC"
rm -f "$(git rev-parse --absolute-git-dir)/autocoder-worker-state"
sed 's/number: 1/number: 2/; s/Real work/More work/; s/, working\]/]/' .issues/working/001.md | sed 's/^status: .*/status: open/' > .issues/open/002.md

# ── clear: the compacted session claims again ────────────────────────────
bash "$CR" clear; assert_eq "clear succeeds" 0 $?
bash "$CR" pending >/dev/null 2>&1; assert_eq "nothing pending after clear" 1 $?
bash "$CR" clear; assert_eq "clear with nothing pending is a no-op" 0 $?
assert_eq "gate claims once the request is cleared" 0 "$(AUTOCODER_RESUME_OWN_CLAIM=0 gate)"

# ── a request nobody answered expires, so a host with no watchdog never stalls ──
bash "$CR" request >/dev/null
OUT=$(AUTOCODER_COMPACT_REQUEST_TTL=0 bash "$CR" pending 2>&1); RC=$?
assert_eq "an expired request is not pending" 1 "$RC"
case "$OUT" in *expired*) assert_eq "expiry is said" yes yes ;; *) assert_eq "expiry is said" yes "$OUT" ;; esac
bash "$CR" pending >/dev/null 2>&1; assert_eq "an expired request is removed" 1 $?

# ── usage ────────────────────────────────────────────────────────────────
bash "$CR" bogus >/dev/null 2>&1; assert_eq "an unknown verb is a usage error" 2 $?
(cd "$TMP" && bash "$CR" pending >/dev/null 2>&1); assert_eq "outside a worktree is a usage error" 2 $?

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
