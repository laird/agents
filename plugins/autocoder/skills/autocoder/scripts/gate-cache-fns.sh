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
#   gate_log_failed_tests <log>                   -> failing test names, one per line
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
      done < <(gate_log_failed_tests "$log")
    fi
  } > "$tmp" && mv -f "$tmp" "$f"
}

# Failing test names in a gate log, one per line: run-shell-suite.sh's "Failing suites:"
# line, else "FAIL <name>" lines (both the suite's and per-assertion "FAIL: <name>").
gate_log_failed_tests() {  # <log>
  local f="$1" names
  [ -s "$f" ] || return 0
  names=$(sed -n 's/^Failing suites://p' "$f" | tr ' ' '\n')
  [ -n "$names" ] || names=$(sed -nE 's/^FAIL[: ]+([^ ]+).*/\1/p' "$f")
  printf '%s\n' "$names" | sed '/^$/d' | sort -u
}

# The first "FAIL <test>" line of <log> and what follows it, up to the next PASS/FAIL or
# summary line: at most 20 lines and 2000 bytes.
gate_log_failure_excerpt() {  # <log> <test>
  awk -v t="$2" '
    on && /^(PASS|FAIL)[: ]|^Failing suites:|^Tests: / { exit }
    !on && /^FAIL[: ]+/ { n = $0; sub(/^FAIL[: ]+/, "", n); sub(/ .*/, "", n); if (n == t) { on = 1; print; c = 1; next } }
    on { print; if (++c >= 20) exit }' "$1" 2>/dev/null | head -c 2000
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
  [ -n "$before" ] || { [ "${4:-}" = whole ] && before=$'\t'; }
  while IFS=$'\t' read -r name excerpt; do
    if [ -n "$name" ] && printf '%s\n' "$after" | grep -qxF -- "$name"; then continue; fi
    echo "gate-cache: flaky: ${name:-the gate} failed earlier on tree ${tree:0:8} and passed now"
    if declare -F gate_cache_on_flaky >/dev/null; then
      gate_cache_on_flaky "$tree" "$name" "$(printf '%b' "$excerpt")" || true
    fi
  done <<< "$before"
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
  failed=$(gate_log_failed_tests "$out")
  if [ "$recorded" = fail ]; then
    # Same tree, same command, red before: what passes now is flaky.
    if [ "$rc" -eq 0 ]; then _gate_cache_report_flaky "$tree" "$earlier" "" whole
    else _gate_cache_report_flaky "$tree" "$earlier" "$failed"; fi
  fi
  if [ "$rc" -ne 0 ] && [ "${AUTOCODER_GATE_FLAKE_RERUN:-0}" = 1 ]; then
    rerun="$cmd"
    if [ -n "${AUTOCODER_GATE_RERUN_CMD:-}" ] && [ -n "$failed" ] \
       && ! printf '%s\n' "$failed" | grep -qv '^[A-Za-z0-9._/:+-]*$'; then
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
      _gate_cache_report_flaky "$tree" "$earlier" "$(gate_log_failed_tests "$out2")"
      # Keep the failures the re-run confirmed. A re-run that named none (a crash, or a
      # whole-command re-run with other output) keeps the first run's list.
      [ -n "$(gate_log_failed_tests "$out2")" ] && mv -f "$out2" "$out"
    fi
    rm -f "$out2"
  fi
  if [ "$rc" -eq 0 ]; then
    gate_cache_put "$tree" "$cmd" pass "$dir"
  else
    gate_cache_put "$tree" "$cmd" fail "$dir" "$out"
  fi
  rm -f "$out"
  [ "$rc" -eq 0 ]
}

gate_cache_prune() {
  local dir
  dir="$(gate_cache_dir)"
  [ -d "$dir" ] || return 0
  find "$dir" -maxdepth 1 -type f -mtime "+${1:-30}" -delete 2>/dev/null || true
}
