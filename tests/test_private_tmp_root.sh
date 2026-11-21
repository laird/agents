#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255: never write the real event logs
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
# Every call pins XDG_STATE_HOME (and AUTOCODER_TMP_BASE) to a temp dir, so the
# suite never creates or reads the real ~/.local/state or /tmp/autocoder-<uid>.
eq "AUTOCODER_TMP wins when set" "$TMP/explicit" \
  "$(AUTOCODER_TMP="$TMP/explicit" XDG_STATE_HOME="$TMP/xdg0" autocoder_tmp_root)"
[ ! -e "$TMP/xdg0" ] && ok "AUTOCODER_TMP set: the state dir is not even created" || bad "state dir created despite AUTOCODER_TMP"

# Default (#272): the persistent XDG state dir, which survives a reboot.
R=$(unset AUTOCODER_TMP; AUTOCODER_TMP_BASE="$TMP/base1" XDG_STATE_HOME="$TMP/xdg1" autocoder_tmp_root)
eq "default is \$XDG_STATE_HOME/autocoder/merge" "$TMP/xdg1/autocoder/merge" "$R"
eq "created mode 0700" "700" "$(mode "$R")"
[ ! -e "$TMP/base1/autocoder-$U" ] && ok "/tmp fallback not created when the state dir is usable" || bad "/tmp dir created anyway"

R=$(unset AUTOCODER_TMP XDG_STATE_HOME; HOME="$TMP/home1" AUTOCODER_TMP_BASE="$TMP/base1h" autocoder_tmp_root)
eq "no XDG_STATE_HOME: ~/.local/state/autocoder/merge" "$TMP/home1/.local/state/autocoder/merge" "$R"

R=$(unset AUTOCODER_TMP; HOME="$TMP/home2" XDG_STATE_HOME="relative/state" AUTOCODER_TMP_BASE="$TMP/base1r" autocoder_tmp_root)
eq "a relative XDG_STATE_HOME is ignored (XDG spec)" "$TMP/home2/.local/state/autocoder/merge" "$R"

R=$(unset AUTOCODER_TMP; AUTOCODER_TMP_BASE="$TMP/base1s" XDG_STATE_HOME="$TMP/x d g" autocoder_tmp_root)
eq "a state path with a space works" "$TMP/x d g/autocoder/merge" "$R"

mkdir -p "$TMP/xdg2/autocoder/merge"; chmod 777 "$TMP/xdg2/autocoder/merge"
R=$(unset AUTOCODER_TMP; AUTOCODER_TMP_BASE="$TMP/base2" XDG_STATE_HOME="$TMP/xdg2" autocoder_tmp_root)
eq "an existing state dir of ours that is too open is tightened" "$TMP/xdg2/autocoder/merge" "$R"
eq "...to 0700" "700" "$(mode "$R")"

# An unsafe state dir is never used: fall back to /tmp/autocoder-<uid>.
mkdir -p "$TMP/base3" "$TMP/xdg3/autocoder" "$TMP/elsewhere"
ln -s "$TMP/elsewhere" "$TMP/xdg3/autocoder/merge"
R=$(unset AUTOCODER_TMP; AUTOCODER_TMP_BASE="$TMP/base3" XDG_STATE_HOME="$TMP/xdg3" autocoder_tmp_root 2>/dev/null)
eq "a symlinked state dir is refused; <base>/autocoder-<uid> is used" "$TMP/base3/autocoder-$U" "$R"
eq "fallback is 0700 too" "700" "$(mode "$R")"

mkdir -p "$TMP/base3b" "$TMP/xdg3b/autocoder"; : > "$TMP/xdg3b/autocoder/merge"
R=$(unset AUTOCODER_TMP; AUTOCODER_TMP_BASE="$TMP/base3b" XDG_STATE_HOME="$TMP/xdg3b" autocoder_tmp_root 2>/dev/null)
eq "a non-directory at the state path falls back" "$TMP/base3b/autocoder-$U" "$R"

# Group/other bits that cannot be cleared: a stub chmod that always fails.
mkdir -p "$TMP/base3c" "$TMP/xdg3c/autocoder/merge"; command chmod 777 "$TMP/xdg3c/autocoder/merge"
R=$(unset AUTOCODER_TMP; chmod() { return 1; }; AUTOCODER_TMP_BASE="$TMP/base3c" XDG_STATE_HOME="$TMP/xdg3c" autocoder_tmp_root 2>/dev/null)
eq "a too-open state dir that cannot be tightened falls back" "$TMP/base3c/autocoder-$U" "$R"
unset -f chmod

# A /tmp fallback that is itself a symlink is refused as well.
mkdir -p "$TMP/base3d" "$TMP/xdg3d/autocoder"; : > "$TMP/xdg3d/autocoder/merge"
ln -s "$TMP/elsewhere" "$TMP/base3d/autocoder-$U"
(unset AUTOCODER_TMP; AUTOCODER_TMP_BASE="$TMP/base3d" XDG_STATE_HOME="$TMP/xdg3d" autocoder_tmp_root) >/dev/null 2>&1
eq "symlinked fallback and unusable state dir: exit 1" "1" "$?"

# A non-directory at both places: no safe root, exit 1.
mkdir -p "$TMP/base4" "$TMP/xdg4/autocoder"
: > "$TMP/base4/autocoder-$U"; : > "$TMP/xdg4/autocoder/merge"
(unset AUTOCODER_TMP; AUTOCODER_TMP_BASE="$TMP/base4" XDG_STATE_HOME="$TMP/xdg4" autocoder_tmp_root) >/dev/null 2>&1
eq "no safe directory: exit 1" "1" "$?"

# ── the decision is visible only when it is a fallback ──────────────────────
ERR=$(unset AUTOCODER_TMP; AUTOCODER_TMP_BASE="$TMP/base5" XDG_STATE_HOME="$TMP/xdg5" autocoder_tmp_root 2>&1 >/dev/null)
eq "default path: nothing on stderr" "" "$ERR"
mkdir -p "$TMP/base6" "$TMP/xdg6/autocoder"; ln -s "$TMP/elsewhere" "$TMP/xdg6/autocoder/merge"
ERR=$(unset AUTOCODER_TMP; AUTOCODER_TMP_BASE="$TMP/base6" XDG_STATE_HOME="$TMP/xdg6" autocoder_tmp_root 2>&1 >/dev/null)
echo "$ERR" | grep -q "is a symlink); using $TMP/base6/autocoder-$U, which may not survive a reboot" \
  && ok "fallback names the reason and the /tmp dir it chose" || bad "fallback notice: '$ERR'"

# No HOME and no XDG_STATE_HOME (a bare cron/launchd/container environment):
# no state dir can be named, so /tmp is used, and it says why.
OUT=$(env -i PATH="$PATH" AUTOCODER_TMP_BASE="$TMP/base7" bash -c \
  'source "$1/repo-id-fns.sh"; autocoder_tmp_root' _ "$S" 2>"$TMP/err7")
eq "no HOME, no XDG_STATE_HOME: /tmp fallback" "$TMP/base7/autocoder-$U" "$OUT"
grep -q "neither XDG_STATE_HOME nor HOME is set" "$TMP/err7" && ok "...and says why" || bad "no-HOME notice: $(cat "$TMP/err7")"

# ── BSD/macOS userland (#272): no `stat -c`, no sha1sum ────────────────────
# A PATH holding only what the helpers need, with a BSD-style stat that rejects
# -c and answers -f %Lp, and no sha1sum. Run under `env -i` so nothing leaks in.
BSD="$TMP/bsdbin"; mkdir -p "$BSD"
for t in mkdir id chmod cut basename dirname git python3 printf cat; do
  p=$(command -v "$t" 2>/dev/null) && [ "${p#/}" != "$p" ] && ln -s "$p" "$BSD/$t"
done
cat > "$BSD/stat" <<'STAT'
#!/bin/bash
# BSD stat: no -c. -f %Lp prints the permission bits in octal.
[ "$1" = "-f" ] && [ "$2" = "%Lp" ] || { echo "stat: illegal option -- ${1#-}" >&2; exit 1; }
exec python3 -c 'import os,stat,sys; print(format(stat.S_IMODE(os.lstat(sys.argv[1]).st_mode), "o"))' "$3"
STAT
chmod +x "$BSD/stat"
bsd() { env -i PATH="$BSD" HOME="$TMP/bsdhome" /bin/bash -c "source '$S/repo-id-fns.sh'; $1"; }

R=$(bsd 'autocoder_tmp_root' 2>"$TMP/bsderr")
eq "BSD stat: default state dir resolves" "$TMP/bsdhome/.local/state/autocoder/merge" "$R"
eq "...with nothing on stderr" "" "$(cat "$TMP/bsderr")"
mkdir -p "$TMP/bsdhome2/.local/state/autocoder/merge"; chmod 755 "$TMP/bsdhome2/.local/state/autocoder/merge"
R=$(env -i PATH="$BSD" HOME="$TMP/bsdhome2" /bin/bash -c "source '$S/repo-id-fns.sh'; autocoder_tmp_root")
eq "BSD stat: a 0755 state dir is read via -f %Lp and tightened" "700" "$(mode "$R")"

git init -q "$TMP/idrepo"
WANT=$(autocoder_repo_id "$TMP/idrepo")
eq "no sha1sum (python3 fallback): same repo id" "$WANT" "$(bsd "autocoder_repo_id '$TMP/idrepo'")"
cat > "$BSD/shasum" <<'SHA'
#!/bin/bash
# macOS shasum stand-in: `shasum -a 1` prints "<hex>  -" like sha1sum.
[ "$1" = "-a" ] && [ "$2" = "1" ] || exit 2
python3 -c 'import hashlib,sys; print(hashlib.sha1(sys.stdin.buffer.read()).hexdigest() + "  -")'
SHA
chmod +x "$BSD/shasum"
eq "shasum -a 1 (macOS): same repo id" "$WANT" "$(bsd "autocoder_repo_id '$TMP/idrepo'")"

# ── every state writer/reader resolves through the helper ──────────────────
for f in merge-launch.sh merge-poll.sh merge-queue-fns.sh main-sentinel.sh merge-to-integration.sh promote.sh; do
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

# The sentinel re-runs a dead job's run.sh only if it is our own regular file.
grep -q '\[ -f "\$base.run.sh" \] && \[ ! -L "\$base.run.sh" \] && \[ -O "\$base.run.sh" \]' "$S/main-sentinel.sh" \
  && ok "sentinel re-run checks run.sh ownership" || bad "sentinel re-runs run.sh without an ownership check"

echo ""
echo "Tests: $FAIL failed, $PASS passed, $((PASS + FAIL)) total"
[ "$FAIL" -eq 0 ]
