#!/usr/bin/env bash
# render-review-digest.sh — the reviewer-first body for every place /fix publishes
# work: a PR body (`pr` mode), a merge job's close comment (`merge` mode), and a
# decomposed parent's rollup close (#196).
#
# WHY THIS EXISTS:
#   Each publish site in fix.md carried its own hand-written placeholder body
#   ("[Detailed explanation of fix]"), and nothing stopped one from shipping
#   unfilled. A reviewer got no structure, and no size, for changes as large as
#   +13,628/−194. This script renders one fixed structure, computes Size itself
#   (the agent never writes it), and refuses to print a body that still has an
#   unfilled slot, so a publish site that checks its exit status cannot ship one.
#
# USAGE:
#   render-review-digest.sh --issue N --base REF [--pr] [--sections FILE]
#   render-review-digest.sh --size-only --base REF [--head REF]
#
#   --sections FILE   Markdown written by the agent with any of these headings:
#                       ## Intent
#                       ## Where to look
#                       ## Verification
#                       ## Not verified / confidence
#                       ## Why net growth      (only needed when Size asks for it)
#                     A heading that is missing or empty renders as a {{FILL: ...}}
#                     slot, which fails the placeholder check below.
#   --pr              Prefix "Closes #N" (PR bodies). Omit for close comments,
#                     where the issue is being closed anyway.
#   --head REF        The commit whose change is measured (default HEAD). The
#                     spot-check selector (#197) measures a landed commit that is
#                     not checked out.
#   --size-only       Print one machine-readable line and exit 0:
#                       changed=<n> files=<n> mirror_changed=<n> mirror_files=<n> over=<yes|no>
#                     `over` compares the non-mirror counts with the thresholds
#                     (REVIEW FIT, below).
#
# SIZE: `git diff --numstat <base>...<head>`. Parity mirrors are counted on their
#   own line, not in the review size, because a reviewer reads the source once:
#   .agent/, plugins/*/skills/, codex-plugins/, .factory/, .factory-plugin/, .pi/.
#
# REVIEW FIT thresholds: .autocoder.json `reviewFit.maxChangedLines` (default 400)
#   and `reviewFit.maxFiles` (default 10), overridable with AUTOCODER_REVIEW_MAX_LINES
#   / AUTOCODER_REVIEW_MAX_FILES. Not under the `review` key: that one is already
#   the string always|merge-only|off that switches the pre-landing review.
#
# PLACEHOLDER CHECK: the rendered body must not contain `{{FILL:` or the legacy
#   `[Detailed explanation`. General `<...>` / `[...]` text is NOT rejected:
#   verification output and prose legitimately contain `Vec<T>`, `<sha>`, HTML,
#   redirections and markdown links.
#
# Exit: 0 body printed on stdout; 1 unfilled placeholder (body on stdout, the
#   offending lines on stderr); 2 bad arguments or the base ref does not resolve.

set -uo pipefail

ISSUE=""; BASE=""; HEAD_REF=HEAD; PR=0; SECTIONS=""; SIZE_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --issue)     ISSUE="${2:-}"; shift 2 ;;
    --base)      BASE="${2:-}"; shift 2 ;;
    --head)      HEAD_REF="${2:-}"; shift 2 ;;
    --sections)  SECTIONS="${2:-}"; shift 2 ;;
    --pr)        PR=1; shift ;;
    --size-only) SIZE_ONLY=1; shift ;;
    *) echo "render-review-digest.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

[ -n "$BASE" ] || { echo "render-review-digest.sh: --base is required" >&2; exit 2; }
git rev-parse --verify -q "${BASE}^{commit}" >/dev/null \
  || { echo "render-review-digest.sh: base '$BASE' does not resolve to a commit" >&2; exit 2; }
git rev-parse --verify -q "${HEAD_REF}^{commit}" >/dev/null \
  || { echo "render-review-digest.sh: head '$HEAD_REF' does not resolve to a commit" >&2; exit 2; }
if [ "$SIZE_ONLY" -eq 0 ] && [ -z "$ISSUE" ]; then
  echo "render-review-digest.sh: --issue is required" >&2; exit 2
fi
if [ -n "$SECTIONS" ] && [ ! -r "$SECTIONS" ]; then
  echo "render-review-digest.sh: cannot read --sections '$SECTIONS'" >&2; exit 2
fi

# ── Size ────────────────────────────────────────────────────────────────────
# One pass over numstat: "<added>\t<deleted>\t<path>"; binary files show "-".
read -r INS DEL FILES M_INS M_DEL M_FILES < <(
  # --no-renames: a rename is a delete plus an add, each under its own plain path
  # (numstat would otherwise print "a => b", which the mirror match cannot read).
  git -c core.quotePath=false diff --no-renames --numstat "${BASE}...${HEAD_REF}" | awk -F'\t' '
    function mirror(p) {
      return p ~ /^\.agent\// || p ~ /^plugins\/[^\/]+\/skills\// || p ~ /^codex-plugins\// \
          || p ~ /^\.factory\// || p ~ /^\.factory-plugin\// || p ~ /^\.pi\//
    }
    { a = ($1 == "-") ? 0 : $1; d = ($2 == "-") ? 0 : $2
      if (mirror($3)) { mi += a; md += d; mf++ } else { i += a; dl += d; f++ } }
    END { printf "%d %d %d %d %d %d\n", i, dl, f, mi, md, mf }')

MAX_LINES="${AUTOCODER_REVIEW_MAX_LINES:-}"
MAX_FILES="${AUTOCODER_REVIEW_MAX_FILES:-}"
if [ -z "$MAX_LINES" ] || [ -z "$MAX_FILES" ]; then
  _top=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
  read -r _jl _jf < <(python3 - "$_top/.autocoder.json" <<'PY' 2>/dev/null || echo "400 10"
import json, sys
try:
    fit = json.load(open(sys.argv[1])).get("reviewFit") or {}
except (OSError, ValueError):
    fit = {}
def num(key, default):
    try:
        return int(fit.get(key, default))
    except (TypeError, ValueError):
        return default
print(num("maxChangedLines", 400), num("maxFiles", 10))
PY
)
  MAX_LINES="${MAX_LINES:-${_jl:-400}}"
  MAX_FILES="${MAX_FILES:-${_jf:-10}}"
fi

CHANGED=$((INS + DEL))
OVER=no
if [ "$CHANGED" -gt "$MAX_LINES" ] || [ "$FILES" -gt "$MAX_FILES" ]; then OVER=yes; fi

if [ "$SIZE_ONLY" -eq 1 ]; then
  echo "changed=$CHANGED files=$FILES mirror_changed=$((M_INS + M_DEL)) mirror_files=$M_FILES over=$OVER"
  exit 0
fi

# ── Sections ────────────────────────────────────────────────────────────────
# section <heading> — the body under "## <heading>" in $SECTIONS, trimmed.
# Headings inside ``` / ~~~ fences are content, not headings: pasted markdown or
# test output must neither end a section nor start one. CRLF and trailing
# whitespace on a heading line are tolerated.
section() {
  [ -n "$SECTIONS" ] || return 0
  tr -d '\r' < "$SECTIONS" | awk -v h="## $1" '
    /^[[:space:]]*(```|~~~)/ { fence = !fence; if (on) print; next }
    !fence && /^## / {
      line = $0; sub(/[[:space:]]+$/, "", line)
      if (on) exit
      if (line == h) { on = 1; next }
    }
    on { print }' | sed -e '/./,$!d' | sed -e ':a' -e '/^\n*$/{$d;N;ba' -e '}'
}
slot() {  # slot <heading> <fill hint>
  local body; body=$(section "$1")
  if [ -n "$body" ]; then printf '%s\n' "$body"; else printf '{{FILL: %s}}\n' "$2"; fi
}

BODY_FILE=$(mktemp "${TMPDIR:-/tmp}/review-digest.XXXXXX") \
  || { echo "render-review-digest.sh: mktemp failed" >&2; exit 2; }
trap 'rm -f "$BODY_FILE"' EXIT
{
  if [ "$PR" -eq 1 ]; then printf 'Closes #%s\n\n' "$ISSUE"; fi
  printf '## Intent\n'
  slot "Intent" "one sentence: what problem this solves and for whom"
  printf '\n## Where to look\n'
  slot "Where to look" "the 1-3 hunks (file:line) where a mistake would matter; everything else labelled mechanical, with a one-line reason"
  printf '\n## Verification\n'
  slot "Verification" "exact commands run and their actual result lines, not \"tests pass\""
  printf '\n## Not verified / confidence\n'
  slot "Not verified / confidence" "what was not exercised, known risks, confidence: high|medium|low"
  printf '\n## Size\n'
  printf '+%d/−%d across %d files' "$INS" "$DEL" "$FILES"
  [ "$OVER" = yes ] && printf ' (over the review-fit limit of %d lines / %d files)' "$MAX_LINES" "$MAX_FILES"
  printf '\n'
  if [ "$M_FILES" -gt 0 ]; then
    printf 'Parity mirrors, not counted above: +%d/−%d across %d files\n' "$M_INS" "$M_DEL" "$M_FILES"
  fi
  if [ "$INS" -gt $((3 * DEL)) ] && [ "$INS" -gt 200 ]; then
    printf '\nWhy net growth: '
    slot "Why net growth" "one sentence: why this change adds more than three times what it removes"
  fi
} > "$BODY_FILE"

cat "$BODY_FILE"
if grep -nE '\{\{FILL:|\[Detailed explanation' "$BODY_FILE" >&2; then
  echo "render-review-digest.sh: the body above has unfilled slots (lines listed); fill them in --sections and render again." >&2
  exit 1
fi
exit 0
