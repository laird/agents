# tests/lib/private-event-logs.sh — sourced by every tests/test_*.sh (#255).
#
# issue-fns.sh, merge-launch.sh, merge-to-integration.sh, release.sh, deploy.sh
# and autocoder-ctl.sh append lifecycle and merge-attempt events to
# ~/.local/state/autocoder/{issue,merge}-events.jsonl unless
# AUTOCODER_ISSUE_EVENTS / AUTOCODER_MERGE_EVENTS say otherwise, and /retro reads
# those files. run-shell-suite.sh exports private logs for the whole suite, but a
# test run on its own (`bash tests/test_x.sh`) got neither, so its fake claims,
# releases and merges landed in the real logs.
#
# This keeps a value the caller already exported (the suite's private files, or
# a test's own) and otherwise points each log at a fresh mktemp file: unique and
# created by us, so nobody else on the host can pre-create or read it. No EXIT
# trap removes them, because the tests set their own EXIT traps and one here
# would be overwritten; the files are small and live in the temp directory. A
# test that needs to inspect its events still sets its own path after sourcing.

# A failed mktemp (TMPDIR naming a missing directory) would export an empty path,
# and an empty path falls back to the real log; retry in /tmp, then give up loudly.
_pel_mk() { mktemp "${TMPDIR:-/tmp}/$1.XXXXXX" 2>/dev/null || mktemp "/tmp/$1.XXXXXX"; }
[ -n "${AUTOCODER_ISSUE_EVENTS:-}" ] || AUTOCODER_ISSUE_EVENTS=$(_pel_mk test-issue-events)
[ -n "${AUTOCODER_MERGE_EVENTS:-}" ] || AUTOCODER_MERGE_EVENTS=$(_pel_mk test-merge-events)
[ -n "${AUTOCODER_LANDING_TIMINGS:-}" ] || AUTOCODER_LANDING_TIMINGS=$(_pel_mk test-landing-timings)
[ -n "${AUTOCODER_TRACES:-}" ] || AUTOCODER_TRACES=$(_pel_mk test-traces)
[ -n "${AUTOCODER_TICKS:-}" ] || AUTOCODER_TICKS=$(_pel_mk test-ticks)
[ -n "${AUTOCODER_EVAL_RESULTS:-}" ] || AUTOCODER_EVAL_RESULTS=$(_pel_mk test-eval-results)
# Evaluation cases are a directory, written under the repository root by default (#395).
[ -n "${AUTOCODER_EVAL_CASES:-}" ] || AUTOCODER_EVAL_CASES=$(mktemp -d "${TMPDIR:-/tmp}/test-eval-cases.XXXXXX" 2>/dev/null || mktemp -d "/tmp/test-eval-cases.XXXXXX")
[ -n "${AUTOCODER_EVAL_DECISIONS:-}" ] || AUTOCODER_EVAL_DECISIONS=$(_pel_mk test-eval-decisions)
unset -f _pel_mk
if [ -z "${AUTOCODER_ISSUE_EVENTS:-}" ] || [ -z "${AUTOCODER_MERGE_EVENTS:-}" ] || [ -z "${AUTOCODER_LANDING_TIMINGS:-}" ] || [ -z "${AUTOCODER_TRACES:-}" ] \
   || [ -z "${AUTOCODER_TICKS:-}" ] || [ -z "${AUTOCODER_EVAL_RESULTS:-}" ] || [ -z "${AUTOCODER_EVAL_CASES:-}" ] || [ -z "${AUTOCODER_EVAL_DECISIONS:-}" ]; then
  echo "private-event-logs.sh: cannot create a private event log; refusing to run against the real one" >&2
  exit 1
fi
export AUTOCODER_ISSUE_EVENTS AUTOCODER_MERGE_EVENTS AUTOCODER_LANDING_TIMINGS AUTOCODER_TRACES AUTOCODER_TICKS \
       AUTOCODER_EVAL_RESULTS AUTOCODER_EVAL_CASES AUTOCODER_EVAL_DECISIONS

# The merge job's context variables (#327), for a test run on its own from inside a
# merge job's environment; run-shell-suite.sh drops them for the whole suite too.
# shellcheck source=merge-job-env.sh
source "$(dirname "${BASH_SOURCE[0]}")/merge-job-env.sh"

# Merge/sentinel state (#272). autocoder_tmp_root now defaults to the persistent
# ~/.local/state/autocoder/merge, so a test that launches or polls a merge
# without choosing AUTOCODER_TMP would leave fake .pid/.exit/.run.sh files there
# for good, and one run under a live worker (which exports its real
# AUTOCODER_TMP) would write into the live merge state. Always start from a
# fresh private directory (mktemp -d is 0700). A test that needs a particular
# root still sets AUTOCODER_TMP itself after sourcing this; one that tests the
# default unsets it.
AUTOCODER_TMP=$(mktemp -d "${TMPDIR:-/tmp}/test-autocoder-tmp.XXXXXX" 2>/dev/null || mktemp -d "/tmp/test-autocoder-tmp.XXXXXX") \
  || { echo "private-event-logs.sh: cannot create a private AUTOCODER_TMP; refusing to run against the real one" >&2; exit 1; }
export AUTOCODER_TMP

# Reboot state (#275): the per-user boot stamp and swarm-roots registry
# (reboot-lib.sh) live in ~/.local/state/autocoder. A test that creates a swarm
# or ticks a sentinel would otherwise register fake roots, or move the real
# boot stamp, for the operator's real boot trigger to act on.
AUTOCODER_REBOOT_STATE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/test-reboot-state.XXXXXX" 2>/dev/null || mktemp -d "/tmp/test-reboot-state.XXXXXX") \
  || { echo "private-event-logs.sh: cannot create a private AUTOCODER_REBOOT_STATE_DIR; refusing to run against the real one" >&2; exit 1; }
export AUTOCODER_REBOOT_STATE_DIR

# Everything else in the per-user state dir (#282): the gate cache and gate.jsonl,
# sentinel and publisher state, train state, the auth watchdog, release.log. Each
# resolves ${XDG_STATE_HOME:-$HOME/.local/state}/autocoder, so pointing
# XDG_STATE_HOME at a fresh private directory keeps a test that forgets a
# script-specific override out of the real one. run-shell-suite.sh also runs the
# suite under a scratch HOME and fails if anything is written to its state dir.
XDG_STATE_HOME=$(mktemp -d "${TMPDIR:-/tmp}/test-state-home.XXXXXX" 2>/dev/null || mktemp -d "/tmp/test-state-home.XXXXXX") \
  || { echo "private-event-logs.sh: cannot create a private XDG_STATE_HOME; refusing to run against the real one" >&2; exit 1; }
export XDG_STATE_HOME
