# Review Blocked Issues in the Browser

Start the local review page for blocked issues and print its URL (#314, part of #308). The page is a second front end over the same scripts `/review-blocked` uses, so it works with every issue backend.

## Usage

```bash
/review-blocked-gui              # start the page (or print the URL of the one already running)
/review-blocked-gui --port 8765  # listen on a fixed port instead of a free one
/review-blocked-gui --stop       # stop the server this repository started
```

## What This Does

1. **Starts `review-blocked-server.py`** in the background, from the repository root, on `127.0.0.1` only. It serves `review-blocked-ui.html` and the `/api/*` calls the page makes.
2. **Prints the tokenised URL.** Every API call must carry the per-run token in that URL, so open the URL exactly as printed. Anyone who has the URL can approve and reject issues until the server stops; do not paste it anywhere shared.
3. **Counts missing and stale analyses.** The page shows each issue's options and recommendation from the analysis cache (`blocked-analysis-cache.py`). When some issues have none, or have an analysis older than the issue, it suggests running `/review-blocked --prepare` first. The page still works without analyses: you can approve with your own text, reject, ask a question or skip.
4. **Leaves the server running.** A second `/review-blocked-gui` prints the running server's URL rather than starting another one. `--stop` ends it.

In the page you can approve (remove the blocking label and post the chosen approach), reject (close with a reason), ask (post a question and keep the label) or skip each issue, or approve several issues with fresh analyses at once in batch mode. Each decision runs `approve-blocked-issue.sh`, `reject-blocked-issue.sh` or `issue_comment`, just as `/review-blocked` does.

The server's pid file and log, which holds the URL with its token, live in the worktree's git directory (`autocoder-review-blocked-server.pid` and `.log`), so each worktree has its own server, and the log is written owner-only.

## Instructions

```bash
# Resolve SCRIPT_DIR — see scripts/README.md#script-dir
SCRIPT_DIR=$(
  for d in "$(pwd)/.agent/scripts" \
           "$(pwd)/plugins/autocoder/scripts" \
           "$(pwd)/.claude-plugin/plugins/autocoder/scripts"; do
    if [ -f "$d/issue-fns.sh" ] && [ -f "$d/fix-loop-gate.sh" ]; then echo "$d"; exit 0; fi
  done
  # Fallback: the installed plugin. Only <ver>/scripts is a complete tree;
  # <ver>/skills/autocoder/scripts is a subset that sorts after it (#142).
  # Rank by the <ver> directory alone, not the whole path: with two marketplaces
  # in the cache, a whole-path sort lets the marketplace name decide (#201).
  found=$(
  find "$HOME/.claude/plugins/cache" -type d -name "scripts" -path "*/autocoder/*" -not -path "*/skills/*" 2>/dev/null \
    | while read -r d; do if [ -f "$d/issue-fns.sh" ] && [ -f "$d/fix-loop-gate.sh" ]; then echo "$d"; fi; done \
    | awk -F/ '{print $(NF-1) "\t" $0}' | sort -V -t$'\t' -k1,1 | tail -1 | cut -f2-
  )
  if [ -n "$found" ]; then echo "$found"; exit 0; fi
  # Grok installs to ~/.grok/installed-plugins/<name>-<hash>/. The hash is in
  # the directory name, so the Claude cache glob */autocoder/* does not match.
  find "$HOME/.grok/installed-plugins" -type d -name "scripts" -path "*/autocoder-*/*" -not -path "*/skills/*" 2>/dev/null \
    | while read -r d; do if [ -f "$d/issue-fns.sh" ] && [ -f "$d/fix-loop-gate.sh" ]; then echo "$d"; fi; done \
    | awk -F/ '{print $(NF-1) "\t" $0}' | sort -V -t$'\t' -k1,1 | tail -1 | cut -f2-
)
if [ ! -f "${SCRIPT_DIR}/review-blocked-server.py" ]; then
  echo "autocoder: cannot locate review-blocked-server.py (resolved SCRIPT_DIR='${SCRIPT_DIR}')" >&2
  exit 1
fi

# The server runs the issue scripts from its working directory: the repository root.
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) \
  || { echo "❌ /review-blocked-gui must run inside the repository whose issues you are reviewing" >&2; exit 1; }
# Per worktree: each worktree's server runs that worktree's scripts and tracker config.
GIT_DIR_ABS=$(git rev-parse --path-format=absolute --git-dir)
PID_FILE="$GIT_DIR_ABS/autocoder-review-blocked-server.pid"
LOG_FILE="$GIT_DIR_ABS/autocoder-review-blocked-server.log"

PORT_ARGS=(); STOP=false
while [ $# -gt 0 ]; do
  case "$1" in
    --stop) STOP=true ;;
    --port) [ -n "${2:-}" ] || { echo "❌ --port needs a number" >&2; exit 2; }
            PORT_ARGS=(--port "$2"); shift ;;
    *) echo "❌ unknown argument: $1 (usage: /review-blocked-gui [--port N] [--stop])" >&2; exit 2 ;;
  esac
  shift
done

# A pid counts as ours only while that process is still the review server.
server_alive() {
  local pid
  pid=$(cat "$PID_FILE" 2>/dev/null) || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null && ps -p "$pid" -o args= 2>/dev/null | grep -q 'review-blocked-server\.py'
}
server_url() { sed -n 's/^review-blocked-server: \(http:.*\)$/\1/p' "$LOG_FILE" 2>/dev/null | tail -1; }

if [ "$STOP" = true ]; then
  if server_alive; then
    kill "$(cat "$PID_FILE")" && echo "🛑 Stopped the review server (pid $(cat "$PID_FILE"))."
  else
    echo "ℹ️  No review server is running for this repository."
  fi
  rm -f "$PID_FILE" "$LOG_FILE"
  exit 0
fi

if server_alive; then
  URL=$(server_url)
  echo "ℹ️  The review server is already running (pid $(cat "$PID_FILE")); --port is ignored."
else
  rm -f "$PID_FILE" "$LOG_FILE"
  # Owner-only log: it holds the URL, and the token in it can approve and close issues.
  (umask 077; : > "$LOG_FILE")
  cd "$REPO_ROOT" || exit 1
  # setsid where it exists, so the server outlives the shell that started it.
  if command -v setsid >/dev/null 2>&1; then
    setsid nohup python3 "$SCRIPT_DIR/review-blocked-server.py" "${PORT_ARGS[@]}" >> "$LOG_FILE" 2>&1 < /dev/null &
  else
    nohup python3 "$SCRIPT_DIR/review-blocked-server.py" "${PORT_ARGS[@]}" >> "$LOG_FILE" 2>&1 < /dev/null &
  fi
  echo $! > "$PID_FILE"
  URL=""
  for _ in $(seq 1 100); do
    URL=$(server_url)
    [ -n "$URL" ] && break
    kill -0 "$(cat "$PID_FILE")" 2>/dev/null || break
    sleep 0.1
  done
  if [ -z "$URL" ]; then
    echo "❌ The review server did not start:" >&2
    sed 's/^/   /' "$LOG_FILE" >&2
    server_alive && kill "$(cat "$PID_FILE")" 2>/dev/null
    rm -f "$PID_FILE"
    exit 1
  fi
  echo "🚀 Started the review server (pid $(cat "$PID_FILE"))."
fi
[ -n "$URL" ] || { echo "❌ The review server is running but its log holds no URL; run /review-blocked-gui --stop and start it again" >&2; exit 1; }

echo ""
echo "🔗 Open: $URL"
echo "   The token in this URL can approve and close issues. Keep it to yourself."
echo "   Stop the server with: /review-blocked-gui --stop"
echo ""

# Which issues the page will show without a current analysis.
python3 - "$URL" <<'PY'
import json, sys, urllib.parse, urllib.request
url = sys.argv[1]
base, _, query = url.partition("/?")
token = urllib.parse.parse_qs(query).get("token", [""])[0]
req = urllib.request.Request(base + "/api/issues", headers={"X-Review-Token": token})
# No proxy: the server is on 127.0.0.1, and an http_proxy setting must not reroute it.
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
try:
    with opener.open(req, timeout=120) as resp:
        issues = json.load(resp).get("issues", [])
except Exception as e:
    print(f"⚠️  Could not list the blocked issues through the server: {e}")
    sys.exit(0)
missing = [i["number"] for i in issues if i.get("analysis") is None and not i.get("stale")]
stale = [i["number"] for i in issues if i.get("stale")]
print(f"📊 {len(issues)} blocked issue(s); {len(missing)} without an analysis, {len(stale)} with a stale one.")
if missing or stale:
    print("💡 Run /review-blocked --prepare first so the page can show options and a recommendation")
    print("   for " + ", ".join(f"#{n}" for n in sorted(missing + stale)) + ". Reload the page when it finishes.")
PY
```

After the block runs, give the user the `Open:` URL and the analysis summary it printed, and stop. Do not open the page yourself or make decisions in it: the decisions are the user's.
