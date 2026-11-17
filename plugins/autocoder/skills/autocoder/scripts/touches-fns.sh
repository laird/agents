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
# across segments). Backticks around entries are ignored. With no `Touches:`
# line, the backticked paths in a `## Files Affected` section count instead.
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
#   touches_mode [<config-file>]          print the configured mode: off, prefer
#                                        or strict (default off; an unknown value
#                                        warns on stderr and reads as off)

_TOUCHES_PY=$(cat <<'PY'
import fnmatch, json, os, re, sys

TOUCHES_RE = re.compile(r"^[ \t>*_-]*Touches:[*_]*[ \t]*(.*)$", re.IGNORECASE | re.MULTILINE)
HEADING_RE = re.compile(r"^#{1,6}[ \t]+(.*?)[ \t]*#*[ \t]*$")
BACKTICK_RE = re.compile(r"`([^`\n]+)`")

def clean(entry):
    e = entry.strip().strip("`").strip()
    while e.startswith("./"):
        e = e[2:]
    return e

def looks_like_path(s):
    return bool(s) and not re.search(r"\s", s) and ("/" in s or "." in s or "*" in s)

def areas_of(issue):
    body = issue.get("body") or ""
    m = TOUCHES_RE.search(body)
    if m:
        return [a for a in (clean(e) for e in m.group(1).split(",")) if a]
    areas, in_section = [], False
    for line in body.splitlines():
        h = HEADING_RE.match(line)
        if h:
            in_section = h.group(1).strip().lower() == "files affected"
            continue
        if in_section:
            areas += [a for a in (clean(t) for t in BACKTICK_RE.findall(line)) if looks_like_path(a)]
    seen = set()
    return [a for a in areas if not (a in seen or seen.add(a))]

WILD = re.compile(r"[*?\[]")

def segs(area):
    return [s for s in area.split("/") if s not in ("", ".")]

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
    if not a or not b:
        rest = b or a
        leaf = a_leaf if not a else b_leaf
        return not rest or not leaf or all(s == "**" for s in rest)
    if a[0] == "**":
        return comparable(a[1:], b, a_leaf, b_leaf) or comparable(a, b[1:], a_leaf, b_leaf)
    if b[0] == "**":
        return comparable(a, b[1:], a_leaf, b_leaf) or comparable(a[1:], b, a_leaf, b_leaf)
    return seg_eq(a[0], b[0]) and comparable(a[1:], b[1:], a_leaf, b_leaf)

def lists_overlap(xs, ys):
    return any(comparable(segs(x), segs(y), is_leaf(x), is_leaf(y)) for x in xs for y in ys)

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
    a, b = lines(os.environ["T_A"]), lines(os.environ["T_B"])
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
    clear, busy = [], []
    for line in cands:
        f = line.split()
        num = int(f[1]) if len(f) > 1 and f[1].isdigit() else None
        mine = areas_of(by_num.get(num) or {})
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
PY
)

touches_of() {
  T_JSON="$1" python3 -c "$_TOUCHES_PY" of
}

areas_overlap() {
  T_A="$1" T_B="$2" python3 -c "$_TOUCHES_PY" overlap
}

touches_order() {
  T_MODE="$1" T_CANDS="$2" T_OPEN="$3" T_WORKING="$4" python3 -c "$_TOUCHES_PY" order
}

touches_mode() {
  T_CONFIG="${1:-}" python3 -c "$_TOUCHES_PY" mode
}
