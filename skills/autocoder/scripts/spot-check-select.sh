#!/usr/bin/env bash
# spot-check-select.sh — pick a sample of merge-mode work for later human review (#197).
#
# WHY THIS EXISTS:
#   In `merge` mode the swarm lands work and closes the issue with no human ever seeing
#   the change; the only gates are automated. Spot-check marks some of that work for a
#   person to read afterwards. It never gates anything: the issue is closed exactly as
#   before, and a selected one also gets the `spot-check` label and a one-line comment.
#   `/spot-check` is where a human works through the labelled items.
#
# WHERE IT RUNS:
#   Wherever merge mode closes an issue as done: the merge job (merge-to-integration.sh
#   --own-issue, which every merge site in fix.md launches), the post-merge sentinel when
#   it closes a parked issue (main-sentinel.sh), and the decomposed-parent rollup in
#   fix.md. The merge job, not the worker, runs it because only the job knows the landed
#   commit and whether the issue actually closed. Call it only AFTER a successful close.
#
# USAGE:
#   spot-check-select.sh --issue N --sha SHA [--base REF] [--head REF] [--labels a,b,...] [--apply]
#
#   --sha SHA     The landed commit. The random sample is a hash of it, so the same
#                 commit always gets the same decision.
#   --base REF, --head REF
#                 The change is `git diff <base>...<head>` (head defaults to SHA). The
#                 merge job passes the integration tip it first saw and the feature tip,
#                 which is exactly the work under review. Without --base: for a merge
#                 commit, its second parent, because merge-to-integration.sh merges
#                 origin/<integration> INTO the feature (the integration side is parent
#                 2); otherwise its parent. Pass --base SHA for a change with no diff of
#                 its own, such as a decomposed parent's rollup.
#   --labels CSV  The issue's labels. Omitted: read with issue_get.
#   --apply       When selected, add the `spot-check` label and post the one-line
#                 comment. A tracker failure is a warning, never an error.
#
# SELECTED when any of these holds, reported in this order:
#   P0 / P1    the issue has the P0 or P1 label
#   security   a changed path matches a `spotCheck.securityPaths` glob in .autocoder.json
#              (default none; `*` also matches `/`), or the issue has the `security`
#              label. Free text in the diff or issue body is never matched: words like
#              "token" or "auth" appear in most commits here and would select most work.
#   size       render-review-digest.sh --size-only reports over=yes (the #196 review-fit
#              thresholds, mirrors excluded)
#   sampled    the first 32 bits of sha256(<full sha>) fall below rate × 2^32, where rate is
#              AUTOCODER_SPOT_CHECK_RATE, else `spotCheck.rate` (default 0.10), in [0, 1]
#
#   Not under the `review` key of .autocoder.json: that one is already the string
#   always|merge-only|off that switches the pre-landing review.
#
# OUTPUT: the reason (P0, P1, security, size, sampled) on stdout, or nothing.
# EXIT:   0 (selected or not); 2 bad arguments.

set -uo pipefail

_SCS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISSUE=""; SHA=""; BASE=""; HEAD_REF=""; LABELS=""; LABELS_GIVEN=0; APPLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --issue)  ISSUE="${2:-}"; shift 2 ;;
    --sha)    SHA="${2:-}"; shift 2 ;;
    --base)   BASE="${2:-}"; shift 2 ;;
    --head)   HEAD_REF="${2:-}"; shift 2 ;;
    --labels) LABELS="${2:-}"; LABELS_GIVEN=1; shift 2 ;;
    --apply)  APPLY=1; shift ;;
    *) echo "spot-check-select.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
[[ "$ISSUE" =~ ^[0-9]+$ ]] || { echo "spot-check-select.sh: --issue N is required" >&2; exit 2; }
[[ "$SHA" =~ ^[0-9a-fA-F]{4,64}$ ]] || { echo "spot-check-select.sh: --sha must be a commit id" >&2; exit 2; }

# The issue functions are needed to read labels and for --apply. Sourced lazily, so a
# caller that passes --labels and no --apply needs no tracker at all.
_scs_issue_fns() {
  declare -F issue_get >/dev/null && return 0
  # shellcheck source=issue-fns.sh
  source "${_SCS_DIR}/issue-fns.sh" 2>/dev/null
}

# A short id names the same commit as its full id: sample on the full one when it resolves.
FULL_SHA=$(git rev-parse --verify -q "${SHA}^{commit}" 2>/dev/null) || FULL_SHA=""
[ -n "$FULL_SHA" ] && SHA="$FULL_SHA"
SHA=$(printf '%s' "$SHA" | tr 'A-F' 'a-f')
if [ -n "$BASE" ]; then
  BASE=$(git rev-parse --verify -q "${BASE}^{commit}" 2>/dev/null) \
    || { echo "spot-check-select.sh: base does not resolve to a commit" >&2; exit 2; }
fi
HEAD_SHA=$(git rev-parse --verify -q "${HEAD_REF:-$SHA}^{commit}" 2>/dev/null) || HEAD_SHA=""
if [ -z "$BASE" ] && [ -n "$FULL_SHA" ]; then
  BASE=$(git rev-parse --verify -q "${FULL_SHA}^2" 2>/dev/null) \
    || BASE=$(git rev-parse --verify -q "${FULL_SHA}^1" 2>/dev/null) || BASE=""
fi

if [ "$LABELS_GIVEN" -eq 0 ]; then
  if _scs_issue_fns; then
    if _j=$(issue_get "$ISSUE" 2>/dev/null) && LABELS=$(printf '%s' "$_j" | jq -r '(.labels // []) | map(.name) | .[]' 2>/dev/null); then :
    else { LABELS=""; echo "spot-check-select.sh: could not read the labels of #${ISSUE}; P0/P1/security not checked" >&2; }
    fi
  else
    echo "spot-check-select.sh: cannot load the issue functions; P0/P1/security not checked" >&2
  fi
fi
# Exact names, one per line (a tracker label may itself contain a comma). --labels is a
# comma list, split here.
[ "$LABELS_GIVEN" -eq 1 ] && LABELS=$(printf '%s' "$LABELS" | tr ',' '\n')
has_label() { printf '%s\n' "$LABELS" | grep -qxF -- "$1"; }

# ── .autocoder.json spotCheck settings ──────────────────────────────────────────
# Never read from the change under review: the merge job runs inside the feature's
# worktree, and a change must not be able to switch off its own sampling. So: the BASE
# commit's copy (the integration side) when the file is tracked; otherwise (it is usually
# gitignored, local config written by /set-issue-source) the primary checkout's copy,
# beside the git common dir, which no feature commit can touch. The current worktree's
# file is never read.
CFG_RATE=""; SECURITY_GLOBS=(); _cfg_json=""
if [ -n "$BASE" ]; then
  _cfg_json=$(git show "${BASE}:.autocoder.json" 2>/dev/null) || _cfg_json=""
fi
if [ -z "$_cfg_json" ]; then
  _common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || _common=""
  if [ -n "$_common" ] && [ -f "$(dirname "$_common")/.autocoder.json" ]; then
    _cfg_json=$(cat "$(dirname "$_common")/.autocoder.json" 2>/dev/null) || _cfg_json=""
  fi
fi
if [ -n "$_cfg_json" ]; then
  if ! _cfg=$(printf '%s' "$_cfg_json" | python3 -c '
import json, sys
sc = json.load(sys.stdin).get("spotCheck") or {}
if not isinstance(sc, dict):
    sc = {}
print(sc.get("rate", ""))
paths = sc.get("securityPaths") or []
if isinstance(paths, list):
    for p in paths:
        if isinstance(p, str) and p.strip():
            print(p.strip())
' 2>/dev/null); then
    echo "spot-check-select.sh: cannot read the spotCheck settings in .autocoder.json; using defaults" >&2
    _cfg=""
  fi
  CFG_RATE=$(printf '%s\n' "$_cfg" | sed -n 1p)
  while IFS= read -r g; do [ -n "$g" ] && SECURITY_GLOBS+=("$g"); done < <(printf '%s\n' "$_cfg" | sed -n '2,$p')
fi
_valid_rate() { awk -v r="$1" 'BEGIN { exit !(r ~ /^([0-9]+\.?[0-9]*|\.[0-9]+)([eE][-+]?[0-9]+)?$/ && r + 0 <= 1) }'; }
RATE=0.10
for _r in "$CFG_RATE" "${AUTOCODER_SPOT_CHECK_RATE:-}"; do   # later wins
  [ -n "$_r" ] || continue
  if _valid_rate "$_r"; then RATE="$_r"
  else echo "spot-check-select.sh: rate '$_r' is not a number in [0, 1]; ignoring it" >&2
  fi
done

# ── Selection ───────────────────────────────────────────────────────────────────
REASON=""
if has_label P0; then REASON=P0
elif has_label P1; then REASON=P1
fi

if [ -z "$REASON" ]; then
  if has_label security; then
    REASON=security
  elif [ "${#SECURITY_GLOBS[@]}" -gt 0 ] && [ -n "$BASE" ] && [ -n "$HEAD_SHA" ]; then
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      for g in "${SECURITY_GLOBS[@]}"; do
        # shellcheck disable=SC2053  # $g is a glob on purpose
        if [[ "$path" == $g ]]; then REASON=security; break 2; fi
      done
    done < <(git -c core.quotePath=false diff --no-renames --name-only "${BASE}...${HEAD_SHA}" 2>/dev/null)
  fi
fi

if [ -z "$REASON" ] && [ -n "$BASE" ] && [ -n "$HEAD_SHA" ]; then
  SIZE_LINE=$(bash "${_SCS_DIR}/render-review-digest.sh" --size-only --base "$BASE" --head "$HEAD_SHA" 2>/dev/null) || SIZE_LINE=""
  case " $SIZE_LINE " in *" over=yes "*) REASON=size ;; esac
fi

if [ -z "$REASON" ]; then
  _h=$(printf '%s' "$SHA" | { sha256sum 2>/dev/null || shasum -a 256 2>/dev/null; } | cut -c1-8)
  if ! [[ "$_h" =~ ^[0-9a-f]{8}$ ]]; then
    echo "spot-check-select.sh: no sha256sum or shasum; not sampling" >&2
  elif awk -v h=$((16#$_h)) -v r="$RATE" 'BEGIN { exit !(h < r * 4294967296) }'; then
    REASON=sampled
  fi
fi

[ -n "$REASON" ] || exit 0
echo "$REASON"

if [ "$APPLY" -eq 1 ]; then
  if ! _scs_issue_fns; then
    echo "⚠️  spot-check: cannot load the issue functions; #${ISSUE} not labelled" >&2
    exit 0
  fi
  issue_update "$ISSUE" --add-label spot-check >/dev/null 2>&1 \
    || echo "⚠️  spot-check: could not add the 'spot-check' label to #${ISSUE}" >&2
  issue_comment "$ISSUE" --body "🔎 Spot-check selected (reason: ${REASON}). Review digest: see the close comment above · \`git show ${SHA}\`" >/dev/null 2>&1 \
    || echo "⚠️  spot-check: could not comment on #${ISSUE}" >&2
fi
exit 0
