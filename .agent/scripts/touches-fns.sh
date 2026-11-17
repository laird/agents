#!/usr/bin/env bash
#
# touches-fns.sh — the file areas an issue expects to edit, and whether two sets
# of areas overlap (#227, sub-task of #186).
#
# Self-claim used to pick the highest-priority issue whatever the other workers
# were editing. Five workers on one hotspot directory produced 8 conflicts, 12
# escalations and 22 push retries in a day. With areas declared, the fix-loop
# gate can steer a worker away from files another worker already holds.
#
# Format (shared by every #186 sub-task). An issue declares its areas on one line
# of its body, at the start of the line:
#
#   Touches: src/web/village/, src/web/server.rs, tools/**/screensaver/*
#
# Entries are comma-separated: an exact path, a directory (a trailing `/` means
# everything under it) or a glob (`*` and `?` within one path segment, `**`
# across segments). Backticks around entries are ignored; `Touches: none`
# declares no areas. With no `Touches:` line (or an empty one), the backticked
# paths in a `## Files Affected` section count instead. Lines inside fenced code
# blocks are ignored, so an issue that quotes the format does not declare it.
# A catch-all (`**`, `*`, `/`) names nothing and is dropped; at most 32 areas of
# 32 segments are read per issue.
# Bodies are read as markdown: a backend that stores HTML (ADO) declares nothing.
#
# Two areas overlap when one of them, or a prefix of it, matches the other:
# `src/web/` overlaps `src/web/server.rs`, `src/*/server.rs` overlaps
# `src/web/`, and `src/a.rs` does not overlap `src/b.rs`. Matching is by path
# segment and errs towards "overlaps" when both sides are globs.
#
# Functions (source this file):
#   touches_of <issue-json>              print the issue's areas, one per line
#                                        ("-" reads the JSON from stdin)
#   areas_overlap <a-list> <b-list>      exit 0 when the newline-separated area
#                                        lists overlap; 1 when not, or either is empty
#   touches_order <mode> <candidates> <open-json-file> <working-json-file>
#       Applies `claims.avoid_overlap` to the gate's candidate lines
#       ("FIX <n> <p>", "ENHANCE <n>", "TAKEOVER <n> <p> <kind>"), given the
#       open issues (for the candidates' bodies) and the in-flight issues, each a
#       JSON array in a file. Prints the lines to try, in order.
#         off     unchanged
#         prefer  candidates that overlap an in-flight claim move after those
#                 that do not; order is otherwise kept
#         strict  candidates that overlap an in-flight claim are dropped
#       An issue with no declared areas never overlaps anything. A candidate is
#       never compared with itself (a takeover candidate is also `working`).
#       A candidate is dropped under prefer and strict alike when it touches a
#       hot file (below) that an in-flight claim also touches: at most one
#       in-flight claim may hold a hot file. Hot files come from T_HOT
#       (newline-separated; the gate fills it from touches_hot_files).
#   touches_mode [<config-file>]          print the configured mode: off, prefer
#                                        or strict (default off; an unknown value
#                                        warns on stderr and reads as off)
#   touches_hot_files [<config-file>] [<repo-id>]
#       Print the hot files, one per line (#228): the `files` of merge attempts
#       with `outcome: conflict` in merge-events.jsonl (#184, merge-events-lib.sh)
#       among the last `claims.hot_window` attempts for this repo. The window is
#       a number of attempts (default 50) or a number of days, written "7d".
#       Events recorded for another repo id are ignored. No events file means no
#       hot files, silently.
#
# Run directly, `touches-fns.sh hot` lists the hot files for the repo in the
# current directory, using its main worktree's .autocoder.json (for the manager).

_TOUCHES_PY=$(cat <<'PY'
import fnmatch, functools, json, os, re, sys

TOUCHES_RE = re.compile(r"^[ \t>*_-]*Touches[*_]*:[*_]*[ \t]*(.*)$", re.IGNORECASE)
HEADING_RE = re.compile(r"^#{1,6}[ \t]+(.*?)[ \t]*#*[ \t]*$")
FENCE_RE = re.compile(r"^[ \t]*(`{3,}|~{3,})(.*)$")
BACKTICK_RE = re.compile(r"`([^`\n]+)`")
NO_AREAS = {"none", "n/a", "na", "-", "nothing", "tbd"}

def clean(entry):
    e = entry.strip().strip("`").strip()
    while e.startswith("./"):
        e = e[2:]
    return e

def looks_like_path(s):
    return bool(s) and not re.search(r"\s", s) and ("/" in s or "." in s or "*" in s)

def prose_lines(body):
    # Lines outside fenced code blocks: a fence that quotes the format, or a
    # `# comment` in a shell snippet, is not a declaration or a heading. A fence
    # closes only on a bare run of its own character at least as long (CommonMark).
    opener = None
    for line in body.splitlines():
        m = FENCE_RE.match(line)
        if opener is None:
            if m:
                opener = m.group(1)
                continue
            yield line
        elif m and m.group(1)[0] == opener[0] and len(m.group(1)) >= len(opener) \
                and not m.group(2).strip():
            opener = None

def areas_of(issue):
    body = issue.get("body") or ""
    body = body if isinstance(body, str) else ""
    for line in prose_lines(body):
        m = TOUCHES_RE.match(line)
        if m and m.group(1).strip():
            entries = [clean(e) for e in m.group(1).split(",")]
            # `Touches: none` declares no areas; an empty line falls through below.
            return keep([a for a in entries if a and a.lower() not in NO_AREAS])
    areas, in_section = [], False
    for line in prose_lines(body):
        h = HEADING_RE.match(line)
        if h:
            in_section = h.group(1).strip().rstrip(":").strip().lower() == "files affected"
            continue
        if in_section:
            areas += [a for a in (clean(t) for t in BACKTICK_RE.findall(line)) if looks_like_path(a)]
    return keep(areas)

def keep(areas):
    seen, out = set(), []
    for a in areas:
        if a not in seen and not is_catch_all(a):
            seen.add(a)
            out.append(a)
    return out[:MAX_AREAS]

WILD = re.compile(r"[*?\[]")

MAX_SEGS = 32     # an area deeper than this is cut to its first segments
MAX_AREAS = 32    # areas read per issue

def segs(area):
    out = []
    for s in area.split("/"):
        if s in ("", "."):
            continue
        if s == "**" and out and out[-1] == "**":
            continue   # `**/**` matches what `**` does
        out.append(s)
    return out[:MAX_SEGS]

def is_catch_all(area):
    # Matches every path: no segment has a literal character (`**`, `*`, `*/**`,
    # or nothing after `/`). It would overlap every issue and, under strict, idle
    # every other worker, so it is not a declaration. `*.md` and `**/*.rs` are
    # real globs and are kept.
    return all(not s.replace("*", "").replace("?", "") for s in segs(area))

def is_leaf(area):
    # A file, with nothing under it: no trailing `/` and the last segment has an
    # extension. `src/web` may be a directory written without its slash.
    last = segs(area)[-1:] or [""]
    return not area.endswith("/") and "." in last[0].strip(".") and last[0] != "**"

def seg_eq(x, y):
    wx, wy = bool(WILD.search(x)), bool(WILD.search(y))
    if wx and wy:
        return True
    if wx:
        return fnmatch.fnmatchcase(y, x)
    if wy:
        return fnmatch.fnmatchcase(x, y)
    return x == y

def comparable(a, b, a_leaf, b_leaf):
    # True when some path matched by one equals, or lies under, some path matched
    # by the other. Running out of one side means it names an ancestor of the
    # other's remaining path, which counts only when it can have children.
    # Memoised on positions, so `**` costs O(len(a) * len(b)), not exponential
    # time: issue bodies are untrusted and the gate runs unattended.
    @functools.lru_cache(maxsize=None)
    def go(i, j):
        if i == len(a) or j == len(b):
            rest = b[j:] if i == len(a) else a[i:]
            leaf = a_leaf if i == len(a) else b_leaf
            return not rest or not leaf or all(s == "**" for s in rest)
        if a[i] == "**":
            return go(i + 1, j) or go(i, j + 1)
        if b[j] == "**":
            return go(i, j + 1) or go(i + 1, j)
        return seg_eq(a[i], b[j]) and go(i + 1, j + 1)
    return go(0, 0)

def lists_overlap(xs, ys):
    return any(comparable(tuple(segs(x)), tuple(segs(y)), is_leaf(x), is_leaf(y))
               for x in xs for y in ys)

def lines(s):
    return [l.strip() for l in (s or "").splitlines() if l.strip()]

cmd = sys.argv[1]
if cmd == "of":
    raw = sys.stdin.read() if os.environ["T_JSON"] == "-" else os.environ["T_JSON"]
    try:
        issue = json.loads(raw)
    except ValueError:
        sys.exit(2)
    for a in areas_of(issue if isinstance(issue, dict) else {}):
        print(a)
elif cmd == "overlap":
    a = [x for x in lines(os.environ["T_A"]) if not is_catch_all(x)]
    b = [x for x in lines(os.environ["T_B"]) if not is_catch_all(x)]
    sys.exit(0 if a and b and lists_overlap(a, b) else 1)
elif cmd == "order":
    mode = os.environ["T_MODE"]
    cands = lines(os.environ["T_CANDS"])
    if mode not in ("prefer", "strict"):
        print("\n".join(cands))
        sys.exit(0)
    def load(path):
        try:
            with open(path) as fh:
                data = json.load(fh)
        except (OSError, ValueError):
            return []
        return [i for i in data if isinstance(i, dict)] if isinstance(data, list) else []
    working = load(os.environ["T_WORKING"])
    # A takeover candidate is itself `working`, so it may only be in that list.
    by_num = {i.get("number"): i for i in working + load(os.environ["T_OPEN"])}
    inflight = [(i.get("number"), areas_of(i)) for i in working]
    inflight = [(n, a) for n, a in inflight if a]
    hot = [h for h in lines(os.environ.get("T_HOT", "")) if not is_catch_all(h)]
    clear, busy = [], []
    for line in cands:
        f = line.split()
        num = int(f[1]) if len(f) > 1 and f[1].isdigit() else None
        mine = areas_of(by_num.get(num) or {})
        # Hot files (#228): one in-flight claim at a time, whatever the mode.
        mine_hot = [h for h in hot if mine and lists_overlap(mine, [h])]
        held = next(((n, h) for h in mine_hot for n, a in inflight
                     if n != num and lists_overlap(a, [h])), None)
        if held is not None:
            print(f"touches: #{num} skipped: hot file {held[1]} is held by in-flight #{held[0]} ({mode})",
                  file=sys.stderr)
            continue
        hit = next((n for n, a in inflight if n != num and mine and lists_overlap(mine, a)), None)
        if hit is None:
            clear.append(line)
        else:
            print(f"touches: #{num} overlaps in-flight #{hit} ({mode})", file=sys.stderr)
            busy.append(line)
    print("\n".join(clear + (busy if mode == "prefer" else [])))
elif cmd == "mode":
    path = os.environ.get("T_CONFIG") or ""
    mode = "off"
    try:
        with open(path) as fh:
            cfg = json.load(fh)
        mode = ((cfg.get("claims") or {}).get("avoid_overlap") or "off")
    except (OSError, ValueError, AttributeError):
        mode = "off"
    mode = str(mode).strip().lower()
    if mode not in ("off", "prefer", "strict"):
        print(f"touches: unknown claims.avoid_overlap '{mode}' in {path}; using off", file=sys.stderr)
        mode = "off"
    print(mode)
elif cmd == "hot":
    import datetime, time
    raw = "50"
    try:
        with open(os.environ.get("T_CONFIG") or "") as fh:
            cfg = json.load(fh)
        w = (cfg.get("claims") or {}).get("hot_window")
        if w is not None:
            raw = str(w)
    except (OSError, ValueError, AttributeError):
        pass
    raw = raw.strip().lower()
    m = re.fullmatch(r"(\d+)\s*(d|days?)?", raw)
    if not m or int(m.group(1)) <= 0:
        print(f"touches: unknown claims.hot_window '{raw}'; using 50", file=sys.stderr)
        m = re.fullmatch(r"(\d+)()", "50")
    count, days = int(m.group(1)), bool(m.group(2))
    repo = os.environ.get("T_REPO") or ""
    attempts = []
    try:
        with open(os.environ.get("T_EVENTS") or "", errors="replace") as fh:
            for l in fh:
                try:
                    ev = json.loads(l)
                except ValueError:
                    continue
                if not isinstance(ev, dict) or ev.get("event") != "attempt":
                    continue
                if repo and ev.get("repo") not in (None, "", repo):
                    continue
                attempts.append(ev)
    except OSError:
        sys.exit(0)
    if days:
        cutoff = time.time() - count * 86400
        def recent(ev):
            try:
                t = datetime.datetime.strptime(str(ev.get("ts")), "%Y-%m-%dT%H:%M:%SZ")
            except ValueError:
                return False
            return t.replace(tzinfo=datetime.timezone.utc).timestamp() >= cutoff
        window = [ev for ev in attempts if recent(ev)]
    else:
        window = attempts[-count:]
    hot = set()
    for ev in window:
        if ev.get("outcome") != "conflict" or not isinstance(ev.get("files"), list):
            continue
        hot.update(clean(f) for f in ev["files"] if isinstance(f, str) and clean(f))
    for h in sorted(hot):
        print(h)
PY
)

touches_of() {
  # Through stdin, not the environment: one variable is capped at 128 KB.
  if [ "$1" = - ]; then
    T_JSON=- python3 -c "$_TOUCHES_PY" of
  else
    printf '%s' "$1" | T_JSON=- python3 -c "$_TOUCHES_PY" of
  fi
}

areas_overlap() {
  T_A="$1" T_B="$2" python3 -c "$_TOUCHES_PY" overlap
}

touches_order() {
  T_MODE="$1" T_CANDS="$2" T_OPEN="$3" T_WORKING="$4" T_HOT="${T_HOT:-}" python3 -c "$_TOUCHES_PY" order
}

touches_mode() {
  T_CONFIG="${1:-}" python3 -c "$_TOUCHES_PY" mode
}

touches_hot_files() {
  local events
  events="${AUTOCODER_MERGE_EVENTS:-${XDG_STATE_HOME:-$HOME/.local/state}/autocoder/merge-events.jsonl}"
  [ -f "$events" ] || return 0
  T_CONFIG="${1:-}" T_REPO="${2:-}" T_EVENTS="$events" python3 -c "$_TOUCHES_PY" hot
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    hot)
      _t_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
      # shellcheck source=repo-id-fns.sh
      source "${_t_dir}/repo-id-fns.sh"
      _t_main="$(git worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')"
      touches_hot_files "${_t_main:-.}/.autocoder.json" "$(autocoder_repo_id "$PWD")"
      ;;
    *) echo "usage: touches-fns.sh hot   (or source it for the touches_* functions)" >&2; exit 2 ;;
  esac
fi
