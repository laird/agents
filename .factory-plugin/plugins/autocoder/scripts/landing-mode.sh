#!/usr/bin/env bash
#
# landing-mode.sh — decide how a branch lands from what its diff touches (#165).
#
# `### Merge Mode` is one value per repo. A change to a CI workflow, a hook, a
# merge or sentinel script, an installer or auth code should not land the same
# way as a typo fix. `.autocoder.json` may list high-risk path globs:
#
#   { "risk": { "high": [".github/workflows/**", "**/install*.sh"] } }
#
# A diff that touches any of them lands as a pull request even when the repo
# merges directly. The diff decides, not the issue's priority or the worker.
#
# Usage:
#   landing-mode.sh --mode <merge|pr> --base <ref> [--head <ref>]
#
# Prints the landing mode to use (`merge` or `pr`; any other configured value
# is passed through unchanged unless the diff is high-risk). When a high-risk
# path forces `pr`, the matched paths are listed on stderr.
#
# The globs are read from `.autocoder.json` AS IT IS ON <base>, not from the
# working tree, so a branch cannot lower its own tier by editing the config.
# While any globs are configured, `.autocoder.json` itself counts as high-risk.
#
# Globs match the repo-relative path: `*` and `?` stay within one path segment,
# `**` spans any number of segments (`**/x` also matches a top-level `x`), and
# `[...]` is a character class. Renames count as both the old and new path, so
# moving a file out of a protected directory still needs a PR.
#
# Exit codes:
#   0  mode printed
#   2  usage error, unreadable diff, or a malformed `risk` setting on <base>.
#      Callers must not land on a 2: silently merging is the unsafe default.

set -euo pipefail

MODE=""; BASE=""; HEAD_REF="HEAD"
while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODE="${2-}"; shift 2 ;;
    --base) BASE="${2-}"; shift 2 ;;
    --head) HEAD_REF="${2-}"; shift 2 ;;
    -h|--help) sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "landing-mode: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
[ -n "$MODE" ] || { echo "landing-mode: --mode is required" >&2; exit 2; }
[ -n "$BASE" ] || { echo "landing-mode: --base is required" >&2; exit 2; }

# Already a PR: nothing can make it less reviewed.
if [ "$MODE" = "pr" ]; then echo pr; exit 0; fi

# A missing file on <base> means no tiers; any other git failure is an error.
if git cat-file -e "${BASE}:.autocoder.json" 2>/dev/null; then
  CONFIG=$(git show "${BASE}:.autocoder.json") || {
    echo "landing-mode: cannot read .autocoder.json on ${BASE}" >&2; exit 2; }
else
  CONFIG=""
fi

CONFIG="$CONFIG" BASE="$BASE" HEAD_REF="$HEAD_REF" MODE="$MODE" python3 - <<'PY'
import json, os, re, subprocess, sys

def fail(msg):
    print(f"landing-mode: {msg}", file=sys.stderr)
    sys.exit(2)

def glob_re(pat):
    out, i, n = [], 0, len(pat)
    while i < n:
        c = pat[i]
        if pat.startswith("**/", i):
            out.append("(?:.*/)?"); i += 3
        elif pat.startswith("**", i):
            out.append(".*"); i += 2
        elif c == "*":
            out.append("[^/]*"); i += 1
        elif c == "?":
            out.append("[^/]"); i += 1
        elif c == "[":
            j = pat.find("]", i + 2)
            if j < 0:
                out.append(re.escape(c)); i += 1
            else:
                body = pat[i + 1:j]
                if body.startswith("!"):
                    body = "^" + body[1:]
                # A class never matches "/", like * and ?.
                out.append("(?!/)[" + body.replace("\\", "\\\\") + "]"); i = j + 1
        else:
            out.append(re.escape(c)); i += 1
    return re.compile("".join(out) + r"\Z")

raw = os.environ["CONFIG"]
globs = []
if raw.strip():
    try:
        cfg = json.loads(raw)
    except ValueError as e:
        fail(f".autocoder.json on the base is not valid JSON ({e}); refusing to guess a landing mode")
    risk = cfg.get("risk") if isinstance(cfg, dict) else None
    if risk is not None:
        high = risk.get("high", []) if isinstance(risk, dict) else None
        if not isinstance(high, list) or not all(isinstance(g, str) and g for g in high):
            fail('"risk.high" in .autocoder.json must be a list of non-empty path globs')
        globs = list(high)

if globs:
    globs.append(".autocoder.json")   # the tiers themselves are high-risk
patterns = [(g, glob_re(g)) for g in globs]

hits = []
# NUL-separated and unquoted: by default git prints a non-ASCII, tab, newline
# or quote in a path as a C-quoted string, which no glob would match.
spec = f'{os.environ["BASE"]}...{os.environ["HEAD_REF"]}'
diff = subprocess.run(["git", "-c", "core.quotePath=false", "diff", "--name-only",
                       "-z", "--no-renames", spec], capture_output=True)
if diff.returncode != 0:
    fail(f"cannot diff {spec}")
changed = [os.fsdecode(b) for b in diff.stdout.split(b"\0") if b]

for path in changed:
    for g, rx in patterns:
        if rx.match(path):
            hits.append((path, g))
            break

if hits:
    print("landing-mode: high-risk paths changed, landing as a pull request:", file=sys.stderr)
    for path, g in hits:
        print(f"  {path!r}  (risk.high: {g})" if "\n" in path else f"  {path}  (risk.high: {g})", file=sys.stderr)
    print("pr")
else:
    print(os.environ["MODE"])
PY
