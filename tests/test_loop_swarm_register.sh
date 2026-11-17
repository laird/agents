#!/bin/bash
# tests/test_loop_swarm_register.sh — /fix-loop and /monitor-loop register
# themselves in the swarm manifest at start (#217, part of #178). Runs the
# "Register in the swarm manifest" block of every command copy against a
# scratch repo: with a manifest it records the worker / manager, without one
# it is a silent no-op, and a failure never stops the loop.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want '$2', got '$3'"; fi; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
unset AUTOCODER_WORKER AUTOCODER_MANAGER TMUX_PANE HERDR_PANE_ID CMUX_WORKSPACE_ID
export HOME="$TMP/home"; mkdir -p "$HOME"
J() { python3 -c "import json,sys; m=json.load(open(sys.argv[1])); print($2)" "$1"; }

# The bash block under the "Register in the swarm manifest" heading.
extract() {
  python3 - "$1" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
m = re.search(r"### Register in the swarm manifest\n\n```bash\n(.*?)\n```", s, re.S)
print(m.group(1) if m else "")
PY
}

# Each copy, with the role it registers and the local scripts tree it finds.
CASES="plugins/autocoder/commands/fix-loop.md:worker:plugins/autocoder/scripts
.agent/workflows/fix-loop.md:worker:.agent/scripts
.pi/prompts/fix-loop.md:worker:plugins/autocoder/scripts
plugins/autocoder/commands/monitor-loop.md:manager:plugins/autocoder/scripts
.agent/workflows/monitor-loop.md:manager:.agent/scripts"

i=0
while IFS=: read -r FILE ROLE TREE; do
  i=$((i + 1))
  BLOCK=$(extract "$ROOT/$FILE")
  if [ -z "$BLOCK" ]; then bad "$FILE: no register block"; continue; fi
  ok "$FILE: has a register block"
  if [ "$ROLE" = manager ]; then
    echo "$BLOCK" | grep -q 'REGISTER_SH" --manager' && ok "$FILE: registers with --manager" \
      || bad "$FILE: does not pass --manager"
  else
    echo "$BLOCK" | grep -q -- '--manager' && bad "$FILE: worker copy passes --manager" || ok "$FILE: registers as a worker"
  fi

  P="$TMP/p$i"
  git init -q "$P"; git -C "$P" config user.email t@example.com; git -C "$P" config user.name T
  git -C "$P" commit -q --allow-empty -m init; git -C "$P" branch -M main
  git -C "$P" worktree add -q -b main-wt-2 "$P-wt-2"
  RUN_IN="$P-wt-2"; [ "$ROLE" = manager ] && RUN_IN="$P"
  mkdir -p "$RUN_IN/$TREE"
  cp "$ROOT/plugins/autocoder/scripts/swarm-register.sh" "$ROOT/plugins/autocoder/scripts/swarm-manifest-lib.sh" "$RUN_IN/$TREE/"

  # No manifest: exits 0, creates nothing.
  (cd "$RUN_IN" && bash -c "$BLOCK" >/dev/null 2>&1); RC=$?
  eq "$FILE: no manifest exits 0" "0" "$RC"
  [ ! -d "$P/.autocoder" ] && ok "$FILE: no manifest creates nothing" || bad "$FILE: created $P/.autocoder"

  mkdir -p "$P/.autocoder/swarm"
  M="$P/.autocoder/swarm/s$i.json"
  printf '{"version": 1, "session": "s%s", "projectRoot": "%s", "workers": [], "manager": null}\n' "$i" "$P" > "$M"
  (cd "$RUN_IN" && TMUX_PANE=%7 bash -c "$BLOCK" >/dev/null 2>&1); RC=$?
  eq "$FILE: with a manifest exits 0" "0" "$RC"
  if [ "$ROLE" = manager ]; then
    eq "$FILE: manager pane recorded" "%7" "$(J "$M" '(m["manager"] or {}).get("tmuxTarget")')"
    eq "$FILE: no worker added" "0" "$(J "$M" 'len(m["workers"])')"
  else
    eq "$FILE: worker recorded" "1 $P-wt-2 %7" "$(J "$M" '" ".join(str(x) for x in [len(m["workers"])] + [m["workers"][0].get(k) for k in ("worktree","tmuxTarget")] if m["workers"]) if m["workers"] else "0"')"
  fi

  # A failed registration (unwritable manifest) warns and continues.
  chmod 000 "$M"
  OUT=$(cd "$RUN_IN" && bash -c "$BLOCK; echo AFTER" 2>&1)
  chmod 644 "$M"
  echo "$OUT" | grep -q '^AFTER$' && ok "$FILE: a failed registration does not stop the loop" || bad "$FILE: block aborted: $OUT"
done <<< "$CASES"

# Installed-plugin fallback: no local tree, newest cached version wins.
P="$TMP/pc"
git init -q "$P"; git -C "$P" config user.email t@example.com; git -C "$P" config user.name T
git -C "$P" commit -q --allow-empty -m init; git -C "$P" branch -M main
git -C "$P" worktree add -q -b main-wt-2 "$P-wt-2"
for v in 4.9.0 4.10.0; do
  d="$HOME/.claude/plugins/cache/mk/autocoder/$v/scripts"; mkdir -p "$d"
  cp "$ROOT/plugins/autocoder/scripts/swarm-manifest-lib.sh" "$d/"
  printf '#!/bin/bash\necho "ran %s" > "%s/ran"\n' "$v" "$TMP" > "$d/swarm-register.sh"
done
(cd "$P-wt-2" && bash -c "$(extract "$ROOT/plugins/autocoder/commands/fix-loop.md")" >/dev/null 2>&1)
eq "cache fallback picks the newest version" "ran 4.10.0" "$(cat "$TMP/ran" 2>/dev/null)"

# No helper anywhere (an older install): silent no-op, exit 0.
rm -rf "$HOME/.claude"
(cd "$P-wt-2" && bash -c "$(extract "$ROOT/plugins/autocoder/commands/fix-loop.md")" >/dev/null 2>&1); RC=$?
eq "no helper installed: exit 0" "0" "$RC"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
