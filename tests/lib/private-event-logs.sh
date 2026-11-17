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

[ -n "${AUTOCODER_ISSUE_EVENTS:-}" ] \
  || export AUTOCODER_ISSUE_EVENTS="$(mktemp "${TMPDIR:-/tmp}/test-issue-events.XXXXXX")"
[ -n "${AUTOCODER_MERGE_EVENTS:-}" ] \
  || export AUTOCODER_MERGE_EVENTS="$(mktemp "${TMPDIR:-/tmp}/test-merge-events.XXXXXX")"
