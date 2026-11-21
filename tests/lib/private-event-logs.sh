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
unset -f _pel_mk
if [ -z "${AUTOCODER_ISSUE_EVENTS:-}" ] || [ -z "${AUTOCODER_MERGE_EVENTS:-}" ] || [ -z "${AUTOCODER_LANDING_TIMINGS:-}" ]; then
  echo "private-event-logs.sh: cannot create a private event log; refusing to run against the real one" >&2
  exit 1
fi
export AUTOCODER_ISSUE_EVENTS AUTOCODER_MERGE_EVENTS AUTOCODER_LANDING_TIMINGS
