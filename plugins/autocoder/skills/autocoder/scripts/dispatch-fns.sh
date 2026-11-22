#!/bin/bash
# dispatch-fns.sh — a manager's dispatch as an OVERRIDE of a worker's own next pick.
#
# Workers run the continuous fix loop by default: between tasks each one's gate
# (fix-loop-gate.sh) claims the next unblocked issue by priority. A manager who wants
# a particular worker on a particular issue used to type `/clear` and `/autocoder:fix N`
# into its pane, which ends the loop: the worker idles at a prompt when that issue is
# done (measured on one project: five workers idle 10 to 60 minutes each in one day,
# waiting for the next typed dispatch). A dispatch is now a FILE the target's gate reads
# first and other gates keep off:
#
#   <main worktree>/.autocoder/dispatch/<worktree basename>
#   {"issue": N, "ts": "<ISO UTC>", "by": "<who>", "note": "<why>"}
#
# dispatch-issue.sh writes one; the next tick of the named worktree's loop claims that
# issue ahead of its own pick (or resumes it, when the issue is the worktree's own held
# claim: the reboot path), marks the plan `"dispatched": true`, and removes the file.
# Every other worktree's gate skips an issue named in a fresh dispatch file, so the
# target's tick (at most one interval away) finds it unclaimed. A file older than
# AUTOCODER_DISPATCH_TTL_S (default 7200 s) is stale: the worker never came (a dead
# pane); its gate removes it when it does come, and other gates stop honouring it.
#
# The typed `/autocoder:fix N` still works inside a loop session (the gate recognises
# the session's own claim as in flight, #130); the file is for a dispatch that must not
# end the loop and must not race the worker's own gate.
#
# Requires: git. Callers that read issues source issue-fns.sh themselves.

# dispatch_main_worktree → the main worktree's path (the dispatch dir is shared by the swarm).
dispatch_main_worktree() {
  git worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p'
}

# dispatch_dir [main-worktree] → the shared dispatch directory (not created).
dispatch_dir() {
  local main="${1:-$(dispatch_main_worktree)}"
  [ -n "$main" ] || return 1
  printf '%s/.autocoder/dispatch\n' "$main"
}

# dispatch_own_name → this worktree's name: the basename of its top-level directory.
dispatch_own_name() {
  local top
  top=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
  basename "$top"
}

# dispatch_name_of <path|name> → the basename a worktree path or name maps to.
dispatch_name_of() {
  basename "${1%/}"
}

# dispatch_ttl → seconds a dispatch stays fresh.
dispatch_ttl() {
  printf '%s\n' "${AUTOCODER_DISPATCH_TTL_S:-7200}"
}

# dispatch_read <file> → prints "<issue>\t<ts>\t<by>\t<note>" (exit 0 fresh, 2 stale, 1 unreadable).
dispatch_read() {
  local f="$1"
  [ -f "$f" ] || return 1
  TTL="$(dispatch_ttl)" python3 - "$f" <<'PY'
import json, os, sys
from datetime import datetime, timezone
try:
    d = json.load(open(sys.argv[1]))
    issue = int(d["issue"])
    ts = str(d.get("ts") or "")
    age = (datetime.now(timezone.utc) - datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)).total_seconds()
except (OSError, ValueError, KeyError, TypeError):
    sys.exit(1)
print("\t".join([str(issue), ts, str(d.get("by") or "-"), str(d.get("note") or "-").replace("\t", " ").replace("\n", " ")]))
sys.exit(0 if age <= int(os.environ["TTL"]) else 2)
PY
}

# dispatch_write <dir> <name> <issue> <by> <note> → writes the file atomically.
dispatch_write() {
  local dir="$1" name="$2" issue="$3" by="$4" note="$5" tmp
  mkdir -p "$dir" || return 1
  tmp=$(mktemp "$dir/.${name}.XXXXXX") || return 1
  ISSUE="$issue" BY="$by" NOTE="$note" python3 - "$tmp" <<'PY' || { rm -f "${tmp:?}"; return 1; }
import json, os, sys
from datetime import datetime, timezone
json.dump({"issue": int(os.environ["ISSUE"]), "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
           "by": os.environ["BY"], "note": os.environ["NOTE"]}, open(sys.argv[1], "w"))
PY
  mv -f "$tmp" "$dir/$name"
}

# dispatch_remove <dir> <name> → removes a dispatch file (nothing else: both parts must be set).
dispatch_remove() {
  rm -f "${1:?dispatch dir}/${2:?worktree name}"
}

# dispatch_others_json <dir> <own name> → a JSON list of the issues FRESH dispatches name for other worktrees.
dispatch_others_json() {
  local dir="$1" own="$2" f row out="[" sep=""
  [ -d "$dir" ] || { echo "[]"; return 0; }
  for f in "$dir"/*; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in "$own"|.*) continue ;; esac
    row=$(dispatch_read "$f") || continue   # stale or unreadable: not honoured
    out="${out}${sep}${row%%	*}"; sep=","
  done
  echo "${out}]"
}
