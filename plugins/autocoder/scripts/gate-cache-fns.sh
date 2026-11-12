#!/bin/bash
# gate-cache-fns.sh — remember which git TREES have already passed (or failed) a gate.
#
# A gate result is a property of the exact tree it ran on plus the command it ran, and
# of nothing else. Workers merge main into their branch and test the result; the tree
# they push is the tree they tested. A sentinel that later tests main's tip, a bisect
# that revisits a commit, or a worker whose re-sync produced a tree a sibling already
# gated can all skip the run when the <tree, command> pair is on record. Entries are
# one file per key, written tmp+rename, so concurrent writers on the same host never
# see a torn record and a repeat put converges to the same file.
#
# Source this file; callers use:
#   gate_cache_get <tree-sha> "<test-cmd>"        -> prints pass|fail, rc 0 if recorded, 1 if not
#   gate_cache_put <tree-sha> "<test-cmd>" pass|fail
#   gate_cache_run <dir> "<test-cmd>"             -> rc 0 pass / 1 fail; runs only on a miss
#   gate_cache_prune [days]                       -> deletes records older than N days (default 30)
#
# gate_cache_run reuses a recorded pass unconditionally and a recorded fail only when
# GATE_CACHE_REUSE_FAIL=1 (a bisect wants that; a merge retry does not, since the fail
# may be flake). It prints one line saying whether it hit or ran, for logs.
#
# Location: ${AUTOCODER_GATE_CACHE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/autocoder/gate-cache}

gate_cache_dir() {
  printf '%s' "${AUTOCODER_GATE_CACHE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/autocoder/gate-cache}"
}

_gate_cache_key() {
  local tree="$1" cmd="$2" cmd_hash
  cmd_hash=$(printf '%s' "$cmd" | git hash-object --stdin 2>/dev/null || printf '%s' "$cmd" | sha1sum | cut -c1-40)
  printf '%s-%s' "$tree" "${cmd_hash:0:12}"
}

gate_cache_get() {
  local f
  f="$(gate_cache_dir)/$(_gate_cache_key "$1" "$2")"
  [ -f "$f" ] || return 1
  awk 'NR==1 {print $1}' "$f"
}

gate_cache_put() {
  local tree="$1" cmd="$2" verdict="$3" dir f tmp
  case "$verdict" in pass|fail) ;; *) echo "gate_cache_put: verdict must be pass|fail" >&2; return 2 ;; esac
  dir="$(gate_cache_dir)"
  mkdir -p "$dir" || return 1
  f="$dir/$(_gate_cache_key "$tree" "$cmd")"
  tmp=$(mktemp "$dir/.tmp.XXXXXX") || return 1
  printf '%s %s\n' "$verdict" "$(date +%s)" > "$tmp" && mv -f "$tmp" "$f"
}

gate_cache_run() {
  local dir="$1" cmd="$2" tree recorded
  tree=$(git -C "$dir" rev-parse 'HEAD^{tree}') || return 1
  if recorded=$(gate_cache_get "$tree" "$cmd"); then
    if [ "$recorded" = pass ] || [ "${GATE_CACHE_REUSE_FAIL:-0}" = 1 ]; then
      echo "gate-cache: ${recorded} recorded for tree ${tree:0:8}; not re-running"
      [ "$recorded" = pass ]
      return
    fi
  fi
  echo "gate-cache: no usable record for tree ${tree:0:8}; running gate"
  if (cd "$dir" && bash -c "$cmd"); then
    gate_cache_put "$tree" "$cmd" pass
    _gate_cache_record_left_tree "$dir" "$tree" "$cmd" pass
    return 0
  fi
  gate_cache_put "$tree" "$cmd" fail
  _gate_cache_record_left_tree "$dir" "$tree" "$cmd" fail
  return 1
}

# A gate command may commit inside its worktree before its test stages (regenerated
# files, a baseline ratchet), so the tree it LEAVES is the one its verdict is about as
# much as the tree it started from. Record both: the caller publishes the left tree, and
# a later run on that exact tree is a hit, not a second run.
_gate_cache_record_left_tree() {
  local dir="$1" started="$2" cmd="$3" verdict="$4" left
  left=$(git -C "$dir" rev-parse 'HEAD^{tree}' 2>/dev/null) || return 0
  [ "$left" != "$started" ] || return 0
  echo "gate-cache: the command left tree ${left:0:8} (started on ${started:0:8}); ${verdict} recorded for it too"
  gate_cache_put "$left" "$cmd" "$verdict"
}

gate_cache_prune() {
  local dir
  dir="$(gate_cache_dir)"
  [ -d "$dir" ] || return 0
  find "$dir" -maxdepth 1 -type f -mtime "+${1:-30}" -delete 2>/dev/null || true
}
