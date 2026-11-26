# quota-failover-lib.sh — pure helpers for agent usage-limit failover.
#
# Source this file. It does not parse argv and it does not launch anything.
# quota-failover.sh is the watchdog that calls these.
#
# Detection reads pane text. It is per agent kind, and a GitHub API or GraphQL
# rate-limit line is never an agent quota hit (those strings share words like
# "rate limit exceeded" with Codex). A short provider retry (tokens-per-minute,
# "try again in 1.5s") is not a quota hit either: the CLI already waits those out.
#
# Strings (pane text, not the GitHub API):
#   claude  Claude Code 2.1.x, observed and documented:
#           "You've hit your weekly limit · resets Nov 27, 12am (America/New_York)"
#           "You've hit your 5-hour limit" / "session limit" / "out of usage credits"
#           "Usage limit reached · limit resets …" / "Continuing automatically at …"
#           "Goal paused · usage limit reached" / "/rate-limit-options"
#           dialog: "Stop and wait for limit to reset" /
#           "Wait here, then continue automatically" /
#           "Add funds to continue with usage credits" (detected, never chosen)
#           A model-family limit ("You've hit your Opus limit") is not a hit:
#           Claude can keep going on another model.
#   grok    1.0.92 binary: "API rate limit. Ask a team admin to purchase more credits"
#           "Usage limits are managed by your team."
#   codex   0.172.0 binary: "rate limit exceeded", "unknown rate limit reached type:"
#           plus the allowance banners ("You've hit your usage limit",
#           "You're out of Codex and work usage", "5-hour work usage limit")
#   gemini  daily allowance: "exhausted your daily quota",
#           "reached your daily … quota limit", "Quota exceeded for quota metric",
#           TerminalQuotaError
#   droid, pi  allowance banners ("usage limit", "out of credits", "quota exhausted")
#           when that pane's agent is droid or pi. Not a TPM retry.

# State file. Tests set QUOTA_STATE_FILE. Otherwise one JSON file per repo under
# ${XDG_STATE_HOME:-~/.local/state}/autocoder/quota-failover/<repo-id>.json
quota_state_path() {
  if [ -n "${QUOTA_STATE_FILE:-}" ]; then
    printf '%s\n' "$QUOTA_STATE_FILE"
    return 0
  fi
  local dir id repo
  dir="${QUOTA_FAILOVER_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/autocoder/quota-failover}"
  repo="${QUOTA_REPO:-$PWD}"
  if declare -F autocoder_repo_id >/dev/null 2>&1; then
    id=$(autocoder_repo_id "$repo" 2>/dev/null || true)
  fi
  [ -n "${id:-}" ] || id=$(basename "$repo")
  printf '%s/%s.json\n' "$dir" "$id"
}

quota_now() {
  if [ -n "${QUOTA_NOW_EPOCH:-}" ]; then
    printf '%s\n' "$QUOTA_NOW_EPOCH"
  else
    date +%s
  fi
}

quota_known_agent() {
  case "$1" in
    claude|gemini|codex|droid|pi|grok) return 0 ;;
    *) return 1 ;;
  esac
}

# Prefix for slash commands. Claude plugin commands are /autocoder:…;
# every other agent lists the bare names.
quota_cmd_prefix() {
  case "$1" in
    claude) printf 'autocoder:' ;;
    *) printf '' ;;
  esac
}

# Resume command for a worker. Issue number when the branch names one, so the
# same claim is what the new agent opens; otherwise the loop.
quota_worker_prompt() {
  local agent="$1" issue="${2:-}" p
  p=$(quota_cmd_prefix "$agent")
  if [ -n "$issue" ]; then
    printf '/%sfix %s' "$p" "$issue"
  else
    printf '/%sfix-loop' "$p"
  fi
}

# Two lines. The manager reads its state, then starts the monitor loop.
quota_manager_prompt_lines() {
  local p
  p=$(quota_cmd_prefix "$1")
  printf '/%smanager-resume --non-interactive\n' "$p"
  printf '/%smonitor-loop\n' "$p"
}

# Issue number from a worktree branch, or nothing. feature/issue-N and
# enhancement/issue-N-auto, the same two shapes worktree-issue.sh reads.
quota_issue_of_worktree() {
  local branch
  branch=$(git -C "$1" rev-parse --abbrev-ref HEAD 2>/dev/null) || return 0
  printf '%s\n' "$branch" | sed -nE \
    's#^feature/issue-([0-9]+)$#\1#p; s#^enhancement/issue-([0-9]+)-auto$#\1#p'
}

# quota_py <exhausted|reset> <agent> <text>
# exhausted: exit 0 when the text is that agent's quota banner.
# reset: print "epoch<TAB>snippet" for the reset time, or nothing.
quota_py() {
  python3 - "$1" "$2" "$3" <<'PY'
import calendar, re, sys
from datetime import datetime, timedelta, timezone
try:
    from zoneinfo import ZoneInfo
except ImportError:
    ZoneInfo = None

cmd, agent, text = sys.argv[1], sys.argv[2], sys.argv[3]

def github_line(line):
    low = line.lower()
    if "api rate limit exceeded" in low:
        return True
    if "secondary rate limit" in low:
        return True
    if "x-ratelimit-" in low:
        return True
    if "rate limit exceeded for user" in low or "rate limit exceeded for installation" in low:
        return True
    if "graphql" in low and "rate limit" in low:
        return True
    if "gh api" in low and "rate limit" in low:
        return True
    stripped = low.strip()
    if stripped.startswith("gh:") and "rate limit" in low:
        return True
    return False

def transient_line(line):
    # A provider retry the CLI already handles. "try again at <date>" is a
    # real reset and must stay; "try again in 1.5s" is not.
    low = line.lower()
    if re.search(r"try again in \d+(?:\.\d+)?\s*s", low):
        return True
    if re.search(r"retry in \d+(?:\.\d+)?\s*s", low):
        return True
    if "tokens per min" in low or "tokens per minute" in low:
        return True
    if re.search(r"\btpm\b", low):
        return True
    if "exceeded retry limit" in low:
        return True
    if "server_is_overloaded" in low or "at capacity" in low:
        return True
    return False

def kept(raw):
    lines = []
    for line in raw.splitlines():
        if github_line(line) or transient_line(line):
            continue
        lines.append(line)
    return "\n".join(lines)

PATTERNS = {
    "claude": [
        r"you'?ve hit your (?:weekly|session|5-hour|daily) limit",
        r"out of usage credits",
        r"usage limit reached",
        r"goal paused\s*[·|:.\-]*\s*usage limit",
        r"/rate-limit-options",
        r"stop and wait for limit to reset",
        r"wait here, then continue automatically",
        r"add funds to continue with usage credits",
        r"continuing automatically at",
        r"claude usage limit reached",
    ],
    "grok": [
        r"ask a team admin to purchase more credits",
        r"usage limits are managed by your team",
        r"you have run out of credits or need a grok subscription",
    ],
    "codex": [
        r"unknown rate limit reached type:",
        r"you'?ve hit your usage limit",
        r"you'?re out of codex and work usage",
        r"you'?ve reached your 5-hour work usage limit",
        r"you have reached your 5-hour work usage limit",
        r"you'?ve used all codex and work usage",
        r"your workspace is out of credits",
        r"rate limit exceeded",
    ],
    "gemini": [
        r"exhausted your daily quota",
        r"reached your daily(?: \S+)? quota",
        r"quota exceeded for quota metric",
        r"terminalquotaerror",
    ],
    "droid": [
        r"you'?ve reached your usage limit",
        r"you'?ve hit your usage limit",
        r"usage limit reached",
        r"out of (?:usage )?credits",
        r"quota exhausted",
    ],
    "pi": [
        r"you'?ve reached your usage limit",
        r"you'?ve hit your usage limit",
        r"usage limit reached",
        r"out of (?:usage )?credits",
        r"quota exhausted",
    ],
}

def exhausted(kind, raw):
    body = kept(raw)
    for pat in PATTERNS.get(kind, []):
        if re.search(pat, body, re.I):
            return True
    return False

def zone_for(name):
    name = (name or "").strip()
    if name and ZoneInfo is not None and "/" in name:
        try:
            return ZoneInfo(name)
        except Exception:
            pass
    return datetime.now().astimezone().tzinfo

def hour24(h, minute, ap):
    h = int(h)
    minute = int(minute or 0)
    if ap.lower() == "am":
        h = 0 if h == 12 else h
    else:
        h = h if h == 12 else h + 12
    return h, minute

MONTHS = {}
for i, name in enumerate(calendar.month_abbr):
    if name:
        MONTHS[name.lower()] = i
for i, name in enumerate(calendar.month_name):
    if name:
        MONTHS[name.lower()] = i

def now_utc():
    raw = __import__("os").environ.get("QUOTA_NOW_EPOCH", "")
    if raw:
        return datetime.fromtimestamp(int(raw), timezone.utc)
    return datetime.now(timezone.utc)

def bump_year(dt, now):
    if (now - dt).total_seconds() > 36 * 3600:
        try:
            return dt.replace(year=dt.year + 1)
        except ValueError:
            return dt.replace(year=dt.year + 1, day=28)
    return dt

def parse_reset(raw):
    body = kept(raw)
    now = now_utc()
    # Highest priority: an explicit calendar date.
    m = re.search(
        r"resets?\s+([A-Za-z]+)\s+(\d{1,2}),\s*(\d{1,2})(?::(\d{2}))?\s*(am|pm)\s*(?:\(([^)]+)\))?",
        body, re.I)
    if m and m.group(1).lower() in MONTHS:
        tz = zone_for(m.group(6))
        hh, mm = hour24(m.group(3), m.group(4), m.group(5))
        local_now = now.astimezone(tz)
        dt = datetime(local_now.year, MONTHS[m.group(1).lower()], int(m.group(2)), hh, mm, tzinfo=tz)
        dt = bump_year(dt, now)
        return int(dt.timestamp()), m.group(0).strip()
    m = re.search(
        r"try again at\s+(\d{1,2})\s+([A-Za-z]+)\s+(\d{4}),\s*(\d{1,2})(?::(\d{2}))?\s*(am|pm)?",
        body, re.I)
    if m and m.group(2).lower() in MONTHS:
        if m.group(6):
            hh, mm = hour24(m.group(4), m.group(5), m.group(6))
        else:
            hh, mm = int(m.group(4)), int(m.group(5) or 0)
        tz = datetime.now().astimezone().tzinfo
        dt = datetime(int(m.group(3)), MONTHS[m.group(2).lower()], int(m.group(1)), hh, mm, tzinfo=tz)
        return int(dt.timestamp()), m.group(0).strip()
    m = re.search(
        r"resets?\s+(Mon|Tue|Wed|Thu|Fri|Sat|Sun)[a-z]*\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)",
        body, re.I)
    if m:
        want = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"].index(m.group(1).lower()[:3])
        hh, mm = hour24(m.group(2), m.group(3), m.group(4))
        tz = datetime.now().astimezone().tzinfo
        local = now.astimezone(tz).replace(second=0, microsecond=0)
        for add in range(0, 8):
            cand = (local + timedelta(days=add)).replace(hour=hh, minute=mm)
            if cand.weekday() == want and cand > local:
                return int(cand.timestamp()), m.group(0).strip()
    m = re.search(
        r"(?:resets?|continuing automatically at)\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)",
        body, re.I)
    if m:
        tzname = re.search(r"\(([A-Za-z]+/[A-Za-z0-9_+\-]+)\)", body)
        tz = zone_for(tzname.group(1) if tzname else "")
        hh, mm = hour24(m.group(1), m.group(2), m.group(3))
        local = now.astimezone(tz).replace(second=0, microsecond=0)
        cand = local.replace(hour=hh, minute=mm)
        if cand <= local:
            cand = cand + timedelta(days=1)
        return int(cand.timestamp()), m.group(0).strip()
    return None

if cmd == "exhausted":
    sys.exit(0 if exhausted(agent, text) else 1)
if cmd == "reset":
    found = parse_reset(text)
    if found:
        print("%s\t%s" % (found[0], found[1]))
    sys.exit(0)
sys.exit(2)
PY
}

# Exit 0 when stdin (or the rest of the pane, passed by the caller via a pipe)
# shows that agent's quota exhaustion.
quota_pane_exhausted() {
  local agent="$1" text
  text=$(cat)
  quota_py exhausted "$agent" "$text" >/dev/null
}

# Print epoch<TAB>snippet for a reset time in stdin, or nothing.
quota_parse_reset() {
  local text
  text=$(cat)
  quota_py reset "" "$text"
}

quota_preference() {
  local out
  if [ -n "${AUTOCODER_AGENT_PREFERENCE:-}" ]; then
    printf '%s\n' "$AUTOCODER_AGENT_PREFERENCE" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' || true
    return 0
  fi
  if [ -n "${QUOTA_REPO:-}" ] && [ -f "$QUOTA_REPO/.autocoder.json" ]; then
    out=$(python3 - "$QUOTA_REPO/.autocoder.json" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(0)
pref = data.get("agentPreference")
if isinstance(pref, str):
    items = [p.strip() for p in pref.split(",")]
elif isinstance(pref, list):
    items = [str(p).strip() for p in pref]
else:
    items = []
for item in items:
    if item:
        print(item)
PY
)
    if [ -n "$out" ]; then
      printf '%s\n' "$out"
      return 0
    fi
  fi
  # Claude, Codex, and Grok are the interchangeable set: any one of them can
  # take a pane the others cannot run. The rest follow.
  printf '%s\n' claude codex grok gemini droid pi
}

# Cheap usability check. Exit 0 only when the binary is installed AND a probe
# says it is authenticated. AUTOCODER_QUOTA_AUTH_<AGENT> replaces the probe
# (a bash -c snippet) so tests can fake it. An unknown auth subcommand falls
# back to a credential file or an agent-specific env key; a definite "not
# logged in" does not.
quota_credential_present() {
  local agent="$1" f
  case "$agent" in
    claude)
      [ -f "$HOME/.claude/.credentials.json" ] && return 0
      [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}${ANTHROPIC_API_KEY:-}" ] && return 0
      ;;
    codex)
      [ -f "$HOME/.codex/auth.json" ] && return 0
      [ -n "${CODEX_API_KEY:-}${OPENAI_API_KEY:-}" ] && return 0
      ;;
    grok)
      for f in "$HOME/.grok/auth.json" "$HOME/.grok/credentials.json" "$HOME/.config/grok/auth.json"; do
        [ -f "$f" ] && return 0
      done
      [ -n "${XAI_API_KEY:-}${GROK_API_KEY:-}" ] && return 0
      ;;
    gemini)
      [ -f "$HOME/.gemini/oauth_creds.json" ] && return 0
      [ -f "$HOME/.gemini/google_accounts.json" ] && return 0
      [ -n "${GEMINI_API_KEY:-}${GOOGLE_API_KEY:-}${GOOGLE_GENAI_API_KEY:-}" ] && return 0
      ;;
    droid)
      [ -f "$HOME/.factory/auth.json" ] && return 0
      [ -f "$HOME/.factory/settings.json" ] && return 0
      [ -n "${FACTORY_API_KEY:-}" ] && return 0
      ;;
    pi)
      [ -f "$HOME/.pi/agent/auth.json" ] && return 0
      [ -f "$HOME/.pi/agent/settings.json" ] && return 0
      ;;
  esac
  return 1
}

quota_default_auth_probe() {
  local agent="$1" out rc=0
  local -a cmd
  case "$agent" in
    codex) cmd=(codex login status) ;;
    *) cmd=("$agent" auth status) ;;
  esac
  if command -v timeout >/dev/null 2>&1; then
    out=$(timeout 15 "${cmd[@]}" 2>&1) || rc=$?
  else
    out=$("${cmd[@]}" 2>&1) || rc=$?
  fi
  if [ "$rc" -eq 0 ]; then
    printf '%s' "$out" | grep -qiE 'not logged in|logged out|login required|"loggedIn"[[:space:]]*:[[:space:]]*false' \
      && return 1
    return 0
  fi
  if printf '%s' "$out" | grep -qiE 'unknown command|unrecognized|unexpected argument|invalid choice|no such command|unknown subcommand'; then
    quota_credential_present "$agent"
    return $?
  fi
  return 1
}

quota_agent_usable() {
  local agent="$1" var snippet
  quota_known_agent "$agent" || return 1
  command -v "$agent" >/dev/null 2>&1 || return 1
  var=$(printf 'AUTOCODER_QUOTA_AUTH_%s' "$agent" | tr '[:lower:]' '[:upper:]')
  snippet=$(eval "printf '%s' \"\${$var:-}\"")
  if [ -n "$snippet" ]; then
    bash -c "$snippet"
    return $?
  fi
  quota_default_auth_probe "$agent"
}

quota_state_get() {
  local op="$1" key="$2" f
  f=$(quota_state_path)
  [ -f "$f" ] || return 0
  python3 - "$f" "$op" "$key" <<'PY'
import json, sys
path, op, key = sys.argv[1:]
try:
    data = json.load(open(path, encoding="utf-8"))
except Exception:
    sys.exit(0)
if op == "until":
    row = (data.get("exhausted") or {}).get(key) or {}
    val = row.get("until")
    if val is not None:
        print(val)
elif op == "reset_text":
    row = (data.get("exhausted") or {}).get(key) or {}
    print(row.get("reset_text") or "")
elif op == "current":
    print((data.get("current") or {}).get(key) or "")
elif op == "switched":
    val = (data.get("switched") or {}).get(key)
    if val is not None:
        print(val)
PY
}

quota_state_set() {
  local op="$1" key="$2" a="${3:-}" b="${4:-}" f
  f=$(quota_state_path)
  mkdir -p "$(dirname "$f")"
  [ -f "$f" ] || printf '%s\n' '{}' > "$f"
  (
    flock -x 9
    python3 - "$f" "$op" "$key" "$a" "$b" <<'PY'
import json, os, sys, tempfile
path, op, key, a, b = sys.argv[1:]
try:
    data = json.load(open(path, encoding="utf-8"))
except Exception:
    data = {}
data.setdefault("exhausted", {})
data.setdefault("current", {})
data.setdefault("switched", {})
if op == "exhausted":
    data["exhausted"][key] = {
        "until": int(a),
        "reset_text": b,
        "seen": __import__("datetime").datetime.now(__import__("datetime").timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
elif op == "current":
    data["current"][key] = a
elif op == "switched":
    data["switched"][key] = int(a)
fd, tmp = tempfile.mkstemp(prefix=".quota.", dir=os.path.dirname(path) or ".")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2)
        fh.write("\n")
    os.replace(tmp, path)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)
PY
  ) 9>>"$f.lock"
}

# 0 when a recorded exhaustion is still in the future, or this tick already
# saw the agent exhausted (QUOTA_SEEN_EXHAUSTED).
quota_agent_blocked() {
  local agent="$1" until now
  case " ${QUOTA_SEEN_EXHAUSTED:-} " in
    *" $agent "*) return 0 ;;
  esac
  until=$(quota_state_get until "$agent")
  [ -n "$until" ] || return 1
  now=$(quota_now)
  [ "$until" -gt "$now" ]
}

# First preference that is installed, authenticated, and not exhausted.
quota_best_usable() {
  local agent
  while IFS= read -r agent; do
    agent=$(printf '%s' "$agent" | tr -d '[:space:]')
    [ -n "$agent" ] || continue
    quota_known_agent "$agent" || continue
    quota_agent_blocked "$agent" && continue
    quota_agent_usable "$agent" || continue
    printf '%s\n' "$agent"
    return 0
  done < <(quota_preference)
  return 1
}

# 0 when best is a higher preference whose recorded exhaustion has ended.
# No record means the swarm was started on `current` on purpose: do not move it.
quota_should_failback() {
  local current="$1" best="$2" until now
  [ -n "$best" ] && [ "$best" != "$current" ] || return 1
  until=$(quota_state_get until "$best")
  [ -n "$until" ] || return 1
  now=$(quota_now)
  [ "$until" -le "$now" ]
}

# Record exhaustion. Prints the until epoch. Parsed reset when the pane shows
# one; otherwise now + AUTOCODER_QUOTA_UNKNOWN_COOLDOWN_S (default 6h).
quota_record_exhaustion() {
  local agent="$1" text="$2" parsed until reset_text now cooldown
  now=$(quota_now)
  parsed=$(printf '%s' "$text" | quota_parse_reset || true)
  if [ -n "$parsed" ]; then
    until=${parsed%%$'\t'*}
    reset_text=${parsed#*$'\t'}
  else
    cooldown="${AUTOCODER_QUOTA_UNKNOWN_COOLDOWN_S:-21600}"
    until=$(( now + cooldown ))
    reset_text=""
  fi
  if [ "$until" -le "$now" ]; then
    until=$(( now + 60 ))
  fi
  quota_state_set exhausted "$agent" "$until" "$reset_text"
  printf '%s\n' "$until"
}

quota_in_cooldown() {
  local key="$1" ts now window
  ts=$(quota_state_get switched "$key")
  [ -n "$ts" ] || return 1
  now=$(quota_now)
  window="${QUOTA_SWITCH_COOLDOWN:-120}"
  [ $(( now - ts )) -lt "$window" ]
}

# herdr status values that mean the pane is sitting between turns. `blocked`
# is not idle: that is a dialog (often a tool-permission prompt) and failback
# must not kill it. Unknown (tmux, when herdr has no row) is not idle either.
# Failover on quota text does not consult this.
quota_status_idle() {
  case "$1" in
    idle|done) return 0 ;;
    *) return 1 ;;
  esac
}
