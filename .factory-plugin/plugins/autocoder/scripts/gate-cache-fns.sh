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
#   gate_cache_forget <tree-sha> "<test-cmd>"     -> removes the record (a run that was no
#                                                    verdict: the host could not run the gate)
#   gate_cache_run <dir> "<test-cmd>"             -> rc 0 pass / 1 fail; runs only on a miss
#   gate_cache_prune [days]                       -> deletes records older than N days (default 30)
#
# gate_cache_run reuses a recorded pass unconditionally and a recorded fail only when
# GATE_CACHE_REUSE_FAIL=1 (a bisect wants that; a merge retry does not, since the fail
# may be flake). It prints one line saying whether it hit or ran, for logs.
#
# Flaky sightings (#191). A fail record also lists the tests that failed and an excerpt
# of each failure (lines after the first; gate_cache_get reads only line 1). When
# gate_cache_run later runs the same <tree, command> and a test named in that record no
# longer fails, the test is flaky on this tree, since nothing else changed. Each such test
# is passed to gate_cache_on_flaky <tree> <test> <excerpt> when the caller defines it
# (merge-to-integration.sh records it in merge-events.jsonl). A fail record that names no
# test reports the whole gate once, with an empty test name.
#
# AUTOCODER_GATE_FLAKE_RERUN=1 re-runs a failing gate once, on the same tree, before
# recording it red. AUTOCODER_GATE_RERUN_CMD, if set, is the re-run command with {tests}
# replaced by the failed test names (e.g. "bash tests/run-shell-suite.sh {tests}");
# without it, or when the failures cannot be named safely, the whole command re-runs.
# A clean re-run records pass, reports each first-run failure as a sighting, and the gate
# passes. A second failure is a real failure.
#
# The narrowed re-run is used only when the first run's "Tests: N failed" summary (as
# tests/run-shell-suite.sh prints) counts exactly the named tests, and every name is a
# plain word (no leading '-', no '..'); the runner must not read names as options.
#
#   gate_log_failed_tests <log>                   -> failing test names, one per line (<= 50)
#
# Location: ${AUTOCODER_GATE_CACHE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/autocoder/gate-cache}
#
# The key also carries the tree's gate environment (gate-env-fns.sh, #223): a tree whose
# committed .autocoder.json sets gate.hermetic gets a key suffixed with a hash of that
# config, so a host-environment pass never satisfies a hermetic gate. get/put read the
# tree from the repository in the current directory, or from [git-dir] when given; a
# tree that repository does not have is looked up under the host key, as before (a
# hermetic run never writes the host key, so this cannot borrow a host pass for it). A
# tree whose hermetic config cannot be parsed (python3 missing) has no usable key: get
# misses and put records nothing, so no host-mode pass can stand in for it.
# Host-mode keys are unchanged.

# shellcheck source=gate-env-fns.sh
source "$(dirname "${BASH_SOURCE[0]}")/gate-env-fns.sh"

gate_cache_dir() {
  printf '%s' "${AUTOCODER_GATE_CACHE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/autocoder/gate-cache}"
}

_gate_cache_key() {  # <tree> "<cmd>" [git-dir]
  local tree="$1" cmd="$2" cmd_hash env_cfg rc suffix=""
  cmd_hash=$(printf '%s' "$cmd" | git hash-object --stdin 2>/dev/null || printf '%s' "$cmd" | sha1sum | cut -c1-40)
  env_cfg=$(gate_env_config "$tree" "${3:-.}"); rc=$?
  if [ "$rc" -eq 3 ]; then
    suffix="-envunreadable"     # never written, never read: no verdict while the mode is unknown
  elif [ "$rc" -eq 0 ] && [ -n "$env_cfg" ]; then
    suffix="-h$(printf '%s' "$env_cfg" | sha1sum | cut -c1-12)"
  fi
  printf '%s-%s%s' "$tree" "${cmd_hash:0:12}" "$suffix"
}

gate_cache_get() {  # <tree> "<cmd>" [git-dir]
  # [git-dir] (default: the current directory) should be a repository holding <tree>;
  # elsewhere the mode cannot be read and the host key is used.
  local f
  f="$(gate_cache_dir)/$(_gate_cache_key "$1" "$2" "${3:-.}")"
  case "$f" in *-envunreadable) return 1 ;; esac
  [ -f "$f" ] || return 1
  awk 'NR==1 {print $1}' "$f"
}

gate_cache_put() {  # <tree> "<cmd>" pass|fail [git-dir] [gate-log]
  # [gate-log] (fail only): the run's output, from which the record keeps the failing
  # tests and an excerpt of each, for flaky detection on a later run of the same tree.
  local tree="$1" cmd="$2" verdict="$3" log="${5:-}" dir f tmp t
  case "$verdict" in pass|fail) ;; *) echo "gate_cache_put: verdict must be pass|fail" >&2; return 2 ;; esac
  dir="$(gate_cache_dir)"
  mkdir -p "$dir" || return 1
  f="$dir/$(_gate_cache_key "$tree" "$cmd" "${4:-.}")"
  case "$f" in *-envunreadable) return 1 ;; esac
  tmp=$(mktemp "$dir/.tmp.XXXXXX") || return 1
  {
    printf '%s %s\n' "$verdict" "$(date +%s)"
    if [ "$verdict" = fail ] && [ -s "$log" ]; then
      while IFS= read -r t; do
        [ -n "$t" ] || continue
        # One line per test: "test <name>\t<excerpt with \\ and newlines escaped>".
        printf 'test %s\t%s\n' "$t" "$(gate_log_failure_excerpt "$log" "$t" | _gate_cache_escape)"
      done < <(gate_log_failed_tests "$log" files)
    fi
  } > "$tmp" && mv -f "$tmp" "$f"
}

# Failing test names in a gate log, one per line: run-shell-suite.sh's "Failing suites:"
# line, else "FAIL <name>" lines (both the suite's and per-assertion "FAIL: <name>").
# With "files", the fallback takes only file-shaped names (test_x.sh, spec/a_test.rb):
# free-text assertion lines ("FAIL: expected 3") name nothing a later run can match, so
# flaky detection must not read them as tests.
gate_log_failed_tests() {  # <log> [files]
  local f="$1" names
  [ -s "$f" ] || return 0
  names=$(sed -n 's/^Failing suites://p' "$f" | tr ' \t' '\n\n')
  if [ -z "$names" ] && [ "${2:-}" = files ]; then
    # A test file: <path>.<ext> whose extension starts with a letter and whose basename
    # says test or spec. "FAIL: 3.5 != 4" and "FAIL: config.yaml missing" are not tests.
    names=$(sed -nE 's/^FAIL[: ]+([A-Za-z0-9_][A-Za-z0-9._/:+-]*\.[A-Za-z][A-Za-z0-9]*)( .*)?$/\1/p' "$f" \
      | awk -F/ 'tolower($NF) ~ /test|spec/')
  elif [ -z "$names" ]; then
    names=$(sed -nE 's/^FAIL[: ]+([^ ]+).*/\1/p' "$f")
  fi
  printf '%s\n' "$names" | sed '/^$/d' | sort -u | head -n 50
}

# The first "FAIL <test>" line of <log> and what follows it, up to the next PASS/FAIL or
# summary line: at most 20 lines and 2000 bytes.
gate_log_failure_excerpt() {  # <log> <test>
  awk -v t="$2" '
    on && /^(PASS|FAIL)[: ]|^Failing suites:|^Tests: / { exit }
    !on && /^FAIL[: ]+/ { n = $0; sub(/^FAIL[: ]+/, "", n); sub(/ .*/, "", n); if (n == t) { on = 1; print; c = 1; next } }
    on { print; if (++c >= 20) exit }' "$1" 2>/dev/null | head -c 2000
}

# rc 0 when <log>'s last "Tests: N failed" summary counts exactly the <names> given.
_gate_log_names_every_failure() {  # <log> <names>
  local n
  n=$(sed -nE 's/^Tests: ([0-9]+) failed.*/\1/p' "$1" | tail -1)
  [ -n "$n" ] && [ "$n" -eq "$(printf '%s\n' "$2" | grep -c .)" ]
}

_gate_cache_escape() { sed 's/\\/\\\\/g' | awk 'NR > 1 { printf "\\n" } { printf "%s", $0 }'; }

# The tests a fail record names, as "<name>\t<escaped excerpt>" lines; nothing for a
# pass, a missing record or an older record that names none.
_gate_cache_failed_tests() {  # <tree> "<cmd>" [git-dir]
  local f
  f="$(gate_cache_dir)/$(_gate_cache_key "$1" "$2" "${3:-.}")"
  case "$f" in *-envunreadable) return 0 ;; esac
  [ -f "$f" ] || return 0
  sed -n 's/^test //p' "$f"
}

# Report each test in <before> ("<name>\t<escaped excerpt>" lines) that is not in <after>
# (names, one per line). <before> with no names reports the whole gate once.
_gate_cache_report_flaky() {  # <tree> <before> <after> [whole]
  local tree="$1" before="$2" after="$3" name excerpt
  if [ -z "$before" ]; then
    [ "${4:-}" = whole ] || return 0   # nothing named before, and the run is not green
    before=$'\t'
  fi
  while IFS=$'\t' read -r name excerpt; do
    if [ -n "$name" ] && printf '%s\n' "$after" | grep -qxF -- "$name"; then continue; fi
    echo "gate-cache: flaky: ${name:-the gate} failed earlier on tree ${tree:0:8} and passed now"
    if declare -F gate_cache_on_flaky >/dev/null; then
      gate_cache_on_flaky "$tree" "$name" "$(printf '%b' "$excerpt")" || true
    fi
  done <<< "$before"
}

# A run the host could not complete (a disk-space stage over its threshold, ENOSPC, a
# missing tool) is recorded as a fail by gate_cache_run, which cannot see the output. The
# caller that classified it removes the record so a bisect reusing fails never reads a
# host condition as a verdict. Prints one line when a record was there.
gate_cache_forget() {
  local tree="$1" cmd="$2" f
  f="$(gate_cache_dir)/$(_gate_cache_key "$tree" "$cmd")"
  [ -f "$f" ] || return 0
  rm -f "$f"
  echo "gate-cache: forgot the record for tree ${tree:0:8} (the run was not a verdict)"
}

gate_cache_run() {
  local dir="$1" cmd="$2" tree recorded
  tree=$(git -C "$dir" rev-parse 'HEAD^{tree}') || return 1
  if recorded=$(gate_cache_get "$tree" "$cmd" "$dir"); then
    if [ "$recorded" = pass ] || [ "${GATE_CACHE_REUSE_FAIL:-0}" = 1 ]; then
      echo "gate-cache: ${recorded} recorded for tree ${tree:0:8}$([ -n "$(gate_env_config "$tree" "$dir")" ] && echo ' (hermetic)'); not re-running"
      [ "$recorded" = pass ]
      return
    fi
  fi
  echo "gate-cache: no usable record for tree ${tree:0:8}; running gate"
  local earlier out rc failed rerun t
  earlier=$(_gate_cache_failed_tests "$tree" "$cmd" "$dir")
  [ "$recorded" = fail ] || earlier=""
  out=$(mktemp "${TMPDIR:-/tmp}/gate-cache-run.XXXXXX") || return 1
  gate_env_run "$dir" "$cmd" 2>&1 | tee "$out"; rc=${PIPESTATUS[0]}
  failed=$(gate_log_failed_tests "$out" files)
  if [ "$recorded" = fail ]; then
    # Same tree, same command, red before: what passes now is flaky.
    # A red run that names no failing test (a crash, an OOM kill, a timeout) says nothing
    # about which earlier failures went away, so it reports nothing.
    if [ "$rc" -eq 0 ]; then _gate_cache_report_flaky "$tree" "$earlier" "" whole
    elif [ -n "$failed" ]; then _gate_cache_report_flaky "$tree" "$earlier" "$failed"; fi
  fi
  if [ "$rc" -ne 0 ] && [ "${AUTOCODER_GATE_FLAKE_RERUN:-0}" = 1 ]; then
    rerun="$cmd"
    # Narrow the re-run to the named tests only when they are every failure the run had,
    # by the runner's own "Tests: N failed" count. Otherwise a failure no FAIL line named
    # (a crash, an odd format) would never re-run, and a narrowed pass would hide it.
    if [ -n "${AUTOCODER_GATE_RERUN_CMD:-}" ] && [ -n "$failed" ] \
       && _gate_log_names_every_failure "$out" "$failed" \
       && ! printf '%s\n' "$failed" | grep -qvE '^[A-Za-z0-9_][A-Za-z0-9._/:+-]*$' \
       && ! printf '%s\n' "$failed" | grep -qF '..'; then
      rerun=${AUTOCODER_GATE_RERUN_CMD//\{tests\}/$(printf '%s\n' "$failed" | paste -sd' ' -)}
    fi
    echo "gate-cache: gate failed on tree ${tree:0:8}; re-running once to tell flake from failure: $rerun"
    earlier=""
    while IFS= read -r t; do
      [ -n "$t" ] && earlier+="${t}"$'\t'"$(gate_log_failure_excerpt "$out" "$t" | _gate_cache_escape)"$'\n'
    done <<< "$failed"
    earlier=${earlier%$'\n'}
    local out2
    out2=$(mktemp "${TMPDIR:-/tmp}/gate-cache-rerun.XXXXXX") || { rm -f "$out"; return 1; }
    gate_env_run "$dir" "$rerun" 2>&1 | tee "$out2"; rc=${PIPESTATUS[0]}
    if [ "$rc" -eq 0 ]; then
      _gate_cache_report_flaky "$tree" "$earlier" "" whole
    else
      # Keep the failures the re-run confirmed, and report the ones it no longer has. A
      # re-run that named none (a crash, a usage error) reports nothing and keeps the
      # first run's list.
      local failed2
      failed2=$(gate_log_failed_tests "$out2" files)
      if [ -n "$failed2" ]; then
        _gate_cache_report_flaky "$tree" "$earlier" "$failed2"
        mv -f "$out2" "$out"
      fi
    fi
    rm -f "$out2"
  fi
  if [ "$rc" -eq 0 ]; then
    gate_cache_put "$tree" "$cmd" pass "$dir"
    _gate_cache_record_left_tree "$dir" "$tree" "$cmd" pass
  else
    gate_cache_put "$tree" "$cmd" fail "$dir" "$out"
    _gate_cache_record_left_tree "$dir" "$tree" "$cmd" fail "$out"
  fi
  rm -f "$out"
  [ "$rc" -eq 0 ]
}

# A gate command may commit inside its worktree before its test stages (regenerated
# files, a baseline ratchet), so the tree it LEAVES is the one its verdict is about as
# much as the tree it started from. Record both: the caller publishes the left tree, and
# a later run on that exact tree is a hit, not a second run.
_gate_cache_record_left_tree() {
  local dir="$1" started="$2" cmd="$3" verdict="$4" log="${5:-}" left
  left=$(git -C "$dir" rev-parse 'HEAD^{tree}' 2>/dev/null) || return 0
  [ "$left" != "$started" ] || return 0
  echo "gate-cache: the command left tree ${left:0:8} (started on ${started:0:8}); ${verdict} recorded for it too"
  gate_cache_put "$left" "$cmd" "$verdict" "$dir" "$log"
}

gate_cache_prune() {
  local dir
  dir="$(gate_cache_dir)"
  [ -d "$dir" ] || return 0
  find "$dir" -maxdepth 1 -type f -mtime "+${1:-30}" -delete 2>/dev/null || true
}
