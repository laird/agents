#!/usr/bin/env bash
# prune-test-events.sh — drop test-fixture records from the per-user event logs (#282).
#
# Before #282 the shell suite could write its fixtures' merge and issue events
# into the real ${XDG_STATE_HOME:-~/.local/state}/autocoder/{merge,issue}-events.jsonl,
# where /retro, flaky-report.sh and UIs read them as real merges and issues.
# The suite no longer does; this removes what it left behind. It is a one-off
# cleanup: nothing runs it automatically.
#
# A record is kept when its "repo" is the repo id (repo-id-fns.sh) of a known
# repo: every root in the swarm-roots registry (reboot-lib.sh), every --root,
# and every --keep-repo. Everything else is dropped, including a record with no
# "repo" or a null one. Lines that are not JSON are kept and counted, so nothing
# this script cannot read is lost. landing-timings.jsonl carries no repo, so it
# cannot be sorted this way and is left alone.
#
# Usage: prune-test-events.sh [--apply] [--state-dir DIR] [--root PATH]... [--keep-repo ID]...
#   (default)    dry run: per file, how many records would be kept and dropped,
#                and the commonest dropped repo ids
#   --apply      rewrite each file, after copying it to <file>.bak-<UTC stamp>
#   --state-dir  default ${XDG_STATE_HOME:-~/.local/state}/autocoder
#
# Run --apply while no merge job or worker is writing (between batches): a file
# that grows while it is being rewritten is left unchanged and reported, so a
# record appended during the run is never lost, but the prune must then be re-run.
#
# Exit: 0 done (or nothing to do), 1 a file could not be rewritten, 2 usage error.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=repo-id-fns.sh
source "$SCRIPT_DIR/repo-id-fns.sh"
# shellcheck source=reboot-lib.sh
source "$SCRIPT_DIR/reboot-lib.sh"

usage() { sed -n '17,22p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

APPLY=false
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/autocoder"
ROOTS=()
KEEP=()
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=true ;;
    --state-dir) [ $# -ge 2 ] || usage; STATE_DIR="$2"; shift ;;
    --root) [ $# -ge 2 ] || usage; ROOTS+=("$2"); shift ;;
    --keep-repo) [ $# -ge 2 ] || usage; KEEP+=("$2"); shift ;;
    -h|--help) usage ;;
    *) echo "prune-test-events: unknown argument: $1" >&2; usage ;;
  esac
  shift
done

while IFS= read -r r; do ROOTS+=("$r"); done < <(swarm_roots_list)
for r in ${ROOTS[@]+"${ROOTS[@]}"}; do
  if [ -d "$r" ]; then
    KEEP+=("$(autocoder_repo_id "$r")")
  else
    echo "prune-test-events: skipping missing root $r" >&2
  fi
done
if [ ${#KEEP[@]} -eq 0 ]; then
  echo "prune-test-events: no known repo (empty swarm-roots registry, no --root or --keep-repo); refusing to drop every record" >&2
  exit 2
fi
echo "Keeping records for: $(printf '%s\n' "${KEEP[@]}" | sort -u | tr '\n' ' ')"

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
rc=0
for name in merge-events.jsonl issue-events.jsonl; do
  f="$STATE_DIR/$name"
  [ -f "$f" ] || { echo "$name: not present"; continue; }
  # The python half filters into $f.prune.$$ and prints the summary; the shell
  # half does the backup and the swap, so a failure leaves the original alone.
  size_before=$(wc -c < "$f" | tr -d ' ')
  out="$f.prune.$$"
  (umask 077; python3 - "$f" "$out" "$APPLY" "${KEEP[@]}" <<'PY'
import collections, json, sys
src, dst, apply, keep = sys.argv[1], sys.argv[2], sys.argv[3] == "true", set(sys.argv[4:])
kept = dropped = unreadable = 0
gone = collections.Counter()
lines = []
with open(src, "rb") as fh:
    for raw in fh:
        try:
            rec = json.loads(raw)
            repo = rec.get("repo") if isinstance(rec, dict) else None
        except ValueError:
            unreadable += 1
            lines.append(raw)
            continue
        if repo in keep:
            kept += 1
            lines.append(raw)
        else:
            dropped += 1
            gone[repo if repo is not None else "<no repo>"] += 1
if apply and dropped:
    with open(dst, "wb") as fh:
        fh.writelines(lines)
top = ", ".join(f"{k} {v}" for k, v in gone.most_common(5))
print(f"keep {kept}, drop {dropped}" + (f", unreadable (kept) {unreadable}" if unreadable else "")
      + (f"; dropped repos: {top}" if top else ""))
PY
  ) > "$out.summary" || { echo "$name: could not read it" >&2; rm -f "$out" "$out.summary"; rc=1; continue; }
  echo "$name: $(cat "$out.summary")"
  rm -f "$out.summary"
  [ "$APPLY" = true ] && [ -f "$out" ] || { rm -f "$out"; continue; }
  if [ "$(wc -c < "$f" | tr -d ' ')" != "$size_before" ]; then
    echo "$name: grew while being pruned (a live writer); left unchanged, re-run when it is quiet" >&2
    rm -f "$out"; rc=1; continue
  fi
  if cp -p "$f" "$f.bak-$STAMP" && mv -f "$out" "$f"; then
    echo "$name: rewritten; backup at $f.bak-$STAMP"
  else
    echo "$name: rewrite failed; the original is unchanged" >&2
    rm -f "$out"; rc=1
  fi
done
echo "landing-timings.jsonl: no repo field, left alone"
[ "$APPLY" = true ] || echo "Dry run. Re-run with --apply to rewrite (a backup is kept)."
exit "$rc"
