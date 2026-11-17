#!/usr/bin/env bash
# revert-breaker.sh — the revert circuit breaker (#252, #168).
#
# After the sentinel reverts a culprit push (main-sentinel.sh), it runs this script. When the
# revert rate over the newest landed issues (revert-rate.sh) reaches the threshold, it opens a
# tracking issue labelled `revert-breaker`. While such an issue is open, merge-launch.sh lands
# work as a pull request instead of merging it. A human closes the issue to restore `merge`.
# The open issue is the switch: shared by every worktree, visible on the tracker, and
# reversible without a commit.
#
# Usage:
#   revert-breaker.sh [--ref REV]    check the rate; open the breaker issue when it trips
#   revert-breaker.sh --active       is the breaker open? prints the issue number
#   revert-breaker.sh --land-as-pr --feature BRANCH --issue N [--feature-sha SHA]
#                     [--integration BRANCH] [--summary-file PATH] [--own-issue]
#                                    push BRANCH, open a PR, and (--own-issue) park issue N
#                                    under `awaiting-integration`. merge-launch.sh runs this.
#
# Settings: `.autocoder.json` "revertBreaker", either "off" or an object (defaults shown):
#   {"window": 20, "threshold": 0.15, "minReverts": 2}
# It trips when, over the newest `window` landed issues, at least `minReverts` were reverted
# and reverts / landed is at or above `threshold`. It is checked only after a revert, so a
# breaker closed while the window is still bad trips again at the next revert. "off" disables the breaker entirely: it
# never trips, and --active reports it closed even if an old breaker issue is still open.
#
# Exit status:
#   check        0 done (tripped, already open, below threshold, or off) · 1 the rate or the
#                tracker could not be read, or the issue could not be filed · 2 usage/config
#   --active     0 open (number on stdout) · 1 not open, or off · 2 tracker or config error
#   --land-as-pr 0 PR open (and issue parked) · 1 push, PR or label failed · 2 usage

_RB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="revert-breaker"
GH="${AUTOCODER_GH:-gh}"   # the PR client; tests point it elsewhere

MODE=check REF="" FEATURE="" FEATURE_SHA="" ISSUE="" INTEGRATION="main" SUMMARY="" OWN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --ref|--feature|--feature-sha|--issue|--integration|--summary-file)
      [ $# -ge 2 ] || { echo "revert-breaker: $1 needs a value" >&2; exit 2; }
      case "$1" in
        --ref) REF="$2" ;; --feature) FEATURE="$2" ;; --feature-sha) FEATURE_SHA="$2" ;;
        --issue) ISSUE="$2" ;; --integration) INTEGRATION="$2" ;; --summary-file) SUMMARY="$2" ;;
      esac
      shift 2 ;;
    --active)     MODE=active; shift ;;
    --land-as-pr) MODE=land; shift ;;
    --own-issue)  OWN=1; shift ;;
    -h|--help) sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "revert-breaker: unknown argument: $1" >&2; exit 2 ;;
  esac
done

# Settings live in the main checkout's .autocoder.json, the file issue-config.sh reads, so
# every worktree of the repo sees the same breaker settings.
_rb_wts=$(git worktree list --porcelain 2>/dev/null)
TOP=$(printf '%s\n' "$_rb_wts" | sed -n '1s/^worktree //p')
[ -n "$TOP" ] || TOP=$(pwd)

# Prints "off", or "<window> <threshold> <minReverts>". Exit 2 on a bad setting.
rb_config() {
  python3 - "$TOP/.autocoder.json" <<'PY'
import json, sys
cfg = {"window": 20, "threshold": 0.15, "minReverts": 2}
try:
    with open(sys.argv[1]) as f:
        raw = json.load(f).get("revertBreaker", cfg)
except FileNotFoundError:
    raw = cfg
except (ValueError, AttributeError) as e:
    sys.exit(f"revert-breaker: cannot read {sys.argv[1]}: {e}")
if raw == "off" or raw is False:
    print("off"); sys.exit(0)
if not isinstance(raw, dict):
    print('revert-breaker: "revertBreaker" must be "off" or an object', file=sys.stderr); sys.exit(2)
unknown = set(raw) - set(cfg)
if unknown:
    print(f'revert-breaker: unknown "revertBreaker" key(s): {", ".join(sorted(unknown))}', file=sys.stderr); sys.exit(2)
cfg.update(raw)
w, t, m = cfg["window"], cfg["threshold"], cfg["minReverts"]
def is_int(v): return isinstance(v, int) and not isinstance(v, bool)
if not (is_int(w) and w > 0):
    print('revert-breaker: "window" must be a positive whole number', file=sys.stderr); sys.exit(2)
if isinstance(t, bool) or not isinstance(t, (int, float)) or not 0 < t <= 1:
    print('revert-breaker: "threshold" must be a number above 0 and at most 1', file=sys.stderr); sys.exit(2)
if not (is_int(m) and m > 0):
    print('revert-breaker: "minReverts" must be a positive whole number', file=sys.stderr); sys.exit(2)
print(w, t, m)
PY
}

# The open breaker issue's number, if any. Lists every state and keeps the open ones: an
# `--state open` list leaves out issues carrying a blocking label such as needs-approval.
# An empty AUTOCODER_REQUIRED_LABEL turns the approval gate off for this one read, or the
# file backend would hide the breaker issue, which never carries the approval label.
# Exit 0 with or without a match; non-zero when the tracker cannot be read.
rb_open_issue() {
  local rows
  rows=$(AUTOCODER_REQUIRED_LABEL="" issue_list --state all --label "$LABEL") || return 1
  printf '%s' "$rows" | python3 -c '
import json, sys
rows = json.load(sys.stdin)
for r in rows:
    names = [l.get("name") if isinstance(l, dict) else l for l in r.get("labels", [])]
    if str(r.get("state", "")).upper() == "OPEN" and "revert-breaker" in names:
        print(r["number"]); break'
}

# Source the issue layer only when an issue source is configured. In an unconfigured repo
# issue-config.sh would prompt, and with stdin at EOF it would pick a backend and write
# .autocoder.json. Returns 1 when there is no tracker to read.
rb_load_issues() {
  local src
  src=$(python3 -c '
import json, sys
try:
    print(json.load(open(sys.argv[1])).get("issueSource", ""))
except Exception:
    print("")' "$TOP/.autocoder.json")
  [ -n "$src" ] || [ -n "${ISSUE_SOURCE:-}" ] || return 1
  # shellcheck source=issue-fns.sh
  source "${_RB_DIR}/issue-fns.sh" </dev/null
}

CONFIG=$(rb_config); rc=$?
[ $rc -eq 0 ] || exit 2

case "$MODE" in
# ── --active ─────────────────────────────────────────────────────────────────────────────────
active)
  [ "$CONFIG" = off ] && exit 1
  rb_load_issues || exit 1
  OPEN=$(rb_open_issue) || { echo "revert-breaker: cannot read the tracker" >&2; exit 2; }
  [ -n "$OPEN" ] || exit 1
  echo "$OPEN"
  exit 0 ;;

# ── check: after a revert ────────────────────────────────────────────────────────────────────
check)
  if [ "$CONFIG" = off ]; then
    echo "ℹ️  Revert breaker is off (.autocoder.json revertBreaker)."
    exit 0
  fi
  read -r WINDOW THRESHOLD MIN <<<"$CONFIG"
  RATE_ARGS=(--last "$WINDOW" --json)
  [ -n "$REF" ] && RATE_ARGS+=(--ref "$REF")
  J=$(bash "${_RB_DIR}/revert-rate.sh" "${RATE_ARGS[@]}") \
    || { echo "revert-breaker: could not compute the revert rate" >&2; exit 1; }
  VERDICT=$(python3 -c '
import json, sys
j = json.loads(sys.argv[1]); t = float(sys.argv[2]); m = int(sys.argv[3])
rate = j.get("rate")
trip = rate is not None and j["reverts"] >= m and rate >= t
pct = "n/a" if rate is None else f"{rate * 100:.1f}%"
print("trip" if trip else "ok", j["reverts"], j["landed"], pct, f"{t * 100:g}%",
      ",".join(f"#{i}" for i in j["reverted_issues"]) or "-", j["window"]["ref"])
' "$J" "$THRESHOLD" "$MIN") || { echo "revert-breaker: unreadable revert-rate output" >&2; exit 1; }
  read -r STATE REVERTS LANDED PCT TPCT REVERTED WREF <<<"$VERDICT"
  SUMMARY_LINE="${REVERTS} of the newest ${LANDED} landed issue(s) on ${WREF} were reverted (${PCT}; trips at ${TPCT} with at least ${MIN} reverts)"
  if [ "$STATE" != trip ]; then
    echo "✅ Revert breaker holds: ${SUMMARY_LINE}."
    exit 0
  fi
  rb_load_issues || { echo "revert-breaker: no issue source configured; not filing a breaker issue" >&2; exit 1; }
  OPEN=$(rb_open_issue) || { echo "revert-breaker: cannot read the tracker; not filing a breaker issue" >&2; exit 1; }
  if [ -n "$OPEN" ]; then
    echo "ℹ️  Revert breaker already open as #${OPEN}: ${SUMMARY_LINE}."
    exit 0
  fi
  if [ "${ISSUE_SOURCE:-}" = github ]; then
    gh label create "$LABEL" --color b60205 \
      --description "Revert circuit breaker: while open, landing uses pr mode" >/dev/null 2>&1 || true
  fi
  BODY="## Revert circuit breaker tripped

The sentinel's revert rate passed the threshold, so landing has switched from \`merge\` to \`pr\`.

- **Window**: the newest ${WINDOW} landed issues on \`${WREF}\` (${LANDED} found)
- **Reverts**: ${REVERTS} (${PCT}); the breaker trips at ${TPCT} with at least ${MIN} reverts
- **Reverted issues**: ${REVERTED//,/, }

While this issue is open, every worker's merge job is replaced by a pull request
(\`merge-launch.sh\` → \`revert-breaker.sh --land-as-pr\`), and the issue is parked under
\`awaiting-integration\` until a human merges the PR.

### To restore \`merge\` mode

Close this issue once the cause of the reverts is understood. No commit is needed.
Set \`\"revertBreaker\": \"off\"\` in \`.autocoder.json\` to disable the breaker.

🤖 Filed by revert-breaker.sh (#252)"
  OUT=$(issue_create --title "Revert breaker: ${REVERTS} of ${LANDED} landed issues reverted, landing switched to pr mode" \
      --body "$BODY" --label "$LABEL" --label needs-approval) \
    || { echo "revert-breaker: could not file the breaker issue" >&2; exit 1; }
  NUM=$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["number"])' 2>/dev/null)
  echo "🚨 Revert breaker tripped: ${SUMMARY_LINE}. Opened #${NUM:-?}; landing uses pr mode until it is closed."
  exit 0 ;;

# ── --land-as-pr ─────────────────────────────────────────────────────────────────────────────
land)
  [ -n "$FEATURE" ] && [ -n "$ISSUE" ] \
    || { echo "revert-breaker: --land-as-pr needs --feature and --issue" >&2; exit 2; }
  case "$FEATURE" in -*) echo "revert-breaker: --feature must name a branch" >&2; exit 2 ;; esac
  rb_load_issues || { echo "revert-breaker: no issue source configured" >&2; exit 1; }
  BREAKER=$(rb_open_issue 2>/dev/null)
  SRC="${FEATURE_SHA:-$FEATURE}"
  if ! git push -q origin "${SRC}:refs/heads/${FEATURE}"; then
    echo "❌ Revert breaker: could not push ${FEATURE}. Nothing landed; no label changed." >&2
    exit 1
  fi
  # No gh to open a PR with (a repo not on GitHub): the pushed branch is the review copy.
  # Park the issue with a note for the human who merges it, so landing never stalls.
  if ! command -v "$GH" >/dev/null 2>&1; then
    echo "🔀 Revert breaker${BREAKER:+ #${BREAKER}} is open and gh is not installed: ${FEATURE} is pushed for a human to review and merge."
    if [ "$OWN" = 1 ] && ! issue_park "$ISSUE" --comment "🔀 **Pushed for review, not merged**: branch \`${FEATURE}\`

The revert circuit breaker${BREAKER:+ (#${BREAKER})} is open and no \`gh\` is available to open a pull request. Review the branch and merge it into \`${INTEGRATION}\` by hand. Parked under \`awaiting-integration\` until then." >/dev/null; then
      echo "❌ Revert breaker: issue #${ISSUE} could not be parked; it still holds its label." >&2
      exit 1
    fi
    exit 0
  fi
  URL=$("$GH" pr view "$FEATURE" --json url,state --jq 'select(.state == "OPEN") | .url' 2>/dev/null)
  if [ -z "$URL" ]; then
    TITLE=$(issue_get "$ISSUE" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("title",""))' 2>/dev/null)
    REF_LINE="Issue #${ISSUE}"
    [ "${ISSUE_SOURCE:-}" = github ] && REF_LINE="Closes #${ISSUE}"
    PR_BODY="${REF_LINE}

Opened as a pull request instead of merged because the revert circuit breaker is open${BREAKER:+ (#${BREAKER})}.
Review and merge it by hand; close the breaker issue to restore \`merge\` mode.
"
    [ -n "$SUMMARY" ] && [ -f "$SUMMARY" ] && PR_BODY+="
$(cat "$SUMMARY")
"
    PR_BODY+="
🤖 Generated with [Claude Code](https://claude.com/claude-code)"
    URL=$("$GH" pr create --base "$INTEGRATION" --head "$FEATURE" \
            --title "#${ISSUE}: ${TITLE:-$FEATURE}" --body "$PR_BODY" 2>&1 | tail -1)
    case "$URL" in
      http*) ;;
      *) echo "❌ Revert breaker: could not open a PR for ${FEATURE}: ${URL}. The branch is pushed; no label changed." >&2
         exit 1 ;;
    esac
  fi
  echo "🔀 Revert breaker${BREAKER:+ #${BREAKER}} is open: ${FEATURE} goes to review as ${URL} instead of merging."
  if [ "$OWN" = 1 ]; then
    if ! issue_park "$ISSUE" --comment "🔀 **Opened as a pull request**: ${URL}

The revert circuit breaker${BREAKER:+ (#${BREAKER})} is open, so this was not merged. Parked under \`awaiting-integration\` until a human merges the PR." >/dev/null; then
      echo "❌ Revert breaker: PR ${URL} is open but issue #${ISSUE} could not be parked; it still holds its label." >&2
      exit 1
    fi
  fi
  exit 0 ;;
esac
