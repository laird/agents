#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255: never write the real event logs
# Grok installs the Claude Code marketplace (.claude-plugin/marketplace.json).
# These checks lock the adapters that make that install usable: stable plugin
# names, loop scheduling, script lookup, and the stop-hook file Grok actually
# loads. A live `grok` (1.0.x) run is optional and skipped when the CLI is absent.
set -u
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
cd "$ROOT" || exit 1
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

python3 - << 'PY'
import json, sys
mp = json.load(open(".claude-plugin/marketplace.json"))
fail = 0
for entry in mp["plugins"]:
    name, ver = entry["name"], entry["version"]
    man = json.load(open(f"plugins/{name}/.grok-plugin/plugin.json"))
    if man.get("name") != name or man.get("version") != ver:
        print(f"FAIL: {name} grok manifest {man.get('name')} {man.get('version')} != {name} {ver}")
        fail += 1
    else:
        print(f"PASS: {name} .grok-plugin/plugin.json matches the Claude marketplace ({ver})")
    src = entry["source"]
    if src != f"./plugins/{name}":
        print(f"FAIL: {name} marketplace source is {src}")
        fail += 1
sys.exit(fail)
PY
[ $? -eq 0 ] && ok "grok manifests agree with .claude-plugin/marketplace.json" \
  || bad "grok manifests disagree with the Claude marketplace"

if [ -e .grok-plugin/marketplace.json ]; then
  bad "a second marketplace index exists; Grok should read .claude-plugin/marketplace.json"
else
  ok "no separate .grok-plugin marketplace index"
fi

for cmd in fix-loop monitor-loop stop-loop; do
  f="plugins/autocoder/commands/$cmd.md"
  if grep -q 'scheduler_create' "$f"; then
    ok "$cmd schedules or cancels via scheduler_create"
  else
    bad "$cmd does not mention scheduler_create"
  fi
done
grep -q 'scheduler_delete' plugins/autocoder/commands/stop-loop.md \
  && ok "stop-loop deletes Grok schedules" \
  || bad "stop-loop does not call scheduler_delete"
# The Claude Code stop-hook script stays the original one. Grok steps come after it.
python3 - << 'PY'
import pathlib, sys
text = pathlib.Path("plugins/autocoder/commands/stop-loop.md").read_text()
start = text.index('LOOP_STATE_FILE=".claude/fix-loop.local.md"')
start = text.rindex("```bash\n", 0, start)
end = text.index("```", start + 4)
block = text[start:end]
required = [
    'LOOP_STATE_FILE=".claude/fix-loop.local.md"',
    'echo "🛑 Fix loop stopped"',
    'echo "ℹ️  No active fix loop found"',
    'echo "   To restart: /fix-loop"',
]
missing = [line for line in required if line not in block]
if missing or "scheduler_delete" in block or ".grok/" in block:
    print("FAIL: Claude stop-loop script changed:", missing)
    sys.exit(1)
print("PASS: Claude stop-loop script is unchanged")
PY
[ $? -eq 0 ] && ok "Claude stop-loop script unchanged" || bad "Claude stop-loop script changed"
grep -q 'at most 8 times' plugins/autocoder/commands/fix-loop.md \
  && ok "fix-loop records why a Stop hook is not the Grok loop" \
  || bad "fix-loop does not explain the Grok Stop continuation cap"

if [ -e plugins/autocoder/hooks/hooks.json ]; then
  bad "hooks/hooks.json exists; Claude Code would load it beside settings.json"
else
  ok "no hooks/hooks.json, so Claude Code's plugin hooks are unchanged"
fi
python3 - << 'PY'
import json, pathlib, sys
fail = 0
settings = json.load(open("plugins/autocoder/settings.json"))
cmd = settings["hooks"]["Stop"][0]["hooks"][0]["command"]
if cmd != "bash plugins/autocoder/hooks/stop-hook.sh":
    print("FAIL: settings.json Stop command changed:", cmd)
    fail += 1
else:
    print("PASS: settings.json Stop command is unchanged")
for path in list(pathlib.Path("plugins/modernize/agents").glob("*.md")) + list(pathlib.Path(".agent/rules").glob("*.md")):
    text = path.read_text().split("---", 2)[1]
    if "description:" not in text:
        print("FAIL: no description frontmatter in", path)
        fail += 1
if fail == 0:
    print("PASS: modernize agents and Antigravity rules have description frontmatter")
sys.exit(fail)
PY
[ $? -eq 0 ] && ok "hook and agent frontmatter" || bad "hook or agent frontmatter"

# Idle sentinel resolves a Grok install when the Claude cache has nothing.
G=$(mktemp -d)
trap 'rm -rf "$G"' EXIT
mkdir -p "$G/autocoder-bbbb2222/scripts"
cat > "$G/autocoder-bbbb2222/scripts/idle-sentinel.sh" << 'EOF'
#!/bin/bash
echo "grok-sentinel $*"
EOF
chmod +x "$G/autocoder-bbbb2222/scripts/idle-sentinel.sh"
OUT=$(AUTOCODER_PLUGIN_CACHE="/no/such/cache" AUTOCODER_GROK_PLUGINS="$G" \
  bash plugins/autocoder/scripts/idle-sentinel-shim.sh --once 2>/dev/null || true)
case "$OUT" in
  "grok-sentinel --once") ok "idle sentinel shim finds a Grok install" ;;
  *) bad "idle sentinel shim output: $OUT" ;;
esac

if command -v grok >/dev/null 2>&1; then
  ISO=$(mktemp -d)
  HOME="$ISO" grok plugin marketplace add "$ROOT" >/dev/null
  HOME="$ISO" grok plugin install autocoder --trust >/dev/null
  HOME="$ISO" grok plugin install modernize --trust >/dev/null
  HOME="$ISO" grok plugin list --json > "$ISO/list.json"
  python3 - "$ISO/list.json" << 'PY'
import json, sys
names = sorted(p["name"] for p in json.load(open(sys.argv[1])))
if names != ["autocoder", "modernize"]:
    print("FAIL: installed names", names)
    sys.exit(1)
print("PASS: grok installed autocoder and modernize by manifest name")
PY
  [ $? -eq 0 ] && ok "live grok install names" || bad "live grok install names"
  mkdir -p "$ISO/proj"
  (cd "$ISO/proj" && HOME="$ISO" grok inspect --json > "$ISO/inspect.json")
  python3 - "$ISO/inspect.json" << 'PY'
import json, sys
d = json.load(open(sys.argv[1]))
skills = {s["name"] for s in d.get("skills") or []}
need = {"fix", "fix-loop", "monitor-loop", "stop-loop", "assess"}
missing = need - skills
agents = {a["name"] for a in d.get("agents") or []}
if missing:
    print("FAIL: missing commands", sorted(missing))
    sys.exit(1)
if "modernize:architect" not in agents:
    print("FAIL: modernize:architect not in", sorted(agents))
    sys.exit(1)
print("PASS: grok inspect lists the loop commands and modernize:architect")
PY
  [ $? -eq 0 ] && ok "live grok inspect" || bad "live grok inspect"
  rm -rf "$ISO"
else
  ok "live grok checks skipped (grok not on PATH)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
