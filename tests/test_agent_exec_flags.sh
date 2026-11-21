#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255: never write the real event logs
# tests/test_agent_exec_flags.sh — codex/droid launch flags are documented defaults,
# never a bypass, and overridable (#286).
#
# The codex and droid wrappers used to hard-code --full-auto. Current codex rejects
# that flag outright ("unexpected argument"), and it is not droid's flag either.
# Each wrapper now passes one default its CLI needs to work headless (codex:
# --sandbox workspace-write; droid: --auto high), replaced by AUTOCODER_CODEX_FLAGS /
# AUTOCODER_DROID_FLAGS, and nothing at all when the variable is set but empty.
set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok - $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/repo"
for cli in codex droid; do
  cat > "$TMP/bin/$cli" <<STUB
#!/bin/bash
for a in "\$@"; do printf '[%s]' "\$a"; done > "$TMP/$cli.args"
STUB
  chmod +x "$TMP/bin/$cli"
done
git -C "$TMP/repo" init -q

# run <cli> <script> [args...]: run a wrapper from inside the scratch repo, print the
# stub's argv (each word bracketed). The env is the caller's.
run() {
  local cli="$1" script="$2"; shift 2
  rm -f "$TMP/$cli.args"
  (cd "$TMP/repo" && PATH="$TMP/bin:$PATH" bash "$REPO_ROOT/scripts/$script" "$@") >/dev/null 2>&1
  cat "$TMP/$cli.args" 2>/dev/null
}

expect() {  # expect <desc> <actual> <literal argv prefix>
  case "$2" in "$3"*) ok "$1" ;; *) fail "$1: got '${2:0:120}'" ;; esac
}

echo "codex"
unset AUTOCODER_CODEX_FLAGS AUTOCODER_DROID_FLAGS
expect "codex-autocoder default is workspace-write" "$(run codex codex-autocoder.sh review-blocked)" "[exec][--sandbox][workspace-write][-C]"
expect "codex-monitor-workers default"             "$(run codex codex-monitor-workers.sh)"        "[exec][--sandbox][workspace-write][/monitor-workers]"
expect "override replaces the default"   "$(AUTOCODER_CODEX_FLAGS='-s read-only -m o3' run codex codex-autocoder.sh fix)" "[exec][-s][read-only][-m][o3][-C]"
expect "empty defers to config.toml"     "$(AUTOCODER_CODEX_FLAGS='' run codex codex-autocoder.sh fix)"        "[exec][-C]"
expect "monitor empty"                   "$(AUTOCODER_CODEX_FLAGS='' run codex codex-monitor-workers.sh)"      "[exec][/monitor-workers]"
expect "flag values are not globbed"     "$(AUTOCODER_CODEX_FLAGS='-m *' run codex codex-monitor-workers.sh)"  "[exec][-m][*][/monitor-workers]"

echo "droid"
expect "droid fix N default is --auto high" "$(run droid droid-autocoder.sh fix 42)"          "[exec][--auto][high][/fix 42]"
expect "droid fix default"                  "$(run droid droid-autocoder.sh fix)"             "[exec][--auto][high][/fix]"
expect "droid monitor via autocoder"        "$(run droid droid-autocoder.sh monitor-workers)" "[exec][--auto][high][/monitor-workers]"
expect "droid-monitor-workers default"      "$(run droid droid-monitor-workers.sh)"           "[exec][--auto][high][/monitor-workers]"
expect "droid override"  "$(AUTOCODER_DROID_FLAGS='--auto medium' run droid droid-autocoder.sh fix 7)" "[exec][--auto][medium][/fix 7]"
expect "droid empty"     "$(AUTOCODER_DROID_FLAGS='' run droid droid-monitor-workers.sh)"              "[exec][/monitor-workers]"

echo "no wrapper forces a removed or bypass flag"
for f in codex-autocoder.sh codex-monitor-workers.sh droid-autocoder.sh droid-monitor-workers.sh; do
  if grep -nE -- '--full-auto|--dangerously|--skip-permissions-unsafe' "$REPO_ROOT/scripts/$f" | grep -v '^[0-9]*:#' | grep -q .; then
    fail "$f passes --full-auto or a bypass flag"
  else
    ok "$f"
  fi
done

echo ""
echo "Tests: $FAIL failed, $PASS passed, $((PASS+FAIL)) total"
[ "$FAIL" -eq 0 ]
