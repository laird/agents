#!/bin/bash
# dispatch-issue.sh — send an issue to a worker WITHOUT ending its fix loop.
#
# Writes the dispatch file dispatch-fns.sh describes; the named worktree's next
# fix-loop tick claims (or resumes) the issue ahead of its own pick and other
# workers' gates keep off it meanwhile. Use it in place of typing
# `/clear` + `/autocoder:fix N` into the pane of a worker that runs the loop
# (the default): the typed form ends the loop and leaves the worker idle when
# the issue is done.
#
# Usage:
#   dispatch-issue.sh <issue> --worktree <path|name> [--note TEXT] [--force]
#   dispatch-issue.sh --list
#   dispatch-issue.sh --clear <path|name>
#
# Refuses (exit 1) unless --force: an issue that is not open, that carries a
# blocking or proposal label, or that is `working` on a branch the target does not
# hold (someone else's claim; a `working` issue whose branch the target worktree is
# on is the reboot path: the worker resumes it). A worktree that is not one of this
# repository's is refused too. An existing dispatch for the worktree is replaced,
# and said. Exit 2 on bad usage.
#
# Environment: AUTOCODER_DISPATCH_TTL_S (fresh window, 7200), AUTOCODER_MANAGER /
# USER (recorded as `by`), the issue backend's own (issue-fns.sh).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=dispatch-fns.sh
source "$SCRIPT_DIR/dispatch-fns.sh"

usage() { sed -n '/^# Usage:/,/^#$/p' "$0" | sed 's/^# \{0,1\}//'; }
ISSUE="" WORKTREE="" NOTE="" FORCE=0 MODE=dispatch
while [ $# -gt 0 ]; do
  case "$1" in
    --worktree) WORKTREE="${2:-}"; shift 2 ;;
    --note) NOTE="${2:-}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --list) MODE=list; shift ;;
    --clear) MODE=clear; WORKTREE="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "dispatch-issue: unknown option '$1'" >&2; usage >&2; exit 2 ;;
    *) if [ -z "$ISSUE" ] && [[ "$1" =~ ^[0-9]+$ ]]; then ISSUE="$1"; else echo "dispatch-issue: unexpected argument '$1'" >&2; exit 2; fi; shift ;;
  esac
done

MAIN=$(dispatch_main_worktree) || { echo "dispatch-issue: not inside a git checkout" >&2; exit 2; }
[ -n "$MAIN" ] || { echo "dispatch-issue: not inside a git checkout" >&2; exit 2; }
DIR=$(dispatch_dir "$MAIN")

if [ "$MODE" = list ]; then
  found=0
  if [ -d "$DIR" ]; then
    for f in "$DIR"/*; do
      [ -f "$f" ] || continue
      case "$(basename "$f")" in .*) continue ;; esac
      row=$(dispatch_read "$f"); rc=$?
      case "$rc" in
        0) state=fresh ;;
        2) state=stale ;;
        *) row="-	-	-	unreadable"; state=unreadable ;;
      esac
      printf '%s\t%s\t%s\n' "$(basename "$f")" "$state" "$row"
      found=1
    done
  fi
  [ "$found" = 1 ] || echo "no dispatch is pending (dir $DIR)"
  exit 0
fi

[ -n "$WORKTREE" ] || { echo "dispatch-issue: --worktree <path|name> is required" >&2; usage >&2; exit 2; }
NAME=$(dispatch_name_of "$WORKTREE")
# The worktree must be one of this repository's: a typo would write a file no gate reads.
WT_PATH=""
while IFS= read -r line; do
  case "$line" in "worktree "*) p="${line#worktree }"; [ "$(basename "$p")" = "$NAME" ] && WT_PATH="$p" ;; esac
done < <(git worktree list --porcelain 2>/dev/null)
if [ -z "$WT_PATH" ] && [ "$FORCE" != 1 ]; then
  echo "dispatch-issue: no worktree of this repository is named '$NAME' (git worktree list); --force writes it anyway" >&2
  exit 1
fi

if [ "$MODE" = clear ]; then
  if [ -f "$DIR/$NAME" ]; then
    row=$(dispatch_read "$DIR/$NAME" || true)
    dispatch_remove "$DIR" "$NAME"
    echo "cleared the dispatch for $NAME${row:+ (#${row%%	*})}"
  else
    echo "no dispatch is pending for $NAME"
  fi
  exit 0
fi

[ -n "$ISSUE" ] || { echo "dispatch-issue: an issue number is required" >&2; usage >&2; exit 2; }
# shellcheck source=issue-fns.sh
source "$SCRIPT_DIR/issue-fns.sh"
if [ "$FORCE" != 1 ]; then
  json=$(issue_get "$ISSUE" 2>/dev/null) || { echo "dispatch-issue: #$ISSUE cannot be read from the tracker; --force dispatches it unchecked" >&2; exit 1; }
  BRANCH=""
  [ -n "$WT_PATH" ] && BRANCH=$(git -C "$WT_PATH" branch --show-current 2>/dev/null || true)
  why=$(printf '%s' "$json" | ISSUE="$ISSUE" BRANCH="$BRANCH" python3 -c '
import json, os, sys
d = json.load(sys.stdin)
labels = {(l.get("name") if isinstance(l, dict) else l) for l in d.get("labels") or []}
blocking = {"needs-approval", "needs-design", "needs-clarification", "too-complex", "future", "decomposed", "blocked",
            "awaiting-integration", "merging", "proposal"}
n, branch = os.environ["ISSUE"], os.environ["BRANCH"]
if str(d.get("state", "")).lower() != "open":
    print("#" + n + " is " + str(d.get("state")) + ", not open")
elif labels & blocking:
    print(f"#{n} carries " + ", ".join(sorted(labels & blocking)) + ": blocked from autonomous work")
elif "working" in labels and branch not in (f"feature/issue-{n}", f"enhancement/issue-{n}-auto"):
    print(f"#{n} is `working` and the target is on {branch or chr(45)}, not its branch: someone else holds it")
')
  if [ -n "$why" ]; then
    echo "dispatch-issue: refused: $why (--force overrides)" >&2
    exit 1
  fi
fi
BY="${AUTOCODER_MANAGER:-${USER:-manager}}@$(hostname -s 2>/dev/null || echo host)"
prev=""
[ -f "$DIR/$NAME" ] && prev=$(dispatch_read "$DIR/$NAME" || true)
dispatch_write "$DIR" "$NAME" "$ISSUE" "$BY" "$NOTE" || { echo "dispatch-issue: could not write $DIR/$NAME" >&2; exit 1; }
echo "dispatched #$ISSUE to $NAME${prev:+ (replacing #${prev%%	*})}: its next fix-loop tick takes it ahead of its own pick; other workers keep off it for $(dispatch_ttl)s ($DIR/$NAME)"
