#!/bin/bash
# tests/test_private_tmp_root.sh — merge/sentinel state lives in a private per-user
# directory, and merge-launch.sh never runs a run.sh it did not just write (#213).
#
# The state files used to sit in shared /tmp under predictable names
# (autocoder-merge-<repo-id>-<issue>.run.sh, .pid, .exit, .log). On a multi-user host
# another local user could pre-create the .run.sh; the `> "$RUNSCRIPT"` redirect failed
# silently and `setsid "$RUNSCRIPT"` ran their file as us.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$ROOT/plugins/autocoder/scripts"
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want '$2', got '$3'"; fi; }
mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# shellcheck source=../plugins/autocoder/scripts/repo-id-fns.sh
source "$S/repo-id-fns.sh"
U=$(id -u)

# ── autocoder_tmp_root ──────────────────────────────────────────────────────
eq "AUTOCODER_TMP wins when set" "$TMP/explicit" "$(AUTOCODER_TMP="$TMP/explicit" autocoder_tmp_root)"

mkdir -p "$TMP/base1"
R=$(unset AUTOCODER_TMP; AUTOCODER_TMP_BASE="$TMP/base1" autocoder_tmp_root)
eq "default is <base>/autocoder-<uid>" "$TMP/base1/autocoder-$U" "$R"
eq "created mode 0700" "700" "$(mode "$R")"

mkdir -p "$TMP/base2/autocoder-$U"; chmod 777 "$TMP/base2/autocoder-$U"
R=$(unset AUTOCODER_TMP; AUTOCODER_TMP_BASE="$TMP/base2" autocoder_tmp_root)
eq "an existing dir of ours that is too open is tightened" "700" "$(mode "$R")"

# A symlink planted at the per-user name is not followed: fall back to XDG state.
mkdir -p "$TMP/base3" "$TMP/elsewhere"
ln -s "$TMP/elsewhere" "$TMP/base3/autocoder-$U"
R=$(unset AUTOCODER_TMP; AUTOCODER_TMP_BASE="$TMP/base3" XDG_STATE_HOME="$TMP/xdg" autocoder_tmp_root)
eq "a symlinked per-user dir is refused; XDG state is used" "$TMP/xdg/autocoder/tmp" "$R"
eq "fallback is 0700 too" "700" "$(mode "$R")"

# A non-directory at both places: no safe root, exit 1.
mkdir -p "$TMP/base4" "$TMP/xdg4/autocoder"
: > "$TMP/base4/autocoder-$U"; : > "$TMP/xdg4/autocoder/tmp"
(unset AUTOCODER_TMP; AUTOCODER_TMP_BASE="$TMP/base4" XDG_STATE_HOME="$TMP/xdg4" autocoder_tmp_root) >/dev/null 2>&1
eq "no safe directory: exit 1" "1" "$?"

# ── every state writer/reader resolves through the helper ──────────────────
for f in merge-launch.sh merge-poll.sh merge-queue-fns.sh main-sentinel.sh merge-to-integration.sh; do
  if grep -v '^\s*#' "$S/$f" | grep -q 'AUTOCODER_TMP:-/tmp'; then
    bad "$f still defaults to shared /tmp"
  else
    grep -q 'autocoder_tmp_root' "$S/$f" && ok "$f uses autocoder_tmp_root" || bad "$f: no autocoder_tmp_root"
  fi
done

# ── merge-launch.sh: a planted run.sh is never written through or executed ─
export AUTOCODER_TMP="$TMP/state"; mkdir -p "$AUTOCODER_TMP"
export AUTOCODER_GATE_CACHE_DIR="$TMP/gate-cache" ISSUE_SOURCE=file
git init --bare -q "$TMP/origin.git"
git init -q "$TMP/worker"
cd "$TMP/worker" || exit 1
git config user.email t@example.com; git config user.name T
git remote add origin "$TMP/origin.git"
echo base > README.md; git add README.md; git commit -q -m base
git branch -M master; git push -q origin master
git checkout -q -b feature/issue-21301
echo fix > fix.txt; git add fix.txt; git commit -q -m fix; git push -q origin feature/issue-21301
BASE="$AUTOCODER_TMP/autocoder-merge-$(autocoder_repo_id "$PWD")-21301"

# The "attacker" file: if it ever runs, it leaves a marker.
printf '#!/bin/bash\ntouch %q\n' "$TMP/PWNED" > "$TMP/evil.sh"; chmod +x "$TMP/evil.sh"
cp "$TMP/evil.sh" "$TMP/evil-orig.sh"
ln -s "$TMP/evil.sh" "$BASE.run.sh"
OUT=$(bash "$S/merge-launch.sh" --feature feature/issue-21301 --issue 21301 --integration master \
  --test-cmd true 2>&1); RC=$?
eq "launch with a planted symlink run.sh still succeeds" "0" "$RC"
[ ! -L "$BASE.run.sh" ] && [ -O "$BASE.run.sh" ] && ok "run.sh replaced by our own file" || bad "run.sh still the planted link"
cmp -s "$TMP/evil.sh" "$TMP/evil-orig.sh" && ok "the planted target was not written through" || bad "symlink target was overwritten"
eq "run.sh is 0700" "700" "$(mode "$BASE.run.sh")"
for _ in $(seq 1 50); do [ -f "$BASE.exit" ] && break; sleep 0.2; done
[ ! -e "$TMP/PWNED" ] && ok "the planted script never ran" || bad "attacker script executed"

# A run.sh that cannot be created (a directory squats the name): refuse, launch nothing.
git checkout -q -b feature/issue-21302 master
echo two > two.txt; git add two.txt; git commit -q -m two; git push -q origin feature/issue-21302
BASE2="$AUTOCODER_TMP/autocoder-merge-$(autocoder_repo_id "$PWD")-21302"
mkdir -p "$BASE2.run.sh/sub"
OUT=$(bash "$S/merge-launch.sh" --feature feature/issue-21302 --issue 21302 --integration master \
  --test-cmd true 2>&1); RC=$?
eq "unwritable run.sh: launch refused (exit 1)" "1" "$RC"
echo "$OUT" | grep -q "could not write" && ok "refusal names the problem" || bad "refusal output: $OUT"
[ ! -e "$BASE2.pid" ] && ok "nothing was started" || bad "a job started anyway"
[ -z "$(ls -d "$BASE2".scripts.* 2>/dev/null)" ] && ok "the snapshot was cleaned up" || bad "snapshot left behind"

echo ""
echo "Tests: $FAIL failed, $PASS passed, $((PASS + FAIL)) total"
[ "$FAIL" -eq 0 ]
