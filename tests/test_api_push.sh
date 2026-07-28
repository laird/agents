#!/bin/bash
# Tests for the API push fallback and the never-close-on-failed-push guard
# (issues #23 and #26).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/plugins/autocoder/scripts/api-push.py"
MIRROR="$ROOT/.agent/scripts/api-push.py"
FIX_MD="$ROOT/plugins/autocoder/commands/fix.md"
FIX_MIRROR="$ROOT/.agent/workflows/fix.md"

fail() { echo "FAIL: $1" >&2; exit 1; }

# ── 1. Script exists in both trees and is valid Python ───────────────────────
for f in "$SCRIPT" "$MIRROR"; do
  [ -f "$f" ] || fail "missing $f"
  python3 -m py_compile "$f" || fail "syntax error in $f"
done

# ── 2. Repo is inferred from origin, never hardcoded ─────────────────────────
grep -q 'def infer_repo' "$SCRIPT" || fail "no infer_repo()"
grep -qE '"?laird/agents"?' "$SCRIPT" && fail "repo appears hardcoded"

# infer_repo must handle both SSH and HTTPS remote forms.
INFER=$(cd "$ROOT" && python3 -c "
import sys; sys.path.insert(0, '$(dirname "$SCRIPT")')
import importlib.util
spec = importlib.util.spec_from_file_location('ap', '$SCRIPT')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(m.infer_repo())
")
[ -n "$INFER" ] || fail "infer_repo returned nothing"
case "$INFER" in */*) ;; *) fail "infer_repo returned '$INFER', want owner/name" ;; esac

# ── 3. Deletions are expressed as a null sha ─────────────────────────────────
grep -q '"sha": None' "$SCRIPT" || fail "deletions not handled (need null sha tree entry)"

# ── 4. File modes are preserved, not assumed ─────────────────────────────────
grep -q 'ls-tree' "$SCRIPT" || fail "modes not read from git"
grep -q '100755' "$SCRIPT" || fail "executable mode not handled"
grep -q '120000' "$SCRIPT" || fail "symlink mode not handled"

# ── 5. Content is base64-encoded so binary survives ──────────────────────────
grep -q 'b64encode' "$SCRIPT" || fail "content not base64-encoded"
grep -q '"encoding": "base64"' "$SCRIPT" || fail "blob encoding not declared base64"

# ── 6. Success is defined by verified content, not exit status ───────────────
# The whole point: a caller gates issue-closure on this, so "pushed" must mean
# "the remote tree equals the local tree".
grep -q 'def verify' "$SCRIPT" || fail "no verify()"
grep -q 'rev-parse' "$SCRIPT" || fail "verify does not compare tree OIDs"
python3 - "$SCRIPT" <<'PY' || exit 1
import re, sys
src = open(sys.argv[1]).read()
body = src[src.index("def push("):]
if "verify(" not in body:
    print("FAIL: push() never calls verify()", file=sys.stderr); sys.exit(1)
# The success return must come after verification, not before.
vi, ri = body.index("verify("), body.rindex("return 0")
if ri < vi:
    print("FAIL: push() returns success before verifying", file=sys.stderr); sys.exit(1)
PY

# ── 7. --dry-run must never be USED as the success check ─────────────────────
# It passes while a real push 403s, because it never sends the pack. Mentioning
# it in a comment is fine — invoking it is not, so strip comments/docstrings
# before checking rather than matching the bare string.
python3 - "$SCRIPT" <<'PY' || exit 1
import io, sys, tokenize
src = open(sys.argv[1], "rb")
code = []
prev = None
for tok in tokenize.tokenize(src.readline):
    if tok.type == tokenize.COMMENT:
        continue
    # A STRING that is its own statement is a docstring — drop it.
    if tok.type == tokenize.STRING and prev in (tokenize.INDENT, tokenize.NEWLINE,
                                                tokenize.NL, None):
        prev = tok.type
        continue
    code.append(tok.string)
    if tok.type not in (tokenize.NL, tokenize.NEWLINE):
        prev = tok.type
if "--dry-run" in " ".join(code):
    print("FAIL: api-push invokes --dry-run as a success check", file=sys.stderr)
    sys.exit(1)
PY

# ── 8. /fix gates closure on the push actually landing (#26) ─────────────────
for f in "$FIX_MD" "$FIX_MIRROR"; do
  name=$(basename "$(dirname "$f")")/$(basename "$f")
  grep -q 'PUSH_OK' "$f" || fail "$name: no PUSH_OK gate in the merge path"
  grep -q 'api-push.py' "$f" || fail "$name: does not fall back to api-push.py"
  # The guard: every issue_close must sit behind a publication check. Two shapes
  # are valid - the inline PUSH_OK gate (PR / simple paths), or delegation to
  # merge-to-integration.sh, which exits non-zero unless the push verified.
  python3 - "$f" <<'PYGATE' || exit 1
import sys
src = open(sys.argv[1]).read()
for idx in [i for i in range(len(src)) if src.startswith('issue_close', i)]:
    window = src[max(0, idx-2000):idx]
    # Valid gates, in order of what they prove:
    #   PUSH_OK                  - inline gate on the PR / simple paths
    #   merge-to-integration.sh  - delegated; that script exits non-zero unless
    #                              the push landed AND the tree verified
    #   ALL_CLOSED               - parent-of-subtasks rollup. This close pushes
    #                              nothing itself; its safety comes from each
    #                              sub-task's own close having been gated.
    if not any(g in window for g in ('PUSH_OK', 'merge-to-integration.sh', 'ALL_CLOSED')):
        line = src[:idx].count(chr(10)) + 1
        print("FAIL: %s: issue_close at line %d is not gated on publication"
              % (sys.argv[1], line), file=sys.stderr)
        sys.exit(1)
PYGATE
done

# -- 9. The live merge path falls back and VERIFIES (#23 + #26) --------------
MTI="$ROOT/plugins/autocoder/scripts/merge-to-integration.sh"
[ -f "$MTI" ] || fail "missing merge-to-integration.sh"
bash -n "$MTI" || fail "merge-to-integration.sh syntax error"
grep -q 'api-push.py' "$MTI" || fail "merge path has no API fallback"
grep -q '_MTI_DIR}/api-push.py' "$MTI" || fail "api-push.py referenced via an undefined dir var"
grep -q 'REMOTE_TREE' "$MTI" || fail "merge path does not verify the ref actually moved"
python3 - "$MTI" <<'PYVER' || exit 1
import sys
src = open(sys.argv[1]).read()
i = src.find('REMOTE_TREE')
if 'exit 1' not in src[i:i+900]:
    print("FAIL: tree verification does not exit non-zero on mismatch", file=sys.stderr)
    sys.exit(1)
PYVER

echo "ok api-push"
